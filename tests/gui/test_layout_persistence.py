# WORK-218: the pinned keyboard layout must survive a Neutrino restart,
# and a stale pin must fall back to the OSD language instead of landing
# on an arbitrary table.
#
# The in-process reopen test (test_input_dialog.py) proves the pin works
# across dialog boundaries; it cannot prove the config half - that
# saveSetup writes the pin to neutrino.conf and loadSetup reads it back
# into the resolution chain. These tests run their own Neutrino instance
# per scenario, tunerless-pattern style: a private mount namespace
# bind-mounts a throwaway copy of the config tree over the compile-time
# CONFIGDIR, so the prepared neutrino.conf is what the instance reads
# and the file it writes on shutdown is what the test inspects - the
# developer's real configuration is never touched.
#
# They also drive the LEGACY CKeyboardInput dialog ("Text input" in the
# test menu) on purpose: its entry path (setLayout) and its switch path
# (switchLayout) are the half of the feature the cc-dialog tests never
# execute.
#
# Like the tunerless tests these need an idle machine (the input FIFO is
# a compile-time path) and skip honestly when `make run` holds it.

import os
import shutil
import time
from pathlib import Path

import pytest

from . import utils
from .neutrino_run import (
CONFIG_MOUNT,
    IsolatedNeutrino,
    OwnedDisplay,
    require_isolated_run,
    send_keys,
    settle,
)

ROOT_DIR = Path(__file__).resolve().parents[2]

# Seconds to let the GUI settle after a key batch (matches the input
# dialog suite; menus open fast, the legacy dialog paints a keyboard).
SETTLE = 1.3


def _set_conf_value(conf: Path, key: str, value: str) -> None:
    """Set key=value in a neutrino.conf, replacing an existing line."""
    lines = conf.read_text(errors="replace").splitlines()
    kept = [l for l in lines if not l.startswith(f"{key}=")]
    kept.append(f"{key}={value}")
    conf.write_text("\n".join(kept) + "\n")


def _conf_value(conf: Path, key: str) -> str | None:
    for line in conf.read_text(errors="replace").splitlines():
        if line.startswith(f"{key}="):
            return line[len(key) + 1:]
    return None


def _prepared_instance(
    workdir: Path, display: str, language: str, keyboard_layout: str
) -> IsolatedNeutrino:
    """A Neutrino run on a copied config tree with the two keys set.

    The full tree is copied so the instance starts like the developer's
    - no first-run wizard, channels and zapit state present - and only
    the two keys under test differ. SIMULATE_FE=1 keeps the start on
    the normal path; the tunerless defect is not what is under test.
    """
    # Both checked before copying: a fresh checkout has no config tree
    # at all (make neutrino leaves the runtime tree incomplete), and
    # copytree would raise an ERROR where the honest answer is a skip.
    if not CONFIG_MOUNT.is_dir():
        pytest.skip("no config tree in the runtime tree - run `make run` once first")
    config = workdir / "config"
    shutil.copytree(CONFIG_MOUNT, config, symlinks=True)
    conf = config / "neutrino.conf"
    if not conf.exists():
        pytest.skip("no neutrino.conf in the runtime tree - run `make run` once first")
    _set_conf_value(conf, "language", language)
    _set_conf_value(conf, "keyboard_layout", keyboard_layout)
    return IsolatedNeutrino(workdir, display, simulate_fe="1")


def _send(*keys: str) -> None:
    """send_keys() with this module's settle pause, which every call here
    relied on: menus open fast, the legacy dialog paints a whole keyboard."""
    send_keys(*keys, settle_for=SETTLE)

def _wait_for_gui(instance: IsolatedNeutrino, display: str, shot: Path) -> None:
    """FIFO up is not GUI up: rcinput opens the pipe long before the
    boot zap, and keys sent into that gap are swallowed or land on live
    TV, where a menu walk's DOWNs zap channels instead (measured - the
    throwaway config's zapit log filled with zapToChannel calls). The
    boot zap in the log is the marker that the main loop took over."""
    fifo = Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input"))
    deadline = time.monotonic() + 60
    while not fifo.exists() and time.monotonic() < deadline:
        assert instance.alive(), "Neutrino died during startup"
        time.sleep(0.5)
    assert fifo.exists(), "input FIFO never appeared - rcinput did not come up"
    assert instance.wait_for("CChannelList::zapTo", timeout=60), (
        "the boot zap never showed up in the log - the GUI main loop "
        "did not come up"
    )
    settle(shot, display)


def _open_main_menu_proven(display: str, shot: Path, workdir: Path) -> None:
    """Open the main menu and prove it opened, retrying a swallowed MENU.

    A key that arrives while the start phase still owns the screen goes
    nowhere, and every step counted after it lands on live TV. The
    proof is pixel mass: the main menu paints a large window, so the
    screen must change massively between the settled pre and post
    shots; an unchanged screen means the MENU was swallowed and gets
    sent again instead of walked from.
    """
    pre = workdir / "menu_pre.png"
    for _attempt in range(3):
        _send("HOME")
        _send("HOME")
        settle(pre, display)
        _send("MENU")
        settle(shot, display)
        if utils.images_differ(pre, shot) > 50000:
            return
    pytest.fail("the main menu never opened - MENU swallowed three times")


