#!/bin/sh
#
# Contract test for the streamprobe tool (neutrino, src/tools/streamprobe.c).
#
# streamprobe exists so a developer can investigate a stream on a PC and have
# the answer mean something on a box: it opens through the same streaminput
# core neutrino's record and stream-relay paths use. What this test pins is
# the part of that contract a script can rely on -- the exit code per failure
# class, the JSON schema, and that URLs and header blobs stay redacted.
#
# Everything here runs offline: nothing is downloaded and nothing outside this
# machine is contacted. The stimuli are an unknown URL scheme, a missing file,
# a file that is not media, a 52-byte WAV the test writes itself, and one
# loopback socket that accepts a connection and then stays silent -- that last
# one is how the deadline and the interrupt are tested, and it is a bare
# socket, not the HTTP fixture server the stream suite will bring.
#
# What this test does NOT prove. Six classes are reachable offline:
# unsupported-protocol, invalid-manifest, end-of-stream, connection-timeout,
# aborted and unknown. connection-failed is deliberately absent -- a refused local
# port answers ECONNREFUSED on one machine and EPERM in a sandbox, which is
# no contract; that mapping is already pinned without a socket in
# test_streaminput.sh. http-4xx, http-5xx and temporary-network are only
# checked to be *named* by --help; their mapping needs the fixture server
# that comes with the stream suite.
#
# Two more things are left to that suite, both for the same reason -- no
# offline fixture produces them deterministically, and a racy one is worse
# than none:
#
#   * that a mixed --repeat run reports the class of the *first* failed
#     iteration, which needs two different failures in one run;
#   * that media.stable goes false when a source changes between iterations.
#     A fifo fed two different WAVs looks like the answer and is not: FFmpeg
#     does not open the source exactly once per iteration, so the writers and
#     the reader cannot be paired reliably. Measured: eight of eight standalone,
#     three of three hanging inside the suite, with every writer already gone
#     while the probe still waited for one. A mutation that makes media_same()
#     always return true therefore survives this file.
#
# Two more mutations survive, for reasons worth knowing rather than hiding:
#
#   * dropping the "our deadline ends the window" branch in read_window().
#     It only matters for a demuxer that folds an interrupted read into EOF
#     instead of passing the interrupt back -- HLS does, and reaching it
#     needs an fMP4 playlist, i.e. the fixture server.
#   * dropping the late-signal conversion at the end of probe_once(). The
#     abort contract below is pinned, but that particular branch is for a
#     signal arriving between the last check and the end of the iteration,
#     which is a window of microseconds.
#
# The observed classes were pinned against FFmpeg 5.1.4 (the in-tree build).
# A different answer is a finding, not a reason to widen the assertion.
#
# POSIX sh. Exits 0 on success, 1 on any failure.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
helper_pid=""
# The helper socket outlives the script if it is interrupted, so the trap ends
# it as well as removing the scratch directory.
cleanup() {
	[ -n "$helper_pid" ] && kill "$helper_pid" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Used by the JSON assertions and by the helper socket further down, so it is
# resolved once, before the first case that needs it.
PY=""
for cand in "${PYTHON:-}" python3 python; do
	[ -n "$cand" ] || continue
	command -v "$cand" >/dev/null 2>&1 && { PY="$cand"; break; }
done

pass=0
fail=0
skip=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf 'FAIL %s\n' "$1"; printf '     %s\n' "$2"; fail=$((fail + 1)); }
sk() { printf 'skip %s\n' "$1"; printf '     %s\n' "$2"; skip=$((skip + 1)); }

summary() {
	printf '[test-streamprobe] pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
}

# --- locate the binary ------------------------------------------------------
# It only exists after `make neutrino`, so a missing one is a loud skip rather
# than a failure: the suite runs on trees that were never built.
BIN=""
for cand in \
	${STREAMPROBE_BIN:+"$STREAMPROBE_BIN"} \
	${NEUTRINO_INSTALL_DIR:+"$NEUTRINO_INSTALL_DIR${NEUTRINO_PREFIX:-/usr}/bin/streamprobe"} \
	"$ROOT_DIR/artifacts/sysroot/usr/bin/streamprobe" \
	"$ROOT_DIR/root/usr/bin/streamprobe"; do
	if [ -x "$cand" ]; then
		BIN="$cand"
		break
	fi
