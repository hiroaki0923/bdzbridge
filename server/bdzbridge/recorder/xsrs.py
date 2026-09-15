"""SOAP client for the recorder's X_ScheduledRecording (XSRS) and X_PvrControl UPnP services (port 64220).

Request shapes verified on BDZ-FBT4100 (docs/xsrs-api.md).
No authentication is required on the LAN.
"""
from __future__ import annotations

import html
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timedelta

import httpx

from .epg import JST

XSRS_TYPE = "urn:schemas-xsrs-org:service:X_ScheduledRecording:2"
PVR_TYPE = "urn:schemas-s-bras-org:service:X_PvrControl:1"
CDS_TYPE = "urn:schemas-upnp-org:service:ContentDirectory:1"
XSRS_NS = "urn:schemas-xsrs-org:metadata-1-0/x_srs/"
_CLIENT_HEADERS = {
    "Content-Type": 'text/xml; charset="utf-8"',
    "Accept-Language": "ja",
}


# The criteria syntax is `field = "value"`, and it has to be exact: the recorder answers 860/861 to a field
# it cannot search on, but a *value* it cannot parse silently matches everything rather than failing
# (docs/upnp/service-sweep.md). Written wrongly, this filter quietly does nothing.
_DESTINATION_HDD = 'recordDestinationID = "HDD"'


# Codes seen on a BDZ-FBT4100. The full list with what produces each one is in docs/xsrs-api.md.
_ERROR_TEXT = {
    "402": "レコーダーがこの要求を受け付けませんでした",
    "804": "レコーダーにこの予約がありません",
    "820": "レコーダーにこの録画がありません",
    "831": "このチャンネルは受信できないため、番組を選んだ予約ができません。"
           "契約やアンテナの設定を確かめてください",
    "880": "レコーダーが待機状態です。先に電源を入れてください",
}


class XsrsError(Exception):
    def __init__(self, action: str, status: int, code: str | None, body: str = ""):
        super().__init__(f"{action} failed: HTTP {status} UPnP error {code}")
        self.action, self.status, self.code, self.body = action, status, code, body

    @property
    def explanation(self) -> str:
        """What to put in front of the reader; the web app shows this. Japanese, with the code and the
        action kept in it so that a report of it can be looked up in docs/xsrs-api.md."""
        if text := _ERROR_TEXT.get(self.code or ""):
            return f"{text} ({self.code}: {self.action})"
        if self.code:
            return f"レコーダーがエラーを返しました ({self.code}: {self.action}, HTTP {self.status})"
        return f"レコーダーが HTTP {self.status} を返しました ({self.action})"


@dataclass
class Reservation:
    id: str
    title: str
    start: datetime
    duration_sec: int
    repeat_code: str
    broadcasting_type: int
    service_id: int
    event_id: int | None
    quality_code: int
    recording: bool
    conflict: bool
    destination: str
    size_mb: int | None
    creator: str | None
    genre_code: int | None = None  # genreID: ARIB content nibbles as level1 * 16 + level2


@dataclass
class RecordedTitle:
    id: str
    title: str
    start: datetime
    duration_sec: int
    broadcasting_type: int
    service_id: int
    quality_code: int
    protected: bool
    is_new: bool
    destination: str
    size_mb: int | None
    genre_code: int | None = None
    last_played: datetime | None = None  # lastPlaybackTime
    resume_sec: int | None = None        # its resumePoint attribute: where playback stopped


def _genre_code(item: ET.Element) -> int | None:
    g = _text(item, "genreID", "")
    return int(g) if g.isdigit() else None


def _fmt_start(dt: datetime) -> str:
    # The recorder accepts "+09:00" but rejects "+0900".
    return dt.astimezone(JST).replace(microsecond=0).isoformat()


def _parse_dt(s: str) -> datetime:
    s = s.strip()
    if len(s) >= 5 and s[-5] in "+-" and s[-3] != ":":
        s = s[:-2] + ":" + s[-2:]
    return datetime.fromisoformat(s)


def _matching_id(service_id: int, event_id: int) -> str:
    return f",,{service_id:#x},{event_id:#x}"


def _parse_matching_id(text: str | None) -> int | None:
    if not text:
        return None
    parts = text.split(",")
    try:
        return int(parts[-1], 16)
    except ValueError:
        return None


