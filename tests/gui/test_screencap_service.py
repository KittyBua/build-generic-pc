"""Every screenshot in a series gets a file of its own.

WORK-273 phase 3 (spec 11, phase 3 AC): every screenshot Neutrino takes
goes through CScreencapService. test_screencap_api.py proves the HTTP
entry -- one synchronous capture, one file; this file proves the key,
and the queue that got harder to reason about when the capture moved off
the GUI thread.

It exists for the regression test below, which pins a Critical defect:
the names of a whole series were built inside one millisecond and
collided, so N screenshots left one file and screenshot_count had
silently stopped doing anything.

Which handler sees the screenshot key depends on what is on screen, so
nothing here asserts a fixed number of files from one press. The infobar
runs a message loop of its own and forwards key_screenshot to
CNeutrinoApp::handleMsg (infoviewer.cpp), which holds the SINGLE-shot
branch, while the series lives in RealRun's own loop (neutrino.cpp) and
only inside "mode is tv/radio/webtv/webradio". Both were measured here.
What is asserted instead is the relationship between captures and files,
which holds on either branch.
"""
import os
import re
import shutil
import time
from collections import namedtuple
from pathlib import Path

import pytest

from .neutrino_run import NEUTRINO_DATA, IsolatedNeutrino, require_isolated_run, send_keys
from .test_screencap_api import (  # noqa: F401 -- private_display is a fixture
    _require_fresh_binary,
    _settle_startup,
    private_display,
)

# CRCInput::RC_games, Neutrino's factory default for key_screenshot and
# bound to nothing else; send_keys.py carries the code.
KEY_SCREENSHOT = "GAMES"

# Five, not two: a run that silently took the single-shot branch for both
# presses would produce two captures and two files and satisfy a "files ==
# captures" check on its own. Requiring at least five makes such a run fail
# loudly instead of passing quietly -- only the series branch can produce
# that many from these presses.
SHOTS = 5

# The infobar is up after a zap and eats the first presses (see the module
# docstring). timing.infobar_* is in seconds and is set to its minimum
# below; eight is that minimum with room for a loaded machine.
INFOBAR_GONE = 8.0

# The one line every outcome passes through, whichever entry queued it --
# CScreencapService::run() and ::capture(), printf("[screencap] %s: %s%s"):
#
#   [screencap] /tmp/a.png: ok
#   [screencap] /tmp/a.png: ok no-video at video_read: ... (a degraded ok)
#   [screencap] /tmp/a.png: FAILED no-video at video_read: ...
#
# The trailing group is Outcome::describe() and is EMPTY exactly when the
# capture was clean.
#
# Non-greedy path: describe() itself contains ": " (a stage, then the
# core's text), so a greedy one has to backtrack through them.
_OUTCOME = re.compile(
    r"^\[screencap\] (?P<path>.+?): (?P<verdict>ok|FAILED)(?P<note>.*)$"
)

# note is "" exactly when the capture was clean; see _OUTCOME above.
Outcome = namedtuple("Outcome", "path ok note")


def _outcomes(log: str) -> list:
    """Every capture the service reported, in order."""
    found = []
    for line in log.splitlines():
        m = _OUTCOME.match(line)
        if m:
            found.append(Outcome(m.group("path"), m.group("verdict") == "ok",
                                 m.group("note").strip()))
    return found


def _captured_paths(log: str) -> list:
    return [o.path for o in _outcomes(log) if o.ok]


def check_series(captured: list, files: list) -> None:
    """The property this file exists for: one file per capture, at its own
    name, and enough captures that a single-shot run cannot satisfy it.

    A function rather than four asserts in the test body so that it can be
    handed a doctored pair and watched to go red -- a check nobody has ever
    seen fail is not yet known to be a check.
    """
    assert len(captured) >= SHOTS, (
        f"no series ran: only {len(captured)} capture(s), expected at least {SHOTS} "
        f"from one press at screenshot_count={SHOTS}. The key never reached "
        f"RealRun's series branch, so this run proves nothing about names:\n"
        + "\n".join(captured)
    )
    assert len(files) == len(captured), (
        f"{len(captured)} successful captures produced {len(files)} file(s) -- "
        f"names collided.\nfiles: {files}\ncaptured:\n" + "\n".join(captured)
    )
    # Strictly stronger than the counts, and free: with the defect back the
    # service reports the same path N times, so this list has duplicates
    # where the directory has one entry. It also catches a capture that
    # landed somewhere other than where it said it did.
    assert sorted(captured) == sorted(files), (
        "the files on disk are not the ones the service reported.\n"
        "files:\n" + "\n".join(sorted(files)) + "\ncaptured:\n" + "\n".join(sorted(captured))
    )
    for name in files:
        head = Path(name).read_bytes()[:8]
        assert head == b"\x89PNG\r\n\x1a\n", f"{name} is not a PNG (starts {head!r})"