def _open_legacy_text_input(display: str, shot: Path, workdir: Path) -> None:
    """Main menu -> Test menu (8 steps) -> "Text input" (10 steps).

    Same pinned-walk arithmetic as the cc-dialog suite: PAGEUP does not
    wrap, so a burst of them resets each menu to its first entry and
    the step counts hold from there. The caller verifies arrival by
    reading a layout token from the footer - a mis-stepped walk shows
    no such token and fails with a diagnosis instead of measuring the
    wrong screen.
    """
    _open_main_menu_proven(display, shot, workdir)
    _send(*(["PAGEUP"] * 5))
    for start in range(0, 8, 5):
        _send(*(["DOWN"] * min(5, 8 - start)))
    _send("OK")
    settle(shot, display)
    _send(*(["PAGEUP"] * 5))
    for start in range(0, 10, 5):
        _send(*(["DOWN"] * min(5, 10 - start)))
    _send("OK")
    settle(shot, display)


def _legacy_footer_token(shot: Path, display: str, tag: str) -> str:
    """The layout token in the legacy dialog's footer.

    The legacy dialog floats centered; on the fixed 1280x720 test
    display its footer row sits at 72-75%% of the screen height
    (measured from a captured strip). The band has to hold the footer
    row ALONE: whole-picture OCR mangled exactly the token next to the
    flag icon, and a wider band that still held two key-grid rows made
    tesseract's auto-segmentation shred boxed keys and footer alike.
    A narrow 69-79%% band reads cleanly, the same way the cc tests'
    footer strip does. Drifts the dialog's height, the token read
    fails loudly with the OCR text in the message rather than guessing.
    """
    settle(shot, display)
    screen_w, screen_h = utils.screenshot_size(shot)
    top = int(screen_h * 0.69)
    height = int(screen_h * 0.10)
    strip = utils.crop_region(
        shot, (0, top, screen_w, height), f"legacy_{tag}", scale=3
    )
    return utils.read_layout_token(strip, tag)


def _leave_legacy_dialog(display: str, shot: Path) -> None:
    """EXIT closes the unedited legacy dialog, HOMEs close the menus."""
    _send("EXIT")
    _send("HOME")
    _send("HOME")
    settle(shot, display)


@pytest.mark.gui
def test_pinned_layout_survives_restart_and_is_saved(
    owned_display: OwnedDisplay, tmp_path: Path
) -> None:
    """A pinned layout beats the OSD language after a restart, and a
    switch in the legacy dialog lands in the written neutrino.conf.

    language=english with keyboard_layout=deutsch: the dialog must open
    QWERTZ - only the pin can explain that, so this single readout
    proves loadSetup, the resolution chain and the legacy entry path at
    once. One MENU then exercises the legacy switch path, and the conf
    the instance writes on shutdown must carry the new pin.
    """
    require_isolated_run()
    instance = _prepared_instance(
        tmp_path, owned_display.display, language="english",
        keyboard_layout="deutsch",
    )
    shot = tmp_path / "screen.png"
    try:
        _wait_for_gui(instance, owned_display.display, shot)
        _open_legacy_text_input(owned_display.display, shot, tmp_path)

        opened = _legacy_footer_token(shot, owned_display.display, "pinned")
        assert opened == "QWERTZ", (
            f"dialog opened {opened!r} although keyboard_layout=deutsch "
            "is pinned - the pin lost against language=english"
        )

        _send("MENU")
        switched = _legacy_footer_token(shot, owned_display.display, "switched")
        assert switched == "QWERTY", (
            f"MENU in the legacy dialog shows {switched!r} - the legacy "
            "switch path did not advance the layout"
        )

        _leave_legacy_dialog(owned_display.display, shot)
    finally:
        instance.stop()

    saved = _conf_value(tmp_path / "config" / "neutrino.conf", "keyboard_layout")
    assert saved == "english", (
        f"neutrino.conf carries keyboard_layout={saved!r} after the "
        "switch to QWERTY - the pin did not reach the written config"
    )


@pytest.mark.gui
def test_stale_pin_falls_back_to_the_language(
    owned_display: OwnedDisplay, tmp_path: Path
) -> None:
    """A keyboard_layout value naming no known table must lose against
    the OSD language, not land on the first table by accident.

    language=deutsch with a nonsense pin: the dialog must open QWERTZ.
    Falling back to the first table instead would show QWERTY here -
    which is exactly what a naive "unknown means index 0" would do.
    """
    require_isolated_run()
    instance = _prepared_instance(
        tmp_path, owned_display.display, language="deutsch",
        keyboard_layout="nosuchlayout",
    )
    shot = tmp_path / "screen.png"
    try:
        _wait_for_gui(instance, owned_display.display, shot)
        _open_legacy_text_input(owned_display.display, shot, tmp_path)

        opened = _legacy_footer_token(shot, owned_display.display, "fallback")
        assert opened == "QWERTZ", (
            f"dialog opened {opened!r} although the pin is unknown and "
            "the language is deutsch - the fallback chain is broken"
        )

        _leave_legacy_dialog(owned_display.display, shot)
    finally:
        instance.stop()
