#!/bin/sh
#
# Unit test for the make configuration contract:
#   * an explicit default goal, so a bare `make` is not a silent no-op;
#   * Makefile.local read once and early, so overrides actually take effect;
#   * the exported plugin install dirs matching Neutrino's layout;
#   * every annotated target discoverable via help-targets.
#
# All of these regressed silently before and would again unnoticed. The test
# never touches the repository's own Makefile.local: it copies the makefiles
# into a scratch tree and drives them there with synthetic overrides, reading
# fully expanded values through a throwaway probe target.
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

# The suite runs this test from inside make, which exports every project
# variable (.EXPORT_ALL_VARIABLES). Those would leak into the nested make
# below: an exported CC has origin 'environment' and would defeat the gcc
# selection, an exported SOURCES_DIR would defeat the ?= derivation. Drive the
# nested make in a scrubbed environment so it behaves like a fresh top-level
# invocation regardless of how this test was started.
run_make() {
	env -i PATH="$PATH" HOME="${HOME:-/tmp}" LC_ALL=C make "$@"
}

# A copy is enough: `make -p -n` / a probe target only parse and expand; no
# recipe runs, and the source/build trees need not exist.
cp "$ROOT_DIR/Makefile" "$WORK/" || { echo "FAIL cannot copy Makefile"; exit 1; }
cp -r "$ROOT_DIR/make" "$WORK/" || { echo "FAIL cannot copy make/"; exit 1; }

TAB="$(printf '\t')"
cat > "$WORK/probe.mk" <<EOF
include make/main.mk
w164-probe:
${TAB}@printf 'DEFAULT_GOAL=%s\n' '\$(.DEFAULT_GOAL)'
${TAB}@printf 'CC=%s\n' '\$(CC)'
${TAB}@printf 'CXX=%s\n' '\$(CXX)'
${TAB}@printf 'PKG_CONFIG_PATH=%s\n' '\$(PKG_CONFIG_PATH)'
${TAB}@printf 'CPPFLAGS=%s\n' '\$(CPPFLAGS)'
${TAB}@printf 'LDFLAGS=%s\n' '\$(LDFLAGS)'
${TAB}@printf 'LD_LIBRARY_PATH=%s\n' '\$(LD_LIBRARY_PATH)'
${TAB}@printf 'PATH=%s\n' '\$(PATH)'
${TAB}@printf 'LIBSTB_HAL_DIR=%s\n' '\$(LIBSTB_HAL_DIR)'
${TAB}@printf 'N_PLUGIN_DIR=%s\n' '\$(N_PLUGIN_DIR)'
${TAB}@printf 'N_LUAPLUGIN_DIR=%s\n' '\$(N_LUAPLUGIN_DIR)'
${TAB}@printf 'CFLAGS_APPEND=[%s]\n' '\$(NEUTRINO_CFLAGS_APPEND)'
${TAB}@printf 'PYTHON=%s\n' '\$(PYTHON)'
${TAB}@printf 'W164_POST=[%s]\n' '\$(W164_POST)'
${TAB}@printf 'GST_BUNDLE=%s\n' '\$(APPIMAGE_BUNDLE_GSTREAMER)'
${TAB}@printf 'GST_DEFINE=[%s]\n' '\$(NEUTRINO_GSTREAMER_FLAGS)'
EOF

# Run the probe with the given Makefile.local body (empty string = none) and
# echo the requested KEY's value.
probe() {
	body="$1"; key="$2"
	if [ -n "$body" ]; then
		printf '%s\n' "$body" > "$WORK/Makefile.local"
	else
		rm -f "$WORK/Makefile.local"
	fi
	( cd "$WORK" && run_make -s -f probe.mk w164-probe 2>/dev/null ) \
		| sed -n "s/^${key}=//p"
}

# --- H3: explicit default goal -------------------------------------------
val="$(probe "" DEFAULT_GOAL)"
if [ "$val" = "help" ]; then
	ok "the default goal is help, not a silent no-op"
else
	ko "the default goal is help, not a silent no-op" "got '$val'"
fi