def build_create_elements(*, title: str, start: datetime, duration_sec: int, repeat_code: str, broadcasting_type: int,
                          service_id: int, quality_code: int, event_id: int | None = None) -> str:
    """The exact <Elements> payload the official app sends to X_CreateRecordSchedule."""
    matching = (f'<desiredMatchingID type="SI_PROGRAMID">{_matching_id(service_id, event_id)}</desiredMatchingID>'
                if event_id is not None else "")
    return (
        f'<xsrs xmlns="{XSRS_NS}"><item id="">'
        f"<title>{html.escape(title, quote=False)}</title>"
        f"<scheduledStartDateTime>{_fmt_start(start)}</scheduledStartDateTime>"
        f"<scheduledDuration>{int(duration_sec)}</scheduledDuration>"
        f"<scheduledConditionID>{repeat_code}</scheduledConditionID>"
        f'<scheduledChannelID broadcastingType="{broadcasting_type}" channelType="2">{service_id:#06x}</scheduledChannelID>'
        f"{matching}"
        f"<desiredQualityMode>{quality_code}</desiredQualityMode>"
        "<priorityFlag>0</priorityFlag>"
        "<recordDestinationID>HDD</recordDestinationID>"
        '<portableRecordFile target="preselect" transferPath="none"></portableRecordFile>'
        "</item></xsrs>"
    )


def build_title_update_elements(title_id: str, *, title: str | None = None, protected: bool | None = None,
                                is_new: bool | None = None) -> str:
    """X_UpdateTitle payload: the title's id plus only the properties to change."""
    props = ""
    if title is not None:
        props += f"<title>{html.escape(title, quote=False)}</title>"
    if protected is not None:
        props += f"<titleProtectFlag>{int(protected)}</titleProtectFlag>"
    if is_new is not None:
        props += f"<titleNewFlag>{int(is_new)}</titleNewFlag>"
    return f'<xsrs xmlns="{XSRS_NS}"><item id="{title_id}">{props}</item></xsrs>'


def build_update_elements(reservation_id: str, **kwargs) -> str:
    """Same item as for creation, with the id set. Verified on BDZ-FBT4100: changes quality/repeat in place."""
    return build_create_elements(**kwargs).replace('<item id="">', f'<item id="{reservation_id}">', 1)


def _soap_body(stype: str, action: str, args: list[tuple[str, object]]) -> bytes:
    inner = "".join(f"<{k}>{html.escape(str(v))}</{k}>" for k, v in args)
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" '
        'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
        f'<u:{action} xmlns:u="{stype}">{inner}</u:{action}></s:Body></s:Envelope>'
    ).encode()


def _find_text(root: ET.Element, tag: str) -> str | None:
    el = next((e for e in root.iter() if e.tag.split("}")[-1] == tag), None)
    return el.text if el is not None else None


def _items(result_xml: str) -> list[ET.Element]:
    if not result_xml.strip():
        return []
    root = ET.fromstring(result_xml)
    return [e for e in root.iter() if e.tag.split("}")[-1] == "item"]


def _child(item: ET.Element, tag: str) -> ET.Element | None:
    return next((c for c in item if c.tag.split("}")[-1] == tag), None)


def _text(item: ET.Element, tag: str, default: str = "") -> str:
    c = _child(item, tag)
    if c is None or c.text is None:
        return default
    return "".join(ch for ch in c.text if ch >= " " or ch == "\n")


def parse_reservation(item: ET.Element) -> Reservation:
    ch = _child(item, "scheduledChannelID")
    return Reservation(
        id=item.get("id", ""),
        title=_text(item, "title"),
        start=_parse_dt(_text(item, "scheduledStartDateTime")),
        duration_sec=int(_text(item, "scheduledDuration", "0")),
        repeat_code=_text(item, "scheduledConditionID", "1"),
        broadcasting_type=int(ch.get("broadcastingType", "0")) if ch is not None else 0,
        service_id=int((ch.text or "0x0"), 16) if ch is not None else 0,
        event_id=_parse_matching_id(_text(item, "desiredMatchingID", "") or None),
        quality_code=int(_text(item, "desiredQualityMode", "0")),
        recording=_text(item, "recordingFlag", "0") == "1",
        conflict=_text(item, "conflictID", "0") != "0",
        destination=_text(item, "recordDestinationID", "HDD"),
        size_mb=int(_text(item, "recordSize")) if _text(item, "recordSize") else None,
        creator=_text(item, "reservationCreatorID", "") or None,
        genre_code=_genre_code(item),
    )


