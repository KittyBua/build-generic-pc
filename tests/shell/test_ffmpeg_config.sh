#!/bin/sh
#
# Unit test for the ffmpeg configure contract in make/third_party/ffmpeg.mk:
#   * the configure stamp records the invocation it was made with; a changed
#     line reconfigures, an unchanged one leaves the stamp alone, and the
#     decision rests on content, not on timestamps;
#   * the record survives shell-sensitive flags (`$ORIGIN`, quotes) verbatim;
#   * a stamp from before the record (empty) is reconfigured once;
#   * the compiler and the exported flags are part of the record, so are
#     re-unpacked sources, and a changed invocation starts the build
#     directory over while a stamp from before the record keeps its objects;
#   * a tree without a stamp is in an unknown state and is started over;
#   * a sub-make (bootstrap, the variants) sees the same invocation as the
#     top level, so the two entry points do not rebuild from each other;
#   * two passes at once (make all) leave a matched tree alone;
#   * a dry run writes nothing, warm or cold, and neither does `make -q`;
#   * FFMPEG_CONFIGURE_FLAGS is appended after the built-in line, so a flag
#     given there has the last word in ffmpeg's configure -- from the command
#     line, from Makefile.local and from Makefile.local.post alike.
#
# The first of these had been broken for as long as the module existed: a flag
# edit was ignored by every tree that had already been configured, and nothing
# said so. Like test_make_config.sh, the test never touches the repository's
# own trees: it copies the makefiles into a scratch tree with a stand-in ffmpeg
# source whose configure only records its arguments.
#
# POSIX sh. Exits 0 on success, 1 on any failure.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf 'FAIL %s\n' "$1"; printf '     %s\n' "$2"; fail=$((fail + 1)); }

cp "$ROOT_DIR/Makefile" "$WORK/" || { echo "FAIL cannot copy Makefile"; exit 1; }
cp -r "$ROOT_DIR/make" "$WORK/" || { echo "FAIL cannot copy make/"; exit 1; }

# The version the module builds by default; the stand-in tree carries its name.
VERSION="$(sed -n 's/^PREFERRED_FFMPEG_VERSION ?= //p' "$WORK/make/third_party/ffmpeg.mk")"
[ -n "$VERSION" ] || { echo "FAIL cannot read PREFERRED_FFMPEG_VERSION"; exit 1; }
SRC="$WORK/sources/ffmpeg-$VERSION"
BUILD="$SRC/build"
STAMP="$BUILD/.configured"
ARGV="$BUILD/configure.argv"

# A stand-in source tree. Archive and unpack stamp exist and are old, so the
# module neither downloads nor unpacks anything, and configure only writes its
# arguments, one per line, into the build directory it is run from.
mkdir -p "$SRC" "$WORK/archive"
: > "$WORK/archive/ffmpeg-$VERSION.tar.gz"
touch -d '2001-01-01 00:00:00' "$WORK/archive/ffmpeg-$VERSION.tar.gz"
cat > "$SRC/configure" <<'CONFIGURE'
#!/bin/sh
printf '%s\n' "$@" > configure.argv
CONFIGURE
chmod +x "$SRC/configure"
: > "$SRC/.unpacked"
touch -d '2001-01-02 00:00:00' "$SRC/.unpacked"

# See test_make_config.sh: the suite exports every project variable into this
# process, and those would leak into the nested make. TOOLCHAIN_GCC_VERSION is
# pinned to system so the gcc guard in the configure recipe stays out of the
# way; nothing here compiles.
run_make() {
	env -i PATH="$PATH" HOME="${HOME:-/tmp}" LC_ALL=C \
		make -C "$WORK" TOOLCHAIN_GCC_VERSION=system "$@"
}

