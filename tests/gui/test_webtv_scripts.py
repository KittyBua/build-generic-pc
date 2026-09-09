# WORK-261/263/265: the WebTV scripts, exercised on the PC build.
#
# These three fixes were verified by hand on an h7 and nowhere else, which is
# how a regression in them stays invisible until someone zaps to ZDFsport. The
# PC build can drive the whole chain: an isolated Neutrino on its own Xvfb, the
# channel switch through the control API, remote-control keys through the input
# FIFO, and the screen through OCR.
#
# What is checked, and why each oracle exists:
#
#   1. The auto-scan of WEBTVDIR loads every source without a failure, and the
#      YouTube list carries its twelve channels. yt_live.xml used to hold raw
#      ampersands (WORK-265), which made the XML parser drop the whole file --
#      "failed" in the reload line, no bouquet, no channel.
#   2. A zap to ZDFsport reaches the resolver and the script paints its own
#      menu (WORK-261). Outside a live event the ZDF API answers with the
#      announced dates rather than a stream, so both outcomes are accepted:
#      a resolved stream, or the script menu on screen.
#   3. Exactly one resolve attempt follows one zap, and the GUI still takes
#      keys afterwards. This is the owner's report from the box: a dialog the
#      script opened could not be dismissed, the loader message kept coming
#      back, and zapping away was impossible. A second "start request accepted"
#      without a second zap is that loop.
#
# The reading hint (WORK-263) has an oracle of its own further down.
#
# Timing: the resolve runs on its own thread (movieplayer.cpp, webtvResolver-
# Thread) and talks to zdf.de, so the waits are generous. Log lines are the
# primary evidence: [webchannels] is INFO (DEBUG build only, hence the skip)
# and [webtv] is printf -- both are block-buffered into the log file, so the
# run gets libstdbuf in line-buffered mode. run-neutrino.sh passes the
# environment straight to exec, and IsolatedNeutrino copies os.environ.

import json
import os
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from . import utils
from .neutrino_run import (
    IsolatedNeutrino,
    OwnedDisplay,
    debug_logging_built_in,
    require_isolated_run,
    require_no_frontend,
    send_keys,
    settle,
)

# Not 31344: that is the port a developer's own `make run` sits on, and this
# test must not talk to it by accident.
HTTP_PORT = 31355
NHTTPD_CONF = (
    Path(__file__).resolve().parents[2]
    / "root" / "usr" / "var" / "tuxbox" / "config" / "nhttpd.conf"
)

# scripts/run-neutrino.sh execs root/usr/bin/neutrino, which `make
# runtime-sync` installs as a wrapper that sets LUA_PATH and then runs
# neutrino.real beside it. So the ELF to inspect is neutrino.real where the
# wrapper is in place, and neutrino itself where it is not. `make -C
# build/neutrino` updates neither -- only runtime-sync stages a fresh binary.
_BIN_DIR = Path(__file__).resolve().parents[2] / "root" / "usr" / "bin"
RUNTIME_BINARY = _BIN_DIR / "neutrino.real"
if not RUNTIME_BINARY.exists():
    RUNTIME_BINARY = _BIN_DIR / "neutrino"

RELOAD_DONE = "[webchannels] reload done"
START_ACCEPTED = "start request accepted"
READING_HINT = "Stream wird geladen"  # LOCALE_LIVESTREAM_READ_DATA, german


def _require_fresh_binary() -> None:
    """Guard against testing yesterday's build.

    `make -C build/neutrino` leaves the runtime root untouched, so a run
    started right after it exercises whatever `make neutrino` installed last --
    measured on 2026-09-09, when a first pass ran against a binary from another
    branch and produced a finding that was pure fiction. require_isolated_run()
    does not catch this: it looks for NEUTRINO_INSTALL_DIR, which `make
    tests-gui` never sets, so it either skips or checks a different tree than
    the one that starts.
    """
    if not RUNTIME_BINARY.exists():
        pytest.skip(f"{RUNTIME_BINARY} missing - run `make neutrino` first")
    # require_isolated_run() builds its path from these; point it at the tree
    # that `make neutrino` fills, so its check and this one agree.
    os.environ.setdefault(
        "NEUTRINO_INSTALL_DIR",
        str(Path(__file__).resolve().parents[2] / "artifacts" / "sysroot"),
    )


def _binary_has(symbol: str) -> bool:
    """Is a given change actually in the binary that will start?

    Symbol names survive stripping in the dynamic tables and, unlike the
    version string, they stay valid once the branch is merged into master.
    """
    try:
        return symbol.encode() in RUNTIME_BINARY.read_bytes()
    except OSError:
        return False