def parse_title(item: ET.Element) -> RecordedTitle:
    ch = _child(item, "scheduledChannelID")
    lp = _child(item, "lastPlaybackTime")
    return RecordedTitle(
        id=item.get("id", ""),
        title=_text(item, "title"),
        start=_parse_dt(_text(item, "scheduledStartDateTime")),
        duration_sec=int(_text(item, "scheduledDuration", "0")),
        broadcasting_type=int(ch.get("broadcastingType", "0")) if ch is not None else 0,
        service_id=int((ch.text or "0x0"), 16) if ch is not None else 0,
        quality_code=int(_text(item, "desiredQualityMode", "0")),
        protected=_text(item, "titleProtectFlag", "0") == "1",
        is_new=_text(item, "titleNewFlag", "0") == "1",
        destination=_text(item, "recordDestinationID", "HDD"),
        size_mb=int(_text(item, "recordSize")) if _text(item, "recordSize") else None,
        genre_code=_genre_code(item),
        last_played=_parse_dt(lp.text) if lp is not None and lp.text and lp.text[:1].isdigit() else None,  # "notplayed" otherwise
        resume_sec=int(lp.get("resumePoint")) if lp is not None and (lp.get("resumePoint") or "").isdigit() else None,
    )


class XsrsClient:
    def __init__(self, host: str, http: httpx.AsyncClient, port: int = 64220):
        self.base = f"http://{host}:{port}"
        self.http = http

    async def _call(self, ctrl: str, stype: str, action: str, args: list[tuple[str, object]]) -> ET.Element:
        headers = dict(_CLIENT_HEADERS, SOAPACTION=f'"{stype}#{action}"')
        r = await self.http.post(self.base + ctrl, content=_soap_body(stype, action, args), headers=headers, timeout=30)
        root = ET.fromstring(r.text)
        code = _find_text(root, "errorCode")
        if r.status_code != 200 or code:
            raise XsrsError(action, r.status_code, code, r.text[:500])
        return root

    async def _result_items(self, ctrl, stype, action, args) -> tuple[list[ET.Element], ET.Element]:
        root = await self._call(ctrl, stype, action, args)
        return _items(_find_text(root, "Result") or ""), root

    # --- reservations ---
    async def list_reservations(self, count: int = 200) -> list[Reservation]:
        items, _ = await self._result_items("/XSRS", XSRS_TYPE, "X_GetRecordScheduleList",
                                            [("SearchCriteria", ""), ("StartingIndex", 0), ("RequestedCount", count),
                                             ("SortCriteria", "-scheduledStartDateTime"), ("Filter", "*")])
        return [parse_reservation(i) for i in items]

    async def conflicts(self, elements: str) -> list[Reservation]:
        items, _ = await self._result_items("/XSRS", XSRS_TYPE, "X_GetConflictList", [("Elements", elements)])
        return [parse_reservation(i) for i in items]

    async def create_reservation(self, elements: str) -> str:
        root = await self._call("/XSRS", XSRS_TYPE, "X_CreateRecordSchedule", [("Elements", elements)])
        return _find_text(root, "RecordScheduleID") or ""

    async def update_reservation(self, elements: str) -> None:
        await self._call("/XSRS", XSRS_TYPE, "X_UpdateRecordSchedule", [("Elements", elements)])

    async def delete_reservation(self, reservation_id: str) -> None:
        await self._call("/XSRS", XSRS_TYPE, "X_DeleteRecordSchedule", [("RecordScheduleID", reservation_id)])

    # --- recorded titles ---
    async def list_titles(self, count: int = 100, start: int = 0) -> list[RecordedTitle]:
        items, _ = await self._result_items("/XSRS", XSRS_TYPE, "X_GetTitleList",
                                            [("SearchCriteria", _DESTINATION_HDD), ("StartingIndex", start),
                                             ("RequestedCount", count), ("SortCriteria", "-scheduledStartDateTime"),
                                             ("Filter", "*")])
        return [parse_title(i) for i in items]

    async def list_titles_all(self, page: int = 200) -> list[RecordedTitle]:
        """Every recorded title, newest first (one call returns at most 200)."""
        out: list[RecordedTitle] = []
        start = 0
        while True:
            items, root = await self._result_items("/XSRS", XSRS_TYPE, "X_GetTitleList",
                                                   [("SearchCriteria", _DESTINATION_HDD), ("StartingIndex", start),
                                                    ("RequestedCount", page), ("SortCriteria", "-scheduledStartDateTime"),
                                                    ("Filter", "*")])
            out += [parse_title(i) for i in items]
            start += len(items)
            if not items or start >= int(_find_text(root, "TotalMatches") or 0):
                return out

    # --- PvrControl ---
    async def _pvr(self, action: str, args: list[tuple[str, object]]) -> str:
        root = await self._call("/X_PvrControl", PVR_TYPE, action, args)
        return _find_text(root, "Result") or ""

    async def private_ip(self) -> dict[str, str]:
        """The recorder's own network settings: ipAddress, subNetMask, defaultGateWay, primaryDns,
        useDhcp, and both MAC addresses (macAddress wired, wirelessMacAddress). Verified on a
        BDZ-FBT4100, where macAddress matches what ARP reports."""
        res = ET.fromstring(await self._pvr("X_GetPrivateIp", []))
        return {child.tag.split("}")[-1]: (child.text or "") for child in res}

    async def play_status(self) -> dict[str, str]:
        res = ET.fromstring(await self._pvr("X_GetPlayStatus", []))
        return {e.tag.split("}")[-1]: (e.text or "") for e in res}

    async def firmware_version(self) -> str:
        return _find_text(ET.fromstring(await self._pvr("X_GetFirmwareVersion", [])), "version") or ""

    async def power_on(self) -> str:
        return _find_text(ET.fromstring(await self._pvr("X_PowerControl", [("Operation", "on")])), "powerstatus") or ""

    async def live_channel_ids(self, broadcasting_type: int) -> list[int]:
        res = ET.fromstring(await self._pvr("X_GetLiveChList", [("BroadcastType", broadcasting_type), ("SkipChannel", 0)]))
        text = _find_text(res, "channelList") or ""
        return [int(x) for x in text.split("_") if x]

    async def play_control(self, title_id: str, operation: str, position: int = 0) -> None:
        """Playback on the TV connected to the recorder. operation: play | stop | pause (lower case; "pause" toggles,
        there is no resume). "play" with a Position restarts from the beginning on the BDZ-FBT4100.
        The recorder must be fully on (X_PowerControl "on"); in network standby it answers error 880."""
        await self._call("/X_PvrControl", PVR_TYPE, "X_PlayControlTitle",
                         [("TitleID", title_id), ("Operation", operation), ("Position", position)])

    async def title_detail(self, title_id: str) -> dict:
        """Summary and detail paragraphs of a recorded title (from its EPG data)."""
        res = await self._pvr("X_GetTitleDetail", [("Id", title_id)])
        root = ET.fromstring(res)
        out = {"summary": "", "details": []}
        for e in root:
            tag = e.tag.split("}")[-1]
            if tag == "summary":
                out["summary"] = (e.text or "").strip()
            elif tag.startswith("detail"):
                out["details"].append((e.text or "").strip())
        return out

    # --- ContentDirectory ---
    async def browse_children(self, object_id: str, count: int = 5, control_url: str = "/DMSContentDirectory") -> str:
        """Raw DIDL-Lite of a container's children (used to learn the media server's streaming port)."""
        root = await self._call(control_url, CDS_TYPE, "Browse",
                                [("ObjectID", object_id), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "*"),
                                 ("StartingIndex", 0), ("RequestedCount", count), ("SortCriteria", "")])
        return _find_text(root, "Result") or ""

    async def update_title(self, elements: str) -> None:
        """Change a recorded title's name / protect flag / new flag (see build_title_update_elements)."""
        await self._call("/XSRS", XSRS_TYPE, "X_UpdateTitle", [("Elements", elements)])

    async def delete_title(self, title_id: str) -> None:
        """Delete a recording (X_DeleteTitle). The recorder refuses protected titles."""
        await self._call("/XSRS", XSRS_TYPE, "X_DeleteTitle", [("TitleID", title_id)])

    async def record_destination_info(self, destination: str = "HDD") -> dict[str, int]:
        """Capacity of a record destination in bytes (ContentDirectory X_HDLnkGetRecordDestinationInfo)."""
        root = await self._call("/DMSContentDirectory", CDS_TYPE, "X_HDLnkGetRecordDestinationInfo",
                                [("RecordDestinationID", destination)])
        info = ET.fromstring(_find_text(root, "RecordDestinationInfo") or "<RecordDestinationInfo/>")
        return {"total_bytes": int(info.get("totalCapacity", 0)), "free_bytes": int(info.get("availableCapacity", 0))}

    async def send_key(self, key: str) -> None:
        await self._call("/X_PvrControl", PVR_TYPE, "X_InputRemoteKey", [("RemoteKey", key)])


def duration_from(start: datetime, end: datetime) -> int:
    return int((end - start) / timedelta(seconds=1))
