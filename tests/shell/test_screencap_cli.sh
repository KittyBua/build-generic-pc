#!/bin/sh
#
# Contract test for the screencap tool (neutrino,
# src/tools/screencap/screencap.c; core
# in libstb-hal, common/screencap*.c). screencap exists so a capture failure
# on a live box (WORK-273: an empty screenshot after long uptime, with no clue
# why) can be reproduced and localised from a script, on a PC build or on
# hardware, without touching Neutrino itself. What this test pins is the part
# of that contract a script can rely on: help/version, the usage-error
# contract, the exit code table, and the report/JSON shapes -- exercised
# through the one host-safe substitute for real hardware: the video layer fed
# from a plain file standing in for /dev/dvb/adapter0/video0, and the OSD
# layer pointed at a path that provably does not exist standing in for a
# missing/broken /dev/fb0.
#
# Why a raw file, not a fake framebuffer: video0 is a pure read() path, so a
# regular file satisfies it completely (open + read of an exact byte count).
# /dev/fb0 is not: the OSD backend also calls FBIOGET_VSCREENINFO/
# FBIOGET_FSCREENINFO and mmap()s the result, none of which a plain file can
# answer, so a real OSD capture cannot be exercised here at all -- only the
# error path can, by naming a device that is not there.
#
# What this does NOT prove, and why:
#   * A real OSD capture -- needs actual /dev/fb0 ioctls; hardware only
#     (Task 9).
#   * --strict actually softening/hardening a layer: the only way to fail a
#     layer here deterministically is an explicit --fb-device naming a path
#     that cannot be opened, and that is ALWAYS the hard class device-open
#     (13), with or without --strict (ruling R14) -- so --strict's own effect
#     on a genuinely absent layer (osd-unavailable/no-video/busy/
#     layer-unsupported) is not reachable without relying on real device
#     state.
#   * The DEFAULT (no --fb-device/--video-device) candidate search's own
#     soft 11/12 classification: reachable only by relying on /dev/fb0 and
#     /dev/dvb/adapter0/video0 genuinely being absent on the machine running
#     this suite. True on this host today (verified live: exit 11) but not a
#     property this file can assert about every host "make tests-shell" ever
#     runs on, so the deterministic explicit-path hard-13 contract is
#     exercised instead (case 3 below); mktemp -d guarantees that path is
#     absent everywhere.
#   * --key/--via daemon/--host/--port/--user/--key-gap: only their phase-4
#     "not available yet" usage-error contract, never remote/key delivery
#     itself (reserved for a later phase, not built).
#   * Ctrl-C/--timeout expiry: both need real signal/timing behaviour, ruled
#     out by "no reliance on timing" for this suite.
#   * substitute_tag()'s per-stage "[substitute: ...]" marking: a pure
#     function of a struct with no unit-test harness in neutrino (see the
#     Task 7 review notes) -- inspection only, same limitation noted there.
#
# python3 is a SOFT dependency, used only for one bonus check (that the exact
# pixel colour survives BGR24->BGRA32 conversion all the way through the
# CLI); it is not otherwise assumed anywhere in tests-shell. This does NOT
# mean PIL/Pillow is absent from the project -- it is a pip dependency of
# scripts/setup_deps.sh and is imported by scripts/gen_appimage.sh -- only
# that neither tests-shell nor tests/gui (stdlib imports plus pytest, no
# PIL; no requirements.txt either) already assumes it, so this file does not
# newly add that assumption. Its absence skips only the one bonus assertion
# below, never the file. Everything else -- including the PNG's own
# width/height, read out of its IHDR chunk -- uses only POSIX utilities (od,
# printf, grep, wc), matching this suite's existing no-external-deps
# convention.
#
# POSIX sh. Exits 0 on success (including a clean skip), 1 on any failure.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
skip=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf 'FAIL %s\n' "$1"; printf '     %s\n' "$2"; fail=$((fail + 1)); }
sk() { printf 'skip %s\n' "$1"; printf '     %s\n' "$2"; skip=$((skip + 1)); }

