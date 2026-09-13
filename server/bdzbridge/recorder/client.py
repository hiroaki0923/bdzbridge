"""One object per recorder: discovery, EPG download, XSRS calls, all serialized through a single lock.

The recorder answers 503 when it gets concurrent requests, so every call goes through `self.lock`.
"""
from __future__ import annotations

import asyncio
import logging
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from urllib.parse import urlparse

import httpx

from . import codes
from .epg import Service, decode_epg_file
from .logo import Logo, decode_logo_file
from .xsrs import XsrsClient

log = logging.getLogger("bdzbridge.recorder")
DEFAULT_STREAM_PORT = 60151


def port_from_didl(didl: str) -> int | None:
    """The media server's HTTP port, taken from the first <res> URL in a DIDL-Lite fragment."""
    for m in re.finditer(r"<res[^>]*>\s*(http://[^<\s]+)", didl):
        port = urlparse(m.group(1)).port
        if port:
            return port
    return None


@dataclass
class RecorderInfo:
    host: str
    friendly_name: str
    model: str
    product: str
    epg_capable: bool
    udn: str


class RecorderClient:
    def __init__(self, host: str, upnp_port: int = 64220, stream_port: int | None = None):
        self.host = host
        self.upnp_port = upnp_port
        self.stream_port = stream_port or DEFAULT_STREAM_PORT
        self._stream_port_detected = stream_port is not None
        self.http = httpx.AsyncClient(timeout=httpx.Timeout(30.0, read=120.0))
        self.xsrs = XsrsClient(host, self.http, upnp_port)
        self.lock = asyncio.Lock()
        self.info: RecorderInfo | None = None

    async def close(self) -> None:
        await self.http.aclose()

    async def discover(self) -> RecorderInfo:
        async with self.lock:
            r = await self.http.get(f"http://{self.host}:{self.upnp_port}/description.xml")
            r.raise_for_status()
        root = ET.fromstring(r.text)

        def t(tag: str) -> str:
            el = next((e for e in root.iter() if e.tag.split("}")[-1] == tag), None)
            return (el.text or "").strip() if el is not None else ""

        self.info = RecorderInfo(host=self.host, friendly_name=t("friendlyName"), model=t("modelDescription"),
                                 product=t("productName") or t("modelName"), epg_capable=t("EPG_CAP") not in ("", "00"),
                                 udn=t("UDN"))
        if not self._stream_port_detected:
            await self.detect_stream_port()
        return self.info

    async def detect_stream_port(self, max_requests: int = 8) -> int:
        """Walk the DLNA tree until an item with a <res> URL appears; its port is where EPG files are served.
        Falls back to the default port when nothing is found."""
        queue, seen = ["0"], 0
        try:
            while queue and seen < max_requests:
                oid = queue.pop(0)
                seen += 1
                async with self.lock:
                    didl = await self.xsrs.browse_children(oid)
                port = port_from_didl(didl)
                if port:
                    self.stream_port = port
                    self._stream_port_detected = True
                    log.info("media server port %s (from %s)", port, oid)
                    return port
                queue += re.findall(r'<container id="([^"]+)"', didl)
        except Exception as e:
            log.warning("stream port detection failed, keeping %s: %s", self.stream_port, e)
        return self.stream_port

    async def fetch_epg(self, broadcasting: str) -> list[Service] | None:
        """Download and decode one broadcasting type's EPG. Returns None when the recorder has no such channels (HTTP 416)
        or does not provide an EPG at all (EPG_CAP 00)."""
        if self.info is not None and not self.info.epg_capable:
            return None
        url = f"http://{self.host}:{self.stream_port}//{codes.EPG_FILES[broadcasting]}"
        async with self.lock:
            r = await self.http.get(url)
        if r.status_code == 416:
            return None
        r.raise_for_status()
        return decode_epg_file(r.content)

    async def fetch_logos(self, broadcasting: str) -> list[Logo] | None:
        """Station logos for one broadcasting type; None when the recorder has none to offer."""
        if self.info is not None and not self.info.epg_capable:
            return None
        url = f"http://{self.host}:{self.stream_port}//{codes.LOGO_FILES[broadcasting]}"
        async with self.lock:
            r = await self.http.get(url)
        if r.status_code in (404, 416):
            return None
        r.raise_for_status()
        return decode_logo_file(r.content)

    @staticmethod
    def cds_id(title_id: str) -> str:
        """The DLNA item id of a recorded title: the low 32 bits of the XSRS title id."""
        return f"V_{int(title_id, 16) & 0xFFFFFFFF}"

    async def fetch_logo_file(self, broadcasting: str) -> bytes | None:
        url = f"http://{self.host}:{self.stream_port}//{codes.LOGO_FILES[broadcasting]}"
        async with self.lock:
            r = await self.http.get(url)
        return r.content if r.status_code == 200 else None
