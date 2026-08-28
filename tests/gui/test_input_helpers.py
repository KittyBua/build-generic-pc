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
import stat
import struct
import subprocess
import sys
import threading
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
        # The read is inside the guard too, not only the write. read() returns
        # at EOF, so it depends on every write descriptor being closed - true
        # today because write_events() owns the descriptor, and exactly the
        # kind of thing a later change breaks. A helper that exists to keep a
        # hang out of the suite must not be able to hang the suite itself.
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
def fails_instead_of_hanging(seconds: float = 5):
    """Turn a call that blocks into a failing test.

    These helpers exist so a missing reader cannot stall the suite. A test for
    them must not be able to produce that outcome itself: without this guard a
    regression in the non-blocking open would hang the run instead of failing
    it, and a hang says far less than a red test.
    """

    # ITIMER_REAL rather than alarm(): pytest-timeout arms this timer with a
    # fractional deadline, which alarm() rounds to whole seconds. The repeat
    # interval is carried through as well - pytest-timeout does not set one,
    # but this timer is process-wide and the next owner may.
    outer_left, outer_interval = signal.getitimer(signal.ITIMER_REAL)

    # Something stricter is already watching - stand aside entirely. Taking
    # over here is what made every earlier version of this helper complicated
    # and wrong in turn: it had to hand an expiry back to its owner, avoid
    # delivering it twice, and rearm itself afterwards, and it got each of
    # those wrong once. Not touching the timer has none of those failure modes,
    # and costs nothing: the outer deadline fails the test either way, with a
    # better diagnosis than this one-liner.
    if outer_left and outer_left <= seconds:
        yield
        return

    def blocked(signum, frame):
        raise AssertionError(f"call still had not returned after {seconds}s - it blocked")

    previous = signal.getsignal(signal.SIGALRM)
    started = time.monotonic()
    signal.signal(signal.SIGALRM, blocked)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        # Disarm before restoring, and restore even if disarming throws: a
        # handler left installed here would outlive the guard and fire into a
        # closure over a finished block.
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)
        finally:
            # getsignal() answers None for a handler installed from C, and then
            # neither option is good: leaving `blocked` in place fails an
            # unrelated part of the run for a call that returned long ago, and
            # SIG_DFL on SIGALRM terminates the process. So restore SIG_DFL and
            # leave the timer disarmed - the two must not be split. A lost
            # outer deadline is a weaker guard; an armed SIG_DFL is a dead
            # pytest with no report at all.
            signal.signal(signal.SIGALRM, previous if previous is not None else signal.SIG_DFL)
            if outer_left and previous is not None:
                # This branch only runs when the outer deadline was the later
                # one, so `rest` is positive in the ordinary case. The clamp is
                # for the exception: the guard raised, the body swallowed it,
                # and the outer deadline ran out in the meantime. setitimer(0)
                # would silently disarm it, so it fires straight away instead.
                rest = outer_left - (time.monotonic() - started)
                signal.setitimer(signal.ITIMER_REAL, max(rest, 1e-3), outer_interval)


@pytest.fixture(name="fbgrab")
def fbgrab_fixture() -> None:
    # For the cases that have to let fbgrab run: capture_framebuffer() checks
    # for the binary before it looks at the device, so without this they would
    # trip over that skip first and fail on their own message assertion instead
    # of testing anything. hosttools.mk treats a missing fbgrab as tolerable,
    # so this is a state the project expects to happen.
    if utils.shutil.which("fbgrab") is None:
        pytest.skip("fbgrab binary is required for this test")


@pytest.fixture(name="past_the_binary_check")
def past_the_binary_check_fixture(monkeypatch) -> None:
    """Reach the device classification without needing fbgrab installed.

    Requiring the real binary would take the classification test off every host
    that has no fbgrab - and that is a host the project accepts. The case below
    never reaches the binary anyway: it stops at the device check.
    """
    monkeypatch.setattr(utils, "require_binary", lambda name: None)


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
    assert plain.read_bytes() == b""  # and nothing was written into it


def test_readerless_fifo_skips_instead_of_blocking(fifo: str, monkeypatch) -> None:
    # The whole point of the non-blocking open: without this the call would
    # wait for a reader that never comes and hang the suite.
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", fifo)
    with fails_instead_of_hanging(), pytest.raises(SystemExit) as exc:
        replay_fifo(["KEY_MENU"])
    assert "has no reader" in str(exc.value)


