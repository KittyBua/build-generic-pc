"""Running a throwaway Neutrino for GUI tests.

Extracted from test_tunerless_start.py, which grew the machinery first and is
no longer its only user: a test about tuner *misconfiguration* needs exactly
the same isolated run, only with a tuner present. The comments are kept where
they were written -- each one records a trap that cost a debugging round.
"""

import glob
import os
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
    """Use the caller's DISPLAY when it answers, else run a private Xvfb.

    A missing DISPLAY used to skip these tests, and a skipped guard passes
    hardest when things are broken -- so bring the display along instead."""

    def __init__(self):
        self.proc = None
        self.display = os.environ.get("DISPLAY")
        if self.display and self._answers(self.display):
            return
        if shutil.which("Xvfb") is None:
            pytest.skip("no working DISPLAY and no Xvfb to start one")
        self.display = ":97"
        self.proc = subprocess.Popen(
            ["Xvfb", self.display, "-screen", "0", "1280x720x24"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self._answers(self.display):
                return
            time.sleep(0.25)
        self.close()
        pytest.skip("private Xvfb did not come up")

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


class IsolatedNeutrino:
    """One throwaway Neutrino run against a config tree of the test's own.

    The tree is bind-mounted over the compile-time CONFIGDIR inside a private
    mount namespace, so the developer's configuration is neither read nor
    written -- Neutrino saves settings on exit, and a test must not be able to
    change what the next `make run` starts with.
    """

    def __init__(self, workdir: Path, display: str, simulate_fe: str = "0"):
        self.workdir = workdir
        self.config = workdir / "config"
        self.log = workdir / "stdout.log"
        (self.config / "zapit").mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        env["DISPLAY"] = display
        env["SIMULATE_FE"] = simulate_fe
        env["NEUTRINO_EXIT_CODES"] = "posix"
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

    def alive(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> None:
        # The whole process group this run created; never a foreign PID. Then
        # wait until the group is actually empty: the wrapper exits before
        # neutrino.real does, and the next test's "is one already running?"
        # check must not see our leftovers.
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


def settle(shot: Path, display: str, tries: int = 20) -> None:
    """Wait for two identical frames, then keep the shot."""
    prev = None
    for _ in range(tries):
        utils.capture_x11(shot, delay=0.4, display=display)
        cur = shot.read_bytes()
        if prev is not None and cur == prev:
            return
        prev = cur
