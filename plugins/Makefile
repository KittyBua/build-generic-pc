ROOT_DIR ?= $(abspath ..)
BUILD_DIR ?= $(ROOT_DIR)/build
PLUGINS_BUILD_DIR ?= $(BUILD_DIR)/plugins
DESTDIR ?=
N_PREFIX ?= /usr
PREFIX ?= $(N_PREFIX)
PLUGIN_SHARE_DIR := $(DESTDIR)$(PREFIX)/share/tuxbox/neutrino/plugins
PLUGIN_LIB_DIR := $(DESTDIR)$(PREFIX)/lib/tuxbox/neutrino/plugins

PLUGIN_PRIMARY_DIR := $(ROOT_DIR)/sources/neutrino-mediathek
PLUGIN_SCRIPTS_LUA_SRC := $(ROOT_DIR)/sources/plugin-scripts-lua
PLUGIN_SCRIPTS_LUA_GIT_URL ?= https://github.com/tuxbox-neutrino/plugin-scripts-lua.git
PLUGIN_SCRIPTS_LUA_GIT_REF ?=
LEGACY_PLUGIN_SRC := $(PLUGIN_SCRIPTS_LUA_SRC)/plugins/neutrino-mediathek
LEGACY_LUA_SRC := $(PLUGIN_SCRIPTS_LUA_SRC)/share/lua
NEUTRINO_MEDIATHEK_GIT_URL ?= https://github.com/tuxbox-neutrino/plugin-lua-neutrino-mediathek.git
NEUTRINO_MEDIATHEK_GIT_REF ?=

LOGOUPDATER_SRC := $(ROOT_DIR)/sources/plugin-lua-logoupdater
# Without a URL this plugin was silently unavailable in every fresh clone: it is
# listed in the aggregate but was only ever present on hosts that happened to
# have a checkout lying around.
LOGOUPDATER_GIT_URL ?= https://github.com/tuxbox-neutrino/plugin-lua-logoupdater.git
LOGOUPDATER_GIT_REF ?=

# Default to C++11 for legacy plugin sources (works with older toolchains).
CXXFLAGS += -std=gnu++11

# Toggle static linking for Fritz plugins (older targets without shared deps).
STATIC_PLUGINS ?= 0

PKG_CONFIG ?= pkg-config

# FritzInfoMonitor is box-only (see fritzinfo-install), so nothing is built or
# installed here. Only the build dir remains, for `clean`.
FIM_BUILD_DIR := $(PLUGINS_BUILD_DIR)/FritzInfoMonitor

FCM_SRC_DIR := $(ROOT_DIR)/sources/FritzCallMonitor
FCM_BUILD_DIR := $(PLUGINS_BUILD_DIR)/FritzCallMonitor
FCM_DST_BIN := $(DESTDIR)$(N_PREFIX)/bin
FCM_STATIC_LDFLAGS :=
FCM_GIT_URL ?= https://github.com/tuxbox-neutrino/FritzCallMonitor.git
FCM_GIT_REF ?=
ifeq ($(STATIC_PLUGINS),1)
FCM_STATIC_LDFLAGS := -static -static-libstdc++ -static-libgcc
endif
FCM_CONFIG_DIR := $(DESTDIR)/var/tuxbox/config
FCM_ICON_DIR := $(PLUGIN_SHARE_DIR)
FCM_INIT_DIR := $(DESTDIR)/etc/init.d

TUXWETTER_SRC_DIR := $(ROOT_DIR)/sources/plugin-tuxwetter
TUXWETTER_GIT_URL ?= https://github.com/tuxbox-neutrino/plugin-tuxwetter
TUXWETTER_GIT_REF ?=
# This is the generic PC build, so the tuxwetter legacy core is compiled
# without the framebuffer-device path. A box build goes through the OE recipe
# and passes 0 there instead.
HAVE_GENERIC_HARDWARE ?= 1

NEUTRINO_MEDIATHEK_SRC ?= $(PLUGIN_PRIMARY_DIR)
NEUTRINO_LUA_HELPERS_SRC ?= $(LEGACY_LUA_SRC)

