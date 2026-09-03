#!/bin/sh
#
# Unit test for the AppImage data mapping in scripts/gen_appimage.sh.
#
# Neutrino resolves its data directories through string literals that configure
# bakes into the binary. The package therefore cannot simply carry the files --
# it has to present them at the exact path the binary was built for, which is
# what the generated AppRun does inside a private mount namespace.
#
# That mechanism has failure modes which are all invisible until someone starts
# the finished package on another machine: the data tree silently not copied,
# the writable half mounted read-only so no configuration can be saved, mounts
# escaping into the host filesystem, or a mapping step that fails and takes the
# process down instead of trying the next mechanism.
#
# Runs offline and builds nothing: a stand-in binary stands for Neutrino and
# asserts, from the inside, what Neutrino would need.
#
# POSIX sh. Exits 0 on success, 1 on any failure.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$ROOT_DIR/scripts/gen_appimage.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
skip=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf 'FAIL %s\n' "$1"; printf '     %s\n' "$2"; fail=$((fail + 1)); }
sk() { printf 'skip %s\n' "$1"; printf '     %s\n' "$2"; skip=$((skip + 1)); }

if [ ! -f "$GEN" ]; then
	printf 'FAIL scripts/gen_appimage.sh not found\n'
	exit 1
fi

PREFIX=/opt/neutrino
if [ -e "$PREFIX" ]; then prefix_existed_before=yes; else prefix_existed_before=no; fi

# gen_appimage.sh derives the package version from the Neutrino source tree, and
# scripts/version_info.sh exits if it is not there. A CI checkout of this repo
# alone has no sources/neutrino, so every assertion that reaches gen_appimage.sh
# failed there while passing on any developer machine -- which is precisely the
# blind spot a unit test is supposed to close. version_info.sh honours SRC_DIR,
# so point it at the three defines it actually reads. Nothing else about the
# real source tree matters here; the version only names the output file.
FAKE_SRC="$WORK/fake-src"
mkdir -p "$FAKE_SRC"
cat > "$FAKE_SRC/configure.ac" <<'ACSRC'
define(ver_major, 2026)
define(ver_minor, 8)
define(ver_micro, 0)
ACSRC

# The stand-in has to be a real ELF with a RUNPATH: the packaging step rewrites
# that RUNPATH, and a shell script would not exercise it.
# CC arrives from the environment under "make test-shell", where it can be a
# multi-word command such as "ccache gcc" -- and, until the guard above was
# fixed, a leading space on a host without ccache. Testing the raw value with
# command -v fails on either, which silently skipped this whole file.
CC="$(printf '%s' "${CC:-cc}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
[ -n "$CC" ] || CC=cc
CC_BIN="${CC%% *}"
have_cc=0
if command -v "$CC_BIN" >/dev/null 2>&1; then
	have_cc=1
fi

build_fake_sysroot() {
	root="$1"
	rm -rf "$root"
	mkdir -p "$root/usr/bin" "$root/usr/lib"
	mkdir -p "$root$PREFIX/usr/share/tuxbox/neutrino/icons"
	mkdir -p "$root$PREFIX/usr/share/tuxbox/neutrino/httpd"
	mkdir -p "$root$PREFIX/usr/var/tuxbox/config"
	echo marker > "$root$PREFIX/usr/share/tuxbox/neutrino/icons/marker"
	echo index  > "$root$PREFIX/usr/share/tuxbox/neutrino/httpd/index.html"
	echo seeded > "$root$PREFIX/usr/var/tuxbox/config/neutrino.conf"

	cat > "$WORK/fake.c" <<'CSRC'
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>

/* Stands in for Neutrino: it can only look at the baked prefix, so every check
   here fails unless the AppRun mapping is actually in place. */
static int missing(const char *path)
{
	if (access(path, R_OK) != 0) {
		printf("MISSING %s\n", path);
		return 1;
	}
	return 0;
}

int main(void)
{
	FILE *f;

	if (missing("/opt/neutrino/usr/share/tuxbox/neutrino/icons/marker"))
		return 3;
	if (missing("/opt/neutrino/usr/share/tuxbox/neutrino/httpd/index.html"))
		return 3;
	if (missing("/opt/neutrino/usr/var/tuxbox/config/neutrino.conf"))
		return 3;

	f = fopen("/opt/neutrino/usr/var/tuxbox/config/written", "w");
	if (f == NULL) {
		printf("STATE_NOT_WRITABLE\n");
		return 4;
	}
	fclose(f);

	f = fopen("/opt/neutrino/usr/share/probe", "w");
	if (f != NULL) {
		fclose(f);
		printf("DATA_WRITABLE\n");
		return 5;
	}

	printf("BRIDGE_OK\n");
	return 0;
}
CSRC
	# Unquoted on purpose: CC may be "ccache gcc".
	# shellcheck disable=SC2086
	if ! $CC -o "$root/usr/bin/neutrino" "$WORK/fake.c" \
		-Wl,-rpath,"$WORK/a-long-staging-path-that-must-not-survive/usr/lib" \
		>/dev/null 2>&1; then
		# Leave nothing behind: the later blocks check for this directory, and a
		# sysroot without a binary turns one compile failure into a cascade of
		# unrelated failures that hide the real cause.
		rm -rf "$root"
		return 1
	fi
	return 0
}

