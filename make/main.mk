MAKEFLAGS += --no-builtin-rules

ifndef MAKE_JOBS
  ifeq ($(filter -j%,$(MAKEFLAGS)),)
    MAKE_JOBS := $(shell command -v nproc >/dev/null 2>&1 && nproc || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    MAKEFLAGS += -j$(MAKE_JOBS)
  endif
else
  ifeq ($(filter -j%,$(MAKEFLAGS)),)
    MAKEFLAGS += -j$(MAKE_JOBS)
  endif
endif

# Set explicitly rather than relying on "first target wins". That rule made
# check-toolchain the default goal, and with the default TOOLCHAIN_GCC_VERSION
# (system) it is a no-op: a bare `make` printed "ok" and built nothing, which
# reads like success. `help` is the safe default -- it tells the user which
# target they actually wanted.
.DEFAULT_GOAL := help

include make/paths.mk
include make/env.mk

# Read exactly once, between the defaults and everything that consumes them.
# Reading it last (the previous behaviour) meant a local TOOLCHAIN_GCC_VERSION
# never reached the CC/CXX selection, and a local NEUTRINO_INSTALL_DIR arrived
# after PKG_CONFIG_PATH/CPPFLAGS/LDFLAGS had been computed -- the build silently
# used the wrong sysroot. It sits AFTER env.mk (so a dependent override such as
# `N_PLUGIN_DIR := $(N_PREFIX)/...` can reference a default) but BEFORE
# env-derive.mk and toolchain.mk (so the override reaches the derived values).
# It also has to come after .DEFAULT_GOAL above: a target defined in
# Makefile.local would otherwise become the default goal.
-include Makefile.local

include make/env-derive.mk
include make/toolchain.mk
include make/deps.mk
include make/third_party.mk
include make/neutrino.mk
include make/plugins.mk
include make/lua.mk
include make/web.mk
include make/yweb.mk
include make/tests.mk
include make/package.mk
include make/hosttools.mk

# Late hook for project-specific TARGETS that must reference something defined by
# the modules above -- e.g. a custom target with a core build product as a
# prerequisite (`my-build: $(NEUTRINO_INSTALL_STAMP)`). Variable OVERRIDES belong
# in Makefile.local (read early, so they reach the toolchain and derived paths);
# this file is read last, exactly where Makefile.local used to be, so late target
# definitions keep working.
-include Makefile.local.post

NEUTRINO_RUNTIME_PREFIX_ABS := $(abspath $(NEUTRINO_RUNTIME_PREFIX))
NEUTRINO_BUILD_DIR_DEBUG := $(NEUTRINO_BUILD_DIR)-debug
NEUTRINO_INSTALL_DIR_DEBUG := $(NEUTRINO_INSTALL_DIR)-debug
NEUTRINO_RUNTIME_PREFIX_DEBUG := $(NEUTRINO_RUNTIME_PREFIX)-debug
NEUTRINO_BUILD_DIR_ASAN := $(NEUTRINO_BUILD_DIR)-asan
NEUTRINO_INSTALL_DIR_ASAN := $(NEUTRINO_INSTALL_DIR)-asan
NEUTRINO_RUNTIME_PREFIX_ASAN := $(NEUTRINO_RUNTIME_PREFIX)-asan
NEUTRINO_BUILD_DIR_TSAN := $(NEUTRINO_BUILD_DIR)-tsan
NEUTRINO_INSTALL_DIR_TSAN := $(NEUTRINO_INSTALL_DIR)-tsan
NEUTRINO_RUNTIME_PREFIX_TSAN := $(NEUTRINO_RUNTIME_PREFIX)-tsan

.PHONY: help
help:
	@echo ""
	@echo "Neutrino Buildsystem – Hilfe"
	@echo "============================"
	@echo ""
	@echo "Grundlagen"
	@echo "  help              : Diese Übersicht anzeigen"
	@echo "  help-targets      : Alle annotierten Targets automatisch auflisten (EN)"
	@echo "  bootstrap         : Abhängigkeiten und Erstbuild in einem Rutsch"
	@echo "  deps              : Benötigte System- und Python-Pakete vorbereiten (ruft runtime-sync auf)"
	@echo "  deps-update       : Bereits installierte Abhängigkeiten aktualisieren"
	@echo "  deps-doctor       : Umgebung prüfen, ohne Änderungen vorzunehmen"
	@echo "  doctor            : Umgebung prüfen und fehlende Komponenten melden"
	@echo "  make VAR=...      : Pfade per Make-Variable anpassen (z. B. N_PREFIX, PLUGIN_PKG_CONFIG_SYSROOT_DIR)"
	@echo ""
	@echo "Bauen"
	@echo "  all               : Kompletten Stack bauen (deps + neutrino + plugins + lua + web)"
	@echo "  neutrino          : Standard-Build des Neutrino-Kerns"
	@echo "  neutrino-static   : Statische Variante des Neutrino-Binaries"
	@echo "  plugins           : Native Plugins aus $$PLUGINS_DIR bauen"
	@echo "  lua               : Lua-Plugins/Runtimes installieren"
	@echo "  web               : Web-Oberfläche (npm build) ins Sysroot kopieren"
	@echo "  deps-ffmpeg       : ffmpeg lokal bauen (Standard, Version via PREFERRED_FFMPEG_VERSION/FFMPEG_VERSION)"
	@echo "                      Host-Version nutzen: FFMPEG_USE_SYSTEM=1"
	@echo "  deps-ffmpeg-<ver> : ffmpeg <ver> lokal bauen (erzwingt Build, ignoriert Host-Version)"
	@echo "  deps-ffmpeg5      : ffmpeg 5.1.4 lokal bauen (Alias für deps-ffmpeg-5.1.4)"
	@echo "                      Bestehende ffmpeg-Installation im Prefix wird vor Neuinstallation entfernt"
	@echo "                      https via GnuTLS (--enable-gnutls); Abwahl: FFMPEG_CONFIGURE_FLAGS=--disable-gnutls"
	@echo "                      Geänderte Configure-Zeile => Reconfigure + Rebuild beim nächsten Lauf"
	@echo "  plugin-install-<name>: Einzelnes Plugin aus plugins/Makefile bauen (siehe list-plugin-targets)"
	@echo "  list-plugin-targets: Verfügbare Plugin-Namen für plugin-install-<name> anzeigen"
	@echo ""
	@echo "Toolchain/Compiler"
	@echo "  build-gcc         : GCC 15.2.0 aus Quellen bauen (Standard)"
	@echo "  build-gcc-<N>     : GCC Version <N> aus Quellen bauen (z.B. build-gcc-13, build-gcc-14, build-gcc-15)"
	@echo "                      Installiert nach: artifacts/toolchains/gcc-<version>/bin/gcc-<N>"
	@echo "  neutrino-gcc-<N>  : Neutrino mit bereits installierter GCC-Version <N> bauen (Debug-Build)"
	@echo ""
	@echo "  WICHTIG: GCC-Version konsistent setzen!"
	@echo "  Empfohlen: echo 'TOOLCHAIN_GCC_VERSION := 15' >> Makefile.local"
	@echo "  Alternative: export TOOLCHAIN_GCC_VERSION=15 (dann make bootstrap)"
	@echo "  Nur für Tests: make TOOLCHAIN_GCC_VERSION=15 neutrino"
	@echo ""
	@echo "Debug/Sanitizer"
	@echo "  neutrino-debug    : Debug-Build (-O0/-g3) in separaten Build-/Runtime-Pfaden"
	@echo "  neutrino-asan     : Address/UBSan-Build in separaten Pfaden"
	@echo "  neutrino-tsan     : ThreadSanitizer-Build in separaten Pfaden"
	@echo "  run-gdb           : Neutrino im proot mit gdb starten (ALLOW_NON_ROOT=1)"
	@echo "  run-gdb-debug     : Debug-Build im proot mit gdb starten"
	@echo "  run-valgrind      : Neutrino unter Valgrind/Memcheck (Logs: logs/valgrind)"
	@echo "  run-memcheck      : Alias für run-valgrind"
	@echo "  run-helgrind      : Thread-Analyse mit Valgrind/Helgrind (Logs: logs/valgrind)"
	@echo "  run-asan          : ASan/UBSan-Build bauen + starten (ALLOW_NON_ROOT=1)"
	@echo "  run-tsan          : TSAN-Build bauen + starten (ALLOW_NON_ROOT=1)"
	@echo ""
	@echo "Entwicklung"
	@echo "  yweb-install      : yWeb-Dateien direkt ins Sysroot/Runtime kopieren (schneller Test)"
	@echo "  yweb-install-sysroot: Nur ins Sysroot kopieren (ohne Runtime-Sync)"
	@echo "  yweb-status       : Zeigt yWeb-Pfade und Installationsstatus"
	@echo ""
	@echo "Laufzeit"
	@echo "  run               : Gestagtes Root direkt auf dem Host starten"
	@echo "  run-nspawn        : systemd-nspawn/Proot-Lauf in der gestagten Runtime"
	@echo "  run-now           : Rootloser Host-Lauf (proot, ALLOW_NON_ROOT=1)"
	@echo "  run-direct        : Host-Lauf über root/usr/bin/neutrino"
	@echo "  run-local         : Neutrino in einem systemd-nspawn-Container starten"
	@echo "  runtime-sync      : Gestagtes /usr → root/usr spiegeln, ohne Neutrino zu starten"
	@echo ""
	@echo "Tests"
	@echo "  test              : Shell-, GUI- und Web-Smoketests ausführen"
	@echo "  test-gui          : Nur GUI-Tests anstoßen"
	@echo "  test-web          : Nur Web-Tests (Playwright) ausführen"
	@echo "  test-hw           : Optionaler Hardware-Schnelltest (benötigt DVB-Geräte)"
	@echo ""
	@echo "Pakete"
	@echo "  package-appimage  : AppImage erstellen (setzt erfolgreichen Build voraus)"
	@echo "  package-appimage-verify : AppImage auf einem sauberen System starten und prüfen"
	@echo "  package-deb       : Debian-Paket erzeugen"
	@echo "  package-static    : Statisches Tarball-Bundle schreiben"
	@echo ""
	@echo "Aufräumen"
	@echo "  list-cleanable-plugins: Verfügbare Plugin-Namen zum gezielten Aufräumen anzeigen"
	@echo "  clean-plugin-<name>: Einzelnes Plugin aus Prefix/Runtime entfernen (alias: plugin-clean-<name>)"
	@echo "  clean             : Zwischenergebnisse der letzten Builds entfernen"
	@echo "  neutrino-clean-all: Alle Neutrino-Builds (Release/Debug/Sanitizer) entfernen"
	@echo "  distclean         : Alle Artefakte (inkl. GCC-Toolchains), Logs und Sysroot löschen"
	@echo "  distclean-keep-toolchains: Wie distclean, aber GCC-Toolchains behalten"
	@echo ""
	@echo "Weitere Infos: docs/README.de.md (bzw. README.en.md) – kompakte Anleitung + Debug-Hinweise."

# Machine-generated companion to the curated help above. It lists every target
# that carries a `## description` annotation across all included makefiles, so
# the annotations are no longer dead and no annotated target can silently go
# undiscovered. The curated `help` stays the default because it groups targets
# and carries the guidance a flat list cannot.
.PHONY: help-targets
help-targets: ## List every annotated target from its inline comment
	@echo "Annotated targets (generated from '##' comments):"
	@echo ""
	@grep -hE '^[a-zA-Z0-9_./%-]+([[:space:]]+[a-zA-Z0-9_./%-]+)*[[:space:]]*:[^=]*##' $(MAKEFILE_LIST) 2>/dev/null \
		| awk -F'##' '{ \
			desc=$$2; sub(/^[[:space:]]+/, "", desc); \
			head=$$1; sub(/:.*/, "", head); \
			n=split(head, names, /[[:space:]]+/); \
			for (i=1; i<=n; i++) if (names[i] != "") printf "  %-28s %s\n", names[i], desc }' \
		| LC_ALL=C sort -u

.PHONY: all default
default: all
all: deps neutrino plugins lua web ## Build everything required for development

.PHONY: bootstrap
bootstrap: ## Run dependency setup and build Neutrino in one step
	@echo "[bootstrap] === dependency setup (make deps) ==="
	@$(MAKE) deps
	@echo "[bootstrap] === lua toolchain (make lua-deps) ==="
	@$(MAKE) lua-deps
	@runtime_dir="$(NEUTRINO_RUNTIME_PREFIX)"; \
	if ! $(MKDIR_P) "$$runtime_dir"; then \
		echo "[bootstrap] Error: konnte Laufzeitverzeichnis '$$runtime_dir' nicht erzeugen. Bitte Berechtigungen anpassen (z. B. via 'sudo chown -R $(shell id -u):$(shell id -g) $$runtime_dir')."; \
		exit 1; \
	fi; \
	if [ ! -w "$$runtime_dir" ]; then \
		echo "[bootstrap] Error: Laufzeitverzeichnis '$$runtime_dir' ist nicht beschreibbar. Bitte Berechtigungen anpassen (z. B. via 'sudo chown -R $(shell id -u):$(shell id -g) $$runtime_dir')."; \
		exit 1; \
	fi
	@echo "[bootstrap] === core build (make neutrino) ==="
	@$(MAKE) neutrino
	@echo "[bootstrap] === lua scripts (make lua) ==="
	@$(MAKE) lua
	@echo "[bootstrap] === staging runtime (make runtime-sync) ==="
	@$(MAKE) runtime-sync
	@echo "[bootstrap] Done. Next steps: 'make run' (host wrapper), 'make run-nspawn' (systemd-nspawn/proot), or 'ALLOW_NON_ROOT=1 make run-now'."

.PHONY: runtime-sync
# yweb-install-sysroot refreshes the staged webroot from the working tree, so
# an uncommitted page edit is visible after "make run"; the install stamp is
# gated on the git HEAD hash and would not notice such an edit.
runtime-sync: $(NEUTRINO_INSTALL_STAMP) yweb-install-sysroot
	@if [ ! -d "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)" ]; then \
		echo "[runtime-sync] Keine Installation gefunden. Bitte zuerst 'make neutrino' ausführen."; \
		exit 1; \
	fi
	@expected_datadir="$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/share/tuxbox"; \
	config_header="$(NEUTRINO_BUILD_DIR)/config.h"; \
	if [ -f "$$config_header" ]; then \
		actual_datadir="$$(grep '^#define DATADIR ' "$$config_header" | awk '{print $$3}' | tr -d '\"')"; \
		if [ -n "$$actual_datadir" ] && [ "$$actual_datadir" != "$$expected_datadir" ]; then \
			echo "[runtime-sync] Hinweis: Neutrino wurde mit Laufzeitpfad '$$actual_datadir' konfiguriert,"; \
			echo "               erwartet wird jedoch '$$expected_datadir'."; \
			echo "[runtime-sync] Säubere Build-Verzeichnis und starte 'make neutrino' neu."; \
			$(RM_RF) "$(NEUTRINO_BUILD_DIR)" "$(NEUTRINO_CONFIGURE_STAMP)" "$(NEUTRINO_BUILD_STAMP)" "$(NEUTRINO_INSTALL_STAMP)"; \
			$(MAKE) neutrino; \
		fi; \
	fi
	@for stale in "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/var/tuxbox/plugins" "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/var/tuxbox/luaplugins" "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/usr/var/tuxbox/plugins" "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/usr/var/tuxbox/luaplugins"; do \
		if [ -d "$$stale" ]; then \
			rm -rf "$$stale/neutrino-mediathek" "$$stale/neutrino-mediathek.lua" "$$stale/neutrino-mediathek.cfg" "$$stale/neutrino-mediathek_hint.png"; \
		fi; \
	done
	@$(MKDIR_P) "$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr"
	@# The webroot is owned by the staged-install overlay at the end of this
	@# recipe; without the exclude this --delete would wipe the served tree.
	@rsync -a --no-owner --no-group --delete \
		--exclude='/var/tuxbox/**' \
		--exclude='/var/tuxbox/' \
		--exclude='/var/' \
		--exclude='/share/tuxbox/neutrino/httpd/***' \
		"$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/" "$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/" || { echo "[runtime-sync] ERROR: rsync stage 1 failed"; exit 1; }
	@if [ -d "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr" ]; then \
		# some installs (e.g. absolute DATADIR) end up under DESTDIR + runtime prefix; sync those in as well \
		rsync -a --no-owner --no-group \
			--exclude='/var/tuxbox/**' \
			--exclude='/var/tuxbox/' \
			--exclude='/var/' \
			--exclude='var/tuxbox/**' \
			--exclude='var/tuxbox/' \
			--exclude='var/' \
			"$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/" "$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/" || { echo "[runtime-sync] ERROR: rsync stage 2 failed"; exit 1; }; \
	fi
	@$(MKDIR_P) \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/share" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/share/fonts" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/share/tuxbox" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/config" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/config/zapit" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/control" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/fonts" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/luaplugins" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/plugins" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/plugins/mnt" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/httpd" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/httpd/hosted" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/icons" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/icons/logo" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/lcd/icons" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/locale" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/themes" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/webradio" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/neutrino/webtv" \
		"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/etc"
	@if [ -d "$(ROOT_DIR)/skel-root" ]; then \
		rsync -a --no-owner --no-group --ignore-existing "$(ROOT_DIR)/skel-root/" "$(NEUTRINO_RUNTIME_PREFIX_ABS)/" || { echo "[runtime-sync] ERROR: rsync skel-root failed"; exit 1; }; \
	fi
	@if [ -d "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_RUNTIME_PREFIX_ABS)" ]; then \
		rsync -a --no-owner --no-group \
			--exclude='/usr/var/tuxbox/**' \
			--exclude='/usr/var/tuxbox/' \
			--exclude='/usr/var/' \
			--exclude='usr/var/tuxbox/**' \
			--exclude='usr/var/tuxbox/' \
			--exclude='usr/var/' \
			"$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_RUNTIME_PREFIX_ABS)/" "$(NEUTRINO_RUNTIME_PREFIX_ABS)/" || { echo "[runtime-sync] ERROR: rsync runtime prefix failed"; exit 1; }; \
	fi
	@if [ -d "$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/var/tuxbox" ]; then \
		rsync -a --no-owner --no-group --ignore-existing \
			"$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_PREFIX)/var/tuxbox/" \
			"$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/" || { echo "[runtime-sync] ERROR: rsync var/tuxbox failed"; exit 1; }; \
	fi
	@for stale in "$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/plugins" "$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/luaplugins"; do \
		if [ -d "$$stale" ]; then \
			rm -rf "$$stale/neutrino-mediathek" "$$stale/neutrino-mediathek.lua" "$$stale/neutrino-mediathek.cfg" "$$stale/neutrino-mediathek_hint.png"; \
		fi; \
	done
	@./scripts/stage_runtime_libs.sh "$(NEUTRINO_RUNTIME_PREFIX_ABS)"
	@config_dir="$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/var/tuxbox/config"; \
	initial_dir_runtime="$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/share/tuxbox/neutrino/initial"; \
	initial_dir_src="$(NEUTRINO_SRC_DIR)/data/initial"; \
	initial_dir_build="$(NEUTRINO_BUILD_DIR)/data/initial"; \
	initial_dir=""; \
	if [ -d "$$initial_dir_runtime" ]; then \
		initial_dir="$$initial_dir_runtime"; \
	elif [ -d "$$initial_dir_src" ]; then \
		initial_dir="$$initial_dir_src"; \
	elif [ -d "$$initial_dir_build" ]; then \
		initial_dir="$$initial_dir_build"; \
	fi; \
	$(MKDIR_P) "$$config_dir"; \
	if [ -n "$$initial_dir" ]; then \
		for f in bouquets.xml services.xml ubouquets.xml frontend.conf; do \
			if [ -f "$$initial_dir/$$f" ] && [ ! -e "$$config_dir/$$f" ]; then \
				cp "$$initial_dir/$$f" "$$config_dir/$$f"; \
			fi; \
		done; \
		config_zapit_dir="$$config_dir/zapit"; \
		$(MKDIR_P) "$$config_zapit_dir"; \
		for f in bouquets.xml services.xml ubouquets.xml; do \
			if [ -f "$$initial_dir/$$f" ] && [ ! -e "$$config_zapit_dir/$$f" ]; then \
				cp "$$initial_dir/$$f" "$$config_zapit_dir/$$f"; \
			fi; \
		done; \
		if [ -f "$$initial_dir/frontend.conf" ] && [ ! -e "$$config_zapit_dir/frontend.conf" ]; then \
			cp "$$initial_dir/frontend.conf" "$$config_zapit_dir/frontend.conf"; \
		fi; \
		for sanitize in "$$config_dir/myservices.xml" "$$config_dir/epgmap.xml" "$$config_zapit_dir/myservices.xml" "$$config_zapit_dir/epgmap.xml"; do \
			if [ -f "$$sanitize" ]; then \
				sed -i 's/-- /- /g' "$$sanitize"; \
			fi; \
		done; \
		for blank in audio.conf volume.conf zapit.conf epgfilter.xml dvbtimefilter.xml; do \
			if [ ! -e "$$config_zapit_dir/$$blank" ]; then \
				: > "$$config_zapit_dir/$$blank"; \
			fi; \
		done; \
	fi; \
	seed_config_dir="$(NEUTRINO_SRC_DIR)/data/config"; \
	if [ -d "$$seed_config_dir" ]; then \
		for f in satellites.xml cables.xml terrestrial.xml providermap.xml encoding.conf epglanguages.conf; do \
			if [ -f "$$seed_config_dir/$$f" ] && [ ! -e "$$config_dir/$$f" ]; then \
				cp "$$seed_config_dir/$$f" "$$config_dir/$$f"; \
			fi; \
		done; \
	fi; \
	if [ ! -f "$$config_dir/neutrino.conf" ]; then \
		touch "$$config_dir/neutrino.conf"; \
	fi; \
	if [ ! -f "$$config_dir/scan.conf" ]; then \
		touch "$$config_dir/scan.conf"; \
	fi; \
	if [ ! -f "$$config_dir/timerd.conf" ]; then \
		touch "$$config_dir/timerd.conf"; \
	fi; \
	nhttpd_conf="$$config_dir/nhttpd.conf"; \
	runtime_prefix="$(NEUTRINO_RUNTIME_PREFIX_ABS)"; \
	runtime_usr="$$runtime_prefix/usr"; \
	write_nhttpd_default() { \
		printf '%s\n' \
			'Language.directory=languages' \
			'Language.selected=English' \
			'Tuxbox.DisplayLogos=true' \
			"Tuxbox.LogosURL=$$runtime_prefix/usr/var/tuxbox/neutrino/httpd/logo" \
			"WebsiteMain.directory=$$runtime_usr/share/tuxbox/neutrino/httpd" \
			"WebsiteMain.override_directory=$$runtime_prefix/usr/var/tuxbox/neutrino/httpd" \
			"WebsiteMain.port=$(NEUTRINO_WEB_PORT)" \
			"WebsiteMain.host=$(NEUTRINO_WEB_HOST)" \
			"WebsiteMain.hosted_directory=$$runtime_prefix/usr/var/tuxbox/neutrino/httpd/hosted" \
			'configfile.version=5' \
			'mod_auth.authenticate=false' \
			'mod_auth.no_auth_client=' \
			'mod_auth.password=tuxbox' \
			'mod_auth.username=root' \
			'mod_cache.cache_directory=/tmp/.cache' \
			'mod_sendfile.mime_types=htm:text/html,html:text/html,xml:application/xml,txt:text/plain,jpg:image/jpeg,jpeg:image/jpeg,gif:image/gif,png:image/png,bmp:image/x-ms-bmp,css:text/css,js:application/javascript,yjs:text/plain,img:application/octet-stream,ico:image/x-icon,m3u:audio/x-mpegURL,m3u8:application/x-mpegURL,tar:application/x-tar,gz:application/gzip,ts:video/MP2T,mkv:video/x-matroska,avi:video/x-msvideo,mp3:audio/mpeg,ogg:audio/ogg' \
			'mod_sendfile.sendAll=true' \
			'mod_weblog.log_format=' \
			'mod_weblog.logfile=/tmp/yhttpd.log' \
			'server.chroot=' \
			'server.group_name=' \
			'server.log.loglevel=0' \
			'server.no_keep-alive_ips=' \
			'server.user_name=' \
			'webserver.threading=true' \
			'webserver.websites=WebsiteMain' \
			> "$$nhttpd_conf"; \
	}; \
	if [ ! -f "$$nhttpd_conf" ]; then \
		write_nhttpd_default; \
	fi
	@neutrino_bin="$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/bin/neutrino"; \
	real_bin="$${neutrino_bin}.real"; \
	target_for_chrpath=""; \
	if [ -x "$$neutrino_bin" ] && file "$$neutrino_bin" 2>/dev/null | grep -q 'ELF'; then \
		target_for_chrpath="$$neutrino_bin"; \
	elif [ -x "$$real_bin" ]; then \
		target_for_chrpath="$$real_bin"; \
	fi; \
	if command -v chrpath >/dev/null 2>&1 && [ -n "$$target_for_chrpath" ]; then \
		chrpath -r '$$ORIGIN/../lib:$$ORIGIN/../lib/c:$$ORIGIN/../lib/t' "$$target_for_chrpath" >/dev/null; \
	elif ! command -v chrpath >/dev/null 2>&1; then \
		echo "[runtime-sync] Warning: chrpath not found – RUNPATH not adjusted."; \
	fi; \
	if [ -x "$$neutrino_bin" ] && file "$$neutrino_bin" 2>/dev/null | grep -q 'ELF'; then \
		mv "$$neutrino_bin" "$$real_bin"; \
	fi; \
	build_bin="$(NEUTRINO_BUILD_DIR)/src/neutrino"; \
	if [ -x "$$build_bin" ] && file "$$build_bin" 2>/dev/null | grep -q 'ELF'; then \
		if [ ! -f "$$real_bin" ] || [ "$$build_bin" -nt "$$real_bin" ]; then \
			cp "$$build_bin" "$$real_bin"; \
			if command -v chrpath >/dev/null 2>&1; then \
				chrpath -r '$$ORIGIN/../lib:$$ORIGIN/../lib/c:$$ORIGIN/../lib/t' "$$real_bin" >/dev/null; \
			fi; \
			echo "[runtime-sync] Staged fresh binary from build output."; \
		fi; \
	fi; \
	if [ -x "$$real_bin" ]; then \
		install -m 755 "$(ROOT_DIR)/scripts/neutrino-wrapper.sh" "$$neutrino_bin"; \
	else \
		echo "[runtime-sync] Warning: Neutrino binary missing at $$real_bin." >&2; \
	fi
	@# Overlay the yWeb webroot from the staged install, not from data/y-web.
	@# The sources carry %() placeholders that only install-data-hook expands;
	@# copying them verbatim leaves scripts/Y_Tools.sh a shell syntax error.
	@yweb_src="$(NEUTRINO_INSTALL_DIR)$(NEUTRINO_RUNTIME_TUXBOX)/neutrino/httpd"; \
	yweb_rt="$(NEUTRINO_RUNTIME_PREFIX_ABS)$(N_PRIVATE_HTTPDDIR)"; \
	if [ -d "$$yweb_src" ] && [ -d "$$yweb_rt" ]; then \
		rsync -a --no-owner --no-group "$$yweb_src/" "$$yweb_rt/"; \
	fi

.PHONY: run
run: run-direct ## Launch Neutrino via host wrapper (default, no nspawn)

.PHONY: run-nspawn
run-nspawn: neutrino runtime-sync ## Launch Neutrino inside systemd-nspawn (optional)
	@if [ "$(ALLOW_NON_ROOT)" = "1" ]; then \
		ALLOW_NON_ROOT=1 ./scripts/check_root.sh run; \
		if command -v proot >/dev/null 2>&1 || [ -x "$(ROOT_DIR)/tools/proot" ]; then \
			PROOT_ROOT=$(NEUTRINO_RUNTIME_PREFIX) \
			RUN_NEUTRINO_DISPLAY=$(RUN_NEUTRINO_DISPLAY) \
				NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR) \
				NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR) \
			./scripts/run_neutrino.sh; \
		else \
			echo "[run-nspawn] proot nicht gefunden – fallback auf Host-Wrapper 'run-direct'."; \
			echo "[run-nspawn] Tipp: 'sudo apt install proot' oder 'make tools-install-proot' bereitstellen, um den isolierten Modus zu nutzen."; \
			bin_path="$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/bin/neutrino"; \
			if [ ! -x "$$bin_path" ]; then \
				echo "[run-nspawn] Wrapper '$$bin_path' nicht gefunden. Bitte 'make runtime-sync' ausführen."; \
				exit 1; \
			fi; \
			if env SIMULATE_FE="$${SIMULATE_FE:-1}" "$$bin_path"; then \
				rc=0; \
			else \
				rc=$$?; \
			fi; \
			exec "$(ROOT_DIR)/scripts/neutrino_run_report.sh" run-nspawn "$$rc" "$(NEUTRINO_EXIT_ACTION_FILE)"; \
		fi; \
	else \
		./scripts/run_neutrino_local.sh; \
	fi