INSTALL_PREFIX ?= $(DESTDIR)$(PREFIX)
PLUGIN_SHARE_DIR := $(INSTALL_PREFIX)/share/tuxbox/neutrino/plugins
LUA_PLUGIN_DIR := $(INSTALL_PREFIX)/share/tuxbox/neutrino/luaplugins
LUA_HELPER_DEST := $(INSTALL_PREFIX)/share/lua
RUNTIME_ROOT_FALLBACK := $(ROOT_DIR)/root

# The build delegates building and installing to each plugin repository, which
# must therefore ship a Makefile with an `install` target. Without this check
# make only says "No rule to make target 'install'", which tells the user
# nothing about the real cause.
# $(1) source dir, $(2) plugin name, $(3) git url, $(4) *_GIT_REF variable name
define require_plugin_contract
	if [ ! -f "$(1)/Makefile" ] || ! grep -qE '^install[[:space:]]*:' "$(1)/Makefile"; then \
		echo "[plugins] ERROR: $(2) does not provide the required build contract."; \
		echo "[plugins]        Expected a Makefile with an 'install' target in:"; \
		echo "[plugins]            $(1)"; \
		echo "[plugins]        cloned from: $(3)"; \
		echo "[plugins]        The generic-pc build delegates build+install to the plugin"; \
		echo "[plugins]        repository; its default branch does not carry that Makefile."; \
		echo "[plugins]        Use a branch that does, e.g.:"; \
		echo "[plugins]            make plugins $(4)=<branch>"; \
		exit 1; \
	fi
endef

.PHONY: install clean neutrino-mediathek-install neutrino-mediathek-lua-helpers logoupdater-install fritzinfo-install fritzcall-install tuxwetter-install

# Every plugin the aggregate attempts, in a deterministic order.
PLUGINS_ALL ?= neutrino-mediathek logoupdater fritzinfo fritzcall tuxwetter

# Only a failure of these makes `make plugins` fail. The others are reported but
# do not deny the user the plugins that did build. fritzinfo stays optional: it
# is a box-only plugin that is deliberately skipped on the generic PC build.
PLUGINS_REQUIRED ?= neutrino-mediathek logoupdater fritzcall tuxwetter

# Driven by a shell loop on purpose: the previous plain prerequisite list ran
# under the auto-injected -j, so output from five plugins interleaved and a
# single failure aborted the whole aggregate -- including plugins that had
# already built correctly.
install:
	@ok=""; failed=""; \
	for p in $(PLUGINS_ALL); do \
		echo "[plugins] === $$p ==="; \
		if $(MAKE) --no-print-directory "$$p-install"; then \
			ok="$$ok $$p"; \
		else \
			failed="$$failed $$p"; \
			echo "[plugins] $$p FAILED (continuing with the remaining plugins)"; \
		fi; \
	done; \
	echo ""; \
	echo "[plugins] ---------- summary ----------"; \
	for p in $(PLUGINS_ALL); do \
		state="ok"; \
		case " $$failed " in *" $$p "*) state="FAILED";; esac; \
		required="optional"; \
		case " $(PLUGINS_REQUIRED) " in *" $$p "*) required="required";; esac; \
		printf '[plugins] %-20s %-8s (%s)\n' "$$p" "$$state" "$$required"; \
	done; \
	rc=0; \
	for p in $$failed; do \
		case " $(PLUGINS_REQUIRED) " in *" $$p "*) rc=1;; esac; \
	done; \
	if [ "$$rc" -ne 0 ]; then \
		echo "[plugins] ERROR: at least one REQUIRED plugin failed."; \
	elif [ -n "$$failed" ]; then \
		echo "[plugins] Optional plugins failed:$$failed"; \
		echo "[plugins] The build continues; see the messages above for the reason."; \
	fi; \
	exit $$rc

