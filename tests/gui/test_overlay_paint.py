# Regression test for the overlay/paint protocol (WORK-178).
#
# Components that save the pixels underneath themselves reserve that area
# against painters in other threads, so a restore cannot undo their work. Both
# halves of that protocol hold one framebuffer-wide lock, and that lock is held
# across paint primitives - which run through CFrameBuffer::checkFbArea().
# checkFbArea() is not a passive test: with the mute icon on screen it hides and
# repaints that icon, and the icon is itself such a component, so the same
# thread takes the same lock again. A non-recursive lock froze the GUI right
# there, silently and without a crash.
#
# Muting is deliberate: it arms that mechanism. Be aware of what this test does
# NOT establish, though - it was measured against a build with the lock made
# non-recursive again, and stayed green. The re-entrant path needs a paint that
# both holds the lock and overlaps the icon rectangle, and the steps below did
# not produce one (tried with the menu centred and top-right). So this is a
# guard against the GUI locking up on these paths, not proof that a
# non-recursive lock would be caught here.
#
# What counts as "still alive" needs care. A deadlocked GUI thread does NOT
# freeze the whole screen: clock components paint from their own timer threads
# with CC_SAVE_SCREEN_NO and never take the lock, so pixels keep changing. A
# test asking "did anything change at all" would therefore pass on a deadlocked
# build. Instead each step must produce the large-area change its key is
# supposed to produce - opening or closing a full-screen menu moves tens of
# thousands of pixels, a ticking clock a few hundred.

import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from . import utils

# A menu opening or closing repaints a large share of the screen, a ticking
# clock a few hundred pixels. Derived from the actual screen size rather than
# hard-coded, so the test keeps its meaning at another resolution.
LARGE_CHANGE_RATIO = 0.02  # 2% of the screen, ~18k pixels at 1280x720
# The mute icon is small; requiring it to be exactly its own size would make the
# check brittle, so this only has to separate "something appeared" from noise.
ICON_CHANGE_MIN = 200


def _press(key: str) -> None:
    """Send one key, turning the known environment gaps into skips."""
    try:
        subprocess.run(
            [sys.executable, "-m", "tests.gui.send_keys", key],
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
        # Not a bare re-raise: CalledProcessError.__str__ carries only the
        # command and the exit status, and stderr is a local pytest does not
        # print. The diagnosis send_keys went to the trouble of writing would
        # never reach anyone.
        pytest.fail(f"send_keys failed and the reason was not an environment gap:\n{err}")


def _shot(tmp_path: Path, name: str) -> Path:
    path = tmp_path / f"{name}.png"
    utils.capture_x11(path)
    return path


def _screen_size(shot: Path):
    out = subprocess.run(
        ["identify", "-format", "%w %h", str(shot)],
        capture_output=True, check=True,
    ).stdout.decode().split()
    return int(out[0]), int(out[1])


@pytest.mark.gui
def test_gui_keeps_responding_while_muted(tmp_path: Path) -> None:
    utils.ensure_neutrino_running()
    if "DISPLAY" not in os.environ:
        pytest.skip("DISPLAY not set - run `make run` before executing GUI tests")
    # fail on a missing tool rather than after a minute of screenshots
    utils.require_binary("import")
    utils.require_binary("compare")
    utils.require_binary("identify")

    # Start from live TV whatever the previous test left open, so the keys below
    # mean what they are supposed to mean.
    for _ in range(3):
        _press("HOME")
        time.sleep(0.7)

    before_mute = _shot(tmp_path, "before_mute")
    width, height = _screen_size(before_mute)
    large_change = int(width * height * LARGE_CHANGE_RATIO)

    _press("MUTE")
    try:
        time.sleep(1.5)
        after_mute = _shot(tmp_path, "after_mute")
        # Without the icon on screen the fbArea mechanism is not armed and this
        # test silently degrades into "the menu opens". That happens whenever
        # the box was already muted when we arrived - then MUTE turned it off.
        icon = utils.images_differ(before_mute, after_mute)
        if icon < ICON_CHANGE_MIN:
            pytest.skip(
                f"muting changed only {icon} pixels - no mute icon appeared, so the "
                f"paths this test is about are not active (was the box already muted?)"
            )

        # Each entry: key, and whether it has to produce a large-area change.
        # The menu steps are the interesting ones - CMenuWidget::saveScreen()
        # is where the re-entrant checkFbArea() path is taken.
        for round_no in range(2):
            before = _shot(tmp_path, f"r{round_no}_before_menu")
            _press("MENU")
            time.sleep(2)
            after_open = _shot(tmp_path, f"r{round_no}_menu_open")
            opened = utils.images_differ(before, after_open)
            assert opened > large_change, (
                f"round {round_no}: pressing MENU while muted changed only {opened} "
                f"pixels - the menu did not open. A GUI thread stuck in the overlay "
                f"paint lock looks exactly like this, while clocks keep ticking."
            )

            _press("HOME")
            time.sleep(2)
            after_close = _shot(tmp_path, f"r{round_no}_menu_closed")
            closed = utils.images_differ(after_open, after_close)
            assert closed > large_change, (
                f"round {round_no}: the menu did not close again (only {closed} "
                f"pixels changed) - the GUI stopped processing keys."
            )
    finally:
        # leave the box as we found it, even if an assertion above failed or a
        # skip fired mid-loop with the menu still open
        _press("HOME")
        time.sleep(0.5)
        _press("MUTE")
