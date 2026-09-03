# Neutrino Generic Build (generic-pc)

Neutrino is an open-source digital TV UI. This repository provides a fully Make-driven build and test environment targeting desktop/laptop systems (x86_64 Linux).

## What gets built, and where it lands

`make bootstrap` runs four stages in order. Knowing the layout makes the rest of
this page, and any build error, much easier to read:

| Stage | What happens | Where it goes |
|---|---|---|
| Dependencies | Host packages are checked (`deps-doctor`) and installed on request | your system |
| Third party | FFmpeg, LuaJIT, giflib and libdvbsi++ are downloaded and compiled | `archive/` (tarballs), `sources/` (unpacked), `artifacts/sysroot/` (installed) |
| libstb-hal | The hardware abstraction layer, generic-pc variant | `build/libstb-hal/` → `artifacts/sysroot/` |
| Neutrino | The application itself | `build/neutrino/` → `artifacts/sysroot/` |

Then `make run` stages a runnable tree into `root/` and starts it.

Three of those directories are worth remembering:

- **`sources/`** — every external source tree, cloned or unpacked on demand. It
  is not tracked by git; nothing in it is carried in this repository. Neutrino,
  libstb-hal, FFmpeg and each plugin are fetched from their own upstream
  repositories the first time something needs them.
- **`artifacts/sysroot/`** — the staged install prefix everything builds against.
- **`build/`** — out-of-tree object directories, one per component.

`make clean` empties `build/`; `make distclean` removes the lot, including the
self-built toolchains. Neither touches your system packages.

### Disk and time

Measured on a completed default build (no sanitizer variants):

| | |
|---|---|
| `sources/` (FFmpeg, Neutrino, libstb-hal) | ~290 MB |
| `build/` | ~125 MB |
| `artifacts/sysroot/` | ~55 MB |
| `archive/` (downloaded tarballs) | ~17 MB |
| **Total for a first build** | **~500 MB**, so keep ~2 GB free |

The first `make bootstrap` compiles FFmpeg from source, and that single step
dominates the wall time — it is a complete media library, not a small
dependency. Measured here, a clean FFmpeg build took **about 8 minutes**. Note that it is
built with `-j1` on purpose (parallel FFmpeg builds race), so extra cores do
**not** speed this step up — expect a similar figure on any machine of
comparable single-core speed, and rather more on an older or throttled one.

This is the point at which people assume something has hung. It has not; it is
compiling. Later builds skip it entirely — a stamp file records that it is
installed — so a normal `make neutrino` cycle is far shorter.

For the whole of `make bootstrap`, measured end to end in a clean Debian 12
container with nothing but `git` and `make` preinstalled: **13 minutes**, ending
in a working `neutrino` binary.

`FFMPEG_USE_SYSTEM=1` can skip it, but only when your distribution ships
**exactly** the version in `FFMPEG_VERSION` (currently 5.1.4). Any other
version — newer, older, or merely patched — is rejected and the local build
runs anyway, so on most distributions this flag changes nothing.

The local FFmpeg is configured with `--enable-gnutls` so that `https` works —
streams hand out https segments and keys even behind a plain `http` entry
point. This needs `libgnutls28-dev` (dnf: `gnutls-devel`) on the host, see
below. To opt out, set `FFMPEG_CONFIGURE_FLAGS := --disable-gnutls` in
`Makefile.local` — also when you pick another TLS backend there
(`--enable-openssl`, `--enable-mbedtls`): FFmpeg's `configure` refuses two
backends at once; a changed configure line reconfigures and rebuilds on the
next `make neutrino` (or `make deps-ffmpeg`) by itself (libstb-hal and
Neutrino then rebuild against the new library as well).

## Prerequisites

- Linux x86_64 (generic-pc)
- `git` and `make`, so the very first command can be run at all.
- Root is needed only for the package installation. Use the command that
  `make deps-doctor` prints (`sudo apt-get install ...`) and do **not** run
  `make` itself under `sudo`, or `.venv/` and `artifacts/sysroot/` end up owned
  by root and the build fails on permissions.
