# Quickstart

## Quick Navigation

- [Project Overview](README.en.md)
- [Quickstart](QUICKSTART.en.md) *(this page)*
  - [1. Clone the repository](#1-clone-the-repository)
  - [2. Bootstrap dependencies + first build](#2-bootstrap-dependencies--first-build)
  - [3. Rebuild Neutrino](#3-rebuild-neutrino-incremental)
  - [4. Start Neutrino](#4-start-neutrino)
    - [4.1 Standard (host wrapper)](#41-standard-host-wrapper)
    - [4.1a Optional: systemd-nspawn/proot](#41a-optional-systemd-nspawnproot-isolated)
    - [4.2 Direct host launch](#42-direct-host-launch-manual)
    - [4.3 Rootless smoke test (proot)](#43-rootless-smoke-test-proot)
    - [4.4 Debugging & sanitizer runs](#44-debugging--sanitizer-runs)
  - [5. Execute smoke tests](#5-execute-smoke-tests)
  - [6. Generate packages](#6-generate-packages-optional)
- [Testing Guide](TESTING.en.md)
- [Packaging Guide](PACKAGING.en.md)
- [Hardware Notes](HARDWARE.en.md)
- Prefer German? See [QUICKSTART.de.md](QUICKSTART.de.md)

### 1. Clone the repository
```bash
git clone https://github.com/tuxbox-neutrino/neutrino-generic-build.git
cd neutrino-generic-build
```

All following commands are run **from the repository root**.

### 2. Bootstrap dependencies + first build

Three steps: **check → install → build.**

1. **Check without changing anything.** Reports missing commands and packages
   and prints a ready-to-paste install command:
   ```bash
   make deps-doctor
   ```
2. **Install the system packages** — `deps-doctor` prints the ready-to-run
   command. Use the one under **"Required packages"**; the second one under
   "Optional packages" is only needed for tests, packaging and the sandboxed run
   targets, and may fail harmlessly. For example:
   ```bash
   sudo apt-get update && sudo apt-get install -y build-essential git ...
   ```
3. **Build** (as your normal user):
   ```bash
   make bootstrap
   ```

> **Why not `sudo make deps`?** `deps` does more than install packages: it also
> creates `.venv/` and builds libdvbsi++ into `artifacts/sysroot/`. Under `sudo`
> those end up owned by `root`, and the next step as your normal user then fails
> on permissions. Only the package installation needs root — and that is exactly
> what the command from step 2 does.

`bootstrap` triggers `deps` and then builds the Neutrino core.

> **About `ALLOW_NON_ROOT=1`:** it does *not* install anything. It only permits
> the rootless targets to run. If mandatory packages are missing, the build now
> stops **up front** with the list of missing packages and the matching
> `apt-get`/`dnf` command, instead of failing deep inside `configure` later.
> Install them, then run `make bootstrap` again.
> To bypass the check deliberately: `SKIP_DEP_CHECK=1 make bootstrap`.

### 3. Rebuild Neutrino (incremental)
- Standard rebuild after code changes:  
  ```bash
  make neutrino
  ```
- If configure/prefix changed: run `make neutrino-clean` first.

### Optional: alternate GCC + debug builds

#### Choosing a GCC version

**Using an installed GCC version:**

⚠️ **IMPORTANT:** `TOOLCHAIN_GCC_VERSION` must be consistent across ALL builds!

**Best Practice (recommended):**
```bash
# Option 1: Via Makefile.local (persistent for all builds)
echo "TOOLCHAIN_GCC_VERSION := 15" >> Makefile.local

# Then build normally
make bootstrap
make neutrino
make plugins
```

**Alternative methods:**

```bash
# Option 2: As environment variable (session-wide)
export TOOLCHAIN_GCC_VERSION=15
make bootstrap
make neutrino
make plugins

# Option 3: Per target (ONLY for quick tests! Not for production!)
TOOLCHAIN_GCC_VERSION=15 make neutrino
```

**Convenience targets (for debug builds):**
```bash
make neutrino-gcc-15  # Sets DEBUG_BUILD=1 + runtime-sync
```

Other options: `TOOLCHAIN_GCC_VERSION=14`, `13`, `12`, ..., `8`; `system` uses host GCC.

**Building GCC from source:**
```bash
# Via Makefile target
make build-gcc-15      # Builds GCC 15.2.0
make build-gcc-14      # Builds GCC 14.2.0
make build-gcc-13      # Builds GCC 13.2.0

# Or directly via script (deletion requires explicit opt-in)
BUILD_GCC_ALLOW_DELETE=1 ./scripts/build_gcc.sh --version 15.2.0 --jobs $(nproc)
```
Note: the script never deletes an existing source tree by accident. Without
`BUILD_GCC_ALLOW_DELETE=1` it **refuses to run at all** and exits, telling you to
set that variable or pass `--keep-sources`. With `--keep-sources` it keeps the
sources and rebuilds only the build directory.

Output under `artifacts/toolchains/gcc-15.2.0/bin/gcc-15`. Supported versions: 8.5.0 through 15.2.0 (8/9 automatically disable libsanitizer).

When `TOOLCHAIN_GCC_VERSION` is set, the build now actively checks that CC/CXX really match that version. On mismatch the configure step aborts with a hint to clean stamps/build dirs (e.g. `sources/ffmpeg-*/build`, `build/neutrino`) and rerun `make TOOLCHAIN_GCC_VERSION=<ver> bootstrap`.

### Optional: FFmpeg version selection

- Default: FFmpeg is built locally into the sysroot (`PREFERRED_FFMPEG_VERSION`, default 5.1.4). `FFMPEG_VERSION` overrides per invocation.
- Build with the default: `make deps-ffmpeg` (builds locally; host version is ignored by default).
- Pin a specific release: `make deps-ffmpeg-6.1.1` (replace with desired version) → **always** builds that version.
- Use the host version (faster, but system-dependent): `FFMPEG_USE_SYSTEM=1 make deps` or `FFMPEG_USE_SYSTEM=1 make bootstrap` (builds only if the host version is missing/mismatched).
- Convenience alias: `make deps-ffmpeg5` → `deps-ffmpeg-5.1.4`.
- Extra flags for `./configure`: `FFMPEG_CONFIGURE_FLAGS="--enable-gpl --enable-nonfree" make deps-ffmpeg-7.0.2` (e.g. for additional codecs/hwaccels).
- https: the local build is configured with `--enable-gnutls` (host package `libgnutls28-dev` or `gnutls-devel`). Opt out with `FFMPEG_CONFIGURE_FLAGS=--disable-gnutls`; the user flags come after the built-in line and have the last word in FFmpeg's `configure`.
- A changed configure invocation (flags, compiler, the calling shell's exported CPPFLAGS/CFLAGS/CXXFLAGS/LDFLAGS/PKG_CONFIG_PATH — so also a switch to `neutrino-debug`/`neutrino-asan`, or a different environment) is detected on the next `make neutrino` or `make deps-ffmpeg` and rebuilds FFmpeg from scratch; libstb-hal and Neutrino are then reconfigured and rebuilt against the new library as well. Deleting `sources/ffmpeg-*/build` is no longer needed for that.

Before installation, any existing FFmpeg in the sysroot (headers/libs/binaries/pkgconfig) is removed so exactly one version stays installed and Neutrino links consistently against it.

**⚠️ IMPORTANT: ABI Compatibility and Clean Builds**

When switching GCC versions, **all dependent components must be rebuilt** to avoid ABI incompatibilities:

```bash
# 1. Clean old artifacts
make distclean              # Removes everything including GCC toolchains
# or
make distclean-keep-toolchains  # Keeps GCC toolchains (saves ~1h build time)

# 2. Set GCC version persistently (recommended!)
echo "TOOLCHAIN_GCC_VERSION := 15" >> Makefile.local

# 3. If GCC was built from source: extend PATH
export PATH="$PWD/artifacts/toolchains/gcc-15.2.0/bin:$PATH"

# 4. Rebuild everything
make bootstrap
```

**Why?** Different GCC versions have incompatible C++ ABIs (libstdc++). If Neutrino is built with GCC 15 but links against FFmpeg/LuaJIT built with GCC 12 → **💥 Runtime errors or crashes**

**Best practices:**
- ✅ **Set `TOOLCHAIN_GCC_VERSION` in `Makefile.local`** (guarantees consistency)
- ✅ Always start with `distclean` or `distclean-keep-toolchains` when switching GCC
- ✅ For experiments: Use separate build directories
- ✅ `make help` shows all available toolchain targets
- ❌ **DON'T:** Use different GCC versions per target!

**Toolchain patches:**
Place fixes in `files/gcc-<version>/toolchain/*.patch`; `scripts/build_gcc.sh` applies them after unpacking. Neutrino-specific patches: `files/gcc-<version>/neutrino/*.patch`.

**Debug/sanitizer convenience:**
`make neutrino-debug`, `make neutrino-asan`, `make neutrino-tsan`.

### Optional: custom defaults (Makefile.local)
- Copy `Makefile.local.sample` → `Makefile.local` and uncomment what you need.
- Common overrides:
  - `ALLOW_NON_ROOT := 1` for rootless targets (`deps`, `run-now`, `run-gdb`, …).
  - `TOOLCHAIN_GCC_VERSION := 15` or custom `CC`/`CXX` paths.
  - `DEBUG_BUILD`, `ENABLE_ASAN/TSAN/UBSAN` for debug/sanitizers.
  - `NEUTRINO_RUN_WRAPPER := gdb --args` to force gdb/valgrind for `make run`/`run-now`/`run-nspawn`.
  - Paths such as `NEUTRINO_INSTALL_DIR`, `NEUTRINO_RUNTIME_PREFIX`, ports/host (`NEUTRINO_WEB_PORT`, `NEUTRINO_WEB_HOST`).
  - Note: `NEUTRINO_WEB_PORT/NEUTRINO_WEB_HOST` are only used when `nhttpd.conf` is created by `make runtime-sync`; existing values are not overwritten.
- Alternatively, set them per invocation via environment (overrides `?=` defaults), e.g.:
  ```bash
  export TOOLCHAIN_GCC_VERSION=15
  export ALLOW_NON_ROOT=1
  make neutrino
  ```

### Apply plugin updates
Whenever you modify the Mediathek plugin, stick to this sequence:

```bash
make clean-plugins   # optional, wipes stale artifacts in artifacts/ and root/usr/var
make clean-plugin-neutrino-mediathek  # optional, cleans just this plugin
make list-cleanable-plugins  # optional, shows available plugin names
make plugins
make runtime-sync
```

Only then will the staged `root/usr` tree contain the newly built files.

### 4. Start Neutrino

**Start here: `make run`, as your normal user.**

```bash
make run
```

That is the whole first launch. No `sudo`, no configuration. The wrapper exports
`SIMULATE_FE=1`, so Neutrino comes up without any tuner hardware, walks through
its startup wizard and opens its window. Its web interface is then at
<http://localhost:31344>. Everything except live TV works this way, and it is
what the smoke tests expect.

> **Do not start Neutrino with `sudo`.** It is not needed, and it usually fails:
> a root process has no authorization for your X11/Wayland display, so the window
> never appears. Root is only ever needed to reach real devices — see
> [Hardware Notes](HARDWARE.en.md), which explains how to get tuner and input
> access through group membership instead.

Once that works, these are the other ways to launch, for when you need them:

- `make run`: Host wrapper without isolation, fastest startup (alias for `make run-direct`).
- `make run-nspawn`: systemd-nspawn/proot sandbox, best isolation, mirrors target box layout.
- `make run-direct`: Explicit host wrapper variant (identical to `make run`).
- `ALLOW_NON_ROOT=1 make run-now`: proot sandbox when sudo is unavailable; falls back to host if proot is missing.

> Script naming: `scripts/run-neutrino.sh` (dash) is the lightweight host/GCC-runtime wrapper (`make run`/`run-direct`). `scripts/run_neutrino.sh` (underscore) wraps proot/systemd-nspawn and is used by `make run-nspawn`/`run-now`.

#### 4.1 Standard (host wrapper)
```bash
make run
# or explicitly:
make run-direct
```
Recommended for fast development: starts Neutrino directly on the host without isolation. The target automatically triggers `make runtime-sync` beforehand; make sure `make neutrino` has been run at least once, otherwise you'll get a helpful hint.

#### 4.1a Optional: systemd-nspawn/proot (isolated)
```bash
make run-nspawn
```
Uses `systemd-nspawn` or `proot` for clean isolation, mirrors target box layout. Requires sudo or proot. The target automatically triggers `make runtime-sync` beforehand.

#### 4.2 Direct host launch (manual)
```bash
make run-direct
# or manually with the GCC runtime wired:
./scripts/run-neutrino.sh
```
Keeps `root/usr` in sync, seeds the default configuration files, and executes a host wrapper. The wrapper sets `LD_LIBRARY_PATH` (including `root/usr/lib/compat` plus the GCC runtime from `artifacts/toolchains/gcc-*`) and exports `SIMULATE_FE=1` before delegating to `neutrino`, so it survives the startup wizard even without real tuners and avoids `GLIBCXX_*` complaints on older host libstdc++. As with the other run targets, a `runtime-sync` is performed automatically and therefore requires a prior `make neutrino` build. For later manual launches without `make run-direct`, use `./scripts/run-neutrino.sh` (override via TOOLCHAIN_GCC_VERSION/TOOLCHAIN_PREFIX if needed).

#### 4.3 Rootless smoke test (proot)
```bash
sudo apt install proot          # once, if you plan to skip sudo
ALLOW_NON_ROOT=1 make run-now
```
Leverages `proot` as a chroot alternative—handy for quick checks on systems without sudo access. If `proot` is missing the target falls back to the host wrapper (`run-direct`); install it via `sudo apt install proot` (or `make tools-install-proot`) to regain the sandboxed variant. As before, `runtime-sync` runs automatically right before launching, so a prior `make neutrino` is mandatory.

> ℹ️ Neutrino communicates shutdown/reboot requests via exit code 1 or 2. The wrappers print a note for these codes but do not treat them as failures.

#### 4.4 Debugging & sanitizer runs
- Quick debug build:  
  ```bash
  make neutrino-debug
  ALLOW_NON_ROOT=1 make run-gdb-debug
  ```
- Memory leaks/UB:  
  ```bash
  make neutrino-asan
  ALLOW_NON_ROOT=1 make run-asan          # ASan/UBSan
  make DEBUG_BUILD=1 ENABLE_UBSAN=1 neutrino   # UBSan-only build
  ALLOW_NON_ROOT=1 make run-memcheck      # Valgrind alternative, logs under logs/valgrind
  ```
- Thread issues:  
  ```bash
  make neutrino-tsan
  ALLOW_NON_ROOT=1 make run-tsan          # TSAN
  ALLOW_NON_ROOT=1 make run-helgrind      # Valgrind/Helgrind
  ```
- Custom wrapper for runs:  
  ```bash
  NEUTRINO_RUN_WRAPPER="gdb --args" make run
  NEUTRINO_RUN_WRAPPER="valgrind --tool=memcheck" make run-now
  ```
  (works for run/run-now/run-nspawn; gdb knobs such as `NEUTRINO_GDB_AUTORUN` still apply).

### 5. Execute smoke tests

The smoke test suite fires a compact set of automated GUI/web scenarios (startup,
menu navigation, basic HTTP API calls) to verify that the freshly built image
behaves as expected.

**Two things have to be in place first, or the run is meaningless:**

1. **Neutrino must already be running.** The GUI and web checks attach to a live
   instance; they do not start one. Leave `make run` (or `run-nspawn`,
   `run-now`, `run-direct`) going in another terminal.
2. **Node.js/npm and Playwright** must be installed for the web half
   (`npx playwright install`). Without them the web tests are skipped, not run —
   a green result then says less than it appears to.

Neither is needed for `make test-shell`, which tests the build logic itself and
runs anywhere with no Neutrino and no network.

```bash
make test-shell   # build-logic unit tests, no prerequisites
make test         # full suite, needs a running Neutrino (see above)
```

### 6. Generate packages (optional)
```bash
make package-appimage
make package-deb
make package-static
```
