# Optional: ffmpeg build (installed into the staged prefix)

PREFERRED_FFMPEG_VERSION ?= 5.1.4
FFMPEG_VERSION ?= $(PREFERRED_FFMPEG_VERSION)
FFMPEG_FORCE ?= 0
FFMPEG_USE_SYSTEM ?= 0
FFMPEG_CONFIGURE_FLAGS ?=
FFMPEG_PREFIX := $(NEUTRINO_PREFIX)
FFMPEG_DESTDIR := $(NEUTRINO_INSTALL_DIR)
FFMPEG_INSTALL_ROOT := $(FFMPEG_DESTDIR)$(FFMPEG_PREFIX)
FFMPEG_PKGCONFIG := $(FFMPEG_DESTDIR)$(FFMPEG_PREFIX)/lib/pkgconfig
FFMPEG_HOST_VERSION := $(shell pkg-config --modversion libavcodec 2>/dev/null || true)
FFMPEG_NEEDS_BUILD := $(shell \
	if [ "$(FFMPEG_FORCE)" = "1" ]; then echo yes; \
	elif [ "$(FFMPEG_USE_SYSTEM)" = "1" ]; then \
		if [ -z "$(FFMPEG_HOST_VERSION)" ]; then echo yes; \
		elif [ "$(FFMPEG_HOST_VERSION)" != "$(FFMPEG_VERSION)" ]; then echo yes; \
		else echo no; fi; \
	else echo yes; fi)

ifeq ($(FFMPEG_NEEDS_BUILD),yes)
THIRD_PARTY_HOSTDEPS += $(FFMPEG_INSTALL_STAMP)
THIRD_PARTY_HOSTDEPS_TARGETS += ffmpeg
FFMPEG_ARCHIVE := $(ARCHIVE_DIR)/ffmpeg-$(FFMPEG_VERSION).tar.gz
FFMPEG_SRC_DIR := $(SOURCES_DIR)/ffmpeg-$(FFMPEG_VERSION)
FFMPEG_BUILD_DIR := $(FFMPEG_SRC_DIR)/build
FFMPEG_UNPACK_STAMP := $(FFMPEG_SRC_DIR)/.unpacked
FFMPEG_CONFIGURE_STAMP := $(FFMPEG_BUILD_DIR)/.configured
FFMPEG_BUILD_STAMP := $(FFMPEG_BUILD_DIR)/.built
FFMPEG_INSTALL_STAMP := $(FFMPEG_BUILD_DIR)/.installed
# The scratch copy of the record lives next to the unpack stamp, outside the
# build directory, so that starting the build directory over cannot take it
# along -- and it is named per make process: `make all` reaches this stamp
# from two makes at once (deps runs runtime-sync in a sub-make while neutrino
# is built alongside), and a shared scratch file would let one pass remove
# the other's copy before its comparison, which reads as a changed record.
# That keeps two passes over a *matched* record apart; two passes over a
# changed one would still configure the same directory at the same time,
# as the same invocation already builds the neutrino tree twice over.
FFMPEG_CONFIGURE_NEW := $(FFMPEG_SRC_DIR)/.configured.new.$(shell echo $$PPID)

.PHONY: deps-ffmpeg ffmpeg
deps-ffmpeg: $(FFMPEG_INSTALL_STAMP)
ffmpeg: deps-ffmpeg

$(FFMPEG_ARCHIVE):
	@$(MKDIR_P) $(ARCHIVE_DIR)
	@echo "[third-party] Downloading ffmpeg $(FFMPEG_VERSION)"
	@if command -v curl >/dev/null 2>&1; then \
		curl -fL --retry 3 -o $@ "https://www.ffmpeg.org/releases/ffmpeg-$(FFMPEG_VERSION).tar.gz" || { rm -f $@; exit 1; }; \
	elif command -v wget >/dev/null 2>&1; then \
		wget -O $@ "https://www.ffmpeg.org/releases/ffmpeg-$(FFMPEG_VERSION).tar.gz" || { rm -f $@; exit 1; }; \
	else \
		echo "Neither curl nor wget found; install one to download ffmpeg." >&2; \
		exit 1; \
	fi