done
if [ -z "$BIN" ]; then
	# A tree that was never built has no binary, and skipping is right there.
	# A job that means to test the tool sets STREAMPROBE_REQUIRE=1, and then a
	# missing binary is a failure rather than a green run that tested nothing.
	if [ "${STREAMPROBE_REQUIRE:-0}" = "1" ]; then
		ko "streamprobe binary not found" "STREAMPROBE_REQUIRE=1 was set"
		summary
		exit 1
	fi
	sk "streamprobe binary not found" "run 'make neutrino' first"
	summary
	exit 0
fi

# The binary links the staged FFmpeg, which is not on the default loader path.
run() {
	LD_LIBRARY_PATH="$ROOT_DIR/artifacts/sysroot/usr/lib:${LD_LIBRARY_PATH:-}" \
		"$BIN" "$@" 2>"$WORK/stderr"
}
# stdout and stderr together: the redaction cases have to cover what FFmpeg
# prints as well, not only what the tool prints.
run_both() {
	LD_LIBRARY_PATH="$ROOT_DIR/artifacts/sysroot/usr/lib:${LD_LIBRARY_PATH:-}" \
		"$BIN" "$@" 2>&1
}

# --- fixtures ---------------------------------------------------------------
# A minimal WAV: 44-byte header plus 8 bytes of silence, 16-bit mono 8000 Hz.
# Written with octal escapes so no external tool is needed. A wrong size means
# this script is broken on this shell -- that is a failure, not a skip, or the
# suite would go green while testing nothing.
WAV="$WORK/min.wav"
printf 'RIFF\054\000\000\000WAVEfmt \020\000\000\000\001\000\001\000\100\037\000\000\200\076\000\000\002\000\020\000data\010\000\000\000\000\000\000\000\000\000\000\000' > "$WAV"
wav_size="$(wc -c < "$WAV" | tr -d ' ')"
if [ "$wav_size" = "52" ]; then
	ok "the test's own WAV fixture is 52 bytes"
else
	ko "the test's own WAV fixture is 52 bytes" "got $wav_size; printf escapes are not portable here"
	summary
	exit 1
fi

NOISE="$WORK/noise.bin"
i=0
: > "$NOISE"
while [ "$i" -lt 32 ]; do
	printf 'not media at all, just words ' >> "$NOISE"
	i=$((i + 1))
done

MISSING="$WORK/does-not-exist.ts"

# --- help and version -------------------------------------------------------
out="$(run --help)"
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "--help exits 0"
else
	ko "--help exits 0" "rc=$rc"
fi
missing=""
for want in -- --repeat --open-time --json --show-url --show-headers "Exit codes:"; do
	case "$out" in
		*"$want"*) ;;
		*) missing="$missing $want" ;;
	esac
done
if [ -z "$missing" ]; then
	ok "--help documents the M6 surface"
else
	ko "--help documents the M6 surface" "missing:$missing"
fi

# Every failure class the core knows must have a documented exit code, and the
# help must print them from the same table the tool exits with.
classes="connection-failed connection-timeout http-4xx http-5xx invalid-manifest
	unsupported-protocol temporary-network end-of-stream aborted unknown"
missing=""
for cls in $classes; do
	printf '%s\n' "$out" | grep -qE "^ +[0-9]+  $cls\$" || missing="$missing $cls"
done
if [ -z "$missing" ]; then
	ok "--help names an exit code for every failure class"
else
	ko "--help names an exit code for every failure class" "missing:$missing"
fi

# The published exit codes, written down here rather than read out of the
# tool. Deriving them from --help would let a consistent renumbering pass:
# the tool and its help would agree with each other and disagree with every
# script that ever used them.
C_CONN_FAILED=10
C_TIMEOUT=11
C_HTTP4XX=12
C_HTTP5XX=13
C_INVALID=14
C_UNSUPPORTED=15
C_TEMPNET=16
C_EOS=17
C_ABORTED=18
C_UNKNOWN=19