def _require_network() -> None:
    """The scripts fetch from zdf.de and sportschau.de; without a route out
    there is nothing to test and a red run would say the wrong thing."""
    for host in ("https://www.zdf.de/", "https://www.sportschau.de/"):
        try:
            urllib.request.urlopen(host, timeout=10).close()
        except (urllib.error.URLError, OSError) as exc:
            pytest.skip(f"no network route to {host}: {exc}")


def _seed_config(config: Path) -> None:
    (config / "zapit").mkdir(parents=True, exist_ok=True)
    # language: an unloadable language opens the start wizard and the run never
    # reaches live TV. webtv_xml_auto is on by default (neutrino.cpp) and is
    # written out anyway, so a changed default cannot silently empty the test.
    (config / "neutrino.conf").write_text(
        "language=deutsch\n"
        "webtv_xml_auto=1\n"
        "uselastchannel=0\n"
    )
    # The config tree is bind-mounted over CONFIGDIR, so the web server finds
    # only what is placed here. Keep the shipped paths, move the port -- by
    # pattern, not by literal: the shipped default is 80, a developer's copy
    # says 31344, and a run that silently keeps either gets no web server at
    # all (port 80 needs root, and yhttpd then aborts after trying 8080).
    text, count = re.subn(
        r"^WebsiteMain\.port=.*$",
        f"WebsiteMain.port={HTTP_PORT}",
        NHTTPD_CONF.read_text(),
        flags=re.MULTILINE,
    )
    assert count == 1, f"expected one port line in {NHTTPD_CONF}, replaced {count}"
    (config / "nhttpd.conf").write_text(text)


def _line_buffered_env() -> None:
    """Neutrino's log lines are printf/INFO into a redirected stdout, which
    glibc buffers in 4k blocks; evidence that never leaves the buffer cannot be
    waited for. stdbuf's preload switches the stream to line buffering."""
    preload = Path("/usr/libexec/coreutils/libstdbuf.so")
    if not preload.exists():
        pytest.skip(f"{preload} missing; log lines would stay block-buffered")
    os.environ["LD_PRELOAD"] = str(preload)
    os.environ["_STDBUF_O"] = "L"
    os.environ["_STDBUF_E"] = "L"


class _Api:
    """The control API of the instance under test."""

    def __init__(self, port: int = HTTP_PORT):
        self.base = f"http://127.0.0.1:{port}"

    def get(self, path: str, timeout: float = 15) -> str:
        with urllib.request.urlopen(self.base + path, timeout=timeout) as response:
            return response.read().decode("utf-8", "replace")

    def wait_until_up(self, instance: IsolatedNeutrino, timeout: float = 60) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert instance.alive(), "Neutrino died before its web server answered"
            try:
                self.get("/control/version", timeout=3)
                return
            except (urllib.error.URLError, OSError):
                time.sleep(1)
        pytest.fail(f"control API did not answer on port {HTTP_PORT} within {timeout:.0f} s")

    def bouquet_number(self, title: str) -> int:
        """getbouquets answers '<nr> <name>' per line."""
        listing = self.get("/control/getbouquets?mode=TV")
        for line in listing.splitlines():
            number, _, name = line.strip().partition(" ")
            if title.lower() in name.lower() and number.isdigit():
                return int(number)
        pytest.fail(f"no bouquet named like {title!r}; got:\n{listing}")

    def channels(self, bouquet: int) -> list:
        raw = self.get(f"/control/getbouquet?format=json&mode=TV&bouquet={bouquet}")
        try:
            return json.loads(raw)["data"]["channels"]
        except (ValueError, KeyError) as exc:
            pytest.fail(f"unreadable bouquet {bouquet} ({exc}): {raw[:400]}")

    def zap_to(self, channel_id: str) -> None:
        answer = self.get(f"/control/zapto?{channel_id}").strip()
        assert answer.startswith("ok"), f"zapto {channel_id} answered {answer!r}"


