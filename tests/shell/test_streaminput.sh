#!/bin/sh
#
# Unit test for the shared stream input core in libstb-hal
# (common/streaminput.c, include/streaminput.h) and its FFmpeg bridge
# (include/streaminput_ffmpeg.h).
#
# The module's whole justification is behaviour equivalence: it replaced two
# hand-copied FFmpeg option blocks in neutrino (CStreamRec::Open and
# CStreamStream::Open) and must keep emitting exactly what they emitted --
# headers when the resolver supplied any, plus timeout=20000000 and
# reconnect=1 for http(s) URLs and nothing else. Nothing in the repository's
# gates would notice if that drifted, so this file pins it.
#
# Two drivers do that. The first compiles against the core alone -- no libav
# anywhere, the core is deliberately libav-free (the STB builds have no
# AVUTIL_CFLAGS) -- and compares the option list as text. The second EXECUTES
# the bridge header's production entry point streaminput_apply_policy() --
# what record.cpp and streamts.cpp actually call -- which drives
# streaminput_kv_to_avdict() internally: both are static inline and their
# only libav reference is av_dict_set(), so the driver supplies a recording
# mock and no libavutil is linked. That driver is built and run both as C and as C++;
# the linked C++ run is what proves the extern "C" contract, a defect class
# that a pure syntax check cannot see and that historically only showed at
# link time.
#
# Cases are looked up by tag rather than line number: a header blob
# contains CRLF and would otherwise shift every following assertion.
#
# POSIX sh, needs only a C compiler (the C++ leg skips loudly without one).
# Skips cleanly when the libstb-hal source tree is absent. Exits 0 on
# success, 1 on any failure.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HAL_DIR="${LIBSTB_HAL_DIR:-$ROOT_DIR/sources/libstb-hal}"
SRC="$HAL_DIR/common/streaminput.c"
INC="$HAL_DIR/include"

pass=0
fail=0

ok()
{
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}

