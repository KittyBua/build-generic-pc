# Regression tests for the CCTextInputDialog keyboard scenario: the key
# selection must be visible and a layout round-trip pixel-stable (the
# footer used to shift and leave button remnants), the space key must
# be legible and actually insert, green must delete one glyph
# backwards, the caret must stand visibly - not blinking - while the
# keyboard holds the keys, and the placeholder must be visibly dimmer
# than typed text without fading into the field.
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
        utils.fail_or_skip(exc)
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
    the text row is what two of these tests compare. When the focus
    moves to the keyboard the caret stops blinking - it stays on screen
    as a static mark since the unfocused-caret change, but a standing
    mark does not tick - so from the keyboard the clock is the only
    thing left that moves.

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


def _measured_text_row(
    tmp_path: Path, ticking, prefix: str
) -> tuple[tuple[int, int, int, int], Path, Path, Path, tuple[int, int, int, int]]:
    """Clear the field, type two letters, and measure the text band.

    Shared by the green-key, caret and placeholder tests, which compare
    against exactly these three states. The band is taken in two steps
    on purpose: an empty field renders its placeholder, so the
    empty->one diff spans the placeholder's whole width and is only good
    for position and height - a width scaled from it would saturate at
    the screen edge, where anything self-repainting lands in a strict
    comparison. The right edge comes from the one->two diff, which is
    the second glyph plus the caret's move, padded by a few pixels.

    Returns the band, the empty/one-letter/two-letter shots - all taken
    with keyboard focus - and last that wider placeholder band, which is
    where the hint's own pixels are and the narrow band is not.
    """
    shot_empty = tmp_path / f"{prefix}_empty.png"
    shot_one = tmp_path / f"{prefix}_one.png"
    shot_two = tmp_path / f"{prefix}_two.png"

    def row_of(shot: Path) -> Path:
        return utils.blank_region(shot, ticking, "notick")

    _send("YELLOW")
    utils.capture_x11(shot_empty)
    _send("A")
    utils.capture_x11(shot_one)
    _send("B")
    utils.capture_x11(shot_two)

    text_x, text_y, hint_w, text_h = utils.diff_bbox(
        row_of(shot_empty), row_of(shot_one)
    )
    second_x, _, second_w, _ = utils.diff_bbox(
        row_of(shot_one), row_of(shot_two)
    )
    screen_w, _ = utils.screenshot_size(shot_empty)
    right = min(max(second_x + second_w, text_x + 1) + 4, screen_w)
    return (
        (text_x, text_y, right - text_x, text_h),
        shot_empty,
        shot_one,
        shot_two,
        (text_x, text_y, hint_w, text_h),
    )


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

    Not asserted as "the screen changes after OK": that would prove
    nothing specific. Since the unfocused-caret change the static mark
    does move when a space is inserted, but a moved caret says a glyph
    arrived, not which one. Instead the same two letters are typed
    twice - once with the space key pressed in between, once without -
    from an identical focus state, so the only difference between the
    finished rows is the space itself (the caret sits further right in
    the spaced row, which the layout comparison is allowed to see and
    the ink comparison tolerates - the mark carries the same ink in
    both).

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


