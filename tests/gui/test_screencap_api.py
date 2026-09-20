"""/control/screenshot on the generic PC goes through the screencap core.

WORK-273 phase 2 (spec 11, phase 2 AC): "PC build: /control/screenshot
yields an OSD without a tuner". Before phase 2 the PC path read the GL
buffer by hand; now cVideo::GetScreenImage() runs the same core the
screencap CLI runs on a box, with an in-process backend. This test is
the runtime half of that proof -- the host unit tests in libstb-hal
cover the core with synthetic buffers, this one covers the real GL
buffer through the real HTTP API, on a display of its own.

The file is checked with ImageMagick rather than a Python imaging
library: PIL is not a prerequisite of this suite (a phase-1 review
established that), `identify` and `convert` are host tools already
required elsewhere.
"""
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from . import utils
from .neutrino_run import (
    IsolatedNeutrino,
    require_isolated_run,
    require_no_frontend,
    send_keys,
)

# Not 31344 (a developer's `make run`) and not 31355 (test_webtv_scripts):
# two suites must never share a port.
HTTP_PORT = 31356
NHTTPD_CONF = (
    Path(__file__).resolve().parents[2]
    / "root" / "usr" / "var" / "tuxbox" / "config" / "nhttpd.conf"
)

# OwnedDisplay's private Xvfb is a fixed 1280x720 (neutrino_run.py, "The
# screen is a fixed 1280x720"), and the GL window fills it exactly:
# measured, not assumed -- a real capture on this fixture comes back at
# precisely 1280x720. Asserting that exact figure (not just "> 0") is
# strictly tighter without hardcoding a box resolution: a stride,
# half-buffer or zero-size regression in the legacy conversion would
# produce some *other* number and get caught, where a bare positivity
# check would wave it through. 1920x1080 is not expected here (see the
# module docstring) -- this is the window's own size.
EXPECTED_OSD_W = 1280
EXPECTED_OSD_H = 720

# scripts/run-neutrino.sh execs root/usr/bin/neutrino, which `make
# runtime-sync` installs as a wrapper that sets LUA_PATH and then runs
# neutrino.real beside it (see test_webtv_scripts.py, which this mirrors).
# `make -C build/neutrino` updates neither -- only runtime-sync stages a
# fresh binary, so this is the ELF to inspect for "is the change actually
# in the thing that will start", not the source tree or the build dir.
_BIN_DIR = Path(__file__).resolve().parents[2] / "root" / "usr" / "bin"
RUNTIME_BINARY = _BIN_DIR / "neutrino.real"
if not RUNTIME_BINARY.exists():
    RUNTIME_BINARY = _BIN_DIR / "neutrino"


def _require_fresh_binary() -> None:
    """Guard against testing yesterday's build, and against a silent skip.

    Two independent traps, both already on record for this suite (see
    test_webtv_scripts.py and the neutrino-generic-build shared memory):
    `make -C build/neutrino` alone leaves the runtime root untouched, so a
    run right after it would exercise whatever `make neutrino` installed
    last, not the working tree; and a bare `pytest` invocation of this file
    (not through `make test-gui`, which exports NEUTRINO_INSTALL_DIR via
    make/env-derive.mk's `.EXPORT_ALL_VARIABLES:`) never sets it, so
    require_isolated_run() -> ensure_neutrino_running() looks for
    /usr/bin/neutrino on the bare host, finds nothing, and skips every test
    in this file without a word about why -- exactly the shape of the
    brief's own step-2 verification command. Pointing it at the tree `make
    neutrino` fills makes that check agree with the tree this file actually
    starts Neutrino from, regardless of how the file is invoked.
    """
    if not RUNTIME_BINARY.exists():
        pytest.skip(f"{RUNTIME_BINARY} missing - run `make neutrino` first")
    os.environ.setdefault(
        "NEUTRINO_INSTALL_DIR",
        str(Path(__file__).resolve().parents[2] / "artifacts" / "sysroot"),
    )


def _binary_has(symbol: str) -> bool:
    """Is a given change actually in the binary that will start?

    Symbol names survive stripping in the dynamic tables and, unlike a
    version string, stay valid once the branch is merged into master.
    """
    try:
        return symbol.encode() in RUNTIME_BINARY.read_bytes()
    except OSError:
        return False


def _seed_config(config: Path) -> None:
    (config / "zapit").mkdir(parents=True, exist_ok=True)
    (config / "neutrino.conf").write_text(
        "language=deutsch\n"
        "uselastchannel=0\n"
    )
    text, count = re.subn(
        r"^WebsiteMain\.port=.*$",
        f"WebsiteMain.port={HTTP_PORT}",
        NHTTPD_CONF.read_text(),
        flags=re.MULTILINE,
    )
    assert count == 1, f"expected one port line in {NHTTPD_CONF}, replaced {count}"
    (config / "nhttpd.conf").write_text(text)