neutrino-mediathek-install: neutrino-mediathek-lua-helpers
	@src=""; \
	for candidate in "$(NEUTRINO_MEDIATHEK_SRC)" "$(PLUGIN_PRIMARY_DIR)" "$(LEGACY_PLUGIN_SRC)"; do \
		if [ -n "$$candidate" ] && [ -d "$$candidate" ] && [ -f "$$candidate/neutrino-mediathek.lua" ]; then \
			src="$$candidate"; \
			break; \
		fi; \
	done; \
	if [ -z "$$src" ]; then \
		if [ -n "$(NEUTRINO_MEDIATHEK_GIT_URL)" ]; then \
			echo "[plugins] Cloning neutrino-mediathek from $(NEUTRINO_MEDIATHEK_GIT_URL)"; \
			branch_opt=""; \
			if [ -n "$(NEUTRINO_MEDIATHEK_GIT_REF)" ]; then branch_opt="--branch $(NEUTRINO_MEDIATHEK_GIT_REF)"; fi; \
			mkdir -p "$(dir $(PLUGIN_PRIMARY_DIR))"; \
			if git clone --depth 1 $$branch_opt "$(NEUTRINO_MEDIATHEK_GIT_URL)" "$(PLUGIN_PRIMARY_DIR)"; then \
				src="$(PLUGIN_PRIMARY_DIR)"; \
			else \
				echo "[plugins] ERROR: clone of neutrino-mediathek failed."; \
				exit 1; \
			fi; \
		else \
			echo "[plugins] ERROR: no neutrino-mediathek source directory found."; \
			echo "          Clone https://github.com/tuxbox-neutrino/plugin-lua-neutrino-mediathek.git"; \
			echo "          e.g. into $(PLUGIN_PRIMARY_DIR) or set NEUTRINO_MEDIATHEK_SRC=<path>."; \
			exit 1; \
		fi; \
	fi; \
	plugin_version_str="$$(cd "$$src" && (git describe --tags --always --dirty 2>/dev/null || cat neutrino-mediathek/VERSION 2>/dev/null || echo 'v1.0.0'))"; \
	for f in neutrino-mediathek.lua neutrino-mediathek.cfg neutrino-mediathek_hint.png; do \
		if [ ! -f "$$src/$$f" ]; then \
			echo "[plugins] Missing required file '$$src/$$f'."; \
			exit 1; \
		fi; \
	done; \
	if [ ! -d "$$src/neutrino-mediathek" ]; then \
		echo "[plugins] Missing subdirectory '$$src/neutrino-mediathek'."; \
		exit 1; \
	fi; \
	dest_share="$(PLUGIN_SHARE_DIR)"; \
	echo "[plugins] Installing neutrino-mediathek via its own Makefile (from $$src)"; \
	rm -rf "$$dest_share/neutrino-mediathek" "$$dest_share/neutrino-mediathek.lua" "$$dest_share/neutrino-mediathek.cfg" "$$dest_share/neutrino-mediathek_hint.png"; \
	rm -rf "$(LUA_PLUGIN_DIR)/neutrino-mediathek" "$(LUA_PLUGIN_DIR)/neutrino-mediathek.lua" "$(LUA_PLUGIN_DIR)/neutrino-mediathek.cfg" "$(LUA_PLUGIN_DIR)/neutrino-mediathek_hint.png"; \
	$(MAKE) -C "$$src" install \
		DESTDIR="$(DESTDIR)" \
		PREFIX="$(PREFIX)/share/tuxbox/neutrino" \
		PLUGIN_SUBDIR=plugins \
		LUAPLUGIN_SUBDIR=luaplugins || exit 1; \
	nm_share="$$dest_share/neutrino-mediathek"; \
	nm_lua="$(LUA_PLUGIN_DIR)/neutrino-mediathek"; \
	if [ -f "$$nm_lua/mt_variables.lua" ] && [ ! -f "$$nm_share/mt_variables.lua" ]; then \
		echo "[plugins] WARNING: plugins/neutrino-mediathek does not resolve to the plugin files"; \
		echo "[plugins]          (nested-symlink layout from a pre-fix plugin Makefile); repairing it"; \
		echo "[plugins]          into a directory symlink -> ../luaplugins/neutrino-mediathek."; \
		rm -rf "$$nm_share"; \
		ln -s ../luaplugins/neutrino-mediathek "$$nm_share"; \
	fi; \
	if [ ! -f "$$nm_share/mt_variables.lua" ]; then \
		echo "[plugins] ERROR: neutrino-mediathek install is broken:"; \
		echo "[plugins]        '$$nm_share/mt_variables.lua' is not readable after install."; \
		echo "[plugins]        Neutrino would fail to launch the plugin with a Lua Script Error."; \
		exit 1; \
	fi; \
	if [ -n "$(DESTDIR)" ]; then \
		for stale in "$(DESTDIR)/var/tuxbox/plugins" "$(DESTDIR)/var/tuxbox/luaplugins" "$(DESTDIR)/usr/var/tuxbox/plugins" "$(DESTDIR)/usr/var/tuxbox/luaplugins"; do \
			rm -rf "$$stale/neutrino-mediathek" "$$stale/neutrino-mediathek.lua" "$$stale/neutrino-mediathek.cfg" "$$stale/neutrino-mediathek_hint.png"; \
		done; \
	fi; \
	for runtime_root in "$(NEUTRINO_RUNTIME_PREFIX_ABS)" "$(RUNTIME_ROOT_FALLBACK)"; do \
		[ -n "$$runtime_root" ] || continue; \
		for mirror in "$$runtime_root/usr/var/tuxbox/plugins" "$$runtime_root/usr/var/tuxbox/luaplugins"; do \
			rm -rf "$$mirror/neutrino-mediathek" "$$mirror/neutrino-mediathek.lua" "$$mirror/neutrino-mediathek.cfg" "$$mirror/neutrino-mediathek_hint.png"; \
		done; \
	done