# $1 = install dir, $2 = output dir, $3 = data prefix; prints nothing, returns
# the exit status of gen_appimage.sh. appimagetool is deliberately absent, so
# the run stops after the AppDir has been assembled.
run_gen() {
	# GStreamer bundling is switched off here on purpose: it needs the GStreamer
	# development files, which setup_deps.sh only installs for a GStreamer build
	# and which no CI runner has. Without this the whole file fails on every CI
	# job for a reason that has nothing to do with what it tests.
	( cd "$ROOT_DIR" && \
		SRC_DIR="$FAKE_SRC" \
		NEUTRINO_INSTALL_DIR="$1" \
		APPIMAGE_OUTPUT_DIR="$2" \
		NEUTRINO_APPIMAGE_PREFIX="$3" \
		APPIMAGE_BUNDLE_GSTREAMER=0 \
		APPIMAGE_TOOL=/nonexistent-appimagetool \
		"$GEN" ) >"$WORK/gen.log" 2>&1
}

# --- prefix validation ------------------------------------------------------
# AppRun lays a tmpfs over the parent of the prefix to create the mount point.
# A single-component prefix makes that parent "/", which would hide the entire
# root filesystem from Neutrino.
if [ "$have_cc" -eq 1 ] && ! build_fake_sysroot "$WORK/sysroot"; then
	ko "the stand-in binary can be built" \
		"'$CC' is on PATH but compiling the fixture failed; the suite would otherwise
     report every assertion below as skipped and still exit 0"
	have_cc=0
fi

if [ "$have_cc" -eq 1 ]; then
	run_gen "$WORK/sysroot" "$WORK/out-badprefix" "/opt"
	if [ $? -ne 0 ] && grep -q 'at least two components' "$WORK/gen.log"; then
		ok "a single-component prefix is rejected"
	else
		ko "a single-component prefix is rejected" "$(tail -2 "$WORK/gen.log")"
	fi

	run_gen "$WORK/sysroot" "$WORK/out-nodata" "/opt/does-not-exist"
	if [ $? -ne 0 ] && grep -q 'No data tree' "$WORK/gen.log"; then
		ok "a missing data tree is refused instead of packaged empty"
	else
		ko "a missing data tree is refused instead of packaged empty" "$(tail -2 "$WORK/gen.log")"
	fi
else
	ko "a C compiler is available to build the stand-in binary" \
		"'$CC_BIN' cannot compile the fixture. Without it nothing here is exercised, and
     reporting that as a skip would let the suite pass while testing nothing."
fi

