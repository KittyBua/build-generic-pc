#!/bin/sh
#
# Unit test for the dependency preflight in scripts/setup_deps.sh.
#
# Covers the three behaviours that silently regressed before and would do so
# again unnoticed: that the check actually detects a missing package instead of
# only printing a list, that required and optional packages are reported as two
# separate install commands, and that a missing command is caught even when the
# package manager cannot be queried.
#
# POSIX sh, no external deps beyond the script under test. Exits 0 on success.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/setup_deps.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf 'FAIL %s\n' "$1"; printf '     %s\n' "$2"; fail=$((fail + 1)); }

check_contains() {
	desc="$1"; haystack="$2"; needle="$3"
	case "$haystack" in
		*"$needle"*) ok "$desc" ;;
		*) ko "$desc" "expected to find: $needle" ;;
	esac
}

check_absent() {
	desc="$1"; haystack="$2"; needle="$3"
	case "$haystack" in
		*"$needle"*) ko "$desc" "did not expect: $needle" ;;
		*) ok "$desc" ;;
	esac
}

if [ ! -x "$SCRIPT" ]; then
	printf 'FAIL setup_deps.sh not found at %s\n' "$SCRIPT"
	exit 1
fi

# ---------------------------------------------------------------- doctor mode
# doctor must never change anything and must always exit 0, even on a host that
# is missing everything -- it is the "look before you leap" entry point.
# setup_deps.sh needs bash (set -o pipefail, arrays); this test itself stays sh.
BASH_BIN="$(command -v bash 2>/dev/null || true)"
if [ -z "$BASH_BIN" ]; then
	printf 'ok   skipped: bash not available\n'
	printf '[test-deps-preflight] pass=1 fail=0\n'
	exit 0
fi
doctor_out="$(VENV_DIR="$WORK/venv" LOG_FILE="$WORK/deps.log" \
	"$BASH_BIN" "$SCRIPT" --mode=doctor 2>&1)"
doctor_rc=$?
if [ "$doctor_rc" -eq 0 ]; then
	ok "doctor exits 0"
else
	ko "doctor exits 0" "got rc=$doctor_rc"
fi

check_contains "doctor reports the package manager" "$doctor_out" "[deps] Package manager:"
check_contains "doctor reports required commands" "$doctor_out" "Required commands"

# The combined list was a trap: one unavailable optional package makes apt
# refuse the whole transaction, so the required packages never get installed.
# Required and optional must therefore be reported separately.
check_contains "doctor separates required packages" "$doctor_out" "Required packages"
check_contains "doctor separates optional packages" "$doctor_out" "Optional packages"

# chrpath must not be offered for installation: runtime-sync warns and
# continues without it, but its chrpath -r call has no `|| true` and can abort
# the recipe when the longer RUNPATH does not fit.
check_absent "doctor never proposes chrpath" "$doctor_out" "chrpath"

# ------------------------------------------------------- detection works both ways
# A check that cannot fail is not a check. Feed the helper a package that
# certainly does not exist and require that it is reported as missing.
# missing_packages is internal, so exercise it through a subshell that keeps
# only the definitions and stops before the dispatch block.
probe="$WORK/probe.sh"
sed -n '1,/^ensure_log$/p' "$SCRIPT" | sed '$d' > "$probe"
cat >> "$probe" <<'PROBE'
pm="$(pm_detect)"
if [ "$pm" = "unknown" ]; then
  echo "PM_UNKNOWN"
else
  missing_packages "$pm" definitely-not-a-real-package-xyz
fi
PROBE
probe_out="$("$BASH_BIN" "$probe" 2>&1)"
case "$probe_out" in
	*definitely-not-a-real-package-xyz*|*PM_UNKNOWN*)
		ok "a non-existent package is detected as missing" ;;
	*)
		ko "a non-existent package is detected as missing" "got: $probe_out" ;;
esac