.PHONY: tools-install-proot
tools-install-proot:
	@if command -v proot >/dev/null 2>&1; then \
		echo "[tools] proot already available at $$(command -v proot)"; \
		exit 0; \
	elif [ -x "tools/proot" ]; then \
		echo "[tools] proot already staged in tools/proot"; \
		exit 0; \
	elif command -v apt-get >/dev/null 2>&1; then \
		echo "[tools] proot is missing. Install it via:"; \
		echo "  sudo apt update && sudo apt install -y proot"; \
		exit 1; \
	elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then \
		echo "[tools] proot is missing. Install it via:"; \
		echo "  sudo dnf install -y proot"; \
		exit 1; \
	else \
		echo "[tools] proot is missing. Please install it with your distribution's package manager."; \
		exit 1; \
	fi

.PHONY: tools-install-ccache
tools-install-ccache:
	@if command -v ccache >/dev/null 2>&1; then \
		echo "[tools] ccache already available at $$(command -v ccache)"; \
		exit 0; \
	elif command -v apt-get >/dev/null 2>&1; then \
		echo "[tools] ccache is missing. Install it via:"; \
		echo "  sudo apt update && sudo apt install -y ccache"; \
		exit 1; \
	elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then \
		echo "[tools] ccache is missing. Install it via:"; \
		echo "  sudo dnf install -y ccache"; \
		exit 1; \
	else \
		echo "[tools] ccache is missing. Please install it with your distribution's package manager."; \
		exit 1; \
	fi

