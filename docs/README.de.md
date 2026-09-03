# Neutrino Generic Build (generic-pc)

Neutrino ist eine freie Digital-TV-Oberfläche. Dieses Repository stellt eine vollständig Make-basierte Build- und Testumgebung für Desktop-/Laptop-Systeme (x86_64) bereit.

## Was gebaut wird — und wohin es landet

`make bootstrap` durchläuft vier Stufen in dieser Reihenfolge. Wer das Layout
kennt, liest den Rest dieser Seite und jede Fehlermeldung deutlich leichter:

| Stufe | Was passiert | Wohin |
|---|---|---|
| Abhängigkeiten | Host-Pakete werden geprüft (`deps-doctor`) und auf Wunsch installiert | dein System |
| Third Party | FFmpeg, LuaJIT, giflib und libdvbsi++ werden geladen und übersetzt | `archive/` (Tarballs), `sources/` (entpackt), `artifacts/sysroot/` (installiert) |
| libstb-hal | Die Hardware-Abstraktionsschicht, Variante generic-pc | `build/libstb-hal/` → `artifacts/sysroot/` |
| Neutrino | Die Anwendung selbst | `build/neutrino/` → `artifacts/sysroot/` |

Danach stellt `make run` einen lauffähigen Baum unter `root/` bereit und startet ihn.

Drei dieser Verzeichnisse sollte man sich merken:

- **`sources/`** — sämtliche externen Quellbäume, bei Bedarf geklont oder
  entpackt. Nicht von git verwaltet; nichts davon liegt in diesem Repository.
  Neutrino, libstb-hal, FFmpeg und jedes Plugin werden aus ihren eigenen
  Upstream-Repositories geholt, sobald sie gebraucht werden.
- **`artifacts/sysroot/`** — das Staging-Präfix, gegen das alles gebaut wird.
- **`build/`** — Objektverzeichnisse außerhalb der Quellen, eines pro Komponente.

`make clean` leert `build/`, `make distclean` räumt alles ab, inklusive der
selbst gebauten Toolchains. Beides fasst deine Systempakete nicht an.

### Platz und Zeit

Gemessen an einem fertigen Standard-Build (ohne Sanitizer-Varianten):

| | |
|---|---|
| `sources/` (FFmpeg, Neutrino, libstb-hal) | ~290 MB |
| `build/` | ~125 MB |
| `artifacts/sysroot/` | ~55 MB |
| `archive/` (geladene Tarballs) | ~17 MB |
| **Summe für den ersten Build** | **~500 MB**, also ~2 GB frei halten |

Das erste `make bootstrap` übersetzt FFmpeg aus den Quellen, und dieser eine
Schritt bestimmt die Laufzeit — es ist eine komplette Medienbibliothek, keine
kleine Abhängigkeit. Hier gemessen: ein sauberer FFmpeg-Build brauchte **rund 8 Minuten**. Er wird
bewusst mit `-j1` gebaut (parallele FFmpeg-Builds laufen in Races), mehr Kerne
beschleunigen diesen Schritt also **nicht** — auf jeder Maschine mit
vergleichbarer Single-Core-Leistung ist mit einem ähnlichen Wert zu rechnen,
auf älteren oder gedrosselten mit mehr.

Genau hier vermuten die meisten, es hänge. Tut es nicht, es compiliert. Spätere
Builds überspringen ihn vollständig — eine Stempeldatei hält fest, dass er
installiert ist —, ein normaler `make neutrino`-Zyklus ist daher deutlich
kürzer.

Für `make bootstrap` insgesamt, von Anfang bis Ende in einem frischen
Debian-12-Container gemessen, in dem nur `git` und `make` vorinstalliert waren:
**13 Minuten**, am Ende steht ein lauffähiges `neutrino`-Binary.

