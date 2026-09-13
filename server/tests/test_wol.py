import pytest

from bdzbridge.recorder.wol import magic_packet, normalize_mac


def test_magic_packet_layout():
    pkt = magic_packet("f8:4e:17:00:00:00")
    assert len(pkt) == 102 and pkt[:6] == b"\xff" * 6 and pkt[6:12] == bytes.fromhex("f84e17000000") and pkt[96:] == pkt[6:12]
    with pytest.raises(ValueError):
        magic_packet("12:34")


def test_normalize_mac_from_arp_output():
    assert normalize_mac("? (192.0.2.63) at f8:4e:17:00:00:00 on en0 ifscope [ethernet]") == "f8:4e:17:00:00:00"
    assert normalize_mac("192.0.2.63 dev eth0 lladdr F8:4E:17:00:00:00 REACHABLE") == "f8:4e:17:00:00:00"
    assert normalize_mac("192.0.2.63 (incomplete)") is None
