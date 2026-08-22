# Emit remote control keys, either through Linux uinput/evdev or through
# Neutrino's own input FIFO.
#
# The two transports are not interchangeable. The generic (PC) build compiles
# the /dev/input scan out of rcinput and listens on /tmp/neutrino.input alone,
# so on that build uinput events are accepted by the kernel and never reach the
# application. Whenever the FIFO is there it therefore wins.

import errno
import os
import stat
import struct
import sys
import time
from typing import Iterable, List

try:
    from evdev import UInput, ecodes as e  # type: ignore
except ImportError:  # pragma: no cover - runtime skip
    UInput = None  # type: ignore
    e = None


UINPUT_DEVICE = "/dev/uinput"

DEFAULT_FIFO = "/tmp/neutrino.input"

KEYS = {
    "UP": "KEY_UP",
    "DOWN": "KEY_DOWN",
    "LEFT": "KEY_LEFT",
    "RIGHT": "KEY_RIGHT",
    "OK": "KEY_OK",
    "BACK": "KEY_BACK",
    "MENU": "KEY_MENU",
    "HOME": "KEY_HOME",
    "EXIT": "KEY_EXIT",
    "RED": "KEY_RED",
    "GREEN": "KEY_GREEN",
    "YELLOW": "KEY_YELLOW",
    "BLUE": "KEY_BLUE",
    # muting puts the mute icon on screen, and that arms CFrameBuffer's fbArea
    # mechanism - the one that paints over and restores the icon around foreign
    # paints. Tests that need that machinery active have no other way to switch
    # it on from outside.
    "MUTE": "KEY_MUTE",
    # menus print a digit next to each entry and jump straight to it. Counting
    # cursor steps instead is unreliable, because a menu reopens on whatever
    # was selected last time.
    "0": "KEY_0",
    "1": "KEY_1",
    "2": "KEY_2",
    "3": "KEY_3",
    "4": "KEY_4",
    "5": "KEY_5",
    "6": "KEY_6",
    "7": "KEY_7",
    "8": "KEY_8",
    "9": "KEY_9",
    # Letters and space, so a scenario can type text rather than only
    # navigate. Same short form as the digits: send "A", not "KEY_A".
    "Q": "KEY_Q",
    "W": "KEY_W",
    "E": "KEY_E",
    "R": "KEY_R",
    "T": "KEY_T",
    "Y": "KEY_Y",
    "U": "KEY_U",
    "I": "KEY_I",
    "O": "KEY_O",
    "P": "KEY_P",
    "A": "KEY_A",
    "S": "KEY_S",
    "D": "KEY_D",
    "F": "KEY_F",
    "G": "KEY_G",
    "H": "KEY_H",
    "J": "KEY_J",
    "K": "KEY_K",
    "L": "KEY_L",
    "Z": "KEY_Z",
    "X": "KEY_X",
    "C": "KEY_C",
    "V": "KEY_V",
    "B": "KEY_B",
    "N": "KEY_N",
    "M": "KEY_M",
    "SPACE": "KEY_SPACE",
}

# Numeric codes from linux/input-event-codes.h. Kept here rather than read from
# evdev because the FIFO transport has to work without that module installed.
KEY_CODES = {
    "KEY_1": 2,
    "KEY_2": 3,
    "KEY_3": 4,
    "KEY_4": 5,
    "KEY_5": 6,
    "KEY_6": 7,
    "KEY_7": 8,
    "KEY_8": 9,
    "KEY_9": 10,
    "KEY_0": 11,
    "KEY_HOME": 102,
    "KEY_UP": 103,
    "KEY_LEFT": 105,
    "KEY_RIGHT": 106,
    "KEY_DOWN": 108,
    "KEY_MENU": 139,
    "KEY_BACK": 158,
    "KEY_EXIT": 174,
    "KEY_OK": 352,
    "KEY_RED": 398,
    "KEY_GREEN": 399,
    "KEY_YELLOW": 400,
    "KEY_BLUE": 401,
    "KEY_MUTE": 113,
    # Letter keys, for the direct typing path. CRCInput::translate() passes
    # unknown codes through unchanged and CRCInput::getUnicodeValue() indexes
    # its table by the code, so these arrive as characters rather than as
    # remote control functions. Three separate ranges, not one:
    # Q-P is 16-25, A-L is 30-38, Z-M is 44-50.
    "KEY_Q": 16,
    "KEY_W": 17,
    "KEY_E": 18,
    "KEY_R": 19,
    "KEY_T": 20,
    "KEY_Y": 21,
    "KEY_U": 22,
    "KEY_I": 23,
    "KEY_O": 24,
    "KEY_P": 25,
    "KEY_A": 30,
    "KEY_S": 31,
    "KEY_D": 32,
    "KEY_F": 33,
    "KEY_G": 34,
    "KEY_H": 35,
    "KEY_J": 36,
    "KEY_K": 37,
    "KEY_L": 38,
    "KEY_Z": 44,
    "KEY_X": 45,
    "KEY_C": 46,
    "KEY_V": 47,
    "KEY_B": 48,
    "KEY_N": 49,
    "KEY_M": 50,
    "KEY_SPACE": 57,
}

# struct input_event: a struct timeval, then type, code and value. Native sizes
# and alignment, because the reader is the local build.
EVENT_FORMAT = "@llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
EV_SYN = 0x00
EV_KEY = 0x01
SYN_REPORT = 0x00