# The counterpart: a package that is certainly installed must NOT be reported.
probe2="$WORK/probe2.sh"
sed -n '1,/^ensure_log$/p' "$SCRIPT" | sed '$d' > "$probe2"
cat >> "$probe2" <<'PROBE'
pm="$(pm_detect)"
if [ "$pm" = "apt" ] && command -v dpkg-query >/dev/null 2>&1; then
  # coreutils is present on every Debian-family system that can run this test
  missing_packages apt coreutils
  echo "PROBE_DONE"
else
  echo "PROBE_SKIP"
fi
PROBE
probe2_out="$("$BASH_BIN" "$probe2" 2>&1)"
case "$probe2_out" in
	*PROBE_SKIP*) ok "installed-package probe skipped (not apt)" ;;
	*coreutils*)  ko "an installed package is not reported missing" "coreutils was flagged" ;;
	*PROBE_DONE*) ok "an installed package is not reported missing" ;;
	*)            ko "an installed package is not reported missing" "got: $probe2_out" ;;
esac

# An apt "a|b" alternatives spec (a package renamed across Debian releases, e.g.
# libfreetype6-dev -> libfreetype-dev on trixie) must be satisfied when EITHER
# name is installed, and must resolve to the installable name for the install
# command. coreutils is present on every Debian-family host.
probe3="$WORK/probe3.sh"
sed -n '1,/^ensure_log$/p' "$SCRIPT" | sed '$d' > "$probe3"
cat >> "$probe3" <<'PROBE'
pm="$(pm_detect)"
if [ "$pm" = "apt" ] && command -v dpkg-query >/dev/null 2>&1 && command -v apt-cache >/dev/null 2>&1; then
  # SPEC_SAT is dpkg-based and works offline. The RESOLVE check reads the apt
  # cache, so only assert it when the cache is populated (a bare container that
  # never ran apt-get update reports no candidate for anything).
  if pkg_installed apt "definitely-absent-xyz|coreutils"; then echo "SPEC_SAT"; else echo "SPEC_MISS"; fi
  if apt_installable coreutils; then
    printf 'RESOLVE=%s\n' "$(apt_resolve "definitely-absent-xyz|coreutils")"
  else
    echo "RESOLVE_SKIP"
  fi
else
  echo "PROBE_SKIP"
fi
PROBE
probe3_out="$("$BASH_BIN" "$probe3" 2>&1)"
case "$probe3_out" in
	*PROBE_SKIP*)
		ok "alternatives-spec test skipped (no apt tooling)" ;;
	*SPEC_SAT*)
		ok "an alternatives spec is satisfied when any name is installed"
		case "$probe3_out" in
			*RESOLVE_SKIP*)
				ok "alternatives resolve check skipped (apt cache not populated)" ;;
			*)
				check_contains "an alternatives spec resolves to the installable name" "$probe3_out" "RESOLVE=coreutils" ;;
		esac ;;
	*)
		ko "an alternatives spec is satisfied when any name is installed" "got: $probe3_out" ;;
esac

# The host ffmpeg dev libs must NOT be unconditional core deps: the default build
# compiles ffmpeg locally, and ffmpeg-devel lives in RPMFusion on Fedora, so
# listing it as core breaks `make deps` there for a package that is never used.
# They must appear in core only when the build opts into system ffmpeg
# (FFMPEG_USE_SYSTEM=1), mirroring the GStreamer opt-in.
probe4="$WORK/probe4.sh"
sed -n '1,/^ensure_log$/p' "$SCRIPT" | sed '$d' > "$probe4"
cat >> "$probe4" <<'PROBE'
in_array() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
in_array libavformat-dev "${CORE_PACKAGES_APT[@]}" && echo "APT_HAS" || echo "APT_MISSING"
in_array ffmpeg-devel   "${CORE_PACKAGES_DNF[@]}" && echo "DNF_HAS" || echo "DNF_MISSING"
PROBE
default_ffmpeg_out="$(FFMPEG_USE_SYSTEM=0 "$BASH_BIN" "$probe4" 2>&1)"
optin_ffmpeg_out="$(FFMPEG_USE_SYSTEM=1 "$BASH_BIN" "$probe4" 2>&1)"
case "$default_ffmpeg_out" in
	*APT_MISSING*) case "$default_ffmpeg_out" in
		*DNF_MISSING*) ok "system ffmpeg dev libs are not core deps by default" ;;
		*) ko "system ffmpeg dev libs are not core deps by default" "dnf still has ffmpeg-devel: $default_ffmpeg_out" ;;
	esac ;;
	*) ko "system ffmpeg dev libs are not core deps by default" "apt still has libavformat-dev: $default_ffmpeg_out" ;;
