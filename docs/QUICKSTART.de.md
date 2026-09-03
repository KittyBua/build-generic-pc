# Schnellstart

## Schnellnavigation

- [Projektüberblick](README.de.md)
- [Schnellstart](QUICKSTART.de.md) *(diese Seite)*
  - [1. Repository klonen](#1-repository-klonen)
  - [2. Abhängigkeiten + Erstbuild](#2-abhängigkeiten--erstbuild-anstoßen)
  - [3. Neutrino erneut bauen](#3-neutrino-erneut-bauen-inkrementell)
  - [4. Neutrino starten](#4-neutrino-starten)
    - [4.1 Standard (Host-Wrapper)](#41-standard-host-wrapper)
    - [4.1a Optional: systemd-nspawn/proot](#41a-optional-systemd-nspawnproot-isoliert)
    - [4.2 Direkt auf dem Host](#42-direkt-auf-dem-host-manuell)
    - [4.3 Ohne Root (proot-Smoketest)](#43-ohne-root-proot-smoketest)
    - [4.4 Debugging & Sanitizer-Läufe](#44-debugging--sanitizer-läufe)
  - [5. Smoke-Tests ausführen](#5-smoke-tests-ausführen)
  - [6. Pakete generieren](#6-pakete-generieren-optional)
- [Test-Handbuch](TESTING.de.md)
- [Paketierungsleitfaden](PACKAGING.de.md)
- [Hardware-Hinweise](HARDWARE.de.md)
- Need English? See [QUICKSTART.en.md](QUICKSTART.en.md)

### 1. Repository klonen
```bash
git clone https://github.com/tuxbox-neutrino/neutrino-generic-build.git
cd neutrino-generic-build
```

Alle folgenden Befehle werden **im Wurzelverzeichnis des Repositories**
ausgeführt.

### 2. Abhängigkeiten + Erstbuild anstoßen

Der Ablauf ist dreistufig: **prüfen → installieren → bauen.**

1. **Prüfen, ohne etwas zu verändern.** Meldet fehlende Programme und Pakete
   und gibt den fertigen Installationsbefehl aus:
   ```bash
   make deps-doctor
   ```
2. **Systempakete installieren** — `deps-doctor` gibt den fertigen Befehl aus.
   Nimm den unter **„Required packages"**; der zweite Befehl unter „Optional
   packages" wird nur für Tests, Packaging und die Sandbox-Startziele gebraucht
   und darf auch fehlschlagen. Beispiel:
   ```bash
   sudo apt-get update && sudo apt-get install -y build-essential git ...
   ```
3. **Bauen** (als normaler User):
   ```bash
   make bootstrap
   ```

> **Warum nicht `sudo make deps`?** `deps` installiert nicht nur Pakete: es legt
> auch `.venv/` an und baut libdvbsi++ nach `artifacts/sysroot/`. Unter `sudo`
> gehören diese Verzeichnisse anschließend `root`, und der nächste Schritt als
> normaler User scheitert an den Rechten. Nur die Paketinstallation braucht
> Root — und die erledigt der Befehl aus Schritt 2.

`bootstrap` ruft `deps` auf und baut anschließend den Neutrino-Kern.

> **Zu `ALLOW_NON_ROOT=1`:** Diese Variable *installiert nichts*. Sie erlaubt
> lediglich, rootlose Targets auszuführen. Fehlen Pflichtpakete, bricht der
> Build **vorher** mit einer Liste der fehlenden Pakete und dem passenden
> `apt-get`/`dnf`-Befehl ab, statt später im `configure` zu scheitern.
> Nach der Installation einfach `make bootstrap` erneut starten.
> Wer die Prüfung bewusst umgehen will: `SKIP_DEP_CHECK=1 make bootstrap`.

### 3. Neutrino erneut bauen (inkrementell)
- Standard-Reload nach Codeänderungen:  
  ```bash
  make neutrino
  ```
- Falls Konfiguration/Prefix geändert wurde: vorher `make neutrino-clean` nutzen.

### Optional: andere GCC-Version + Debug-Builds

#### GCC-Version wählen

**Vorhandene GCC-Version nutzen:**

⚠️ **WICHTIG:** Die `TOOLCHAIN_GCC_VERSION` muss für ALLE Builds konsistent sein!

**Best Practice (empfohlen):**
```bash
# Option 1: Via Makefile.local (persistent für alle Builds)
echo "TOOLCHAIN_GCC_VERSION := 15" >> Makefile.local

# Dann normal bauen
make bootstrap
make neutrino
make plugins
```

**Alternative Methoden:**

```bash
# Option 2: Als Environment-Variable (Session-weit)
export TOOLCHAIN_GCC_VERSION=15
make bootstrap
make neutrino
make plugins

# Option 3: Pro Target (NUR für Quick-Tests! Nicht für Produktion!)
TOOLCHAIN_GCC_VERSION=15 make neutrino
```

**Komfort-Targets (für Debug-Builds):**
```bash
make neutrino-gcc-15  # Setzt DEBUG_BUILD=1 + runtime-sync
```

Weitere Varianten: `TOOLCHAIN_GCC_VERSION=14`, `13`, `12`, ..., `8`; `system` nutzt den Host-GCC.

**GCC aus Quellen bauen:**
```bash
# Via Makefile-Target
make build-gcc-15      # Baut GCC 15.2.0
make build-gcc-14      # Baut GCC 14.2.0
make build-gcc-13      # Baut GCC 13.2.0

# Oder direkt via Script (Löschen nur mit expliziter Freigabe)
BUILD_GCC_ALLOW_DELETE=1 ./scripts/build_gcc.sh --version 15.2.0 --jobs $(nproc)
```
Hinweis: Das Script löscht keinen vorhandenen Quellbaum aus Versehen. Ohne
`BUILD_GCC_ALLOW_DELETE=1` **läuft es gar nicht erst los**, sondern bricht ab und
verweist auf diese Variable oder auf `--keep-sources`. Mit `--keep-sources`
bleiben die Quellen stehen und nur das Build-Verzeichnis wird neu gebaut.

Ergebnis liegt unter `artifacts/toolchains/gcc-15.2.0/bin/gcc-15`. Unterstützte Versionen: 8.5.0 bis 15.2.0 (bei 8/9 ist libsanitizer automatisch deaktiviert).

Wenn `TOOLCHAIN_GCC_VERSION` gesetzt ist, prüft der Build nun aktiv, ob CC/CXX wirklich zu dieser Version gehören. Bei Mismatch bricht das Configure ab mit Hinweis auf Aufräumen (Stamps/Builddirs löschen, z. B. `sources/ffmpeg-*/build`, `build/neutrino`) und erneutem `make TOOLCHAIN_GCC_VERSION=<ver> bootstrap`.

### Optional: FFmpeg-Version auswählen

- Standard: FFmpeg wird lokal ins Sysroot gebaut (`PREFERRED_FFMPEG_VERSION`, Standard 5.1.4). `FFMPEG_VERSION` überschreibt pro Aufruf.
- Build mit Standard: `make deps-ffmpeg` (baut lokal; Host-Version wird standardmäßig ignoriert).
- Konkrete Version pinnen: `make deps-ffmpeg-6.1.1` (Version ersetzen nach Bedarf) → baut **immer** exakt diese Version.
- Host-Version nutzen (schneller, aber abhängig vom System): `FFMPEG_USE_SYSTEM=1 make deps` oder `FFMPEG_USE_SYSTEM=1 make bootstrap` (baut nur, wenn Host-Version fehlt/abweicht).
- Alias: `make deps-ffmpeg5` → `deps-ffmpeg-5.1.4`.
- Zusätzliche Flags für `./configure`: `FFMPEG_CONFIGURE_FLAGS="--enable-gpl --enable-nonfree" make deps-ffmpeg-7.0.2` (z. B. für zusätzliche Codecs/Hardwarebeschleuniger).
- https: der lokale Build ist mit `--enable-gnutls` konfiguriert (Host-Paket `libgnutls28-dev` bzw. `gnutls-devel`). Abwahl mit `FFMPEG_CONFIGURE_FLAGS=--disable-gnutls`; die Nutzer-Flags stehen hinter der eingebauten Zeile und haben in FFmpegs `configure` das letzte Wort.
- Eine geänderte Configure-Invocation (Flags, Compiler, exportierte CPPFLAGS/CFLAGS/CXXFLAGS/LDFLAGS/PKG_CONFIG_PATH der aufrufenden Shell — also auch ein Wechsel zu `neutrino-debug`/`neutrino-asan` oder eine andere Umgebung) wird beim nächsten `make neutrino` oder `make deps-ffmpeg` erkannt und baut FFmpeg von Grund auf neu; danach werden auch libstb-hal und Neutrino gegen die neue Bibliothek neu konfiguriert und gebaut. `sources/ffmpeg-*/build` muss dafür nicht mehr gelöscht werden.

Vor jeder Installation wird das im Sysroot vorhandene FFmpeg (Header/Libs/Binaries/PKG-CONFIG) entfernt, damit immer nur **eine** Version liegt und Neutrino konsistent dagegen gebaut werden kann.

**⚠️ WICHTIG: ABI-Kompatibilität und Clean-Builds**

Wenn du die GCC-Version wechselst, **müssen alle abhängigen Komponenten neu gebaut werden**, um ABI-Inkompatibilitäten zu vermeiden:

```bash
# 1. Alte Artefakte aufräumen
make distclean              # Löscht alles inkl. GCC-Toolchains
# oder
make distclean-keep-toolchains  # Behält GCC-Toolchains (spart ~1h Build-Zeit)

# 2. GCC-Version persistent setzen (empfohlen!)
echo "TOOLCHAIN_GCC_VERSION := 15" >> Makefile.local

# 3. Falls GCC selbst gebaut: PATH erweitern
export PATH="$PWD/artifacts/toolchains/gcc-15.2.0/bin:$PATH"

# 4. Alles neu bauen
make bootstrap
```

**Warum?** Verschiedene GCC-Versionen haben unterschiedliche C++-ABIs (libstdc++). Wenn Neutrino mit GCC 15 gebaut wird, aber gegen FFmpeg/LuaJIT von GCC 12 linkt → **💥 Laufzeitfehler oder Crashes**

**Best Practice:**
- ✅ **`TOOLCHAIN_GCC_VERSION` in `Makefile.local` setzen** (garantiert Konsistenz)
- ✅ Immer mit `distclean` oder `distclean-keep-toolchains` starten bei GCC-Wechsel
- ✅ Für Experimente: Separates Build-Verzeichnis verwenden
- ✅ `make help` zeigt alle verfügbaren Toolchain-Targets
- ❌ **NICHT:** Per-Target unterschiedliche GCC-Versionen verwenden!

**Patches für Toolchain:**
Fixes nach `files/gcc-<version>/toolchain/*.patch` legen; `scripts/build_gcc.sh` wendet sie nach dem Entpacken automatisch an. Neutrino-spezifische Patches: `files/gcc-<version>/neutrino/*.patch`.

**Debug/Sanitizer bequem:**
`make neutrino-debug`, `make neutrino-asan`, `make neutrino-tsan`.

### Optional: eigene Voreinstellungen (Makefile.local)
- Kopiere `Makefile.local.sample` → `Makefile.local` und kommentiere gewünschte Zeilen ein.
- Typische Overrides:
  - `ALLOW_NON_ROOT := 1` für rootlose Targets (`deps`, `run-now`, `run-gdb` …).
  - `TOOLCHAIN_GCC_VERSION := 15` oder eigene `CC`/`CXX`-Pfade.
  - `DEBUG_BUILD`, `ENABLE_ASAN/TSAN/UBSAN` für Debug/Sanitizer.
  - `NEUTRINO_RUN_WRAPPER := gdb --args` für gdb/valgrind o. Ä. bei `make run`/`run-now`/`run-nspawn`.
  - Pfade wie `NEUTRINO_INSTALL_DIR`, `NEUTRINO_RUNTIME_PREFIX`, Ports/Host (`NEUTRINO_WEB_PORT`, `NEUTRINO_WEB_HOST`).
  - Hinweis: `NEUTRINO_WEB_PORT/NEUTRINO_WEB_HOST` werden nur beim erstmaligen Anlegen von `nhttpd.conf` durch `make runtime-sync` verwendet; vorhandene Werte werden nicht überschrieben.
- Alternativ pro Aufruf per Environment setzen (überschreibt `?=`-Defaults), z. B.:
  ```bash
  export TOOLCHAIN_GCC_VERSION=15
  export ALLOW_NON_ROOT=1
  make neutrino
  ```

### Plugin-Updates übernehmen
Nach Anpassungen am Mediathek-Plugin immer die Reihenfolge einhalten:

```bash
make clean-plugins   # optional, entfernt alte Artefakte aus artifacts/ und root/usr/var
make clean-plugin-neutrino-mediathek  # optional, nur dieses Plugin säubern
make list-cleanable-plugins  # optional, zeigt verfügbare Pluginnamen
make plugins
make runtime-sync
```

Nur so landet der neue Stand zuverlässig im gestagten `root/usr`.

### 4. Neutrino starten

**Hier anfangen: `make run`, als normaler Benutzer.**

```bash
make run
```

Das ist der ganze erste Start. Kein `sudo`, keine Konfiguration. Der Wrapper
setzt `SIMULATE_FE=1`, Neutrino kommt also ohne jede Tuner-Hardware hoch,
durchläuft seinen Startassistenten und öffnet sein Fenster. Die Weboberfläche
liegt dann unter <http://localhost:31344>. Alles außer Live-TV funktioniert so —
und genau davon gehen die Smoke-Tests aus.

> **Neutrino nicht mit `sudo` starten.** Es ist nicht nötig und scheitert meist:
> ein Root-Prozess hat keine Berechtigung für deinen X11-/Wayland-Display, das
> Fenster erscheint also nie. Root braucht man ausschließlich für echte Geräte —
> siehe [Hardware-Hinweise](HARDWARE.de.md); dort steht, wie man Tuner- und
> Eingabezugriff stattdessen über Gruppenmitgliedschaft bekommt.

Wenn das läuft, gibt es diese weiteren Startwege — für den Fall, dass du sie brauchst:

- `make run`: Host-Wrapper ohne Isolation, schnellster Start (Alias für `make run-direct`).
- `make run-nspawn`: systemd-nspawn/proot-Sandbox, nahe an der Zielbox, saubere Isolation.
- `make run-direct`: Explizite Host-Wrapper-Variante (identisch zu `make run`).
- `ALLOW_NON_ROOT=1 make run-now`: proot-Sandbox ohne Root; fällt bei fehlendem proot auf den Host zurück.

> Hinweis zu den Skripten: `scripts/run-neutrino.sh` (Bindestrich) ist der schlanke Host/GCC-Runtime-Wrapper (`make run`/`run-direct`). `scripts/run_neutrino.sh` (Underscore) kapselt proot/systemd-nspawn und wird von `make run-nspawn`/`run-now` verwendet.

#### 4.1 Standard (Host-Wrapper)
```bash
make run
# oder explizit:
make run-direct
```
Empfohlener Weg für schnelle Entwicklung: Startet Neutrino direkt auf dem Host ohne Isolation. Vor dem Start wird automatisch `make runtime-sync` ausgeführt; ein vorheriger `make neutrino`-Build ist daher weiterhin Voraussetzung (ansonsten weist das Target darauf hin).

#### 4.1a Optional: systemd-nspawn/proot (isoliert)
```bash
make run-nspawn
```
Nutzt `systemd-nspawn` oder `proot` für saubere Isolation, nahe an der Zielbox. Benötigt sudo bzw. proot. Vor dem Start wird automatisch `make runtime-sync` ausgeführt.

#### 4.2 Direkt auf dem Host (manuell)
```bash
make run-direct
# oder manuell mit GCC-Runtime:
./scripts/run-neutrino.sh
```
Aktualisiert `root/usr`, kopiert Basis-Konfigurationen und startet den Host-Wrapper. Dieser setzt `LD_LIBRARY_PATH` (inklusive `root/usr/lib/compat` und der GCC-Runtime aus `artifacts/toolchains/gcc-*`) sowie `SIMULATE_FE=1`, bevor `neutrino` ausgeführt wird – dadurch läuft Neutrino auch ohne reale Tuner stabil durch den Setup-Assistenten und meckert nicht über fehlende `GLIBCXX_*`-Symbole. Auch dieses Target stößt vor dem Start ein `runtime-sync` an und setzt daher voraus, dass vorher mindestens einmal `make neutrino` gebaut wurde. Für spätere manuelle Starts ohne `make run-direct` einfach `./scripts/run-neutrino.sh` nutzen (TOOLCHAIN_GCC_VERSION/TOOLCHAIN_PREFIX sind überschreibbar).

#### 4.3 Ohne Root (proot-Smoketest)
```bash
sudo apt install proot          # einmalig, falls noch nicht installiert
ALLOW_NON_ROOT=1 make run-now
```
Nutzt `proot` als chroot-Ersatz – ideal für schnelle Checks, wenn kein sudo verfügbar ist. Fehlt `proot`, fällt der Befehl automatisch auf den Host-Wrapper (`run-direct`) zurück; für die isolierte Variante `sudo apt install proot` (oder `make tools-install-proot`) ausführen. Wie bei den anderen Laufzielen wird vor dem Start `runtime-sync` ausgeführt, daher muss zuvor mindestens einmal `make neutrino` erfolgreich gelaufen sein.

> ℹ️ Neutrino signalisiert Shutdown/Reboot über Exitcode 1 bzw. 2. Die Wrapper geben dazu eine Info aus, behandeln dies aber nicht als Fehler.

#### 4.4 Debugging & Sanitizer-Läufe
- Schneller Debug-Build:  
  ```bash
  make neutrino-debug
  ALLOW_NON_ROOT=1 make run-gdb-debug
  ```
- Memory-Leaks/UB:  
  ```bash
  make neutrino-asan
  ALLOW_NON_ROOT=1 make run-asan          # ASan/UBSan
  make DEBUG_BUILD=1 ENABLE_UBSAN=1 neutrino   # UBSan-only Build
  ALLOW_NON_ROOT=1 make run-memcheck      # Valgrind-Variante, Logs unter logs/valgrind
  ```
- Threading-Probleme:  
  ```bash
  make neutrino-tsan
  ALLOW_NON_ROOT=1 make run-tsan          # TSAN
  ALLOW_NON_ROOT=1 make run-helgrind      # Valgrind/Helgrind
  ```
- Eigener Wrapper für Läufe:  
  ```bash
  NEUTRINO_RUN_WRAPPER="gdb --args" make run
  NEUTRINO_RUN_WRAPPER="valgrind --tool=memcheck" make run-now
  ```
  (funktioniert für run/run-now/run-nspawn; gdb-Optionen wie `NEUTRINO_GDB_AUTORUN` gelten weiterhin).

### 5. Smoke-Tests ausführen

Die Smoke-Tests durchlaufen eine kleine Auswahl automatisierter GUI-/Web-Szenarien
(z. B. Start, Menü-Navigation, grundlegende HTTP-APIs) und prüfen damit, ob das
frisch gebaute Image grundsätzlich funktioniert.

**Zwei Dinge müssen vorher stimmen, sonst ist der Lauf wertlos:**

1. **Neutrino muss bereits laufen.** Die GUI- und Web-Prüfungen hängen sich an
   eine laufende Instanz, sie starten keine. Also `make run` (oder `run-nspawn`,
   `run-now`, `run-direct`) in einem zweiten Terminal laufen lassen.
2. **Node.js/npm und Playwright** werden für den Web-Teil gebraucht
   (`npx playwright install`). Fehlen sie, werden die Web-Tests übersprungen,
   nicht ausgeführt — ein grünes Ergebnis sagt dann weniger, als es aussieht.

Für `make test-shell` gilt beides nicht: es prüft die Build-Logik selbst und
läuft überall, ohne Neutrino und ohne Netz.

```bash
make test-shell   # Unit-Tests der Build-Logik, ohne Voraussetzungen
make test         # vollständige Suite, braucht ein laufendes Neutrino (s. o.)
```

### 6. Pakete generieren (optional)
```bash
make package-appimage
make package-deb
make package-static
```