$(FFMPEG_UNPACK_STAMP): $(FFMPEG_ARCHIVE)
	@$(MKDIR_P) $(SOURCES_DIR)
	@echo "[third-party] Unpacking ffmpeg $(FFMPEG_VERSION)"
	@tar -xf $< -C $(SOURCES_DIR)
	@touch $@

# The configure line as it is run. Recursive on purpose: the recipe always
# expanded FFMPEG_CONFIGURE_FLAGS at run time, and Makefile.local.post is read
# after this module, so an override made there has to keep working.
FFMPEG_CONFIGURE_ARGS = \
	--prefix=$(FFMPEG_PREFIX) \
	--enable-shared \
	--disable-static \
	--disable-debug \
	--disable-doc \
	--enable-pic \
	$(FFMPEG_CONFIGURE_FLAGS)

# What the stamp records: the whole invocation -- the compiler and the
# exported flags ffmpeg's configure reads from the environment (they end up
# in ffbuild/config.mak), passed explicitly so that record and call cannot
# drift apart. A switched TOOLCHAIN_GCC_VERSION, a DEBUG_BUILD or sanitizer
# variant and a moved sysroot are therefore all reasons to reconfigure; the
# variants rebuild ffmpeg with their own flags, as a first configure under
# them always did.
FFMPEG_CONFIGURE_ENV = CC="$(CC)" CXX="$(CXX)" CPPFLAGS="$(CPPFLAGS)" \
	CFLAGS="$(CFLAGS)" CXXFLAGS="$(CXXFLAGS)" LDFLAGS="$(LDFLAGS)" \
	PKG_CONFIG_PATH="$(PKG_CONFIG_PATH)"
FFMPEG_CONFIGURE_CMD = $(FFMPEG_CONFIGURE_ENV) ../configure $(FFMPEG_CONFIGURE_ARGS)
# The GNU make idiom for "this is a dry run": under -n the recipe is only
# printed, and under -q only expanded, so the record must not be written in
# either case.
FFMPEG_DRY_RUN = $(findstring n,$(firstword -$(MAKEFLAGS)))$(findstring q,$(firstword -$(MAKEFLAGS)))

$(FFMPEG_BUILD_DIR):
	@$(MKDIR_P) $@

# The stamp holds the invocation the build directory was configured with, and
# the recipe runs on every pass (FORCE) to compare it with the current one.
# Reconfigure exactly when the two differ or a source stamp is newer ($? less
# FORCE); a matching stamp is left untouched, so nothing downstream rebuilds.
# The decision is made on content, not on timestamps: a record and a stamp
# written within the same second on a filesystem with whole-second mtimes
# could otherwise swallow a change for good. The record goes through make's
# $(file) function and never through a shell -- the line is shell input for
# configure, and echoing it through a second shell would expand `$ORIGIN` or
# break on a quote that configure was meant to see. Under `make -n` and
# `make -q` nothing is written; a dry run does list the reconfigure and
# everything downstream of it as pending, and runs the sub-makes it meets in
# dry-run mode, because a comparison made inside the recipe is invisible to
# it -- and for the same reason `make -q` answers "out of date" for anything
# downstream of this stamp. cmp comes with diffutils, essential on Debian,
# in the dnf core list, and among the commands the deps preflight requires:
# without it every pass would read as a changed record and rebuild.
#
# A changed invocation starts the build directory over: ffmpeg's own
# dependency tracking notices a changed config.h, but not a changed compiler
# or CFLAGS, and objects from the old invocation would otherwise be linked
# into the new build. The one tree that keeps its objects is the one whose
# stamp is empty -- a tree from before the record, which says nothing about
# its old invocation and is reconfigured once. A tree with no stamp at all is
# in an unknown state (a fresh directory, or a wipe that did not finish) and
# is started over as well. The compiler guard runs on every pass: a no-op
# unless a version is pinned, and then exactly the check a switched
# toolchain needs before the reconfigure. Before this rule a flag edit was
# silently ignored by any tree that had already been configured.
$(FFMPEG_CONFIGURE_STAMP): $(FFMPEG_UNPACK_STAMP) FORCE | $(FFMPEG_BUILD_DIR)
	$(if $(FFMPEG_DRY_RUN),,$(file >$(FFMPEG_CONFIGURE_NEW),$(FFMPEG_CONFIGURE_CMD)))
	$(call ENFORCE_GCC_VERSION)
	@same=no; cmp -s $(FFMPEG_CONFIGURE_NEW) $@ 2>/dev/null && same=yes; \
	if [ -z "$(filter-out FORCE,$?)" ] && [ $$same = yes ]; then \
		rm -f $(FFMPEG_CONFIGURE_NEW); \
	else \
		if [ -f $@ ] && [ ! -s $@ ]; then \
			rm -f $@ $(FFMPEG_BUILD_STAMP) $(FFMPEG_INSTALL_STAMP); \
		else \
			if [ -f $@ ] && [ $$same = yes ]; then \
				echo "[third-party] ffmpeg sources were unpacked after the last configure; starting the build directory over"; \
			elif [ -f $@ ]; then \
				echo "[third-party] ffmpeg configure invocation changed; starting the build directory over"; \
			fi; \
			rm -rf "$(FFMPEG_BUILD_DIR)" && $(MKDIR_P) "$(FFMPEG_BUILD_DIR)"; \
		fi; \
		cd $(FFMPEG_BUILD_DIR) && $(FFMPEG_CONFIGURE_CMD) && \
		mv -f $(FFMPEG_CONFIGURE_NEW) $@; \
	fi

