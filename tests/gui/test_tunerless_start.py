# WORK-222: a PC without a usable tuner must start with defined Zapit state.
#
# Before the fix, CZapit::Start() bailed out ahead of LoadSettings() when no
# frontend opened, and the start wizard then displayed indeterminate memory as
# tuner settings (0x20202020 -> "53897628800 ms"), segfaulted on "next"
# (SaveSettings dereferenced the never-initialised current_channel), and wrote
# the garbage into zapit.conf where it outlived the session.
#
# These tests run their own Neutrino instance: the developer run targets export
# SIMULATE_FE=1 (scripts/run-neutrino.sh), which creates a dummy frontend and
# sails past the very defect under test. A private mount namespace bind-mounts
# a throwaway config tree over the compile-time CONFIGDIR, so the wizard runs
# and nothing of the developer's real configuration is at risk.

import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from . import utils

ROOT_DIR = Path(__file__).resolve().parents[2]
RUN_SCRIPT = ROOT_DIR / "scripts" / "run-neutrino.sh"
CONFIG_MOUNT = ROOT_DIR / "root" / "usr" / "var" / "tuxbox" / "config"
BUILD_CONFIG_H = ROOT_DIR / "build" / "neutrino" / "config.h"


def _debug_logging_built_in() -> bool:
    """WARN/INFO are empty macros without -DDEBUG (src/zapit/debug.h), and
    the healing test's only evidence is those log lines. On a --without-debug
    build the healing works but says nothing, so the test has to skip there
    honestly instead of failing red."""
    try:
        return "#define DEBUG 1" in BUILD_CONFIG_H.read_text(errors="replace")
    except OSError:
        return False


def _require_isolated_run() -> None:
    """Preconditions both tunerless tests share.

    These tests run their own Neutrino, so they need an idle machine: the
    input FIFO path is a compile-time constant, and a second instance would
    steal the running one's keys. Skipping is the honest answer on a
    developer box with `make run` active -- but each skip names what is
    missing, so a green suite cannot quietly mean 'nothing ran' without
    saying so (the skip accounting itself is WORK-215)."""
    utils.ensure_neutrino_running()  # binary built?
    if not _unshare_works():
        pytest.skip("unprivileged user+mount namespaces unavailable")
    if subprocess.run(["pgrep", "-x", "neutrino.real"], capture_output=True).returncode == 0:
        pytest.skip("needs an idle machine: another neutrino.real is running (stop `make run` first)")


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


def _unshare_works() -> bool:
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


class TunerlessNeutrino:
    """One throwaway Neutrino run: empty config, no tuner, no dummy frontend."""

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


@pytest.fixture
def owned_display():
    display = OwnedDisplay()
    try:
        yield display
    finally:
        display.close()


@pytest.fixture
def tunerless(tmp_path: Path, owned_display):
    _require_isolated_run()
    instance = TunerlessNeutrino(tmp_path, owned_display.display)
    try:
        yield instance
    finally:
        instance.stop()


def _send(*keys: str) -> None:
    try:
        subprocess.run(
            [sys.executable, "-m", "tests.gui.send_keys", *keys],
            check=True,
            capture_output=True,
            cwd=ROOT_DIR,
        )
    except subprocess.CalledProcessError as exc:
        # Same classification as the rest of the suite: a missing evdev or a
        # readerless FIFO is an environment gap, not a defect (utils).
        utils.fail_or_skip(exc)


def _settle(shot: Path, display: str, tries: int = 20) -> None:
    """Wait for two identical frames, then keep the shot."""
    prev = None
    for _ in range(tries):
        time.sleep(0.4)
        subprocess.run(
            ["import", "-display", display, "-window", "root", str(shot)],
            check=True,
            capture_output=True,
        )
        cur = shot.read_bytes()
        if prev is not None and cur == prev:
            return
        prev = cur