.PHONY: run-now
run-now: runtime-sync ## Launch Neutrino without rebuilding (use existing artefacts)
	@if [ "$(ALLOW_NON_ROOT)" != "1" ]; then \
		echo "[run-now] Für einen direkten Lauf ohne systemd-nspawn bitte 'ALLOW_NON_ROOT=1 make run-now' nutzen oder 'make run' ausführen."; \
		exit 1; \
	fi
	@ALLOW_NON_ROOT=1 ./scripts/check_root.sh run
	@if command -v proot >/dev/null 2>&1 || [ -x "$(ROOT_DIR)/tools/proot" ]; then \
		PROOT_ROOT=$(NEUTRINO_RUNTIME_PREFIX) \
		RUN_NEUTRINO_DISPLAY=$(RUN_NEUTRINO_DISPLAY) \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR) \
			./scripts/run_neutrino.sh || { \
				rc=$$?; \
				echo "[run-now] proot-Start fehlgeschlagen (rc=$$rc) – fallback auf Host-Wrapper."; \
				bin_path="$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/bin/neutrino"; \
				if [ ! -x "$$bin_path" ]; then \
					echo "[run-now] Wrapper '$$bin_path' nicht gefunden. Bitte 'make runtime-sync' ausführen."; \
					exit 1; \
				fi; \
				exec env NEUTRINO_BIN="$$bin_path" TOOLCHAIN_GCC_VERSION="$(TOOLCHAIN_GCC_VERSION)" SIMULATE_FE="$${SIMULATE_FE:-1}" "$(ROOT_DIR)/scripts/run-neutrino.sh"; \
			}; \
	else \
		echo "[run-now] proot nicht gefunden – fallback auf Host-Wrapper."; \
		echo "[run-now] Installiere proot via 'sudo apt install proot' oder 'make tools-install-proot', um den sandboxed Modus nutzen zu können."; \
		bin_path="$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/bin/neutrino"; \
		if [ ! -x "$$bin_path" ]; then \
			echo "[run-now] Wrapper '$$bin_path' nicht gefunden. Bitte 'make runtime-sync' ausführen."; \
			exit 1; \
		fi; \
		exec env NEUTRINO_BIN="$$bin_path" TOOLCHAIN_GCC_VERSION="$(TOOLCHAIN_GCC_VERSION)" SIMULATE_FE="$${SIMULATE_FE:-1}" "$(ROOT_DIR)/scripts/run-neutrino.sh"; \
	fi

