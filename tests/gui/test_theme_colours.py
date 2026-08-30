# The input field's two text colours have to stay apart in the themes
# that ship with Neutrino, not only in whatever theme this workstation
# happens to run.
#
# This is where the last regression hid. The field used to paint typed
# text in COL_MENUCONTENTDARK_TEXT_PLUS_1 and its placeholder in
# _PLUS_2, two neighbours of one derivation that setPalette() builds
# with fixed brightness offsets - eight of 255 steps apart at best,
# identical on a dark base. Nothing in the suite looked at a theme file,
# so a pixel test on one configuration was the only thing standing
# behind a claim about all of them.
#
# No display, no screenshots, no running Neutrino: this reads the theme
# files and redoes the arithmetic setPalette() does.

from __future__ import annotations

from pathlib import Path

import pytest

from . import utils

# Themes are data, not code: the colour a theme picks is its author's
# call, and a test may only object where the OSD stops working. The one
# rule enforced here is that the field's hint must stand out LESS than
# its content - which is what "greyed out" means and what makes a
# placeholder readable as a hint.
#
# Deliberately not "darker": on a light theme the subdued colour is the
# brighter one. Crema paints black text and a mid-grey hint on a pale
# body, and by distance from that body it is the clearest of them all.
MAX_HINT_RATIO = 0.85

# Grey defines menu_Content_inactive_Text as the normal text colour, so
# the two are one and the same value and nothing the input field does
# can separate them. That is not this field's defect: on Grey a disabled
# menu entry is equally indistinguishable from an enabled one, which is
# the same colour used the same way. Listed here rather than silently
# skipped, so the count is on the record and a second theme drifting
# into this state fails loudly.
THEMES_WITHOUT_INACTIVE_COLOUR = {"Grey"}


def _theme_dir() -> Path:
    return Path(__file__).resolve().parents[2] / "sources/neutrino/data/themes"


def _theme_files() -> list[Path]:
    themes = sorted(_theme_dir().glob("*.theme"))
    if not themes:
        pytest.skip(f"no theme files under {_theme_dir()} - no source tree here")
    return themes


def _percent_rgb(values: dict[str, str], prefix: str) -> tuple[int, int, int]:
    """A theme's 0-100 triplet as RGB, the way convertSetupColor2RGB does."""
    return tuple(
        int(int(values[f"{prefix}_{channel}"]) * 255 // 100)
        for channel in ("red", "green", "blue")
    )


def _read_theme(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" in line:
            key, value = line.strip().split("=", 1)
            values[key] = value
    return values


def _field_colours(values: dict[str, str]):
    """The three colours the input field wears, derived as setPalette() does.

    Body is COL_MENUCONTENTDARK_PLUS_0, the first step of the fade
    starting at 60% of menu_Content; text is COL_MENUCONTENTDARK_TEXT
    and hint COL_MENUCONTENTINACTIVE_TEXT, both raw theme values.
    See src/system/setting_helpers.cpp (paletteGenFade for
    COL_MENUCONTENTDARK, paletteSetColor for NEUTRINO_TEXT + 8 and + 14).
    """
    body = tuple(
        int(int(int(values[f"menu_Content_{channel}"]) * 0.6) * 255 // 100)
        for channel in ("red", "green", "blue")
    )
    return (
        body,
        _percent_rgb(values, "menu_Content_Text"),
        _percent_rgb(values, "menu_Content_inactive_Text"),
    )


def test_shipped_themes_keep_the_hint_quieter_than_the_content() -> None:
    offenders = []
    checked = 0
    for path in _theme_files():
        name = path.stem
        values = _read_theme(path)
        try:
            body, text, hint = _field_colours(values)
        except KeyError as missing:
            pytest.fail(f"{name} has no {missing} - cannot judge its field colours")

        text_gap = utils.color_distance(text, body)
        hint_gap = utils.color_distance(hint, body)
        ratio = hint_gap / text_gap if text_gap else 1.0

        if name in THEMES_WITHOUT_INACTIVE_COLOUR:
            # Still measured, so the exemption cannot outlive the defect
            # it was granted for.
            assert text == hint, (
                f"{name} is listed as having no separate inactive colour, "
                f"but its text {text} and hint {hint} now differ - drop it "
                "from THEMES_WITHOUT_INACTIVE_COLOUR"
            )
            continue

        checked += 1
        if ratio > MAX_HINT_RATIO:
            offenders.append(
                f"{name}: hint {hint} stands {hint_gap:.0f} off the body "
                f"{body} where text {text} stands {text_gap:.0f} "
                f"(ratio {ratio:.2f})"
            )

    # A run that measured nothing must not read as a pass.
    assert checked >= 10, (
        f"only {checked} themes were judged - the theme directory or the "
        "exemption list is not what this test was written against"
    )
    assert not offenders, (
        "these shipped themes do not keep the input field's placeholder "
        "quieter than its typed text, so the hint reads as content there:"
        + "".join(f"\n  {line}" for line in offenders)
    )


def test_the_two_field_text_colours_are_separate_theme_values() -> None:
    """Neither colour may be derived from the other by a fixed offset.

    The property the fix rests on: both are values a theme sets in its
    own right. A future change reaching back for a *_TEXT_PLUS_n
    neighbour would tie the hint to the text again at a fixed distance,
    and this is the cheapest place to say so.
    """
    for path in _theme_files():
        values = _read_theme(path)
        for key in ("menu_Content_Text_red", "menu_Content_inactive_Text_red"):
            assert key in values, (
                f"{path.stem} does not set {key}; the input field's colours "
                "would then fall back to whatever the previous theme left"
            )
