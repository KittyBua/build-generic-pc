# Toolchain defaults for building Neutrino and its dependencies.

HOST_ARCH ?= $(shell uname -m)
HOST_OS ?= $(shell uname -s)

TOOLCHAIN_GCC_VERSION ?= system
VALID_GCC_VERSIONS := system 8 9 10 11 12 13 14 15
ifneq ($(filter $(TOOLCHAIN_GCC_VERSION),$(VALID_GCC_VERSIONS)),)
# ok
else
  $(error Invalid TOOLCHAIN_GCC_VERSION=$(TOOLCHAIN_GCC_VERSION). Valid: $(VALID_GCC_VERSIONS))
endif
CCACHE ?= $(shell command -v ccache 2>/dev/null)
CCACHE_BASE ?= $(CACHE_DIR)/ccache
CCACHE_ID := $(if $(filter system,$(TOOLCHAIN_GCC_VERSION)),system,$(TOOLCHAIN_GCC_VERSION))
# Not `ifdef`: that tests the unexpanded text, and `$(shell command -v ...)`
# is never empty as text -- so the wrapper branch was taken on every host
# without ccache too, and CC became " gcc" with a leading space.
ifneq ($(strip $(CCACHE)),)
CCACHE_DIR ?= $(CCACHE_BASE)/$(HOST_ARCH)/gcc-$(CCACHE_ID)
CCACHE_TEMPDIR ?= $(CCACHE_BASE)/tmp
endif
DEBUG_BUILD ?= 0
ENABLE_ASAN ?= 0
ENABLE_UBSAN ?= 0
ENABLE_TSAN ?= 0

# Honor explicit CC/CXX overrides, otherwise pick gcc/g++ (or versioned variants)
ifeq ($(origin CC),default)
  ifeq ($(TOOLCHAIN_GCC_VERSION),system)
    CC := gcc
  else
    CC := gcc-$(TOOLCHAIN_GCC_VERSION)
  endif
endif
ifeq ($(origin CXX),default)
  ifeq ($(TOOLCHAIN_GCC_VERSION),system)
    CXX := g++
  else
    CXX := g++-$(TOOLCHAIN_GCC_VERSION)
  endif
endif

# Transparently wrap compilers with ccache (if available) and steer cache into a per-arch/per-gcc directory.
ifneq ($(strip $(CCACHE)),)
  ifeq ($(findstring ccache,$(CC)),)
    CC := $(CCACHE) $(CC)
  endif
  ifeq ($(findstring ccache,$(CXX)),)
    CXX := $(CCACHE) $(CXX)
  endif
endif
AR ?= ar
STRIP ?= strip
RANLIB ?= ranlib
PKG_CONFIG ?= pkg-config

SANITIZER_FLAGS :=
ifeq ($(ENABLE_ASAN),1)
SANITIZER_FLAGS += -fsanitize=address
endif
ifeq ($(ENABLE_UBSAN),1)
SANITIZER_FLAGS += -fsanitize=undefined
endif
ifeq ($(ENABLE_TSAN),1)
SANITIZER_FLAGS += -fsanitize=thread
endif
ifeq ($(ENABLE_ASAN),1)
ifeq ($(ENABLE_TSAN),1)
$(error ENABLE_ASAN=1 and ENABLE_TSAN=1 are mutually exclusive)
endif
endif

ifeq ($(DEBUG_BUILD),1)
DEBUG_CFLAGS_BASE := -O0 -g3 -fno-omit-frame-pointer -fno-optimize-sibling-calls -fstack-protector-strong -fPIC -Wall -Wextra -Wformat=2
CFLAGS ?= $(DEBUG_CFLAGS_BASE) $(SANITIZER_FLAGS)
CXXFLAGS ?= $(DEBUG_CFLAGS_BASE) -std=gnu++17 $(SANITIZER_FLAGS)
else
CFLAGS ?= -O2 -pipe -fPIC -Wall -Wextra -Wformat=2 -fstack-protector-strong $(SANITIZER_FLAGS)
CXXFLAGS ?= $(CFLAGS) -std=gnu++17
endif

LDFLAGS ?= -Wl,-O1 -Wl,--as-needed $(SANITIZER_FLAGS)

export HOST_ARCH HOST_OS CC CXX AR STRIP RANLIB PKG_CONFIG CFLAGS CXXFLAGS LDFLAGS CCACHE_DIR CCACHE_TEMPDIR

define ENFORCE_GCC_VERSION
	@if [ "$(TOOLCHAIN_GCC_VERSION)" != "system" ]; then \
		exp_major="$(TOOLCHAIN_GCC_VERSION)"; \
		cc_ver="$$( $(CC) -dumpfullversion -dumpversion 2>/dev/null | head -n1 || true)"; \
		cxx_ver="$$( $(CXX) -dumpfullversion -dumpversion 2>/dev/null | head -n1 || true)"; \
		if [ -z "$$cc_ver" ] || [ -z "$$cxx_ver" ]; then \
			echo "[toolchain] ERROR: Compiler nicht gefunden (CC=$(CC), CXX=$(CXX))."; \
			echo "[toolchain] Bitte gcc-$(TOOLCHAIN_GCC_VERSION)/g++-$(TOOLCHAIN_GCC_VERSION) installieren oder PATH/CC/CXX korrigieren."; \
			exit 1; \
		fi; \
		cc_major="$$(printf '%s\n' "$$cc_ver" | cut -d. -f1)"; \
		cxx_major="$$(printf '%s\n' "$$cxx_ver" | cut -d. -f1)"; \
		if [ "$$cc_major" != "$$exp_major" ] || [ "$$cxx_major" != "$$exp_major" ]; then \
			echo "[toolchain] ERROR: TOOLCHAIN_GCC_VERSION=$(TOOLCHAIN_GCC_VERSION), aber CC=$(CC) meldet $$cc_ver, CXX=$(CXX) meldet $$cxx_ver."; \
			echo "[toolchain] Hinweis: Alte Build-Verzeichnisse oder falscher Compiler im PATH."; \
			echo "[toolchain] Bitte Stamps/Builddirs der betroffenen Komponenten löschen (z. B. sources/ffmpeg-*/build, build/neutrino) und 'make TOOLCHAIN_GCC_VERSION=$(TOOLCHAIN_GCC_VERSION) bootstrap' erneut ausführen."; \
			exit 1; \
		fi; \
	fi
endef

.PHONY: check-toolchain
check-toolchain: ## Verify the selected GCC version matches TOOLCHAIN_GCC_VERSION
	$(call ENFORCE_GCC_VERSION)
	@echo "[toolchain] GCC-Version ok (TOOLCHAIN_GCC_VERSION=$(TOOLCHAIN_GCC_VERSION), CC=$(CC))"