no()
{
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1"
	if [ $# -gt 1 ]; then
		printf '     %s\n' "$2"
	fi
	return 0
}

skip=0
skipped()
{
	skip=$((skip + 1))
	printf 'skip %s\n' "$1"
}

if [ ! -f "$SRC" ] || [ ! -f "$INC/streaminput.h" ]; then
	printf 'SKIP no libstb-hal source tree at %s\n' "$HAL_DIR"
	exit 0
fi

# CC arrives from the environment under "make test-shell", where it can be a
# multi-word command such as "ccache gcc" and, with no ccache wrapper
# configured, carries a leading space (make/toolchain.mk:44). Testing the raw
# value with command -v fails in both cases, and this file skipped itself
# without ever compiling anything -- the same trap test_appimage_bridge.sh
# documents. Whitespace runs are squeezed too: a doubled space or a tab
# would make the word splits below come out empty. When the first word is
# the ccache wrapper -- toolchain.mk stores it as an absolute path -- the
# compiler to probe is the word behind it: probing the wrapper would only
# prove that ccache exists. A missing C compiler is failed loudly rather
# than skipped: a skip would let the suite pass while nothing here was
# exercised. CXX below goes through the same two helpers.
normalize_compiler()
{
	printf '%s' "$1" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

probe_target()
{
	_bin="${1%% *}"
	_rest="${1#* }"
	if [ "${_bin##*/}" = ccache ]; then
		# a bare ccache with nothing behind it names no compiler; an
		# empty probe target fails the command -v gate loudly instead
		# of blaming the module for a toolchain typo
		[ "$_rest" != "$1" ] && printf '%s' "${_rest%% *}"
	else
		printf '%s' "$_bin"
	fi
}

CC="$(normalize_compiler "${CC:-cc}")"
[ -n "$CC" ] || CC=cc
CC_PROBE="$(probe_target "$CC")"
if ! command -v "$CC_PROBE" >/dev/null 2>&1; then
	no "a C compiler is available to build the driver" \
		"'$CC_PROBE' is not on PATH; reporting that as a skip would hide that
     nothing in this file ran"
	printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The driver prints one tagged line per case: "<tag>\t<value>". Tags rather
# than line numbers, because a header value legitimately contains CRLF and
# would otherwise shift every following assertion. Control characters are
# escaped so one case stays one line.
cat > "$WORK/driver.c" <<'EOF'
#include <stdio.h>
#include <streaminput.h>

/* CR and LF as two-character escapes: a header blob is multi-line by
 * nature and must not break the one-line-per-case output. */
static void put_escaped(const char *s)
{
	for (; *s; s++)
	{
		if (*s == '\r')
			fputs("\\r", stdout);
		else if (*s == '\n')
			fputs("\\n", stdout);
		else
			putchar(*s);
	}
}

/* Every return code is checked: a builder that failed without touching
 * the list must not let an expected-empty case report success. */
static void policy(const char *tag, const char *url, const char *headers)
{
	stream_source_t s;
	stream_kv_list_t kv;
	size_t i;

	streaminput_source_init(&s);
	streaminput_kv_init(&kv);
	if (streaminput_source_set_url(&s, url) < 0)
	{
		printf("%s\tDRIVER-ERROR:set_url\n", tag);
		goto out;
	}
	if (streaminput_source_set_headers(&s, headers) < 0)
	{
		printf("%s\tDRIVER-ERROR:set_headers\n", tag);
		goto out;
	}
	if (streaminput_policy_build(&s, STREAM_PROFILE_RECORD, &kv) < 0)
	{
		printf("%s\tDRIVER-ERROR:policy_build\n", tag);
		goto out;
	}
	printf("%s\t", tag);
	for (i = 0; i < kv.count; i++)
	{
		put_escaped(kv.items[i].key);
		putchar('=');
		put_escaped(kv.items[i].value);
		putchar(';');
	}
	putchar('\n');
out:
	streaminput_kv_free(&kv);
	streaminput_source_free(&s);
}

static void redact_n(const char *tag, const char *url, size_t outlen)
{
	char out[64];

	streaminput_redact_url(url, out, outlen);
	printf("%s\t%s\n", tag, out);
}

static void redact(const char *tag, const char *url)
{
	redact_n(tag, url, 64);
}

int main(void)
{
	/* policy: the historic block, case by case */
	policy("https-nohdr", "https://a.test/x.m3u8", "");
	policy("https-hdr", "https://a.test/x.m3u8", "X-A: 1\r\n");
	policy("http-nohdr", "http://a.test/x.ts", "");
	policy("rtsp-nohdr", "rtsp://a.test/s", "");
	policy("rtsp-hdr", "rtsp://a.test/s", "X-A: 1\r\n");
	policy("file-nohdr", "/tmp/local.ts", "");
	policy("upper-scheme", "HTTP://UPPER.test/x", "");
	policy("empty-url", "", "");
	/* a profile the builder does not know: reported, list untouched */
	{
		stream_source_t s;
		stream_kv_list_t kv;

		streaminput_source_init(&s);
		streaminput_kv_init(&kv);
		if (streaminput_source_set_url(&s, "https://a.test/x") < 0)
			printf("bad-profile\tDRIVER-ERROR:set_url\n");
		else
		{
			/* sequenced before the printf: C leaves the argument
			 * evaluation order open, and kv.count read early would
			 * mask a builder that touched the list */
			int rc = streaminput_policy_build(&s, (stream_input_profile_t)999, &kv);
			printf("bad-profile\trc=%d count=%d\n", rc, (int)kv.count);
		}
		streaminput_kv_free(&kv);
		streaminput_source_free(&s);
	}
	/* redaction */
	redact("redact-query", "https://a.test/master.m3u8?token=secret&sig=abc");
	redact("redact-none", "https://a.test/master.m3u8");
	redact("redact-bare-q", "https://a.test/master.m3u8?");
	/* redaction under truncation: the marker survives complete (24),
	 * alone at the exact boundary sizeof("?<redacted>") (12), and below
	 * that only bare path bytes are left (8) */
	redact_n("redact-trunc24", "https://a.test/very/long/path.m3u8?token=secret", 24);
	redact_n("redact-trunc12", "https://a.test/very/long/path.m3u8?token=secret", 12);
	redact_n("redact-trunc8", "https://a.test/very/long/path.m3u8?token=secret", 8);
	/* protocol detection */
	printf("protocols\t%d %d %d %d %d\n",
		(int)streaminput_detect_protocol("https://a/x.m3u8"),
		(int)streaminput_detect_protocol("https://a/x.ts"),
		(int)streaminput_detect_protocol("https://a/x.mpd"),
		(int)streaminput_detect_protocol("rtsp://a/s"),
		(int)streaminput_detect_protocol("/tmp/x.ts"));
	/* a media fragment does not hide the playlist suffix */
	printf("protocol-fragment\t%d\n",
		(int)streaminput_detect_protocol("https://a/x.m3u8#t=30"));
	/* failure classification of the codes the app path maps today */
	printf("classes\t%s %s %s %s %s %s\n",
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_CONNECTION_RESET, 0)),
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_INVALID_DATA, 0)),
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_HTTP_SERVER_ERROR, 0)),
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_EXIT_REQUESTED, 0)),
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_NONE, 503)),
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_NONE, 404)));
	/* Every failure class must be reachable from some error code: a class
	 * nothing can produce is dead vocabulary, and connection-failed (a
	 * refused or unreachable endpoint) is the most common real one. */
	printf("conn-failed\t%s\n",
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_CONNECTION_FAILED, 0)));
	printf("unsup-proto\t%s\n",
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_PROTOCOL_NOT_FOUND, 0)));
	/* terminal local outcomes are not relabelled by a stale HTTP status */
	printf("classes-precedence\t%s %s\n",
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_EXIT_REQUESTED, 404)),
		streaminput_failure_class_name(streaminput_classify(STREAM_ERR_EOF, 503)));
	return 0;
}
EOF