- `ALLOW_NON_ROOT=1` merely permits the rootless targets; it installs nothing.
- `make deps-doctor` inspects the host without changing anything and names the
  missing packages together with a ready-to-paste install command. If mandatory
  packages are missing the build stops up front instead of failing later in
  `configure`.

### Debian/Ubuntu (apt)

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git pkg-config cmake ninja-build nasm automake autoconf libtool \
  curl rsync patch xz-utils \
  gettext libssl-dev libgnutls28-dev libcurl4-openssl-dev libjpeg-dev libpng-dev \
  libtiff-dev libglew-dev freeglut3-dev \
  libao-dev libmad0-dev libid3tag0-dev libgif-dev libflac-dev libreadline-dev \
  liblua5.3-dev lua5.3 libluajit-5.1-dev python3 python3-dev python3-venv python3-pip python3-opencv \
  python3-numpy tesseract-ocr libleptonica-dev xvfb x11-apps fbcat netpbm \
  fonts-dejavu-core libevdev-dev evtest proot libfuse2 appstream file \
  desktop-file-utils squashfs-tools libfreetype6-dev libsigc++-2.0-dev \
  libopenthreads-dev libvorbis-dev libogg-dev
```

Note: If `libfuse2` is unavailable, use `libfuse2t64`.

### Fedora/RHEL (dnf)

Note: use a Fedora release that ships prebuilt Python wheels for numpy and
opencv-python-headless (e.g. Fedora 41, Python 3.13). On the newest Fedora
(currently Python 3.14) those wheels do not exist yet, so `make deps` fails
while building them from source. CI pins fedora:41 for the same reason.

```bash
sudo dnf install -y \
  gcc gcc-c++ make git pkgconf-pkg-config cmake ninja-build nasm automake autoconf libtool \
  curl rsync patch xz \
  gettext openssl-devel gnutls-devel libcurl-devel libjpeg-turbo-devel \
  libpng-devel libtiff-devel glew-devel freeglut-devel libao-devel libmad-devel \
  libid3tag-devel giflib-devel flac-devel readline-devel lua-devel luajit-devel python3 \
  python3-devel python3-virtualenv python3-pip opencv opencv-devel tesseract tesseract-devel \
  leptonica-devel xorg-x11-server-Xvfb netpbm-progs dejavu-sans-fonts \
  libevdev-devel evtest fuse fuse-libs appstream file desktop-file-utils \
  squashfs-tools freetype-devel libsigc++20-devel OpenThreads-devel \
  libvorbis-devel libogg-devel
```

Note: system ffmpeg development packages are intentionally omitted above — the
build compiles ffmpeg locally by default. Install them only for a host-ffmpeg
build (`FFMPEG_USE_SYSTEM=1`): apt `libavformat-dev libswscale-dev
libswresample-dev`; dnf `ffmpeg-devel` (from RPMFusion on Fedora).

### Optional: GStreamer Playback (generic-pc)

Additional packages required for `--enable-gstreamer` (libstb-hal):

**Debian/Ubuntu (apt):**

```bash
sudo apt-get install -y \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev
```

**Fedora/RHEL (dnf):**

```bash
sudo dnf install -y \
  gstreamer1-devel gstreamer1-plugins-base-devel gstreamer1-plugins-bad-free-devel
```

Enable e.g. in `Makefile.local`:

```make
LIBSTB_HAL_CONFIGURE_FLAGS := --enable-gstreamer
```

Note: `make deps` will include these packages automatically when `LIBSTB_HAL_CONFIGURE_FLAGS` contains `--enable-gstreamer` (or use `ENABLE_GSTREAMER=1 make deps`).

Optional: Node.js/npm and Playwright (`npx`) are only required for web tests (`make test-web`).

## Quick Navigation

- [Project Overview](README.en.md)
- [Quickstart](QUICKSTART.en.md)
- [Testing Guide](TESTING.en.md)
- [Packaging Guide](PACKAGING.en.md)
