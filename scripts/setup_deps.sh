#!/usr/bin/env bash
set -euo pipefail

MODE="auto"
ALLOW_NON_ROOT="${ALLOW_NON_ROOT:-0}"
LOG_FILE="${LOG_FILE:-/tmp/neutrino-deps.log}"
VENV_DIR="${VENV_DIR:-.venv}"

NEUTRINO_DEPS_APT=(
  # Debian renamed this from libfreetype6-dev to libfreetype-dev in trixie
  # (Debian 13). Listing both as apt alternatives lets one list serve both
  # releases; the installed/installable one is picked per host. The new name
  # is listed FIRST on purpose: it also exists on bookworm (as the transitional
  # package), so even the empty-apt-cache fallback (first alternative) yields a
  # name that installs on both 12 and 13 -- the doctor hint is never wrong.
  "libfreetype-dev|libfreetype6-dev"
  libsigc++-2.0-dev
  libopenthreads-dev
  libvorbis-dev
  libogg-dev
)

NEUTRINO_DEPS_DNF=(
  freetype-devel
  libsigc++20-devel
  OpenThreads-devel
  libvorbis-devel
  libogg-devel
)

GSTREAMER_DEPS_APT=(
  libgstreamer1.0-dev
  libgstreamer-plugins-base1.0-dev
  libgstreamer-plugins-bad1.0-dev
)

GSTREAMER_DEPS_DNF=(
  gstreamer1-devel
  gstreamer1-plugins-base-devel
  gstreamer1-plugins-bad-free-devel
)

# ffmpeg dev libraries are needed ONLY when building against the host ffmpeg
# (FFMPEG_USE_SYSTEM=1). The default build compiles ffmpeg locally and links
# against that, so these must not be unconditional core deps: ffmpeg-devel in
# particular lives in RPMFusion on Fedora and would break `make deps` there for
# a package the default build never uses. Appended to core only on opt-in below,
# mirroring the GStreamer handling.
FFMPEG_SYSTEM_DEPS_APT=(
  libavformat-dev libswscale-dev libswresample-dev
)

FFMPEG_SYSTEM_DEPS_DNF=(
  ffmpeg-devel
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*)
      MODE="${1#*=}"
      shift
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
setup_deps.sh -- install/update Neutrino generic-pc build requirements.

Options:
  --mode <auto|update|doctor>
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Packages without which the core build cannot succeed. Missing entries here
# abort before the build instead of failing deep inside ./configure.
# libgnutls28-dev (gnutls-devel on dnf) is what the locally built ffmpeg's
# --enable-gnutls needs (make/third_party/ffmpeg.mk): without a TLS backend
# that ffmpeg has no https protocol, and with the flag set but the headers
# missing its configure aborts. It stays in the core list even for
# FFMPEG_USE_SYSTEM=1, where it merely sits idle: the package lives in every
# main repository, so nothing is gained by a second conditional list.
CORE_PACKAGES_APT=(
  build-essential git pkg-config cmake ninja-build nasm automake autoconf libtool
  curl rsync patch xz-utils
  gettext libssl-dev libgnutls28-dev libcurl4-openssl-dev libjpeg-dev libpng-dev libtiff-dev libglew-dev
  freeglut3-dev libao-dev libmad0-dev libid3tag0-dev libgif-dev libflac-dev
  libreadline-dev liblua5.3-dev lua5.3 libluajit-5.1-dev
  python3 python3-dev python3-venv python3-pip
)
CORE_PACKAGES_APT+=("${NEUTRINO_DEPS_APT[@]}")

# Needed only for the test suites, packaging and optional run targets. Missing
# entries are reported but never block the build.
# chrpath is deliberately NOT installed. runtime-sync warns and continues when
# it is absent, but when it is present its `chrpath -r` call (make/main.mk) has
# no `|| true`, and the longer RUNPATH is not always writable ("new rpath too
# large"), which aborts the recipe. Listing it -- in either list -- would make
# `make deps` install it and turn a harmless skip into a build failure.
# patchelf does the same job for the AppImage build and is not affected: nothing
# outside gen_appimage.sh calls it, and gen_appimage.sh refuses to package
# without one of the two, so without this entry the documented AppImage flow
# fails immediately after a plain `make deps`. It belongs in *both* lists -- an
# apt-only entry left Fedora without it, and the AppImage suite failed there
# while passing on every Debian and Ubuntu image in the same CI run.
# procps (procps-ng on Fedora) supplies pgrep, which run-neutrino.sh asks
# whether a Neutrino is already running before starting another one, and which
# cleanup_runtime.sh uses to find leftovers. Neither is fatal without it -- both
# say so and carry on -- but on a minimal Fedora image the single-instance
# guard silently protected nothing, which is how the run-report suite found it.
OPTIONAL_PACKAGES_APT=(
  python3-opencv python3-numpy tesseract-ocr libleptonica-dev
  xvfb x11-apps fbcat netpbm fonts-dejavu-core
  libevdev-dev evtest proot libfuse2
  appstream file desktop-file-utils squashfs-tools patchelf
  procps
)