# --- GStreamer: the switch has to follow configure, not a substring ---------
# libstb-hal enables GStreamer only for the resolved value "yes", so
# --enable-gstreamer=no and --disable-gstreamer are off and the last option
# wins. A `findstring --enable-gstreamer` said yes to all of them: the AppImage
# was asked to bundle modules that were never built, and Neutrino got
# -DENABLE_GSTREAMER=1 against a libstb-hal compiled without it, which is the
# object-size mismatch make/neutrino.mk warns about right above the flag.
gst_case() { # $1 = flags, $2 = expected bundle (0/1)
	gst_body="LIBSTB_HAL_CONFIGURE_FLAGS := $1"
	gst_bundle="$(probe "$gst_body" GST_BUNDLE)"
	gst_define="$(probe "$gst_body" GST_DEFINE)"
	if [ "$2" = 1 ]; then
		gst_want_define="[-DENABLE_GSTREAMER=1]"
	else
		gst_want_define="[]"
	fi
	if [ "$gst_bundle" = "$2" ] && [ "$gst_define" = "$gst_want_define" ]; then
		ok "GStreamer stays $2 for '$1'"
	else
		ko "GStreamer stays $2 for '$1'" \
			"bundle='$gst_bundle' want '$2', define='$gst_define' want '$gst_want_define'"
	fi
}
gst_case "--enable-gstreamer" 1
gst_case "--enable-gstreamer=yes" 1
gst_case "--enable-gstreamer=no" 0
gst_case "--disable-gstreamer" 0
gst_case "--enable-gstreamer --disable-gstreamer" 0
gst_case "--disable-gstreamer --enable-gstreamer" 1

# --- H2: a local TOOLCHAIN_GCC_VERSION reaches the compiler selection -----
cc="$(probe 'TOOLCHAIN_GCC_VERSION := 15' CC)"
cxx="$(probe 'TOOLCHAIN_GCC_VERSION := 15' CXX)"
case "$cc:$cxx" in
	*gcc-15*:*g++-15*)
		ok "TOOLCHAIN_GCC_VERSION from Makefile.local selects gcc-15/g++-15" ;;
	*)
		ko "TOOLCHAIN_GCC_VERSION from Makefile.local selects gcc-15/g++-15" "CC='$cc' CXX='$cxx'" ;;
esac

# --- H2: a local NEUTRINO_INSTALL_DIR reaches the derived pkg-config path --
pcp="$(probe 'NEUTRINO_INSTALL_DIR := /w164/custom-sysroot' PKG_CONFIG_PATH)"
case "$pcp" in
	/w164/custom-sysroot/*)
		ok "NEUTRINO_INSTALL_DIR override flows into PKG_CONFIG_PATH" ;;
	*)
		ko "NEUTRINO_INSTALL_DIR override flows into PKG_CONFIG_PATH" "got '$pcp'" ;;
esac

# --- H2: a dependent := override can still reference an env default ---------
# The whole point of reading Makefile.local after the ?= defaults but before the
# derivations: `N_PLUGIN_DIR := $(N_PREFIX)/...` must see N_PREFIX, not expand it
# to empty. Reading Makefile.local before env.mk regressed this to /oem/plugins.
np_ovr="$(probe 'N_PLUGIN_DIR := $(N_PREFIX)/oem/plugins' N_PLUGIN_DIR)"
case "$np_ovr" in
	/usr/oem/plugins)
		ok "a dependent := override resolves the referenced env default" ;;
	*)
		ko "a dependent := override resolves the referenced env default" "got '$np_ovr'" ;;
esac

# --- H2: += takes effect exactly once ------------------------------------
appended="$(probe 'NEUTRINO_CFLAGS_APPEND += -DW164ONCE' CFLAGS_APPEND)"
count="$(printf '%s\n' "$appended" | grep -o -- '-DW164ONCE' | wc -l | tr -d ' ')"
if [ "$count" = "1" ]; then
	ok "a += in Makefile.local is applied exactly once"
else
	ko "a += in Makefile.local is applied exactly once" "count=$count value=$appended"
fi

# --- H2/H3 coupling: a target in Makefile.local does not hijack the goal ---
val="$(probe "zzz-local-target:${TAB}@true" DEFAULT_GOAL)"
if [ "$val" = "help" ]; then
	ok "a target defined in Makefile.local does not become the default goal"
else
	ko "a target defined in Makefile.local does not become the default goal" "got '$val'"
fi

# --- H2: without Makefile.local nothing derived changes -------------------
hal="$(probe "" LIBSTB_HAL_DIR)"
case "$hal" in
	"$WORK"/sources/libstb-hal)
		ok "derived paths still resolve under ROOT_DIR with no Makefile.local" ;;
	*)
		ko "derived paths still resolve under ROOT_DIR with no Makefile.local" "got '$hal'" ;;
esac

# --- H5: exported plugin dirs match Neutrino's layout --------------------
np="$(probe "" N_PLUGIN_DIR)"
nlp="$(probe "" N_LUAPLUGIN_DIR)"
case "$np" in
	*/share/tuxbox/neutrino/plugins)
		ok "N_PLUGIN_DIR carries the tuxbox/ segment" ;;
	*)
		ko "N_PLUGIN_DIR carries the tuxbox/ segment" "got '$np'" ;;
