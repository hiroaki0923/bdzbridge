"""Wake-on-LAN for a recorder that has dropped off the network (deep standby, after a firmware update, ...).

The recorder's MAC address is taken from the host's ARP/neighbour table right after we have talked to it, so
nothing needs configuring; BDZBRIDGE_RECORDER_MAC overrides it.
"""
from __future__ import annotations

import asyncio
import re
import shutil
import socket

_MAC = re.compile(r"\b([0-9a-f]{1,2})[:-]([0-9a-f]{1,2})[:-]([0-9a-f]{1,2})[:-]([0-9a-f]{1,2})[:-]([0-9a-f]{1,2})[:-]([0-9a-f]{1,2})\b", re.IGNORECASE)


def normalize_mac(text: str) -> str | None:
    m = _MAC.search(text)
    return ":".join(p.lower().zfill(2) for p in m.groups()) if m else None


async def mac_for(host: str) -> str | None:
    """The MAC the OS currently has for `host` (macOS `arp -n`, Linux `ip neigh`), or None."""
    for cmd in (["/usr/sbin/arp", "-n", host], ["arp", "-n", host], ["ip", "neigh", "show", host]):
        if not (cmd[0].startswith("/") or shutil.which(cmd[0])):
            continue
        try:
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            out, _ = await asyncio.wait_for(proc.communicate(), 5)
        except (TimeoutError, OSError):
            continue
        mac = normalize_mac(out.decode(errors="replace"))
        if mac and mac != "ff:ff:ff:ff:ff:ff":
            return mac
    return None


def magic_packet(mac: str) -> bytes:
    raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    if len(raw) != 6:
        raise ValueError(f"bad MAC address: {mac}")
    return b"\xff" * 6 + raw * 16


def send_magic(mac: str, broadcasts: tuple[str, ...] = ("255.255.255.255",), ports: tuple[int, ...] = (9, 7)) -> None:
    pkt = magic_packet(mac)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for addr in broadcasts:
            for port in ports:
                s.sendto(pkt, (addr, port))


async def port_open(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        _, w = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    except (TimeoutError, OSError):
        return False
    w.close()
    return True


async def wake(host: str, mac: str, port: int = 64220, wait: float = 25.0) -> bool:
    """Send magic packets and wait until `port` answers.

    They go to the limited broadcast, the host's own /24 broadcast, and the host itself: a directed packet
    wakes the recorder too (measured), and is the one that survives a router when the gateway still knows
    the MAC.
    """
    subnet = ".".join(host.split(".")[:3]) + ".255" if host.count(".") == 3 else "255.255.255.255"
    send_magic(mac, ("255.255.255.255", subnet, host))
    deadline = asyncio.get_running_loop().time() + wait
    while asyncio.get_running_loop().time() < deadline:
        if await port_open(host, port):
            return True
        await asyncio.sleep(2)
    return await port_open(host, port)
