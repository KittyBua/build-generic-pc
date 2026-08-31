# Utilities for GUI smoke tests (headless Neutrino).

import math
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from . import send_keys


def require_binary(name: str) -> None:
    """Skip the test if the given binary is not available."""
    if shutil.which(name) is None:
        pytest.skip(f"{name} binary is required for this test")


def ensure_neutrino_running() -> None:
    """Skip if the Neutrino binary is not reachable."""
    install_dir = os.environ.get("NEUTRINO_INSTALL_DIR")
    prefix = os.environ.get("NEUTRINO_PREFIX", "/usr")
    candidate = Path(install_dir or "") / prefix.strip("/") / "bin" / "neutrino"
    if not candidate.exists():
        pytest.skip("Neutrino binary not installed – run `make neutrino` first")


def send_keys_skip_reason(stderr: str) -> str | None:
    """The reason to skip over, when send_keys failed for want of an
    environment rather than because the key transport is broken.

    An installed binary is not a running one: ensure_neutrino_running() only
    checks that Neutrino was built, so a suite started without `make run`
    reaches send_keys and dies there on a FIFO nobody reads. That is a missing
    precondition, not a defect, and it has to read like one - otherwise the
    first thing a newcomer sees is a CalledProcessError naming a subprocess.

    Returns None for anything unrecognised, so a genuine failure still raises.
    """
    known = (
        # The device path, not a bare "Permission denied": that would swallow an
        # EACCES on the FIFO as a supposedly absent uinput device, and the real
        # defect would leave as a skip. Recognising it by path holds only while
        # evdev keeps naming the device in its message and keeps opening this
        # one - both pinned in test_input_helpers.py.
        send_keys.UINPUT_DEVICE,
        "has no reader",
        "not found. Ensure Neutrino is running",
        "is not a FIFO",
        "python-evdev missing",
    )
    for marker in known:
        if marker in stderr:
            return f"cannot replay keys: {stderr.strip().splitlines()[-1]}"
    return None


def fail_or_skip(exc: subprocess.CalledProcessError) -> None:
    """Skip a send_keys failure that is a missing precondition, fail the rest.

    Kept here rather than repeated in every caller. A bare re-raise reports
    only the command and the exit status - CalledProcessError carries stderr in
    an attribute its message ignores, and pytest does not print the local
    holding it, so the sentence send_keys went to the trouble of writing would
    never reach anyone. Raised from inside an `except` block, so the original
    exception still shows as the cause.
    """
    err = (exc.stderr or b"").decode(errors="ignore")
    reason = send_keys_skip_reason(err)
    if reason:
        pytest.skip(reason)
    pytest.fail(f"send_keys failed and the reason was not an environment gap:\n{err}")


def capture_framebuffer(destination: Path, delay: float = 0.5) -> None:
    """Capture a framebuffer screenshot using fbgrab."""
    require_binary("fbgrab")
    # fbgrab being installed says nothing about there being something to grab:
    # a PC build renders into X (Xvfb), and such a host usually has no
    # framebuffer device at all. Without this check the test fails on a plain
    # environment mismatch instead of skipping like every other missing piece.
    # Same reading as fbgrab's own `device=${FRAMEBUFFER:-/dev/fb0}`: an empty
    # value falls back to the default rather than naming an empty path.
    device = os.environ.get("FRAMEBUFFER") or "/dev/fb0"
    if not os.access(device, os.R_OK):
        pytest.skip(f"no readable framebuffer at {device} – fbgrab cannot capture here")
    time.sleep(delay)
    subprocess.run(["fbgrab", str(destination)], check=True)


def capture_x11(destination: Path, delay: float = 0.5) -> None:
    """Capture the screen of a PC build, which renders into X rather than a
    framebuffer device.

    Separate from capture_framebuffer() on purpose: that one grabs /dev/fb0 and
    skips where there is none, which is exactly the PC-build case. A test that
    needs a picture from an Xvfb-hosted Neutrino has to come here instead.
    """
    require_binary("import")
    display = os.environ.get("DISPLAY")
    if not display:
        pytest.skip("DISPLAY not set - start Neutrino under Xvfb before running this test")
    time.sleep(delay)
    subprocess.run(["import", "-window", "root", str(destination)], check=True)