# --- AppDir assembly --------------------------------------------------------
APPDIR=""
if [ "$have_cc" -eq 1 ] && [ -d "$WORK/sysroot" ]; then
	# Not just "non-zero": the script has several earlier exits, and a missing
	# chrpath would satisfy a bare exit-code check while proving nothing.
	if ! run_gen "$WORK/sysroot" "$WORK/out" "$PREFIX" &&
	   grep -q 'is not available' "$WORK/gen.log"; then
		ok "gen_appimage.sh stops at the packaging step without appimagetool"
	else
		ko "gen_appimage.sh stops at the packaging step without appimagetool" \
			"$(tail -3 "$WORK/gen.log")"
	fi
	if [ -d "$WORK/out/Neutrino.AppDir" ]; then
		APPDIR="$WORK/out/Neutrino.AppDir"
	fi

	if [ -f "$APPDIR$PREFIX/usr/share/tuxbox/neutrino/icons/marker" ] &&
	   [ -f "$APPDIR$PREFIX/usr/share/tuxbox/neutrino/httpd/index.html" ]; then
		ok "the data tree below the prefix is copied into the AppDir"
	else
		ko "the data tree below the prefix is copied into the AppDir" \
			"missing under $APPDIR$PREFIX"
	fi

	if [ -d "$APPDIR$PREFIX/usr/var" ]; then
		ok "the writable mount point exists in the AppDir"
	else
		ko "the writable mount point exists in the AppDir" "no $APPDIR$PREFIX/usr/var"
	fi

	if [ -x "$APPDIR/AppRun" ] && sh -n "$APPDIR/AppRun" 2>/dev/null; then
		ok "the generated AppRun is executable and valid POSIX sh"
	else
		ko "the generated AppRun is executable and valid POSIX sh" "sh -n failed"
	fi

	# Neutrino only builds its dummy frontend when it found no tuner *and*
	# SIMULATE_FE says so (src/zapit/femanager.cpp). Without a receiver and
	# without the variable, a downloaded package just ends up with no frontend.
	# Setting it unconditionally is not an option either: the same variable
	# switches off radiotext and other tuner-bound functions in
	# src/gui/osd_setup.cpp and src/gui/channellist.cpp, and this package goes
	# to people who may well own a receiver.
	#
	# The decision block is lifted out of the *generated* AppRun and driven
	# directly, so this measures the shipped text rather than a copy of it.
	awk '/^NEUTRINO_FRONTEND_GLOB=/,/^fi$/' "$APPDIR/AppRun" > "$WORK/fe_decision.sh"
	mkdir -p "$WORK/fe/adapter0"
	decide() { # $1 = glob, $2 = preset value ("" leaves it unset)
		if [ -n "$2" ]; then
			SIMULATE_FE="$2" NEUTRINO_FRONTEND_GLOB="$1" sh -c \
				'. "$0"; printf "%s" "${SIMULATE_FE:-unset}"' "$WORK/fe_decision.sh"
		else
			NEUTRINO_FRONTEND_GLOB="$1" sh -c \
				'. "$0"; printf "%s" "${SIMULATE_FE:-unset}"' "$WORK/fe_decision.sh"
		fi
	}

	got=$(decide "$WORK/fe/adapter*/frontend*" "")
	[ "$got" = 1 ] && ok "with no tuner AppRun turns simulation on" \
		|| ko "with no tuner AppRun turns simulation on" "SIMULATE_FE=$got"

	touch "$WORK/fe/adapter0/frontend0"
	got=$(decide "$WORK/fe/adapter*/frontend*" "")
	[ "$got" = unset ] && ok "with a tuner AppRun leaves simulation alone" \
		|| ko "with a tuner AppRun leaves simulation alone" "SIMULATE_FE=$got"

	# A value the user chose wins either way -- 0 is how somebody with a
	# receiver switches the simulation off again, and it must survive.
	got=$(decide "$WORK/fe/nothing-here/*" 0)
	[ "$got" = 0 ] && ok "a chosen SIMULATE_FE=0 is not overwritten" \
		|| ko "a chosen SIMULATE_FE=0 is not overwritten" "SIMULATE_FE=$got"
	rm -f "$WORK/fe/adapter0/frontend0"

	# The linker records the staging directory; shipping that would name the
	# machine the package was built on and point at libraries no other machine
	# has.
	rp=""
	if command -v readelf >/dev/null 2>&1; then
		rp="$(readelf -d "$APPDIR/usr/bin/neutrino" 2>/dev/null |
			awk '/RUNPATH|RPATH/ {print $NF}' | tr -d '[]')"
		case "$rp" in
			'$ORIGIN'*) ok "the RUNPATH is rewritten to \$ORIGIN" ;;
			*) ko "the RUNPATH is rewritten to \$ORIGIN" "found: ${rp:-none}" ;;
		esac
	else
		sk "RUNPATH rewrite" "readelf not available"
	fi
