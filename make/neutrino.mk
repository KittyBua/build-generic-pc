# Build orchestration for libstb-hal and Neutrino core.

# Patch stamps depend on the helper too: a changed helper can classify the
# same patch differently, so the stamps must not survive an edit to it.
PATCH_HELPER := $(ROOT_DIR)/scripts/apply_patch_dir.sh

LIBSTB_HAL_GIT_URL ?= https://github.com/tuxbox-neutrino/libstb-hal.git
LIBSTB_HAL_GIT_REF ?= mpx
LIBSTB_HAL_VERSION ?= $(LIBSTB_HAL_GIT_REF)
LIBSTB_HAL_FORCE ?= 0
LIBSTB_HAL_CONFIGURE_STAMP := $(LIBSTB_HAL_BUILD_DIR)/.configured
LIBSTB_HAL_BUILD_STAMP := $(LIBSTB_HAL_BUILD_DIR)/.built
LIBSTB_HAL_INSTALL_STAMP := $(LIBSTB_HAL_BUILD_DIR)/.installed
LIBSTB_HAL_REF_STAMP := $(LIBSTB_HAL_BUILD_DIR)/.source-ref
# The stamp records "<ref> <resolved HEAD>". The sync runs on every invocation so
# a moved origin/<ref> or a manually switched source tree is picked up, but the
# stamp is only rewritten when the resolved commit actually changed. Depending on
# the .git directory instead would mark the stamp stale after every unrelated git
# operation in the source repo and cascade a full rebuild each time.