def images_differ(
    first: Path,
    second: Path,
    crop: tuple[int, int, int, int] | None = None,
) -> int:
    """Number of differing pixels between two screenshots, optionally only
    inside a crop.

    Uses ImageMagick's compare, which reports the count on stderr and exits
    non-zero whenever the images are not identical - that is a result here, not
    a failure, so the exit code is deliberately not checked.

    A tool that is installed but returns nothing usable is a defect, not a
    missing precondition, so that fails rather than skips: a skipped
    comparison reads as "no regression found".
    """
    require_binary("compare")
    left, right = first, second
    if crop is not None:
        require_binary("convert")
        x, y, w, h = crop
        cuts = []
        for index, source in enumerate((first, second)):
            cut = first.parent / f"{first.stem}_region{index}.png"
            cut.unlink(missing_ok=True)
            proc = subprocess.run(
                ["convert", str(source), "-crop", f"{w}x{h}+{x}+{y}", "+repage", str(cut)],
                capture_output=True,
            )
            if proc.returncode != 0 or not cut.exists():
                pytest.fail(
                    f"convert could not crop {crop} out of {source}: "
                    f"{(proc.stderr or b'').decode(errors='ignore').strip()!r}"
                )
            cuts.append(cut)
        left, right = cuts
    proc = subprocess.run(
        ["compare", "-metric", "AE", str(left), str(right), "null:"],
        capture_output=True,
    )
    out = (proc.stderr or b"").decode(errors="ignore").strip().split()
    if not out:
        pytest.fail(f"compare produced no metric for {left} vs {right}")
    try:
        # some builds print "1234 (0.001)"
        return int(float(out[0]))
    except ValueError:
        pytest.fail(f"compare returned an unreadable metric: {out[0]!r}")


def diff_bbox(first: Path, second: Path) -> tuple[int, int, int, int]:
    """Bounding box (x, y, w, h) of the pixels differing between two shots.

    Lets a test locate a repainted region without hardcoding dialog
    geometry, which depends on the OSD resolution. compare exits non-zero
    for differing images - that is the expected case here.

    A tool that is installed but fails is a defect, not a missing
    precondition: only require_binary() skips here, everything below
    fails loudly. A silent skip would read as "no regression found".
    """
    require_binary("compare")
    require_binary("convert")
    mask = first.parent / (first.stem + "_diffmask.png")
    # Removed first: the name is derived from the input, and this helper is
    # called repeatedly with the same input across retries - a failed
    # compare would otherwise leave the previous attempt's mask in place
    # and the geometry below would describe a measurement nobody took.
    mask.unlink(missing_ok=True)
    subprocess.run(
        ["compare", str(first), str(second), "-compose", "src",
         "-highlight-color", "white", "-lowlight-color", "black", str(mask)],
        capture_output=True,
    )
    if not mask.exists():
        pytest.fail(f"compare wrote no difference mask for {first} vs {second}")
    proc = subprocess.run(
        ["convert", str(mask), "-trim", "-format", "%w %h %X %Y", "info:"],
        capture_output=True,
    )
    out = (proc.stdout or b"").decode(errors="ignore").split()
    if len(out) != 4:
        pytest.fail(
            "convert could not locate a difference region in "
            f"{mask}: {(proc.stderr or b'').decode(errors='ignore').strip()!r}"
        )
    w, h, x, y = (int(v) for v in out)
    return x, y, w, h