# The repository behind the Lua helper libraries -- and, upstream, the WebTV
# lists. Kept as a target of its own so that exactly one recipe ever clones it:
# two recipes doing it themselves race under the auto-injected -j and the
# loser dies on a non-empty target directory. A directory that is already
# there -- a checkout, or a symlink to one -- is never touched.
.PHONY: plugin-scripts-lua-fetch
plugin-scripts-lua-fetch:
	@if [ -d "$(PLUGIN_SCRIPTS_LUA_SRC)" ] || [ -z "$(PLUGIN_SCRIPTS_LUA_GIT_URL)" ]; then exit 0; fi; \
	branch_opt=""; \
	if [ -n "$(PLUGIN_SCRIPTS_LUA_GIT_REF)" ]; then branch_opt="--branch $(PLUGIN_SCRIPTS_LUA_GIT_REF)"; fi; \
	echo "[plugins] Cloning plugin-scripts-lua from $(PLUGIN_SCRIPTS_LUA_GIT_URL)"; \
	git clone --depth 1 $$branch_opt "$(PLUGIN_SCRIPTS_LUA_GIT_URL)" "$(PLUGIN_SCRIPTS_LUA_SRC)" || { \
		echo "[plugins] ERROR: clone of plugin-scripts-lua failed."; \
		exit 1; \
	}