ENABLE_GSTREAMER="${ENABLE_GSTREAMER:-0}"
if [[ "${LIBSTB_HAL_CONFIGURE_FLAGS:-}" == *--enable-gstreamer* ]]; then
  ENABLE_GSTREAMER=1
fi
# Opted into explicitly, so these are required for that build, not optional.
if [[ "${ENABLE_GSTREAMER}" == "1" ]]; then
  CORE_PACKAGES_APT+=("${GSTREAMER_DEPS_APT[@]}")
fi

# Host ffmpeg dev libs are required only when linking against system ffmpeg.
FFMPEG_USE_SYSTEM="${FFMPEG_USE_SYSTEM:-0}"
if [[ "${FFMPEG_USE_SYSTEM}" == "1" ]]; then
  CORE_PACKAGES_APT+=("${FFMPEG_SYSTEM_DEPS_APT[@]}")
fi

SYSTEM_PACKAGES_APT=("${CORE_PACKAGES_APT[@]}" "${OPTIONAL_PACKAGES_APT[@]}")

# diffutils: cmp, which the ffmpeg configure stamp compares its record with;
# essential on Debian, a normal package on Fedora that a minimal image lacks.
CORE_PACKAGES_DNF=(
  gcc gcc-c++ make git pkgconf-pkg-config cmake ninja-build nasm automake autoconf libtool
  curl rsync patch xz diffutils
  gettext openssl-devel gnutls-devel libcurl-devel libjpeg-turbo-devel libpng-devel libtiff-devel
  glew-devel freeglut-devel libao-devel libmad-devel
  libid3tag-devel giflib-devel flac-devel readline-devel lua-devel luajit-devel
  python3 python3-devel python3-virtualenv python3-pip
)
CORE_PACKAGES_DNF+=("${NEUTRINO_DEPS_DNF[@]}")

OPTIONAL_PACKAGES_DNF=(
  opencv opencv-devel tesseract tesseract-devel leptonica-devel
  xorg-x11-server-Xvfb netpbm-progs dejavu-sans-fonts
  libevdev-devel evtest fuse fuse-libs
  appstream file desktop-file-utils squashfs-tools patchelf
  procps-ng
)

if [[ "${ENABLE_GSTREAMER}" == "1" ]]; then
  CORE_PACKAGES_DNF+=("${GSTREAMER_DEPS_DNF[@]}")
fi

if [[ "${FFMPEG_USE_SYSTEM}" == "1" ]]; then
  CORE_PACKAGES_DNF+=("${FFMPEG_SYSTEM_DEPS_DNF[@]}")
fi

SYSTEM_PACKAGES_DNF=("${CORE_PACKAGES_DNF[@]}" "${OPTIONAL_PACKAGES_DNF[@]}")

PIP_PACKAGES=(
  pytest pytest-xdist pytest-timeout
  pillow opencv-python-headless pytesseract numpy
  evdev
)

ensure_log() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}"
}

pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "dnf"
  else
    echo "unknown"
  fi
}

pm_install() {
  local pm="$1"
  shift
  local packages=("$@")
  if [[ "${#packages[@]}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${pm}" == "apt" ]]; then
    # Update first: apt_resolve reads the apt cache to pick the installable
    # alternative, and on a fresh host the package lists are empty until now (a
    # bare debian:13 has a candidate for nothing, so resolution would wrongly
    # fall back to the first, removed name before the cache is populated).
    "${SUDO_BIN[@]}" apt-get update
    # Collapse any "a|b" alternatives to the concrete name apt can install here,
    # so apt-get never sees a literal pipe.
    local p
    local -a resolved=()
    for p in "${packages[@]}"; do resolved+=("$(apt_resolve "${p}")"); done
    # DEBIAN_FRONTEND=noninteractive keeps package post-install scripts from
    # opening a debconf prompt (e.g. tzdata's geographic-area question) that
    # would block forever on a container or headless host with no stdin. Pass it
    # through env so it survives even when SUDO_BIN is "sudo" (which resets the
    # environment).
    "${SUDO_BIN[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${resolved[@]}"
  elif [[ "${pm}" == "dnf" ]]; then
    "${SUDO_BIN[@]}" dnf install -y "${packages[@]}"
  fi
}