def _seed(config: Path, shots_dir: str, count: int) -> None:
    """A config that can zap, with the screenshot settings under test.

    The series branch sits inside RealRun's "mode is tv/radio/..." arm, so
    the run needs a channel list and a frontend to reach it at all -- an
    instance without either never leaves the neutral mode and the key
    falls through to the single-shot branch. The channel data comes from
    what the repo ships, never from the developer's own configuration.

    key_screenshot is deliberately NOT written: RC_games is what
    loadKeys() defaults it to (neutrino.cpp), so the tests press the
    binding a user really gets rather than one the test invented.

    OSD-only (screenshot_mode=1, screenshot_video=0) so no capture can
    fail for want of a decoder layer: this is about names, not layers.
    """
    zapit = config / "zapit"
    zapit.mkdir(parents=True, exist_ok=True)
    for name in ("services.xml", "bouquets.xml", "ubouquets.xml"):
        shutil.copy(NEUTRINO_DATA / "initial" / name, zapit / name)
    shutil.copy(NEUTRINO_DATA / "config" / "satellites.xml", config / "satellites.xml")
    (config / "neutrino.conf").write_text(
        "language=deutsch\n"
        "timing.infobar_tv=1\n"
        "timing.infobar_radio=1\n"
        f"screenshot_count={count}\n"
        "screenshot_mode=1\n"
        "screenshot_video=0\n"
        "screenshot_format=0\n"
        f"screenshot_dir={shots_dir}\n"
    )


def _start(workdir: Path, display: str, shots_dir: str, count: int) -> IsolatedNeutrino:
    _require_fresh_binary()
    require_isolated_run()
    config = workdir / "config"
    config.mkdir(parents=True)
    _seed(config, shots_dir, count)
    # see test_screencap_api.py: the previous run's FIFO is never removed,
    # and _settle_startup would find it and stop waiting before this
    # instance has made its own.
    Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input")).unlink(missing_ok=True)
    instance = IsolatedNeutrino(workdir, display, simulate_fe="1")
    _settle_startup(instance)
    return instance


@pytest.fixture
def series(tmp_path: Path, private_display):  # noqa: F811
    workdir = tmp_path / "series"
    shots = workdir / "shots"
    shots.mkdir(parents=True)
    instance = _start(workdir, private_display.display, str(shots), SHOTS)
    try:
        yield instance, shots
    finally:
        instance.stop()


@pytest.mark.gui
def test_every_capture_gets_its_own_file(series):
    """Every capture in a series gets a file of its own.

    Regression test for a Critical defect: the old code grabbed
    synchronously on the GUI thread between two MakeFileName() calls, and
    that is what kept the millisecond stamps apart. With the capture on a
    worker the screenshot_count names are built back to back, inside the
    same millisecond, and collided -- a series of N screenshots left ONE
    file, and screenshot_count had silently stopped doing anything.
    CScreencapService::makeFileName() now claims each name under a lock
    against both the filesystem and the names already handed out.

    Two presses eight seconds apart: by the second the infobar is long
    gone, so at least one press reaches the series branch. That is what
    the "at least SHOTS captures" assertion below checks -- without it a
    run that only ever took the single-shot path would pass.
    """
    instance, shots = series
    time.sleep(INFOBAR_GONE)
    send_keys(KEY_SCREENSHOT, settle_for=INFOBAR_GONE)
    send_keys(KEY_SCREENSHOT, settle_for=INFOBAR_GONE)

    # Neutrino's stdout is a file here and therefore fully buffered; read
    # while it runs and only the blocks already flushed are there, which
    # undercounts. Stop first. stop() is safe to call twice -- the fixture
    # calls it again and finds the group gone.
    instance.stop()
    log = instance.log.read_text(errors="replace")
    check_series(_captured_paths(log), [str(p) for p in shots.iterdir()])
