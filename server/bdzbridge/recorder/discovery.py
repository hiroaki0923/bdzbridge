"""Find Sony BDZ recorders on the LAN.

Two strategies, tried in order:
1. SSDP M-SEARCH (standard UPnP discovery). Fast when multicast works.
2. A TCP scan of the local subnet(s) for port 64220, then fetching description.xml.
   Needed where multicast replies never arrive (some firewalls / Wi-Fi controllers).
Every candidate is confirmed by parsing description.xml for the Sony recorder markers.
"""
from __future__ import annotations

import asyncio
import ipaddress
import re
import socket
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from urllib.parse import urlparse

import httpx

UPNP_PORT = 64220
SSDP_ADDR = ("239.255.255.250", 1900)
XSRS_SERVICE = "urn:schemas-xsrs-org:service:X_ScheduledRecording"


@dataclass
class Candidate:
    host: str
    port: int
    friendly_name: str
    product: str
    model: str
    udn: str
    epg_capable: bool
    location: str
    via: str  # "ssdp" | "scan" | "manual"


def parse_description(xml_text: str, host: str, port: int, location: str, via: str) -> Candidate | None:
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return None

    def t(tag: str) -> str:
        el = next((e for e in root.iter() if e.tag.split("}")[-1] == tag), None)
        return (el.text or "").strip() if el is not None else ""

    services = [e.text or "" for e in root.iter() if e.tag.split("}")[-1] == "serviceType"]
    if t("manufacturer") != "Sony Corporation" or not any(s.startswith(XSRS_SERVICE) for s in services):
        return None
    return Candidate(host=host, port=port, friendly_name=t("friendlyName"), product=t("productName") or t("modelName"),
                     model=t("modelDescription"), udn=t("UDN"), epg_capable=t("EPG_CAP") not in ("", "00"),
                     location=location, via=via)


async def probe(host: str, http: httpx.AsyncClient, port: int = UPNP_PORT, via: str = "manual") -> Candidate | None:
    url = f"http://{host}:{port}/description.xml"
    try:
        r = await http.get(url, timeout=4.0)
    except httpx.HTTPError:
        return None
    if r.status_code != 200:
        return None
    return parse_description(r.text, host, port, url, via)


class _SsdpProtocol(asyncio.DatagramProtocol):
    def __init__(self):
        self.locations: set[str] = set()

    def datagram_received(self, data: bytes, addr) -> None:
        m = re.search(rb"(?im)^location:\s*(\S+)", data)
        if m:
            self.locations.add(m.group(1).decode(errors="ignore"))


async def ssdp_locations(timeout: float = 3.0) -> set[str]:
    loop = asyncio.get_running_loop()
    transport, proto = await loop.create_datagram_endpoint(_SsdpProtocol, family=socket.AF_INET, proto=socket.IPPROTO_UDP)
    try:
        for st in ("urn:schemas-upnp-org:device:MediaServer:1", "ssdp:all"):
            msg = "\r\n".join(["M-SEARCH * HTTP/1.1", f"HOST: {SSDP_ADDR[0]}:{SSDP_ADDR[1]}", 'MAN: "ssdp:discover"',
                               f"MX: {max(1, int(timeout))}", f"ST: {st}", "", ""]).encode()
            transport.sendto(msg, SSDP_ADDR)
        await asyncio.sleep(timeout)
    finally:
        transport.close()
    return proto.locations


def local_networks(extra: str = "") -> list[ipaddress.IPv4Network]:
    nets: list[ipaddress.IPv4Network] = []
    for cidr in (c.strip() for c in extra.split(",") if c.strip()):
        nets.append(ipaddress.ip_network(cidr, strict=False))
    if nets:
        return nets
    # No interface API in the stdlib; the routing trick tells us the primary local address, assume /24.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))  # no packet is sent for UDP connect
        ip = s.getsockname()[0]
    finally:
        s.close()
    return [ipaddress.ip_network(f"{ip}/24", strict=False)]


async def tcp_open_hosts(networks: list[ipaddress.IPv4Network], port: int = UPNP_PORT, concurrency: int = 128,
                         timeout: float = 1.0) -> list[str]:
    sem = asyncio.Semaphore(concurrency)
    found: list[str] = []

    async def check(ip: str) -> None:
        async with sem:
            try:
                _, w = await asyncio.wait_for(asyncio.open_connection(ip, port), timeout)
            except (TimeoutError, OSError):
                return
            w.close()
            found.append(ip)

    hosts = [str(h) for net in networks for h in net.hosts()]
    await asyncio.gather(*(check(h) for h in hosts))
    return found


async def discover(http: httpx.AsyncClient, *, ssdp_timeout: float = 3.0, scan: bool = True,
                   networks: str = "") -> list[Candidate]:
    """SSDP first; if that yields no recorder, scan the subnet. Returns confirmed recorders only."""
    results: dict[str, Candidate] = {}
    try:
        locations = await ssdp_locations(ssdp_timeout)
    except OSError:
        locations = set()
    for loc in locations:
        u = urlparse(loc)
        if not u.hostname:
            continue
        try:
            r = await http.get(loc, timeout=4.0)
        except httpx.HTTPError:
            continue
        c = parse_description(r.text, u.hostname, u.port or 80, loc, "ssdp") if r.status_code == 200 else None
        if c:
            results[c.udn or c.host] = c
    if not results and scan:
        hosts = await tcp_open_hosts(local_networks(networks))
        for c in await asyncio.gather(*(probe(h, http, via="scan") for h in hosts)):
            if c:
                results[c.udn or c.host] = c
    return sorted(results.values(), key=lambda c: c.host)