code_for() {
	printf '%s\n' "$out" | sed -n "s/^ *\([0-9][0-9]*\)  $1\$/\1/p" | head -1
}
mismatch=""
for pair in "connection-failed=$C_CONN_FAILED" "connection-timeout=$C_TIMEOUT" \
	"http-4xx=$C_HTTP4XX" "http-5xx=$C_HTTP5XX" "invalid-manifest=$C_INVALID" \
	"unsupported-protocol=$C_UNSUPPORTED" "temporary-network=$C_TEMPNET" \
	"end-of-stream=$C_EOS" "aborted=$C_ABORTED" "unknown=$C_UNKNOWN"; do
	cls="${pair%=*}"
	want="${pair#*=}"
	got="$(code_for "$cls")"
	[ "$got" = "$want" ] || mismatch="$mismatch $cls(help=$got want=$want)"
done
if [ -z "$mismatch" ]; then
	ok "--help agrees with the published exit codes"
else
	ko "--help agrees with the published exit codes" "$mismatch"
fi

ver="$(run --version)"
rc=$?
missing=""
for lib in libavformat libavcodec libavutil; do
	printf '%s\n' "$ver" | grep -qE "^$lib +runtime [0-9]+\.[0-9]+\.[0-9]+ build [0-9]+\.[0-9]+\.[0-9]+" \
		|| missing="$missing $lib"
done
if [ "$rc" -eq 0 ] && [ -z "$missing" ]; then
	ok "--version reports runtime and build versions of all three libav libraries"
else
	ko "--version reports runtime and build versions of all three libav libraries" \
		"rc=$rc missing:$missing"
fi

# --- usage errors -----------------------------------------------------------
usage_case() { # $1 = description, rest = argv
	uc_desc="$1"
	shift
	uc_out="$(run "$@")"
	uc_rc=$?
	if [ "$uc_rc" -eq 2 ] && [ -z "$uc_out" ] && [ -s "$WORK/stderr" ]; then
		ok "$uc_desc"
	else
		ko "$uc_desc" "rc=$uc_rc stdout='$uc_out'"
	fi
}
usage_case "no argument is a usage error" 
usage_case "an unknown option is a usage error" --nope "$WAV"
usage_case "--repeat 0 is a usage error" --repeat 0 "$WAV"
usage_case "--repeat abc is a usage error" --repeat abc "$WAV"
usage_case "--open-time -1 is a usage error" --open-time -1 "$WAV"
usage_case "--repeat without a value is a usage error" --repeat
usage_case "an unknown profile is a usage error" --profile live "$WAV"
usage_case "two urls are a usage error" "$WAV" "$WAV"
usage_case "an empty url is a usage error" ""

# An error message is output like any other: a url on the command line can
# carry a token, so it must not be echoed back.
run "http://127.0.0.1:1/x?token=LEAKME" "http://second/url" >/dev/null 2>&1
if grep -q LEAKME "$WORK/stderr"; then
	ko "a usage error does not echo the url" "the token reached stderr"
else
	ok "a usage error does not echo the url"
fi

# --- failure classes, offline ----------------------------------------------
class_case() { # $1 desc, $2 expected class, $3 expected code, rest argv
	cc_desc="$1"; cc_cls="$2"; cc_code="$3"
	shift 3
	cc_out="$(run "$@")"
	cc_rc=$?
	cc_seen="$(printf '%s\n' "$cc_out" | sed -n 's/^Failure  *//p')"
	if [ "$cc_rc" = "$cc_code" ] && [ "$cc_seen" = "$cc_cls" ]; then
		ok "$cc_desc"
	else
		ko "$cc_desc" "want class=$cc_cls exit=$cc_code, got class=$cc_seen exit=$cc_rc"
	fi
}
class_case "an unknown url scheme is unsupported-protocol" unsupported-protocol "$C_UNSUPPORTED" "sptest://x/y"
class_case "a missing file is unknown" unknown "$C_UNKNOWN" "$MISSING"
class_case "a file that is not media is invalid-manifest" invalid-manifest "$C_INVALID" "$NOISE"
class_case "a live source that ends is end-of-stream" end-of-stream "$C_EOS" --live --open-time 1 "$WAV"

