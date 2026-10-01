import os
import struct
import zlib
from pathlib import Path

import pytest

from bdzbridge.recorder.logo import LOGO_CLUT, decode_logo_file, encode_logo_file, with_palette


def _chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def make_png(index: int = 7, width: int = 64, height: int = 36) -> bytes:
    """A palette PNG without PLTE, the way the recorder stores logos: every pixel is `index`."""
    rows = b"".join(b"\x00" + bytes([index]) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(rows)) + _chunk(b"IEND", b""))


def chunks(png: bytes) -> list[tuple[str, int]]:
    out, pos = [], 8
    while pos < len(png):
        ln, kind = struct.unpack(">I4s", png[pos:pos + 8])
        out.append((kind.decode(), ln))
        pos += 12 + ln
    return out


def test_roundtrip_and_palette():
    raw = encode_logo_file([(11, 1024, make_png()), (12, 1025, bytes(1152)), (21, 1032, make_png(1))])
    logos = decode_logo_file(raw)
    assert [(lg.channel_no, lg.service_id) for lg in logos] == [(11, 1024), (21, 1032)]
    png = logos[0].png
    assert [k for k, _ in chunks(png)] == ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"]
    assert dict(chunks(png))["PLTE"] == 3 * len(LOGO_CLUT) and dict(chunks(png))["tRNS"] == len(LOGO_CLUT)
    assert with_palette(png) == png  # idempotent
    trns = png[png.index(b"tRNS") + 4:]
    assert trns[7] == 255 and trns[8] == 0  # white opaque, index 8 transparent


def test_clut_is_the_common_fixed_colour_table():
    """ARIB STD-B24 Vol.2 Part 2 App.2 Table 5-7, which TR-B15 App.1 makes the logos' table: every colour of
    the 4-level cube once (index 8 is the transparent one), then all but black-transparent again at alpha 128.
    That would be 129 entries; the standard drops (255, 255, 170, 128) to keep it at 128."""
    levels = (0, 85, 170, 255)
    cube = [(r, g, b) for r in levels for g in levels for b in levels]
    assert len(LOGO_CLUT) == 128
    opaque = LOGO_CLUT[:65]
    assert opaque[8] == (0, 0, 0, 0)
    assert all(a == 255 for i, (_r, _g, _b, a) in enumerate(opaque) if i != 8)
    rgb = [(r, g, b) for i, (r, g, b, _a) in enumerate(opaque) if i != 8]
    assert sorted(rgb) == sorted(cube)  # each colour of the cube exactly once
    # 0-7 and 9-15 are the eight caption colours at full and two-thirds level, 16-64 the rest of the cube in order
    assert rgb[16 - 1:] == [c for c in cube if c not in rgb[:16 - 1]]
    assert LOGO_CLUT[65:] == tuple((r, g, b, 128) for i, (r, g, b, _a) in enumerate(opaque[:64]) if i != 8)
    assert LOGO_CLUT[54] == (255, 0, 170, 255)
    assert LOGO_CLUT[64] == (255, 255, 170, 255)
    assert LOGO_CLUT[118] == (255, 0, 170, 128)


def test_pale_yellow_pixels_are_not_drawn_white():
    png = decode_logo_file(encode_logo_file([(11, 1024, make_png(64))]))[0].png
    plte = png[png.index(b"PLTE") + 4:]
    assert tuple(plte[3 * 64:3 * 64 + 3]) == (255, 255, 170)
    assert tuple(plte[3 * 54:3 * 54 + 3]) == (255, 0, 170)


def test_rejects_non_png():
    with pytest.raises(ValueError):
        with_palette(b"not a png")


@pytest.mark.skipif(not os.environ.get("BDZBRIDGE_TEST_LOGO_FILE"), reason="set BDZBRIDGE_TEST_LOGO_FILE to a real logo file")
def test_real_file():
    logos = decode_logo_file(Path(os.environ["BDZBRIDGE_TEST_LOGO_FILE"]).read_bytes())
    assert logos
    for lg in logos:
        w, h = struct.unpack(">II", lg.png[16:24])
        assert (w, h) == (64, 36) and lg.service_id > 0 and lg.channel_no > 0