esac
case "$nlp" in
	*/share/tuxbox/neutrino/luaplugins)
		ok "N_LUAPLUGIN_DIR points at luaplugins, not the C plugin dir" ;;
	*)
		ko "N_LUAPLUGIN_DIR points at luaplugins, not the C plugin dir" "got '$nlp'" ;;
esac

# --- M7: help-targets surfaces the targets the curated help omitted ------
rm -f "$WORK/Makefile.local"
targets="$( cd "$WORK" && run_make -s help-targets 2>/dev/null )"
missing=""
for t in check-toolchain hosttools libstb-hal test-shell help-targets; do
	printf '%s\n' "$targets" | grep -qE "^[[:space:]]+$t[[:space:]]" || missing="$missing $t"
done
if [ -z "$missing" ]; then
	ok "help-targets lists every previously-omitted annotated target"
else
	ko "help-targets lists every previously-omitted annotated target" "missing:$missing"
fi

# --- M7: every alias of a multi-target annotated rule is listed -----------
# `deps-hostdeps hostdeps: ... ##` and `deps-ffmpeg-% ffmpeg-%: ... ##` must
# yield a row per name, not just the first one before the colon.
missing_alias=""
for t in hostdeps ffmpeg-% ffmpeg5; do
	printf '%s\n' "$targets" | grep -qE "^[[:space:]]+$t[[:space:]]" || missing_alias="$missing_alias $t"
done
if [ -z "$missing_alias" ]; then
	ok "help-targets lists every alias on a multi-target rule"
else
	ko "help-targets lists every alias on a multi-target rule" "missing:$missing_alias"
fi

# --- H2/venv: an explicit PYTHON opt-out survives the venv preference ------
# With a venv present the default resolves to it, but `PYTHON := python3` in
# Makefile.local must still win -- the $(origin) guard, not a string compare,
# is what makes those two cases distinguishable.
mkdir -p "$WORK/.venv/bin" && : > "$WORK/.venv/bin/python"
py_default="$(probe "" PYTHON)"
py_optout="$(probe 'PYTHON := python3' PYTHON)"
rm -rf "$WORK/.venv"
case "$py_default" in
	*/.venv/bin/python)
		ok "the venv interpreter is preferred when no PYTHON is set" ;;
	*)
		ko "the venv interpreter is preferred when no PYTHON is set" "got '$py_default'" ;;
esac
if [ "$py_optout" = "python3" ]; then
	ok "an explicit PYTHON := python3 opts out of the venv"
else
	ko "an explicit PYTHON := python3 opts out of the venv" "got '$py_optout'"
fi

# --- env-derive: a sub-make derives the same paths as the top level --------
# The sysroot search paths and flags are prepended to their own exported
# value; a sub-make (bootstrap's $(MAKE) neutrino, the variants) re-reads the
# module with the parent's result in its environment and used to prepend a
# second time. The ffmpeg configure record made that visible: level 1 saw a
# different invocation than level 0.
cat > "$WORK/submake.mk" <<EOF
include make/main.mk
w231-submake:
${TAB}@\$(MAKE) -s -f probe.mk w164-probe
EOF
rm -f "$WORK/Makefile.local"
derived='^(PKG_CONFIG_PATH|CPPFLAGS|LDFLAGS|LD_LIBRARY_PATH|PATH)='
top="$( cd "$WORK" && run_make -s -f probe.mk w164-probe 2>/dev/null | grep -E "$derived" )"
sub="$( cd "$WORK" && run_make -s -f submake.mk w231-submake 2>/dev/null | grep -E "$derived" )"
rm -f "$WORK/submake.mk"
if [ -n "$top" ] && [ "$top" = "$sub" ]; then
	ok "a sub-make derives the same sysroot paths as the top level"
