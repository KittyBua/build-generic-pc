#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${NEUTRINO_INSTALL_DIR:-}"
OUTPUT_DIR="${DEB_OUTPUT_DIR:-artifacts/deb}"
NEUTRINO_PREFIX="${NEUTRINO_PREFIX:-/usr}"
PACKAGE_NAME="${PACKAGE_NAME:-neutrino-generic-pc}"
VERSION_JSON=$(scripts/version_info.sh)
# The version goes in as version_info.sh reports it. Composing it here from base
# and slug produced "2026.8.27+git2026.8-32-g13ae2fa8b8", which dpkg silently
# splits at the last hyphen into upstream version "2026.8.27+git2026.8-32" plus
# Debian revision "g13ae2fa8b8" -- a revision this project never intended to
# have. The reported version carries no hyphen.
DEFAULT_VERSION=$(printf '%s' "${VERSION_JSON}" | python3 -c 'import sys,json;data=json.load(sys.stdin);print(data.get("package") or data.get("base") or "0.0.0")')
DEFAULT_FILE_VERSION=$(printf '%s' "${VERSION_JSON}" | python3 -c 'import sys,json;data=json.load(sys.stdin);print(data.get("slug") or "dev")')
PACKAGE_VERSION="${PACKAGE_VERSION:-$DEFAULT_VERSION}"
# The file is named from the slug, like the AppImage and the static bundle: the
# version keeps its '+' because dpkg wants it, the filename does not because
# release-asset uploads mangle it. A caller who pins PACKAGE_VERSION gets the
# same treatment applied to their value rather than a name that contradicts it.
if [[ "${PACKAGE_VERSION}" == "${DEFAULT_VERSION}" ]]; then
  PACKAGE_FILE_VERSION="${DEFAULT_FILE_VERSION}"
else
  PACKAGE_FILE_VERSION="$(printf '%s' "${PACKAGE_VERSION}" | tr '+' '.' | tr -c '[:alnum:]._-' '-')"
fi
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

if [[ -z "${INSTALL_DIR}" || ! -d "${INSTALL_DIR}" ]]; then
  echo "[deb] NEUTRINO_INSTALL_DIR invalid: ${INSTALL_DIR}" >&2
  exit 1
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "[deb] dpkg-deb missing. Install the dpkg package (dpkg-deb ships with it)." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

mkdir -p "${WORKDIR}/DEBIAN"
mkdir -p "${WORKDIR}${NEUTRINO_PREFIX}"
cp -a "${INSTALL_DIR}${NEUTRINO_PREFIX}/." "${WORKDIR}${NEUTRINO_PREFIX}/"

INSTALLED_SIZE=$(du -sk "${WORKDIR}${NEUTRINO_PREFIX}" | cut -f1)

# The locally built libavformat links libgnutls.so.30; the package name split
# in t64 between releases is what the alternative is for. The rest of this
# list is a hand-maintained minimum and knows nothing of the other libraries
# the staged tree needs -- generating it from the packaged ELF files is the
# real fix.
cat >"${WORKDIR}/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${PACKAGE_VERSION}
Section: misc
Priority: optional
Architecture: ${ARCH}
Maintainer: Neutrino Team <dev@neutrino>
Description: Neutrino generic-pc build (requires root for device access)
Installed-Size: ${INSTALLED_SIZE}
Depends: adduser, libstdc++6, libc6, libgcc-s1, libgnutls30t64 | libgnutls30
EOF

mkdir -p "${WORKDIR}/DEBIAN"
cat >"${WORKDIR}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
echo "Neutrino benötigt Root-Rechte für DVB/Input-Geräte."
echo "Neutrino requires root privileges for DVB/input devices."
echo "Bitte fügen Sie den Benutzer zu den Gruppen video,input,plugdev hinzu."
EOF
chmod 0755 "${WORKDIR}/DEBIAN/postinst"

mkdir -p "${OUTPUT_DIR}"
dpkg-deb --build "${WORKDIR}" "${OUTPUT_DIR}/${PACKAGE_NAME}_${PACKAGE_FILE_VERSION}_${ARCH}.deb"

echo "[deb] Paket erstellt unter ${OUTPUT_DIR}/${PACKAGE_NAME}_${PACKAGE_FILE_VERSION}_${ARCH}.deb"