def test_a_file_swapped_in_after_the_check_is_refused(tmp_path: Path, monkeypatch) -> None:
    # The path is inspected first and opened afterwards. A regular file accepts
    # a non-blocking write-only open without complaint, so if only the name is
    # trusted the keys go into a file nobody reads and the run falls over much
    # later, at the screenshot. Provoked by letting the first look report a
    # FIFO while the path really holds a plain file.
    plain = tmp_path / "swapped"
    plain.write_text("")
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", str(plain))

    real_stat = os.stat

    class LooksLikeAFifo:
        st_mode = stat.S_IFIFO | 0o600

    monkeypatch.setattr(
        os,
        "stat",
        lambda path, *a, **kw: LooksLikeAFifo() if str(path) == str(plain) else real_stat(path, *a, **kw),
    )

    with pytest.raises(SystemExit) as exc:
        replay_fifo(["KEY_OK"])
    assert "is not a FIFO" in str(exc.value)
    assert plain.read_bytes() == b""  # and nothing was written into it


def test_a_reader_that_leaves_mid_write_fails_and_is_named(fifo: str, monkeypatch) -> None:
    # Both halves matter here. A bare BrokenPipeError names nothing, so the
    # situation gets a sentence. But it must not become a skip: a reader that
    # was there at the open and left mid-write is a Neutrino that stopped -
    # possibly because of the key just sent - and reporting that as a missing
    # precondition would hide a GUI regression behind a green run.
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", fifo)
    read_fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)

    def close_once_the_writer_is_past_its_open() -> None:
        # Waiting for real bytes is what makes this deterministic: closing on a
        # timer could land before the open and provoke the ENXIO case instead,
        # which carries a similar message and would let this pass without ever
        # reaching the write path. A read on a FIFO nobody writes to yet
        # answers 0 straight away rather than blocking, so this has to keep
        # asking until an event actually arrives.
        try:
            os.set_blocking(read_fd, True)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if os.read(read_fd, EVENT_SIZE):
                    break
                time.sleep(0.005)
        finally:
            # Also on the way out of a raising read: the descriptor points into
            # tmp_path and would otherwise be held for the life of the process.
            os.close(read_fd)

    closer = threading.Thread(target=close_once_the_writer_is_past_its_open, daemon=True)
    closer.start()

    try:
        with fails_instead_of_hanging(30), pytest.raises(RuntimeError) as exc:
            replay_fifo(["KEY_OK"] * 40)
    finally:
        closer.join(timeout=25)
        # Recorded here, asserted below: an assert inside the finally would
        # replace whatever the body was really failing on.
        outlived = closer.is_alive()
    assert not outlived, "the closing thread outlived the test"
    assert "went away while keys were being sent" in str(exc.value)
    assert utils.send_keys_skip_reason(str(exc.value)) is None, "this must not turn into a skip"


def test_other_open_errors_are_not_filed_as_missing_reader(fifo: str, monkeypatch) -> None:
    monkeypatch.setenv("NEUTRINO_INPUT_FIFO", fifo)

    def refuse(path, flags, *args):
        raise PermissionError(errno.EACCES, "Permission denied")

    monkeypatch.setattr(os, "open", refuse)
    # Must surface as the permission problem it is, not as a skip reason.
    with pytest.raises(PermissionError) as exc:
        replay_fifo(["KEY_MENU"])
    # The other half of the same contract, which nothing joined up before: a
    # caller sees this as text on the child's stderr, and the classifier has to
    # leave it alone there too. Provoked from a real EACCES rather than from a
    # sentence written here.
    assert utils.send_keys_skip_reason(f"PermissionError: {exc.value}") is None


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


def test_missing_framebuffer_skips(past_the_binary_check, tmp_path: Path, monkeypatch) -> None:
    device = tmp_path / "no-such-fb"
    monkeypatch.setenv("FRAMEBUFFER", str(device))
    with pytest.raises(pytest.skip.Exception) as exc:
        utils.capture_framebuffer(tmp_path / "shot.png", delay=0)
    assert "no readable framebuffer" in str(exc.value)
    # Naming the device is what catches a helper that stopped reading
    # FRAMEBUFFER at all and always looks at the default.
    assert str(device) in str(exc.value), exc.value


