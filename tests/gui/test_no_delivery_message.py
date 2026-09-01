# WORK-226: a tuner that could receive the channel but sits at FE_MODE_UNUSED
# must be named, not merely implied.
#
# Reported from a real AppImage session on a TBS5580: the satellite frontend
# was switched off, the DVB-T/C one was not, and Neutrino said "no active tuner
# supports this channel delivery system". Correct, and unusable -- it named
# neither the reception path nor the tuner that was one menu entry away from
# working. The message now names both and offers the way there.
#
# The run is isolated the same way test_tunerless_start.py isolates its own:
# a private mount namespace puts a throwaway config over the compile-time
# CONFIGDIR, so nothing here reads or writes the developer's configuration.

import glob
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

from . import utils
from .neutrino_run import (
    NEUTRINO_DATA,
    ROOT_DIR,
    IsolatedNeutrino,
    debug_logging_built_in,
    require_isolated_run,
    settle,
)


def _satellite_frontend_last() -> bool:
    """True when frontend 0 cannot do satellite and a later one can.

    That is the shape this test needs: an enabled frontend that cannot carry
    the channel, and a disabled one that could. Deriving it from the driver
    rather than assuming it keeps the test honest on other hardware -- a stick
    whose frontend 0 is the satellite one would silently exercise a different
    reason and prove nothing.
    """
    frontends = sorted(glob.glob("/dev/dvb/adapter0/frontend*"))
    if len(frontends) < 2:
        return False
    kinds = []
    for path in frontends:
        number = path.rsplit("frontend", 1)[-1]
        probe = subprocess.run(["dvb-fe-tool", "-a", "0", "-f", number],
                               capture_output=True, text=True)
        # The device name carries its delivery systems ("... DVB-S/S2/S2X").
        # dvb-fe-tool localises its labels but not the name it read from the
        # driver.
        kinds.append("DVB-S" in probe.stdout)
    return not kinds[0] and any(kinds[1:])


def _require_misconfigurable_tuner() -> None:
    require_isolated_run()
    utils.require_binary("dvb-fe-tool")
    utils.require_binary("xwininfo")
    # "found N frontends" below is an INFO(), and INFO is an empty macro
    # without -DDEBUG (src/zapit/debug.h). Asserting on it in a --without-debug
    # build would fail red for a reason that has nothing to do with the change.
    if not debug_logging_built_in():
        pytest.skip("zapit INFO logging compiled out (--without-debug)")
    if not _satellite_frontend_last():
        pytest.skip("needs a tuner whose satellite frontend is not frontend 0")


def _seed_config(config: Path) -> None:
    """Build a config that reaches a real zap attempt.

    Everything comes from the repo's own shipped data, not from the
    developer's configuration: a test that copied the latter would pass or fail
    depending on what somebody last scanned. The channel list is the one the
    start wizard installs, so it is exactly what a fresh installation zaps to.
    """
    zapit = config / "zapit"
    zapit.mkdir(parents=True, exist_ok=True)

    for name in ("services.xml", "bouquets.xml", "ubouquets.xml"):
        shutil.copy(NEUTRINO_DATA / "initial" / name, zapit / name)
    shutil.copy(NEUTRINO_DATA / "config" / "satellites.xml", config / "satellites.xml")

    # Without a loadable language the start wizard opens instead of the zap
    # (neutrino.cpp, NO_SUCH_LOCALE), and then nothing under test ever runs.
    (config / "neutrino.conf").write_text("language=deutsch\n")

    # The defect state: the frontend that can do satellite is switched off,
    # the one that cannot is the only enabled one.
    (zapit / "frontend.conf").write_text(
        "fe0_0_mode=1\n"                 # FE_MODE_INDEPENDENT, the non-satellite one
        "fe0_0_satellites=\n"
        "fe0_1_mode=0\n"                 # FE_MODE_UNUSED, the satellite one
        "fe0_1_satellites=192\n"
        "fe0_1_position_192=192,-1,-1,-1,0,0,9750,10600,11700,0,0,1\n"
    )