TAB="$(printf '\t')"
configured() { [ -f "$ARGV" ] && echo yes || echo no; }
# The scratch copies of the record are named per make process.
scratch_left() { ls "$SRC"/.configured.new.* 2>/dev/null; }
last_arg() { tail -n 1 "$ARGV" 2>/dev/null; }
# The stamp's identity. A reconfigure replaces it (mv of a file created while
# the old one still existed, so a different inode); an absent stamp has none,
# which is what keeps the "nothing happened" cases from passing vacuously.
stamp_id() { [ -f "$STAMP" ] && ls -i "$STAMP" | awk '{print $1}'; }
# The downstream stamps: a matching invocation must leave them alone, a
# changed one must remove them.
plant_canaries() { : > "$BUILD/.built"; : > "$BUILD/.installed"; }
canaries_present() { [ -f "$BUILD/.built" ] && [ -f "$BUILD/.installed" ]; }
canaries_gone() { [ ! -e "$BUILD/.built" ] && [ ! -e "$BUILD/.installed" ]; }

# --- fresh tree: configured once, the invocation recorded -------------------
out="$(run_make "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$STAMP" ] && [ "$(configured)" = yes ]; then
	ok "a fresh tree is configured"
else
	ko "a fresh tree is configured" "rc=$rc; $out"
fi
if grep -q -- '--enable-pic' "$STAMP" 2>/dev/null; then
	ok "the stamp records the configure line"
else
	ko "the stamp records the configure line" "$(cat "$STAMP" 2>/dev/null)"
fi
if grep -q 'CC="' "$STAMP" 2>/dev/null; then
	ok "the record includes the compiler"
else
	ko "the record includes the compiler" "$(cat "$STAMP" 2>/dev/null)"
fi
if grep -qx -- '--enable-shared' "$ARGV" 2>/dev/null; then
	ok "configure receives the built-in line"
else
	ko "configure receives the built-in line" "argv: $(tr '\n' ' ' < "$ARGV" 2>/dev/null)"
fi

# --- unchanged line: nothing happens ----------------------------------------
# Identity and mtime both: a `touch` of the matched stamp would keep the
# inode and still send .built, .installed and every consumer downstream into
# a rebuild on each pass.
before="$(stamp_id)"
plant_canaries
touch -d '2010-01-01 00:00:00' "$STAMP"
: > "$WORK/ref"
touch -d '2011-01-01 00:00:00' "$WORK/ref"
rm -f "$ARGV"
out="$(run_make "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = no ] && [ -n "$before" ] && [ "$(stamp_id)" = "$before" ] && [ -z "$(find "$STAMP" -newer "$WORK/ref")" ] && canaries_present; then
	ok "an unchanged line leaves the stamps alone"
else
	ko "an unchanged line leaves the stamps alone" "rc=$rc configured=$(configured) stamp $before -> $(stamp_id) touched=$([ -n "$(find "$STAMP" -newer "$WORK/ref")" ] && echo yes || echo no); $out"
fi
if [ -z "$(scratch_left)" ]; then
	ok "no scratch record is left behind"
else
	ko "no scratch record is left behind" "$(scratch_left)"
fi

# --- changed line on the command line: reconfigured, user flags last --------
rm -f "$ARGV"
plant_canaries
out="$(run_make "$STAMP" FFMPEG_CONFIGURE_FLAGS=--enable-gpl 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ] && canaries_gone; then
	ok "a changed line reconfigures and drops the downstream stamps"
else
	ko "a changed line reconfigures and drops the downstream stamps" "rc=$rc configured=$(configured) built=$([ -e "$BUILD/.built" ] && echo kept || echo gone); $out"
fi
if [ "$(last_arg)" = "--enable-gpl" ]; then
	ok "FFMPEG_CONFIGURE_FLAGS comes after the built-in line"
else
	ko "FFMPEG_CONFIGURE_FLAGS comes after the built-in line" "last argument: '$(last_arg)'"
fi
if grep -q -- ' --enable-gpl' "$STAMP" 2>/dev/null; then
	ok "the record follows the line that was configured"
else
	ko "the record follows the line that was configured" "$(cat "$STAMP" 2>/dev/null)"
fi

# --- Makefile.local.post: read after the module, must still reach the line --
# This is what keeps FFMPEG_CONFIGURE_ARGS a recursive variable; with `:=` the
# override below would be dropped without a word.
rm -f "$ARGV"
printf 'FFMPEG_CONFIGURE_FLAGS := --enable-version3\n' > "$WORK/Makefile.local.post"
out="$(run_make "$STAMP" 2>&1)"
rc=$?
rm -f "$WORK/Makefile.local.post"
if [ "$rc" -eq 0 ] && [ "$(last_arg)" = "--enable-version3" ]; then
	ok "an override from Makefile.local.post reaches the configure line"