def _histogram(
    image: Path, crop: tuple[int, int, int, int]
) -> list[tuple[int, tuple[int, int, int]]]:
    """Colours of a crop as (count, rgb), most frequent first.

    Fails rather than skips when convert is installed but unusable, for
    the reason given in diff_bbox().
    """
    require_binary("convert")
    x, y, w, h = crop
    if w <= 0 or h <= 0:
        pytest.fail(f"empty crop {crop} - nothing to measure in {image}")
    proc = subprocess.run(
        ["convert", str(image), "-crop", f"{w}x{h}+{x}+{y}", "+repage",
         "-format", "%c", "histogram:info:"],
        capture_output=True,
    )
    entries: list[tuple[int, tuple[int, int, int]]] = []
    for line in (proc.stdout or b"").decode(errors="ignore").splitlines():
        text = line.strip()
        head = text.split(":", 1)[0]
        if not head.isdigit():
            continue
        hexcode = re.search(r"#([0-9A-Fa-f]+)", text)
        if hexcode is None:
            # A line whose colour cannot be read is not a colour this
            # measurement may silently drop - it would change every
            # ranking below it.
            pytest.fail(f"unreadable histogram line for {image}: {text!r}")
        raw = hexcode.group(1)
        # ImageMagick prints two hex digits per channel at 8 bits and
        # four at 16, for three channels or four with an alpha one.
        # Reading the first six digits of a 16-bit line would take
        # R-high, R-low, G-high as RGB and quietly return a colour that
        # is not on screen, so the width decides rather than being
        # assumed. Alpha, where present, is dropped: nothing here asks
        # about transparency, and the first three channels are the
        # colour either way.
        step = {6: 2, 8: 2, 12: 4, 16: 4}.get(len(raw))
        if step is None:
            pytest.fail(
                f"histogram colour {raw!r} in {image} is none of the "
                "widths ImageMagick writes for 8- or 16-bit RGB(A) - the "
                "parser cannot tell what it means"
            )
        rgb = tuple(
            int(raw[i * step:i * step + 2], 16) for i in range(3)
        )
        entries.append((int(head), rgb))
    if not entries:
        pytest.fail(
            f"convert produced no histogram for {image} crop {crop}: "
            f"{(proc.stderr or b'').decode(errors='ignore').strip()!r}"
        )
    entries.sort(key=lambda e: e[0], reverse=True)
    return entries


def non_background_pixels(image: Path, crop: tuple[int, int, int, int]) -> int:
    """Pixels in the crop that differ from the crop's dominant color.

    A key face that shows anything - a glyph or an icon - has plenty of
    them; a blank key is close to uniform and yields almost none.

    Pass an interior crop: key gaps, rounded corners and the surrounding
    background are not the key's dominant color either, so a crop that
    still contains them scores a three-digit count on a blank key and the
    measurement says nothing.
    """
    counts = [count for count, _ in _histogram(image, crop)]
    return sum(counts) - max(counts)


def color_distance(first: tuple[int, int, int], second: tuple[int, int, int]) -> float:
    """How far apart two colours are, as a plain euclidean RGB distance.

    Preferred over comparing brightness() alone whenever the question is
    "does this stand out against that": two colours can share a
    brightness and still be plainly different - Bluemoon paints inactive
    text orange at the same maximum channel as its white text - and on a
    light theme the subdued colour is the BRIGHTER one, which a
    brightness difference gets backwards.
    """
    return math.sqrt(sum((a - b) ** 2 for a, b in zip(first, second)))


def brightness(color: tuple[int, int, int]) -> int:
    """Neutrino's own brightness measure for a colour.

    getBrightnessRGB() in color.cpp takes the largest of the three
    channels, and that value is what the palette generator writes into
    HSV's V. Comparing two OSD colours the way the OSD itself does keeps
    a test's numbers comparable to the ones in the palette code.
    """
    return max(color)