# Lua helper libraries (feedparser/json/n_gui/n_helpers/…) are a runtime
# dependency shared by the Lua plugins, not part of any single plugin's install.
# On the box these arrive via RDEPENDS; on the PC build they are cloned from
# plugin-scripts-lua, which owns them upstream -- like every other plugin source,
# they are fetched when they are needed and are not carried in this repository.
# Kept as its own target (a prerequisite of the mediathek install) so the helpers
# are staged even when a plugin source tree is absent. The fetch is a
# prerequisite and, as before, happens only when the helpers are taken from
# plugin-scripts-lua: an explicitly chosen NEUTRINO_LUA_HELPERS_SRC is never
# silently replaced by a clone.
HELPERS_FETCH_DEP := $(if $(filter $(LEGACY_LUA_SRC),$(NEUTRINO_LUA_HELPERS_SRC)),plugin-scripts-lua-fetch,)
neutrino-mediathek-lua-helpers: $(HELPERS_FETCH_DEP)
	@lualib_src="$(NEUTRINO_LUA_HELPERS_SRC)"; \
	if [ ! -d "$$lualib_src" ] && [ "$$lualib_src" != "$(LEGACY_LUA_SRC)" ]; then \
		echo "[plugins] ERROR: NEUTRINO_LUA_HELPERS_SRC points at '$$lualib_src',"; \
		echo "[plugins]        which does not exist. An explicitly chosen helper"; \
		echo "[plugins]        directory is never silently replaced by a clone."; \
		echo "[plugins]        Correct the path, or unset it to fetch"; \
		echo "[plugins]        plugin-scripts-lua instead."; \
		exit 1; \
	fi; \
	if [ ! -d "$$lualib_src" ] && [ -n "$(PLUGIN_SCRIPTS_LUA_GIT_URL)" ]; then \
		if [ -d "$(LEGACY_LUA_SRC)" ]; then \
			lualib_src="$(LEGACY_LUA_SRC)"; \
		else \
			echo "[plugins] ERROR: $(PLUGIN_SCRIPTS_LUA_SRC) exists but carries no share/lua/."; \
			echo "[plugins]        An interrupted clone leaves such a tree behind."; \
			echo "[plugins]        Remove that directory to fetch it again, or point"; \
			echo "[plugins]        NEUTRINO_LUA_HELPERS_SRC at a directory holding 5.x/."; \
			exit 1; \
		fi; \
	fi; \
	if [ ! -d "$$lualib_src" ]; then \
		echo "[plugins] ERROR: Lua helper libraries not found at '$$lualib_src'."; \
		echo "[plugins]        They are a runtime dependency of the Lua plugins, so"; \
		echo "[plugins]        installing without them ships a broken plugin."; \
		echo "[plugins]        Provide them with either:"; \
		echo "[plugins]            make plugins NEUTRINO_LUA_HELPERS_SRC=<dir holding 5.x/>"; \
		echo "[plugins]            make plugins PLUGIN_SCRIPTS_LUA_GIT_URL=<repository url>"; \
		exit 1; \
	fi; \
	echo "[plugins] Staging Lua helper libraries from $$lualib_src (PC runtime dependency)"; \
	mkdir -p "$(LUA_HELPER_DEST)" || exit 1; \
	rsync -a --no-owner --no-group "$$lualib_src/" "$(LUA_HELPER_DEST)/" || exit 1; \
	compat_src=""; \
	if [ -d "$$lualib_src/5.1" ]; then \
		compat_src="$$lualib_src/5.1"; \
	elif [ -d "$$lualib_src/5.2" ]; then \
		compat_src="$$lualib_src/5.2"; \
	fi; \
	if [ -n "$$compat_src" ]; then \
		compat_dst="$(LUA_HELPER_DEST)/5.1"; \
		mkdir -p "$$compat_dst" || exit 1; \
		rsync -a --no-owner --no-group --ignore-existing "$$compat_src/" "$$compat_dst/" || exit 1; \
	fi

logoupdater-install:
	@src="$(LOGOUPDATER_SRC)"; \
	if [ ! -d "$$src" ] && [ -n "$(LOGOUPDATER_GIT_URL)" ]; then \
		branch_opt=""; \
		if [ -n "$(LOGOUPDATER_GIT_REF)" ]; then branch_opt="--branch $(LOGOUPDATER_GIT_REF)"; fi; \
		echo "[plugins] Cloning logoupdater from $(LOGOUPDATER_GIT_URL)"; \
		git clone --depth 1 $$branch_opt "$(LOGOUPDATER_GIT_URL)" "$$src" || \
			echo "[plugins] ERROR: clone of logoupdater failed."; \
	fi; \
	if [ -d "$$src" ] && [ -f "$$src/plugin/logoupdater.lua" ]; then \
		echo "[plugins] Installing logoupdater into $(PLUGIN_SHARE_DIR)"; \
		$(MAKE) -C "$$src" install \
			DESTDIR="$(DESTDIR)" \
			PREFIX="$(PREFIX)/share/tuxbox/neutrino" \
			PLUGIN_SUBDIR=plugins; \
	else \
		echo "[plugins] ERROR: logoupdater source not found at $$src."; \
		exit 1; \
	fi