def test_empty_framebuffer_variable_falls_back_like_fbgrab(past_the_binary_check, tmp_path: Path, monkeypatch) -> None:
    # fbgrab resolves ${FRAMEBUFFER:-/dev/fb0}, so an empty value must name the
    # default device here as well instead of an empty path.
    #
    # Asserted on the device that gets asked about, and the answer is forced to
    # "not readable" so the call always stops at the skip. Two earlier shapes
    # of this test sorted real outcomes into pass and fail and were wrong on a
    # host with a working framebuffer, then on one without fbgrab. There is no
    # outcome to sort here, nothing is executed, and no screenshot is taken as
    # a side effect of a unit test.
    monkeypatch.setenv("FRAMEBUFFER", "")
    asked_about: list = []
    monkeypatch.setattr(os, "access", lambda path, mode: asked_about.append(path) or False)
    with pytest.raises(pytest.skip.Exception):
        utils.capture_framebuffer(tmp_path / "shot.png", delay=0)
    assert asked_about == ["/dev/fb0"], asked_about


def test_readable_framebuffer_reaches_fbgrab(fbgrab, tmp_path: Path, monkeypatch) -> None:
    # /dev/null is readable but is not a framebuffer, so the guard has to let
    # the call through and fbgrab has to be the one that fails. Otherwise a
    # genuine capture failure would disappear as a skip.
    monkeypatch.setenv("FRAMEBUFFER", "/dev/null")
    # pytest.skip.Exception derives from BaseException, so pytest.raises() lets
    # it through and the test would report SKIPPED - green - in exactly the
    # case it exists to catch: a guard that skips instead of letting the
    # capture fail. Caught by hand for that reason.
    try:
        with pytest.raises(subprocess.CalledProcessError):
            utils.capture_framebuffer(tmp_path / "shot.png", delay=0)
    except pytest.skip.Exception as exc:
        pytest.fail(f"the guard skipped instead of letting fbgrab run: {exc}")


def a_failed_send_keys(stderr: str) -> subprocess.CalledProcessError:
    """A CalledProcessError shaped like the one the three GUI suites catch."""
    return subprocess.CalledProcessError(
        1, [sys.executable, "-m", "tests.gui.send_keys"], output=b"", stderr=stderr.encode()
    )


def test_a_missing_precondition_skips_the_caller(tmp_path: Path, monkeypatch) -> None:
    # fail_or_skip() is the one place that decides this for all three GUI
    # suites, and nothing exercised it: turning its pytest.fail into a
    # pytest.skip left the whole tree green, which is the fail-open this file
    # exists to rule out. Both directions are pinned here.
    stderr = gap_missing_fifo(tmp_path, monkeypatch)
    with pytest.raises(pytest.skip.Exception):
        utils.fail_or_skip(a_failed_send_keys(stderr))


def test_a_real_defect_fails_the_caller_and_carries_the_diagnosis() -> None:
    stderr = "PermissionError: [Errno 13] Permission denied: '/tmp/neutrino.input'\n"
    # The skip has to be caught by hand. pytest.skip's exception derives from
    # BaseException, so pytest.raises() lets it through and this test would
    # report SKIPPED - green - in exactly the case it exists to catch. Written
    # the obvious way first, and the mutation proved it: with fail_or_skip()
    # turned into a blanket skip the whole tree still passed.
    try:
        with pytest.raises(pytest.fail.Exception) as exc:
            utils.fail_or_skip(a_failed_send_keys(stderr))
    except pytest.skip.Exception as skipped:
        pytest.fail(f"a real defect was filed away as a missing precondition: {skipped}")
    # And the child's own words come along: a bare re-raise would report the
    # command and the exit status and drop this line.
    assert "Permission denied" in str(exc.value)


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


def test_the_uinput_marker_is_a_specific_device_path() -> None:
    # The classification searches stderr for this constant, so its *value* is
    # part of the contract, not just its presence. An empty string - or any
    # prefix short enough to appear in unrelated output - would make
    # send_keys_skip_reason() match everything and turn every real defect into
    # a skip. The two tests that ask evdev itself both need evdev installed;
    # this one holds on the host the hard-coded key table exists for.
    assert UINPUT_DEVICE.startswith("/dev/"), UINPUT_DEVICE
    assert len(UINPUT_DEVICE) > len("/dev/"), UINPUT_DEVICE
    assert utils.send_keys_skip_reason("nothing to do with input devices") is None


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


