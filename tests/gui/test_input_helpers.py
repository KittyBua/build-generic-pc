# Unit tests for the key/screenshot helpers of the GUI suite.
#
# These guard the error classification, not the GUI: every case below decides
# whether a broken environment makes the suite skip or fail. Both directions
# matter equally - a missing piece has to skip, and a real defect must not be
# filed away as a missing piece.

import contextlib
import errno
import inspect
import os
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

import pytest

from . import send_keys, utils
from .send_keys import (
    EVENT_FORMAT,
    EVENT_SIZE,
    EV_KEY,
    KEY_CODES,
    KEYS,
    UINPUT_DEVICE,
    replay_fifo,
)


def decode_events(blob: bytes):
    """Split a raw FIFO stream into (when, type, code, value) tuples."""
    assert len(blob) % EVENT_SIZE == 0, f"{len(blob)} bytes is not a whole number of events"
    events = []
    for offset in range(0, len(blob), EVENT_SIZE):
        seconds, micros, ev_type, code, value = struct.unpack_from(EVENT_FORMAT, blob, offset)
        events.append((seconds + micros / 1_000_000, ev_type, code, value))
    return events


def drain(fifo_path: str, send) -> bytes:
    """Hold the read end open, run `send`, and return everything it wrote.

    A reader started alongside the writer would race its non-blocking open, and
    losing that race means ENXIO in the writer and a reader left waiting
    forever - the very hang this suite is supposed to rule out. O_NONBLOCK on
    the read end succeeds even with no writer, so this ordering always works.
    """
    read_fd = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        with fails_instead_of_hanging():
            send()
        os.set_blocking(read_fd, True)
        handle = os.fdopen(read_fd, "rb")
        read_fd = -1  # the file object owns it now
        with handle:
            return handle.read()
    finally:
        if read_fd != -1:
            os.close(read_fd)


@contextlib.contextmanager
def fails_instead_of_hanging(seconds: int = 5):
    """Turn a call that blocks into a failing test.

    These helpers exist so a missing reader cannot stall the suite. A test for
    them must not be able to produce that outcome itself: without this guard a
    regression in the non-blocking open would hang the run instead of failing
    it, and a hang says far less than a red test.
    """

    def blocked(signum, frame):
        raise AssertionError(f"call still had not returned after {seconds}s - it blocked")

    previous = signal.signal(signal.SIGALRM, blocked)
    started = time.monotonic()
    # alarm() returns what was left of an alarm already running - pytest-timeout
    # sets one, and dropping it would silently disarm the outer limit for the
    # rest of the test. Put the remainder back, minus the time spent here.
    outer_left = signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        if outer_left:
            rest = outer_left - (time.monotonic() - started)
            signal.alarm(max(1, int(rest)))


@pytest.fixture(name="fbgrab")
def fbgrab_fixture() -> None:
    # capture_framebuffer() checks for the binary before it looks at the
    # device, so without this every framebuffer test would trip over that skip
    # first and fail on its own message assertion instead of testing anything.
    # hosttools.mk treats a missing fbgrab as tolerable, so this is a state the
    # project expects to happen.
    if utils.shutil.which("fbgrab") is None:
        pytest.skip("fbgrab binary is required for this test")


@pytest.fixture(name="fifo")
def fifo_fixture(tmp_path: Path) -> str:
    path = tmp_path / "input.fifo"
    os.mkfifo(path)
    return str(path)


