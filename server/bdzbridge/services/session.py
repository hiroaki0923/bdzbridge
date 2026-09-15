"""Which recorder we talk to: discovery, selection and re-discovery, reachability, Wake-on-LAN."""
from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from fastapi import HTTPException

from ..recorder import discovery, wol
from ..recorder.client import RecorderClient

if TYPE_CHECKING:
    from ..state import Bridge

log = logging.getLogger("bdzbridge.session")


async def discover(bridge) -> list[discovery.Candidate]:
    return await discovery.discover(bridge.http, networks=bridge.settings.scan_networks)


async def set_recorder(bridge, host: str, persist: bool = True) -> RecorderClient:
    client = RecorderClient(host)
    try:
        info = await client.discover()
    except Exception as e:
        await client.close()
        raise HTTPException(400, f"no recorder answered at {host}: {e}")
    old, bridge.recorder = bridge.recorder, client
    if old is not None:
        await old.close()
    if persist:
        bridge.store.set_meta("recorder_host", host)
        bridge.store.set_meta("recorder_udn", info.udn)
        bridge.store.set_meta("recorder_name", info.friendly_name)
    if not bridge.settings.recorder_mac and (mac := await _discover_mac(client, host)):
        bridge.store.set_meta("recorder_mac", mac)  # for Wake-on-LAN later
    return client


async def _discover_mac(client, host: str) -> str | None:
    """The recorder hands out its own MAC, which beats hoping the OS has it in ARP: that needs the host to
    have talked to the recorder recently and to be on the same segment. ARP stays as the fallback for a
    recorder too old to answer."""
    try:
        async with client.lock:
            settings = await client.xsrs.private_ip()
    except Exception as e:  # any recorder that does not answer this leaves ARP to try
        log.debug("X_GetPrivateIp did not answer: %s", e)
    else:
        if mac := wol.normalize_mac(settings.get("macAddress", "")):
            return mac
    return await wol.mac_for(host)


def mac(bridge: Bridge) -> str | None:
    return bridge.settings.recorder_mac or bridge.store.get_meta("recorder_mac")


async def reachable(bridge) -> bool:
    return bridge.recorder is not None and await wol.port_open(bridge.recorder.host, 64220)


async def wake(bridge) -> bool:
    """Wake-on-LAN, then wait for the reservation service to answer. False when it stays silent."""
    rec = bridge.require_recorder()
    if not mac(bridge):
        raise HTTPException(409, "the recorder's MAC address is not known; set BDZBRIDGE_RECORDER_MAC")
    if await wol.port_open(rec.host, 64220):
        return True
    return await wol.wake(rec.host, mac(bridge))


async def resolve_recorder(bridge) -> None:
    """Startup: env var wins; else the saved host; if it moved, find it again by UDN."""
    if bridge.settings.recorder_host:
        try:
            await set_recorder(bridge, bridge.settings.recorder_host, persist=False)
        except HTTPException as e:
            log.warning("configured recorder unreachable: %s", e.detail)
        return
    saved_host, saved_udn = bridge.store.get_meta("recorder_host"), bridge.store.get_meta("recorder_udn")
    if saved_host:
        c = await discovery.probe(saved_host, bridge.http)
        if c and (not saved_udn or c.udn == saved_udn):
            await set_recorder(bridge, saved_host, persist=False)
            return
        log.warning("saved recorder %s not answering (or a different device); re-discovering", saved_host)
    if saved_udn:
        for c in await bridge.discover():
            if c.udn == saved_udn:
                log.info("recorder %s moved to %s", saved_udn, c.host)
                await set_recorder(bridge, c.host)
                return
    log.warning("no recorder configured; discovery endpoints are available")