def ink_and_background(
    image: Path, crop: tuple[int, int, int, int], min_pixels: int = 8
) -> tuple[tuple[int, int, int] | None, tuple[int, int, int]]:
    """The crop's background colour and the ink painted on it.

    Background is the most frequent colour - sound for a band that is
    mostly empty surface. The ink is NOT simply the second most frequent
    one: RenderString() blends every glyph coverage level against the
    background, so which shade occurs most often depends on the glyph
    raster, not on what the eye reads as the letter. Taken instead is the
    colour that sits furthest from the background in brightness and still
    covers at least min_pixels - the fully covered core of the glyphs,
    whether the text is lighter or darker than what it sits on.

    min_pixels drops the stray blend shades that exist a handful of
    pixels at a time. Ink is None when nothing on the band clears it,
    which is a measurement result - an empty field - and left to the
    caller to judge.
    """
    entries = _histogram(image, crop)
    background = entries[0][1]
    base = brightness(background)
    candidates = [rgb for count, rgb in entries[1:] if count >= min_pixels]
    if not candidates:
        return None, background
    return max(candidates, key=lambda rgb: abs(brightness(rgb) - base)), background


def ink_added(
    before: Path,
    after: Path,
    crop: tuple[int, int, int, int],
    min_pixels: int = 64,
) -> tuple[tuple[int, int, int] | None, tuple[int, int, int]]:
    """The colour `after` paints into the crop and `before` does not.

    Use this instead of ink_and_background() wherever the ink is meant
    to be subdued. Neutrino's dialogs are not opaque - the input field
    body carries an alpha, so the boot screen behind it shows through as
    patches several hundred pixels large. "Furthest from the dominant
    colour" then finds a patch rather than the glyphs as soon as the
    text is dimmer than the show-through, which is exactly the case a
    faded placeholder is about. Whatever shows through, though, shows
    through in BOTH shots: taking the colour whose pixel count grows is
    blind to it.

    Returns that colour and the crop's dominant colour in `before`,
    which is the surface the ink was painted onto. Ink is None when
    nothing was added - a measurement result, left to the caller.
    """
    before_hist = _histogram(before, crop)
    was = {rgb: count for count, rgb in before_hist}
    background = before_hist[0][1]
    # Judged on how many pixels a colour GAINED, not on a ratio: a
    # ratio treats a shade that already covered a few hundred pixels
    # the same as one that covered none, and the gain is what the new
    # ink actually is.
    added = [
        (count - was.get(rgb, 0), rgb)
        for count, rgb in _histogram(after, crop)
        if count - was.get(rgb, 0) >= min_pixels
    ]
    if not added:
        return None, background
    # The biggest gain, not the most extreme colour: a glyph's fully
    # covered core outnumbers each of the blend steps around its edges
    # by an order of magnitude.
    return max(added, key=lambda e: e[0])[1], background


def image_size(image: Path) -> tuple[int, int] | None:
    """Width and height of an image, or None when it cannot be decoded.

    A file that exists is not an image that renders, so callers that ask
    about an asset get to tell the two apart; callers that pass their own
    screenshot should treat None as a failure.
    """
    require_binary("identify")
    proc = subprocess.run(
        ["identify", "-format", "%w %h", str(image)], capture_output=True
    )
    out = (proc.stdout or b"").decode(errors="ignore").split()
    if len(out) != 2:
        return None
    return int(out[0]), int(out[1])


def screenshot_size(image: Path) -> tuple[int, int]:
    """Width and height of a screenshot this suite took itself."""
    size = image_size(image)
    if size is None:
        pytest.fail(f"identify could not read the size of {image}")
    return size


