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
# exclusive to this Neutrino instance, so the round-trip == 0 assert
# catches any moving element at once - which is why the one element
# that legitimately moves, Neutrino's on-screen clock, is measured and
# masked out instead of assumed absent. It paints from its own timer
# thread with CC_SAVE_SCREEN_NO and therefore draws over dialogs too.

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


def _leave_dialog() -> None:
    """Leave a dialog whose value was NOT edited: EXIT closes it right
    away, and the first HOME then closes the whole menu stack
    (RETURN_EXIT_ALL); the second is idle by then."""
    _send("EXIT", "HOME", "HOME")


def _leave_edited_dialog() -> None:
    """Leave a dialog whose value WAS edited.

    EXIT does not close such a dialog, it asks whether to discard the
    changes - and EXIT on that box only cancels it. Left that way the
    GUI stays modal and swallows the keys meant for the screen below,
    so whatever runs next sees a picture that never changes. OK is the
    box's default button and discards, which also keeps the edit out of
    the bound value that the next run would otherwise start from.
    """
    _send("EXIT")
    _send("OK")
    _send("HOME", "HOME")


def _walk_down(steps: int, chunk: int = 5) -> None:
    """Move a menu selection down, in small batches with a settle
    between them.

    One long burst repaints the menu once per step and outruns it; keys
    then go missing and the OK behind them activates whatever entry the
    selection actually reached. That failed about one run in five, and
    it failed silently - the walk simply ended up on another screen.
    """
    for start in range(0, steps, chunk):
        _send(*(["DOWN"] * min(chunk, steps - start)))


def _open_keyboard_dialog(tmp_path: Path) -> bool:
    """Ground state, then the pinned walk described above: reset each
    menu to its first entry before counting. First entry -> Test menu
    is 8 steps (main menu), Zurueck -> OSD-Components Demo is 5
    (test menu), Zurueck -> CCTextInput Dialog with Keyboard is 20
    (demo menu).

    False when the screen never came to rest between two steps: the keys
    after that one went out over a repaint and landed on whatever was
    still underneath, so the walk cannot be trusted and the caller had
    better start over rather than measure the result."""
    settled = True
    # One HOME per send, not both in one batch: closing a painted dialog
    # takes a moment, and MENU arriving while it is still up does not
    # open the main menu - the dialog binds MENU to its layout switch and
    # swallows it. Everything after that lands on live TV, where the
    # DOWN keys zap instead of moving a menu selection.
    _send("HOME")
    _send("HOME")
    # Not one key more until the screen has settled: a key that arrives
    # mid-repaint lands on whatever is still underneath, and every step
    # counted from there is off.
    settled &= utils.wait_until_static(tmp_path)
    _send("MENU")
    settled &= utils.wait_until_static(tmp_path)
    _send(*(["PAGEUP"] * 5))
    _walk_down(8)
    _send("OK")
    settled &= utils.wait_until_static(tmp_path)
    _send(*(["PAGEUP"] * 5))
    _walk_down(5)
    _send("OK")
    settled &= utils.wait_until_static(tmp_path)
    _send(*(["PAGEUP"] * 5))
    _walk_down(20)
    _send("OK")
    settled &= utils.wait_until_static(tmp_path)

    return settled


def _clock_band(tmp_path: Path) -> tuple[int, int, int, int] | None:
    """The band the on-screen clock repaints in, or None when nothing
    trustworthy moves. Call only with the focus on the KEYBOARD.

    With the focus in the input field the caret blinks, and a probe would
    report the text row instead of the clock - which is fatal, because
    the text row is what two of these tests compare. The caret stops when
    the focus leaves the field, so from the keyboard the clock is the
    only thing left that moves.

    ticking_band() refuses to hand out a band that reaches into the
    dialog, so a mistake here costs a failed comparison rather than a
    silently masked one.
    """
    return utils.ticking_band(tmp_path)


def _require_gui() -> None:
    utils.ensure_neutrino_running()
    if "DISPLAY" not in os.environ:
        pytest.skip("DISPLAY not set – run `make run` before executing GUI tests")


