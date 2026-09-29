import json
from functools import cache
import math
import os
import re
import struct
import subprocess
import stat
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "scripts" / "build-horizon-helper.sh"
HELPER = ROOT / ".local" / "development" / "BatchAutoStraighten.lrdevplugin" / "bin" / "horizon-helper"
FIXTURES = ROOT / "tests" / "fixtures" / "horizon"
TOLERANCE_DEG = 0.5


@cache
def _build() -> Path:
    env = os.environ.copy()
    proc = subprocess.run(
        ["bash", str(BUILD)],
        check=False,
        capture_output=True,
        text=True,
        cwd=str(ROOT),
        env=env,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    assert HELPER.is_file(), HELPER
    assert bool(HELPER.stat().st_mode & stat.S_IXUSR)
    return HELPER


def test_built_helper_targets_the_documented_macos_version():
    result = subprocess.run(['otool', '-l', str(_build())], check=True,
                            capture_output=True, text=True)
    assert re.search(r'\bminos\s+26\.0\b', result.stdout), result.stdout


def _require_absent(payload: dict) -> None:
    assert payload["kind"] == "none"
    assert payload["source"] == "camera_roll"
    assert payload["detail"] == "camera_metadata_unavailable"
    assert "vision_degrees" not in payload


def _run(helper: Path, image: Path, tmp_path: Path, photo_id: str = "t") -> dict:
    output = tmp_path / f"{photo_id}.json"
    proc = subprocess.run(
        [
            str(helper),
            "--id",
            photo_id,
            "--image",
            str(image),
            "--output",
            str(output),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert output.is_file(), proc.stderr or proc.stdout
    payload = json.loads(output.read_text(encoding="utf-8"))
    return payload


def _run_with_original(
    helper: Path,
    image: Path,
    original: Path,
    tmp_path: Path,
    photo_id: str,
) -> dict:
    output = tmp_path / f"{photo_id}.json"
    proc = subprocess.run(
        [
            str(helper),
            "--id",
            photo_id,
            "--image",
            str(image),
            "--original",
            str(original),
            "--output",
            str(output),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert output.is_file(), proc.stderr or proc.stdout
    return json.loads(output.read_text(encoding="utf-8"))


def _canon_level_values(encoded_roll_tenths: int) -> bytes:
    values = [0] * 10
    values[4] = encoded_roll_tenths
    return struct.pack("<10I", *values)


def _synthetic_canon_jpeg(encoded_roll_tenths: int) -> bytes:
    # Minimal Exif TIFF: IFD0 -> ExifIFD -> Canon MakerNote -> LevelInfo.
    tiff = bytearray(120)
    struct.pack_into("<2sHI", tiff, 0, b"II", 42, 8)
    struct.pack_into("<H", tiff, 8, 2)
    struct.pack_into("<HHII", tiff, 10, 0x010F, 2, 6, 38)
    struct.pack_into("<HHII", tiff, 22, 0x8769, 4, 1, 44)
    struct.pack_into("<I", tiff, 34, 0)
    tiff[38:44] = b"Canon\0"
    struct.pack_into("<H", tiff, 44, 1)
    struct.pack_into("<HHII", tiff, 46, 0x927C, 7, 58, 62)
    struct.pack_into("<I", tiff, 58, 0)
    struct.pack_into("<H", tiff, 62, 1)
    struct.pack_into("<HHII", tiff, 64, 0x4059, 4, 10, 80)
    struct.pack_into("<I", tiff, 76, 0)
    tiff[80:120] = _canon_level_values(encoded_roll_tenths)
    payload = b"Exif\0\0" + bytes(tiff)
    return b"\xff\xd8\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload + b"\xff\xd9"


def _synthetic_canon_cr3(encoded_roll_tenths: int) -> bytes:
    # Minimal CR3-compatible BMFF prefix with a CMT3 TIFF maker-note box.
    tiff = bytearray(66)
    struct.pack_into("<2sHI", tiff, 0, b"II", 42, 8)
    struct.pack_into("<H", tiff, 8, 1)
    struct.pack_into("<HHII", tiff, 10, 0x4059, 4, 10, 26)
    struct.pack_into("<I", tiff, 22, 0)
    tiff[26:66] = _canon_level_values(encoded_roll_tenths)
    ftyp = struct.pack(">I4s4sI4s", 20, b"ftyp", b"crx ", 1, b"isom")
    cmt3 = struct.pack(">I4s", len(tiff) + 8, b"CMT3") + bytes(tiff)
    return ftyp + cmt3


def _encrypt_nikon_shot_info(data: bytes, ci: int = 0xC1, cj: int = 0xA7) -> bytes:
    # serial "0" selects ci=0xc1 and shutter count 0 selects cj=0xa7.
    encrypted = bytearray(data)
    ck = 0x60
    for index in range(4, len(encrypted)):
        cj = (cj + ci * ck) & 0xFF
        ck = (ck + 1) & 0xFF
        encrypted[index] ^= cj
    return bytes(encrypted)


def _synthetic_nikon_tiff(
    roll_degrees: float,
    *,
    shot_version: bytes = b"0806",
    shutter_mode: int = 16,
) -> bytes:
    # Minimal TIFF: IFD0 -> ExifIFD -> Nikon type-2 MakerNote -> ShotInfo.
    assert len(shot_version) == 4
    shot = bytearray(0xB0)
    shot[:4] = shot_version
    struct.pack_into("<I", shot, 0x24, 24)  # offsets 0x28 through 0x84
    struct.pack_into("<I", shot, 0x84, 0xA0)
    encoded_roll = roll_degrees if roll_degrees >= 0 else roll_degrees + 360
    struct.pack_into("<I", shot, 0xA0, round(encoded_roll * 65536))
    shot = _encrypt_nikon_shot_info(shot)

    nested = bytearray(64 + len(shot))
    struct.pack_into("<2sHI", nested, 0, b"II", 42, 8)
    struct.pack_into("<H", nested, 8, 4)
    struct.pack_into("<HHI4s", nested, 10, 0x001D, 2, 2, b"0\0\0\0")
    struct.pack_into("<HHII", nested, 22, 0x0034, 3, 1, shutter_mode)
    struct.pack_into("<HHII", nested, 34, 0x0091, 7, len(shot), 64)
    struct.pack_into("<HHII", nested, 46, 0x00A7, 4, 1, 0)
    struct.pack_into("<I", nested, 58, 0)
    nested[64:] = shot
    maker = b"Nikon\0\x02\x11\0\0" + bytes(nested)

    make = b"NIKON CORPORATION\0"
    model = b"NIKON Z 8\0"
    make_offset = 56
    model_offset = make_offset + len(make)
    exif_offset = model_offset + len(model)
    maker_offset = exif_offset + 18
    tiff = bytearray(maker_offset + len(maker))
    struct.pack_into("<2sHI", tiff, 0, b"II", 42, 8)
    struct.pack_into("<H", tiff, 8, 3)
    struct.pack_into("<HHII", tiff, 10, 0x010F, 2, len(make), make_offset)
    struct.pack_into("<HHII", tiff, 22, 0x0110, 2, len(model), model_offset)
    struct.pack_into("<HHII", tiff, 34, 0x8769, 4, 1, exif_offset)
    struct.pack_into("<I", tiff, 46, 0)
    tiff[make_offset : make_offset + len(make)] = make
    tiff[model_offset : model_offset + len(model)] = model
    struct.pack_into("<H", tiff, exif_offset, 1)
    struct.pack_into(
        "<HHII", tiff, exif_offset + 2, 0x927C, 7, len(maker), maker_offset
    )
    struct.pack_into("<I", tiff, exif_offset + 14, 0)
    tiff[maker_offset:] = maker
    return bytes(tiff)


def _synthetic_nikon_jpeg(*args, **kwargs) -> bytes:
    payload = b"Exif\0\0" + _synthetic_nikon_tiff(*args, **kwargs)
    return b"\xff\xd8\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload + b"\xff\xd9"


def _synthetic_ricoh_tiff(
    roll_degrees: float,
    *,
    model: bytes = b"RICOH GR IV\0",
    dng_private: bool = False,
) -> bytes:
    # Minimal TIFF: IFD0 -> ExifIFD -> RICOH/Pentax MakerNote -> LevelInfo.
    encoded_roll = round(-roll_degrees * 2)
    assert -128 <= encoded_roll <= 127
    level = bytearray(19)
    struct.pack_into("<b", level, 1, encoded_roll)

    maker = bytearray(26 + len(level))
    maker[:8] = b"RICOH\0II"
    struct.pack_into("<H", maker, 8, 1)
    struct.pack_into("<HHII", maker, 10, 0x022B, 7, len(level), 26)
    struct.pack_into("<I", maker, 22, 0)
    maker[26:] = level

    make = b"RICOH IMAGING COMPANY, LTD.\0"
    make_offset = 56
    model_offset = make_offset + len(make)
    exif_offset = model_offset + len(model)
    maker_offset = exif_offset + 18
    tiff = bytearray(maker_offset + len(maker))
    struct.pack_into("<2sHI", tiff, 0, b"II", 42, 8)
    struct.pack_into("<H", tiff, 8, 3)
    struct.pack_into("<HHII", tiff, 10, 0x010F, 2, len(make), make_offset)
    struct.pack_into("<HHII", tiff, 22, 0x0110, 2, len(model), model_offset)
    if dng_private:
        struct.pack_into("<HHII", tiff, 34, 0xC634, 1, len(maker), maker_offset)
    else:
        struct.pack_into("<HHII", tiff, 34, 0x8769, 4, 1, exif_offset)
    struct.pack_into("<I", tiff, 46, 0)
    tiff[make_offset : make_offset + len(make)] = make
    tiff[model_offset : model_offset + len(model)] = model
    if not dng_private:
        struct.pack_into("<H", tiff, exif_offset, 1)
        struct.pack_into(
            "<HHII", tiff, exif_offset + 2, 0x927C, 7, len(maker), maker_offset
        )
        struct.pack_into("<I", tiff, exif_offset + 14, 0)
    tiff[maker_offset:] = maker
    return bytes(tiff)


def _synthetic_ricoh_jpeg(*args, **kwargs) -> bytes:
    payload = b"Exif\0\0" + _synthetic_ricoh_tiff(*args, **kwargs)
    return b"\xff\xd8\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload + b"\xff\xd9"


def _synthetic_maker_tiff(
    make: bytes,
    model: bytes,
    maker_builder,
    *,
    signature: bytes = b"II*\0",
    dng_private: bool = False,
) -> bytes:
    assert len(signature) == 4
    make_offset = 56
    model_offset = make_offset + len(make)
    exif_offset = model_offset + len(model)
    maker_offset = exif_offset + (0 if dng_private else 18)
    maker = maker_builder(maker_offset)
    tiff = bytearray(maker_offset + len(maker))
    tiff[:4] = signature
    struct.pack_into("<I", tiff, 4, 8)
    struct.pack_into("<H", tiff, 8, 3)
    struct.pack_into("<HHII", tiff, 10, 0x010F, 2, len(make), make_offset)
    struct.pack_into("<HHII", tiff, 22, 0x0110, 2, len(model), model_offset)
    if dng_private:
        struct.pack_into("<HHII", tiff, 34, 0xC634, 1, len(maker), maker_offset)
    else:
        struct.pack_into("<HHII", tiff, 34, 0x8769, 4, 1, exif_offset)
        struct.pack_into("<H", tiff, exif_offset, 1)
        struct.pack_into(
            "<HHII", tiff, exif_offset + 2, 0x927C, 7, len(maker), maker_offset
        )
        struct.pack_into("<I", tiff, exif_offset + 14, 0)
    struct.pack_into("<I", tiff, 46, 0)
    tiff[make_offset : make_offset + len(make)] = make
    tiff[model_offset : model_offset + len(model)] = model
    tiff[maker_offset:] = maker
    return bytes(tiff)


def _as_jpeg(tiff: bytes) -> bytes:
    payload = b"Exif\0\0" + tiff
    return b"\xff\xd8\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload + b"\xff\xd9"


def _synthetic_apple_tiff(
    roll_degrees: float,
    *,
    orientation: int = 1,
    screen_projection: float = 0.98,
) -> bytes:
    orientation_correction = {1: 0.0, 3: 180.0, 6: 90.0, 8: -90.0}[
        orientation
    ]
    raw_angle = math.radians(roll_degrees - orientation_correction)
    x = -screen_projection * math.cos(raw_angle)
    y = screen_projection * math.sin(raw_angle)
    z = math.sqrt(max(0.0, 1.0 - screen_projection * screen_projection))

    maker = bytearray(56)
    maker[:14] = b"Apple iOS\0\0\1MM"
    struct.pack_into(">H", maker, 14, 1)
    struct.pack_into(">HHII", maker, 16, 0x0008, 10, 3, 32)
    struct.pack_into(">I", maker, 28, 0)
    for index, value in enumerate((x, y, z)):
        struct.pack_into(">ii", maker, 32 + index * 8, round(value * 1_000_000), 1_000_000)

    make = b"Apple\0"
    model = b"iPhone 15 Pro\0"
    make_offset = 64
    model_offset = make_offset + len(make)
    exif_offset = model_offset + len(model)
    maker_offset = exif_offset + 18
    tiff = bytearray(maker_offset + len(maker))
    struct.pack_into("<2sHI", tiff, 0, b"II", 42, 8)
    struct.pack_into("<H", tiff, 8, 4)
    struct.pack_into("<HHII", tiff, 10, 0x010F, 2, len(make), make_offset)
    struct.pack_into("<HHII", tiff, 22, 0x0110, 2, len(model), model_offset)
    struct.pack_into("<HHI", tiff, 34, 0x0112, 3, 1)
    struct.pack_into("<H", tiff, 42, orientation)
    struct.pack_into("<HHII", tiff, 46, 0x8769, 4, 1, exif_offset)
    struct.pack_into("<I", tiff, 58, 0)
    tiff[make_offset : make_offset + len(make)] = make
    tiff[model_offset : model_offset + len(model)] = model
    struct.pack_into("<H", tiff, exif_offset, 1)
    struct.pack_into(
        "<HHII", tiff, exif_offset + 2, 0x927C, 7, len(maker), maker_offset
    )
    struct.pack_into("<I", tiff, exif_offset + 14, 0)
    tiff[maker_offset:] = maker
    return bytes(tiff)


def _synthetic_panasonic_tiff(
    roll_degrees: float,
    *,
    rw2: bool = False,
    leica: bool = False,
) -> bytes:
    def maker_builder(_maker_offset: int) -> bytes:
        header = b"LEICA\0\0\0" if leica else b"Panasonic\0\0\0"
        ifd_offset = len(header)
        maker = bytearray(ifd_offset + 18)
        maker[:ifd_offset] = header
        struct.pack_into("<H", maker, ifd_offset, 1)
        struct.pack_into(
            "<HHIhxx",
            maker,
            ifd_offset + 2,
            0x0090,
            3,
            1,
            round(roll_degrees * 10),
        )
        struct.pack_into("<I", maker, ifd_offset + 14, 0)
        return bytes(maker)

    return _synthetic_maker_tiff(
        b"LEICA CAMERA AG\0" if leica else b"Panasonic\0",
        b"LEICA Q3\0" if leica else b"DC-G9\0",
        maker_builder,
        signature=b"IIU\0" if rw2 else b"II*\0",
    )


def _synthetic_olympus_tiff(
    roll_degrees: float,
    *,
    orf: bool = False,
    valid: int = 1,
) -> bytes:
    def maker_builder(_maker_offset: int) -> bytes:
        maker = bytearray(50)
        maker[:12] = b"OLYMPUS\0II\x03\0"
        struct.pack_into("<H", maker, 12, 1)
        struct.pack_into("<HHII", maker, 14, 0x2020, 13, 1, 32)
        struct.pack_into("<I", maker, 26, 0)
        struct.pack_into("<H", maker, 32, 1)
        struct.pack_into(
            "<HHIhh",
            maker,
            34,
            0x0903,
            8,
            2,
            round(-roll_degrees * 10),
            valid,
        )
        struct.pack_into("<I", maker, 46, 0)
        return bytes(maker)

    return _synthetic_maker_tiff(
        b"OLYMPUS CORPORATION\0",
        b"E-M1MarkIII\0",
        maker_builder,
        signature=b"IIRO" if orf else b"II*\0",
    )


def _synthetic_fuji_tiff(roll_degrees: float) -> bytes:
    def maker_builder(_maker_offset: int) -> bytes:
        maker = bytearray(38)
        maker[:8] = b"FUJIFILM"
        struct.pack_into("<I", maker, 8, 12)
        struct.pack_into("<H", maker, 12, 1)
        struct.pack_into("<HHII", maker, 14, 0x144D, 10, 1, 30)
        struct.pack_into("<I", maker, 26, 0)
        struct.pack_into("<ii", maker, 30, round(roll_degrees * 10), 10)
        return bytes(maker)

    return _synthetic_maker_tiff(
        b"FUJIFILM\0", b"X-T5\0", maker_builder
    )


def _synthetic_fuji_raf(roll_degrees: float) -> bytes:
    jpeg = _as_jpeg(_synthetic_fuji_tiff(roll_degrees))
    header = bytearray(0x94)
    header[:16] = b"FUJIFILMCCD-RAW"
    struct.pack_into(">II", header, 0x54, len(header), len(jpeg))
    return bytes(header) + jpeg


def _synthetic_pentax_tiff(
    roll_degrees: float,
    *,
    dng_private: bool,
    k3iii: bool = False,
    make: bytes | None = None,
) -> bytes:
    model = b"PENTAX K-3 Mark III\0" if k3iii else b"PENTAX K-5\0"

    def maker_builder(maker_offset: int) -> bytes:
        level = bytearray(19)
        if k3iii:
            struct.pack_into(">h", level, 3, round(-roll_degrees * 2))
        else:
            struct.pack_into("b", level, 1, round(-roll_degrees * 2))
        if dng_private:
            maker = bytearray(30 + len(level))
            maker[:10] = b"PENTAX \0MM"
            struct.pack_into(">H", maker, 10, 1)
            struct.pack_into(">HHII", maker, 12, 0x022B, 7, len(level), 30)
            struct.pack_into(">I", maker, 24, 0)
            maker[30:] = level
        else:
            maker = bytearray(24 + len(level))
            maker[:6] = b"AOC\0MM"
            struct.pack_into(">H", maker, 6, 1)
            struct.pack_into(
                ">HHII", maker, 8, 0x022B, 7, len(level), maker_offset + 24
            )
            struct.pack_into(">I", maker, 20, 0)
            maker[24:] = level
        return bytes(maker)

    return _synthetic_maker_tiff(
        make or (b"RICOH IMAGING COMPANY, LTD.\0" if k3iii else b"PENTAX Corporation\0"),
        model,
        maker_builder,
        dng_private=dng_private,
    )


def test_images_without_metadata_do_not_infer_horizons(tmp_path: Path):
    helper = _build()
    for name in ("horizon-3.png", "horizon--3.png", "horizon-8.png", "horizon--8.png"):
        payload = _run(helper, FIXTURES / name, tmp_path, name)
        assert payload["id"] == name
        _require_absent(payload)


def test_blank_is_none_or_error_not_a_large_angle(tmp_path: Path):
    helper = _build()
    payload = _run(helper, FIXTURES / "blank.png", tmp_path, "blank")
    assert payload["kind"] in {"none", "error"}


def test_metadata_absence_does_not_require_decoding_preview(tmp_path: Path):
    helper = _build()
    for name in ("junk.bin", "missing.png"):
        if name == "junk.bin":
            (tmp_path / name).write_bytes(b"not-an-image")
        _require_absent(_run(helper, tmp_path / name, tmp_path, name))


def test_usage_nonzero_without_output(tmp_path: Path):
    helper = _build()
    proc = subprocess.run([str(helper)], check=False, capture_output=True, text=True)
    assert proc.returncode != 0
    assert "usage:" in proc.stderr


def test_runtime_metadata_reader_has_no_external_process_dependency():
    source = (ROOT / "src" / "native" / "HorizonHelper.swift").read_text(encoding="utf-8")
    source += (ROOT / "src" / "native" / "CameraRoll.swift").read_text(encoding="utf-8")
    assert "Process(" not in source
    assert "exiftool" not in source.lower()


def test_original_without_roll_reports_absent_metadata(tmp_path: Path):
    helper = _build()
    payload = _run(helper, FIXTURES / "horizon-3.png", tmp_path, "orig")
    _require_absent(payload)
    output = tmp_path / "with-original.json"
    proc = subprocess.run(
        [
            str(helper),
            "--id",
            "orig",
            "--image",
            str(FIXTURES / "horizon-3.png"),
            "--original",
            str(FIXTURES / "horizon-3.png"),
            "--output",
            str(output),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert output.is_file(), proc.stderr or proc.stdout
    payload = json.loads(output.read_text(encoding="utf-8"))
    assert payload["schema"] == "batch-auto-straighten.horizon.v2"
    _require_absent(payload)


@pytest.mark.parametrize(
    ("suffix", "contents", "expected"),
    [
        ("jpg", _synthetic_canon_jpeg(7), -0.7),
        ("cr3", _synthetic_canon_cr3(3595), 0.5),
    ],
)
def test_reads_canon_roll_without_external_tool(
    tmp_path: Path,
    suffix: str,
    contents: bytes,
    expected: float,
):
    helper = _build()
    original = tmp_path / f"original.{suffix}"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        f"canon-{suffix}",
    )
    assert payload["kind"] == "horizon"
    assert payload["source"] == "camera_roll"
    assert payload["make"] == "Canon"
    assert float(payload["roll_degrees"]) == pytest.approx(expected)


@pytest.mark.parametrize(
    ("suffix", "contents"),
    [
        ("jpg", _synthetic_nikon_jpeg(-0.575)),
        ("nef", _synthetic_nikon_tiff(-0.575)),
    ],
)
def test_reads_nikon_z_roll_without_external_tool(
    tmp_path: Path,
    suffix: str,
    contents: bytes,
):
    helper = _build()
    original = tmp_path / f"original.{suffix}"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        f"nikon-{suffix}",
    )
    assert payload["kind"] == "horizon"
    assert payload["source"] == "camera_roll"
    assert payload["make"] == "Nikon"
    assert float(payload["roll_degrees"]) == pytest.approx(-0.575, abs=2e-5)


@pytest.mark.parametrize(
    ("suffix", "contents", "expected"),
    [
        ("jpg", _synthetic_ricoh_jpeg(-1.5), -1.5),
        (
            "dng",
            _synthetic_ricoh_tiff(
                2.0, model=b"RICOH GR IIIx\0", dng_private=True
            ),
            2.0,
        ),
    ],
)
def test_reads_ricoh_gr_roll_without_external_tool(
    tmp_path: Path,
    suffix: str,
    contents: bytes,
    expected: float,
):
    helper = _build()
    original = tmp_path / f"original.{suffix}"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        f"ricoh-{suffix}",
    )
    assert payload["kind"] == "horizon"
    assert payload["source"] == "camera_roll"
    assert payload["make"] == "Ricoh"
    assert float(payload["roll_degrees"]) == pytest.approx(expected)


@pytest.mark.parametrize(
    ("suffix", "contents", "expected_make"),
    [
        ("jpg", _as_jpeg(_synthetic_panasonic_tiff(-1.7)), "Panasonic"),
        ("rw2", _synthetic_panasonic_tiff(-1.7, rw2=True), "Panasonic"),
        (
            "jpg",
            _as_jpeg(_synthetic_panasonic_tiff(-1.7, leica=True)),
            "Leica",
        ),
    ],
)
def test_reads_panasonic_roll_without_external_tool(
    tmp_path: Path,
    suffix: str,
    contents: bytes,
    expected_make: str,
):
    helper = _build()
    original = tmp_path / f"original.{suffix}"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        f"panasonic-{suffix}",
    )
    assert payload["kind"] == "horizon"
    assert payload["source"] == "camera_roll"
    assert payload["make"] == expected_make
    assert float(payload["roll_degrees"]) == pytest.approx(-1.7)


@pytest.mark.parametrize(
    ("suffix", "contents"),
    [
        ("jpg", _as_jpeg(_synthetic_olympus_tiff(-0.4))),
        ("orf", _synthetic_olympus_tiff(-0.4, orf=True)),
    ],
)
def test_reads_olympus_roll_without_external_tool(
    tmp_path: Path,
    suffix: str,
    contents: bytes,
):
    helper = _build()
    original = tmp_path / f"original.{suffix}"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        f"olympus-{suffix}",
    )
    assert payload["kind"] == "horizon"
    assert payload["source"] == "camera_roll"
    assert payload["make"] == "Olympus"
    assert float(payload["roll_degrees"]) == pytest.approx(-0.4)


@pytest.mark.parametrize(
    ("suffix", "contents"),
    [
        ("jpg", _as_jpeg(_synthetic_fuji_tiff(2.5))),
        ("raf", _synthetic_fuji_raf(2.5)),
    ],
)
def test_reads_fuji_roll_without_external_tool(
    tmp_path: Path,
    suffix: str,
    contents: bytes,
):
    helper = _build()
    original = tmp_path / f"original.{suffix}"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        f"fuji-{suffix}",
    )
    assert payload["kind"] == "horizon"
    assert payload["source"] == "camera_roll"
    assert payload["make"] == "Fujifilm"
    assert float(payload["roll_degrees"]) == pytest.approx(2.5)


@pytest.mark.parametrize(
    ("suffix", "contents", "expected"),
    [
        ("jpg", _as_jpeg(_synthetic_pentax_tiff(1.5, dng_private=False)), 1.5),
        ("dng", _synthetic_pentax_tiff(-2.0, dng_private=True), -2.0),
        (
            "dng",
            _synthetic_pentax_tiff(2.5, dng_private=True, k3iii=True),
            2.5,
        ),
    ],
)
def test_reads_pentax_roll_without_external_tool(
    tmp_path: Path,
    suffix: str,
    contents: bytes,
    expected: float,
):
    helper = _build()
    original = tmp_path / f"original-{expected}.{suffix}"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        f"pentax-{suffix}-{expected}",
    )
    assert payload["kind"] == "horizon"
    assert payload["source"] == "camera_roll"
    assert payload["make"] == "Pentax"
    assert float(payload["roll_degrees"]) == pytest.approx(expected)