summary() {
	printf '[test-screencap-cli] pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
}

# --- locate the binary -------------------------------------------------
# It only exists after `make neutrino && make runtime-sync`, so a missing one
# is a loud skip rather than a failure: the suite runs on trees that were
# never built. A job that means to test the tool sets SCREENCAP_REQUIRE=1,
# and then a missing binary is a failure rather than a green run that tested
# nothing (same convention as STREAMPROBE_REQUIRE in test_streamprobe.sh).
BIN="${SCREENCAP_BIN:-$ROOT_DIR/root/usr/bin/screencap}"
if [ ! -x "$BIN" ]; then
	if [ "${SCREENCAP_REQUIRE:-0}" = "1" ]; then
		ko "screencap binary not found" "SCREENCAP_REQUIRE=1 was set ($BIN)"
		summary
		exit 1
	fi
	sk "screencap binary not found" "run 'make neutrino runtime-sync' first ($BIN)"
	summary
	exit 0
fi

# The binary links libswscale/libavutil (screencap_LDADD in
# src/tools/screencap/Makefile.am); on a machine without the matching system dev
# packages, only the staged sysroot copy resolves the SONAMEs -- same
# reasoning and same path as test_streamprobe.sh's run().
#
# stderr always lands in "$WORK/stderr", fresh on every call, regardless of
# how the caller redirects the *call* to run(): a redirect attached where
# run is invoked (e.g. `run ... 2>&1`) would only apply to fd 2 as seen from
# outside this function, and the explicit `2>"$WORK/stderr"` on the actual
# binary invocation below -- being the innermost, most specific redirect --
# always wins for the real command's own stderr. So every check below reads
# "$WORK/stderr" directly for diagnostic text; nothing tries to reroute it
# from the call site, which would silently be a no-op.
SYSROOT_LIB="$ROOT_DIR/artifacts/sysroot/usr/lib"
run() {
	LD_LIBRARY_PATH="$SYSROOT_LIB:${LD_LIBRARY_PATH:-}" "$BIN" "$@" 2>"$WORK/stderr"
}

PY=""
command -v python3 >/dev/null 2>&1 && PY=python3

# --- fixtures ------------------------------------------------------------
# A 64x36 BGR24 frame, one solid colour (blue: B=255 G=0 R=0), built with
# printf octal escapes so no external tool or python is needed (same
# technique as test_streamprobe.sh's WAV fixture). Built one row at a time
# (64 printf calls) and the row then appended 36 times, rather than one
# printf per pixel (2304 calls) -- cheaper, and the bytes never pass through
# a shell variable, which cannot hold the embedded NUL bytes a BGR pixel
# containing 0x00 needs.
VW=64
VH=36
i=0
: > "$WORK/row.bgr"
while [ "$i" -lt "$VW" ]; do
	printf '\377\000\000' >> "$WORK/row.bgr"
	i=$((i + 1))
done
i=0
: > "$WORK/frame.bgr"
while [ "$i" -lt "$VH" ]; do
	cat "$WORK/row.bgr" >> "$WORK/frame.bgr"
	i=$((i + 1))
done
frame_bytes="$(wc -c < "$WORK/frame.bgr" | tr -d ' ')"
if [ "$frame_bytes" = "$((VW * VH * 3))" ]; then
	ok "the test's own BGR24 fixture is $((VW * VH * 3)) bytes"
else
	ko "the test's own BGR24 fixture is $((VW * VH * 3)) bytes" "got $frame_bytes; printf/cat are not behaving as expected here"
	summary
	exit 1
fi
# A short/truncated copy: same device, an incomplete read.
head -c 1000 "$WORK/frame.bgr" > "$WORK/short.bgr"