def _settle_startup(instance: IsolatedNeutrino) -> None:
    """Let the start finish before anything zaps.

    Startup ends in a hint box raised from CNeutrinoApp::run, and CHintBox::exec
    hands application messages to CNeutrinoApp::handleMsg. A zap that arrives
    there runs the whole WebTV resolve *inside* that box, the script's own menu
    opens inside that, and its CMenuWidget::exec hands messages to handleMsg a
    second time. Measured on 2026-09-09: that nesting ends in SIGSEGV in
    CChannelList::adjustToChannelID -- a real defect, but not the one this test
    is about, and it makes every oracle below meaningless.

    So wait for the input FIFO (Neutrino opens it late in the start), dismiss
    whatever box is up, and give the paint a moment.
    """
    fifo = Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input"))
    deadline = time.monotonic() + 40
    while not fifo.exists() and time.monotonic() < deadline:
        assert instance.alive(), "Neutrino died during startup"
        time.sleep(0.5)
    assert fifo.exists(), "the input FIFO never appeared; Neutrino never finished starting"
    time.sleep(3)
    send_keys("BACK", settle_for=3.0)
    assert instance.alive(), "Neutrino died while the startup box was dismissed"


def _start(tmp_path: Path, display: str, name: str) -> IsolatedNeutrino:
    workdir = tmp_path / name
    (workdir / "config").mkdir(parents=True)
    _seed_config(workdir / "config")
    instance = IsolatedNeutrino(workdir, display, simulate_fe="1")
    assert instance.wait_for(RELOAD_DONE, timeout=90), (
        "the webtv sources were never reloaded; last log lines:\n"
        + "\n".join(instance.log.read_text(errors="replace").splitlines()[-15:])
    )
    _settle_startup(instance)
    return instance


@pytest.fixture
def private_display(monkeypatch):
    """A display of this test's own, never the developer's session.

    OwnedDisplay prefers an answering DISPLAY, and on a desktop that means the
    screenshots below would catch whatever window happens to overlap Neutrino
    -- `import -window` reads back the frame buffer, not the window's own
    contents. Dropping DISPLAY first forces the private Xvfb, where Neutrino is
    the only thing on screen. Measured: with the session display, the OCR of a
    ZDFsport shot came back full of editor text.
    """
    monkeypatch.delenv("DISPLAY", raising=False)
    display = OwnedDisplay()
    try:
        yield display
    finally:
        display.close()


def _resolve_evidence(instance: IsolatedNeutrino, script: str) -> str:
    return "\n".join(
        line for line in instance.log.read_text(errors="replace").splitlines()
        if "[webtv]" in line and script in line
    )


def _zap_and_wait(api: _Api, instance: IsolatedNeutrino, bouquet_title: str,
                  script: str) -> int:
    """Zap to the first channel of a bouquet, wait for the resolver to pick it
    up, and hand back how many resolve attempts had run before the zap."""
    number = api.bouquet_number(bouquet_title)
    channels = api.channels(number)
    assert channels, f"bouquet {bouquet_title!r} carries no channel"
    before = instance.log.read_text(errors="replace").count(START_ACCEPTED)
    api.zap_to(channels[0]["id"])
    assert instance.wait_for(f"script={script}", timeout=45), (
        f"no resolve attempt for {script} within 45 s after the zap; "
        f"[webtv] lines so far:\n{_resolve_evidence(instance, script)}"
    )
    return before


