"""One object per recorder: discovery, EPG download, XSRS calls, all serialized through a single lock.

The recorder answers 503 when it gets concurrent requests, so every call goes through `self.lock`.
"""
from __future__ import annotations

import asyncio
import xml.etree.ElementTree as ET
from dataclasses import dataclass

import httpx

from . import codes
from .epg import Service, decode_epg_file
from .xsrs import XsrsClient


@dataclass
class RecorderInfo:
    host: str
    friendly_name: str
    model: str
    product: str
    epg_capable: bool
    udn: str


class RecorderClient:
    def __init__(self, host: str, upnp_port: int = 64220, stream_port: int = 60151):
        self.host = host
        self.upnp_port = upnp_port
        self.stream_port = stream_port
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
        return self.info

    async def fetch_epg(self, broadcasting: str) -> list[Service] | None:
        """Download and decode one broadcasting type's EPG. Returns None when the recorder has no such channels (HTTP 416)."""
        url = f"http://{self.host}:{self.stream_port}//{codes.EPG_FILES[broadcasting]}"
        async with self.lock:
            r = await self.http.get(url)
        if r.status_code == 416:
            return None
        r.raise_for_status()
        return decode_epg_file(r.content)

    async def fetch_logo_file(self, broadcasting: str) -> bytes | None:
        url = f"http://{self.host}:{self.stream_port}//{codes.LOGO_FILES[broadcasting]}"
        async with self.lock:
            r = await self.http.get(url)
        return r.content if r.status_code == 200 else None