def ticking_band(
    workdir: Path, settle: float = 2.5
) -> tuple[int, int, int, int] | None:
    """Full-width band across whatever repaints on its own, or None when
    the screen is still.

    Neutrino paints its on-screen clock (mode_clock) from its own timer
    thread with CC_SAVE_SCREEN_NO, so it can draw over menus and dialogs.
    Whether it does depends on what ran before, which is what makes a
    pixel-exact comparison fail only sometimes - the worst way for a test
    to be wrong.

    A band, not the measured rectangle: within a short probe only the
    blinking colon moves, so masking just what moved would leave the hour
    and minute digits exposed and the minute rolling over would still
    break the comparison. The digits share the colon's rows, so a band
    over those rows covers the whole clock wherever it sits.

    Measured rather than hardcoded, so it also works when the clock is
    off, moved or styled differently.
    """
    first = workdir / "tick_probe_a.png"
    second = workdir / "tick_probe_b.png"
    capture_x11(first)
    time.sleep(settle)
    capture_x11(second)
    if images_differ(first, second) == 0:
        return None

    _, y, _, h = diff_bbox(first, second)
    width, screen_h = screenshot_size(first)
    # Padded by twice the measured height on each side. What a short
    # probe catches is the blinking colon, whose ink is a good deal
    # shorter than the digits around it - a band the size of the colon
    # would leave their top and bottom rows exposed for the minute to
    # change in.
    pad = max(4, 2 * h)
    band = (0, max(0, y - pad), width, h + 2 * pad)
    # Nothing is handed out that could mask away the content under test.
    # The clock is a thin screen-edge element; a band deeper than that is
    # something else repainting, and the honest answer is then "no mask",
    # which lets the comparison fail loudly instead of passing blind.
    if band[1] + band[3] > screen_h // 4:
        return None
    return band


def wait_until_static(
    workdir: Path, tries: int = 10, settle: float = 0.4, tolerance: int = 300
) -> bool:
    """Wait until the screen stops changing. True when it did.

    Sending the next key while a window is still being painted is how a
    scripted walk ends up somewhere else entirely: the key reaches the
    screen underneath, and everything counted from there is off by one.
    A fixed sleep only hides that until the machine is busy, so wait for
    the picture instead of for the clock.

    The tolerance leaves room for the on-screen clock, which repaints on
    its own timer and would otherwise mean "never static": its colon is
    a few dozen pixels and the minute rolling over a few hundred, while
    a window opening or closing is tens of thousands.
    """
    first = workdir / "static_probe_a.png"
    second = workdir / "static_probe_b.png"
    calm = 0
    for _ in range(tries):
        capture_x11(first, delay=0.0)
        time.sleep(settle)
        capture_x11(second, delay=0.0)
        if images_differ(first, second) <= tolerance:
            # Twice in a row before believing it: a repaint that has not
            # started yet also produces two identical frames, and calling
            # that "settled" is the very race this is here to close.
            calm += 1
            if calm == 2:
                return True
        else:
            calm = 0
    return False


def _converted(image: Path, args: list[str], suffix: str, what: str) -> Path:
    """Copy of the image run through `convert` with the given args.

    Removed first, and the exit status checked: the name is reused
    across retries, so a failed conversion would otherwise leave the
    previous run's picture in place and every measurement below would
    quietly run on stale pixels.
    """
    require_binary("convert")
    out = image.parent / f"{image.stem}_{suffix}.png"
    out.unlink(missing_ok=True)
    proc = subprocess.run(
        ["convert", str(image), *args, str(out)],
        capture_output=True,
    )
    if proc.returncode != 0 or not out.exists():
        pytest.fail(
            f"convert could not {what} {image}: "
            f"{(proc.stderr or b'').decode(errors='ignore').strip()!r}"
        )
    return out


def blank_region(
    image: Path, region: tuple[int, int, int, int] | None, suffix: str
) -> Path:
    """Copy of the image with the region painted over, so a comparison
    can ignore it. Returns the original when region is None."""
    if region is None:
        return image
    x, y, w, h = region
    return _converted(
        image,
        ["-fill", "black", "-draw", f"rectangle {x},{y} {x + w},{y + h}"],
        suffix, f"blank {region} in",
    )


def crop_region(
    image: Path, region: tuple[int, int, int, int], suffix: str,
    scale: int = 1,
) -> Path:
    """Copy of the image reduced to the region, optionally scaled up -
    OCR on a small screen font gains a lot from a 3x enlargement."""
    x, y, w, h = region
    args = ["-crop", f"{w}x{h}+{x}+{y}", "+repage"]
    if scale > 1:
        args += ["-resize", f"{scale * 100}%"]
    return _converted(image, args, suffix, f"crop {region} from")


