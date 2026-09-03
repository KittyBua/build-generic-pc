# WORK-228: a message box must not swallow what does not belong to it.
#
# CMsgBox::exec() ends in an if/else-if chain whose first branch tests whether
# the footer has a selected button. Every box with buttons has one, so the
# branches behind it -- among them the one handing the message to
# CNeutrinoApp::handleMsg -- have been unreachable since 2022 (783f09d3fb).
# While a box is up, a recording timer that fires does not start, standby does
# nothing, and the payload of every message that carries one is leaked.
#
# The box under test here is the one Neutrino itself raises on a machine
# without a tuner (DisplayInfoMessage, LOCALE_ZAPIT_NO_TUNER). It is modal, it
# has a single OK button, and it sits in the startup sequence just before
# "menue setup" reaches the log -- which makes that line a precise oracle for
# "the box is gone and startup continued". It resolves DEFAULT_TIMEOUT to the
# static-message timing, 60 seconds by default, so every deadline below stays
# well under that: a test that waited longer would pass on unfixed code for the
# wrong reason, namely the box timing out on its own.
#
# The run is isolated like the other GUI tests: a private mount namespace puts
# a throwaway config over the compile-time CONFIGDIR, so the developer's own
# configuration is neither read nor written.

import os
import time
from pathlib import Path

import pytest

from .neutrino_run import (
    IsolatedNeutrino,
    debug_logging_built_in,
    require_isolated_run,
    require_no_frontend,
    send_keys,
)

# The startup line that only appears once the modal box is gone.
STARTUP_CONTINUED = "menue setup"

# standbyMode() creates this on the way into standby; the constructor removes
# it at startup. A file rather than a log line on purpose: Neutrino's INFO()
# output goes to stdout and is block-buffered into the log file, so it can lag
# far behind reality. dprintf() goes to stderr and arrives promptly, which is
# why STARTUP_CONTINUED above is usable and an INFO line would not be.
STANDBY_MARKER = Path("/tmp/.standby")


@pytest.fixture
def box_on_screen(tmp_path: Path, owned_display):
    """A run parked on the no-tuner box, with startup not yet continued."""
    require_isolated_run()
    require_no_frontend()
    # "found 0 frontends" is an INFO(), which is an empty macro without
    # -DDEBUG. Asserting on it in a --without-debug build would fail red for a
    # reason that has nothing to do with this change.
    if not debug_logging_built_in():
        pytest.skip("zapit INFO logging compiled out (--without-debug)")

    instance = IsolatedNeutrino(tmp_path, owned_display.display)
    try:
        assert instance.wait_for("found 0 frontends"), "expected a run without any frontend"
        # "found 0 frontends" prints before the dummy-frontend block, so on its
        # own it cannot tell "no frontend" from "simulated frontend" -- and with
        # a dummy the box never appears.
        assert "SIMULATE_FE is set" not in instance.log.read_text(errors="replace"), (
            "a dummy frontend appeared; SIMULATE_FE=0 did not reach Neutrino"
        )

        # The box takes input only once rcinput is up, which the FIFO shows.
        fifo = Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input"))
        deadline = time.monotonic() + 40
        while not fifo.exists() and time.monotonic() < deadline:
            assert instance.alive(), "Neutrino died during startup"
            time.sleep(0.5)
        assert fifo.exists(), "input FIFO never appeared"
        time.sleep(3)

        # Without this the tests below would be vacuous: if startup had already
        # moved on, every key would be answered by whatever runs now, not by
        # the box.
        assert STARTUP_CONTINUED not in instance.log.read_text(errors="replace"), (
            "startup passed the modal box before the test could use it"
        )
        yield instance
    finally:
        instance.stop()


@pytest.mark.gui
def test_back_closes_a_box_that_has_no_back_button(box_on_screen) -> None:
    """Back must end a box even when no button is bound to it.

    This box shows OK alone. Before the fix the key reached neither a button
    nor the general cancel branch behind the unreachable else, so it was
    dropped and the box stayed up for its full timeout.
    """
    send_keys("BACK")
    assert box_on_screen.wait_for(STARTUP_CONTINUED, timeout=20), (
        "Back did not close the box; startup was still parked on it"
    )


@pytest.mark.gui
def test_the_power_key_is_handed_on_not_swallowed(box_on_screen) -> None:
    """Standby must survive an open box.

    Two things have to happen: the box has to let go, and the key has to reach
    the application. Asserting only the first would pass on a fix that closes
    the box and drops the key.
    """
    # A marker left over from an earlier run would make the second assertion
    # meaningless. Neutrino removes it at startup, so it must be gone by now.
    assert not STANDBY_MARKER.exists(), (
        f"{STANDBY_MARKER} exists although Neutrino removes it at startup"
    )

    send_keys("POWER")

    assert box_on_screen.wait_for(STARTUP_CONTINUED, timeout=20), (
        "the power key did not end the box"
    )

    deadline = time.monotonic() + 60
    while not STANDBY_MARKER.exists() and time.monotonic() < deadline:
        assert box_on_screen.alive(), "Neutrino died on the power key"
        time.sleep(0.5)
    assert STANDBY_MARKER.exists(), (
        "the box let go of the power key but standby was never entered: "
        "the key was dropped instead of handed on"
    )


@pytest.mark.gui
def test_a_key_without_a_button_does_not_close_the_box(box_on_screen) -> None:
    """A key the box has no button for must not end it.

    The guard against overshooting. CHintBox reposts what it cannot use and
    leaves its loop, which is right for a hint and wrong for a question: a
    confirmation dialog that closes on a stray key would answer for the user.
    This test passes both before and after the change and pins that.
    """
    send_keys("BLUE")
    assert not box_on_screen.wait_for(STARTUP_CONTINUED, timeout=8), (
        "an unrelated key closed the box"
    )
    assert box_on_screen.alive(), "Neutrino died on an unrelated key"

    # ...and the box is still working, rather than merely still on screen.
    send_keys("OK")
    assert box_on_screen.wait_for(STARTUP_CONTINUED, timeout=20), (
        "the box stopped responding to its own button"
    )