`FFMPEG_USE_SYSTEM=1` kann ihn überspringen, aber nur wenn die Distribution
**exakt** die Version aus `FFMPEG_VERSION` mitbringt (derzeit 5.1.4). Jede
andere Version — neuer, älter oder nur gepatcht — wird abgelehnt und der
lokale Build läuft trotzdem; auf den meisten Distributionen ändert das Flag
also nichts.

Der lokale FFmpeg wird mit `--enable-gnutls` konfiguriert, damit `https`
funktioniert — Streams liefern auch hinter einem `http`-Einstieg heute
https-Segmente und -Schlüssel. Dafür braucht der Host `libgnutls28-dev` (dnf:
`gnutls-devel`), siehe unten. Abwahl: `FFMPEG_CONFIGURE_FLAGS := --disable-gnutls`
in `Makefile.local` — auch dann, wenn dort ein anderes TLS-Backend gewählt wird
(`--enable-openssl`, `--enable-mbedtls`): FFmpegs `configure` lehnt zwei
Backends zugleich ab; eine geänderte Configure-Zeile löst beim nächsten
`make neutrino` (oder `make deps-ffmpeg`) von selbst ein Reconfigure samt
Rebuild aus (danach bauen auch libstb-hal und Neutrino gegen die neue
Bibliothek neu).

## Voraussetzungen

- Linux x86_64 (generic-pc)
- `git` und `make`, um den ersten Befehl überhaupt ausführen zu können.
- Root-Rechte nur für die Paketinstallation. Nutze den Befehl, den
  `make deps-doctor` ausgibt (`sudo apt-get install ...`), und rufe `make`
  selbst **nicht** mit `sudo` auf — sonst gehören `.venv/` und
  `artifacts/sysroot/` anschließend `root` und der Build scheitert an Rechten.
- `ALLOW_NON_ROOT=1` erlaubt lediglich rootlose Targets; es installiert nichts.
- `make deps-doctor` prüft den Rechner, ohne etwas zu verändern, und nennt die
  fehlenden Pakete samt fertigem Installationsbefehl. Fehlen Pflichtpakete,
  bricht der Build vorher ab statt später im `configure`.

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

Hinweis: Falls `libfuse2` nicht verfügbar ist, nutze `libfuse2t64`.

### Fedora/RHEL (dnf)

Hinweis: Eine Fedora-Version verwenden, für die es fertige Python-Wheels für
numpy und opencv-python-headless gibt (z. B. Fedora 41, Python 3.13). Auf dem
neuesten Fedora (aktuell Python 3.14) existieren diese Wheels noch nicht, sodass
`make deps` beim Bauen aus Quelle scheitert. Die CI pinnt aus demselben Grund
fedora:41.

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

Hinweis: Die System-ffmpeg-Entwicklungspakete fehlen oben bewusst — der Build
kompiliert ffmpeg standardmäßig lokal. Installiere sie nur für einen
Host-ffmpeg-Build (`FFMPEG_USE_SYSTEM=1`): apt `libavformat-dev libswscale-dev
libswresample-dev`; dnf `ffmpeg-devel` (auf Fedora aus RPMFusion).

### Optional: GStreamer-Playback (generic-pc)

Zusätzliche Pakete für `--enable-gstreamer` (libstb-hal):

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

Aktivierung z. B. in `Makefile.local`:

```make
LIBSTB_HAL_CONFIGURE_FLAGS := --enable-gstreamer
```

Hinweis: `make deps` nimmt die Pakete automatisch mit, wenn `LIBSTB_HAL_CONFIGURE_FLAGS` `--enable-gstreamer` enthält (alternativ `ENABLE_GSTREAMER=1 make deps`).

Optional: Node.js/npm und Playwright (`npx`) werden nur für Web-Tests benötigt (`make test-web`).

## Schnellnavigation

- [Projektüberblick](README.de.md)
- [Schnellstart](QUICKSTART.de.md)
- [Test-Handbuch](TESTING.de.md)
- [Paketierungsleitfaden](PACKAGING.de.md)
