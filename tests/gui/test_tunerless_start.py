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
import subprocess
import sys
import time
from pathlib import Path

import pytest

from . import utils
from .neutrino_run import (
    ROOT_DIR,
    IsolatedNeutrino,
    debug_logging_built_in,
    require_isolated_run,
    require_no_frontend,
    settle,
)









@pytest.fixture
def tunerless(tmp_path: Path, owned_display):
    require_isolated_run()
    require_no_frontend()
    instance = IsolatedNeutrino(tmp_path, owned_display.display)
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
    settle(shot, owned_display.display)
    _send("UP", "OK")
    settle(shot, owned_display.display)

    # Walk the wizard up to the tuner page the way a user does. The pages in
    # between (video, OSD, network) all end on a "next" forwarder.
    for _ in range(3):
        _send("OK")
        settle(shot, owned_display.display)
    _send("BACK")  # the network page's OK opened its interface submenu
    settle(shot, owned_display.display)

    text = utils.ocr_image(shot)
    assert "Tuner" in text, f"not on the tuner page: {text!r}"
    # feTimeout's default is 40, shown through the "%d00 ms" format as 4000 ms.
    # The bug showed an 11-digit number here.
    assert re.search(r"\b4000\b", text), f"tuner timeout is not the default: {text!r}"
    assert not re.search(r"\d{6,}", text), f"garbage value on the tuner page: {text!r}"

    # The key that used to segfault: leaving the tuner page runs saveScanSetup()
    # -> CZapit::SetConfig() -> SaveSettings().
    _send("OK")
    settle(shot, owned_display.display)
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
    require_isolated_run()
    require_no_frontend()
    # The evidence is WARN lines, which are empty macros without -DDEBUG
    # (src/zapit/debug.h): a --without-debug build heals fine but silently.
    if not debug_logging_built_in():
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
    instance = IsolatedNeutrino(workdir, owned_display.display, simulate_fe="1")
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