else
	ko "a sub-make derives the same sysroot paths as the top level" "top: $top | sub: $sub"
fi

# A variant sub-make (neutrino-debug and friends) changes the runtime prefix
# but not the scripts directory; its own bin has to land in front of PATH
# even though scripts is already there, or an asan run would pick up the
# release runtime's binaries.
cat > "$WORK/submake.mk" <<EOF
include make/main.mk
w231-variant:
${TAB}@\$(MAKE) -s -f probe.mk NEUTRINO_RUNTIME_PREFIX=$WORK/root-variant w164-probe
EOF
variant_path="$( cd "$WORK" && run_make -s -f submake.mk w231-variant 2>/dev/null | sed -n 's/^PATH=//p' )"
rm -f "$WORK/submake.mk"
scripts_count="$(printf '%s\n' "$variant_path" | tr ':' '\n' | grep -c -x "$WORK/scripts")"
case "$variant_path" in
	"$WORK/root-variant/bin:"*)
		if [ "$scripts_count" -eq 1 ]; then
			ok "a variant sub-make puts its own runtime bin first and scripts only once"
		else
			ko "a variant sub-make puts its own runtime bin first and scripts only once" "scripts x$scripts_count in '$variant_path'"
		fi ;;
	*)
		ko "a variant sub-make puts its own runtime bin first and scripts only once" "got '$variant_path'" ;;
esac

# --- H2/post: a late target extension can reference a later module's var ----
# Makefile.local is read early (variable overrides); target definitions that
# depend on a module variable go in Makefile.local.post, read after every
# module. The early file cannot see NEUTRINO_INSTALL_STAMP; the post file must.
rm -f "$WORK/Makefile.local"
printf 'W164_POST := $(NEUTRINO_INSTALL_STAMP)\n' > "$WORK/Makefile.local.post"
post_val="$( cd "$WORK" && run_make -s -f probe.mk w164-probe 2>/dev/null | sed -n 's/^W164_POST=//p' )"
rm -f "$WORK/Makefile.local.post"
case "$post_val" in
	'['*build*.installed']')
		ok "Makefile.local.post resolves a variable defined by a later module" ;;
	*)
		ko "Makefile.local.post resolves a variable defined by a later module" "got '$post_val'" ;;
esac

# The derived GStreamer switch is deliberately recursive, so that a
# Makefile.local.post -- read after the module that defines it -- still reaches
# it. Written `:=` it is computed at include time, silently ignores that file,
# and turns a GStreamer build back into a non-GStreamer one; nothing else in
# this suite notices, because every other case sets the flags in Makefile.local.
rm -f "$WORK/Makefile.local"
printf 'LIBSTB_HAL_CONFIGURE_FLAGS := --enable-gstreamer\n' > "$WORK/Makefile.local.post"
post_gst="$( cd "$WORK" && run_make -s -f probe.mk w164-probe 2>/dev/null | sed -n 's/^GST_BUNDLE=//p' )"
post_gst_def="$( cd "$WORK" && run_make -s -f probe.mk w164-probe 2>/dev/null | sed -n 's/^GST_DEFINE=//p' )"
rm -f "$WORK/Makefile.local.post"
if [ "$post_gst" = 1 ] && [ "$post_gst_def" = "[-DENABLE_GSTREAMER=1]" ]; then
	ok "a Makefile.local.post flag still reaches the GStreamer switch"
else
	ko "a Makefile.local.post flag still reaches the GStreamer switch" \
		"bundle='$post_gst' want 1, define='$post_gst_def' want [-DENABLE_GSTREAMER=1]"
fi

printf -- '----\n'
printf '[test-make-config] pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