@pytest.mark.gui
def test_tunerless_wizard_shows_defaults_and_survives_next(tunerless, owned_display, tmp_path: Path) -> None:
    # The run must actually be the tunerless one: with a frontend present this
    # test would pass on unfixed code, which is exactly the
    # guard-that-passes-when-broken trap.
    assert tunerless.wait_for("found 0 frontends"), "expected a run without any frontend"
    # "found 0 frontends" prints BEFORE the dummy-frontend block, so on its own
    # it cannot tell "no frontend" from "dummy frontend" -- and with the dummy
    # this test is green on unfixed code. Prove the dummy did not come up.
    assert "SIMULATE_FE is set" not in tunerless.log.read_text(errors="replace"), (
        "a dummy frontend appeared; SIMULATE_FE=0 did not reach Neutrino"
    )
    # The no-tuner info box is modal and sits BEFORE "menue setup" in the start
    # sequence, so waiting for that line here would dead-lock. The input FIFO
    # appearing means rcinput is up and the box can take its OK.
    fifo = Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input"))
    deadline = time.monotonic() + 40
    while not fifo.exists() and time.monotonic() < deadline:
        assert tunerless.alive(), "Neutrino died during startup"
        time.sleep(0.5)
    assert fifo.exists(), "input FIFO never appeared"
    time.sleep(3)

    shot = tmp_path / "step.png"

    # Info box (no usable tuner) -> language list -> Deutsch.
    _send("OK")
    assert tunerless.wait_for("menue setup"), "Neutrino did not reach the wizard"
    _settle(shot, owned_display.display)
    _send("UP", "OK")
    _settle(shot, owned_display.display)

    # Walk the wizard up to the tuner page the way a user does. The pages in
    # between (video, OSD, network) all end on a "next" forwarder.
    for _ in range(3):
        _send("OK")
        _settle(shot, owned_display.display)
    _send("BACK")  # the network page's OK opened its interface submenu
    _settle(shot, owned_display.display)

    text = utils.ocr_image(shot)
    assert "Tuner" in text, f"not on the tuner page: {text!r}"
    # feTimeout's default is 40, shown through the "%d00 ms" format as 4000 ms.
    # The bug showed an 11-digit number here.
    assert re.search(r"\b4000\b", text), f"tuner timeout is not the default: {text!r}"
    assert not re.search(r"\d{6,}", text), f"garbage value on the tuner page: {text!r}"

    # The key that used to segfault: leaving the tuner page runs saveScanSetup()
    # -> CZapit::SetConfig() -> SaveSettings().
    _send("OK")
    _settle(shot, owned_display.display)
    assert tunerless.alive(), "Neutrino died on 'next' in the tuner page"

    # A Zapit that never started must not have persisted anything.
    assert not (tunerless.config / "zapit" / "zapit.conf").exists(), (
        "half-initialised Zapit wrote zapit.conf"
    )


@pytest.mark.gui
def test_poisoned_config_is_healed_on_load(tmp_path: Path, owned_display) -> None:
    # An older build already wrote indeterminate memory into zapit.conf.
    # Loading must repair every field, say so per field, and leave a
    # hand-written value that merely exceeds the menu's range alone.
    _require_isolated_run()
    # The evidence is WARN lines, which are empty macros without -DDEBUG
    # (src/zapit/debug.h): a --without-debug build heals fine but silently.
    if not _debug_logging_built_in():
        pytest.skip("zapit WARN logging compiled out (--without-debug); heal lines cannot appear")

    workdir = tmp_path / "healed"
    (workdir / "config" / "zapit").mkdir(parents=True)
    (workdir / "config" / "zapit" / "zapit.conf").write_text(
        "feTimeout=538976288\n"      # 0x20202020, the value users actually saw
        "rezapTimeout=538976288\n"   # sleep() of ~17 years per rezap
        "feRetries=150\n"            # beyond the menu's 0..9, but plausible: must survive
        "gotoXXLatitude=1e400\n"     # overflows strtod
        "gotoXXLongitude=banana\n"   # parses to nothing
        "cam_ci=7\n"                 # outside the switch in Start()
    )
    # LoadSettings() only runs once a frontend exists, so this run uses the
    # dummy one - the same shape as a user's AppImage with SIMULATE_FE=1.
    instance = TunerlessNeutrino(workdir, owned_display.display, simulate_fe="1")
    try:
        assert instance.wait_for("SIMULATE_FE is set"), "dummy frontend did not come up"
        assert instance.wait_for("out of range"), "no healing happened"
        time.sleep(2)
        log = instance.log.read_text(errors="replace")
        for expect in (
            "feTimeout=538976288 out of range",
            "rezapTimeout=538976288 out of range",
            "cam_ci=7 out of range",
            "gotoXXLatitude: '1e400' is not a usable number",
            "gotoXXLongitude: 'banana' is not a usable number",
        ):
            assert expect in log, f"missing heal line: {expect}"
        assert "feRetries=150 out of range" not in log, (
            "a hand-written value beyond the menu bounds was clamped"
        )
    finally:
        instance.stop()
