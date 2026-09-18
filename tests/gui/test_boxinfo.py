# Box-Info used to inspect every matching /proc/mounts entry synchronously
# before its first paint and again every five seconds. On a Generic-PC host a
# slow NFS mount parked the main thread in the kernel, leaving both the dialog
# and its Back key apparently dead.

import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from . import utils
from .neutrino_run import (
    NEUTRINO_DATA,
    IsolatedNeutrino,
    require_isolated_run,
    send_keys,
    settle,
)


def _seed_config(config: Path, recording_dir: str) -> None:
    zapit = config / "zapit"
    zapit.mkdir(parents=True, exist_ok=True)
    for name in ("services.xml", "bouquets.xml", "ubouquets.xml"):
        shutil.copy(NEUTRINO_DATA / "initial" / name, zapit / name)
    shutil.copy(NEUTRINO_DATA / "config" / "satellites.xml", config / "satellites.xml")
    (config / "neutrino.conf").write_text(
        "language=deutsch\n"
        f"network_nfs_recordingdir={recording_dir}\n"
    )


def _build_mount_blocker(tmp_path: Path) -> Path:
    compiler = shutil.which("cc")
    if compiler is None:
        pytest.skip("cc is required to build the Box-Info mount test helper")
    source = Path(__file__).with_name("boxinfo_mount_block.c")
    preload = tmp_path / "boxinfo_mount_block.so"
    subprocess.run(
        [compiler, "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", str(source), "-ldl", "-o", str(preload)],
        check=True,
        capture_output=True,
        text=True,
    )
    return preload


def _mount_test_env(tmp_path: Path) -> tuple[dict[str, str], Path, Path, Path]:
    mounts = tmp_path / "mounts"
    long_source = "source-" + "s" * 4100
    mounts.write_text(
        "overlay / overlay rw 0 0\n"
        f"{long_source} /tmp ext4 rw 0 0\n"
        "/dev/sda1 /var ext4 rw 0 0\n"
        "/dev/sdb1 /tmp/boxinfo-stalled ext4 rw 0 0\n"
        "/dev/sdc1 /tmp/boxinfo-stalled/hidden ext4 rw 0 0\n"
        "server:/recordings /tmp/boxinfo-stalled nfs4 rw,hard 0 0\n"
        "server:/archive /tmp/boxinfo-stalled/nfs nfs4 rw,hard 0 0\n"
        "sshfs#archive /tmp/boxinfo-stalled/fuse fuse.sshfs rw 0 0\n"
    )
    mounts_used = tmp_path / "mounts-used"
    armed = tmp_path / "armed"
    blocked = tmp_path / "blocked"
    env = {
        "LD_PRELOAD": str(_build_mount_blocker(tmp_path)),
        "NEUTRINO_TEST_MOUNTS": str(mounts),
        "NEUTRINO_TEST_MOUNTS_USED": str(mounts_used),
        "NEUTRINO_TEST_BLOCK_PREFIX": "/tmp/boxinfo-stalled",
        "NEUTRINO_TEST_BLOCK_ARMED": str(armed),
        "NEUTRINO_TEST_BLOCKED": str(blocked),
    }
    return env, mounts_used, armed, blocked


def _mount_reads(marker: Path) -> int:
    return len(marker.read_text().splitlines()) if marker.exists() else 0


def _wait_for_mount_read(marker: Path, previous: int, timeout: float) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = _mount_reads(marker)
        if current > previous:
            return current
        time.sleep(0.05)
    return _mount_reads(marker)


def _record_marker_score(screenshot: Path) -> float:
    utils.require_module("cv2")
    utils.require_module("numpy")
    import cv2  # pylint: disable=import-error,import-outside-toplevel
    import numpy  # pylint: disable=import-error,import-outside-toplevel

    icon = Path(__file__).resolve().parents[2] / "root/usr/share/tuxbox/neutrino/icons/marker_record_gray.png"
    image = cv2.imread(str(screenshot), cv2.IMREAD_COLOR)
    template = cv2.imread(str(icon), cv2.IMREAD_UNCHANGED)
    if image is None or template is None:
        pytest.fail("could not read Box-Info screenshot or recording marker")
    # Fully opaque pixels retain their exact RGB values when Neutrino paints
    # the icon. Including its antialiased alpha edge makes OpenCV's masked
    # normalization produce NaNs on flat regions of the screenshot.
    mask = (template[:, :, 3] == 255).astype("uint8") * 255
    scores = cv2.matchTemplate(image, template[:, :, :3], cv2.TM_CCORR_NORMED, mask=mask)
    finite_scores = scores[numpy.isfinite(scores)]
    if not finite_scores.size:
        pytest.fail("recording marker comparison produced no finite score")
    return float(finite_scores.max())