.PHONY: run-direct
run-direct: neutrino runtime-sync ## Launch Neutrino directly on the host via the staged runtime wrapper
	@bin_path="$(NEUTRINO_RUNTIME_PREFIX_ABS)/usr/bin/neutrino"; \
	if [ ! -x "$$bin_path" ]; then \
		echo "[run-direct] Wrapper '$$bin_path' fehlt – synchronisiere Runtime (make runtime-sync)…"; \
		$(MAKE) runtime-sync; \
	fi; \
	if [ ! -x "$$bin_path" ]; then \
		echo "[run-direct] Wrapper '$$bin_path' nicht gefunden. Bitte 'make neutrino' erneut ausführen."; \
		exit 1; \
	fi; \
	echo "[run-direct] Starting host Neutrino via $$bin_path"; \
	if env NEUTRINO_BIN="$$bin_path" TOOLCHAIN_GCC_VERSION="$(TOOLCHAIN_GCC_VERSION)" SIMULATE_FE="$${SIMULATE_FE:-1}" "$(ROOT_DIR)/scripts/run-neutrino.sh"; then \
		rc=0; \
	else \
		rc=$$?; \
	fi; \
	exec "$(ROOT_DIR)/scripts/neutrino_run_report.sh" run-direct "$$rc" "$(NEUTRINO_EXIT_ACTION_FILE)"