else
	ko "an override from Makefile.local.post reaches the configure line" "rc=$rc last argument: '$(last_arg)'; $out"
fi

# --- a shell-sensitive flag: recorded verbatim, so no spurious reconfigure --
# `$$ORIGIN` reaches configure as the literal $ORIGIN inside the user's own
# quotes. Echoing the line through a second shell would expand it to nothing
# and record a line that never matches.
rm -f "$ARGV"
printf "FFMPEG_CONFIGURE_FLAGS := --extra-ldflags='-Wl,-rpath,\$\$ORIGIN/lib'\n" > "$WORK/Makefile.local"
out="$(run_make "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(last_arg)" = '--extra-ldflags=-Wl,-rpath,$ORIGIN/lib' ]; then
	ok "a quoted \$ORIGIN reaches configure intact"
else
	ko "a quoted \$ORIGIN reaches configure intact" "rc=$rc last argument: '$(last_arg)'; $out"
fi
if grep -qF -- "'-Wl,-rpath,\$ORIGIN/lib'" "$STAMP" 2>/dev/null; then
	ok "the record keeps the flag verbatim"
else
	ko "the record keeps the flag verbatim" "$(cat "$STAMP" 2>/dev/null)"
fi
before="$(stamp_id)"
rm -f "$ARGV"
out="$(run_make "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = no ] && [ -n "$before" ] && [ "$(stamp_id)" = "$before" ]; then
	ok "the same shell-sensitive flag does not reconfigure again"
else
	ko "the same shell-sensitive flag does not reconfigure again" "rc=$rc configured=$(configured) stamp $before -> $(stamp_id); $out"
fi
rm -f "$ARGV"
printf "FFMPEG_CONFIGURE_FLAGS := --extra-ldflags='-Wl,-rpath,\$\$ORIGIN/lib64'\n" > "$WORK/Makefile.local"
out="$(run_make "$STAMP" 2>&1)"
rc=$?
rm -f "$WORK/Makefile.local"
if [ "$rc" -eq 0 ] && [ "$(last_arg)" = '--extra-ldflags=-Wl,-rpath,$ORIGIN/lib64' ]; then
	ok "a change inside the quoted flag is still seen"
else
	ko "a change inside the quoted flag is still seen" "rc=$rc last argument: '$(last_arg)'; $out"
fi

# --- timestamps play no part in the decision -------------------------------
# A stamp from the future would defeat any mtime comparison; the content
# comparison reconfigures regardless. Sources unpacked after the stamp, on the
# other hand, reconfigure even with an unchanged line.
rm -f "$ARGV"
touch -d '2038-01-01 00:00:00' "$STAMP"
out="$(run_make "$STAMP" FFMPEG_CONFIGURE_FLAGS=--enable-gpl 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ]; then
	ok "a changed line reconfigures even against a newer stamp"
else
	ko "a changed line reconfigures even against a newer stamp" "rc=$rc configured=$(configured); $out"
fi
rm -f "$ARGV"
touch -d '2038-01-02 00:00:00' "$SRC/.unpacked"
out="$(run_make "$STAMP" FFMPEG_CONFIGURE_FLAGS=--enable-gpl 2>&1)"
rc=$?
touch -d '2001-01-02 00:00:00' "$SRC/.unpacked"
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ]; then
	ok "re-unpacked sources reconfigure with an unchanged line"
else
	ko "re-unpacked sources reconfigure with an unchanged line" "rc=$rc configured=$(configured); $out"
fi

# --- the compiler and the exported flags are part of the record -------------
# ffmpeg's configure reads CFLAGS & co. from the environment (they end up in
# ffbuild/config.mak), so a DEBUG_BUILD or sanitizer variant is a different
# invocation. And a different invocation starts the build directory over:
# ffmpeg's own dependency tracking would not rebuild an object for a changed
# compiler, so a leftover from the old invocation must not survive.
rm -f "$ARGV"
mkdir -p "$BUILD/libavformat"
: > "$BUILD/libavformat/http.o"
out="$(run_make "$STAMP" FFMPEG_CONFIGURE_FLAGS=--enable-gpl CC=cc-other 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ] && grep -q 'cc-other' "$STAMP" 2>/dev/null; then
	ok "a different compiler reconfigures"