@pytest.mark.gui
def test_green_key_deletes_one_character_backwards(tmp_path: Path) -> None:
    """GREEN must remove the glyph before the cursor - one, and only one.

    The regression this exists for: GREEN was bound to a forward delete
    while the cursor starts past the last glyph (setText() ends with
    ib_cursor = ib_glyphs.size()), so erase() returned false, nothing
    repainted, and the key looked dead until a LEFT press had moved the
    cursor back.

    Two letters are typed and GREEN is pressed once. The result has to
    land exactly on the one-letter picture, which separates the three
    outcomes that matter: doing nothing leaves two letters, a clear-all
    empties the field, and only a backspace lands in between. Asserting
    "the screen changed" would pass for all but the first.
    """
    _require_gui()

    shot_after = tmp_path / "bs_after_green.png"

    space_crop, ticking, shot_key, _ = _open_verified(tmp_path)

    def row_of(shot: Path) -> Path:
        return utils.blank_region(shot, ticking, "notick")

    try:
        # Back onto the space key, the state shot_key was taken in - the
        # dialog guard below compares against it. The focus stays on the
        # keyboard throughout, which also keeps the field caret from
        # blinking into the comparison.
        _send("RIGHT")

        # Where the text lands, measured rather than assumed: the full
        # frame carries the clock and would let a dialog that closed
        # itself pass hardest of all.
        text_row, shot_empty, shot_one, shot_two, _ = _measured_text_row(
            tmp_path, ticking, "bs"
        )

        # Guard, not decoration: if the second letter never arrived, the
        # buffer holds one glyph and a working backspace would empty the
        # field - the assert below would then read that as "GREEN cleared
        # everything" and fail for the wrong reason.
        typed = utils.images_differ(row_of(shot_one), row_of(shot_two), text_row)
        assert typed > 0, (
            "typing a second letter did not change the text row, so the "
            "field never held two glyphs - nothing can be concluded about "
            "what GREEN does to them"
        )

        _send("GREEN")
        utils.capture_x11(shot_after)

        # OK is bound to SAVE in the footer and GREEN could, if the
        # dispatch broke, close the dialog instead of editing. The crop
        # would then sit over the menu underneath and every text
        # comparison below would measure the wrong screen.
        drift = utils.images_differ(row_of(shot_key), row_of(shot_after), space_crop)
        assert drift == 0, (
            f"the selected space key changed by {drift} pixels after GREEN "
            "- the dialog closed or the keyboard moved, so what the field "
            "shows says nothing about the key"
        )

        # The regression itself: GREEN used to leave the field untouched.
        assert utils.images_differ(row_of(shot_two), row_of(shot_after), text_row) > 0, (
            "the text row is unchanged after GREEN - the key did nothing, "
            "which is exactly how a forward delete behaves with the cursor "
            "at the end of the buffer"
        )

        # One glyph removed, not the buffer emptied.
        back = utils.images_differ(row_of(shot_one), row_of(shot_after), text_row)
        assert back == 0, (
            f"the text row differs from the one-letter picture by {back} "
            "pixels after GREEN - the key removed something other than the "
            "single glyph before the cursor"
        )
        assert utils.images_differ(row_of(shot_empty), row_of(shot_after), text_row) > 0, (
            "the text row is back to the empty picture after one GREEN - "
            "the key cleared the whole field instead of deleting one glyph, "
            "which is what YELLOW is for"
        )
    finally:
        # Edits the value, so it meets the discard box on the way out.
        _leave_edited_dialog()


@pytest.mark.gui
def test_caret_stays_visible_on_keyboard_focus(tmp_path: Path) -> None:
    """The caret must stand still and stay in sight on keyboard focus.

    The regression this exists for: the caret was only painted with
    field focus, so stepping down to the keyboard hid it while the
    cursor position kept acting - green deleted and glyphs landed at a
    place nothing marked.

    The decision has two halves and both are asserted. Visible: two
    letters are typed, the cursor is walked one glyph left through the
    field, focus returns to the keyboard, and the text row must differ
    between the two keyboard-focused shots - same text, moved mark.
    Static: three extra captures spanning well over one blink period
    must be pixel-identical in the text row - a caret that still
    blinked would flip somewhere inside that window, and a moved-mark
    assert alone would wave a blinking caret through on phase luck.

    Focus is proven, not assumed, in both directions. A shot after the
    climb must differ from the typed row (the field's focus repaint is
    visible), or the climb lost a key and the failure is the harness's,
    not the product's. A probe LEFT after the return must leave the
    text row untouched (the keyboard consumes it), or the final DOWN
    was lost and shot_mid shows the field's focus repaint - which would
    otherwise pass the moved-mark assert with the feature removed.

    Four separately settled UPs, not one: _open_verified() leaves the
    keyboard selection on the bottom grid row, and only UP on the top
    row hands the focus to the field (OnLeaveTop). One batch would
    outrun the repaint and get swallowed.
    """
    _require_gui()

    shot_mid = tmp_path / "cv_mid.png"
    shot_field = tmp_path / "cv_field.png"
    shot_probe = tmp_path / "cv_probe.png"

    space_crop, ticking, _, shot_neighbor = _open_verified(tmp_path)

    def row_of(shot: Path) -> Path:
        return utils.blank_region(shot, ticking, "notick")

    try:
        text_row, _, _, shot_two, _ = _measured_text_row(tmp_path, ticking, "cv")

        # Static half of the decision: nothing in the text row may move
        # on its own while the keyboard holds the keys. The samples
        # span >1.5s, three full blink periods - a timer-driven caret
        # cannot hold one phase that long.
        for sample in range(3):
            still = tmp_path / f"cv_still_{sample}.png"
            utils.capture_x11(still)
            ticks = utils.images_differ(row_of(shot_two), row_of(still), text_row)
            assert ticks == 0, (
                f"the text row changed by {ticks} pixels with no key sent "
                "- the unfocused caret is blinking, the static half of "
                "the requirement is broken"
            )

        # Bottom row -> top row -> field, one settled key each.
        _send("UP")
        _send("UP")
        _send("UP")
        _send("UP")
        utils.capture_x11(shot_field)

        # Harness guard, so a lost UP reads as a lost UP: with field
        # focus the field repaints - thicker frame, focus body colour,
        # blinking caret - so the row must differ from the typed state.
        arrived = utils.images_differ(row_of(shot_two), row_of(shot_field), text_row)
        if arrived == 0:
            pytest.fail(
                "the field shows no focus repaint after four UPs - a key "
                "went out over a repaint and the climb never reached the "
                "field; harness failure, not a caret defect"
            )

        _send("LEFT")
        _send("DOWN")
        utils.capture_x11(shot_mid)

        # Product guard in the other direction: prove shot_mid really
        # was taken with keyboard focus. A keyboard-consumed LEFT moves
        # the key selection, which sits below the text row; with field
        # focus it would move the cursor and change the row - and the
        # moved-mark assert below would then measure the focus repaint
        # instead of the caret and pass with the feature removed.
        _send("LEFT")
        utils.capture_x11(shot_probe)
        leaked = utils.images_differ(row_of(shot_mid), row_of(shot_probe), text_row)
        assert leaked == 0, (
            f"LEFT changed the text row by {leaked} pixels after the "
            "return to the keyboard - the final DOWN was lost and "
            "shot_mid shows the focused field, so nothing below would "
            "measure the caret"
        )

        # Guard, against the UNSELECTED reference: after the climb the
        # keyboard selection sits on the top row, so the space key is
        # unselected - exactly the state shot_neighbor recorded. A
        # comparison against the selected shot would differ for a
        # legitimate reason and cry wolf.
        drift = utils.images_differ(
            row_of(shot_neighbor), row_of(shot_mid), space_crop
        )
        assert drift == 0, (
            f"the space key face changed by {drift} pixels - the dialog "
            "closed or the keyboard moved, so the field says nothing "
            "about the caret"
        )

        # The regression itself: same text, moved caret.
        moved = utils.images_differ(row_of(shot_two), row_of(shot_mid), text_row)
        assert moved > 0, (
            "the text row is identical with the cursor at the end and "
            "one glyph to the left - no visible caret moved, which is "
            "exactly the hidden-cursor state this test exists to catch"
        )
    finally:
        # Edits the value, so it meets the discard box on the way out.
        _leave_edited_dialog()