.PHONY: neutrino-debug
neutrino-debug: ## Build a debug-friendly Neutrino tree (-O0/-g3, separate dirs)
	@$(MAKE) DEBUG_BUILD=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_DEBUG) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_DEBUG) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_DEBUG) \
		neutrino
	@# Same flags as the build above: runtime-sync walks the install stamp and
	@# with it the ffmpeg configure record, which carries the compiler flags.
	@# Without them this pass would rebuild ffmpeg and the tree as release.
	@$(MAKE) DEBUG_BUILD=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_DEBUG) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_DEBUG) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_DEBUG) \
		runtime-sync

.PHONY: neutrino-asan
neutrino-asan: ## Build an ASan/UBSan-enabled Neutrino tree (separate dirs)
	@$(MAKE) DEBUG_BUILD=1 ENABLE_ASAN=1 ENABLE_UBSAN=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_ASAN) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_ASAN) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_ASAN) \
		neutrino
	@$(MAKE) DEBUG_BUILD=1 ENABLE_ASAN=1 ENABLE_UBSAN=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_ASAN) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_ASAN) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_ASAN) \
		runtime-sync

.PHONY: neutrino-tsan
neutrino-tsan: ## Build a TSAN-enabled Neutrino tree (separate dirs)
	@$(MAKE) DEBUG_BUILD=1 ENABLE_TSAN=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_TSAN) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_TSAN) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_TSAN) \
		neutrino
	@$(MAKE) DEBUG_BUILD=1 ENABLE_TSAN=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_TSAN) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_TSAN) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_TSAN) \
		runtime-sync