# Unquoted on purpose: CC may be "ccache gcc".
if ! $CC -std=c99 -Wall -Wextra -Werror -I "$INC" \
	"$WORK/driver.c" "$SRC" -o "$WORK/driver" 2> "$WORK/cc.err"; then
	no "the module compiles warning-free as C99" "$(head -5 "$WORK/cc.err")"
	printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
	exit 1
fi
ok "the module compiles warning-free as C99"

"$WORK/driver" > "$WORK/out" 2>&1 || {
	no "the driver runs" "$(head -3 "$WORK/out")"
	printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
	exit 1
}

# Look the case up by its tag, so an added or reordered case cannot silently
# shift another assertion onto the wrong output.
check()
{
	# plain POSIX grep: -m1 is a GNUism (and this host grep is a
	# ugrep wrapper); tags are unique, so it bought nothing, and a
	# failing grep may speak to stderr instead of being silenced
	line="$(grep "^$1	" "$WORK/out")"
	if [ -z "$line" ]; then
		no "$3" "no output line tagged '$1'"
		return
	fi
	got="${line#*	}"
	# if/else, not && ||: a printf failing on a short pipe must not turn
	# a passing case into a counted failure as well.
	if [ "$got" = "$2" ]; then
		ok "$3"
	else
		no "$3" "expected [$2], got [$got]"
	fi
}

# Policy: an https URL without headers gets exactly the two network options.
check https-nohdr 'timeout=20000000;reconnect=1;' \
	"https without headers: timeout + reconnect only"
# With headers, the resolver blob comes first and is passed through verbatim.
check https-hdr 'headers=X-A: 1\r\n;timeout=20000000;reconnect=1;' \
	"resolver headers are passed through verbatim, before the network options"
# A plain http URL is treated the same as https.
check http-nohdr 'timeout=20000000;reconnect=1;' \
	"http is treated like https"
# Non-http protocols get no network options at all.
check rtsp-nohdr '' "rtsp without headers: no options"
check rtsp-hdr 'headers=X-A: 1\r\n;' "rtsp with headers: headers only, no network options"
check file-nohdr '' "local path: no options"
# The scheme test is case sensitive, exactly like the block it replaced
# (and like FFmpeg itself) -- an uppercase scheme must NOT match.
check upper-scheme '' "uppercase scheme is not matched (as before)"
check empty-url '' "empty URL: no options"
# An unknown profile is reported, and the option list stays untouched.
check bad-profile 'rc=-1 count=0' \
	"an unknown profile fails without touching the option list"

# Redaction hides the query string but keeps the path.
check redact-query 'https://a.test/master.m3u8?<redacted>' \
	"a query string is redacted, the path stays"