# Commands the build invokes directly. Package names differ per distro, so the
# preflight reports the command and lets the package list carry the mapping.
# cmp: the ffmpeg configure stamp compares its record with it; without cmp
# every pass would read as a changed record and rebuild ffmpeg from scratch.
REQUIRED_COMMANDS=(
  gcc g++ make git pkg-config autoconf automake libtool
  rsync patch tar python3 cmp
)

# One of these is enough: the download helpers accept either.
DOWNLOAD_COMMANDS=(curl wget)

# apt: does this exact package have an installation candidate on this host?
apt_installable() {
  local cand
  cand="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk -F': ' '/Candidate:/ {print $2; exit}')"
  [[ -n "${cand}" && "${cand}" != "(none)" ]]
}

# apt: resolve a spec "a|b" (alternatives, apt's own syntax) to the name to
# install on THIS host -- the first alternative apt can install, else the first
# listed. A plain name passes through unchanged.
apt_resolve() {
  local spec="$1" alt
  local -a alts
  IFS='|' read -r -a alts <<< "${spec}"
  for alt in "${alts[@]}"; do
    if apt_installable "${alt}"; then printf '%s' "${alt}"; return 0; fi
  done
  printf '%s' "${alts[0]}"
}

pkg_installed() {
  local pm="$1" pkg="$2" alt
  local -a alts
  case "${pm}" in
    apt)
      # Satisfied if ANY alternative in an "a|b" spec is installed.
      IFS='|' read -r -a alts <<< "${pkg}"
      for alt in "${alts[@]}"; do
        dpkg-query -W -f='${db:Status-Abbrev}' "${alt}" 2>/dev/null | grep -q '^ii' && return 0
      done
      return 1
      ;;
    dnf) rpm -q "${pkg}" >/dev/null 2>&1 ;;
    *)   return 0 ;;  # unknown package manager: cannot verify, do not block
  esac
}

# Prints missing package names, one per line. For an apt "a|b" alternatives
# spec, prints the name to actually install on this host (so the generated
# install command is correct across Debian releases).
missing_packages() {
  local pm="$1"; shift
  local pkg
  for pkg in "$@"; do
    pkg_installed "${pm}" "${pkg}" && continue
    if [[ "${pm}" == "apt" ]]; then
      apt_resolve "${pkg}"; printf '\n'
    else
      printf '%s\n' "${pkg%%|*}"
    fi
  done
}

# Prints missing commands, one per line.
missing_commands() {
  local cmd found
  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || printf '%s\n' "${cmd}"
  done
  found=0
  for cmd in "${DOWNLOAD_COMMANDS[@]}"; do
    if command -v "${cmd}" >/dev/null 2>&1; then found=1; break; fi
  done
  [[ "${found}" -eq 1 ]] || printf '%s\n' "curl (or wget)"
}

install_hint() {
  local pm="$1"; shift
  case "${pm}" in
    apt) echo "sudo apt-get update && sudo apt-get install -y $*" ;;
    dnf) echo "sudo dnf install -y $*" ;;
    *)   echo "(install these with your package manager: $*)" ;;
  esac
}

# Fails with an actionable message when prerequisites are missing, so the build
# stops here instead of dying deep inside ./configure.
require_prerequisites() {
  local pm="$1"
  local -a miss_pkg=() miss_cmd=()
  mapfile -t miss_pkg < <(missing_packages "${pm}" "${@:2}")
  mapfile -t miss_cmd < <(missing_commands)

  if [[ "${#miss_pkg[@]}" -eq 0 && "${#miss_cmd[@]}" -eq 0 ]]; then
    return 0
  fi

  {
    echo "[deps] ERROR: Fehlende Voraussetzungen / missing prerequisites."
    if [[ "${#miss_cmd[@]}" -gt 0 ]]; then
      echo "[deps] Fehlende Programme / missing commands:"
      printf '         %s\n' "${miss_cmd[@]}"
    fi
    if [[ "${#miss_pkg[@]}" -gt 0 ]]; then
      echo "[deps] Fehlende Pakete / missing packages (${#miss_pkg[@]}):"
      printf '         %s\n' "${miss_pkg[@]}"
      echo "[deps] Installieren mit / install with:"
      echo "         $(install_hint "${pm}" "${miss_pkg[@]}")"
    fi
    echo "[deps] Danach den Build erneut starten / then start the build again:"
    echo "         make bootstrap"
    echo "[deps] Pruefung ueberspringen (auf eigene Gefahr) / skip this check:"
    echo "         SKIP_DEP_CHECK=1 make bootstrap"
  } >&2
  return 1
}