.PHONY: run-gdb
run-gdb: neutrino runtime-sync ## Launch Neutrino inside gdb (headless)
	@if [ "$(ALLOW_NON_ROOT)" != "1" ]; then \
		echo "[run-gdb] Bitte mit 'ALLOW_NON_ROOT=1 make run-gdb' ausführen."; \
		exit 1; \
	fi
	@ALLOW_NON_ROOT=1 ./scripts/check_root.sh run-gdb
	@PROOT_ROOT=$(NEUTRINO_RUNTIME_PREFIX) \
		RUN_NEUTRINO_DISPLAY=$(RUN_NEUTRINO_DISPLAY) \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR) \
		LSAN_OPTIONS="verbosity=1:log_threads=1" \
		NEUTRINO_RUN_WRAPPER="$(GDB)" \
		NEUTRINO_GDB_AUTORUN=1 \
		./scripts/run_neutrino.sh

.PHONY: run-gdb-debug
run-gdb-debug: ## Launch debug build inside gdb (headless, separate dirs)
	@$(MAKE) ALLOW_NON_ROOT=1 DEBUG_BUILD=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_DEBUG) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_DEBUG) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_DEBUG) \
		run-gdb

.PHONY: run-valgrind
run-valgrind: neutrino runtime-sync ## Launch Neutrino under Valgrind memcheck
	@if [ "$(ALLOW_NON_ROOT)" != "1" ]; then \
		echo "[run-valgrind] Bitte mit 'ALLOW_NON_ROOT=1 make run-valgrind' ausführen."; \
		exit 1; \
	fi
	@ALLOW_NON_ROOT=1 ./scripts/check_root.sh run-valgrind
	@timestamp=$$(date '+%Y%m%d%H%M%S'); \
		log_dir="$(LOG_DIR)/valgrind"; \
		latest_link="$$log_dir/memcheck_latest.log"; \
		log_file="$$log_dir/memcheck_$${timestamp}.log"; \
		mkdir -p "$$log_dir"; \
		echo "[run-valgrind] Schreibe Log nach $$log_file"; \
		PROOT_ROOT=$(NEUTRINO_RUNTIME_PREFIX) \
		RUN_NEUTRINO_DISPLAY=$(RUN_NEUTRINO_DISPLAY) \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR) \
		G_SLICE=always-malloc \
		G_DEBUG=gc-friendly \
		NEUTRINO_RUN_WRAPPER="$(VALGRIND) --tool=memcheck --leak-check=full --error-limit=no --num-callers=40 --show-leak-kinds=all --track-origins=yes --log-file=$$log_file -v" \
		./scripts/run_neutrino.sh; \
		rc=$$?; \
		ln -sf "$$log_file" "$$latest_link"; \
		exit $$rc