$(FFMPEG_BUILD_STAMP): $(FFMPEG_CONFIGURE_STAMP)
	@echo "[third-party] Building ffmpeg (using -j1 to avoid race conditions)"
	@stale_ffmpeg_objs=$$(find $(FFMPEG_BUILD_DIR) -type f -name '*.o' -size 0 -print); \
	if [ -n "$$stale_ffmpeg_objs" ]; then \
		echo "[third-party] Removing zero-byte ffmpeg objects from interrupted build"; \
		printf '%s\n' "$$stale_ffmpeg_objs" | while IFS= read -r stale_obj; do \
			rm -f "$$stale_obj" "$${stale_obj%.o}.d"; \
		done; \
	fi
	@$(MAKE) -C $(FFMPEG_BUILD_DIR) -j1
	@touch $@

$(FFMPEG_INSTALL_STAMP): $(FFMPEG_BUILD_STAMP)
	@echo "[third-party] Removing previous ffmpeg install from $(FFMPEG_INSTALL_ROOT)"
	@rm -rf \
		$(FFMPEG_INSTALL_ROOT)/include/libav* \
		$(FFMPEG_INSTALL_ROOT)/include/libsw* \
		$(FFMPEG_INSTALL_ROOT)/include/libpostproc* \
		$(FFMPEG_INSTALL_ROOT)/lib/libav* \
		$(FFMPEG_INSTALL_ROOT)/lib/libsw* \
		$(FFMPEG_INSTALL_ROOT)/lib/libpostproc* \
		$(FFMPEG_INSTALL_ROOT)/lib/pkgconfig/libav* \
		$(FFMPEG_INSTALL_ROOT)/lib/pkgconfig/libsw* \
		$(FFMPEG_INSTALL_ROOT)/lib/pkgconfig/libpostproc* \
		$(FFMPEG_INSTALL_ROOT)/bin/ff* \
		$(FFMPEG_INSTALL_ROOT)/share/ffmpeg || true
	@echo "[third-party] Installing ffmpeg into $(FFMPEG_DESTDIR)$(FFMPEG_PREFIX)"
	@$(MAKE) -C $(FFMPEG_BUILD_DIR) install DESTDIR=$(FFMPEG_DESTDIR)
	@touch $@
endif

.PHONY: deps-ffmpeg-force ffmpeg-force
deps-ffmpeg-force ffmpeg-force:
	@$(MAKE) FFMPEG_FORCE=1 deps-ffmpeg

.PHONY: deps-ffmpeg-% ffmpeg-%
deps-ffmpeg-% ffmpeg-%: ## Build ffmpeg <version> locally (always, ignores host version)
	@$(MAKE) FFMPEG_FORCE=1 FFMPEG_VERSION=$* deps-ffmpeg

.PHONY: deps-ffmpeg5 ffmpeg5
deps-ffmpeg5 ffmpeg5: ## Build ffmpeg 5.1.4 locally (always, ignores host version)
	@$(MAKE) deps-ffmpeg-5.1.4