def inset(crop: tuple[int, int, int, int], by: int) -> tuple[int, int, int, int]:
    """Shrink a crop on all four sides, e.g. to drop a key's border,
    rounded corners and the gap to its neighbour."""
    x, y, w, h = crop
    return x + by, y + by, w - 2 * by, h - 2 * by


_ICONS_TREE: list[Path | None] = []


def icons_tree() -> Path | None:
    """The installed icon directory of the built tree, or None when there
    is none to look into.

    Kept apart from installed_icon() so a caller can tell "this checkout
    has no build tree" from "the icon is missing", which are the same
    None but very different findings.
    """
    if _ICONS_TREE:
        return _ICONS_TREE[0]

    icons = "usr/share/tuxbox/neutrino/icons"
    trees: list[Path] = []
    # The install dir the suite was pointed at comes first: a debug or asan
    # build stages into its own prefix, and a stale release tree next door
    # must not vouch for the runtime that is actually being driven.
    install_dir = os.environ.get("NEUTRINO_INSTALL_DIR")
    if install_dir:
        trees += sorted(Path(install_dir).glob(f"**/{icons}"))
    root = Path(__file__).resolve().parents[2]
    trees.append(root / "root" / icons)
    trees += sorted((root / "artifacts" / "sysroot").glob(f"**/{icons}"))
    found = next((tree for tree in trees if tree.is_dir()), None)
    # Each candidate is a recursive walk of a sysroot; the answer cannot
    # change while a test session runs.
    _ICONS_TREE.append(found)
    return found


def installed_icon(name: str) -> Path | None:
    """Path of an installed OSD icon in the built tree, or None when no
    build tree is there to look into.

    Neutrino resolves icons through ICONSDIR at runtime, and the build
    stages them twice: into the runtime prefix the PC build actually
    loads from, and into the sysroot. The first tree that exists decides
    - a leftover sysroot copy must not vouch for a runtime tree that
    lost the file, because the runtime tree is what the box reads.
    """
    tree = icons_tree()
    if tree is None:
        return None
    candidate = tree / f"{name}.png"
    return candidate if candidate.exists() else None


def read_layout_token(strip: Path, tag: str, case_sensitive: bool = False) -> str:
    """The keyboard layout name OCR finds in the image: QWERTZ or QWERTY.

    Matched on WERTZ/WERTY without the leading Q: the capital Q is the
    letter OCR most likes to misread (as O or 0), while the differing
    tail letter is what actually tells the two layouts apart. Reading
    both or neither token is failed loudly instead of guessed at.

    Two ways to keep the key grid from spelling the token: crop it away
    and match case-folded (the cc dialog, whose footer strip is easy to
    cut), or keep the whole picture and match case-sensitively - the
    footer writes the layout name in capitals while an uncapsed grid
    spells its letters small (the legacy dialog, which floats centered
    and has no fixed strip to cut).
    """
    text = ocr_image(strip)
    if not case_sensitive:
        text = text.upper()
    has_z = "WERTZ" in text
    has_y = "WERTY" in text
    if has_z == has_y:
        pytest.fail(
            f"OCR could not tell the layout apart ({tag}): "
            f"both={has_z} in {text!r}"
        )
    return "QWERTZ" if has_z else "QWERTY"


def ocr_image(path: Path) -> str:
    """Perform OCR on image using Tesseract, skip if binary missing."""
    require_binary("tesseract")
    require_module("pytesseract")
    require_module("cv2")

    import cv2  # pylint: disable=import-error
    import pytesseract  # pylint: disable=import-error

    image = cv2.imread(str(path))
    if image is None:
        pytest.skip(f"Failed to read screenshot at {path}")
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    return pytesseract.image_to_string(gray)


def require_module(name: str) -> None:
    """Skip if the Python module is not installed."""
    try:
        __import__(name)
    except ImportError:
        pytest.skip(f"Python module '{name}' required for this test")