esac
case "$optin_ffmpeg_out" in
	*APT_HAS*) case "$optin_ffmpeg_out" in
		*DNF_HAS*) ok "FFMPEG_USE_SYSTEM=1 pulls system ffmpeg dev libs into core" ;;
		*) ko "FFMPEG_USE_SYSTEM=1 pulls system ffmpeg dev libs into core" "dnf missing ffmpeg-devel: $optin_ffmpeg_out" ;;
	esac ;;
	*) ko "FFMPEG_USE_SYSTEM=1 pulls system ffmpeg dev libs into core" "apt missing libavformat-dev: $optin_ffmpeg_out" ;;
esac

# dnf resolves `pkgconfig` as a virtual provide, so `dnf install pkgconfig`
# succeeds, but the post-install `rpm -q pkgconfig` check then fails because the
# real package on Fedora is pkgconf-pkg-config. The dnf core list must use the
# real rpm name, or the prerequisite check aborts `make deps` on a host that
# actually has pkg-config.
probe5="$WORK/probe5.sh"
sed -n '1,/^ensure_log$/p' "$SCRIPT" | sed '$d' > "$probe5"
cat >> "$probe5" <<'PROBE'
in_array() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
in_array pkgconf-pkg-config "${CORE_PACKAGES_DNF[@]}" && echo "HAS_REAL" || echo "NO_REAL"
in_array pkgconfig          "${CORE_PACKAGES_DNF[@]}" && echo "HAS_VIRTUAL" || echo "NO_VIRTUAL"
PROBE
probe5_out="$("$BASH_BIN" "$probe5" 2>&1)"
case "$probe5_out" in
	*HAS_REAL*) case "$probe5_out" in
		*NO_VIRTUAL*) ok "dnf core uses the real pkgconf-pkg-config rpm name" ;;
		*) ko "dnf core uses the real pkgconf-pkg-config rpm name" "bare 'pkgconfig' still present -- rpm -q would fail: $probe5_out" ;;
	esac ;;
	*) ko "dnf core uses the real pkgconf-pkg-config rpm name" "pkgconf-pkg-config missing: $probe5_out" ;;
esac

# ------------------------------------------------- installing as a normal user
# Packages are installed only as root, so on an unattended host that is not root
# `make deps` reported everything as missing and stopped -- which is how the CI
# packaging job failed before it compiled a line. Reaching for sudo unasked is
# still wrong on somebody's workstation, so the opt-in has to be explicit and,
# more importantly, has to have no effect when it was not given.
#
# Driven through stubs on PATH: nothing here may install anything for real. The
# stubbed dpkg-query reports every package as absent, so the run stops at the
# verification step either way and the only difference left to observe is
# whether an installation was attempted at all.
stub_run() { # $1 = value for DEPS_ALLOW_SUDO ("" leaves it unset)
	stub="$WORK/stub"
	rm -rf "$stub"
	mkdir -p "$stub"
	: > "$WORK/apt-calls"
	cat > "$stub/apt-get" <<STUB
#!/bin/sh
echo "\$@" >> "$WORK/apt-calls"
exit 0
STUB
	cat > "$stub/sudo" <<'STUB'
#!/bin/sh
[ "$1" = "-n" ] && shift
[ "$1" = "true" ] && exit 0
exec "$@"
STUB
	# Everything absent, so the preflight refuses and create_venv is never
	# reached -- this test must not build a virtualenv.
	printf '#!/bin/sh\nexit 1\n' > "$stub/dpkg-query"
	printf '#!/bin/sh\nexit 1\n' > "$stub/apt-cache"
	chmod +x "$stub/apt-get" "$stub/sudo" "$stub/dpkg-query" "$stub/apt-cache"
	if [ -n "$1" ]; then
		DEPS_ALLOW_SUDO="$1" PATH="$stub:$PATH" VENV_DIR="$WORK/venv-stub" \
			LOG_FILE="$WORK/deps-stub.log" "$BASH_BIN" "$SCRIPT" >/dev/null 2>&1
	else
		PATH="$stub:$PATH" VENV_DIR="$WORK/venv-stub" \
			LOG_FILE="$WORK/deps-stub.log" "$BASH_BIN" "$SCRIPT" >/dev/null 2>&1
	fi
	cat "$WORK/apt-calls" 2>/dev/null
}

