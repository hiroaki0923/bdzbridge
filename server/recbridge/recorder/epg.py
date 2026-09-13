"""Decoder (and test encoder) for the EPG files a Sony BDZ recorder serves on port 60151.

Format (as served by a BDZ-FBT4100; see docs/epg-format.md):
  raw file  = XOR 0x9D over a concatenation of zlib streams, one stream per service.
  stream    = "@SRV" record: 156-byte header, then "@DAY" blocks holding "@EVT" blocks.
  times     = seconds since 1970-01-01 00:00 *JST* (unix time + 32400).
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

JST = timezone(timedelta(hours=9))
_JST_OFFSET = 32400
_XOR = 0x9D
_HEADER_LEN = 156
_EVT_HEADER_LEN = 56


@dataclass
class Program:
    service_id: int
    event_id: int
    start: datetime
    end: datetime
    title: str = ""
    description: str = ""
    extended: str = ""
    genres: list[tuple[int, int]] = field(default_factory=list)  # (level1, level2) nibbles
    copy_control: int = 0
    parental_rating: int = 0
    ref_service_id: int | None = None  # set for simulcast references on sub-channels
    ref_event_id: int | None = None

    @property
    def is_reference(self) -> bool:
        return self.ref_event_id is not None

    @property
    def duration_sec(self) -> int:
        return int((self.end - self.start).total_seconds())


@dataclass
class Service:
    service_id: int
    name: str
    programs: list[Program] = field(default_factory=list)


def _be16(b: bytes, i: int) -> int:
    return (b[i] << 8) | b[i + 1]


def _be32(b: bytes, i: int) -> int:
    return struct.unpack_from(">I", b, i)[0]


def _ts(v: int) -> datetime:
    return datetime.fromtimestamp(v - _JST_OFFSET, JST)


# ARIB additional symbols arrive as private-use code points (mapping: docs/epg-format.md).
ARIB_SYMBOLS = {
    "\ue0fd": "[手]", "\ue0fe": "[字]", "\ue180": "[デ]", "\ue182": "[二]", "\ue183": "[多]", "\ue184": "[解]",
    "\ue185": "[SS]", "\ue18c": "[映]", "\ue192": "[再]", "\ue193": "[新]", "\ue195": "[終]", "\ue196": "[生]",
}


def _clean(b: bytes) -> str:
    """UTF-8 text from the recorder: NUL padding and C0 controls dropped, ARIB symbols spelled out, unknown private-use chars removed."""
    out = []
    for ch in b.decode("utf-8", "replace"):
        if ch in ARIB_SYMBOLS:
            out.append(ARIB_SYMBOLS[ch])
        elif "\ue000" <= ch <= "\uf8ff" or (ch < " " and ch != "\n"):
            continue
        else:
            out.append(ch)
    return "".join(out).strip()


def _unts(dt: datetime) -> int:
    return int(dt.timestamp()) + _JST_OFFSET


def split_streams(raw: bytes) -> list[bytes]:
    """XOR-decode and inflate every concatenated zlib stream."""
    x = bytes(b ^ _XOR for b in raw)
    out: list[bytes] = []
    pos = 0
    while pos < len(x):
        d = zlib.decompressobj()
        data = d.decompress(x[pos:])
        used = len(x) - pos - len(d.unused_data)
        if used <= 0:
            break
        out.append(data)
        pos += used
    return out


def parse_service(rec: bytes) -> Service:
    if rec[:4] != b"@SRV":
        raise ValueError("not an @SRV record")
    service_id = _be16(rec, 8)
    name_len = _be16(rec, 26)
    name = _clean(rec[28:28 + name_len])
    svc = Service(service_id=service_id, name=name)
    p = _HEADER_LEN
    while p + 16 <= len(rec) and rec[p:p + 4] == b"@DAY":
        block_len = _be32(rec, p + 8)
        e = p + 16
        end = p + block_len
        while e + 12 <= end and rec[e:e + 4] == b"@EVT":
            event_len = _be16(rec, e + 8)
            if event_len < 28:
                break
            flags = rec[e + 10]
            pr = Program(service_id=service_id, event_id=_be16(rec, e + 6),
                         start=_ts(_be32(rec, e + 16)), end=_ts(_be32(rec, e + 20)))
            if (flags >> 6) & 1 and not (flags >> 5) & 1:
                # reference form (simulcast on a sub-channel): only start/end plus the parent service/event
                pr.ref_service_id = _be16(rec, e + 24)
                pr.ref_event_id = _be16(rec, e + 26)
            else:
                # three 2-byte slots: content nibbles, then user nibbles (0xFF when the slot is in use)
                pr.genres = [(rec[e + 30 + 2 * i] >> 4, rec[e + 30 + 2 * i] & 0xF) for i in range(3)
                             if rec[e + 31 + 2 * i] != 0 or rec[e + 30 + 2 * i] != 0]
                pr.copy_control = (rec[e + 40] & 0x0C) >> 2
                rating = rec[e + 41] & 0x1F
                pr.parental_rating = 0 if rating < 4 else rating - 3
                n_title, n_desc, title_field, desc_end, n_ext = (_be16(rec, e + 44 + 2 * i) for i in range(5))
                t = e + _EVT_HEADER_LEN
                pr.title = _clean(rec[t:t + n_title])
                pr.description = _clean(rec[t + title_field:t + title_field + n_desc])
                pr.extended = _clean(rec[t + desc_end:t + desc_end + n_ext])
            svc.programs.append(pr)
            e += event_len
        p += block_len
    return svc


def decode_epg_file(raw: bytes) -> list[Service]:
    return [parse_service(s) for s in split_streams(raw)]


# --- encoder: used by tests to build fixtures and to prove the layout is understood both ways ---

def _encode_event(pr: Program) -> bytes:
    if pr.is_reference:
        body = bytearray(b"@EVT" + b"\x04\x00")
        body += struct.pack(">HHB", pr.event_id, 0, 0x44) + b"\x00" * 5
        body += struct.pack(">II", _unts(pr.start), _unts(pr.end))
        body += struct.pack(">HH", pr.ref_service_id or 0, pr.ref_event_id or 0)
        body += b"\x00" * 4
        struct.pack_into(">H", body, 8, len(body))
        return bytes(body)
    title, desc, ext = pr.title.encode(), pr.description.encode(), pr.extended.encode()
    title_field = len(title) + 2
    desc_end = title_field + len(desc) + 2
    body = bytearray(b"@EVT" + b"\x04\x00")
    body += struct.pack(">HHB", pr.event_id, 0, 0x64) + b"\x08\x00\x00\x00\x01"
    body += struct.pack(">II", _unts(pr.start), _unts(pr.end)) + b"\x00" * 6
    genres = list(pr.genres)[:3]
    for l1, l2 in genres:
        body += bytes([(l1 << 4) | l2, 0xFF])
    body += b"\x00\x00" * (3 - len(genres))
    body += b"\x00" * 4 + bytes([pr.copy_control << 2, 0 if pr.parental_rating == 0 else pr.parental_rating + 3]) + b"\x00" * 2
    body += struct.pack(">HHHHH", len(title), len(desc), title_field, desc_end, len(ext)) + b"\x00" * 2
    assert len(body) == _EVT_HEADER_LEN
    body += title + b"\x00\x00" + desc + b"\x00\x00" + ext + b"\x00\x00"
    struct.pack_into(">H", body, 8, len(body))
    return bytes(body)


def encode_service(svc: Service) -> bytes:
    """Build one inflated @SRV record (no XOR/zlib)."""
    name = svc.name.encode()
    hdr = bytearray(b"@SRV" + struct.pack(">HHH", 3, 0, svc.service_id) + b"\x00\x08" + b"\x00" * 4)
    hdr += b"\x00" * (26 - len(hdr)) + struct.pack(">H", len(name)) + name
    hdr += b"\x00" * (_HEADER_LEN - len(hdr))
    days: dict[datetime, list[Program]] = {}
    for pr in svc.programs:
        day = pr.start.astimezone(JST).replace(hour=0, minute=0, second=0, microsecond=0)
        days.setdefault(day, []).append(pr)
    body = bytearray()
    for day, prs in sorted(days.items()):
        events = b"".join(_encode_event(p) for p in prs)
        body += b"@DAY" + struct.pack(">IIB", _unts(day), 16 + len(events), len(prs)) + b"\x00" * 3 + events
    struct.pack_into(">I", hdr, 12, len(hdr) + len(body) - 4)
    return bytes(hdr) + bytes(body)


def encode_epg_file(services: list[Service]) -> bytes:
    raw = b"".join(zlib.compress(encode_service(s)) for s in services)
    return bytes(b ^ _XOR for b in raw)
