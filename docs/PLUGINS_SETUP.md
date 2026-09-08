# Plugins bauen und installieren

Der Generic-PC-Build baut Plugins **nicht selbst**. Er besorgt die Quellen und
ruft dann das Makefile des jeweiligen Plugin-Repositories auf. Dieses Dokument
beschreibt diesen Vertrag und wie man ihn nutzt.

*English: this build delegates building and installing to each plugin
repository. The contract is the `install` target described below.*

## Kurzfassung

```bash
make plugins
```

Das genügt. Fehlende Plugin-Quellen werden automatisch über HTTPS geklont; ein
vorheriger `make neutrino`-Lauf wird bei Bedarf selbst angestoßen.

## Welche Plugins kennt der Build?

```bash
make list-plugin-targets      # Namen für plugin-install-<name>
make plugin-install-<name>    # ein einzelnes Plugin
```

| Plugin | Quelle | Status |
| --- | --- | --- |
| `neutrino-mediathek` | `tuxbox-neutrino/plugin-lua-neutrino-mediathek` | wird gebaut |
| `logoupdater` | `tuxbox-neutrino/plugin-lua-logoupdater` | wird gebaut |
| `webtv` | `tuxbox-neutrino/plugin-scripts-lua`, Verzeichnis `plugins/webtv` | wird kopiert, kein Build |
| `FritzInfoMonitor` | — | auf dem PC bewusst übersprungen (braucht Framebuffer- und RC-Gerät der Box) |
| `FritzCallMonitor` | `tuxbox-neutrino/FritzCallMonitor` | wird gebaut |
| `tuxwetter` | `tuxbox-neutrino/plugin-tuxwetter` | wird gebaut |

## Pflicht- und optionale Plugins

Ein einzelnes defektes Plugin bricht den Lauf **nicht** ab. Am Ende steht eine
Übersicht, und nur ein Fehlschlag in `PLUGINS_REQUIRED` lässt `make plugins`
mit einem Fehlerstatus enden:

Standardmäßig sind `neutrino-mediathek`, `logoupdater`, `fritzcall` und
`tuxwetter` Pflicht; `fritzinfo` ist optional (box-only, auf dem PC bewusst
übersprungen) und `webtv` ebenfalls — es sind reine Skripte ohne Build, die
zum Testen da sind und einen sonst vollständigen Lauf nicht scheitern lassen
sollen. Die Liste lässt sich überschreiben:

```make
# Makefile.local
PLUGINS_REQUIRED := neutrino-mediathek logoupdater
```

Einmalig geht es auch direkt:

```bash
make plugins PLUGINS_REQUIRED="neutrino-mediathek logoupdater"
```

## Der Vertrag zwischen Build und Plugin-Repository

Jedes Plugin-Repository muss ein **`Makefile` mit einem `install`-Target**
mitbringen. Der Build übergibt:

| Variable | Bedeutung |
| --- | --- |
| `DESTDIR` | Staging-Wurzel (Sysroot) |
| `PREFIX` | Präfix darin, für Lua-Plugins `<prefix>/share/tuxbox/neutrino` |
| `PLUGIN_SUBDIR` | Unterverzeichnis für klassische Plugins, i. d. R. `plugins` |
| `LUAPLUGIN_SUBDIR` | Unterverzeichnis für Lua-Plugins, i. d. R. `luaplugins` |
| `CC`, `CXX`, `PKG_CONFIG`, `CPPFLAGS`, `CXXFLAGS`, `LDFLAGS` | Toolchain für native Plugins |

Erfüllt ein Repository den Vertrag nicht, meldet der Build das ausdrücklich und
nennt Repository, erwartete Datei und den Ausweg über `<PLUGIN>_GIT_REF`.

## Installationspfade

Maßgeblich sind — mit `tuxbox/`-Segment:

```
$(DESTDIR)$(PREFIX)/share/tuxbox/neutrino/plugins
$(DESTDIR)$(PREFIX)/share/tuxbox/neutrino/luaplugins
$(DESTDIR)$(PREFIX)/share/tuxbox/neutrino/webtv
$(DESTDIR)$(PREFIX)/lib/tuxbox/neutrino/plugins
```