# --- a deadline on a network source: prompt, and never an abort ------------
# A socket that accepts and then says nothing is the canonical --open-time
# stimulus, and unlike a local file FFmpeg honours the deadline there
# promptly. This is a bare socket, not the fixture server the stream suite
# will bring: it speaks no HTTP and answers nothing.
if [ -n "$PY" ]; then
	cat > "$WORK/silent.py" <<'PYEOF'
import socket, sys, threading, time

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(4)
print(srv.getsockname()[1], flush=True)

def serve(c):
	try:
		c.recv(4096)
		time.sleep(30)
	except Exception:
		pass
	finally:
		c.close()

while True:
	conn, _ = srv.accept()
	threading.Thread(target=serve, args=(conn,), daemon=True).start()
PYEOF
	"$PY" "$WORK/silent.py" > "$WORK/port" 2>/dev/null &
	helper_pid=$!
	port=""
	i=0
	# Whole seconds: fractional sleep is not POSIX, and five tries is plenty
	# for a python interpreter to bind a loopback socket.
	while [ "$i" -lt 5 ]; do
		port="$(cat "$WORK/port" 2>/dev/null)"
		[ -n "$port" ] && break
		i=$((i + 1))
		sleep 1
	done
	if [ -n "$port" ]; then
		out="$(run --open-time 1 "http://127.0.0.1:$port/x.ts")"
		rc=$?
		seen="$(printf '%s\n' "$out" | sed -n 's/^Failure  *//p')"
		if [ "$rc" = "$C_TIMEOUT" ] && [ "$seen" = "connection-timeout" ]; then
			ok "a silent server plus --open-time is a timeout, not an abort"
		else
			ko "a silent server plus --open-time is a timeout, not an abort" \
				"want class=connection-timeout exit=$C_TIMEOUT, got class=$seen exit=$rc"
		fi
		case "$out" in
			*"Deadline     --open-time expired"*)
				ok "the report says the deadline fired" ;;
			*) ko "the report says the deadline fired" "no deadline line: $out" ;;
		esac
		# and the JSON carries the same fact, which is what a script reads
		run --json --open-time 1 "http://127.0.0.1:$port/x.ts" > "$WORK/deadline.json"
		if [ -n "$PY" ] && "$PY" -c 'import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if all(i["deadline_hit"] is True for i in d["iterations"]) else 1)' \
			"$WORK/deadline.json" 2>"$WORK/pyerr"; then
			ok "the json carries deadline_hit as well"
		else
			ko "the json carries deadline_hit as well" "$(cat "$WORK/pyerr" 2>/dev/null)"
		fi
	else
		sk "the network deadline" "the helper socket did not come up"
	fi
	# The abort contract, on the same socket: a signal ends the run as
	# aborted with its own exit code, and that is the one path where the
	# tool must not call its own timer a user abort or the other way round.
	if [ -n "$port" ]; then
		LD_LIBRARY_PATH="$ROOT_DIR/artifacts/sysroot/usr/lib:${LD_LIBRARY_PATH:-}" \
			"$BIN" --open-time 20 "http://127.0.0.1:$port/x.ts" > "$WORK/abort.out" 2>/dev/null &
		probe_pid=$!
		sleep 1
		kill -INT "$probe_pid" 2>/dev/null
		wait "$probe_pid" 2>/dev/null
		rc=$?
		seen="$(sed -n 's/^Failure  *//p' "$WORK/abort.out")"
		if [ "$rc" = "$C_ABORTED" ] && [ "$seen" = "aborted" ]; then
			ok "an interrupt ends the run as aborted"
		else
			ko "an interrupt ends the run as aborted" \
				"want class=aborted exit=$C_ABORTED, got class=$seen exit=$rc"
		fi
	fi

	kill "$helper_pid" 2>/dev/null
	wait "$helper_pid" 2>/dev/null
	helper_pid=""