else
	ko "a different compiler reconfigures" "rc=$rc configured=$(configured); $(cat "$STAMP" 2>/dev/null); $out"
fi
if [ ! -e "$BUILD/libavformat/http.o" ] && [ -s "$STAMP" ]; then
	ok "a changed invocation starts the build directory over"
else
	ko "a changed invocation starts the build directory over" "old object kept: $(ls "$BUILD/libavformat" 2>/dev/null)"
fi
rm -f "$ARGV"
out="$(run_make "$STAMP" FFMPEG_CONFIGURE_FLAGS=--enable-gpl CC=cc-other CFLAGS=-Oprobe 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ] && grep -q 'CFLAGS="-Oprobe"' "$STAMP" 2>/dev/null; then
	ok "changed CFLAGS alone reconfigure"
else
	ko "changed CFLAGS alone reconfigure" "rc=$rc configured=$(configured); $(cat "$STAMP" 2>/dev/null); $out"
fi
rm -f "$ARGV"
out="$(run_make "$STAMP" FFMPEG_CONFIGURE_FLAGS=--enable-gpl CC=cc-other CFLAGS=-Oprobe LDFLAGS=-Wl,-Oprobe 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ] && grep -q 'LDFLAGS="-Wl,-Oprobe"' "$STAMP" 2>/dev/null; then
	ok "changed LDFLAGS alone reconfigure"
else
	ko "changed LDFLAGS alone reconfigure" "rc=$rc configured=$(configured); $(cat "$STAMP" 2>/dev/null); $out"
fi
rm -f "$ARGV"
out="$(run_make "$STAMP" FFMPEG_CONFIGURE_FLAGS=--enable-gpl CC=cc-other DEBUG_BUILD=1 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ] && grep -q -- '-O0' "$STAMP" 2>/dev/null; then
	ok "a debug variant's flags reconfigure"
else
	ko "a debug variant's flags reconfigure" "rc=$rc configured=$(configured); $(cat "$STAMP" 2>/dev/null); $out"
fi

# --- a stamp from before the record: reconfigured once, objects kept --------
# It says nothing about the old invocation, so there is no ground to throw
# the objects away; a changed config.h is ffmpeg's own business.
rm -f "$ARGV"
: > "$STAMP"
mkdir -p "$BUILD/libavformat"
: > "$BUILD/libavformat/http.o"
plant_canaries
out="$(run_make "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ] && [ -s "$STAMP" ] && [ -e "$BUILD/libavformat/http.o" ] && canaries_gone; then
	ok "an empty stamp from before the record is reconfigured once, objects kept, downstream stamps dropped"
else
	ko "an empty stamp from before the record is reconfigured once, objects kept, downstream stamps dropped" "rc=$rc configured=$(configured) object=$([ -e "$BUILD/libavformat/http.o" ] && echo kept || echo gone) built=$([ -e "$BUILD/.built" ] && echo kept || echo gone); $out"
fi
before="$(stamp_id)"
rm -f "$ARGV"
out="$(run_make "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = no ] && [ -n "$before" ] && [ "$(stamp_id)" = "$before" ]; then
	ok "and only once"
else
	ko "and only once" "rc=$rc configured=$(configured) stamp $before -> $(stamp_id); $out"
fi

# --- a tree without a stamp is in an unknown state: started over -----------
# A wipe that did not finish looks exactly like this, and must not be taken
# for a tree from before the record.
rm -f "$ARGV" "$STAMP"
mkdir -p "$BUILD/libavformat"
: > "$BUILD/libavformat/http.o"
out="$(run_make "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(configured)" = yes ] && [ ! -e "$BUILD/libavformat/http.o" ]; then
	ok "a tree without a stamp is started over"
else
	ko "a tree without a stamp is started over" "rc=$rc configured=$(configured) object=$([ -e "$BUILD/libavformat/http.o" ] && echo kept || echo gone); $out"