@pytest.mark.parametrize(
    ("orientation", "expected"),
    [
        (1, 5.5),
        (3, -2.25),
        (6, 3.75),
        (8, -4.5),
    ],
)
def test_reads_apple_acceleration_without_external_tool(
    tmp_path: Path,
    orientation: int,
    expected: float,
):
    helper = _build()
    original = tmp_path / f"iphone-{orientation}.dng"
    original.write_bytes(_synthetic_apple_tiff(expected, orientation=orientation))
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        f"apple-{orientation}",
    )
    assert payload["kind"] == "horizon"
    assert payload["source"] == "camera_roll"
    assert payload["make"] == "Apple"
    assert float(payload["roll_degrees"]) == pytest.approx(expected, abs=1e-4)


@pytest.mark.parametrize(
    ("roll_degrees", "screen_projection"),
    [(2.0, 0.1), (46.0, 0.98)],
)
def test_unsafe_apple_acceleration_reports_absent_metadata(
    tmp_path: Path,
    roll_degrees: float,
    screen_projection: float,
):
    helper = _build()
    original = tmp_path / "iphone-flat.dng"
    original.write_bytes(
        _synthetic_apple_tiff(
            roll_degrees,
            orientation=1,
            screen_projection=screen_projection,
        )
    )
    payload = _run_with_original(
        helper,
        tmp_path / "missing-preview.png",
        original,
        tmp_path,
        "apple-flat",
    )
    _require_absent(payload)


