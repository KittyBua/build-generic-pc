"""The remote control path and the queue behind it, on a private display.

WORK-273 phase 3 (spec 11, phase 3 AC): every screenshot Neutrino takes
goes through CScreencapService. test_screencap_api.py proves the HTTP
entry -- one synchronous capture, one file; this file proves the other
half, the one that got harder when the capture moved off the GUI thread:

  * a series of screenshot_count shots gets screenshot_count files,
  * an unwritable screenshot_dir falls back to /tmp and says so, and the
    outcome carries the substitution instead of reading as a clean ok,
  * /control/screenshot refuses a path as a name before writing,
  * a layer this platform cannot deliver is refused, and a capture that
    lost one is reported as having lost it rather than as a clean ok,
  * a SIGTERM in the middle of a series ends, worker and all.

The first of those is a regression test for a Critical defect and is the
reason this file exists (see test_every_capture_gets_its_own_file).

Which handler sees the screenshot key depends on what is on screen, so
none of these tests asserts a fixed number of files from one press. The
infobar runs a message loop of its own and forwards key_screenshot to
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
from .test_screencap_api import (  # noqa: F401 -- neutrino is a fixture
    _get,
    _require_fresh_binary,
    _settle_startup,
    neutrino,
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
# capture was clean, which is what makes it evidence: see
# test_http_marks_a_missing_layer_instead_of_calling_it_clean, where a
# clean capture and a degraded one come out of the same run.
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
    seen fail is not yet known to be a check. test_check_series_rejects_
    the_collision does exactly that, with the defect's measured shape.
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
    fail for want of a decoder layer: these tests are about names,
    directories and shutdown, not about layers -- the two HTTP tests
    below own the layer questions.
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
def series(tmp_path: Path, owned_display):
    workdir = tmp_path / "series"
    shots = workdir / "shots"
    shots.mkdir(parents=True)
    instance = _start(workdir, owned_display.display, str(shots), SHOTS)
    try:
        yield instance, shots
    finally:
        instance.stop()


def test_check_series_rejects_the_collision():
    """The negative control for the check below, kept in the suite.

    check_series() is the whole of test_every_capture_gets_its_own_file's
    judgement, and a run on a fixed build never shows it saying no. These
    three shapes are what it has to reject, and the last two are what the
    defect and a wrong-branch run actually looked like when they were
    measured -- five captures reporting one path with one file on disk,
    and a single-shot run that would satisfy "files == captures" on its
    own. Without this, "the test passed" and "the test cannot fail" look
    identical from the outside.

    Not marked gui: it starts nothing, so it also runs where a display
    or a namespace is missing and the rest of this file skips.
    """
    one = ["/tmp/same.png"] * SHOTS
    with pytest.raises(AssertionError, match="names collided"):
        check_series(one, ["/tmp/same.png"])
    with pytest.raises(AssertionError, match="no series ran"):
        check_series(["/tmp/a.png", "/tmp/b.png"], ["/tmp/a.png", "/tmp/b.png"])
    # Same count on both sides, different names: only the third assertion
    # catches this one.
    with pytest.raises(AssertionError, match="not the ones the service reported"):
        check_series([f"/tmp/said-{i}.png" for i in range(SHOTS)],
                     [f"/tmp/wrote-{i}.png" for i in range(SHOTS)])


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


@pytest.mark.gui
def test_unwritable_dir_falls_back_to_tmp(tmp_path, owned_display):
    """An unwritable screenshot_dir does not lose the shot, and does not
    pretend the shot went where it was asked to go.

    CScreencapService::ensureDir() creates the directory when it can, and
    writes to /tmp when it cannot. The log line alone was the old answer
    and is not enough: noteDirFallback() now puts the substitution into
    the Outcome as well, so the capture comes back ok (the file really
    was written) but carrying ERR_WRITE and the errno behind it -- a
    structured caller would otherwise see a flawless capture with no hint
    that the file is not where the user configured it.

    /proc/nonexistent can be neither created nor written, by anyone, not
    even by the root this run is inside its user namespace. The HTTP
    entry could not be used for this: it sets job.path itself, so it
    never reaches makeFileName() and never asks ensureDir() anything.
    Only the key path does, which is the point of testing it from here.
    """
    configured = "/proc/nonexistent/shots"
    workdir = tmp_path / "fallback"
    instance = _start(workdir, owned_display.display, configured, 1)
    written = []
    try:
        send_keys(KEY_SCREENSHOT, settle_for=0.0)
        # No log to poll while it runs (see above), so give the capture a
        # bounded chance to land before asking the log where it went.
        time.sleep(15)
        instance.stop()
        log = instance.log.read_text(errors="replace")
        screencap_lines = "\n".join(ln for ln in log.splitlines() if "screencap" in ln)
        assert f"{configured} not usable" in log and "using /tmp" in log, (
            "ensureDir() did not report the fallback:\n" + screencap_lines
        )
        reported = [o for o in _outcomes(log) if o.ok]
        assert reported, (
            "the fallback was logged but nothing was captured:\n" + screencap_lines
        )
        for o in reported:
            written.append(Path(o.path))
            assert o.path.startswith("/tmp/"), f"fell back to {o.path}, not to /tmp"
            assert Path(o.path).exists(), f"{o.path} was reported captured but is not there"
            # The point of the test: ok, but not clean. An Outcome that
            # echoed ERR_NONE here would print no note at all -- which is
            # what a clean capture in any other test of this file does,
            # so the empty string is a real alternative and this is a
            # real check.
            assert configured in o.note and "/tmp" in o.note, (
                f"the capture reads as a clean ok, or does not name the directory it "
                f"could not use: {o.note!r}\n" + screencap_lines
            )
    finally:
        instance.stop()
        for png in written:
            png.unlink(missing_ok=True)


@pytest.mark.gui
def test_http_rejects_a_path_as_name(neutrino, tmp_path):  # noqa: F811
    """A path in "name" is refused before anything is written.

    "name" used to reach the filename unchecked -- ScreenshotCGI builds
    "/tmp/" + name + ".png" -- so ../../etc/x put a PNG where it pointed,
    from an unauthenticated request. The CGI now asks
    CScreencapService::validBasename() first, the same rule the Lua entry
    uses. The sibling file's tests are the other half of this one: they
    show a well-formed name still answers "ok", so a refusal here is the
    rule biting and not the API being broken.

    The escape target is deliberately a directory this user can write.
    "../evil" alone would not do: it resolves to /evil.png, which nobody
    can create here anyway, so the request would answer "error" whether
    the rule ran or not and the check could not fail. Reaching tmp_path
    instead means an unguarded build really would answer "ok" and really
    would leave the file -- and both assertions have something to catch.
    """
    escaped = tmp_path / "evil.png"
    escaped.unlink(missing_ok=True)
    # Raw, not percent-encoded: "%2F" would be refused for the '%' and the
    # test would pass without ever putting a separator in front of the rule.
    name = f"{os.path.relpath(tmp_path, '/tmp')}/evil"
    answer = _get(f"/control/screenshot?name={name}&osd=1&video=0").strip()
    assert "invalid name" in answer, (
        f"a path was accepted as a name, or refused by something other than "
        f"validBasename(): {answer!r}"
    )
    assert not escaped.exists(), f"{escaped} was written -- the name escaped /tmp"
    # The classic form from the report, for the record. Its target is not
    # writable here, so only the refusal itself is evidence.
    assert "invalid name" in _get("/control/screenshot?name=../evil&osd=1&video=0").strip()
    assert not Path("/evil.png").exists(), "/evil.png was written"


@pytest.mark.gui
def test_http_refuses_a_layer_the_platform_cannot_deliver(neutrino):  # noqa: F811
    """Video alone, on a PC with no tuner: refused, and no file.

    There is no decoder output on this build, so LAYER_VIDEO is a layer
    the platform cannot deliver. The core answers NO_VIDEO at video_read,
    grabAndWrite() returns before the encoder, and the API says error
    with nothing on disk -- rather than writing an empty or OSD-only
    picture under the name the caller asked for.

    The OSD-only request in the same run is the control: it goes through
    the same entry, the same service and the same instance and answers
    ok with a file, so the refusal above is the missing layer and not a
    web server that cannot serve or a directory it cannot write.
    """
    video_only = Path(f"/tmp/sc-vid-{os.getpid()}.png")
    control = Path(f"/tmp/sc-ctl-{os.getpid()}.png")
    for png in (video_only, control):
        png.unlink(missing_ok=True)
    try:
        answer = _get(f"/control/screenshot?name={video_only.stem}&osd=0&video=1").strip()
        assert answer != "ok", "a video-only capture claimed ok without a video layer"
        assert not video_only.exists(), f"{video_only} was written for a refused capture"

        assert _get(f"/control/screenshot?name={control.stem}&osd=1&video=0").strip() == "ok"
        assert control.exists(), "the OSD-only control did not write its file"

        neutrino.stop()  # fully buffered stdout; see the series test
        log = neutrino.log.read_text(errors="replace")
        refused = [o for o in _outcomes(log) if o.path == str(video_only)]
        assert len(refused) == 1, f"expected one outcome for {video_only}, got {refused}"
        assert not refused[0].ok
        assert "no-video" in refused[0].note, (
            f"the refusal does not name the missing layer: {refused[0].note!r}"
        )
    finally:
        for png in (video_only, control):
            png.unlink(missing_ok=True)


@pytest.mark.gui
def test_http_marks_a_missing_layer_instead_of_calling_it_clean(neutrino):  # noqa: F811
    """A capture that lost a layer is ok, but says which one it lost.

    osd=1&video=1 with no decoder is the case the old code papered over:
    StartSync() answered with a bool, so a picture that arrived without
    the video layer was indistinguishable from one that had everything.
    The core measures layers_captured, so the Outcome comes back ok --
    the file is real and best effort is what this API promised -- with
    NO_VIDEO still on it.

    The OSD-only capture in the same run is the control, and it is what
    makes the note evidence rather than decoration: it asks for a layer
    that IS there, and its line carries no note at all. Both come out of
    one log through one parser, so "every line has a note" cannot be why
    this passes.

    Only the log carries it today: ScreenshotCGI answers on Outcome::ok
    alone, so the HTTP reply for a degraded capture is a plain "ok". That
    is the phase-3 contract -- the strict/report variant is phase 4 -- and
    this test pins where the distinction does exist.
    """
    degraded = Path(f"/tmp/sc-deg-{os.getpid()}.png")
    clean = Path(f"/tmp/sc-cln-{os.getpid()}.png")
    for png in (degraded, clean):
        png.unlink(missing_ok=True)
    try:
        assert _get(f"/control/screenshot?name={degraded.stem}&osd=1&video=1").strip() == "ok"
        assert degraded.exists(), "no file although the API said ok"
        assert _get(f"/control/screenshot?name={clean.stem}&osd=1&video=0").strip() == "ok"
        assert clean.exists(), "the OSD-only control did not write its file"

        neutrino.stop()
        log = neutrino.log.read_text(errors="replace")
        by_path = {o.path: o for o in _outcomes(log)}
        assert str(degraded) in by_path and str(clean) in by_path, (
            f"the service did not report both captures: {sorted(by_path)}"
        )
        lost, whole = by_path[str(degraded)], by_path[str(clean)]
        assert lost.ok and whole.ok, "a capture failed; this test is about a degraded ok"
        assert "no-video" in lost.note, (
            f"a capture without the video layer was reported as clean: {lost.note!r}"
        )
        assert whole.note == "", (
            f"the control carries a note too, so a note proves nothing here: {whole.note!r}"
        )
    finally:
        for png in (degraded, clean):
            png.unlink(missing_ok=True)


@pytest.mark.gui
def test_shutdown_during_a_series_ends(tmp_path, owned_display):
    """SIGTERM with a series still in the queue ends, and does not crash.

    The worker is stopped, not abandoned: CScreencapService::stop() runs
    from ExitRun()/stop_daemons() before g_RCInput and videoDecoder go
    away, hands the waiting jobs ERR_ABORTED, lets the one in flight
    finish and joins. A shutdown that waited for all screenshot_count
    captures, or that tore the decoder out from under the worker, would
    show up here as a timeout or as a signal in the log.
    """
    workdir = tmp_path / "shutdown"
    shots = workdir / "shots"
    shots.mkdir(parents=True)
    instance = _start(workdir, owned_display.display, str(shots), SHOTS)
    try:
        time.sleep(INFOBAR_GONE)
        # No settle: SIGTERM has to arrive while the queue still has jobs
        # in it, which is the whole premise.
        send_keys(KEY_SCREENSHOT, settle_for=0.0)
        started = time.monotonic()
        instance.stop()  # SIGTERM to the group, then wait for it to empty
        took = time.monotonic() - started
        # stop() waits 10 s, then polls for 10 s, then escalates to
        # SIGKILL. The bound has to sit below that escalation to mean
        # anything: a shutdown that hung on the worker must fail here, not
        # be quietly killed and reported as a clean exit.
        assert took < 15, f"neutrino needed {took:.1f} s to exit a SIGTERM during a series"
        assert not instance.alive(), "neutrino survived the SIGTERM"
        log = instance.log.read_text(errors="replace")
        for crash in ("Segmentation", "Aborted", "AddressSanitizer", "terminate called"):
            assert crash not in log, f"{crash!r} in the log -- crash during shutdown"
    finally:
        instance.stop()