HOLD_SECONDS = 0.03
PAUSE_SECONDS = 0.05


def fifo_target() -> str:
    return os.environ.get("NEUTRINO_INPUT_FIFO", DEFAULT_FIFO)


def fifo_present() -> bool:
    """True when anything at all sits at the configured FIFO path.

    Deliberately not "is a FIFO", and lexists() rather than exists(): whatever
    is there - a stale FIFO, a regular file, a dangling symlink - the path was
    meant to be Neutrino's input, so replay_fifo() gets to say what is wrong
    with it. Handing those cases to uinput instead would write the keys where
    the generic build never reads them and leave the run looking successful.
    """
    return os.path.lexists(fifo_target())


def uinput_available() -> bool:
    if UInput is None or e is None:
        return False
    try:
        st = os.stat(UINPUT_DEVICE)
    except FileNotFoundError:
        return False
    if not stat.S_ISCHR(st.st_mode):
        return False
    # Fallback to FIFO if the device exists but is not writable (common without root/input group).
    return os.access(UINPUT_DEVICE, os.W_OK)


def encode_event(ev_type: int, code: int, value: int, when: float) -> bytes:
    """One input event, laid out the way the kernel hands it to a reader.

    The timestamp is not decoration: rcinput derives its repeat handling from
    it by subtracting gettimeofday() from the event time, so a zeroed field
    would look like an event from 1970.
    """
    seconds, micros = divmod(int(when * 1_000_000), 1_000_000)
    return struct.pack(EVENT_FORMAT, seconds, micros, ev_type, code, value)


def tap(ui: "UInput", code: int, hold: float = HOLD_SECONDS, pause: float = PAUSE_SECONDS) -> None:
    ui.write(e.EV_KEY, code, 1)
    ui.write(e.EV_SYN, e.SYN_REPORT, 0)
    time.sleep(hold)
    ui.write(e.EV_KEY, code, 0)
    ui.write(e.EV_SYN, e.SYN_REPORT, 0)
    time.sleep(pause)


def replay_uinput(keys: List[str]) -> None:
    if UInput is None or e is None:  # pragma: no cover - sanity guard
        raise SystemExit("python-evdev missing. Install via 'pip install evdev'.")
    with UInput() as ui:
        for key_name in keys:
            code = getattr(e, key_name)
            tap(ui, code)


def replay_fifo(keys: List[str]) -> None:
    fifo_path = fifo_target()
    if not os.path.exists(fifo_path):
        raise SystemExit(
            f"FIFO '{fifo_path}' not found. Ensure Neutrino is running (make run / run-now) or set NEUTRINO_INPUT_FIFO."
        )
    # A plain file at this path would accept every key without complaint and
    # nothing would reach Neutrino - the keys land in the file and the test
    # fails much later, at the screenshot, with a reason that says nothing
    # about the actual cause.
    if not stat.S_ISFIFO(os.stat(fifo_path).st_mode):
        raise SystemExit(
            f"'{fifo_path}' is not a FIFO. Point NEUTRINO_INPUT_FIFO at Neutrino's input FIFO."
        )
    # A FIFO outlives the process that read it, so an earlier Neutrino run
    # leaves the path in place. Opening it write-only would then block until
    # some reader shows up - which never happens, and the whole suite hangs
    # instead of skipping. Ask for a non-blocking open first: without a reader
    # that fails right away with ENXIO. Writing itself stays blocking, so a
    # reader that is merely slow still gets every key.
    try:
        fd = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as exc:
        # Only ENXIO means "nobody is reading". Anything else - out of
        # descriptors, no permission - is a real problem and has to surface as
        # one instead of being filed away as a missing Neutrino.
        if exc.errno != errno.ENXIO:
            raise
        raise SystemExit(
            f"FIFO '{fifo_path}' has no reader. Ensure Neutrino is running (make run) or set NEUTRINO_INPUT_FIFO."
        ) from exc
    os.set_blocking(fd, True)
    with os.fdopen(fd, "wb") as fifo:
        for key_name in keys:
            code = KEY_CODES[key_name]
            # Press and release each get their own SYN_REPORT. Neutrino skips
            # everything that is not EV_KEY, but keeping the stream shaped like
            # the device it imitates costs nothing and keeps it replayable
            # against evtest.
            fifo.write(encode_event(EV_KEY, code, 1, time.time()))
            fifo.write(encode_event(EV_SYN, SYN_REPORT, 0, time.time()))
            fifo.flush()
            time.sleep(HOLD_SECONDS)
            fifo.write(encode_event(EV_KEY, code, 0, time.time()))
            fifo.write(encode_event(EV_SYN, SYN_REPORT, 0, time.time()))
            fifo.flush()
            time.sleep(PAUSE_SECONDS)


def replay(keys: Iterable[str]) -> None:
    normalised: List[str] = []
    for name in keys:
        key = KEYS.get(name.upper())
        if key is None:
            raise ValueError(f"Unknown key: {name}")
        normalised.append(key)

    # The FIFO wins whenever it exists; uinput is for builds that read real
    # input devices. When neither is usable, replay_fifo() is also the one that
    # raises the message naming what is missing.
    if fifo_present() or not uinput_available():
        replay_fifo(normalised)
    else:
        replay_uinput(normalised)


if __name__ == "__main__":
    replay(sys.argv[1:] or ["MENU", "DOWN", "OK"])