@pytest.mark.gui
def test_placeholder_is_dimmer_than_typed_text(tmp_path: Path) -> None:
    """The placeholder must read as a hint, not as content.

    It used to be COL_MENUCONTENTDARK_TEXT_PLUS_2 against typed text in
    _PLUS_1 - two neighbouring slots that setPalette() derives from one
    base with fixed offsets, so they sit at most 8 of 255 brightness
    steps apart in any theme. On screen that is the same colour, and a
    hint saying "type your proxy host here" looked like a host name
    somebody had already entered.

    Measured in two bands of the same row, both shot with the keyboard
    holding the keys. The remainder right of the AB band carries only
    placeholder, because an empty field parks the caret at the far
    left. The AB band carries the typed text - but read from a later
    shot, after six more letters have pushed the caret out of it.

    That detour is not decoration. The caret paints in the text colour,
    so inside a band that still holds it no colour reading can tell a
    glyph from a caret: a field that had stopped drawing glyphs
    entirely would hand back a perfectly good text colour, taken from
    the caret, and this test would pass. Measured on a build mutated to
    do exactly that. Counting pixels does not separate them either -
    the caret's anti-aliased edge changes shade as it moves. Moving the
    caret out of the band does.

    Judged by distance from the FIELD BODY, not by which of the two is
    darker. "Subdued" means standing out less than the content does,
    and on a light theme that makes the hint the brighter colour -
    Crema paints black text and a mid-grey hint on a pale body. A
    brightness comparison gets that exactly backwards, and it is blind
    to Bluemoon, which separates the two by hue at equal brightness.
    """
    _require_gui()

    # The hint may reach at most this share of the text's distance from
    # the body. Measured on this build: text (243,238,223) stands 373
    # off the body (0,18,46), the placeholder (121,116,106) stands 167 -
    # a ratio of 0.45. The old neighbouring-slot pair scores 0.95.
    # Computed over the seventeen shipped themes the worst legitimate
    # ratio is DVB2000's 0.80, so 0.85 leaves them all room; Grey is the
    # single theme this cannot pass, and it cannot because it defines
    # inactive text as the normal text colour - see
    # test_theme_colours.py, which states that separately.
    MAX_HINT_RATIO = 0.85
    # And a floor, so dimming the hint into the body cannot satisfy the
    # ratio. 167 here; the tightest shipped theme is Crema at 57.
    MIN_HINT_TO_BODY = 40

    space_crop, ticking, _, shot_neighbor = _open_verified(tmp_path)

    def row_of(shot: Path) -> Path:
        return utils.blank_region(shot, ticking, "notick")

    try:
        text_row, shot_empty, shot_one, shot_two, hint_band = _measured_text_row(
            tmp_path, ticking, "ph"
        )

        # Colours are read from the untouched shots, not from the
        # clock-masked copies the comparisons use: blank_region() paints
        # its band black, and black would win "furthest from the
        # background" against any real ink. So the bands must not meet
        # the clock in the first place - they do not, the clock is a
        # screen-edge element and this row sits inside a centred dialog,
        # but an untested assumption here would corrupt the measurement
        # silently rather than loudly.
        if ticking is not None:
            row_top, row_bottom = text_row[1], text_row[1] + text_row[3]
            tick_top, tick_bottom = ticking[1], ticking[1] + ticking[3]
            if tick_top < row_bottom and row_top < tick_bottom:
                pytest.fail(
                    f"the clock band {ticking} overlaps the text row "
                    f"{text_row}; colours read here would be the mask, "
                    "not the dialog"
                )

        hint_x = text_row[0] + text_row[2]
        hint_w = hint_band[0] + hint_band[2] - hint_x
        if hint_w <= 0:
            pytest.fail(
                f"no placeholder is left of the band {hint_band} once the "
                f"typed-text band {text_row} is cut off it - the hint is "
                "shorter than two letters, or one of the two measurements "
                "did not land where it should"
            )
        hint_row = (hint_x, hint_band[1], hint_w, hint_band[3])

        # Harness guard, same one the green-key test uses: without it a
        # lost keypress leaves the field empty, both bands then hold
        # placeholder, and comparing a colour with itself would sail
        # through every threshold below.
        typed = utils.images_differ(row_of(shot_one), row_of(shot_two), text_row)
        if typed <= 0:
            pytest.fail(
                "the text band did not change between one and two "
                "letters - the second keypress never arrived, so the "
                "band that should hold typed text may hold anything"
            )

        # Six more letters, so the caret leaves the AB band and what is
        # left in it is glyphs and nothing else.
        shot_long = tmp_path / "ph_long.png"
        _send("C", "D", "E", "F", "G", "H")
        utils.capture_x11(shot_long)

        # Two different measurements on purpose. In the AB band the
        # typed text is now the only thing painted, so "furthest from
        # the dominant colour" finds it. The placeholder is meant to be
        # quiet, and the field body is not opaque - the boot screen
        # shows through it in patches brighter than a subdued hint - so
        # there it is taken as what the empty field ADDS over the
        # one-letter shot, which the show-through cannot fake because
        # it stands in both.
        text_ink, _ = utils.ink_and_background(shot_long, text_row)
        hint_ink, hint_body = utils.ink_added(shot_one, shot_empty, hint_row)
        assert text_ink is not None, (
            f"no ink found in the typed-text band {text_row} although "
            "eight letters were sent - the field is not showing them"
        )
        assert hint_ink is not None, (
            f"the empty field added no colour to the placeholder band "
            f"{hint_row} over the one-letter shot - it rendered no hint, "
            "so there is nothing here to judge a colour by"
        )

        text_gap = utils.color_distance(text_ink, hint_body)
        hint_gap = utils.color_distance(hint_ink, hint_body)
        ratio = hint_gap / text_gap if text_gap else 1.0

        # Told apart from the ratio below on purpose: a band with no
        # glyphs in it still yields a colour - the boot screen through
        # the body, some 30 off it - and a ratio computed against that
        # would report "the hint reads as content" for a field that is
        # not drawing text at all.
        if text_gap < MIN_HINT_TO_BODY:
            pytest.fail(
                f"the typed-text band {text_row} holds nothing that "
                f"stands off the field body {hint_body}: its strongest "
                f"colour {text_ink} is only {text_gap:.0f} away. Eight "
                "letters were sent, so the field is not rendering glyphs"
            )

        # The regression itself: a hint that stands out as far as the
        # content does is not a hint.
        assert ratio <= MAX_HINT_RATIO, (
            f"the placeholder {hint_ink} stands {hint_gap:.0f} off the "
            f"field body {hint_body} where the typed text {text_ink} "
            f"stands {text_gap:.0f} - a ratio of {ratio:.2f}, past the "
            f"{MAX_HINT_RATIO} this asks for. The hint reads as content"
        )

        # And the other direction: dimming it into the body would
        # satisfy that ratio perfectly.
        assert hint_gap >= MIN_HINT_TO_BODY, (
            f"the placeholder {hint_ink} stands only {hint_gap:.0f} off "
            f"the field body {hint_body} - dimmed past being readable"
        )

        # Same guard the neighbouring tests use: without it a dialog
        # that closed itself would hand back a screen whose colours
        # answer some other question entirely.
        drift = utils.images_differ(
            row_of(shot_neighbor), row_of(shot_two), space_crop
        )
        assert drift == 0, (
            f"the space key face changed by {drift} pixels - the dialog "
            "closed or the keyboard moved, so the bands above were not "
            "measured on the input field"
        )
    finally:
        # Edits the value, so it meets the discard box on the way out.
        _leave_edited_dialog()
