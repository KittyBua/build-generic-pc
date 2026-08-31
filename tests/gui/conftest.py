"""Fixtures shared by the GUI tests.

owned_display used to live in test_tunerless_start.py and was imported by name
from other modules, which made an unrelated test file a dependency of anything
that needed a display. pytest looks fixtures up here on its own.
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