else
	sk "the network deadline" "no python interpreter for the helper socket"
fi

# --- the policy actually reaches the open ----------------------------------
# Deliberately no class assertion here: whether a refused local port answers
# ECONNREFUSED or EPERM depends on the sandbox. The policy line is printed
# before the open, so it is deterministic either way.
out="$(run "http://127.0.0.1:1/x.ts")"
policy="$(printf '%s\n' "$out" | sed -n 's/^Policy  *//p')"
proto="$(printf '%s\n' "$out" | sed -n 's/^Protocol  *//p')"
case "$policy" in
	*timeout=20000000*reconnect=1*)
		if [ "$proto" = "http" ]; then
			ok "an http url gets the record policy: timeout and reconnect"
		else
			ko "an http url gets the record policy: timeout and reconnect" "protocol=$proto"
		fi ;;
	*)
		ko "an http url gets the record policy: timeout and reconnect" "policy='$policy'" ;;
esac

out="$(run "$WAV")"
policy="$(printf '%s\n' "$out" | sed -n 's/^Policy  *//p')"
proto="$(printf '%s\n' "$out" | sed -n 's/^Protocol  *//p')"
if [ -z "$policy" ] && [ "$proto" = "file" ]; then
	ok "a file url gets no network policy"
else
	ko "a file url gets no network policy" "protocol=$proto policy='$policy'"
fi

# --- the success path -------------------------------------------------------
out="$(run "$WAV")"
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "the WAV fixture opens and probes"
else
	ko "the WAV fixture opens and probes" "rc=$rc; $out"
fi
missing=""
for want in "Container    wav" "pcm_s16le" "Result       ok"; do
	case "$out" in
		*"$want"*) ;;
		*) missing="$missing '$want'" ;;
	esac
done
if [ -z "$missing" ]; then
	ok "the report names the container and the audio codec"
else
	ko "the report names the container and the audio codec" "missing:$missing"
fi

out="$(run --open-time 1 "$WAV")"
rc=$?
case "$out" in
	*"Packets      1"*)
		if [ "$rc" -eq 0 ]; then
			ok "--open-time reads packets, and a finite file ending is not a failure"
		else
			ko "--open-time reads packets, and a finite file ending is not a failure" "rc=$rc"
		fi ;;
	*) ko "--open-time reads packets, and a finite file ending is not a failure" "$out" ;;
esac

# An option the demuxer does not know is reported back rather than swallowed.
out="$(run --show-headers --headers 'X-Test: y' "$WAV")"
unconsumed="$(printf '%s\n' "$out" | sed -n 's/^Not consumed  *//p')"
case "$unconsumed" in
	*headers=*) ok "an option the demuxer ignores is reported as not consumed" ;;
	*) ko "an option the demuxer ignores is reported as not consumed" "got '$unconsumed'" ;;
esac

# --- JSON -------------------------------------------------------------------
if [ -z "$PY" ]; then
	sk "JSON assertions" "no python interpreter to parse with"
else
	# A real parser, not a grep: invalid JSON, wrong types and a summary that
	# contradicts the iterations all pass a substring check.
	run --json --repeat 3 --open-time 1 "$WAV" > "$WORK/ok.json"
	rc=$?
	if "$PY" - "$WORK/ok.json" "$rc" 2>"$WORK/pyerr" <<'PYEOF'
import json, sys

doc = json.load(open(sys.argv[1]))
rc = int(sys.argv[2])
problems = []

def want(cond, msg):
	if not cond:
		problems.append(msg)

want(doc["tool"] == "streamprobe", "tool name")
want(isinstance(doc["tool_version"], str), "tool_version type")
for lib in ("avformat", "avcodec", "avutil"):
	want(isinstance(doc["libav"][lib]["runtime"], str), lib + " runtime")
	want(isinstance(doc["libav"][lib]["build"], str), lib + " build")