@contextlib.contextmanager
def an_outer_deadline(seconds: float, interval: float):
    """Stand in for pytest-timeout, and put back whatever was there before.

    Saving only the handler and cancelling the timer - the shape this test had
    first - would disarm the deadline pytest-timeout set for this very test.
    """
    fired: list = []
    previous_handler = signal.getsignal(signal.SIGALRM)
    outer_left, outer_interval = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()
    signal.signal(signal.SIGALRM, lambda *_: fired.append(True))
    signal.setitimer(signal.ITIMER_REAL, seconds, interval)
    try:
        yield fired
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        # Same None case as in the guard above, and the same coupling: no named
        # handler, no armed timer.
        signal.signal(signal.SIGALRM, previous_handler if previous_handler is not None else signal.SIG_DFL)
        if outer_left and previous_handler is not None:
            # The remaining time, not the value captured on entry - putting the
            # latter back would hand a real enclosing deadline more time than
            # it had, which is the mistake this stub is here to help catch.
            rest = outer_left - (time.monotonic() - started)
            signal.setitimer(signal.ITIMER_REAL, max(rest, 1e-3), outer_interval)


def test_the_guard_turns_a_blocking_call_into_a_failure(fifo: str) -> None:
    # The guard's own behaviour, which nothing checked: three tests and drain()
    # rely on it to turn a regression in the non-blocking open into a red test
    # instead of a hung run, and with the guard reduced to a no-op the whole
    # file still passed. A blocking open on a readerless FIFO is the real
    # thing, not a stand-in.
    #
    # The rescue reader is why a broken guard fails this test rather than
    # hanging the suite: it arrives late, unblocks the open, and pytest.raises
    # then reports that no AssertionError came.
    rescue = threading.Timer(3.0, lambda: os.close(os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)))
    rescue.start()
    try:
        with pytest.raises(AssertionError, match="it blocked"):
            with fails_instead_of_hanging(0.5):
                os.close(os.open(fifo, os.O_WRONLY))
    finally:
        rescue.cancel()
        rescue.join(timeout=5)
        assert not rescue.is_alive(), "the rescue reader outlived the test"


def test_the_guard_hands_an_outer_deadline_back_intact() -> None:
    # ITIMER_REAL carries a fractional deadline and a repeat interval; alarm()
    # can represent neither. The interval is what makes this assertion
    # independent of wall-clock timing - a busy machine changes how much of the
    # deadline is left, but never whether the interval survived. pytest-timeout
    # itself sets no interval, so this half stands for any other owner of a
    # process-wide timer, not for pytest-timeout.
    # The guard's own deadline has to be the shorter one, or it stands aside
    # and never touches the timer - which would make this assertion true
    # without any restoring code behind it.
    with an_outer_deadline(5.0, 2.5) as fired:
        with fails_instead_of_hanging(0.4):
            # Long enough that the remaining time and the value captured on
            # entry differ measurably. With an empty body the two are equal by
            # construction and the bound below accepts either, so putting the
            # entry value back would go unnoticed.
            time.sleep(0.3)
        left, interval = signal.getitimer(signal.ITIMER_REAL)
        assert interval == pytest.approx(2.5), f"repeat interval came back as {interval}"
        assert 0 < left <= 5.0 - 0.25, f"outer deadline came back as {left}s, not ~4.7s"
        assert not fired


def test_the_guard_lets_an_earlier_outer_deadline_win() -> None:
    # Restoring on the way out is not enough: while the guard is active its own
    # deadline must not postpone a shorter outer one. Arming for five seconds
    # here would let a --timeout=0.2 run sit for five, and the diagnosis would
    # come from the wrong owner.
    with an_outer_deadline(0.2, 0) as fired:
        with fails_instead_of_hanging(30):
            time.sleep(0.5)
            # Asserted inside the guard. A version that took the timer over
            # and only restored it on the way out would also let this fire
            # eventually, so checking afterwards would pass against exactly the
            # behaviour this test exists to rule out.
            assert fired, "the outer deadline did not fire while the guard was active"
    # And exactly once: standing aside must not add a second delivery on the
    # way out either.
    assert len(fired) == 1, f"the outer deadline was delivered {len(fired)} times"


def test_send_keys_module_runs_standalone() -> None:
    # test_menu.py starts it as a subprocess; an import error there would only
    # ever show up as a confusing CalledProcessError.
    result = subprocess.run(
        [sys.executable, "-c", "import tests.gui.send_keys"],
        capture_output=True,
        # -c prepends the *current* directory, so without this the test says
        # "send_keys is broken" whenever pytest happens to run from elsewhere.
        cwd=Path(__file__).resolve().parents[2],
    )
    assert result.returncode == 0, result.stderr.decode(errors="ignore")