# Reads a PNG's IHDR width/height (big-endian u32 at byte offset 16/20) with
# only od -- so the dimension half of the video-capture check below needs no
# python3. PNG signature (8) + length+"IHDR" (8) = 16 bytes before width.
# The unquoted $(od ...) below is deliberate: it feeds od's space-separated
# byte values into "$@" as eight positional parameters.
png_wh() {
	set -- $(od -An -tu1 -j 16 -N 8 "$1" 2>/dev/null)
	if [ $# -ne 8 ]; then
		echo "0 0"
		return
	fi
	echo "$(( (($1 * 256 + $2) * 256 + $3) * 256 + $4 )) $(( (($5 * 256 + $6) * 256 + $7) * 256 + $8 ))"
}

# Extracts one --probe --json step object by its stage name from a JSON blob
# already held in a shell variable. Safe because these step objects are flat
# (no nested '{'/'}' in any field screencap ever emits for this test's own
# fixtures), so "up to the first closing brace" is exactly the object's end.
json_step() {
	printf '%s' "$1" | grep -o "{\"stage\": \"$2\"[^}]*}"
}

# ==========================================================================
# 1. --help / --version: stdout, exit 0 (spec section 8; catches help/version
#    ending up on stderr, or exiting non-zero, which would break any script
#    that runs `screencap --help` to check the tool is present).
out="$(run --help)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "--help exits 0"; else ko "--help exits 0" "rc=$rc"; fi
case "$out" in
	"Usage: screencap"*) ok "--help starts with the usage line" ;;
	*) ko "--help starts with the usage line" "got: $out" ;;
esac
if [ -s "$WORK/stderr" ]; then
	ko "--help writes nothing to stderr" "$(cat "$WORK/stderr")"
else
	ok "--help writes nothing to stderr"
fi

out="$(run --version)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "--version exits 0"; else ko "--version exits 0" "rc=$rc"; fi
case "$out" in
	"screencap "[0-9]*) ok "--version names the tool and a version" ;;
	*) ko "--version names the tool and a version" "got: $out" ;;
esac

# ==========================================================================
# 2. Usage errors: exit 2, message on stderr naming the option, nothing on
#    stdout (spec: "stderr = Diagnose und Usage-Fehler"). Catches a usage
#    error leaking a diagnosis onto stdout, where a script capturing stdout
#    as "the report" would silently treat it as one.
out="$(run --bogus)"
rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown option exits 2"; else ko "unknown option exits 2" "rc=$rc"; fi
if grep -q "^screencap: unknown option" "$WORK/stderr"; then
	ok "unknown option names itself on stderr"
else
	ko "unknown option names itself on stderr" "$(cat "$WORK/stderr")"
fi
if [ -z "$out" ]; then
	ok "unknown option writes nothing to stdout"
else
	ko "unknown option writes nothing to stdout" "$out"
fi

# --osd/--video/--layers are mutually exclusive (spec: "Konflikte").
run --osd --video "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ]; then ok "--osd with --video exits 2"; else ko "--osd with --video exits 2" "rc=$rc"; fi

# --repeat cannot target stdout -- checked in parse_opts() before the isatty
# refusal, so this must be exit 2 whether or not this suite's own stdout
# happens to be a terminal (verified in source: screencap.c's repeat/'-'
# guard runs unconditionally, ahead of the isatty() check).
run --repeat 2 - >/dev/null
rc=$?
if [ "$rc" -eq 2 ]; then ok "--repeat with FILE '-' exits 2"; else ko "--repeat with FILE '-' exits 2" "rc=$rc"; fi

# --layers with no valid value (an all-empty/comma-only value must not fall
# through to layers=0 and get misreported as layer-unsupported/24 -- the
# exact trap fixed during Task 7 review).
run --layers= "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ]; then ok "--layers= (no value) exits 2"; else ko "--layers= (no value) exits 2" "rc=$rc"; fi

# --video-size with trailing garbage must be refused, not silently truncated
# by a lenient WxH scan.
run --video-size 64x36junk "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ]; then ok "--video-size 64x36junk exits 2"; else ko "--video-size 64x36junk exits 2" "rc=$rc"; fi