.PHONY: run-memcheck
run-memcheck: ## Alias for run-valgrind (memcheck)
	@$(MAKE) run-valgrind

.PHONY: run-helgrind
run-helgrind: neutrino runtime-sync ## Launch Neutrino under Valgrind helgrind
	@if [ "$(ALLOW_NON_ROOT)" != "1" ]; then \
		echo "[run-helgrind] Bitte mit 'ALLOW_NON_ROOT=1 make run-helgrind' ausführen."; \
		exit 1; \
	fi
	@ALLOW_NON_ROOT=1 ./scripts/check_root.sh run-helgrind
	@timestamp=$$(date '+%Y%m%d%H%M%S'); \
		log_dir="$(LOG_DIR)/valgrind"; \
		latest_link="$$log_dir/helgrind_latest.log"; \
		log_file="$$log_dir/helgrind_$${timestamp}.log"; \
		mkdir -p "$$log_dir"; \
		echo "[run-helgrind] Schreibe Log nach $$log_file"; \
		PROOT_ROOT=$(NEUTRINO_RUNTIME_PREFIX) \
		RUN_NEUTRINO_DISPLAY=$(RUN_NEUTRINO_DISPLAY) \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR) \
		G_SLICE=always-malloc \
		G_DEBUG=gc-friendly \
		NEUTRINO_RUN_WRAPPER="$(VALGRIND) --tool=helgrind --read-var-info=yes --error-limit=no --num-callers=40 --log-file=$$log_file -v" \
		./scripts/run_neutrino.sh; \
		rc=$$?; \
		ln -sf "$$log_file" "$$latest_link"; \
		exit $$rc

