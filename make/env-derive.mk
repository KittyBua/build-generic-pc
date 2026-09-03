# Values derived from the env.mk defaults.
#
# Included AFTER Makefile.local so an override of one of the inputs
# (NEUTRINO_INSTALL_DIR, NEUTRINO_PREFIX, NEUTRINO_RUNTIME_PREFIX, N_PREFIX, ...)
# actually flows into the `:=` values computed here. env.mk (the defaults) is
# included before Makefile.local so a dependent override there can still
# reference those defaults.

# Every path here is prepended to its own previous value, and every one of
# them is exported. A sub-make ($(MAKE) neutrino from bootstrap, the debug and
# sanitizer variants, deps-ffmpeg-<ver>) therefore reads this file with the
# parent's result already in its environment, and used to prepend a second
# time: two -I and -L for the sysroot, the pkgconfig directory twice, the
# runtime bin directory twice in PATH. Harmless to the compiler, but not to
# anything that compares the values -- the ffmpeg configure stamp records
# them, and a level-1 make saw a different invocation than a level-0 one.
# So each entry goes in only when it is not there yet.
NEUTRINO_SYSROOT_PKGCONFIG := $(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/lib/pkgconfig
ifeq ($(filter $(NEUTRINO_SYSROOT_PKGCONFIG),$(subst :, ,$(PKG_CONFIG_PATH))),)
PKG_CONFIG_PATH := $(NEUTRINO_SYSROOT_PKGCONFIG)$(if $(PKG_CONFIG_PATH),:$(PKG_CONFIG_PATH))
endif
ifeq ($(filter $(NEUTRINO_RUNTIME_PREFIX)/lib,$(subst :, ,$(LD_LIBRARY_PATH))),)
LD_LIBRARY_PATH := $(NEUTRINO_RUNTIME_PREFIX)/lib$(if $(LD_LIBRARY_PATH),:$(LD_LIBRARY_PATH))
endif
# Two entries, two guards: the runtime prefix differs per variant, the
# scripts directory does not, and a variant sub-make needs its own bin in
# front even though scripts is already there.
ifeq ($(filter $(ROOT_DIR)/scripts,$(subst :, ,$(PATH))),)
PATH := $(ROOT_DIR)/scripts:$(PATH)
endif
ifeq ($(filter $(NEUTRINO_RUNTIME_PREFIX)/bin,$(subst :, ,$(PATH))),)
PATH := $(NEUTRINO_RUNTIME_PREFIX)/bin:$(PATH)
endif

# Resolve the Python interpreter and pip. Prefer the project venv, but only when
# the user has not chosen one. `$(origin PYTHON)` is 'undefined' unless PYTHON
# was set in Makefile.local, on the command line, or in the environment -- so a
# deliberate opt-out with `PYTHON := python3` survives, which an
# `ifeq ($(PYTHON),python3)` guard could not tell apart from the default.
ifeq ($(origin PYTHON),undefined)
ifneq ($(wildcard $(VENV_DIR)/bin/python),)
PYTHON := $(VENV_DIR)/bin/python
else
PYTHON := python3
endif
endif
ifeq ($(origin PIP),undefined)
ifneq ($(wildcard $(VENV_DIR)/bin/python),)
PIP := $(VENV_DIR)/bin/pip
else
PIP := pip3
endif
endif

# Same rule as for the search paths above: once, not once per make level.
CPPFLAGS ?=
NEUTRINO_SYSROOT_CPPFLAG := -I$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include
ifeq ($(filter $(NEUTRINO_SYSROOT_CPPFLAG),$(CPPFLAGS)),)
CPPFLAGS := $(NEUTRINO_SYSROOT_CPPFLAG) $(CPPFLAGS)
endif
LDFLAGS ?=
NEUTRINO_SYSROOT_LDFLAG := -L$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/lib
ifeq ($(filter $(NEUTRINO_SYSROOT_LDFLAG),$(LDFLAGS)),)
LDFLAGS := $(NEUTRINO_SYSROOT_LDFLAG) $(LDFLAGS)
endif

export ROOT_DIR SOURCES_DIR BUILD_DIR OUTPUT_DIR CACHE_DIR LOG_DIR VENV_DIR ARCHIVE_DIR
export NEUTRINO_GIT_URL NEUTRINO_BRANCH NEUTRINO_SRC_DIR NEUTRINO_BUILD_DIR NEUTRINO_INSTALL_DIR NEUTRINO_PREFIX
export NEUTRINO_WEB_PORT NEUTRINO_WEB_HOST
export NEUTRINO_EXIT_CODES NEUTRINO_EXIT_ACTION_FILE
export LIBSTB_HAL_CONFIGURE_FLAGS LIBSTB_HAL_DIR LIBSTB_HAL_BUILD_DIR
export PKG_CONFIG_PATH LD_LIBRARY_PATH PATH CPPFLAGS LDFLAGS NEUTRINO_LUA_FLAVOR
export PYTHON PIP NODE NPM GDB VALGRIND
export NEUTRINO_CONFIGURE_FLAGS NEUTRINO_BASE_CFLAGS NEUTRINO_WARN_OPTS NEUTRINO_WARN_OPTS_CXX
export NEUTRINO_CFLAGS_APPEND NEUTRINO_CXXFLAGS_APPEND NEUTRINO_GDB_AUTORUN NEUTRINO_GDB_COMMANDS
export N_PREFIX N_SYSCONFDIR N_LOCALSTATEDIR N_CONFIG_DIR N_CONTROLDIR N_CONTROLDIR_VAR
export N_DATADIR N_DATADIR_VAR N_FLAGDIR N_FONTDIR N_FONTDIR_VAR N_GAMES_DIR N_HOSTED_HTTPDDIR
export N_ICONS_DIR N_ICONS_DIR_VAR N_LIBDIR N_LOCALEDIR N_LOCALEDIR_VAR N_LOGODIR N_LOGODIR_VAR
export N_PLUGIN_DIR N_PLUGIN_DIR_VAR N_PLUGIN_DIR_MNT N_LUAPLUGIN_DIR N_LUAPLUGIN_DIR_VAR
export N_PRIVATE_HTTPDDIR N_PUBLIC_HTTPDDIR N_THEMESDIR N_THEMESDIR_VAR N_WEBRADIO_DIR
export N_WEBRADIO_DIR_VAR N_WEBTV_DIR N_WEBTV_DIR_VAR N_ZAPITDIR N_LCD4L_ICONSDIR N_LCD4L_ICONSDIR_VAR
export PLUGIN_PKG_CONFIG_SYSROOT_DIR PLUGIN_PKG_CONFIG_PATH PLUGIN_PROGRAM_PREFIX
export PLUGIN_PROGRAM_SUFFIX PLUGIN_PROGRAM_TRANSFORM_NAME PLUGIN_PROGRAM_NAME

.EXPORT_ALL_VARIABLES:

# Autoconf semantics rather than substring matching. libstb-hal enables
# GStreamer only when the resolved value is exactly "yes" -- its configure.ac
# tests `test "$$enable_gstreamer" = "yes"` -- so `--enable-gstreamer=no` and
# `--disable-gstreamer` are off, `--enable-gstreamer=1` is off too, and the last
# of these options on the line wins. `findstring --enable-gstreamer` read
# `--enable-gstreamer=no` as on: the package was asked to bundle GStreamer that
# was never built, and Neutrino was compiled with -DENABLE_GSTREAMER=1 against a
# libstb-hal without it -- the object-size mismatch that define exists to
# prevent. Recursive on purpose, because Makefile.local.post can still change
# the flags.
LIBSTB_HAL_GSTREAMER_OPT = $(lastword $(filter --enable-gstreamer --enable-gstreamer=% --disable-gstreamer,$(LIBSTB_HAL_CONFIGURE_FLAGS)))
LIBSTB_HAL_GSTREAMER = $(if $(filter --enable-gstreamer --enable-gstreamer=yes,$(LIBSTB_HAL_GSTREAMER_OPT)),1,)