fritzinfo-install:
	@echo "[plugins] FritzInfoMonitor is a box-only plugin: it renders on the"
	@echo "          framebuffer and reads the RC device, so it needs target-only"
	@echo "          headers (fb_device.h, rc_device_hardcoded.h) that do not exist"
	@echo "          on the generic PC. It is built for the target via its OE recipe."
	@echo "[plugins] Skipping FritzInfoMonitor on the generic PC build."

fritzcall-install:
	@if [ ! -d "$(FCM_SRC_DIR)" ]; then \
		if [ -n "$(FCM_GIT_URL)" ]; then \
			echo "[plugins] Cloning FritzCallMonitor from $(FCM_GIT_URL)"; \
			branch_opt=""; \
			if [ -n "$(FCM_GIT_REF)" ]; then branch_opt="--branch $(FCM_GIT_REF)"; fi; \
			git clone --depth 1 $$branch_opt "$(FCM_GIT_URL)" "$(FCM_SRC_DIR)" || exit 1; \
		fi; \
	fi; \
	if [ ! -d "$(FCM_SRC_DIR)" ]; then \
		echo "[plugins] ERROR: FritzCallMonitor sources not found at $(FCM_SRC_DIR)"; \
		exit 1; \
	fi; \
	$(call require_plugin_contract,$(FCM_SRC_DIR),FritzCallMonitor,$(FCM_GIT_URL),FCM_GIT_REF); \
	echo "[plugins] Building + installing FritzCallMonitor (repo Makefile)"; \
	$(MAKE) -C "$(FCM_SRC_DIR)" install \
		DESTDIR= \
		BINDIR="$(FCM_DST_BIN)" \
		CONFIGDIR="$(FCM_CONFIG_DIR)" \
		ICONSDIR="$(FCM_ICON_DIR)" \
		INITDIR="$(FCM_INIT_DIR)" \
		INIT_NAME=fritzcallmonitor.init \
		OBJDIR="$(FCM_BUILD_DIR)" \
		CXX="$(CXX)" \
		PKG_CONFIG="$(PKG_CONFIG)" \
		CPPFLAGS="$(CPPFLAGS)" \
		CXXFLAGS="$(CXXFLAGS)" \
		LDFLAGS="$(LDFLAGS) $(FCM_STATIC_LDFLAGS)"

tuxwetter-install:
	@if [ ! -d "$(TUXWETTER_SRC_DIR)" ]; then \
		if [ -n "$(TUXWETTER_GIT_URL)" ]; then \
			echo "[plugins] Cloning plugin-tuxwetter from $(TUXWETTER_GIT_URL)"; \
			branch_opt=""; \
			if [ -n "$(TUXWETTER_GIT_REF)" ]; then branch_opt="--branch $(TUXWETTER_GIT_REF)"; fi; \
			git clone --depth 1 $$branch_opt "$(TUXWETTER_GIT_URL)" "$(TUXWETTER_SRC_DIR)" || exit 1; \
		fi; \
	fi
	@if [ ! -d "$(TUXWETTER_SRC_DIR)" ]; then \
		echo "[plugins] ERROR: plugin-tuxwetter sources not found at $(TUXWETTER_SRC_DIR)"; \
		exit 1; \
	else \
		$(call require_plugin_contract,$(TUXWETTER_SRC_DIR),tuxwetter,$(TUXWETTER_GIT_URL),TUXWETTER_GIT_REF); \
		echo "[plugins] Building + installing tuxwetter (repo Makefile)"; \
		$(MAKE) -C "$(TUXWETTER_SRC_DIR)" install \
			CC="$(CC)" \
			CXX="$(CXX)" \
			PKG_CONFIG="$(PKG_CONFIG)" \
			NEUTRINO_SRC_DIR="$(NEUTRINO_SRC_DIR)" \
			NEUTRINO_BUILD_DIR="$(NEUTRINO_BUILD_DIR)" \
			NEUTRINO_INSTALL_DIR="$(NEUTRINO_INSTALL_DIR)" \
			DESTDIR="$(DESTDIR)" \
			PREFIX="$(PREFIX)" \
			HAVE_GENERIC_HARDWARE="$(HAVE_GENERIC_HARDWARE)"; \
	fi

clean:
	@rm -rf "$(FIM_BUILD_DIR)" "$(FCM_BUILD_DIR)"
