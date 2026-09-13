"""Decoder (and test encoder) for the station-logo files served next to the EPG files.

Format (as served by a BDZ-FBT4100; see docs/epg-format.md):
  raw file  = XOR 0x9D over concatenated zlib streams (same wrapping as the EPG files).
  stream 0  = 8-byte file header (a timestamp).
  stream n  = one service: 20-byte record header, then the payload.
      u32 record length (header + payload)
      u8  broadcaster index for the first service of a broadcaster, 0xFF for the rest; u8 0xFF
      u32 channel number: top byte 0 = BS, 1 = terrestrial, 2 = CS; low 24 bits the 3-digit number (011, 101, ...)
      u32 0
      u16 service_id
      u32 payload length
      payload: a 64x36 palette PNG without a PLTE chunk, or 1152 zero bytes when no logo was received.
The PNGs rely on the common fixed colour table of the broadcast standard, which is inserted here so that
ordinary image viewers can render them.
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass

from .epg import split_streams

_XOR = 0x9D
_PNG_SIG = b"\x89PNG\r\n\x1a\n"
_HEADER = ">IBBIIHI"  # 20 bytes
_HEADER_LEN = struct.calcsize(_HEADER)

# Common fixed colour table for station logos (RGBA). Opaque entries first, then the same colours at half alpha.
LOGO_CLUT = (
    (0, 0, 0, 255), (255, 0, 0, 255), (0, 255, 0, 255), (255, 255, 0, 255),
    (0, 0, 255, 255), (255, 0, 255, 255), (0, 255, 255, 255), (255, 255, 255, 255),
    (0, 0, 0, 0), (170, 0, 0, 255), (0, 170, 0, 255), (170, 170, 0, 255),
    (0, 0, 170, 255), (170, 0, 170, 255), (0, 170, 170, 255), (170, 170, 170, 255),
    (0, 0, 85, 255), (0, 85, 0, 255), (0, 85, 85, 255), (0, 85, 170, 255),
    (0, 85, 255, 255), (0, 170, 85, 255), (0, 170, 255, 255), (0, 255, 85, 255),
    (0, 255, 170, 255), (85, 0, 0, 255), (85, 0, 85, 255), (85, 0, 170, 255),
    (85, 0, 255, 255), (85, 85, 0, 255), (85, 85, 85, 255), (85, 85, 170, 255),
    (85, 85, 255, 255), (85, 170, 0, 255), (85, 170, 85, 255), (85, 170, 170, 255),
    (85, 170, 255, 255), (85, 255, 0, 255), (85, 255, 85, 255), (85, 255, 170, 255),
    (85, 255, 255, 255), (170, 0, 85, 255), (170, 0, 255, 255), (170, 85, 0, 255),
    (170, 85, 85, 255), (170, 85, 170, 255), (170, 85, 255, 255), (170, 170, 85, 255),
    (170, 170, 255, 255), (170, 255, 0, 255), (170, 255, 85, 255), (170, 255, 170, 255),
    (170, 255, 255, 255), (255, 0, 85, 255), (255, 0, 255, 255), (255, 85, 0, 255),
    (255, 85, 85, 255), (255, 85, 170, 255), (255, 85, 255, 255), (255, 170, 0, 255),
    (255, 170, 85, 255), (255, 170, 170, 255), (255, 170, 255, 255), (255, 255, 85, 255),
    (255, 255, 255, 255), (0, 0, 0, 128), (255, 0, 0, 128), (0, 255, 0, 128),
    (255, 255, 0, 128), (0, 0, 255, 128), (255, 0, 255, 128), (0, 255, 255, 128),
    (255, 255, 255, 128), (170, 0, 0, 128), (0, 170, 0, 128), (170, 170, 0, 128),
    (0, 0, 170, 128), (170, 0, 170, 128), (0, 170, 170, 128), (170, 170, 170, 128),
    (0, 0, 85, 128), (0, 85, 0, 128), (0, 85, 85, 128), (0, 85, 170, 128),
    (0, 85, 255, 128), (0, 170, 85, 128), (0, 170, 255, 128), (0, 255, 85, 128),
    (0, 255, 170, 128), (85, 0, 0, 128), (85, 0, 85, 128), (85, 0, 170, 128),
    (85, 0, 255, 128), (85, 85, 0, 128), (85, 85, 85, 128), (85, 85, 170, 128),
    (85, 85, 255, 128), (85, 170, 0, 128), (85, 170, 85, 128), (85, 170, 170, 128),
    (85, 170, 255, 128), (85, 255, 0, 128), (85, 255, 85, 128), (85, 255, 170, 128),
    (85, 255, 255, 128), (170, 0, 85, 128), (170, 0, 255, 128), (170, 85, 0, 128),
    (170, 85, 85, 128), (170, 85, 170, 128), (170, 85, 255, 128), (170, 170, 85, 128),
    (170, 170, 255, 128), (170, 255, 0, 128), (170, 255, 85, 128), (170, 255, 170, 128),
    (170, 255, 255, 128), (255, 0, 85, 128), (255, 0, 255, 128), (255, 85, 0, 128),
    (255, 85, 85, 128), (255, 85, 170, 128), (255, 85, 255, 128), (255, 170, 0, 128),
    (255, 170, 85, 128), (255, 170, 170, 128), (255, 170, 255, 128), (255, 255, 85, 128),
    (255, 255, 255, 128),
)


@dataclass
class Logo:
    channel_no: int  # 3-digit channel number (11 for 011, 101, ...)
    service_id: int
    png: bytes  # 64x36 PNG with the palette inserted


def _chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


_PLTE = _chunk(b"PLTE", bytes(v for r, g, b, _a in LOGO_CLUT for v in (r, g, b)))
_TRNS = _chunk(b"tRNS", bytes(a for _r, _g, _b, a in LOGO_CLUT))
_IHDR_END = 8 + 4 + 4 + 13 + 4  # signature + IHDR chunk


def with_palette(png: bytes) -> bytes:
    """Insert the common palette (PLTE + tRNS) right after IHDR unless the PNG already has one."""
    if not png.startswith(_PNG_SIG):
        raise ValueError("not a PNG")
    if png[_IHDR_END + 4:_IHDR_END + 8] == b"PLTE":
        return png
    return png[:_IHDR_END] + _PLTE + _TRNS + png[_IHDR_END:]


def decode_logo_file(raw: bytes) -> list[Logo]:
    """Every service that has a logo, in file order. Services whose payload is not a PNG are skipped."""
    out: list[Logo] = []
    for rec in split_streams(raw)[1:]:
        if len(rec) < _HEADER_LEN:
            continue
        _rec_len, _group, _ff, chno, _zero, service_id, payload_len = struct.unpack_from(_HEADER, rec, 0)
        payload = rec[_HEADER_LEN:_HEADER_LEN + payload_len]
        if payload.startswith(_PNG_SIG):
            out.append(Logo(chno & 0xFFFFFF, service_id, with_palette(payload)))
    return out


def encode_logo_file(records: list[tuple[int, int, bytes]], broadcasting_byte: int = 1) -> bytes:
    """Test helper: build a logo file from (channel_no, service_id, payload) records."""
    parts = [zlib.compress(bytes(8))]
    for chno, service_id, payload in records:
        header = struct.pack(_HEADER, _HEADER_LEN + len(payload), 0xFF, 0xFF, (broadcasting_byte << 24) | chno, 0,
                             service_id, len(payload))
        parts.append(zlib.compress(header + payload))
    return bytes(b ^ _XOR for b in b"".join(parts))