check redact-none 'https://a.test/master.m3u8' \
	"a URL without a query is left alone"
check redact-bare-q 'https://a.test/master.m3u8?' \
	"a bare trailing ? is not reported as redacted"
# Under truncation the path gives way, never the marker: a torn "?<red"
# tells the reader nothing, and a cut on the '?' would mimic a clean URL.
check redact-trunc24 'https://a.te?<redacted>' \
	"truncation shortens the path and keeps the marker complete"
check redact-trunc12 '?<redacted>' \
	"at the exact marker boundary the marker alone survives"
check redact-trunc8 'https:/' \
	"below the marker boundary only bare path bytes are emitted"

# Protocol detection: HLS, HTTP, DASH, RTSP, FILE in enum order 2,1,3,4,5.
check protocols '2 1 3 4 5' "protocol detection covers hls/http/dash/rtsp/file"
check protocol-fragment '2' \
	"a media fragment (#t=30) does not hide the .m3u8 suffix"

# Failure classes for the codes the WebTV path classifies today.
check classes 'temporary-network invalid-manifest http-5xx aborted http-5xx http-4xx' \
	"transport errors and HTTP status map to the documented classes"
check conn-failed 'connection-failed' \
	"a refused or unreachable endpoint is its own class, not 'unknown'"
check unsup-proto 'unsupported-protocol' \
	"a missing protocol handler is its own class, not 'unknown'"
check classes-precedence 'aborted end-of-stream' \
	"a user abort and an orderly EOF beat a stale HTTP status"

# --- the FFmpeg bridge header -----------------------------------------------
# streaminput_ffmpeg.h is where both earlier review rounds found defects. Its
# entry points are what production actually calls, so they are EXECUTED here
# through a recording av_dict_set() mock (see the driver below) -- once built
# as C and once as C++, each linked against the module object and run. The
# C++ run is the extern "C" proof. Skipped, loudly, when no libav headers are
# around (CI runs the shell suite without building FFmpeg).
#
# Version contract note: this gate compiles against whichever libav header
# tree it finds first. The candidates track the build system instead of
# hardcoding one layout: the exported install dir when the make
# environment provides it, the default sysroot, then any unpacked FFmpeg
# source tree (globbed, so a PREFERRED_FFMPEG_VERSION bump cannot silently
# disarm this gate). The 4.4-7.0 contract (WORK-231/D8) was proven
# manually against 4.4.1, 5.1.4, 6.1.1 and 7.0 trees and is NOT re-proven
# by this file.
# error.h alone does not make a usable include tree: libavutil/macros.h
# unconditionally includes the GENERATED libavutil/avconfig.h, which an
# unpacked-but-unbuilt source tree only has under build/. Accepting such
# a tree would compile only where a system libavutil dev package papers
# over the gap -- and hard-fail everywhere else, blaming the module for
# a missing prerequisite.
AVINC=""
AVINC2=""
for d in ${NEUTRINO_INSTALL_DIR:+"$NEUTRINO_INSTALL_DIR${NEUTRINO_PREFIX:-/usr}/include"} \
	"$ROOT_DIR/artifacts/sysroot/usr/include" "$ROOT_DIR"/sources/ffmpeg-*; do
	[ -f "$d/libavutil/error.h" ] || continue
	if [ -f "$d/libavutil/avconfig.h" ]; then
		AVINC="$d"
		break
	fi
	if [ -f "$d/build/libavutil/avconfig.h" ]; then
		AVINC="$d"
		AVINC2="$d/build"
		break
	fi
done
if [ -z "$AVINC" ]; then
	skipped "no libav headers found; streaminput_ffmpeg.h not exercised"
else
	cat > "$WORK/bridge_driver.c" <<'EOF'
#include <stdio.h>
#include <streaminput_ffmpeg.h>

/* The bridge's entry points are static inline and their only libav
 * reference is av_dict_set(), so no libavutil is linked: AVDictionary
 * is opaque to callers, which lets this driver define it and supply a
 * recording mock. Every call is logged in order as "key=value@flags;"
 * (CR/LF escaped) -- the exact stream FFmpeg would receive. When
 * armed, the g_fail_at-th call fails with AVERROR(ENOMEM) to pin the
 * header's promise that the first error is passed through. */