@pytest.mark.parametrize(
    "contents",
    [
        _synthetic_olympus_tiff(1.0, orf=True, valid=0),
        _as_jpeg(_synthetic_fuji_tiff(0.0)),
    ],
)
def test_missing_vendor_roll_reports_absent_metadata(
    tmp_path: Path,
    contents: bytes,
):
    helper = _build()
    original = tmp_path / "missing-roll.bin"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        "missing-vendor-roll",
    )
    _require_absent(payload)
    _require_absent(payload)


@pytest.mark.parametrize(
    "contents",
    [
        _synthetic_nikon_jpeg(0.5, shot_version=b"0812"),
        _synthetic_nikon_jpeg(0.5, shutter_mode=96),
    ],
)
def test_unsupported_nikon_metadata_reports_absent_metadata(
    tmp_path: Path,
    contents: bytes,
):
    helper = _build()
    original = tmp_path / "unsupported-nikon.jpg"
    original.write_bytes(contents)
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        "unsupported-nikon",
    )
    _require_absent(payload)
    _require_absent(payload)


def test_unsupported_ricoh_model_reports_absent_metadata(tmp_path: Path):
    helper = _build()
    original = tmp_path / "unsupported-ricoh.jpg"
    original.write_bytes(_synthetic_ricoh_jpeg(-1.5, model=b"GR DIGITAL 2\0"))
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        "unsupported-ricoh",
    )
    _require_absent(payload)
    _require_absent(payload)