want(doc["libav"]["version_mismatch"] is False, "version mismatch")
want(doc["protocol"] == "file", "protocol")
want(doc["live"] == 0, "live default")
want(doc["profile"] == "record", "profile")
# nothing to hide in a plain path, so nothing was hidden
want(doc["url_redacted"] is False, "url_redacted on a url without a query")
want(isinstance(doc["policy"], dict), "policy type")
# an open succeeded, so this is a result ({}), not the absence of one (null)
want(doc["policy_unconsumed"] == {}, "policy_unconsumed after a successful open")
want(doc["repeat"] == 3 and doc["open_time_s"] == 1, "repeat/open_time echo")
want(len(doc["iterations"]) == doc["summary"]["attempts"] == 3, "iteration count")
want([it["index"] for it in doc["iterations"]] == [0, 1, 2], "iteration indices")
want(all(it["result"] == "ok" for it in doc["iterations"]), "iteration results")
want(doc["summary"]["ok"] == 3 and doc["summary"]["failed"] == 0, "summary counts")
want(doc["summary"]["packets"] == sum(it["packets"] for it in doc["iterations"]), "packet total")
want(doc["summary"]["failure_classes"] == {}, "empty histogram on success")
want(doc["media"]["container"] == "wav", "container")
want(doc["media"]["audio"]["codec"] == "pcm_s16le", "audio codec")
want(doc["media"]["video"] is None, "no video stream")
want(doc["media"]["stable"] is True, "media stable across iterations")
# this window ends at the end of the file, not at the deadline, and the flag
# has to say so -- the other direction is pinned on the silent socket
want(all(it["deadline_hit"] is False for it in doc["iterations"]), "no deadline hit on a file that ends")
want(doc["exit_code"] == rc == 0, "exit code agrees with the process")

if problems:
	print("json contract: " + ", ".join(problems), file=sys.stderr)
	sys.exit(1)
PYEOF
	then
		ok "the success JSON is valid and internally consistent"
	else
		ko "the success JSON is valid and internally consistent" "$(cat "$WORK/pyerr" 2>/dev/null)"
	fi

	run --json --repeat 2 "$NOISE" > "$WORK/fail.json"
	rc=$?
	if "$PY" - "$WORK/fail.json" "$rc" "$C_INVALID" 2>"$WORK/pyerr" <<'PYEOF'
import json, sys

doc = json.load(open(sys.argv[1]))
rc = int(sys.argv[2])
want_code = int(sys.argv[3])
problems = []

def want(cond, msg):
	if not cond:
		problems.append(msg)

want(len(doc["iterations"]) == 2, "iteration count")
want(all(it["result"] == "failed" for it in doc["iterations"]), "results")
want(all(it["failure_class"] == "invalid-manifest" for it in doc["iterations"]), "class")
want(all(it["ffmpeg_error"] < 0 for it in doc["iterations"]), "ffmpeg error present")
want(doc["summary"]["failed"] == 2 and doc["summary"]["ok"] == 0, "summary counts")
want(doc["summary"]["failure_classes"] == {"invalid-manifest": 2}, "histogram")
# internal failures carry no class, so they are counted separately; together
# the two must account for every failure or a consumer cannot reconcile them
want(sum(doc["summary"]["failure_classes"].values()) + doc["summary"]["internal"]
	== doc["summary"]["failed"], "histogram plus internal covers every failure")
# no open succeeded, so there is nothing FFmpeg could have left unconsumed
want(doc["policy_unconsumed"] is None, "policy_unconsumed without a successful open")
want(doc["url_redacted"] is False, "url_redacted on a url without a query")
want(doc["media"] is None, "no media")
want(doc["exit_code"] == rc == want_code, "exit code agrees with the process and the help table")

if problems:
	print("json contract: " + ", ".join(problems), file=sys.stderr)
	sys.exit(1)