@pytest.mark.gui
def test_webtv_scripts_resolve_without_looping(tmp_path: Path, private_display) -> None:
    _require_fresh_binary()
    require_isolated_run()
    require_no_frontend()
    if not debug_logging_built_in():
        pytest.skip("needs a DEBUG build: [webchannels] is an INFO macro and stays empty otherwise")
    _require_network()
    _line_buffered_env()

    instance = _start(tmp_path, private_display.display, "webtv")
    api = _Api()
    try:
        # ---- oracle 1: every source loaded, the YouTube list is complete ----
        reload_lines = [
            line for line in instance.log.read_text(errors="replace").splitlines()
            if RELOAD_DONE in line and "mode=webtv" in line
        ]
        assert reload_lines, "no webtv reload line in the log"
        reload_line = reload_lines[-1]
        counts = dict(re.findall(r"(\w+)=(\d+)", reload_line))
        assert counts.get("failed") == "0", f"a webtv source failed to load: {reload_line}"
        assert counts.get("sources") == counts.get("loaded"), (
            f"not every source produced channels: {reload_line}"
        )
        assert int(counts.get("loaded", 0)) >= 4, (
            f"fewer sources than the four shipped xml files: {reload_line}"
        )

        api.wait_until_up(instance)
        youtube = api.channels(api.bouquet_number("YouTube Livestreams"))
        # yt_live.xml ships twelve channels; a parser that trips over an
        # unescaped ampersand delivers none of them.
        assert len(youtube) == 12, (
            f"expected the 12 channels of yt_live.xml, got {len(youtube)}"
        )

        # ---- oracle 2: zdfsport reaches the resolver and shows its menu ----
        before = _zap_and_wait(api, instance, "ZDFsport Livestreams", "zdfsport")
        time.sleep(8)
        assert instance.alive(), (
            "Neutrino died while resolving zdfsport; last log lines:\n"
            + "\n".join(instance.log.read_text(errors="replace").splitlines()[-10:])
        )
        shot = tmp_path / "zdfsport.png"
        settle(shot, private_display.display, tries=10)
        screen = utils.ocr_image(shot)
        log = instance.log.read_text(errors="replace")
        assert "resolved stream" in log or "ZDFsport" in screen, (
            "zdfsport neither resolved a stream nor put its menu on screen; "
            f"OCR was:\n{screen[:600]}\n[webtv] lines:\n{_resolve_evidence(instance, 'zdfsport')}"
        )

        # ---- oracle 3: one zap, one resolve, and the GUI still takes keys ----
        send_keys("BACK", settle_for=8.0)
        after = instance.log.read_text(errors="replace").count(START_ACCEPTED)
        assert after - before == 1, (
            f"{after - before} resolve attempts for one zap: the failed resolve "
            "started another one (the rezap path in restoreNeutrino), which is "
            "the loop reported from the box"
        )
        assert instance.alive(), "Neutrino died while the script menu was open"

        send_keys("MENU", settle_for=4.0)
        menu_shot = tmp_path / "mainmenu.png"
        settle(menu_shot, private_display.display, tries=10)
        menu_text = utils.ocr_image(menu_shot)
        assert "instellungen" in menu_text, (
            "the main menu did not open after the script menu was closed, so the "
            f"GUI is not taking keys any more; OCR was:\n{menu_text[:600]}"
        )
        send_keys("BACK", settle_for=2.0)

        # ---- oracle 4: sportschau behaves the same way ----
        before = _zap_and_wait(api, instance, "Sportschau Livestreams", "sportschau")
        time.sleep(8)
        shot = tmp_path / "sportschau.png"
        settle(shot, private_display.display, tries=10)
        screen = utils.ocr_image(shot)
        log = instance.log.read_text(errors="replace")
        assert "resolved stream" in log or "Sportschau" in screen, (
            "sportschau neither resolved a stream nor put its menu on screen; "
            f"OCR was:\n{screen[:600]}\n[webtv] lines:\n{_resolve_evidence(instance, 'sportschau')}"
        )
        send_keys("BACK", settle_for=8.0)
        after = instance.log.read_text(errors="replace").count(START_ACCEPTED)
        assert after - before == 1, (
            f"{after - before} resolve attempts for one zap to sportschau"
        )
        assert instance.alive(), "Neutrino died on the sportschau menu"
    finally:
        instance.stop()


@pytest.mark.gui
# WORK-263. Before 99998d6b3d the hint's loader kept painting over the script
# menu; a first measurement on 2026-09-09 still showed that -- against a binary
# that predated the fix (see _require_fresh_binary). With the listener in
# place the menu stands alone; this pins it.
def test_reading_hint_is_hidden_while_a_script_shows_its_menu(
    tmp_path: Path, private_display
) -> None:
    _require_fresh_binary()
    require_isolated_run()
    require_no_frontend()
    if not debug_logging_built_in():
        pytest.skip("needs a DEBUG build for the [webchannels] reload line")
    # Without the listener the hint was never meant to disappear, and a red
    # result would only say "this binary predates 99998d6b3d".
    if not _binary_has("setScriptUiListener"):
        pytest.skip("the installed binary predates 99998d6b3d (no script-UI listener)")
    _require_network()
    _line_buffered_env()

    instance = _start(tmp_path, private_display.display, "hint")
    api = _Api()
    try:
        api.wait_until_up(instance)
        _zap_and_wait(api, instance, "ZDFsport Livestreams", "zdfsport")
        # Three looks spread over the open menu: the hint is painted by a timer,
        # so a single frame could catch it between two paints.
        seen = []
        for index in range(3):
            time.sleep(6)
            shot = tmp_path / f"hint-{index}.png"
            settle(shot, private_display.display, tries=8)
            text = utils.ocr_image(shot)
            if "ZDFsport" not in text and "resolved stream" in instance.log.read_text(errors="replace"):
                pytest.skip("a live event is running: the script resolves instead of showing its menu")
            seen.append(READING_HINT in text)
        assert not any(seen), (
            f"the reading hint was on screen in {sum(seen)} of {len(seen)} looks "
            "while the script menu was open"
        )
    finally:
        instance.stop()