/* No extern "C" needed on a type definition; linkage only matters for
 * av_dict_set below. */
struct AVDictionary
{
	int unused;
};

static struct AVDictionary dummy;
static char g_log[512];
static size_t g_len;
static int g_calls;
static int g_fail_at; /* 0 = never fail */

static void log_ch(char c)
{
	if (g_len + 1 < sizeof(g_log))
	{
		g_log[g_len++] = c;
		g_log[g_len] = '\0';
	}
}

static void log_str(const char *s)
{
	for (; *s; s++)
	{
		if (*s == '\r')
		{
			log_ch('\\');
			log_ch('r');
		}
		else if (*s == '\n')
		{
			log_ch('\\');
			log_ch('n');
		}
		else
			log_ch(*s);
	}
}

#ifdef __cplusplus
extern "C"
#endif
int av_dict_set(AVDictionary **pm, const char *key, const char *value, int flags)
{
	char fbuf[16];

	g_calls++;
	if (g_fail_at && g_calls == g_fail_at)
		return AVERROR(ENOMEM);
	*pm = &dummy;
	log_str(key);
	log_ch('=');
	log_str(value);
	snprintf(fbuf, sizeof(fbuf), "@%d;", flags);
	log_str(fbuf);
	return 0;
}

static const char *rc_name(int rc)
{
	if (rc == 0)
		return "0";
	if (rc == AVERROR(ENOMEM))
		return "ENOMEM";
	return "other";
}

static void apply(const char *prefix, const char *tag, const char *url,
	const char *headers, int fail_at)
{
	AVDictionary *dict = NULL;
	int rc;

	g_log[0] = '\0';
	g_len = 0;
	g_calls = 0;
	g_fail_at = fail_at;
	rc = streaminput_apply_policy(url, headers, STREAM_PROFILE_RECORD, &dict);
	printf("%s-%s\trc=%s %s\n", prefix, tag, rc_name(rc), g_log);
}