# Phase-4 reserved options: each is its own usage error today (spec section
# 11); tested individually so a regression in exactly one of them is
# pinpointed rather than hidden behind a single aggregate check. Asserting
# the MESSAGE, not just rc -eq 2, matters: a generic "unknown option '%s'"
# fallback (screencap.c:522) also exits 2, so rc alone cannot tell "still
# has its own phase-4 usage_error() call" from "the special case was
# removed and it now falls through to the generic path" -- proven live by
# the reviewer against a build with the phase-4 handling stripped out, where
# an rc-only version of these six checks stayed green. `grep -q --` guards
# against grep parsing a pattern that starts with "--" as its own options.
run --host box "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ] && grep -q -- "--host is not available before phase 4" "$WORK/stderr"; then
	ok "--host is rejected before phase 4 with its own message"
else
	ko "--host is rejected before phase 4 with its own message" "rc=$rc: $(cat "$WORK/stderr")"
fi
run --port 1234 "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ] && grep -q -- "--port is not available before phase 4" "$WORK/stderr"; then
	ok "--port is rejected before phase 4 with its own message"
else
	ko "--port is rejected before phase 4 with its own message" "rc=$rc: $(cat "$WORK/stderr")"
fi
run --user someone "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ] && grep -q -- "--user is not available before phase 4" "$WORK/stderr"; then
	ok "--user is rejected before phase 4 with its own message"
else
	ko "--user is rejected before phase 4 with its own message" "rc=$rc: $(cat "$WORK/stderr")"
fi
run --key KEY_OK "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ] && grep -q -- "--key is not available before phase 4" "$WORK/stderr"; then
	ok "--key is rejected before phase 4 with its own message"
else
	ko "--key is rejected before phase 4 with its own message" "rc=$rc: $(cat "$WORK/stderr")"
fi
run --key-gap 100 "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ] && grep -q -- "--key-gap is not available before phase 4" "$WORK/stderr"; then
	ok "--key-gap is rejected before phase 4 with its own message"
else
	ko "--key-gap is rejected before phase 4 with its own message" "rc=$rc: $(cat "$WORK/stderr")"
fi
run --via daemon "$WORK/x.png" >/dev/null
rc=$?
if [ "$rc" -eq 2 ] && grep -q -- "--via daemon is not available before phase 4" "$WORK/stderr"; then
	ok "--via daemon is rejected before phase 4 with its own message"
else
	ko "--via daemon is rejected before phase 4 with its own message" "rc=$rc: $(cat "$WORK/stderr")"
fi

# ==========================================================================
# 3. An explicitly named OSD device that cannot be opened is the HARD class
#    device-open (13) -- always, this is the one the user named -- never the
#    softer osd-unavailable (11) the automatic default search can report for
#    the very same missing device (ruling R14). Catches that asymmetry fix
#    regressing, and catches a file being written despite the failure.
out="$(run --osd --fb-device "$WORK/no-such-fb" "$WORK/osd.png")"
rc=$?
if [ "$rc" -eq 13 ]; then ok "explicit --fb-device open failure is exit 13"; else ko "explicit --fb-device open failure is exit 13" "rc=$rc: $out"; fi
case "$out" in
	*no-such-fb*) ok "the report names the device that failed to open" ;;
	*) ko "the report names the device that failed to open" "$out" ;;
esac
if [ -e "$WORK/osd.png" ]; then
	ko "no file is written on a hard failure" "$WORK/osd.png exists"
else
	ok "no file is written on a hard failure"
fi

# ==========================================================================
# 4. Video capture from a raw BGR24 stand-in file: exit 0, correct reported
#    layer, correct PNG dimensions (dependency-free, via IHDR) and -- when
#    python3 is available -- the exact colour survives the BGR24->BGRA32
#    conversion. Catches the video-only path breaking outright, a wrong
#    output size, and (with python3) a channel-order or blend bug becoming
#    visible all the way through the CLI, not just inside libstb-hal's own
#    unit tests. --via direct is spelled out explicitly here so a regression
#    that made the option itself misparse (as opposed to just rejecting
#    "daemon") would also show up.
out="$(run --via direct --video --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} "$WORK/video.png")"
rc=$?
if [ "$rc" -eq 0 ]; then ok "video capture from a raw file exits 0"; else ko "video capture from a raw file exits 0" "rc=$rc: $out"; fi
case "$out" in
	*"Layers       video"*) ok "the report says the video layer was captured" ;;
	*) ko "the report says the video layer was captured" "$out" ;;
