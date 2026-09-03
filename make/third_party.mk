# Third-party components that need to be built locally (Lua, LuaJIT, optional hostdeps).

HOSTDEPS_DIR := $(OUTPUT_DIR)/hostdeps

NEUTRINO_LUA_FLAVOR ?= lua
LUA_DEP_STAMP ?=

LUA_INSTALL_PREFIX := $(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)
LUA_PKGCONFIG_DIR := $(LUA_INSTALL_PREFIX)/lib/pkgconfig

THIRD_PARTY_TARGETS :=
THIRD_PARTY_HOSTDEPS :=

THIRD_PARTY_MODULES := $(wildcard $(ROOT_DIR)/make/third_party/*.mk)
include $(THIRD_PARTY_MODULES)

.PHONY: deps-hostdeps hostdeps
deps-hostdeps hostdeps: $(THIRD_PARTY_HOSTDEPS) ## Build optional host-provided deps (ffmpeg, etc.) if missing

# When building against system-provided Lua/LuaJIT, no local build artefacts.
ifeq ($(NEUTRINO_LUA_FLAVOR),system)
LUA_DEP_STAMP :=
endif

.PHONY: lua-deps
lua-deps: ## Force-build lua/luajit toolchain into sysroot for bootstrap
ifeq ($(NEUTRINO_LUA_FLAVOR),luajit)
	@echo "[lua-deps] Force-building LuaJIT $(LUAJIT_VERSION) for bootstrap"
	@$(MAKE) LUAJIT_FORCE=1 $(LUA_DEP_STAMP)
else ifeq ($(NEUTRINO_LUA_FLAVOR),lua)
	@echo "[lua-deps] Force-building Lua for bootstrap"
	@$(MAKE) LUA_FORCE=1 $(LUA_DEP_STAMP)
else ifeq ($(NEUTRINO_LUA_FLAVOR),system)
	@echo "[lua-deps] Using system-provided Lua/LuaJIT (flavor=system)"
endif

.PHONY: third-party
third-party: $(VENV_DIR)/.ready $(THIRD_PARTY_TARGETS)

.PHONY: third-party-clean
third-party-clean:
	@if [ -d "$(LUA_BUILD_DIR)" ]; then $(RM_RF) "$(LUA_BUILD_DIR)"; fi
	@if [ -d "$(LUAJIT_BUILD_DIR)" ]; then $(RM_RF) "$(LUAJIT_BUILD_DIR)"; fi
	@if [ -d "$(DVBSI_BUILD_DIR)" ]; then $(RM_RF) "$(DVBSI_BUILD_DIR)"; fi
	@if [ -f "$(DVBSI_INSTALL_STAMP)" ]; then rm -f "$(DVBSI_INSTALL_STAMP)"; fi
	@if [ -n "$(DVBSI_INSTALL_STAMP)" ]; then true; fi
	@if [ -f "$(LUA_DEP_STAMP)" ]; then rm -f "$(LUA_DEP_STAMP)"; fi

.PHONY: third-party-distclean
third-party-distclean: third-party-clean
	@if [ -d "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lua5.1" ]; then $(RM_RF) "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lua5.1"; fi
	@if [ -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lua.h" ]; then rm -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lua.h"; fi
	@if [ -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lualib.h" ]; then rm -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lualib.h"; fi
	@if [ -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lauxlib.h" ]; then rm -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lauxlib.h"; fi
	@if [ -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lua.hpp" ]; then rm -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/include/lua.hpp"; fi
	@if [ -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/lib/liblua.a" ]; then rm -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/lib/liblua.a"; fi
	@if [ -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/lib/liblua.so" ]; then rm -f "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/lib/liblua.so"; fi