int main(int argc, char **argv)
{
	const char *prefix = argc > 1 ? argv[1] : "x";

	apply(prefix, "avdict-https-hdr", "https://a.test/x.m3u8", "X-A: 1\r\n", 0);
	apply(prefix, "avdict-https-nohdr", "https://a.test/x.m3u8", "", 0);
	apply(prefix, "avdict-rtsp-hdr", "rtsp://a.test/s", "X-A: 1\r\n", 0);
	apply(prefix, "avdict-null-hdr", "https://a.test/x.ts", NULL, 0);
	/* the second av_dict_set() fails: the error must come back
	 * verbatim, and the remaining entries must still be attempted --
	 * the historic block's calls were independent of each other */
	apply(prefix, "avdict-enomem", "https://a.test/x.m3u8", "X-A: 1\r\n", 2);
	/* the AVERROR translation itself, over the codes the app maps */
	printf("%s-averror-classes\t%s %s %s %s %s %s %s\n", prefix,
		streaminput_failure_class_name(streaminput_classify_averror(AVERROR(ECONNREFUSED))),
		streaminput_failure_class_name(streaminput_classify_averror(AVERROR(ETIMEDOUT))),
		streaminput_failure_class_name(streaminput_classify_averror(AVERROR_HTTP_NOT_FOUND)),
		streaminput_failure_class_name(streaminput_classify_averror(AVERROR_EXIT)),
		streaminput_failure_class_name(streaminput_classify_averror(AVERROR_EOF)),
		streaminput_failure_class_name(streaminput_classify_averror(AVERROR_INVALIDDATA)),
		streaminput_failure_class_name(streaminput_classify_averror(AVERROR_PROTOCOL_NOT_FOUND)));
	printf("%s-averror-name\t%s\n", prefix,
		streaminput_error_code_name(streaminput_error_from_averror(AVERROR(ECONNRESET))));
	return 0;
}
EOF
	cp "$WORK/bridge_driver.c" "$WORK/bridge_driver.cpp"

	# The C++ leg needs the matching driver. toolchain.mk exports CXX with
	# the same quirks as CC, so it goes through the same helpers. Unlike a
	# missing C compiler -- without which nothing in this file runs -- a
	# missing C++ compiler skips only this one leg, loudly, so the gap
	# stays visible.
	CXX="$(normalize_compiler "${CXX:-c++}")"
	[ -n "$CXX" ] || CXX=c++
	CXX_PROBE="$(probe_target "$CXX")"

	BRIDGE_LANGS=""
	if ! $CC -std=c99 -Wall -Wextra -Werror -I "$INC" \
		-c "$SRC" -o "$WORK/streaminput.o" 2> "$WORK/mod.err"; then
		no "the module compiles as an object for the bridge drivers" \
			"$(head -3 "$WORK/mod.err")"
	else
		# Unquoted CC/CXX on purpose (see above). Compile and run are
		# separate steps so a runtime crash reports the driver's own
		# output, not an empty compiler stderr. The C++ leg uses the
		# same dialect as the production callers (gnu++17,
		# make/toolchain.mk CXXFLAGS) -- proving the contract under a
		# dialect no consumer uses would prove the wrong thing.
		if ! $CC -std=c99 -Wall -Wextra -Werror -I "$INC" -isystem "$AVINC" \
			"$WORK/bridge_driver.c" "$WORK/streaminput.o" ${AVINC2:+-isystem "$AVINC2"} -o "$WORK/bridge_c" \
			2> "$WORK/brc.err"; then
			no "bridge driver builds and links as c" "$(head -3 "$WORK/brc.err")"
		elif ! "$WORK/bridge_c" c > "$WORK/out.bc" 2>&1; then
			no "bridge driver runs as c" "$(head -3 "$WORK/out.bc")"
		else
			cat "$WORK/out.bc" >> "$WORK/out"
			ok "bridge driver builds, links and runs as c"
			BRIDGE_LANGS="$BRIDGE_LANGS c"
		fi
		if ! command -v "$CXX_PROBE" >/dev/null 2>&1; then
			skipped "no C++ compiler ($CXX_PROBE); the extern \"C\" link proof did not run"
		elif ! $CXX -std=gnu++17 -Wall -Wextra -Werror -I "$INC" -isystem "$AVINC" \
			"$WORK/bridge_driver.cpp" "$WORK/streaminput.o" ${AVINC2:+-isystem "$AVINC2"} -o "$WORK/bridge_cxx" \
			2> "$WORK/brx.err"; then
			no "bridge driver builds and links as c++ (extern \"C\" contract)" \
				"$(head -3 "$WORK/brx.err")"
		elif ! "$WORK/bridge_cxx" cxx > "$WORK/out.bx" 2>&1; then
			no "bridge driver runs as c++" "$(head -3 "$WORK/out.bx")"
		else
			cat "$WORK/out.bx" >> "$WORK/out"
			ok "bridge driver builds, links and runs as c++ (extern \"C\" contract)"
			BRIDGE_LANGS="$BRIDGE_LANGS cxx"
		fi
	fi

	for lang in $BRIDGE_LANGS; do
		check "$lang-avdict-https-hdr" 'rc=0 headers=X-A: 1\r\n@0;timeout=20000000@0;reconnect=1@0;' \
			"apply_policy ($lang): headers then network options, each with flag 0"
		check "$lang-avdict-https-nohdr" 'rc=0 timeout=20000000@0;reconnect=1@0;' \
			"apply_policy ($lang): empty headers are dropped, not passed as \"\""
		check "$lang-avdict-rtsp-hdr" 'rc=0 headers=X-A: 1\r\n@0;' \
			"apply_policy ($lang): non-http input gets headers only"
		check "$lang-avdict-null-hdr" 'rc=0 timeout=20000000@0;reconnect=1@0;' \
			"apply_policy ($lang): NULL headers behave like empty"
		check "$lang-avdict-enomem" 'rc=ENOMEM headers=X-A: 1\r\n@0;reconnect=1@0;' \
			"apply_policy ($lang): the first av_dict_set error is passed through, the rest still attempted"
		check "$lang-averror-classes" 'connection-failed connection-timeout http-4xx aborted end-of-stream invalid-manifest unsupported-protocol' \
			"averror translation ($lang): real AVERROR constants land in the documented classes"
		check "$lang-averror-name" 'connection-reset' \
			"averror translation ($lang): error_from_averror feeds the stable code names"
	done
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
exit 0