create_venv() {
  if ! command -v python3 >/dev/null 2>&1; then
    {
      echo "[deps] ERROR: python3 fehlt und wird fuer die Testumgebung gebraucht."
      echo "[deps] ERROR: python3 is missing but required for the test environment."
      echo "[deps] $(install_hint "$(pm_detect)" python3 python3-venv python3-pip)"
    } >&2
    return 1
  fi
  if [[ ! -d "${VENV_DIR}" ]]; then
    echo "[deps] Creating virtual environment at ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  fi
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  echo "[deps] Installing Python packages: ${PIP_PACKAGES[*]}"
  pip install --upgrade pip wheel
  pip install "${PIP_PACKAGES[@]}"
}

doctor_report() {
  local pm
  pm=$(pm_detect)
  echo "[deps] Package manager: ${pm}"

  local -a miss_cmd=()
  mapfile -t miss_cmd < <(missing_commands)
  if [[ "${#miss_cmd[@]}" -eq 0 ]]; then
    echo "[deps] Required commands: all present"
  else
    echo "[deps] Required commands MISSING (${#miss_cmd[@]}):"
    printf '         %s\n' "${miss_cmd[@]}"
  fi

  if [[ "${pm}" == "unknown" ]]; then
    echo "[deps] Cannot verify system packages: unknown package manager."
  else
    # Reported as two separate lists with two separate install commands. A single
    # combined command is a trap: if one OPTIONAL package is unavailable on this
    # distro (libfuse2 vs libfuse2t64, say), apt/dnf refuses the whole
    # transaction and the REQUIRED packages never get installed either.
    local pm_upper core_var optional_var
    pm_upper="$(echo "${pm}" | tr '[:lower:]' '[:upper:]')"
    core_var="CORE_PACKAGES_${pm_upper}[@]"
    optional_var="OPTIONAL_PACKAGES_${pm_upper}[@]"
    local -a core=("${!core_var}") optional=("${!optional_var}")

    local -a miss_core=() miss_opt=()
    mapfile -t miss_core < <(missing_packages "${pm}" "${core[@]}")
    mapfile -t miss_opt < <(missing_packages "${pm}" "${optional[@]}")

    if [[ "${#miss_core[@]}" -eq 0 ]]; then
      echo "[deps] Required packages: all ${#core[@]} present"
    else
      echo "[deps] Required packages MISSING (${#miss_core[@]} of ${#core[@]}) -- the build needs these:"
      printf '         %s\n' "${miss_core[@]}"
      echo "[deps] Install with:"
      echo "         $(install_hint "${pm}" "${miss_core[@]}")"
    fi

    if [[ "${#miss_opt[@]}" -eq 0 ]]; then
      echo "[deps] Optional packages: all ${#optional[@]} present"
    else
      echo "[deps] Optional packages missing (${#miss_opt[@]} of ${#optional[@]}) -- only tests, packaging and the sandboxed run targets:"
      printf '         %s\n' "${miss_opt[@]}"
      echo "[deps] Install separately if you need them (failures here are harmless):"
      echo "         $(install_hint "${pm}" "${miss_opt[@]}")"
    fi
  fi

  # Optional tooling: only needed for specific targets, never blocking.
  echo "[deps] Optional: node=$(command -v node || echo missing)" \
       "npm=$(command -v npm || echo missing)" \
       "npx=$(command -v npx || echo missing)" \
       "gdb=$(command -v gdb || echo missing)" \
       "valgrind=$(command -v valgrind || echo missing)" \
       "proot=$(command -v proot || echo missing)"
  if [[ -d "${VENV_DIR}" ]]; then
    echo "[deps] Virtualenv detected at ${VENV_DIR}"
  else
    echo "[deps] Virtualenv missing (created by 'make deps')"
  fi
}

ensure_log