.PHONY: run-asan
run-asan: ## Build + run ASan/UBSan tree (headless/proot, separate dirs)
	@ASAN_OPTIONS="detect_leaks=1:halt_on_error=1" \
	LSAN_OPTIONS="verbosity=1:log_threads=1" \
	$(MAKE) ALLOW_NON_ROOT=1 DEBUG_BUILD=1 ENABLE_ASAN=1 ENABLE_UBSAN=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_ASAN) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_ASAN) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_ASAN) \
		run-now

.PHONY: run-tsan
run-tsan: ## Build + run TSAN tree (headless/proot, separate dirs)
	@TSAN_OPTIONS="halt_on_error=1" \
	$(MAKE) ALLOW_NON_ROOT=1 DEBUG_BUILD=1 ENABLE_TSAN=1 \
		NEUTRINO_BUILD_DIR=$(NEUTRINO_BUILD_DIR_TSAN) \
		NEUTRINO_INSTALL_DIR=$(NEUTRINO_INSTALL_DIR_TSAN) \
		NEUTRINO_RUNTIME_PREFIX=$(NEUTRINO_RUNTIME_PREFIX_TSAN) \
		run-now

.PHONY: test
test: ## Execute shell, GUI and web smoke tests
	@$(MAKE) tests-all

.PHONY: test-gui
test-gui: ## Execute only GUI tests
	@$(MAKE) tests-gui

.PHONY: test-web
test-web: ## Execute only web tests
	@$(MAKE) tests-web

.PHONY: test-shell
test-shell: ## Execute only POSIX shell unit tests
	@$(MAKE) tests-shell

.PHONY: test-hw
test-hw: ## Run optional hardware smoke tests (requires DVB hardware)
	@$(MAKE) tests-hw

.PHONY: package-appimage
package-appimage: neutrino ## Build AppImage package
	@$(MAKE) package-appimage-build

.PHONY: package-deb
package-deb: neutrino ## Build Debian package
	@$(MAKE) package-deb-build

.PHONY: package-static
package-static: neutrino-static ## Build static tarball
	@$(MAKE) package-static-build

.PHONY: clean
clean: ## Remove intermediate build outputs
	@$(MAKE) third-party-clean
	@$(MAKE) neutrino-clean
	@$(MAKE) plugins-clean
	@$(MAKE) lua-clean
	@$(MAKE) web-clean
	@$(MAKE) tests-clean
	@$(MAKE) package-clean

.PHONY: distclean
distclean: clean ## Remove all build artefacts and downloaded sources
	@./scripts/cleanup_runtime.sh
	@$(MAKE) third-party-distclean
	@$(MAKE) neutrino-distclean
	@$(MAKE) deps-distclean
	@echo "[distclean] Cleaning GCC build directories..."
	@$(RM_RF) $(BUILD_DIR)/gcc-*
	@echo "[distclean] Removing artifacts, logs, cache, and runtime..."
	@./scripts/remove_tree.sh "$(OUTPUT_DIR)" "$(LOG_DIR)" "$(CACHE_DIR)" "$(NEUTRINO_RUNTIME_PREFIX)"
	@if [ -x ./scripts/docker_prompt_cleanup.sh ]; then ./scripts/docker_prompt_cleanup.sh; fi
	@echo "[distclean] Done. GCC toolchains in artifacts/toolchains/ were removed."
	@echo "[distclean] Source trees in sources/ and archive/ were preserved."

.PHONY: distclean-keep-toolchains
distclean-keep-toolchains: clean ## distclean but keep GCC toolchains
	@./scripts/cleanup_runtime.sh
	@$(MAKE) third-party-distclean
	@$(MAKE) neutrino-distclean
	@$(MAKE) deps-distclean
	@echo "[distclean] Skipping GCC build directory cleanup to keep toolchains."
	@echo "[distclean] Removing sysroot, logs, cache, and runtime (keeping toolchains)..."
	@./scripts/remove_tree.sh "$(OUTPUT_DIR)/sysroot" "$(LOG_DIR)" "$(CACHE_DIR)" "$(NEUTRINO_RUNTIME_PREFIX)"
	@if [ -x ./scripts/docker_prompt_cleanup.sh ]; then ./scripts/docker_prompt_cleanup.sh; fi
	@echo "[distclean] Done. GCC toolchains in artifacts/toolchains/ were PRESERVED."
	@echo "[distclean] Run 'make distclean' to remove toolchains too."

.PHONY: doctor
doctor: ## Inspect environment and highlight missing dependencies
	@$(MAKE) deps-doctor

.PHONY: run-local
run-local: neutrino runtime-sync ## Launch Neutrino inside a local systemd-nspawn container
	@./scripts/run_neutrino_local.sh

.PHONY: neutrino-gcc-%
neutrino-gcc-%: ## Build neutrino with alternate GCC version (DEBUG_BUILD=1)
	@echo "[neutrino] Building with GCC $* (debug-friendly flags enabled)"
	@$(MAKE) TOOLCHAIN_GCC_VERSION=$* DEBUG_BUILD=1 neutrino
	@$(MAKE) runtime-sync

.PHONY: build-gcc-%
# --keep-sources is deliberate: without it the script refuses to start unless
# BUILD_GCC_ALLOW_DELETE=1 is set, so these targets failed every single time.
# Reusing the sources and rebuilding only the build directory is the sane
# default; wiping the source tree stays an explicit opt-in via the script.
build-gcc-%: ## Build GCC toolchain from source (e.g. build-gcc-15, build-gcc-13)
	@echo "[toolchain] Building GCC $* from source"
	@./scripts/build_gcc.sh --version $*.2.0 --keep-sources

.PHONY: build-gcc
build-gcc: ## Build default GCC toolchain (15.2.0)
	@./scripts/build_gcc.sh --keep-sources

.PHONY: deps-update
deps-update: ## Update required toolchains and Python packages
	@$(MAKE) deps-update-internal

.PHONY: hw-detect
hw-detect: ## Detect available tuner/video devices
	@./scripts/detect_devs.sh