def test_missing_fifo_asks_for_neutrino(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", str(tmp_path / "nothing"))
    with pytest.raises(SystemExit) as exc:
        replay_fifo(["KEY_MENU"])
    assert "not found." in str(exc.value)


def test_a_plain_file_at_the_fifo_path_is_refused(tmp_path: Path, monkeypatch) -> None:
    # A regular file would swallow every key without complaint, and the run
    # would only fall over later at the screenshot - with a reason that says
    # nothing about where the keys went.
    plain = tmp_path / "not-a-fifo"
    plain.write_text("")
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", str(plain))
    with pytest.raises(SystemExit) as exc:
        replay_fifo(["KEY_MENU"])
    assert "is not a FIFO" in str(exc.value)
    assert plain.read_text() == ""  # and nothing was written into it


def test_readerless_fifo_skips_instead_of_blocking(fifo: str, monkeypatch) -> None:
    # The whole point of the non-blocking open: without this the call would
    # wait for a reader that never comes and hang the suite.
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", fifo)
    with fails_instead_of_hanging(), pytest.raises(SystemExit) as exc:
        replay_fifo(["KEY_MENU"])
    assert "has no reader" in str(exc.value)


def test_other_open_errors_are_not_filed_as_missing_reader(fifo: str, monkeypatch) -> None:
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", fifo)

    def refuse(path, flags, *args):
        raise PermissionError(errno.EACCES, "Permission denied")

    monkeypatch.setattr(os, "open", refuse)
    # Must surface as the permission problem it is, not as a skip reason.
    with pytest.raises(PermissionError):
        replay_fifo(["KEY_MENU"])


def test_keys_reach_a_live_reader(fifo: str, monkeypatch) -> None:
    # Neutrino reads this FIFO as a stream of binary input_event records
    # (rcinput.cpp) and skips anything that is not exactly one record long, so
    # asserting on the decoded events is the only check that proves a key was
    # actually delivered rather than merely written.
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", fifo)
    blob = drain(fifo, lambda: replay_fifo(["KEY_MENU", "KEY_DOWN", "KEY_OK"]))

    presses = [(code, value) for _, ev_type, code, value in decode_events(blob) if ev_type == EV_KEY]
    assert presses == [
        (KEY_CODES["KEY_MENU"], 1),
        (KEY_CODES["KEY_MENU"], 0),
        (KEY_CODES["KEY_DOWN"], 1),
        (KEY_CODES["KEY_DOWN"], 0),
        (KEY_CODES["KEY_OK"], 1),
        (KEY_CODES["KEY_OK"], 0),
    ]


def test_events_carry_a_current_timestamp(fifo: str, monkeypatch) -> None:
    # rcinput compensates its repeat handling by subtracting gettimeofday()
    # from the event time. A zeroed timeval - the obvious thing to pack when
    # nobody looks - would date every key to 1970 and skew that arithmetic.
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", fifo)
    before = time.time()
    blob = drain(fifo, lambda: replay_fifo(["KEY_OK"]))
    after = time.time()

    stamps = [when for when, _, _, _ in decode_events(blob)]
    assert stamps, "no events were written"
    assert all(before <= when <= after for when in stamps), stamps


def test_every_named_key_has_a_numeric_code() -> None:
    # The FIFO transport looks the code up by the evdev name KEYS maps to, so a
    # name added on one side only would fail deep inside the write loop, long
    # after the test that wanted the key.
    missing = sorted(set(KEYS.values()) - set(KEY_CODES))
    assert not missing, missing


def test_key_codes_match_evdev() -> None:
    # The table is hard-coded so the FIFO path works without python-evdev. That
    # makes it a second copy of the kernel's numbers, and a wrong entry would
    # quietly press a different button - ask evdev rather than trust the copy.
    evdev = pytest.importorskip("evdev")
    mismatches = {
        name: (code, getattr(evdev.ecodes, name, None))
        for name, code in KEY_CODES.items()
        if getattr(evdev.ecodes, name, None) != code
    }
    assert not mismatches, mismatches


def test_the_colour_keys_are_available() -> None:
    # Driving the theme chooser needs the coloured footer keys and a way out;
    # for a long time this map had neither, which made those paths untestable.
    for name in ("RED", "GREEN", "YELLOW", "BLUE", "HOME"):
        assert name in KEYS, name


def test_unknown_key_names_are_refused() -> None:
    with pytest.raises(ValueError) as exc:
        send_keys.replay(["POWER"])
    assert "POWER" in str(exc.value)


def test_a_live_fifo_wins_over_uinput(fifo: str, monkeypatch) -> None:
    # The trap this ordering exists for: the generic build compiles the
    # /dev/input scan out of rcinput, so keys written to uinput are accepted by
    # the kernel and dropped on the floor - a run that presses nothing and
    # still reports success.
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", fifo)
    monkeypatch.setattr(send_keys, "uinput_available", lambda: True)
    monkeypatch.setattr(
        send_keys,
        "replay_uinput",
        lambda keys: pytest.fail("uinput was used although the FIFO is live"),
    )
    blob = drain(fifo, lambda: send_keys.replay(["OK"]))

    codes = [code for _, ev_type, code, _ in decode_events(blob) if ev_type == EV_KEY]
    assert codes == [KEY_CODES["KEY_OK"], KEY_CODES["KEY_OK"]]


def test_a_plain_file_reaches_the_fifo_diagnostic(tmp_path: Path, monkeypatch) -> None:
    # replay_fifo() refuses a regular file by name, but only if the dispatch
    # sends it there. Deciding the transport on "is a FIFO" would route this
    # case to uinput, where the keys vanish without a word - the exact silent
    # drop the FIFO is preferred for.
    plain = tmp_path / "not-a-fifo"
    plain.write_text("")
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", str(plain))
    monkeypatch.setattr(send_keys, "uinput_available", lambda: True)
    monkeypatch.setattr(
        send_keys,
        "replay_uinput",
        lambda keys: pytest.fail("uinput swallowed the keys instead of naming the bad path"),
    )
    with pytest.raises(SystemExit) as exc:
        send_keys.replay(["OK"])
    assert "is not a FIFO" in str(exc.value)
    assert plain.read_text() == ""


def test_a_dangling_symlink_reaches_the_fifo_diagnostic(tmp_path: Path, monkeypatch) -> None:
    # Same class as the plain file, and the reason the check is lexists():
    # exists() follows the link, finds nothing and would hand the path to
    # uinput, where the keys disappear without naming the broken path.
    link = tmp_path / "gone.fifo"
    link.symlink_to(tmp_path / "no-such-target")
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", str(link))
    monkeypatch.setattr(send_keys, "uinput_available", lambda: True)
    monkeypatch.setattr(
        send_keys,
        "replay_uinput",
        lambda keys: pytest.fail("uinput swallowed the keys instead of naming the bad path"),
    )
    with pytest.raises(SystemExit) as exc:
        send_keys.replay(["OK"])
    assert "not found." in str(exc.value)


def test_without_a_fifo_uinput_is_still_used(tmp_path: Path, monkeypatch) -> None:
    # The other direction: on a build that does read real input devices the
    # FIFO is absent, and preferring it would turn every key into a skip.
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", str(tmp_path / "nothing"))
    monkeypatch.setattr(send_keys, "uinput_available", lambda: True)
    used: list = []
    monkeypatch.setattr(send_keys, "replay_uinput", used.append)
    send_keys.replay(["MENU"])
    assert used == [["KEY_MENU"]]


def test_missing_framebuffer_skips(fbgrab, tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("FRAMEBUFFER", str(tmp_path / "no-such-fb"))
    with pytest.raises(pytest.skip.Exception) as exc:
        utils.capture_framebuffer(tmp_path / "shot.png", delay=0)
    assert "no readable framebuffer" in str(exc.value)


def test_empty_framebuffer_variable_falls_back_like_fbgrab(fbgrab, tmp_path: Path, monkeypatch) -> None:
    # fbgrab resolves ${FRAMEBUFFER:-/dev/fb0}, so an empty value must name the
    # default device here as well instead of an empty path.
    monkeypatch.setenv("FRAMEBUFFER", "")
    try:
        utils.capture_framebuffer(tmp_path / "shot.png", delay=0)
    except pytest.skip.Exception as exc:
        assert "/dev/fb0" in str(exc)
    except subprocess.CalledProcessError:
        pass  # a real framebuffer exists and fbgrab ran - also fine


def test_readable_framebuffer_reaches_fbgrab(fbgrab, tmp_path: Path, monkeypatch) -> None:
    # /dev/null is readable but is not a framebuffer, so the guard has to let
    # the call through and fbgrab has to be the one that fails. Otherwise a
    # genuine capture failure would disappear as a skip.
    monkeypatch.setenv("FRAMEBUFFER", "/dev/null")
    with pytest.raises(subprocess.CalledProcessError):
        utils.capture_framebuffer(tmp_path / "shot.png", delay=0)


def test_a_broken_fifo_permission_is_not_filed_as_a_missing_uinput() -> None:
    # The exact trap: send_keys correctly lets EACCES through, but the caller
    # used to see "Permission denied" in the traceback and skip the test as if
    # uinput were missing. The real defect has to reach the test result.
    traceback = (
        "Traceback (most recent call last):\n"
        '  File "tests/gui/send_keys.py", line 79, in replay_fifo\n'
        "    fd = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)\n"
        "PermissionError: [Errno 13] Permission denied: '/tmp/neutrino.input'\n"
    )
    assert utils.send_keys_skip_reason(traceback) is None


def fifo_stderr(path, monkeypatch) -> str:
    """The stderr a failing replay_fifo() really produces for `path`.

    Spelling the expected sentence out here instead would pin the
    classification to a message the transport is free to reword: the marker
    would stop matching, every gap would turn into a hard failure, and this
    test would keep passing against its own copy of the old wording.
    """
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", str(path))
    with pytest.raises(SystemExit) as exc:
        replay_fifo(["KEY_OK"])
    return f"SystemExit: {exc.value}"


def gap_missing_fifo(tmp_path: Path, monkeypatch) -> str:
    return fifo_stderr(tmp_path / "nothing", monkeypatch)


def gap_readerless_fifo(tmp_path: Path, monkeypatch) -> str:
    path = tmp_path / "input.fifo"
    os.mkfifo(path)
    with fails_instead_of_hanging():
        return fifo_stderr(path, monkeypatch)


def gap_plain_file(tmp_path: Path, monkeypatch) -> str:
    plain = tmp_path / "not-a-fifo"
    plain.write_text("")
    return fifo_stderr(plain, monkeypatch)


def gap_unwritable_uinput(tmp_path: Path, monkeypatch) -> str:
    # Built from the constant the classification keys on rather than from a
    # hand-written path. Opening the real device to provoke evdev's own
    # sentence would create a virtual input device on a host where uinput *is*
    # writable, which is too much for one assertion; that half of the contract
    # is pinned by test_evdev_names_the_device_in_its_error instead.
    return f'UInputError: "{UINPUT_DEVICE}" cannot be opened for writing'


@pytest.mark.parametrize(
    "gap",
    [gap_missing_fifo, gap_readerless_fifo, gap_plain_file, gap_unwritable_uinput],
    ids=["fifo missing", "fifo without reader", "not a fifo", "uinput not writable"],
)
def test_environment_gaps_still_produce_a_skip(gap, tmp_path: Path, monkeypatch) -> None:
    # What the caller needs is that the gap is recognised at all - it then
    # skips. Asserting on the wording of the reason would pin a phrasing that
    # is nobody's contract. The opposite direction, that a real defect is *not*
    # recognised, is what test_a_broken_fifo_permission... covers.
    stderr_text = gap(tmp_path, monkeypatch)
    assert utils.send_keys_skip_reason(stderr_text) is not None, stderr_text


def test_uinput_constant_matches_the_device_evdev_opens() -> None:
    # send_keys_skip_reason() recognises a uinput problem by finding this path
    # in the child's stderr, so the constant has to be the device evdev really
    # uses - asked of evdev itself, not built from the constant under test.
    evdev = pytest.importorskip("evdev")
    default = inspect.signature(evdev.UInput.__init__).parameters["devnode"].default
    assert default == UINPUT_DEVICE


def test_evdev_names_the_device_in_its_error() -> None:
    # The other half of the same contract: recognising it by path only works
    # while evdev keeps putting the path into the message. Provoke a real error
    # instead of writing the expected text by hand.
    evdev = pytest.importorskip("evdev")
    bogus = "/dev/definitely-not-a-uinput-device"
    with pytest.raises(evdev.UInputError) as exc:
        evdev.UInput(devnode=bogus)
    assert bogus in str(exc.value)


def test_send_keys_module_runs_standalone() -> None:
    # test_menu.py starts it as a subprocess; an import error there would only
    # ever show up as a confusing CalledProcessError.
    result = subprocess.run(
        [sys.executable, "-c", "import tests.gui.send_keys"],
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr.decode(errors="ignore")