@pytest.mark.gui
@pytest.mark.parametrize(
    ("recording_dir", "expect_record_marker"),
    [
        ("/tmp/boxinfo-stalled/movie", False),
        ("/var/movie", True),
    ],
    ids=("remote-recording-mount", "local-recording-mount"),
)
def test_boxinfo_opens_and_back_remains_responsive(
    tmp_path: Path, owned_display, recording_dir: str, expect_record_marker: bool
) -> None:
    require_isolated_run()

    workdir = tmp_path / "boxinfo"
    _seed_config(workdir / "config", recording_dir)
    test_env, mounts_used, armed, blocked = _mount_test_env(tmp_path)

    # IsolatedNeutrino.stop() does not yet remove this FIFO (WORK-230). A stale
    # one would make the startup wait succeed before this process can read keys.
    Path(os.environ.get("NEUTRINO_INPUT_FIFO", "/tmp/neutrino.input")).unlink(missing_ok=True)
    instance = IsolatedNeutrino(
        workdir,
        owned_display.display,
        simulate_fe="1",
        extra_env=test_env,
    )
    try:
        assert instance.wait_for("[neutrino] initialized everything", timeout=60), (
            "Neutrino did not reach live mode"
        )
        time.sleep(3)

        # Dismiss a possible startup/playback hint, then use the same direct
        # keys as the user's Main menu -> Information -> Box-Info path.
        send_keys("BACK", settle_for=1)
        send_keys("MENU", settle_for=1)
        send_keys("INFO", settle_for=1)

        shot = tmp_path / "information.png"
        settle(shot, owned_display.display, windows=instance.windows())
        text = utils.ocr_image(shot)
        assert "Information" in text, f"information menu did not open: {text!r}"

        armed.touch()
        send_keys("GREEN")
        shot = tmp_path / "boxinfo.png"
        settle(shot, owned_display.display, tries=8, windows=instance.windows())
        text = utils.ocr_image(shot)
        assert "Box-Info" in text, f"Box-Info did not paint promptly: {text!r}"
        assert "tmp" in text.lower(), f"local /tmp mount was not shown: {text!r}"
        assert "var" in text.lower(), f"same-source /var mount was not shown: {text!r}"
        assert mounts_used.exists(), "mount-table preload was not exercised"
        assert not blocked.exists(), "Box-Info touched a synthetic stalled mount"
        marker_score = _record_marker_score(shot)
        if expect_record_marker:
            assert marker_score > 0.98, f"local recording mount marker missing (score {marker_score:.3f})"
        else:
            assert marker_score < 0.95, f"excluded recording mount was marked (score {marker_score:.3f})"

        # The dialog refreshes its filesystem data every five seconds. Keep it
        # open beyond that boundary and make it process another key before Back.
        first_read = _mount_reads(mounts_used)
        refreshed_read = _wait_for_mount_read(mounts_used, first_read, 7)
        assert refreshed_read > first_read, "five-second Box-Info refresh did not read the mount table"
        send_keys("INFO", settle_for=0.1)
        info_read = _wait_for_mount_read(mounts_used, refreshed_read, 2)
        assert info_read > refreshed_read, "Box-Info did not process INFO and repaint"
        shot = tmp_path / "refreshed.png"
        settle(shot, owned_display.display, tries=8, windows=instance.windows())
        text = utils.ocr_image(shot)
        assert "Box-Info" in text, f"Box-Info stopped responding after refresh: {text!r}"
        assert not blocked.exists(), "Box-Info refresh touched a synthetic stalled mount"

        send_keys("BACK")
        shot = tmp_path / "back.png"
        settle(shot, owned_display.display, tries=8, windows=instance.windows())
        text = utils.ocr_image(shot)
        assert "Information" in text, f"Back did not leave Box-Info: {text!r}"
    finally:
        instance.stop()