def test_malformed_canon_metadata_reports_absent_metadata(tmp_path: Path):
    helper = _build()
    original = tmp_path / "truncated.jpg"
    original.write_bytes(_synthetic_canon_jpeg(7)[:-35])
    payload = _run_with_original(
        helper,
        FIXTURES / "horizon-3.png",
        original,
        tmp_path,
        "truncated",
    )
    _require_absent(payload)
    _require_absent(payload)


def test_output_cannot_overwrite_preview_or_original(tmp_path):
    helper = _build()
    image = tmp_path / 'image.png'
    original = tmp_path / 'original.jpg'
    image.write_bytes(b'input bytes must remain unchanged')
    original.write_bytes(_synthetic_canon_jpeg(7))
    before = {p: p.read_bytes() for p in (image, original)}
    symlink = tmp_path / 'linked.png'
    symlink.symlink_to(image)
    hardlink = tmp_path / 'hardlinked.png'
    os.link(image, hardlink)
    for output in (image, original, symlink, hardlink):
        for extra in ([], ['--preview-degrees', '2']):
            proc = subprocess.run([str(helper), '--id', 'guard', '--image', str(image),
                                   '--original', str(original), '--output', str(output), *extra],
                                  capture_output=True, text=True, timeout=20)
            assert proc.returncode == 2
            assert 'must not overwrite' in proc.stderr
            for path, data in before.items():
                assert path.read_bytes() == data