PYEOF
	then
		ok "the failure JSON keeps the schema and reports the class"
	else
		ko "the failure JSON keeps the schema and reports the class" "$(cat "$WORK/pyerr" 2>/dev/null)"
	fi

	# Every shape of invalid UTF-8, not just the easy one. A guard that only
	# checks "the next bytes look like continuations" lets three classes
	# through, and each of them makes json.load() refuse the document:
	#   \370...    a lead byte above the legal range
	#   \300\200   an overlong encoding of NUL
	#   \355\240\200 a UTF-16 surrogate
	# The truncated sequence \341\202 is the one such a guard does catch.
	for bytes_desc in 'f8:\370\200\200\200' 'overlong:\300\200' 'surrogate:\355\240\200' 'truncated:\341\202'; do
		bd_name="${bytes_desc%%:*}"
		bd_bytes="${bytes_desc#*:}"
		run --json --show-headers --headers "$(printf "X-Bin: ${bd_bytes} tail")" "$WAV" \
			> "$WORK/utf8.json"
		if "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if "\ufffd" in d["policy"]["headers"] and "tail" in d["policy"]["headers"] else 1)' \
			"$WORK/utf8.json" 2>"$WORK/pyerr"; then
			ok "invalid utf-8 ($bd_name) still yields parseable JSON"
		else
			ko "invalid utf-8 ($bd_name) still yields parseable JSON" "$(cat "$WORK/pyerr" 2>/dev/null)"
		fi
	done
	# Real multibyte UTF-8 has to survive untouched -- a guard that replaced
	# everything would pass the cases above and destroy legitimate text.
	run --json --show-headers --headers "$(printf 'X-Bin: \303\244\342\202\254\360\237\216\265 tail')" "$WAV" \
		> "$WORK/utf8ok.json"
	if "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); h=d["policy"]["headers"]; sys.exit(0 if "\u00e4\u20ac\U0001f3b5" in h and "\ufffd" not in h else 1)' \
		"$WORK/utf8ok.json" 2>"$WORK/pyerr"; then
		ok "valid multibyte utf-8 passes through unchanged"
	else
		ko "valid multibyte utf-8 passes through unchanged" "$(cat "$WORK/pyerr" 2>/dev/null)"
	fi

	# The opt-outs produce JSON as well.
	run --json --show-url --show-headers \
		--headers "$(printf 'X-Bin: \377\200 tail')" "http://127.0.0.1:1/x?token=s3cr3t" \
		> "$WORK/optout.json"
	if "$PY" - "$WORK/optout.json" 2>"$WORK/pyerr" <<'PYEOF'
import json, sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
problems = []

def want(cond, msg):
	if not cond:
		problems.append(msg)

want(doc["url"].endswith("?token=s3cr3t"), "--show-url puts the full url in the json")
want(doc["url_redacted"] is False, "url_redacted is false when nothing was hidden")
want("X-Bin" in doc["policy"]["headers"], "--show-headers puts the blob in the json")
want("\ufffd" in doc["policy"]["headers"], "invalid bytes became replacement characters")

if problems:
	print("json opt-out: " + ", ".join(problems), file=sys.stderr)
	sys.exit(1)
PYEOF
	then
		ok "--show-url and --show-headers produce valid JSON, invalid bytes and all"
	else
		ko "--show-url and --show-headers produce valid JSON, invalid bytes and all" \
			"$(cat "$WORK/pyerr" 2>/dev/null)"
	fi
fi

# --- redaction --------------------------------------------------------------
SECRET_URL="http://127.0.0.1:1/x?token=s3cr3t"
out="$(run_both "$SECRET_URL")"
case "$out" in
	*s3cr3t*) ko "a query string is redacted by default" "the secret reached the output" ;;
	*"?<redacted>"*) ok "a query string is redacted by default" ;;
	*) ko "a query string is redacted by default" "no redaction marker: $out" ;;
esac

out="$(run_both --show-url "$SECRET_URL")"
case "$out" in
	*token=s3cr3t*) ok "--show-url prints the full url" ;;
	*) ko "--show-url prints the full url" "$out" ;;
esac

out="$(run_both --json "$SECRET_URL")"
case "$out" in
	*s3cr3t*) ko "--json is not a redaction bypass" "the secret reached the JSON" ;;
	*"?<redacted>"*)
		# and the flag says so: the other half of the pair asserted above,
		# where a url without a query reports false.
		case "$out" in
			*'"url_redacted": true'*) ok "--json is not a redaction bypass" ;;
			*) ko "--json is not a redaction bypass" "redacted, but url_redacted is not true" ;;
		esac ;;
	*) ko "--json is not a redaction bypass" "no redaction marker in the JSON" ;;