def _get(path: str, timeout: float = 15) -> str:
    with urllib.request.urlopen(f"http://127.0.0.1:{HTTP_PORT}{path}", timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def _wait_until_up(instance: IsolatedNeutrino, timeout: float = 60) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert instance.alive(), "Neutrino died before its web server answered"
        try:
            _get("/control/version", timeout=3)
            return
        except (urllib.error.URLError, OSError):
            time.sleep(1)
    pytest.fail(f"control API did not answer on port {HTTP_PORT} within {timeout:.0f} s")


def _settle_startup(instance: IsolatedNeutrino) -> None:
    """Wait for the input FIFO (opened late in the start), then dismiss the
    startup hint box so the screen shows Neutrino's own OSD, not a dialog
    raised from CNeutrinoApp::run (see test_webtv_scripts for the crash
    that nesting causes)."""
    fifo = Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input"))
    deadline = time.monotonic() + 40
    while not fifo.exists() and time.monotonic() < deadline:
        assert instance.alive(), "Neutrino died during startup"
        time.sleep(0.5)
    assert fifo.exists(), "the input FIFO never appeared; Neutrino never finished starting"
    time.sleep(3)
    send_keys("BACK", settle_for=3.0)
    assert instance.alive(), "Neutrino died while the startup box was dismissed"


def _identify(png: Path) -> tuple[int, int, str]:
    out = subprocess.run(
        ["identify", "-format", "%w %h %[channels]", str(png)],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    return int(out[0]), int(out[1]), out[2]


def _alpha_maximum(png: Path) -> float:
    out = subprocess.run(
        ["convert", str(png), "-alpha", "extract", "-format", "%[fx:maxima]", "info:"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return float(out)


def _unique_colors(png: Path) -> int:
    """Rejects the other half of "blank": alpha-maximum > 0 only proves the
    buffer is not all-transparent, and would wave through a uniformly
    opaque single-colour fill just as happily as a real, painted OSD."""
    out = subprocess.run(
        ["convert", str(png), "-format", "%k", "info:"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return int(out)


@pytest.fixture
def neutrino(tmp_path: Path, owned_display):
    _require_fresh_binary()
    require_isolated_run()
    require_no_frontend()
    utils.require_binary("identify")
    utils.require_binary("convert")
    if not _binary_has("sc_grab_osd"):
        pytest.skip(
            "the installed binary predates 01a170ca (no screencap inproc "
            "backend); run `make neutrino` against mpx.screencap"
        )
    workdir = tmp_path / "screencap"
    (workdir / "config").mkdir(parents=True)
    _seed_config(workdir / "config")
    # glfb.cpp's unlink+mkfifo+open(O_RDWR) creates this FIFO but nothing
    # ever removes it again: ~GLFbPC() only closes the fd, and stop() below
    # SIGTERMs the process group without touching the filesystem. Left in
    # place, _settle_startup's "wait for the FIFO to appear" loop finds the
    # PREVIOUS instance's stale file immediately and stops waiting before
    # this one has created its own -- a real race after any earlier
    # isolated run, including test 1 of this very file before test 2.
    # require_isolated_run() above already guarantees no other neutrino.real
    # is running, so nothing can be reading the file we are about to remove.
    Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input")).unlink(missing_ok=True)
    instance = IsolatedNeutrino(workdir, owned_display.display, simulate_fe="0")
    try:
        _settle_startup(instance)
        _wait_until_up(instance)
        yield instance
    finally:
        instance.stop()


def _shot(name: str, osd: int, video: int) -> Path:
    target = Path(f"/tmp/{name}.png")
    target.unlink(missing_ok=True)
    answer = _get(f"/control/screenshot?name={name}&osd={osd}&video={video}").strip()
    assert answer == "ok", f"/control/screenshot answered {answer!r}"
    assert target.exists(), f"{target} was not written although the API said ok"
    return target


@pytest.mark.gui
def test_osd_only_screenshot_is_a_real_osd(neutrino):
    """OSD without a tuner: the file is an RGBA PNG of the GL buffer's own
    size, and its alpha is not empty -- Neutrino has painted something."""
    png = _shot(f"sc-osd-{os.getpid()}", osd=1, video=0)
    try:
        w, h, channels = _identify(png)
        assert (w, h) == (EXPECTED_OSD_W, EXPECTED_OSD_H), (
            f"unexpected geometry {w}x{h}, expected {EXPECTED_OSD_W}x{EXPECTED_OSD_H}"
        )
        assert channels.endswith("a"), f"no alpha channel: {channels}"
        assert _alpha_maximum(png) > 0.0, "alpha is empty everywhere: no OSD in the shot"
        assert _unique_colors(png) > 1, "a single uniform colour: no real OSD content painted"
    finally:
        png.unlink(missing_ok=True)


@pytest.mark.gui
def test_video_requested_without_tuner_still_answers_ok(neutrino):
    """Best effort as before phase 2: with no decoder output the video
    layer is absent, and the API still writes an OSD-only image and says
    ok (the strict mode that makes this an error is a phase-4 HTTP
    option, not part of the old API)."""
    png = _shot(f"sc-both-{os.getpid()}", osd=1, video=1)
    try:
        w, h, _ = _identify(png)
        assert (w, h) == (EXPECTED_OSD_W, EXPECTED_OSD_H), (
            f"unexpected geometry {w}x{h}, expected {EXPECTED_OSD_W}x{EXPECTED_OSD_H}"
        )
    finally:
        png.unlink(missing_ok=True)


@pytest.mark.gui
def test_nothing_requested_is_an_error(neutrino):
    """Both layers off: the core reports LAYER_UNSUPPORTED, GetScreenImage
    returns false, the API answers error and writes no file."""
    name = f"sc-none-{os.getpid()}"
    target = Path(f"/tmp/{name}.png")
    target.unlink(missing_ok=True)
    answer = _get(f"/control/screenshot?name={name}&osd=0&video=0").strip()
    assert answer != "ok", "the API claimed ok for a capture of no layer at all"
    assert not target.exists(), f"{target} was written for a request of no layer"