@pytest.mark.parametrize("angle", [-2.5, 0, 2.5])
@pytest.mark.parametrize("suffix", ["jpg", "pef", "dng"])
def test_ricoh_pentax_k3iii_formats(tmp_path, angle, suffix):
    contents = _synthetic_pentax_tiff(angle, dng_private=suffix == "dng", k3iii=True)
    if suffix == "jpg":
        contents = _as_jpeg(contents)
    test_reads_pentax_roll_without_external_tool(tmp_path, suffix, contents, angle)


@pytest.mark.parametrize("invalid", ["model", "header"])
def test_ricoh_pentax_rejects_unknown_format(tmp_path, invalid):
    contents = _synthetic_pentax_tiff(2.5, dng_private=True, k3iii=True)
    if invalid == "model":
        contents = contents.replace(b"PENTAX K-3 Mark III", b"UNKNOWN CAMERA    ")
    else:
        contents = contents.replace(b"PENTAX \0MM", b"BROKEN \0MM")
    original = tmp_path / "invalid.dng"
    original.write_bytes(contents)
    _require_absent(_run_with_original(_build(), FIXTURES / "horizon-3.png", original, tmp_path, "invalid"))


@pytest.mark.parametrize('field,value', [('count', 5), ('count', 18), ('count', 37),
                                         ('type', 2), ('offset', 40), ('offset', 121)])
def test_canon_declared_maker_bounds(tmp_path, field, value):
    data = bytearray(_synthetic_canon_jpeg(7))
    # JPEG APP1 wrapper plus Exif signature precedes TIFF by 12 bytes.
    if field == 'count':
        struct.pack_into('<I', data, 12 + 50, value)
    elif field == 'type':
        struct.pack_into('<H', data, 12 + 48, value)
    else:
        struct.pack_into('<I', data, 12 + 72, value)
    original = tmp_path / 'invalid.jpg'
    original.write_bytes(data)
    payload = _run_with_original(_build(), FIXTURES / 'horizon-3.png', original, tmp_path, 'bounds')
    _require_absent(payload)