def _try_locate_space_key(
    tmp_path: Path, shot_selected: Path, shot_neighbor: Path
):
    """Select the space key and return its interior crop plus the clock
    band, or None when what is on screen is not the keyboard.

    Leaves the selection on the neighbouring key, one step to the left.

    The key is found by moving, not by geometry: moveFocus() clamps at
    the grid edges, so overshooting DOWN and RIGHT lands on the
    bottom-right cell whatever was selected before, and the diff between
    the two shots is exactly those two keys - once the self-repainting
    band is masked out, or the clock in the corner would widen that diff
    to most of the screen.

    That diff is also the proof that the walk arrived: a menu row moves
    differently from a pair of grid cells, so the caller can tell a
    mis-stepped walk from a real defect instead of measuring the wrong
    screen.
    """
    _send("DOWN")
    _send(*(["DOWN"] * 4))
    _send(*(["RIGHT"] * 14))
    # Probed here and not earlier: the focus is on the keyboard from the
    # first DOWN on, so the field caret has stopped blinking.
    ticking = _clock_band(tmp_path)

    # Measured up to three times. A whole-frame diff sees everything that
    # repainted between the two shots, and now and then something else
    # does - a late repaint of the dialog, an overlay settling. Those do
    # not repeat, so a measurement that does not look like two adjacent
    # cells is taken again rather than believed. RIGHT clamps at the
    # grid edge, so each attempt starts on the space key again.
    box = (0, 0, 0, 0)
    for _attempt in range(3):
        _send(*(["RIGHT"] * 14))
        # Anchored to the grid edge, not to the step count: 13 steps
        # reach the last of 14 columns and the 14th is slack, so a single
        # lost RIGHT would leave the selection one cell short and every
        # measurement below would describe the wrong key. One more RIGHT
        # must therefore change nothing - that is what "clamped at the
        # edge" looks like.
        utils.capture_x11(shot_selected)
        _send("RIGHT")
        utils.capture_x11(shot_neighbor)
        if utils.images_differ(
            utils.blank_region(shot_selected, ticking, "notick"),
            utils.blank_region(shot_neighbor, ticking, "notick"),
        ) != 0:
            continue

        _send("LEFT")
        utils.capture_x11(shot_neighbor)
        if utils.images_differ(
            utils.blank_region(shot_selected, ticking, "notick"),
            utils.blank_region(shot_neighbor, ticking, "notick"),
        ) == 0:
            # LEFT moved nothing - the key never arrived, so there is no
            # pair to measure and diff_bbox would fail on a blank mask.
            continue

        box = utils.diff_bbox(
            utils.blank_region(shot_selected, ticking, "notick"),
            utils.blank_region(shot_neighbor, ticking, "notick"),
        )
        x, y, w, h = box
        screen_w, screen_h = utils.screenshot_size(shot_selected)
        # A pair of adjacent grid cells: small, in the lower half where
        # the keyboard is, and about as wide as two cells rather than as
        # wide as a menu row - a walk that ended up on another screen
        # would otherwise satisfy a plain "something changed".
        if (w < screen_w // 4 and h < screen_h // 6
                and y > screen_h // 2 and w < 4 * h):
            break
    else:
        return None

    x, y, w, h = box

    # Interior of the right half: the cell gap, the rounded corners and
    # the background beyond them differ from the key body as well. The
    # margin scales with the cell, which scale2Res() sizes per OSD
    # resolution.
    space_crop = utils.inset((x + w // 2, y, w - w // 2, h), max(3, h // 7))
    return space_crop, ticking


def _open_verified(tmp_path: Path):
    """Open the dialog and prove it is really the one with the keyboard.

    The walk counts fixed cursor steps through three menus, and now and
    then one of them does not arrive - the OK behind it then activates a
    neighbouring entry and everything after that measures the wrong
    screen. Waiting for a static picture made that rarer but not rare
    enough, so the result is checked and the whole walk repeated. What
    cannot be recovered is reported as such, instead of being handed on
    as a keyboard defect.

    Returns the space key's interior crop, the clock band, and the two
    shots it was measured from - selected and unselected - with the
    selection left on the key next to the space key.
    """
    shot_selected = tmp_path / "space_selected.png"
    shot_neighbor = tmp_path / "space_unselected.png"
    for _attempt in range(3):
        if not _open_keyboard_dialog(tmp_path):
            # The walk went out over a repaint somewhere; measuring what
            # it landed on would only produce a confusing failure.
            _leave_dialog()
            continue
        located = _try_locate_space_key(tmp_path, shot_selected, shot_neighbor)
        if located is not None:
            space_crop, ticking = located
            return space_crop, ticking, shot_selected, shot_neighbor
        _leave_dialog()

    pytest.fail(
        "no pair of keyboard keys could be measured in three attempts. "
        "Either the walk never reached the dialog - a reordered demo menu, "
        "or keys lost on the way in - or the keyboard itself is at fault: "
        "a selection highlight that no longer shows, or moveFocus() no "
        "longer clamping at the grid edge would look exactly like this"
    )


@pytest.mark.gui
def test_keyboard_selection_and_layout_roundtrip(tmp_path: Path) -> None:
    _require_gui()

    shot_open = tmp_path / "dialog_open.png"
    shot_focus = tmp_path / "keyboard_focused.png"
    shot_moved = tmp_path / "selection_moved.png"
    shot_round = tmp_path / "layout_roundtrip.png"

    # Opened through the verified path: its check that a key grid is on
    # screen is what keeps a mis-stepped walk from being reported as a
    # repaint defect down here.
    _, ticking, _, _ = _open_verified(tmp_path)

    try:
        utils.capture_x11(shot_open)

        # The focus already sits on the keyboard - _open_verified() put
        # it there and left the selection next to the space key. The
        # baseline is taken here, so the two LEFTs below move nothing but
        # the selection; diffing across a focus change instead would pass
        # on the field repaint alone, even with an invisible highlight.
        utils.capture_x11(shot_focus)
        _send("LEFT", "LEFT")
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
        stray = utils.images_differ(
            utils.blank_region(shot_moved, ticking, "notick"),
            utils.blank_region(shot_round, ticking, "notick"),
        )
        assert stray == 0, (
            f"layout round-trip left {stray} differing pixels - "
            "footer rebuild shifted or left remnants"
        )
    finally:
        _leave_dialog()


@pytest.mark.gui
def test_space_key_is_legible(tmp_path: Path) -> None:
    """The space key must show a visible face in both selection states.

    The key used to carry the localized word "Leerzeichen", which the
    fixed-width cell shrank into unreadable dots; since then it is faced
    with an icon. Measured on the key's interior only - the cell gap,
    the rounded corners and the background around them are not the key
    body colour either and would score a three-digit count on a blank
    key, which would make the measurement meaningless.
    """
    _require_gui()

    # The icon has to be in the built tree AND decode, or applyKeyFace()
    # takes the caption fallback - which is readable too and would let
    # the pixel counts below pass while the asset silently stopped
    # shipping or arrived corrupt.
    if utils.icons_tree() is None:
        pytest.skip(
            "no installed icon directory in this checkout - cannot tell a "
            "dropped asset from a tree that was never built"
        )
    icon = utils.installed_icon("key_space")
    assert icon is not None, (
        "key_space.png is not installed in the built tree - the space key "
        "icon was dropped from the automake file list"
    )
    assert utils.image_size(icon) is not None, (
        f"{icon} is installed but does not decode - the keyboard would "
        "quietly fall back to a caption. Note this checks the build tree, "
        "not a theme's own icons directory, which getIconPath() searches "
        "first and which this suite does not install into."
    )

    shot_caps = tmp_path / "space_caps.png"

    space_crop, _, shot_sel, shot_neighbor = _open_verified(tmp_path)

    try:

        # The caps page is a second glyph table with its own blank cell,
        # so it faces its space key in its own refresh pass. Toggled back
        # right away: the dialog object outlives this test and the next
        # one would otherwise open on the shifted page.
        _send("BLUE")
        utils.capture_x11(shot_caps)
        _send("BLUE")

        # A share of the crop rather than a pixel count, so the bar means
        # the same at any OSD resolution, and no constant floor: at a
        # small OSD a constant is the whole crop and stops separating
        # anything. Measured on this build the icon covers about 30% of
        # the interior and a blank key zero, while the shrunken caption
        # this test exists to catch reaches some 8% - a sixth sits
        # between them with room on both sides.
        cell_w, cell_h = space_crop[2], space_crop[3]
        floor = cell_w * cell_h // 6
        faces = (
            (shot_sel, "selected"),
            (shot_neighbor, "unselected"),
            (shot_caps, "on the caps page"),
        )
        for shot, state in faces:
            visible = utils.non_background_pixels(shot, space_crop)
            assert visible > floor, (
                f"the {state} space key face shows only {visible} "
                f"non-background pixels of {cell_w}x{cell_h}, under the "
                f"{floor} an icon covers - the key is blank, or it fell "
                "back to a caption although the icon is installed"
            )
    finally:
        _leave_dialog()


@pytest.mark.gui
def test_space_key_inserts_a_space(tmp_path: Path) -> None:
    """OK on the space key must still reach the input buffer.

    Not asserted as "the screen changes after OK": the caret is only
    painted while the field has focus, so a correctly inserted trailing
    space leaves an identical frame. Instead the same two letters are
    typed twice - once with the space key pressed in between, once
    without - from an identical focus state, so the only possible
    difference is the space itself.

    What this pins down is that the key inserted something that takes
    room without leaving ink. That it is exactly one U+0020 does not
    follow from any pixel: it follows from insertFocusedGlyph() writing
    the raw layout glyph, which is a single blank in every table. A
    regression that inserted two of them, or another invisible advancing
    character, would pass here.
    """
    _require_gui()

    shot_empty = tmp_path / "field_empty.png"
    shot_one = tmp_path / "field_one_letter.png"
    shot_letters = tmp_path / "letters_plain.png"
    shot_spaced = tmp_path / "letters_spaced.png"

    space_crop, ticking, shot_key, _ = _open_verified(tmp_path)

    try:
        # Back onto the space key after the locating step moved one left,
        # which is the state shot_key was taken in - the guard below
        # compares against it.
        _send("RIGHT")

        # Where the text lands, measured instead of assumed. The whole
        # frame would be the wrong comparison surface twice over: the
        # clock changes it on its own, and a regression that closed the
        # dialog would change all of it and so pass this test hardest.
        _send("YELLOW")
        utils.capture_x11(shot_empty)
        _send("A")
        utils.capture_x11(shot_one)
        text_x, text_y, text_w, text_h = utils.diff_bbox(
            utils.blank_region(shot_empty, ticking, "notick"),
            utils.blank_region(shot_one, ticking, "notick"),
        )
        screen_w, _ = utils.screenshot_size(shot_empty)
        # Starting at the first letter and running a few letters to the
        # right, at the letter's own rows - not across the whole width.
        # A full-width band is mostly field border and background, and
        # its pixel count would then be dominated by chrome that never
        # changes, which is no measure of what the text does.
        text_row = (
            text_x,
            text_y,
            min(8 * max(1, text_w), screen_w - text_x),
            text_h,
        )

        # Direct letter keys reach the buffer even while the keyboard has
        # focus, so both passes end with the selection on the space key
        # and differ in nothing but the OK.
        _send("A")
        utils.capture_x11(shot_letters)

        _send("YELLOW")
        _send("A")
        _send("OK")
        _send("A")
        utils.capture_x11(shot_spaced)

        # The selected space key must look exactly as it did at locate
        # time in both shots. Counting non-background pixels would not do:
        # OK is also bound to the footer's SAVE, so a keyboard that stops
        # consuming OK closes the dialog - and the crop would then sit
        # over the menu underneath and count thousands, letting the one
        # regression this test exists for pass hardest of all.
        for shot, when in ((shot_letters, "before"), (shot_spaced, "after")):
            drift = utils.images_differ(shot_key, shot, space_crop)
            assert drift == 0, (
                f"the selected space key changed by {drift} pixels in the "
                f"{when} shot - the dialog closed, or the keyboard moved, "
                "so what the field shows says nothing about the space key"
            )

        spaced = utils.images_differ(shot_letters, shot_spaced, text_row)
        assert spaced > 0, (
            "typing A, space, A rendered exactly like typing A, A - the "
            "space key did not reach the input buffer"
        )

        # A space is the one thing that takes room without leaving ink.
        # Equal ink with a different layout is what an inserted space
        # looks like; a visible glyph would add its own pixels and a
        # rejected insert would leave the row identical, which the assert
        # above already rules out.
        ink_plain = utils.non_background_pixels(shot_letters, text_row)
        ink_spaced = utils.non_background_pixels(shot_spaced, text_row)
        assert abs(ink_plain - ink_spaced) <= max(4, ink_plain // 8), (
            f"the text row carries {ink_spaced} ink pixels with the space "
            f"key pressed against {ink_plain} without - a space adds room, "
            "not ink, so the key inserted something visible instead"
        )
    finally:
        # The one test that edits the value, so the one that meets the
        # discard box on the way out.
        _leave_edited_dialog()
