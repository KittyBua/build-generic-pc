"""Fixtures shared by the GUI tests.

owned_display used to live in test_tunerless_start.py and was imported by name
from other modules, which made an unrelated test file a dependency of anything
that needed a display. pytest looks fixtures up here on its own.

There is only this one display fixture. test_webtv_scripts.py and
test_screencap_api.py each held a private_display copy that deleted DISPLAY
first, to get around OwnedDisplay's preference for the caller's session --
the preference is gone, and so are the copies. Anything that wants a screen
takes owned_display, and it is always private.
"""

import pytest

from .neutrino_run import OwnedDisplay


@pytest.fixture
def owned_display():
    display = OwnedDisplay()
    try:
        yield display
    finally:
        display.close()