esac
wh="$(png_wh "$WORK/video.png")"
if [ "$wh" = "$VW $VH" ]; then
	ok "the captured PNG is exactly ${VW}x${VH}"
else
	ko "the captured PNG is exactly ${VW}x${VH}" "IHDR says: $wh"
fi
if [ -n "$PY" ]; then
	# Minimal PNG decoder (stdlib zlib/struct only, no Pillow): reads the
	# IHDR, inflates the IDAT stream and undoes the per-row PNG filter
	# (spec-defined None/Sub/Up/Average/Paeth) to recover raw RGBA bytes,
	# then reads back the pixel at (10, 10). Cross-checked by hand against
	# Pillow's own decoding of a real screencap PNG before this file was
	# written (they agreed at (0,0), (10,10) and (63,35)); not shipped as a
	# general-purpose decoder, just enough for this one 8-bit RGBA case.
	pix="$("$PY" - "$WORK/video.png" <<'PY'
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
pos = 8
w = h = depth = ctype = None
idat = b''
while pos < len(d):
	n = struct.unpack('>I', d[pos:pos+4])[0]
	t = d[pos+4:pos+8]
	body = d[pos+8:pos+8+n]
	pos += 12 + n
	if t == b'IHDR':
		w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
	elif t == b'IDAT':
		idat += body
	elif t == b'IEND':
		break
raw = zlib.decompress(idat)
stride = w * 4
buf = bytearray(stride * h)
prev = bytearray(stride)
pos = 0
for y in range(h):
	ft = raw[pos]; pos += 1
	row = bytearray(raw[pos:pos + stride]); pos += stride
	for x in range(stride):
		a = row[x - 4] if x >= 4 else 0
		b = prev[x]
		c = prev[x - 4] if x >= 4 else 0
		if ft == 0: pred = 0
		elif ft == 1: pred = a
		elif ft == 2: pred = b
		elif ft == 3: pred = (a + b) // 2
		else:
			p = a + b - c
			pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
			pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
		row[x] = (row[x] + pred) & 0xFF
	buf[y*stride:(y+1)*stride] = row
	prev = row
off = (10 * w + 10) * 4
print(buf[off], buf[off+1], buf[off+2], buf[off+3])
PY
)"
	if [ "$pix" = "0 0 255 255" ]; then
		ok "the captured pixel is opaque blue, unchanged end to end"
	else
		ko "the captured pixel is opaque blue, unchanged end to end" "got RGBA=$pix"
	fi
else
	sk "the captured pixel is opaque blue, unchanged end to end" "python3 not found, dimension check above still ran"
fi

# ==========================================================================
# 5. JPEG via extension, quality reaches the encoder; --type vs. extension
#    conflict is a usage error. Catches --quality being ignored, and the
#    extension/--type conflict guard regressing.
out="$(run --video --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} --quality 20 "$WORK/lo.jpg")"
rc=$?
if [ "$rc" -eq 0 ]; then ok "jpeg at quality 20 exits 0"; else ko "jpeg at quality 20 exits 0" "rc=$rc: $out"; fi
out="$(run --video --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} --quality 95 "$WORK/hi.jpg")"
rc=$?
if [ "$rc" -eq 0 ]; then ok "jpeg at quality 95 exits 0"; else ko "jpeg at quality 95 exits 0" "rc=$rc: $out"; fi
lo="$(wc -c < "$WORK/lo.jpg" | tr -d ' ')"
hi="$(wc -c < "$WORK/hi.jpg" | tr -d ' ')"
if [ "$hi" -ge "$lo" ]; then
	ok "quality 95 is not smaller than quality 20 (lo=$lo hi=$hi)"