case "${MODE}" in
  auto|update)
    PM=$(pm_detect)
    if [[ "${EUID}" -eq 0 ]]; then
      SUDO_BIN=()
    else
      SUDO_BIN=(sudo)
    fi
    if [[ "${PM}" == "unknown" ]]; then
      echo "[deps] Unknown package manager. Install prerequisites manually." | tee -a "${LOG_FILE}"
      # Package names cannot be verified here, but the commands the build
      # invokes still can -- otherwise a host without a compiler or downloader
      # would pass this step and fail much later.
      if [[ "${SKIP_DEP_CHECK:-0}" == "1" ]]; then
        echo "[deps] SKIP_DEP_CHECK=1 gesetzt - Voraussetzungspruefung uebersprungen." | tee -a "${LOG_FILE}"
      elif ! require_prerequisites "${PM}" 2>&1 | tee -a "${LOG_FILE}"; then
        exit 1
      fi
    else
      PM_UPPER="$(echo "${PM}" | tr '[:lower:]' '[:upper:]')"
      PACKAGES_VAR="SYSTEM_PACKAGES_${PM_UPPER}[@]"
      CORE_VAR="CORE_PACKAGES_${PM_UPPER}[@]"
      OPTIONAL_VAR="OPTIONAL_PACKAGES_${PM_UPPER}[@]"
      PACKAGES=("${!PACKAGES_VAR}")
      CORE_PACKAGES=("${!CORE_VAR}")
      OPTIONAL_PACKAGES=("${!OPTIONAL_VAR}")
      # Installing needs root. As an ordinary user the packages are only
      # reported: reaching for sudo on somebody's workstation is not this
      # script's decision to make, and that is why SUDO_BIN was computed above
      # and never used. A host that has already decided says so explicitly with
      # DEPS_ALLOW_SUDO=1 -- which is what CI does on a runner, where the only
      # alternative is copying the whole package list into a workflow file, and
      # hand-copied lists are precisely what goes stale.
      DEPS_CAN_INSTALL=0
      if [[ "${EUID}" -eq 0 ]]; then
        DEPS_CAN_INSTALL=1
      elif [[ "${DEPS_ALLOW_SUDO:-0}" == "1" ]]; then
        if sudo -n true 2>/dev/null; then
          DEPS_CAN_INSTALL=1
        else
          echo "[deps] DEPS_ALLOW_SUDO=1 gesetzt, aber sudo verlangt ein Passwort." \
            | tee -a "${LOG_FILE}"
          echo "[deps] DEPS_ALLOW_SUDO=1 is set, but sudo asks for a password;" \
            "nothing was installed." | tee -a "${LOG_FILE}"
        fi
      fi
      if [[ "${DEPS_CAN_INSTALL}" -eq 1 ]]; then
        # Two transactions on purpose: a single unavailable OPTIONAL package
        # (e.g. libfuse2 renamed to libfuse2t64) would otherwise abort the whole
        # installation under `set -e` and take the core packages with it.
        pm_install "${PM}" "${CORE_PACKAGES[@]}" | tee -a "${LOG_FILE}"
        if ! pm_install "${PM}" "${OPTIONAL_PACKAGES[@]}" 2>&1 | tee -a "${LOG_FILE}"; then
          echo "[deps] Warning: some optional packages could not be installed." \
            "Tests, packaging or the sandboxed run targets may be unavailable." \
            | tee -a "${LOG_FILE}"
        fi
      fi
      # Report optional gaps without blocking: these only affect tests,
      # packaging and the sandboxed run targets.
      MISSING_OPTIONAL=()
      mapfile -t MISSING_OPTIONAL < <(missing_packages "${PM}" "${OPTIONAL_PACKAGES[@]}")
      if [[ "${#MISSING_OPTIONAL[@]}" -gt 0 ]]; then
        {
          echo "[deps] Hinweis: optionale Pakete fehlen (Tests/Packaging/Sandbox-Run):"
          echo "[deps] Note: optional packages missing (tests/packaging/sandboxed run):"
          printf '         %s\n' "${MISSING_OPTIONAL[@]}"
          echo "         $(install_hint "${PM}" "${MISSING_OPTIONAL[@]}")"
        } | tee -a "${LOG_FILE}"
      fi
      # Verify instead of assuming: an install may have failed partially, and
      # where none was attempted nothing is there at all. Either way the build
      # must not continue on an incomplete host.
      if [[ "${SKIP_DEP_CHECK:-0}" == "1" ]]; then
        echo "[deps] SKIP_DEP_CHECK=1 gesetzt - Voraussetzungspruefung uebersprungen." | tee -a "${LOG_FILE}"
      elif ! require_prerequisites "${PM}" "${CORE_PACKAGES[@]}" 2>&1 | tee -a "${LOG_FILE}"; then
        exit 1
      fi
    fi
    create_venv 2>&1 | tee -a "${LOG_FILE}"
    ;;
  doctor)
    doctor_report | tee -a "${LOG_FILE}"
    ;;
  *)
    echo "Unsupported mode: ${MODE}" >&2
    exit 1
    ;;
esac
