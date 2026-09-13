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