fi

# --- a sub-make sees the same invocation as the top level -------------------
# bootstrap, the debug and sanitizer variants and deps-ffmpeg-<ver> reach the
# stamp through $(MAKE). The exported search paths and flags used to be
# prepended once per make level, so a level-1 record differed from a level-0
# one and the two entry points wiped the build directory from each other.
cat > "$WORK/submake.mk" <<PROBE
include make/main.mk
w231-submake:
${TAB}@\$(MAKE) $STAMP
PROBE
before="$(stamp_id)"
rm -f "$ARGV"
mkdir -p "$BUILD/libavformat"
: > "$BUILD/libavformat/http.o"
out="$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" LC_ALL=C \
	make -C "$WORK" -f submake.mk TOOLCHAIN_GCC_VERSION=system w231-submake 2>&1)"
rc=$?
rm -f "$WORK/submake.mk"
if [ "$rc" -eq 0 ] && [ "$(configured)" = no ] && [ -n "$before" ] && [ "$(stamp_id)" = "$before" ] && [ -e "$BUILD/libavformat/http.o" ]; then
	ok "a sub-make sees the same invocation and leaves the tree alone"
else
	ko "a sub-make sees the same invocation and leaves the tree alone" "rc=$rc configured=$(configured) stamp $before -> $(stamp_id) object=$([ -e "$BUILD/libavformat/http.o" ] && echo kept || echo gone); $out"
fi

# --- two passes at once leave a matched tree alone ---------------------------
# `make all` reaches the stamp from two makes at the same time (deps runs
# runtime-sync in a sub-make while neutrino is built alongside). With one
# shared scratch file, the first pass removed the copy the second was about
# to compare, and the second wiped a good build directory.
before="$(stamp_id)"
mkdir -p "$BUILD/libavformat"
: > "$BUILD/libavformat/http.o"
pair_ok=yes
for round in 1 2 3; do
	rm -f "$ARGV"
	run_make "$STAMP" >/dev/null 2>&1 &
	p1=$!
	run_make "$STAMP" >/dev/null 2>&1 &
	p2=$!
	wait "$p1" || pair_ok=no
	wait "$p2" || pair_ok=no
	[ "$(configured)" = no ] || pair_ok=no
done
if [ "$pair_ok" = yes ] && [ -n "$before" ] && [ "$(stamp_id)" = "$before" ] && [ -e "$BUILD/libavformat/http.o" ] && [ -z "$(scratch_left)" ]; then
	ok "two passes at once leave a matched tree alone"
else
	ko "two passes at once leave a matched tree alone" "pairs=$pair_ok configured=$(configured) stamp $before -> $(stamp_id) object=$([ -e "$BUILD/libavformat/http.o" ] && echo kept || echo gone) scratch='$(scratch_left)'"
fi

# --- a dry run changes nothing ----------------------------------------------
# $(file) runs at recipe expansion, which `make -n` and `make -q` perform as
# well; the guard keeps the record from being written, warm and cold alike.
rm -f "$ARGV"; rm -f "$SRC"/.configured.new.*
out="$(run_make -n "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(scratch_left)" ] && [ "$(configured)" = no ]; then
	ok "a dry run on a configured tree writes nothing"
else
	ko "a dry run on a configured tree writes nothing" "rc=$rc scratch='$(scratch_left)' configured=$(configured); $out"
fi
run_make -q "$STAMP" >/dev/null 2>&1
if [ -z "$(scratch_left)" ] && [ "$(configured)" = no ]; then
	ok "a question run writes nothing either"
else
	ko "a question run writes nothing either" "scratch='$(scratch_left)' configured=$(configured)"
fi
rm -rf "$BUILD"
out="$(run_make -n "$STAMP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$BUILD" ] && [ -z "$(scratch_left)" ]; then
	ok "a dry run on a cold tree neither fails nor creates anything"
else
	ko "a dry run on a cold tree neither fails nor creates anything" "rc=$rc build dir=$([ -e "$BUILD" ] && echo created || echo absent) scratch='$(scratch_left)'; $out"
fi

printf '[test-ffmpeg-config] pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
