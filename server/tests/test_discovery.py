from pathlib import Path

import httpx

from recbridge.recorder import discovery

SAMPLE = Path(__file__).resolve().parent / "fixtures" / "description.xml"


def test_parse_description_recognises_bdz():
    c = discovery.parse_description(SAMPLE.read_text(), "192.0.2.10", 64220, "http://192.0.2.10:64220/description.xml", "scan")
    assert c and c.product == "BDZ-FBT4100" and c.friendly_name == "BDR - BDZ-FBT4100" and c.epg_capable
    assert c.udn.startswith("uuid:") and c.via == "scan"


def test_parse_description_rejects_other_devices():
    xml = '<root xmlns="urn:schemas-upnp-org:device-1-0"><device><manufacturer>Sony Corporation</manufacturer><friendlyName>TV</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType></service></serviceList></device></root>'
    assert discovery.parse_description(xml, "h", 1, "loc", "ssdp") is None


async def test_probe_uses_description(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/description.xml"
        return httpx.Response(200, text=SAMPLE.read_text())
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        c = await discovery.probe("192.0.2.10", http)
    assert c and c.host == "192.0.2.10" and c.via == "manual"


async def test_discover_falls_back_to_scan(monkeypatch):
    async def no_ssdp(timeout=3.0):
        return set()

    async def fake_scan(networks, port=64220, concurrency=128, timeout=1.0):
        return ["192.0.2.10"]
    monkeypatch.setattr(discovery, "ssdp_locations", no_ssdp)
    monkeypatch.setattr(discovery, "tcp_open_hosts", fake_scan)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text=SAMPLE.read_text())
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        found = await discovery.discover(http, networks="192.0.2.0/24")
    assert [c.host for c in found] == ["192.0.2.10"] and found[0].via == "scan"


def test_port_from_didl():
    from recbridge.recorder.client import port_from_didl
    didl = ('<DIDL-Lite><item id="TUNTRD_1024"><dc:title>x</dc:title>'
            '<res protocolInfo="http-get:*:application/x-dtcp1:*">http://192.0.2.10:60151/ObjID=TUNTRD_1024_ResID=/LIVE.mpg</res></item></DIDL-Lite>')
    assert port_from_didl(didl) == 60151
    assert port_from_didl('<DIDL-Lite><container id="VideoRoot"><dc:title>ビデオ</dc:title></container></DIDL-Lite>') is None