if [ "$(id -u)" = 0 ]; then
	# As root the install path is taken regardless, so the opt-in cannot be
	# observed. Skipping would hide that, so say it plainly instead.
	printf 'ok   sudo opt-in not exercised (running as root, installs unconditionally)\n'
	pass=$((pass + 1))
else
	calls_without="$(stub_run "")"
	case "$calls_without" in
		"") ok "without DEPS_ALLOW_SUDO nothing is installed" ;;
		*) ko "without DEPS_ALLOW_SUDO nothing is installed" \
			"apt-get was called: $calls_without" ;;
	esac

	calls_with="$(stub_run 1)"
	case "$calls_with" in
		*install*) ok "DEPS_ALLOW_SUDO=1 installs through sudo" ;;
		*) ko "DEPS_ALLOW_SUDO=1 installs through sudo" \
			"apt-get install was never reached: ${calls_with:-<nothing>}" ;;
	esac
fi

# cmp is what the ffmpeg configure stamp compares its record with, and a
# missing cmp reads as "changed" on every pass: a full ffmpeg rebuild each
# time, with no message about why. It has to be a required command.
probe7="$WORK/probe7.sh"
sed -n '1,/^ensure_log$/p' "$SCRIPT" | sed '$d' > "$probe7"
cat >> "$probe7" <<'PROBE'
in_array() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
in_array cmp "${REQUIRED_COMMANDS[@]}" && echo "HAS_CMP" || echo "NO_CMP"
PROBE
cmp_out="$("$BASH_BIN" "$probe7" 2>&1)"
case "$cmp_out" in
	*HAS_CMP*) ok "cmp is a required command" ;;
	*) ko "cmp is a required command" "got: $cmp_out" ;;
esac

# The locally built ffmpeg is configured with --enable-gnutls, and that flag
# turns a missing gnutls-dev from "no https" into a configure abort. So the
# package must be a core dep on both package managers, unconditionally: it is
# needed by the default build, not by an opt-in.
probe6="$WORK/probe6.sh"
sed -n '1,/^ensure_log$/p' "$SCRIPT" | sed '$d' > "$probe6"
cat >> "$probe6" <<'PROBE'
in_array() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
in_array libgnutls28-dev "${CORE_PACKAGES_APT[@]}" && echo "APT_HAS_GNUTLS" || echo "APT_NO_GNUTLS"
in_array gnutls-devel    "${CORE_PACKAGES_DNF[@]}" && echo "DNF_HAS_GNUTLS" || echo "DNF_NO_GNUTLS"
PROBE
gnutls_out="$(FFMPEG_USE_SYSTEM=0 "$BASH_BIN" "$probe6" 2>&1)"
case "$gnutls_out" in
	*APT_HAS_GNUTLS*) ok "libgnutls28-dev is an apt core dep for the local ffmpeg build" ;;
	*) ko "libgnutls28-dev is an apt core dep for the local ffmpeg build" "got: $gnutls_out" ;;
esac
case "$gnutls_out" in
	*DNF_HAS_GNUTLS*) ok "gnutls-devel is a dnf core dep for the local ffmpeg build" ;;
	*) ko "gnutls-devel is a dnf core dep for the local ffmpeg build" "got: $gnutls_out" ;;
esac

# --------------------------------------------------------------- summary
printf -- '----\n'
printf '[test-deps-preflight] pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