else
	ko "quality 95 is not smaller than quality 20" "lo=$lo hi=$hi"
fi
run --type png "$WORK/x.jpg" >/dev/null
rc=$?
if [ "$rc" -eq 2 ]; then ok "--type contradicting the FILE extension exits 2"; else ko "--type contradicting the FILE extension exits 2" "rc=$rc"; fi

# ==========================================================================
# 6. A short/truncated device read is device-read (16), and the message
#    carries the real expected/actual byte counts -- not just the class.
#    Catches a short read being folded into a different class, or the counts
#    not reaching the text (needed to tell "died immediately" from "died
#    mid-frame").
out="$(run --video --video-device "$WORK/short.bgr" --video-size ${VW}x${VH} "$WORK/short.png")"
rc=$?
if [ "$rc" -eq 16 ]; then ok "a short device read exits 16"; else ko "a short device read exits 16" "rc=$rc: $out"; fi
case "$out" in
	*"1000 of $((VW * VH * 3))"*) ok "the report gives the real byte counts (1000 of $((VW * VH * 3)))" ;;
	*) ko "the report gives the real byte counts" "$out" ;;
esac

# ==========================================================================
# 7. A target inside a directory that does not exist is device write
#    failure (19), with the real errno and the actual temp-file path in the
#    text. Silent write failure is the exact WORK-273 shape (the tool says
#    "ok" while nothing landed on disk); this pins that the CLI's own
#    exit_for() mapping for SCREENCAP_ERR_WRITE is reachable end to end
#    through the argument parser and backend construction, not only
#    unit-tested inside libstb-hal's encode_file() in isolation.
out="$(run --video --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} "$WORK/no-such-dir/out.png")"
rc=$?
if [ "$rc" -eq 19 ]; then ok "writing into a non-existent directory exits 19"; else ko "writing into a non-existent directory exits 19" "rc=$rc: $out"; fi
case "$out" in
	*"write errno="*"No such file or directory"*) ok "the report gives the real write errno and reason" ;;
	*) ko "the report gives the real write errno and reason" "$out" ;;
esac

# ==========================================================================
# 8. PATH_MAX: a FILE argument at/over the limit is a clean usage error,
#    never a silent truncation -- the Critical finding of the Task 7 review
#    (a 708-char path was accepted, silently shortened, and the tool still
#    exited 0; screencap.c:548-549 now guards this explicitly) -- and a
#    long-but-still-valid path is written in full, under the exact name
#    asked for, not a shortened one. With Task 9 (hardware) not running this
#    session, this is the only executable coverage this defect class gets
#    in Phase 1.
toolong="$WORK/$(head -c 4200 /dev/zero | tr '\0' a)"
run "$toolong" >/dev/null
rc=$?
if [ "$rc" -eq 2 ] && grep -q "FILE path is too long" "$WORK/stderr"; then
	ok "a FILE path at/over PATH_MAX is a usage error, not a silent truncation"
else
	ko "a FILE path at/over PATH_MAX is a usage error, not a silent truncation" "rc=$rc: $(cat "$WORK/stderr")"
fi

# 15 nested 200-byte directory components: ~3000 bytes, long enough to be a
# meaningful stress case while staying comfortably under PATH_MAX (4096) on
# both the tool's own check and the real filesystem's -- /dev/zero + tr
# avoids the embedded-NUL problem a shell variable would have for arbitrary
# binary data, but is moot here since 'a' has none; used anyway for the same
# fast, dependency-free repeat-a-byte technique as the frame.bgr fixture.
comp="$(head -c 200 /dev/zero | tr '\0' a)"
longdir="$WORK"
n=1
while [ "$n" -le 15 ]; do
	longdir="$longdir/$comp"
	n=$((n + 1))