def _send(*keys: str) -> None:
    try:
        subprocess.run(
            [sys.executable, "-m", "tests.gui.send_keys", *keys],
            check=True,
            capture_output=True,
            cwd=ROOT_DIR,
        )
    except subprocess.CalledProcessError as exc:
        utils.fail_or_skip(exc)


@pytest.mark.gui
def test_disabled_tuner_is_named_and_reachable(tmp_path: Path, owned_display) -> None:
    _require_misconfigurable_tuner()

    workdir = tmp_path / "misconfigured"
    (workdir / "config").mkdir(parents=True)
    _seed_config(workdir / "config")

    instance = IsolatedNeutrino(workdir, owned_display.display)
    try:
        # The premise has to hold before anything is asserted about the
        # message: two real frontends, and a zap that could not get one.
        assert instance.wait_for("found 2 frontends"), "expected a run with both frontends"
        assert instance.wait_for("Cannot get frontend", timeout=60), (
            "the zap succeeded; the config did not reproduce the defect"
        )

        fifo = Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input"))
        deadline = time.monotonic() + 60
        while not fifo.exists() and time.monotonic() < deadline:
            assert instance.alive(), "Neutrino died during startup"
            time.sleep(0.5)
        assert fifo.exists(), "input FIFO never appeared"

        # A key press to reach the dialog. The box on screen is the startup
        # one -- the failing zap at startup does raise it -- so this mostly
        # serves to get past whatever the run settled on and to prove the
        # dialog takes input at all.
        _send("UP")
        time.sleep(5)

        shot = tmp_path / "message.png"
        utils.capture_x11(shot, display=owned_display.display, windows=instance.windows())
        text = utils.ocr_image(shot)

        # The three things the message did not say before. Whole words only --
        # tesseract reads "[B]" and "02:" unreliably, so the tuner label is
        # checked by its stable parts rather than in full.
        # "Tuner" alone would not do: the old message already ended in "please
        # check the tuner configuration". These three words exist only in the
        # sentences this change added.
        assert "Satellit" in text, f"reception path not named: {text!r}"
        assert "braucht" in text, f"the channel's requirement is not stated: {text!r}"
        assert "genutzt" in text, f"the disabled tuner's mode is not quoted: {text!r}"

        # ...and the way out. Pressing it used to segfault: exec() enters the
        # message loop without painting, and the first key scrolled a text box
        # that did not exist.
        # Wait for the screen to change, not for a guessed number of seconds.
        # Measured here, the setup menu is painted about 4.4 s after the key --
        # a fixed sleep(4) failed roughly half the runs, and make test-gui
        # stops at the first failure, so one flaky test takes the suite with
        # it. Waiting on Neutrino's own log line does not work either: its
        # stdout is block-buffered into the log file and the line arrives long
        # after the menu does.
        _send("OK")

        # Poll for the menu rather than photographing once after a guessed
        # delay. Two things make a single shot unreliable: the setup is painted
        # about 4.4 s after the key, and the channel keeps being re-zapped, so
        # a fresh failure box can cover the menu for a moment -- correctly, the
        # re-entry guard turns it into a plain hint. Neither is a defect, and
        # neither should decide whether this test passes. Waiting on Neutrino's
        # log line does not work: its stdout is block-buffered into the log
        # file and arrives long after the menu does.
        #
        # "Timeout" is the menu entry "Tuning Timeout", not an expired one --
        # either it or the mode column proves the frontend setup is up.
        menu = ""
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            settle(shot, owned_display.display, windows=instance.windows())
            menu = utils.ocr_image(shot)
            if "Independent" in menu or "Timeout" in menu:
                break
            time.sleep(0.5)

        assert instance.alive(), "Neutrino died on the tuner setup button"
        assert "Independent" in menu or "Timeout" in menu, (
            f"the button did not open the tuner setup: {menu!r}"
        )
    finally:
        instance.stop()
