"""Running a throwaway Neutrino for GUI tests.

Extracted from test_tunerless_start.py, which grew the machinery first and is
no longer its only user: a test about tuner *misconfiguration* needs exactly
the same isolated run, only with a tuner present. The comments are kept where
they were written -- each one records a trap that cost a debugging round.
"""

import glob
import os
import re
import sys
import shutil
import signal
import subprocess
import time
from pathlib import Path

import pytest

from . import utils

ROOT_DIR = Path(__file__).resolve().parents[2]
RUN_SCRIPT = ROOT_DIR / "scripts" / "run-neutrino.sh"
CONFIG_MOUNT = ROOT_DIR / "root" / "usr" / "var" / "tuxbox" / "config"
BUILD_CONFIG_H = ROOT_DIR / "build" / "neutrino" / "config.h"

# Where the repo keeps the channel data it ships. A test that needs a zappable
# channel list builds its config from these rather than from the developer's
# own configuration, which would make the test depend on whatever they last
# scanned.
NEUTRINO_DATA = ROOT_DIR / "sources" / "neutrino" / "data"


class OwnedDisplay:
    """A display of this run's own: always a private Xvfb, never the
    caller's session.

    This used to take $DISPLAY whenever it answered and fall back to Xvfb
    only otherwise -- and that preference is the trap the class now exists
    to close. On a developer machine with a desktop session $DISPLAY is the
    real screen, so an isolated run started its own Neutrino correctly and
    then photographed the wrong thing: settle() grabs the root window, and
    `import -window root' reads the frame buffer rather than one
    application's output. Measured: one run's OCR came back with the
    desktop clock ('00:46 / Freitag, 4. September 2026'), and with the
    session display, the OCR of a ZDFsport shot came back full of editor
    text. The tests then fail for reasons that have nothing to do with
    Neutrino, and because `make test-gui' passes --maxfail=1, the first
    such failure takes the whole suite with it. `env -u DISPLAY' was the
    workaround everybody ended up finding on their own; doing it here,
    once, means nobody has to.

    A missing DISPLAY is still no reason to skip -- a skipped guard passes
    hardest when things are broken, so bring the display along instead.

    The screen is a fixed 1280x720 and tests assert exactly that figure
    (test_screencap_api.py, EXPECTED_OSD_W/H). Change both or neither.

    Watching a run is not what this is for: there is deliberately no
    variable that points it back at a session, because that is the same
    door under another name. `x11vnc -display :100' looks in from outside.

    The attaching tests (test_menu.py, test_overlay_paint.py,
    test_input_dialog.py) do not come through here at all: they drive a
    Neutrino the developer started and need the ambient DISPLAY.
    """

    # :100 upwards, above everything anyone else in this repo claims. :0 is
    # the session; :99 is what RUN_NEUTRINO_DISPLAY falls back to when there
    # is no session (make/env.mk), and scripts/run_neutrino.sh -- the
    # underscore one, behind `make run-now', not the run-neutrino.sh this
    # module execs -- adopts an occupied display instead of refusing it
    # ("Reusing existing X11 socket"). So a suite sitting on :99 would hand
    # a developer's `make run' our private Xvfb. Starting above it costs
    # nothing and needs no exception inside the walk.
    #
    # Walking is not what makes the suite parallelisable and does not mean
    # it is -- the input FIFO is a compile-time path and
    # require_isolated_run() forbids a second instance anyway. It only keeps
    # one leftover server from taking every later run down with it.
    FIRST_DISPLAY = 100
    LAST_DISPLAY = 109

    def __init__(self):
        self.proc = None
        self.display = None
        if shutil.which("Xvfb") is None:
            pytest.skip(
                "no Xvfb: these tests need a display of their own and will "
                "not borrow the caller's session (install xvfb)"
            )
        # Named separately from Xvfb, because without it the failure is
        # unreadable: _answers() swallows the OSError and reports False
        # forever, so every candidate starts a healthy Xvfb, waits out the
        # full timeout and gets killed again -- minutes of it, ending in
        # "no free display", which is not what went wrong. It lives in
        # x11-utils, which the host-tool list and setup_deps.sh ask for.
        if shutil.which("xdpyinfo") is None:
            pytest.skip(
                "no xdpyinfo: cannot tell when a private Xvfb is up "
                "(install x11-utils)"
            )
        for number in range(self.FIRST_DISPLAY, self.LAST_DISPLAY + 1):
            candidate = f":{number}"
            # Somebody else's server on this number: a second suite, or a
            # leftover from a killed run. Xvfb would refuse it, and the
            # refusal is silent because stderr goes to DEVNULL -- the code
            # that took :97 on faith then watched the *foreign* server
            # answer, called that success, and kept a dead Popen as
            # self.proc while handing back a display it did not own.
            if self._answers(candidate):
                continue
            proc = self._start(candidate)
            if proc is not None:
                self.proc = proc
                self.display = candidate
                return
        pytest.skip(
            f"no free display between :{self.FIRST_DISPLAY} and "
            f":{self.LAST_DISPLAY} for a private Xvfb"
        )

    @classmethod
    def _start(cls, display: str):
        """A live Xvfb on `display`, or None so the caller tries the next.

        Polls for the server rather than trusting Popen: Xvfb forks into
        place and is not answering yet when it returns. It also exits at
        once on a stale /tmp/.X<n>-lock, which is why poll() is checked --
        without it the loop would question a dead process for 15 seconds
        and then blame the timeout.
        """
        proc = subprocess.Popen(
            ["Xvfb", display, "-screen", "0", "1280x720x24"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            # Our own process first. The other order looks equivalent and is
            # not: when a parallel starter wins the number, ours exits on the
            # lock while theirs begins to answer, and asking the display
            # first would accept THEIR server as our success -- handing back
            # a display we do not own, with a dead Popen to close. That is
            # the exact failure this walk exists to end, so it must not be
            # rebuilt one level down.
            if proc.poll() is not None:
                return None
            if cls._answers(display):
                return proc
            time.sleep(0.25)
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        return None

    @staticmethod
    def _answers(display: str) -> bool:
        try:
            return (
                subprocess.run(
                    ["xdpyinfo", "-display", display],
                    capture_output=True,
                    timeout=10,
                ).returncode
                == 0
            )
        except (OSError, subprocess.TimeoutExpired):
            return False

    def close(self) -> None:
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def unshare_works() -> bool:
    try:
        return (
            subprocess.run(
                ["unshare", "-r", "-m", "true"],
                capture_output=True,
                timeout=10,
            ).returncode
            == 0
        )
    except (OSError, subprocess.TimeoutExpired):
        return False


def debug_logging_built_in() -> bool:
    """WARN/INFO are empty macros without -DDEBUG (src/zapit/debug.h), so a
    test whose only evidence is those log lines has to skip on a
    --without-debug build instead of failing red."""
    try:
        return "#define DEBUG 1" in BUILD_CONFIG_H.read_text(errors="replace")
    except OSError:
        return False


def root_children(display: str) -> set:
    """Window ids currently below the root window."""
    try:
        listing = subprocess.run(["xwininfo", "-display", display, "-root", "-children"],
                                 capture_output=True, text=True)
    except OSError:
        # Every isolated run calls this, not just the tests that photograph
        # something. A host without x11-utils must not die here with a
        # FileNotFoundError -- callers that need the list skip when it is
        # empty, and the rest never look.
        return set()
    return set(re.findall(r"^\s+(0x[0-9a-f]+)", listing.stdout, re.MULTILINE))


class IsolatedNeutrino:
    """One throwaway Neutrino run against a config tree of the test's own.

    The tree is bind-mounted over the compile-time CONFIGDIR inside a private
    mount namespace, so the developer's configuration is neither read nor
    written -- Neutrino saves settings on exit, and a test must not be able to
    change what the next `make run` starts with.
    """

    def __init__(
        self,
        workdir: Path,
        display: str,
        simulate_fe: str = "0",
        extra_env: dict[str, str] | None = None,
    ):
        self.workdir = workdir
        self.config = workdir / "config"
        self.log = workdir / "stdout.log"
        (self.config / "zapit").mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        env["DISPLAY"] = display
        env["SIMULATE_FE"] = simulate_fe
        env["NEUTRINO_EXIT_CODES"] = "posix"
        if extra_env:
            env.update(extra_env)
        # Everything below the root window before this run started. Neutrino
        # sets neither a window name nor _NET_WM_PID, so "which window is
        # Neutrino's" has no direct answer -- but "which windows appeared with
        # it" does, and that is enough to keep a screenshot from being taken of
        # somebody else's editor.
        self.display = display
        self._windows_before = root_children(display)
        # The bind mount lives and dies with this process's namespace, so a
        # crashed test cannot leave the developer tree shadowed.
        script = (
            f'mount --bind "{self.config}" "{CONFIG_MOUNT}" || exit 70\n'
            f'exec "{RUN_SCRIPT}"\n'
        )
        # Its own session, so stop() can kill the whole group: a TERM to the
        # unshare wrapper alone leaves neutrino.real running (measured).
        with open(self.log, "wb") as logfile:
            self.proc = subprocess.Popen(
                ["unshare", "-r", "-m", "bash", "-c", script],
                stdout=logfile,
                stderr=subprocess.STDOUT,
                env=env,
                start_new_session=True,
            )

    def wait_for(self, needle: str, timeout: float = 40.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if needle in self.log.read_text(errors="replace"):
                return True
            if self.proc.poll() is not None:
                return needle in self.log.read_text(errors="replace")
            time.sleep(0.5)
        return False

    def windows(self) -> list:
        """Windows that appeared since this run started -- Neutrino's own."""
        return sorted(root_children(self.display) - self._windows_before)

    def alive(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> None:
        # The whole process group this run created; never a foreign PID. Then
        # wait until the group is actually empty: the wrapper exits before
        # neutrino.real does, and the next test's "is one already running?"
        # check must not see our leftovers.
        #
        # TODO: this cleans up processes but nothing on disk, and one leftover
        # file quietly weakens every test that waits for startup. The HAL's
        # GLFbPC constructor does unlink -> mkfifo -> open on
        # /tmp/neutrino.input and its destructor only closes the descriptor,
        # so the FIFO outlives the run. Any test that waits for that path to
        # appear before sending a key therefore returns instantly from the
        # SECOND run onwards -- it finds the previous instance's file -- and is
        # left relying on whatever fixed sleep follows. If the new instance has
        # not reached GLFbPC by then, the write hits ENXIO, send_keys reports
        # "has no reader", and utils.fail_or_skip turns that into a skip: the
        # test silently does not run. test_screencap_api.py unlinks the path
        # itself before starting its instance, which works but has to be
        # repeated in every such test. Unlinking it here, once, would fix it
        # for all of them.
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            pass
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                os.killpg(self.proc.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.2)
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def require_isolated_run() -> None:
    """Preconditions every test that starts its own Neutrino shares.

    These tests run their own instance, so they need an idle machine: the
    input FIFO path is a compile-time constant, and a second instance would
    steal the running one's keys. Skipping is the honest answer on a developer
    box with `make run` active -- but each skip names what is missing, so a
    green suite cannot quietly mean 'nothing ran' without saying so (the skip
    accounting itself is WORK-215)."""
    utils.ensure_neutrino_running()  # binary built?
    if not unshare_works():
        pytest.skip("unprivileged user+mount namespaces unavailable")
    if subprocess.run(["pgrep", "-x", "neutrino.real"], capture_output=True).returncode == 0:
        pytest.skip("needs an idle machine: another neutrino.real is running (stop `make run` first)")


def require_no_frontend() -> None:
    """Only for tests whose premise is a machine with no usable tuner.

    Deliberately not part of require_isolated_run(): most isolated runs work
    perfectly well with a tuner plugged in, and skipping those would hide them.
    """
    if glob.glob("/dev/dvb/adapter*/frontend*"):
        pytest.skip("needs a machine without a DVB frontend; one is present")


def settle(shot: Path, display: str, tries: int = 20, windows: list | None = None) -> None:
    """Wait for two identical frames, then keep the shot."""
    prev = None
    for _ in range(tries):
        utils.capture_x11(shot, delay=0.4, display=display, windows=windows)
        cur = shot.read_bytes()
        if prev is not None and cur == prev:
            return
        prev = cur


def send_keys(*keys: str, settle_for: float = 0.0) -> None:
    """Replay remote-control keys into the running Neutrino.

    One helper for the four GUI test modules that used to keep a copy each,
    with the most defensive set of the four: a missing interpreter, a missing
    evdev and a readerless FIFO are environment gaps and skip, everything else
    is a defect and fails (utils.fail_or_skip). `settle_for` is the pause some
    callers need before looking at the screen; the default is no pause.
    """
    try:
        subprocess.run(
            [sys.executable, "-m", "tests.gui.send_keys", *keys],
            check=True,
            capture_output=True,
            cwd=ROOT_DIR,
        )
    except FileNotFoundError:
        pytest.skip("python3 not available to replay keys")
    except subprocess.CalledProcessError as exc:
        utils.fail_or_skip(exc)
    except SystemExit as exc:  # send_keys handles missing evdev
        pytest.skip(str(exc))
    if settle_for:
        time.sleep(settle_for)