done
mkdir -p "$longdir"
longfile="$longdir/deep.png"
out="$(run --video --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} "$longfile")"
rc=$?
if [ "$rc" -eq 0 ]; then ok "a long-but-valid path (${#longfile} bytes) exits 0"; else ko "a long-but-valid path (${#longfile} bytes) exits 0" "rc=$rc: $out"; fi
if [ -e "$longfile" ]; then
	ok "the long path is written in full, under the exact name asked for"
else
	ko "the long path is written in full, under the exact name asked for" "not found at: $longfile"
fi
wh="$(png_wh "$longfile")"
if [ "$wh" = "$VW $VH" ]; then
	ok "the file at the long path is a genuine ${VW}x${VH} capture, not a stub"
else
	ko "the file at the long path is a genuine ${VW}x${VH} capture, not a stub" "IHDR says: $wh"
fi

# ==========================================================================
# 9. Device errors are never best effort: OSD hard-fails (explicit bad
#    --fb-device) while video would succeed, and neither --strict nor the
#    default best-effort mode may turn that into a partial exit 0. This is
#    the central "never a false ok" property WORK-273 exists to enforce --
#    catches DEVICE_OPEN being folded into the skippable-absent set
#    (sc_layer_absent()), which would let a real hardware fault yield a
#    silently partial screenshot instead of a hard failure.
run --fb-device "$WORK/no-such-fb" --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} "$WORK/be.png" >/dev/null
rc=$?
if [ "$rc" -eq 13 ]; then ok "a hard device error is never softened to best effort"; else ko "a hard device error is never softened to best effort" "rc=$rc: $(cat "$WORK/stderr")"; fi
if [ -e "$WORK/be.png" ]; then
	ko "no file is written when one layer hard-fails" "$WORK/be.png exists"
else
	ok "no file is written when one layer hard-fails"
fi

# ==========================================================================
# 10. -q/--quiet: nothing at all on success (spec/--help: "errors only"), the
#    full report on failure. Catches -q's success branch printing a
#    half-quiet "Result ok" line, and catches -q hiding a real failure.
out="$(run -q --video --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} "$WORK/q_ok.png")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$WORK/stderr" ]; then
	ok "-q prints nothing at all on success"
else
	ko "-q prints nothing at all on success" "rc=$rc stdout=$out stderr=$(cat "$WORK/stderr")"
fi
out="$(run -q --osd --fb-device "$WORK/no-such-fb" "$WORK/q_fail.png")"
rc=$?
case "$out" in
	*Result*) result_line=1 ;;
	*) result_line=0 ;;
esac
if [ "$rc" -eq 13 ] && [ "$result_line" -eq 1 ]; then
	ok "-q still prints the full report on failure"
else
	ko "-q still prints the full report on failure" "rc=$rc: $out"
fi

# ==========================================================================
# 11. --repeat with a numbered series and --json: exit 0 only if every
#    iteration is ok, the %02d template is honoured, and the JSON reflects
#    exactly the right number of iterations, all "ok". Catches the series
#    file naming breaking, and the JSON iteration count/status not matching
#    what was actually written.
json="$(run --video --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} --repeat 3 --interval 0 --json "$WORK/s-%02d.png")"
rc=$?
if [ "$rc" -eq 0 ]; then ok "a 3-shot --repeat series exits 0"; else ko "a 3-shot --repeat series exits 0" "rc=$rc: $(cat "$WORK/stderr")"; fi
if [ -e "$WORK/s-01.png" ] && [ -e "$WORK/s-02.png" ] && [ -e "$WORK/s-03.png" ]; then
	ok "the %02d template produced s-01/02/03.png"
else
	series_seen=""
	for f in "$WORK"/s-*; do
		[ -e "$f" ] && series_seen="$series_seen $(basename "$f")"
	done
	ko "the %02d template produced s-01/02/03.png" "found:$series_seen"
fi
n_index="$(printf '%s' "$json" | grep -o '"index":' | wc -l | tr -d ' ')"
n_ok="$(printf '%s' "$json" | grep -o '"status": "ok"' | wc -l | tr -d ' ')"
if [ "$n_index" = "3" ] && [ "$n_ok" = "3" ]; then
	ok "the JSON lists exactly 3 iterations, all ok"