esac

out="$(run_both --headers 'Cookie: sid=c00k13' "$WAV")"
case "$out" in
	*c00k13*) ko "a header blob is hidden by default" "the cookie reached the output" ;;
	*"headers=<hidden>"*) ok "a header blob is hidden by default" ;;
	*) ko "a header blob is hidden by default" "no hidden marker: $out" ;;
esac

out="$(run_both --json --headers 'Cookie: sid=c00k13' "$WAV")"
case "$out" in
	*c00k13*) ko "a header blob is hidden in the JSON too" "the cookie reached the JSON" ;;
	*'"<hidden>"'*) ok "a header blob is hidden in the JSON too" ;;
	*) ko "a header blob is hidden in the JSON too" "no hidden marker in the JSON" ;;
esac

out="$(run_both --show-headers --headers 'Cookie: sid=c00k13' "$WAV")"
case "$out" in
	*c00k13*) ok "--show-headers prints the blob" ;;
	*) ko "--show-headers prints the blob" "$out" ;;
esac

# FFmpeg prints the string it is handed, so the dump has to get the redacted
# one -- otherwise --av-dump would be a second bypass. Checked on a file that
# actually opens, and requiring a real dump line: a run that prints nothing
# at all would satisfy "no secret in the output" while testing nothing. The
# query is part of the path here, so the same name carries a secret and still
# resolves to the fixture.
SECRET_WAV="$WORK/probe?token=s3cr3t.wav"
cp "$WAV" "$SECRET_WAV"
out="$(run_both --av-dump "$SECRET_WAV")"
case "$out" in
	*"Input #0"*)
		case "$out" in
			*s3cr3t*) ko "--av-dump dumps, and without the secret" "the secret reached the dump" ;;
			*) ok "--av-dump dumps, and without the secret" ;;
		esac ;;
	*) ko "--av-dump dumps, and without the secret" "no dump line at all: $out" ;;
esac

# --- --repeat 1 is the plain report, byte for byte -------------------------
# The default output is what a person reads; the iteration table only appears
# above one repetition. Nothing else pins that.
if [ "$(run "$WAV")" = "$(run --repeat 1 "$WAV")" ]; then
	ok "--repeat 1 prints exactly the default report"
else
	ko "--repeat 1 prints exactly the default report" "the two differ"
fi

# --- credentials in the url are hidden too ---------------------------------
# The core hides the query; user:password sits in front of the host and is how
# more than one resolver delivers an authenticated stream.
CRED_URL="http://user:p4ssw0rd@127.0.0.1:1/x.ts"
out="$(run_both "$CRED_URL")"
case "$out" in
	*p4ssw0rd*) ko "credentials in the url are hidden" "the password reached the output" ;;
	*"<redacted>@127.0.0.1"*) ok "credentials in the url are hidden" ;;
	*) ko "credentials in the url are hidden" "no redaction of the authority: $out" ;;
esac
out="$(run_both --json "$CRED_URL")"
case "$out" in
	*p4ssw0rd*) ko "credentials are hidden in the JSON too" "the password reached the JSON" ;;
	*"<redacted>@127.0.0.1"*) ok "credentials are hidden in the JSON too" ;;
	*) ko "credentials are hidden in the JSON too" "no redaction in the JSON" ;;
esac
out="$(run_both --show-url "$CRED_URL")"
case "$out" in
	*p4ssw0rd*) ok "--show-url shows the credentials as well" ;;
	*) ko "--show-url shows the credentials as well" "$out" ;;
esac
# An @ outside the authority is an ordinary character and must survive.
out="$(run_both "http://127.0.0.1:1/p@th/x.ts")"
case "$out" in
	*"/p@th/x.ts"*) ok "an @ in the path is left alone" ;;
	*) ko "an @ in the path is left alone" "$out" ;;
esac

summary
[ "$fail" -eq 0 ] || exit 1
exit 0