else
	sk "AppDir assembly" "no working C compiler ($CC); cannot build the stand-in binary"
fi

# --- the mapping itself -----------------------------------------------------
# Needs a private mount namespace. Restricted containers deny that even to root,
# so report it as skipped rather than as a defect in the package.
have_ns=0
if [ "$(id -u)" = 0 ] && unshare --mount --propagation private true 2>/dev/null; then
	have_ns=1
elif unshare --user --map-root-user --mount --propagation private true 2>/dev/null; then
	have_ns=1
elif command -v bwrap >/dev/null 2>&1 && bwrap --dev-bind / / true 2>/dev/null; then
	have_ns=1
fi

if [ -n "$APPDIR" ] && [ "$have_ns" -eq 1 ]; then
	STATE="$WORK/state"
	rm -rf "$STATE"
	out="$(NEUTRINO_APPIMAGE_STATE="$STATE" "$APPDIR/AppRun" 2>&1)"
	rc=$?

	case "$out" in
		*BRIDGE_OK*)
			ok "the baked prefix resolves to the bundled data at runtime"
			ok "the shipped data stays read-only"
			ok "the per-user state is writable"
			;;
		*MISSING*)
			ko "the baked prefix resolves to the bundled data at runtime" "$out"
			;;
		*STATE_NOT_WRITABLE*)
			ko "the per-user state is writable" "$out"
			;;
		*DATA_WRITABLE*)
			ko "the shipped data stays read-only" \
				"the read-only bind is missing, so a package could modify itself"
			;;
		*)
			ko "the baked prefix resolves to the bundled data at runtime" "rc=$rc: $out"
			;;
	esac

	if [ -f "$STATE/tuxbox/config/neutrino.conf" ]; then
		ok "the per-user state is seeded from the shipped defaults on first run"
	else
		ko "the per-user state is seeded from the shipped defaults on first run" \
			"no neutrino.conf below $STATE"
	fi

	# Two regressions that cost the user their configuration, both found in
	# review rather than here. Neither is exotic: shell completion appends the
	# trailing slash, and every user upgrading from a package that predates the
	# marker arrives with a state directory that has none.
	STATE_SLASH="$WORK/state-slash"
	rm -rf "$STATE_SLASH"
	mkdir -p "$STATE_SLASH/tuxbox/config"
	echo mine > "$STATE_SLASH/tuxbox/config/bouquets.xml"
	# The output matters as much as the files: an AppRun that refuses to start
	# also leaves the configuration untouched, and that is not the guarantee
	# being tested here.
	out="$(NEUTRINO_APPIMAGE_STATE="$STATE_SLASH/" "$APPDIR/AppRun" 2>&1)"
	if [ -f "$STATE_SLASH/tuxbox/config/bouquets.xml" ] &&
	   [ "$(cat "$STATE_SLASH/tuxbox/config/bouquets.xml" 2>/dev/null)" = mine ] &&
	   case "$out" in *BRIDGE_OK*) true ;; *) false ;; esac; then
		ok "a trailing slash on the state path does not destroy the configuration"
	else
		ko "a trailing slash on the state path does not destroy the configuration" \
			"$STATE_SLASH/tuxbox/config/bouquets.xml is gone or changed"
	fi

	STATE_OLD="$WORK/state-old"
	rm -rf "$STATE_OLD"
	mkdir -p "$STATE_OLD/tuxbox/config"
	echo mine > "$STATE_OLD/tuxbox/config/bouquets.xml"
	echo keep > "$STATE_OLD/tuxbox/config/neutrino.conf"
	out="$(NEUTRINO_APPIMAGE_STATE="$STATE_OLD" "$APPDIR/AppRun" 2>&1)"
	if [ "$(cat "$STATE_OLD/tuxbox/config/bouquets.xml" 2>/dev/null)" = mine ] &&
	   [ "$(cat "$STATE_OLD/tuxbox/config/neutrino.conf" 2>/dev/null)" = keep ] &&
	   case "$out" in *BRIDGE_OK*) true ;; *) false ;; esac; then
		ok "an unmarked existing configuration is completed, never overwritten"
	else
		ko "an unmarked existing configuration is completed, never overwritten" \
			"existing files under $STATE_OLD were replaced or removed"
	fi

	# The whole point of the namespace: a package must not leave anything on the
	# machine it ran on. Compared against what was there before, not against
	# absence -- a machine that legitimately has /opt/neutrino installed would
	# otherwise fail this for no reason, and CI runs this suite.
	if [ "$prefix_existed_before" = "$(if [ -e "$PREFIX" ]; then echo yes; else echo no; fi)" ]; then
		ok "the host filesystem is left untouched"
	else
		ko "the host filesystem is left untouched" \
			"$PREFIX changed from existed=$prefix_existed_before during the run"
	fi