Nach `make runtime-sync` liegen sie zusätzlich unter `root/usr/...` und sind
damit für `make run` sichtbar.

## Nützliche Variablen

| Variable | Standard | Zweck |
| --- | --- | --- |
| `PLUGINS_DIR` | `./plugins` | Verzeichnis mit eigenen Plugin-Unterprojekten |
| `PLUGINS_REQUIRED` | `neutrino-mediathek logoupdater fritzcall tuxwetter` | Plugins, deren Fehlschlag den Build scheitern lässt |
| `NEUTRINO_MEDIATHEK_GIT_URL` / `_GIT_REF` | öffentliche URL / leer | Quelle des Mediathek-Plugins |
| `LOGOUPDATER_GIT_URL` / `_GIT_REF` | öffentliche URL / leer | Quelle des Logoupdaters |
| `FCM_GIT_URL` / `_GIT_REF` | öffentliche URL / leer | Quelle des FritzCallMonitors |
| `TUXWETTER_GIT_URL` / `_GIT_REF` | öffentliche URL / leer | Quelle des Tuxwetter-Plugins |
| `NEUTRINO_MEDIATHEK_SRC` | `./sources/neutrino-mediathek` | vorhandene Quelle statt Clone verwenden |
| `PLUGIN_SCRIPTS_LUA_GIT_URL` / `_GIT_REF` | öffentliche URL / leer | Quelle der gemeinsamen Lua-Helfer (json, feedparser, n_gui, n_helpers) |
| `NEUTRINO_LUA_HELPERS_SRC` | `./sources/plugin-scripts-lua/share/lua` | vorhandenes Helfer-Verzeichnis (mit `5.x/`) statt Clone verwenden |
| `WEBTV_SRC` | `./sources/plugin-scripts-lua/plugins/webtv` | Verzeichnis mit den WebTV-Skripten und -Listen |

Aufräumen:

```bash
make list-cleanable-plugins
make clean-plugin-<name>
make clean-plugins
```

## WebTV auf dem PC testen

Die WebTV-Gruppe (`zdfsport`, `sportschau`, `yt_live`, `plutotv_us` und der
gemeinsame Helfer `best_bitrate_m3u8`) besteht aus Lua-Skripten und XML-Listen.
Sie werden flach nach `share/tuxbox/neutrino/webtv` kopiert — genau dorthin, wo
sie auch auf der Box liegen.

```bash
make plugin-install-webtv     # oder make plugins
make run
```

Neutrino liest beim Start beide WebTV-Verzeichnisse: das gerade befüllte
`root/usr/share/tuxbox/neutrino/webtv` und daneben
`root/usr/var/tuxbox/neutrino/webtv`. Aus jeder `.xml` wird ein Bouquet, die
`script="..."`-Angabe darin verweist auf das `.lua` im selben Verzeichnis.
**Eigene Listen gehören in den `var`-Zweig**: dort bleiben sie liegen, während
`make clean-plugin-webtv` nur den kopierten Paketstand entfernt.

Was dabei geprüft werden kann, ohne eine Box anzufassen: ob die Bouquets
erscheinen (`http://localhost:31344/control/getbouquets`), ob ein Skript beim
Umschalten überhaupt eine URL liefert (im Log `start request accepted` gefolgt
von `resolved stream`) und ob seine Menüs und Meldungen richtig aussehen.
Lua ist hier LuaJIT, also Lua 5.1; `json.lua` und die übrigen Helfer stehen
über `LUA_PATH` bereit, `DIR.CONFIGDIR` zeigt auf `root/usr/var/tuxbox/config`.

## Einen anderen Plugin-Branch bauen

`FritzCallMonitor` und `tuxwetter` liefern das oben beschriebene `Makefile` auf
ihrem Standard-Branch (`master`); beide werden gebaut und stehen in
`PLUGINS_REQUIRED`. Wer stattdessen einen anderen Branch bauen will, setzt den
passenden `*_GIT_REF`:

```bash
make plugins TUXWETTER_GIT_REF=<branch> FCM_GIT_REF=<branch>
```

## Ein eigenes Plugin ergänzen

Siehe [HOWTO_ADD_PLUGIN.de.md](HOWTO_ADD_PLUGIN.de.md).