# Toolchain-independent fixes live in files/common; only genuinely compiler-
# specific patches belong under files/gcc-<version>. Without the common set a
# build with any TOOLCHAIN_GCC_VERSION other than the one that happens to have a
# directory would silently get an empty patch list.
LIBSTB_HAL_PATCH_DIRS := $(ROOT_DIR)/files/common/libstb-hal $(ROOT_DIR)/files/gcc-$(TOOLCHAIN_GCC_VERSION)/libstb-hal
LIBSTB_HAL_PATCH_FILES := $(sort $(foreach d,$(LIBSTB_HAL_PATCH_DIRS),$(wildcard $(d)/*.patch)))
LIBSTB_HAL_PATCH_STAMP := $(LIBSTB_HAL_DIR)/.patches-applied-$(TOOLCHAIN_GCC_VERSION)
LIBSTB_HAL_HOST_VERSION := $(shell pkg-config --modversion libstb-hal 2>/dev/null || true)
LIBSTB_HAL_NEEDS_BUILD := $(shell \
	if [ "$(LIBSTB_HAL_FORCE)" = "1" ]; then echo yes; \
	elif [ -z "$(LIBSTB_HAL_HOST_VERSION)" ]; then echo yes; \
	elif [ -n "$(LIBSTB_HAL_VERSION)" ] && [ "$(LIBSTB_HAL_HOST_VERSION)" != "$(LIBSTB_HAL_VERSION)" ]; then echo yes; \
	else echo no; fi)
LIBSTB_HAL_PREREQ := $(if $(filter yes,$(LIBSTB_HAL_NEEDS_BUILD)),$(LIBSTB_HAL_INSTALL_STAMP),)

NEUTRINO_SOURCE_STAMP := $(NEUTRINO_SRC_DIR)/.git/HEAD
NEUTRINO_CONFIGURE_STAMP := $(NEUTRINO_BUILD_DIR)/.configured
NEUTRINO_BUILD_STAMP := $(NEUTRINO_BUILD_DIR)/.built
NEUTRINO_INSTALL_STAMP := $(NEUTRINO_BUILD_DIR)/.installed
NEUTRINO_BUILD_DIR_STATIC := $(NEUTRINO_BUILD_DIR)-static
NEUTRINO_INSTALL_DIR_STATIC := $(NEUTRINO_INSTALL_DIR)-static
NEUTRINO_STATIC_STAMP := $(NEUTRINO_BUILD_DIR_STATIC)/.installed-static
# Propagate ENABLE_GSTREAMER to neutrino so that playback_hal.h dispatches to
# the correct (GStreamer) header — without this define neutrino compiles against
# the smaller playback_lib.h layout while linking the GStreamer implementation,
# causing a fatal object-size mismatch (ODR violation / heap overflow).
NEUTRINO_GSTREAMER_FLAGS = $(if $(LIBSTB_HAL_GSTREAMER),-DENABLE_GSTREAMER=1)

NEUTRINO_CFLAGS_ALL = $(strip $(NEUTRINO_BASE_CFLAGS) $(NEUTRINO_WARN_OPTS) $(NEUTRINO_CFLAGS_APPEND) $(SANITIZER_FLAGS) $(NEUTRINO_GSTREAMER_FLAGS))
NEUTRINO_CXXFLAGS_ALL = $(strip $(NEUTRINO_BASE_CFLAGS) $(NEUTRINO_WARN_OPTS) $(NEUTRINO_WARN_OPTS_CXX) $(NEUTRINO_CXXFLAGS_APPEND) $(SANITIZER_FLAGS) $(NEUTRINO_GSTREAMER_FLAGS))
NEUTRINO_RUNTIME_PREFIX_ABS := $(abspath $(NEUTRINO_RUNTIME_PREFIX))
NEUTRINO_RUNTIME_USR := $(NEUTRINO_RUNTIME_PREFIX_ABS)/usr
NEUTRINO_RUNTIME_SHARE := $(NEUTRINO_RUNTIME_USR)/share
NEUTRINO_RUNTIME_TUXBOX := $(NEUTRINO_RUNTIME_SHARE)/tuxbox
NEUTRINO_RUNTIME_VAR := $(NEUTRINO_RUNTIME_USR)/var/tuxbox

NEUTRINO_CONFIGURE_COMMON_FLAGS := \
	--with-configdir=$(NEUTRINO_RUNTIME_VAR)/config \
	--with-zapitdir=$(NEUTRINO_RUNTIME_VAR)/config/zapit \
	--with-datadir=$(NEUTRINO_RUNTIME_TUXBOX) \
	--with-datadir_var=$(NEUTRINO_RUNTIME_VAR) \
	--with-controldir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/control \
	--with-controldir_var=$(NEUTRINO_RUNTIME_VAR)/control \
	--with-fontdir=$(NEUTRINO_RUNTIME_SHARE)/fonts \
	--with-fontdir_var=$(NEUTRINO_RUNTIME_VAR)/fonts \
	--with-gamesdir=$(NEUTRINO_RUNTIME_TUXBOX)/games \
	--with-libdir=$(NEUTRINO_RUNTIME_USR)/lib/tuxbox \
	--with-plugindir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/plugins \
	--with-plugindir_var=$(NEUTRINO_RUNTIME_VAR)/plugins \
	--with-plugindir_mnt=$(NEUTRINO_RUNTIME_VAR)/plugins \
	--with-luaplugindir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/luaplugins \
	--with-luaplugindir_var=$(NEUTRINO_RUNTIME_VAR)/luaplugins \
	--with-webradiodir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/webradio \
	--with-webradiodir_var=$(NEUTRINO_RUNTIME_VAR)/neutrino/webradio \
	--with-webtvdir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/webtv \
	--with-webtvdir_var=$(NEUTRINO_RUNTIME_VAR)/neutrino/webtv \
	--with-localedir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/locale \
	--with-localedir_var=$(NEUTRINO_RUNTIME_VAR)/neutrino/locale \
	--with-themesdir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/themes \
	--with-themesdir_var=$(NEUTRINO_RUNTIME_VAR)/neutrino/themes \
	--with-iconsdir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/icons \
	--with-iconsdir_var=$(NEUTRINO_RUNTIME_VAR)/neutrino/icons \
	--with-lcd4liconsdir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/lcd/icons \
	--with-lcd4liconsdir_var=$(NEUTRINO_RUNTIME_VAR)/neutrino/lcd/icons \
	--with-logodir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/icons/logo \
	--with-logodir_var=$(NEUTRINO_RUNTIME_VAR)/neutrino/icons/logo \
	--with-private_httpddir=$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/httpd \
	--with-public_httpddir=$(NEUTRINO_RUNTIME_VAR)/neutrino/httpd \
	--with-hosted_httpddir=$(NEUTRINO_RUNTIME_VAR)/neutrino/httpd/hosted \
	--with-flagdir=$(NEUTRINO_RUNTIME_VAR)/etc

STB_HAL_INCLUDE_DIR := $(LIBSTB_HAL_DIR)/include
STB_HAL_LIBRARY_DIR := $(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/lib

NEUTRINO_LUA_PREREQ :=
ifneq ($(strip $(LUA_DEP_STAMP)),)
NEUTRINO_LUA_PREREQ := $(LUA_DEP_STAMP)
endif
NEUTRINO_OPTIONAL_DEPS := $(THIRD_PARTY_HOSTDEPS)
NEUTRINO_PATCH_DIRS := $(ROOT_DIR)/files/common/neutrino $(ROOT_DIR)/files/gcc-$(TOOLCHAIN_GCC_VERSION)/neutrino
NEUTRINO_PATCH_FILES := $(sort $(foreach d,$(NEUTRINO_PATCH_DIRS),$(wildcard $(d)/*.patch)))
NEUTRINO_PATCH_STAMP := $(NEUTRINO_SRC_DIR)/.patches-applied-$(TOOLCHAIN_GCC_VERSION)

.PHONY: libstb-hal neutrino neutrino-static neutrino-clean neutrino-distclean

libstb-hal: $(LIBSTB_HAL_PREREQ) ## Build the libstb-hal hardware abstraction library

ifeq ($(LIBSTB_HAL_NEEDS_BUILD),yes)
$(LIBSTB_HAL_DIR)/.git:
	@$(MKDIR_P) $(SOURCES_DIR)
	@if [ ! -d "$(LIBSTB_HAL_DIR)/.git" ]; then \
		echo "[libstb-hal] Cloning $(LIBSTB_HAL_GIT_URL)"; \
		git clone $(LIBSTB_HAL_GIT_URL) $(LIBSTB_HAL_DIR); \
		echo "[libstb-hal] Checking out $(LIBSTB_HAL_GIT_REF)"; \
		git -C $(LIBSTB_HAL_DIR) fetch origin $(LIBSTB_HAL_GIT_REF) >/dev/null 2>&1 || true; \
		git -C $(LIBSTB_HAL_DIR) checkout $(LIBSTB_HAL_GIT_REF) >/dev/null 2>&1 || true; \
	else \
		echo "[libstb-hal] Using existing source tree at $(LIBSTB_HAL_DIR)"; \
	fi

.PHONY: libstb-hal-source-sync
libstb-hal-source-sync: | $(LIBSTB_HAL_DIR)/.git $(LIBSTB_HAL_BUILD_DIR)
	@current_branch="$$(git -C $(LIBSTB_HAL_DIR) symbolic-ref --short -q HEAD || true)"; \
	head_sha="$$(git -C $(LIBSTB_HAL_DIR) rev-parse HEAD)"; \
	want_sha="$$(git -C $(LIBSTB_HAL_DIR) rev-parse --verify --quiet "$(LIBSTB_HAL_GIT_REF)^{commit}" || true)"; \
	if [ -z "$$want_sha" ]; then \
		want_sha="$$(git -C $(LIBSTB_HAL_DIR) rev-parse --verify --quiet "refs/remotes/origin/$(LIBSTB_HAL_GIT_REF)^{commit}" || true)"; \
	fi; \
	ref_exists="$$want_sha"; \
	if [ -z "$$ref_exists" ]; then \
		ref_exists="$$(git -C $(LIBSTB_HAL_DIR) for-each-ref --count=1 --format='%(objectname)' \
			"refs/remotes/*/$(LIBSTB_HAL_GIT_REF)")"; \
	fi; \
	if [ "$$current_branch" = "$(LIBSTB_HAL_GIT_REF)" ]; then \
		if ! git -C $(LIBSTB_HAL_DIR) diff --quiet --ignore-submodules HEAD -- || \
		   ! git -C $(LIBSTB_HAL_DIR) diff --cached --quiet --ignore-submodules; then \
			echo "[libstb-hal] NOTE: working tree has local changes; keeping them and skipping" >&2; \
			echo "[libstb-hal]       the update from origin/$(LIBSTB_HAL_GIT_REF). Commit or stash to resume tracking." >&2; \
		else \
			if git -C $(LIBSTB_HAL_DIR) remote get-url origin >/dev/null 2>&1; then \
				git -C $(LIBSTB_HAL_DIR) fetch origin $(LIBSTB_HAL_GIT_REF) >/dev/null 2>&1 || true; \
			fi; \
			if git -C $(LIBSTB_HAL_DIR) show-ref --verify --quiet refs/remotes/origin/$(LIBSTB_HAL_GIT_REF); then \
				echo "[libstb-hal] Updating $(LIBSTB_HAL_GIT_REF) from origin"; \
				git -C $(LIBSTB_HAL_DIR) merge --ff-only refs/remotes/origin/$(LIBSTB_HAL_GIT_REF) >/dev/null || \
					echo "[libstb-hal] WARNING: cannot fast-forward $(LIBSTB_HAL_GIT_REF) to origin/$(LIBSTB_HAL_GIT_REF); keeping local state." >&2; \
			fi; \
		fi; \
	elif [ -z "$$ref_exists" ]; then \
		echo "[libstb-hal] ERROR: ref $(LIBSTB_HAL_GIT_REF) does not resolve in $(LIBSTB_HAL_DIR)," >&2; \
		echo "[libstb-hal]        neither locally nor under any remote. Check LIBSTB_HAL_GIT_REF." >&2; \
		exit 1; \
	elif [ -n "$$want_sha" ] && [ "$$head_sha" = "$$want_sha" ]; then \
		echo "[libstb-hal] Source tree already at $(LIBSTB_HAL_GIT_REF); nothing to update."; \
	else \
		if [ -n "$$current_branch" ]; then \
			at="branch '$$current_branch'"; \
		else \
			at="detached HEAD $$(git -C $(LIBSTB_HAL_DIR) rev-parse --short HEAD)"; \
		fi; \
		echo "[libstb-hal] NOTE: source tree is on $$at, not $(LIBSTB_HAL_GIT_REF)." >&2; \
		echo "[libstb-hal]       Leaving it untouched; the builder never moves an existing checkout." >&2; \
		echo "[libstb-hal]       Building what is checked out. Switch manually to track $(LIBSTB_HAL_GIT_REF) again." >&2; \
	fi

$(LIBSTB_HAL_REF_STAMP): libstb-hal-source-sync
	@resolved="$(LIBSTB_HAL_GIT_REF) $$(git -C $(LIBSTB_HAL_DIR) rev-parse HEAD)"; \
	if [ ! -f $@ ] || [ "$$resolved" != "$$(cat $@)" ]; then \
		printf '%s\n' "$$resolved" > $@; \
	fi

$(LIBSTB_HAL_PATCH_STAMP): $(LIBSTB_HAL_REF_STAMP) $(LIBSTB_HAL_PATCH_FILES) $(PATCH_HELPER)
	@for d in $(LIBSTB_HAL_PATCH_DIRS); do \
		$(PATCH_HELPER) "$(LIBSTB_HAL_DIR)" "$$d" libstb-hal || exit 1; \
	done
	@touch $@

$(LIBSTB_HAL_CONFIGURE_STAMP): $(LIBSTB_HAL_REF_STAMP) $(LIBSTB_HAL_PATCH_STAMP) $(NEUTRINO_OPTIONAL_DEPS) | $(LIBSTB_HAL_BUILD_DIR)
	@$(MKDIR_P) $(LIBSTB_HAL_BUILD_DIR) $(NEUTRINO_INSTALL_DIR)
	$(call ENFORCE_GCC_VERSION)
	@echo "[libstb-hal] Running autogen + configure"
	@cd $(LIBSTB_HAL_DIR) && ./autogen.sh >/dev/null
	@cd $(LIBSTB_HAL_BUILD_DIR) && \
		SWRESAMPLE_CFLAGS="$$(PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) $(PKG_CONFIG) --cflags libswresample 2>/dev/null)" \
		SWRESAMPLE_LIBS="$$(PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) $(PKG_CONFIG) --libs libswresample 2>/dev/null)" \
		$(LIBSTB_HAL_DIR)/configure \
			--prefix=$(NEUTRINO_PREFIX) \
			--libdir=$(NEUTRINO_PREFIX)/lib \
			--enable-maintainer-mode \
			--enable-shared=no \
			--with-pic=yes \
			$(LIBSTB_HAL_CONFIGURE_FLAGS) \
			PKG_CONFIG_PATH=$(PKG_CONFIG_PATH)
	@touch $@

# Hash-based rebuild detection for libstb-hal
LIBSTB_HAL_GIT_HASH := $(shell cd $(LIBSTB_HAL_DIR) 2>/dev/null && git rev-parse HEAD 2>/dev/null)
LIBSTB_HAL_BUILT_HASH := $(shell cat $(LIBSTB_HAL_BUILD_DIR)/.built_hash 2>/dev/null)
LIBSTB_HAL_NEEDS_REBUILD := $(shell [ -n "$(LIBSTB_HAL_GIT_HASH)" ] && [ "$(LIBSTB_HAL_GIT_HASH)" != "$(LIBSTB_HAL_BUILT_HASH)" ] && echo yes)

$(LIBSTB_HAL_BUILD_STAMP): $(LIBSTB_HAL_CONFIGURE_STAMP) $(if $(LIBSTB_HAL_NEEDS_REBUILD),FORCE)
	@echo "[libstb-hal] Building"
	@if [ -d "$(LIBSTB_HAL_BUILD_DIR)" ]; then \
		find "$(LIBSTB_HAL_BUILD_DIR)" -name '*.lo' | while read -r lo; do \
			obj="$${lo%.lo}.o"; \
			pic="$$(dirname "$$lo")/.libs/$$(basename "$$obj")"; \
			if [ ! -f "$$obj" ] && [ ! -f "$$pic" ]; then \
				rm -f "$$lo"; \
			fi; \
		done; \
	fi
	@$(MAKE) -C $(LIBSTB_HAL_BUILD_DIR)
	@# Record the HEAD that was actually built. $(LIBSTB_HAL_GIT_HASH) was expanded
	@# at parse time and is stale if the source-ref step advanced HEAD in this run.
	@git -C $(LIBSTB_HAL_DIR) rev-parse HEAD > $(LIBSTB_HAL_BUILD_DIR)/.built_hash
	@touch $@

$(LIBSTB_HAL_INSTALL_STAMP): $(LIBSTB_HAL_BUILD_STAMP)
	@echo "[libstb-hal] Installing into $(NEUTRINO_INSTALL_DIR)"
	@$(MAKE) -C $(LIBSTB_HAL_BUILD_DIR) install DESTDIR=$(NEUTRINO_INSTALL_DIR)
	@touch $@
else
$(LIBSTB_HAL_CONFIGURE_STAMP) $(LIBSTB_HAL_BUILD_STAMP) $(LIBSTB_HAL_INSTALL_STAMP):
	@echo "[libstb-hal] Using host libstb-hal $(LIBSTB_HAL_HOST_VERSION), skipping build"
	@touch $@
endif

$(NEUTRINO_SOURCE_STAMP):
	@$(MKDIR_P) $(SOURCES_DIR)
	@if [ ! -d "$(NEUTRINO_SRC_DIR)/.git" ]; then \
		echo "[neutrino] Cloning $(NEUTRINO_GIT_URL) (branch $(NEUTRINO_BRANCH))"; \
		git clone --branch $(NEUTRINO_BRANCH) --depth 1 $(NEUTRINO_GIT_URL) $(NEUTRINO_SRC_DIR); \
	else \
		echo "[neutrino] Using existing source tree at $(NEUTRINO_SRC_DIR)"; \
	fi

$(NEUTRINO_PATCH_STAMP): $(NEUTRINO_SOURCE_STAMP) $(NEUTRINO_PATCH_FILES) $(PATCH_HELPER)
	@for d in $(NEUTRINO_PATCH_DIRS); do \
		$(PATCH_HELPER) "$(NEUTRINO_SRC_DIR)" "$$d" neutrino || exit 1; \
	done
	@touch $@

$(NEUTRINO_CONFIGURE_STAMP): $(NEUTRINO_SOURCE_STAMP) $(NEUTRINO_PATCH_STAMP) $(LIBSTB_HAL_PREREQ) $(DVBSI_PREREQ) $(NEUTRINO_LUA_PREREQ) $(NEUTRINO_OPTIONAL_DEPS) | $(NEUTRINO_BUILD_DIR)
	@$(MKDIR_P) $(NEUTRINO_BUILD_DIR) $(NEUTRINO_INSTALL_DIR)
	$(call ENFORCE_GCC_VERSION)
	@echo "[neutrino] Running autogen + configure"
	@if [ -f "$(NEUTRINO_SRC_DIR)/config.status" ]; then \
		echo "[neutrino] Removing stale in-tree configure state from source tree"; \
		rm -f "$(NEUTRINO_SRC_DIR)/config.status" "$(NEUTRINO_SRC_DIR)/config.log" \
			"$(NEUTRINO_SRC_DIR)/config.cache" "$(NEUTRINO_SRC_DIR)/config.h" \
			"$(NEUTRINO_SRC_DIR)/stamp-h1" "$(NEUTRINO_SRC_DIR)/libtool" \
			"$(NEUTRINO_SRC_DIR)/Makefile"; \
	fi
	@src_real="$$(readlink -f "$(NEUTRINO_SRC_DIR)")"; \
	if [ -z "$$src_real" ] || [ ! -d "$$src_real" ]; then \
		echo "[neutrino] ERROR: cannot resolve source tree $(NEUTRINO_SRC_DIR)" >&2; \
		exit 1; \
	fi; \
	if find "$$src_real" \
		\( -path "$$src_real/.git" -o -path "$$src_real/.git/*" \
		   -o -path "$$src_real/oe-workdir" -o -path "$$src_real/oe-workdir/*" \) -prune -o \
		\( -type d \( -name .deps -o -name .libs \) -print -quit \) -o \
		\( -type f \( -name '*.o' -o -name '*.lo' -o -name '*.a' -o -name '*.la' -o -name '*.lai' \) -print -quit \) \
		| grep -q .; then \
		echo "[neutrino] Removing stale in-tree build artifacts from source tree"; \
		find "$$src_real" \
			\( -path "$$src_real/.git" -o -path "$$src_real/.git/*" \
			   -o -path "$$src_real/oe-workdir" -o -path "$$src_real/oe-workdir/*" \) -prune -o \
			-type d \( -name .deps -o -name .libs \) -exec rm -rf {} +; \
		find "$$src_real" \
			\( -path "$$src_real/.git" -o -path "$$src_real/.git/*" \
			   -o -path "$$src_real/oe-workdir" -o -path "$$src_real/oe-workdir/*" \) -prune -o \
			-type f \( -name '*.o' -o -name '*.lo' -o -name '*.a' -o -name '*.la' -o -name '*.lai' \) -exec rm -f {} +; \
	fi
	@cd $(NEUTRINO_SRC_DIR) && ./autogen.sh >/dev/null
	@cd $(NEUTRINO_BUILD_DIR) && \
		CFLAGS="$(NEUTRINO_CFLAGS_ALL)" \
		CXXFLAGS="$(NEUTRINO_CXXFLAGS_ALL)" \
		CPPFLAGS="$(CPPFLAGS) -I$(STB_HAL_INCLUDE_DIR) -I$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include $(NEUTRINO_CPPFLAGS_APPEND)" \
		LDFLAGS="$(LDFLAGS) -L$(STB_HAL_LIBRARY_DIR)" \
		PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) \
		$(NEUTRINO_SRC_DIR)/configure \
			--prefix=$(NEUTRINO_PREFIX) \
			--enable-maintainer-mode \
			--enable-silent-rules \
			--enable-mdev \
			--enable-giflib \
			--enable-cleanup \
			--with-target=native \
			--with-boxtype=generic \
			--with-stb-hal-includes=$(STB_HAL_INCLUDE_DIR) \
			--with-stb-hal-build=$(STB_HAL_LIBRARY_DIR) \
			$(NEUTRINO_CONFIGURE_COMMON_FLAGS) \
			$(NEUTRINO_CONFIGURE_FLAGS)
	@touch $@

# Hash-based rebuild detection: compare current git HEAD with last built commit
NEUTRINO_GIT_HASH := $(shell cd $(NEUTRINO_SRC_DIR) 2>/dev/null && git rev-parse HEAD 2>/dev/null)
NEUTRINO_BUILT_HASH := $(shell cat $(NEUTRINO_BUILD_DIR)/.built_hash 2>/dev/null)
NEUTRINO_NEEDS_REBUILD := $(shell [ "$(NEUTRINO_GIT_HASH)" != "$(NEUTRINO_BUILT_HASH)" ] && echo yes)

$(NEUTRINO_BUILD_STAMP): $(NEUTRINO_CONFIGURE_STAMP) $(if $(NEUTRINO_NEEDS_REBUILD),FORCE)
	@echo "[neutrino] Building"
	@$(MAKE) -C $(NEUTRINO_BUILD_DIR)
	@# Recipe time, not parse time — same reason as the libstb-hal side above.
	@git -C $(NEUTRINO_SRC_DIR) rev-parse HEAD > $(NEUTRINO_BUILD_DIR)/.built_hash
	@touch $@

.PHONY: FORCE
FORCE:

$(NEUTRINO_INSTALL_STAMP): $(NEUTRINO_BUILD_STAMP)
	@echo "[neutrino] Installing into $(NEUTRINO_INSTALL_DIR)"
	@$(MAKE) -C $(NEUTRINO_BUILD_DIR) install DESTDIR=$(NEUTRINO_INSTALL_DIR)
ifeq ($(NEUTRINO_STAGE_RUNTIME),1)
	@$(MKDIR_P) "$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr"
	@# The webroot is owned by the staged-install overlay below. This sync
	@# carries --delete and no longer has a copy of it on the sending side,
	@# so without the exclude it would wipe the served tree every time.
	@# FIXME: share/fonts needs the same protection and does not get it, so
	@# every build silently deletes the staged fonts. Neutrino is configured
	@# with an absolute --with-fontdir, so `make install DESTDIR=' drops the
	@# .ttf files under DESTDIR + the absolute runtime path and NOT under
	@# DESTDIR/usr -- share/fonts is the only directory that exists solely
	@# there. The runtime-sync recipe in make/main.mk covers exactly this
	@# with a SECOND, non-deleting rsync from that tree; this recipe
	@# replicates only its first stage, so the fonts go and stay gone until
	@# somebody runs `make runtime-sync' by hand. The symptom points nowhere
	@# near the cause: the GUI suite fails on missing fonts, not on a build
	@# error. Fix by excluding /share/fonts/*** here, or by carrying
	@# main.mk's second stage into this recipe so both paths stage the same
	@# tree.
	@rsync -a --no-owner --no-group --delete \
		--exclude='/var/tuxbox/**' \
		--exclude='/var/tuxbox/' \
		--exclude='/var/' \
		--exclude='/share/tuxbox/neutrino/httpd/***' \
		"$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/" "$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/"
	@if [ -d "$(ROOT_DIR)/skel-root" ]; then \
		rsync -a --no-owner --no-group --ignore-existing "$(ROOT_DIR)/skel-root/" "$(NEUTRINO_RUNTIME_PREFIX_ABS)/"; \
	fi
	@# Overlay the yWeb webroot from the staged install, not from data/y-web.
	@# The sources carry %() placeholders that only install-data-hook expands;
	@# copying them verbatim leaves scripts/Y_Tools.sh a shell syntax error.
	@yweb_src="$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/httpd"; \
	yweb_rt="$(NEUTRINO_RUNTIME_PREFIX_ABS)$(N_PRIVATE_HTTPDDIR)"; \
	if [ -d "$$yweb_src" ] && [ -d "$$yweb_rt" ]; then \
		rsync -a --no-owner --no-group "$$yweb_src/" "$$yweb_rt/"; \
	fi
endif
	@touch $@
	@echo "[neutrino] Build complete."
	@echo "[neutrino] Launch Neutrino with 'make run' (systemd-nspawn) or for direct host tests use 'ALLOW_NON_ROOT=1 make run-now'."

neutrino: $(NEUTRINO_INSTALL_STAMP)

$(NEUTRINO_STATIC_STAMP): $(NEUTRINO_SOURCE_STAMP) $(NEUTRINO_PATCH_STAMP) $(LIBSTB_HAL_PREREQ) $(DVBSI_PREREQ) $(NEUTRINO_LUA_PREREQ) $(NEUTRINO_OPTIONAL_DEPS) | $(NEUTRINO_BUILD_DIR_STATIC)
	@$(MKDIR_P) $(NEUTRINO_BUILD_DIR_STATIC) $(NEUTRINO_INSTALL_DIR_STATIC)
	@echo "[neutrino] Configuring static build"
	@cd $(NEUTRINO_SRC_DIR) && ./autogen.sh >/dev/null
	@cd $(NEUTRINO_BUILD_DIR_STATIC) && \
		CFLAGS="$(NEUTRINO_CFLAGS_ALL)" \
		CXXFLAGS="$(NEUTRINO_CXXFLAGS_ALL)" \
		CPPFLAGS="$(CPPFLAGS) -I$(STB_HAL_INCLUDE_DIR) -I$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include $(NEUTRINO_CPPFLAGS_APPEND)" \
		LDFLAGS="$(LDFLAGS) -L$(STB_HAL_LIBRARY_DIR)" \
		PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) \
		$(NEUTRINO_SRC_DIR)/configure \
			--prefix=$(NEUTRINO_PREFIX) \
			--enable-maintainer-mode \
			--enable-silent-rules \
			--disable-shared \
			--enable-static \
			--with-target=native \
			--with-boxtype=generic \
			--with-stb-hal-includes=$(STB_HAL_INCLUDE_DIR) \
			--with-stb-hal-build=$(STB_HAL_LIBRARY_DIR) \
			$(NEUTRINO_CONFIGURE_COMMON_FLAGS) \
			$(NEUTRINO_CONFIGURE_FLAGS) \
			LDFLAGS="$(LDFLAGS) -static"
	@$(MAKE) -C $(NEUTRINO_BUILD_DIR_STATIC)
	@$(MAKE) -C $(NEUTRINO_BUILD_DIR_STATIC) install DESTDIR=$(NEUTRINO_INSTALL_DIR_STATIC)
	@touch $@

neutrino-static: $(NEUTRINO_STATIC_STAMP)

.PHONY: neutrino-clean
neutrino-clean:
	@$(RM_RF) $(LIBSTB_HAL_BUILD_STAMP) $(NEUTRINO_BUILD_STAMP)
	@[ -d $(LIBSTB_HAL_BUILD_DIR) ] && find $(LIBSTB_HAL_BUILD_DIR) -name '*.o' -delete || true
	@[ -d $(NEUTRINO_BUILD_DIR) ] && find $(NEUTRINO_BUILD_DIR) -name '*.o' -delete || true

.PHONY: neutrino-clean-all
neutrino-clean-all: neutrino-clean ## Clean all Neutrino variants (release + debug/sanitizer)
	@$(RM_RF) \
		$(NEUTRINO_BUILD_DIR_DEBUG) $(NEUTRINO_INSTALL_DIR_DEBUG) $(NEUTRINO_RUNTIME_PREFIX_DEBUG) \
		$(NEUTRINO_BUILD_DIR_ASAN) $(NEUTRINO_INSTALL_DIR_ASAN) $(NEUTRINO_RUNTIME_PREFIX_ASAN) \
		$(NEUTRINO_BUILD_DIR_TSAN) $(NEUTRINO_INSTALL_DIR_TSAN) $(NEUTRINO_RUNTIME_PREFIX_TSAN)

.PHONY: neutrino-distclean
neutrino-distclean:
	@$(RM_RF) $(LIBSTB_HAL_BUILD_DIR) $(NEUTRINO_BUILD_DIR) $(NEUTRINO_BUILD_DIR_STATIC) \
		$(LIBSTB_HAL_CONFIGURE_STAMP) $(LIBSTB_HAL_BUILD_STAMP) $(LIBSTB_HAL_INSTALL_STAMP) \
		$(NEUTRINO_CONFIGURE_STAMP) $(NEUTRINO_BUILD_STAMP) $(NEUTRINO_INSTALL_STAMP) \
		$(NEUTRINO_STATIC_STAMP) $(NEUTRINO_INSTALL_DIR_STATIC)

$(LIBSTB_HAL_BUILD_DIR):
	@$(MKDIR_P) $@

$(NEUTRINO_BUILD_DIR):
	@$(MKDIR_P) $@

$(NEUTRINO_BUILD_DIR_STATIC):
	@$(MKDIR_P) $@
