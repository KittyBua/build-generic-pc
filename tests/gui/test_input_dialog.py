# Regression test for the CCTextInputDialog keyboard scenario: the key
# selection must be visible (moving it changes pixels) and a layout
# round-trip must be pixel-stable (the footer used to shift and leave
# button remnants behind).
#
# Navigation is position-independent on purpose. Menus reopen on the
# entry that was selected when they last closed (CMenuGlobal keeps the
# selection per widget id even across rebuilds), so counting cursor
# steps from an unknown state lands wherever the previous visitor left
# off. PAGE_UP is the reset: unlike UP/DOWN it does not wrap ("...but
# not if already at top" in menue.cpp) - a few of them pin the
# selection to the first entry, and from there the step counts are
# fixed. Both diffs span the whole root window: the Xvfb display is
# exclusive to this Neutrino instance, and nothing ticks in the menu
# context - the round-trip == 0 assert would catch any moving element
# at once.

import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from . import utils

# Seconds to let the GUI settle after a key batch. Menus open fast, but
# the input dialog paints a full window with keyboard.
SETTLE = 1.3


def _send(*keys: str) -> None:
    try:
        subprocess.run(
            [sys.executable, "-m", "tests.gui.send_keys", *keys],
            check=True,
            capture_output=True,
        )
    except FileNotFoundError:
        pytest.skip("python3 not available to replay keys")
    except subprocess.CalledProcessError as exc:
        err = (exc.stderr or b"").decode(errors="ignore")
        reason = utils.send_keys_skip_reason(err)
        if reason:
            pytest.skip(reason)
        raise
    except SystemExit as exc:  # send_keys handles missing evdev
        pytest.skip(str(exc))
    time.sleep(SETTLE)


@pytest.mark.gui
def test_keyboard_selection_and_layout_roundtrip(tmp_path: Path) -> None:
    utils.ensure_neutrino_running()
    if "DISPLAY" not in os.environ:
        pytest.skip("DISPLAY not set – run `make run` before executing GUI tests")

    shot_open = tmp_path / "dialog_open.png"
    shot_focus = tmp_path / "keyboard_focused.png"
    shot_moved = tmp_path / "selection_moved.png"
    shot_round = tmp_path / "layout_roundtrip.png"

    # Ground state, then the pinned walk described above: reset each
    # menu to its first entry before counting. First entry -> Test menu
    # is 8 steps (main menu), Zurueck -> OSD-Components Demo is 5
    # (test menu), Zurueck -> CCTextInput Dialog with Keyboard is 20
    # (demo menu).
    _send("HOME", "HOME")
    _send("MENU")
    _send(*(["PAGEUP"] * 5))
    _send(*(["DOWN"] * 8 + ["OK"]))
    _send(*(["PAGEUP"] * 5))
    _send("DOWN", "DOWN", "DOWN", "DOWN", "DOWN", "OK")
    _send(*(["PAGEUP"] * 5))
    _send(*(["DOWN"] * 20 + ["OK"]))

    try:
        utils.capture_x11(shot_open)

        # The scenario seeds a value, so focus starts in the field; DOWN
        # drops onto the keyboard. The baseline is taken AFTER that
        # drop: it repaints the field as well, and diffing across it
        # would pass on the field change alone even with an invisible
        # key selection. The two RIGHTs then move nothing but the
        # selection.
        _send("DOWN")
        utils.capture_x11(shot_focus)
        _send("RIGHT", "RIGHT")
        utils.capture_x11(shot_moved)
        moved = utils.images_differ(shot_focus, shot_moved)
        assert moved > 1000, (
            f"moving the key selection changed only {moved} pixels - "
            "the selection highlight is not visible"
        )

        # Layout round-trip German -> English -> German. Two separate
        # sends: each switch rebuilds keyboard and footer.
        _send("MENU")
        _send("MENU")
        utils.capture_x11(shot_round)
        stray = utils.images_differ(shot_moved, shot_round)
        assert stray == 0, (
            f"layout round-trip left {stray} differing pixels - "
            "footer rebuild shifted or left remnants"
        )
    finally:
        # EXIT first for a possibly stacked message box, then HOME:
        # the first one already closes the whole menu stack
        # (RETURN_EXIT_ALL), the others are idle by then.
        _send("EXIT", "HOME", "HOME")
