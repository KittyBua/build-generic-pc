# WORK-268: the inactivity shutdown must still happen while a box is up.
#
# The inactivity sleep timer (Erweiterte Einstellungen -> Energieverbrauch)
# ends in a CMsgBox with a 60 second deadline; the shutdown happens only when
# that box runs into its timeout (neutrino.cpp, INACTIVITY SLEEPTIMER:
# skipShutdownTimer = !(msgbox & mbrTimeout)). Since 992782a149 the box hands
# application messages to CNeutrinoApp::handleMsg -- and restarted its whole
# deadline afterwards. In live TV the infoviewer keeps a repeating 60 second
# LCD timer armed, so its tick landed a few milliseconds before every restarted
# deadline and the box never timed out: the bar started over "shortly before
# it ran out", the machine stayed on (reported on an E4HDU, nightly of
# 2026-09-07).
#
# Oracle: /tmp/.standby, which standbyMode() creates and the constructor
# removes. Not a log line -- Neutrino's printf() output is block-buffered into
# the log and stop() kills the process, so [SHTDCNT] lines may never arrive.
#
# The run uses the simulated frontend (SIMULATE_FE=1, the `make run` default):
# without it, startup parks on the "no channels found" error box, which is
# raised from InitZapper() -- before SHTDCNT::init() starts the inactivity
# count at all -- and nothing under test ever runs. With the dummy frontend
# that box is skipped (CChannelList::showEmptyError) and the run settles in
# plain live mode with no channel, which is all the shutdown counter needs.
#
# Timing: shutdown_min=1 gives a 60 second inactivity count, which any key
# press restarts (rcinput.cpp, resetSleepTimer). One BACK once input is up is
# that key -- it also closes the settings hint if that is still showing, and
# does nothing in live mode without channels. The clock starts there: 60 s
# until the box opens, 60 s until it times out, standby right after. 150 s is
# the deadline; an unfixed build never gets there.

import os
import time
from pathlib import Path

import pytest

from .neutrino_run import (
    IsolatedNeutrino,
    require_isolated_run,
    require_no_frontend,
    send_keys,
)

STANDBY_MARKER = Path("/tmp/.standby")

EXPECTED_STANDBY_AFTER = 120.0
DEADLINE = 150.0


def _seed_config(config: Path) -> None:
    (config / "zapit").mkdir(parents=True, exist_ok=True)
    # language: without a loadable language the start wizard opens and the
    # run never reaches plain live TV. shutdown_min is only read when the
    # hardware reports can_shutdown, which libgeneric-pc does.
    (config / "neutrino.conf").write_text(
        "language=deutsch\n"
        "shutdown_min=1\n"
        "shutdown_count=0\n"
        "shutdown_real=false\n"
    )


@pytest.mark.gui
def test_inactivity_shutdown_reaches_standby_while_the_lcd_timer_ticks(
    tmp_path: Path, owned_display
) -> None:
    require_isolated_run()
    # The dummy frontend is only ever used when no real one is found; with a
    # tuner plugged in this run would zap for real and the premise changes.
    require_no_frontend()

    assert not STANDBY_MARKER.exists(), (
        f"{STANDBY_MARKER} exists although Neutrino removes it at startup"
    )

    workdir = tmp_path / "inactivity"
    (workdir / "config").mkdir(parents=True)
    _seed_config(workdir / "config")

    instance = IsolatedNeutrino(workdir, owned_display.display, simulate_fe="1")
    try:
        fifo = Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input"))
        deadline = time.monotonic() + 40
        while not fifo.exists() and time.monotonic() < deadline:
            assert instance.alive(), "Neutrino died during startup"
            time.sleep(0.5)
        assert fifo.exists(), "input FIFO never appeared"
        time.sleep(3)

        # The key press that restarts the inactivity count; the clock starts
        # here. Startup may still be finishing behind it, which is why the
        # bounds below leave room.
        send_keys("BACK")
        started = time.monotonic()

        while not STANDBY_MARKER.exists() and time.monotonic() - started < DEADLINE:
            assert instance.alive(), "Neutrino died while waiting for the inactivity shutdown"
            time.sleep(1.0)

        elapsed = time.monotonic() - started
        assert STANDBY_MARKER.exists(), (
            f"no standby after {elapsed:.0f} s: the inactivity box never timed out "
            "(its deadline is restarted by every application message, and the "
            "infoviewer's 60 s LCD timer wins that race each round)"
        )
        # Sanity bound: the count is 60 s and the box 60 s. Much less means the
        # box did not run its full deadline; that would be a different defect.
        assert elapsed > EXPECTED_STANDBY_AFTER - 15, (
            f"standby after only {elapsed:.0f} s; the box did not run its 60 s deadline"
        )
    finally:
        instance.stop()
        # Leave nothing behind for the next test that uses the marker.
        try:
            STANDBY_MARKER.unlink()
        except FileNotFoundError:
            pass