elif [ -n "$APPDIR" ]; then
	sk "the runtime mapping" "no mount namespace available here (restricted container?)"
fi

# --- the fallback ladder ----------------------------------------------------
# A mapping step that cannot run must say so. Reporting it as a defect only
# works if the failure is not silent and not a crash.
if [ -n "$APPDIR" ]; then
	MINBIN="$WORK/minbin"
	rm -rf "$MINBIN"
	mkdir -p "$MINBIN"
	for t in sh readlink dirname id mkdir cp mv cat rm; do
		p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MINBIN/$t"
	done
	printf '#!/bin/sh\nexit 1\n' > "$MINBIN/unshare"
	chmod +x "$MINBIN/unshare"

	out="$(env -i PATH="$MINBIN" HOME="$WORK/home-none" \
		NEUTRINO_APPIMAGE_STATE="$WORK/state-none" "$APPDIR/AppRun" 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'cannot map the bundled data'; then
		ok "with no namespace mechanism it fails with a diagnosis, not a crash"
	else
		ko "with no namespace mechanism it fails with a diagnosis, not a crash" \
			"rc=$rc: $(printf '%s' "$out" | head -3)"
	fi
fi

# --- the library policy patterns ------------------------------------------
# The block that applies these deletes files from the AppDir, and it only runs
# when linuxdeploy is available -- so no test reaches it, and both regressions
# that lived there (an unanchored "libGL" that deleted the required libGLEW, and
# a rule so broad it removed the X11 client libraries libglut needs) got as far
# as a finished package. The patterns themselves need no build to check.
host_re="$(sed -n "s/^APPIMAGE_HOST_LIBS='\(.*\)'$/\1/p" "$GEN")"
never_re="$(sed -n "s/^  never_bundle='\(.*\)'$/\1/p" "$GEN")"

if [ -z "$host_re" ] || [ -z "$never_re" ]; then
	ko "the library policy patterns can be read from gen_appimage.sh" \
		"APPIMAGE_HOST_LIBS or never_bundle not found; the assertions below cannot run"
else
	# $1 = pattern, $2 = name, $3 = expected (yes|no), $4 = why it matters
	check_pattern() {
		if printf '%s\n' "$2" | grep -qE "$1"; then got=yes; else got=no; fi
		if [ "$got" = "$3" ]; then
			ok "$4"
		else
			ko "$4" "'$2' match=$got, expected $3"
		fi
	}

	check_pattern "$never_re" libGLEW.so.2.2 no \
		"libGLEW is not treated as a host library (it must be bundled)"
	check_pattern "$never_re" libglut.so.3 no \
		"libglut is not treated as a host library (it must be bundled)"
	check_pattern "$never_re" libGL.so.1 yes \
		"libGL is refused (it is the entry point into the host driver)"
	check_pattern "$never_re" libGLESv2.so.2 yes \
		"libGLESv2 is refused"
	check_pattern "$never_re" libc.so.6 yes \
		"the C library is refused"
	check_pattern "$never_re" libgomp.so.1 no \
		"libgomp may be bundled (a leaf, no driver, no version agreement needed)"
	check_pattern "$never_re" libXext.so.6 no \
		"X11 client libraries are left to the upstream exclude list"
	check_pattern "$never_re" libva.so.2 no \
		"libva may ship (the host libavcodec needs it; it degrades to software)"
	check_pattern "$host_re" libGLEW.so.2.2 no \
		"libGLEW is not withheld from the dependency closure either"
	check_pattern "$host_re" libfontconfig.so.1 no \
		"libfontconfig is collected for the modules that need it"
fi

printf -- '----\n'
printf '[test-appimage-bridge] pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
exit 0