else
	ko "the JSON lists exactly 3 iterations, all ok" "index count=$n_index ok count=$n_ok: $json"
fi

# ==========================================================================
# 12. --probe --json: the OSD hard-fails (bad --fb-device), video is real.
#     Per-stage attribution must be exact (osd_open errors as device-open,
#     osd_read is skipped, video/encode/write are ok), and -- ruling R12 --
#     the probe must NEVER touch the FILE argument itself, only a private
#     sibling it creates and removes. Catches the OPEN-vs-READ
#     misattribution defect class (Task 6 finding I3) and, more importantly,
#     a regression of R12: a probe that writes/deletes the user's own named
#     file would be silent data loss on any pre-existing file at that path.
pjson="$(run --probe --json --fb-device "$WORK/no-such-fb" --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} "$WORK/probe.png")"
rc=$?
if [ "$rc" -eq 13 ]; then ok "--probe exits with the first failing stage's class (13)"; else ko "--probe exits with the first failing stage's class (13)" "rc=$rc: $(cat "$WORK/stderr")"; fi
step="$(json_step "$pjson" osd_open)"
case "$step" in
	*'"status": "error"'*'"error": "device-open"'*) ok "probe: osd_open is error/device-open" ;;
	*) ko "probe: osd_open is error/device-open" "$step" ;;
esac
step="$(json_step "$pjson" osd_read)"
case "$step" in
	*'"status": "skipped"'*) ok "probe: osd_read is skipped after osd_open failed" ;;
	*) ko "probe: osd_read is skipped after osd_open failed" "$step" ;;
esac
step="$(json_step "$pjson" video_read)"
case "$step" in
	*'"status": "ok"'*) ok "probe: video_read is ok (the raw file backs it)" ;;
	*) ko "probe: video_read is ok (the raw file backs it)" "$step" ;;
esac
step="$(json_step "$pjson" encode)"
case "$step" in
	*'"status": "ok"'*) ok "probe: encode is ok" ;;
	*) ko "probe: encode is ok" "$step" ;;
esac
step="$(json_step "$pjson" write)"
case "$step" in
	*'"status": "ok"'*) ok "probe: write is ok" ;;
	*) ko "probe: write is ok" "$step" ;;
esac
if [ -e "$WORK/probe.png" ]; then
	ko "probe never creates the FILE argument itself (R12)" "$WORK/probe.png exists"
else
	ok "probe never creates the FILE argument itself (R12)"
fi

# ==========================================================================
# 13. FILE '-': the image goes to stdout, the report to stderr -- never
#     mixed, or a script doing `screencap - | decoder` would feed the
#     decoder a corrupted stream. Stdout is redirected straight to a file
#     here (never captured through a shell variable): it carries raw binary
#     PNG bytes, and "$(...)" both mishandles embedded NULs and strips
#     trailing newline bytes, either of which would corrupt the comparison.
run --video --video-device "$WORK/frame.bgr" --video-size ${VW}x${VH} - >"$WORK/stdout.png"
rc=$?
if [ "$rc" -eq 0 ]; then ok "FILE '-' exits 0"; else ko "FILE '-' exits 0" "rc=$rc: $(cat "$WORK/stderr")"; fi
magic="$(od -An -tx1 -N 8 "$WORK/stdout.png" | tr -s ' ')"
case "$magic" in
	*"89 50 4e 47 0d 0a 1a 0a"*) ok "stdout carries PNG bytes, not the report" ;;
	*) ko "stdout carries PNG bytes, not the report" "first 8 bytes:$magic" ;;
esac
if grep -q "^Result" "$WORK/stderr"; then
	ok "the report (not the image) lands on stderr"
else
	ko "the report (not the image) lands on stderr" "$(cat "$WORK/stderr")"
fi

summary
[ "$fail" -eq 0 ] || exit 1
exit 0
