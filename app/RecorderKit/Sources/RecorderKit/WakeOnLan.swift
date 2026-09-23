import Darwin
import Foundation
import os

/// Waking a recorder that has left the network.
///
/// A recorder in network standby answers its API, and `X_PowerControl` is the way to bring it out of that.
/// This is for the state below that: the box has dropped off the LAN entirely and answers nothing, which a
/// BDZ-FBT4100 does on its own after a while. Only a magic packet gets it back, and the recorder tells us
/// it supports one: `X_WakeupOnLAN` is `1` in its `description.xml`.
///
/// The address to send to comes from the recorder itself (`X_GetPrivateIp` gives `macAddress`), so nobody
/// has to type it in — iOS cannot read the ARP table, which is the only other place it could come from.
public enum WakeOnLan {
    /// Accepts the shapes a recorder or a person writes a MAC in: colons, hyphens, or nothing at all, in
    /// either case. Returns the lower-case colon form, or nil if it is not six bytes.
    public static func normalise(_ mac: String) -> String? {
        let digits = mac.lowercased().filter { $0.isHexDigit }
        guard digits.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2)
            .map { String(digits[digits.index(digits.startIndex, offsetBy: $0)...].prefix(2)) }
            .joined(separator: ":")
    }

    /// Six 0xFF bytes, then the MAC sixteen times over: 102 bytes.
    public static func magicPacket(for mac: String) -> Data? {
        guard let normalised = normalise(mac) else { return nil }
        let bytes = normalised.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        return Data(repeating: 0xFF, count: 6) + Data(bytes).repeated(16)
    }

    /// Where to send a packet meant for a recorder at `host`: the broadcast addresses of the subnets this
    /// device is on, which is what reaches it on the same network, then the recorder's own address and the
    /// broadcast address of its subnet, which is the only chance of reaching it from the other side of a
    /// VPN. Nothing routes 255.255.255.255, and a device on a VPN cannot work out the home subnet from its
    /// own interfaces, so both of those have to come from the recorder's address.
    ///
    /// Sending straight to the recorder's address needs something to know which machine that address
    /// belongs to: this device's ARP cache on the same network, the gateway's from the far side of a VPN.
    /// Whether a recorder that has left the network still answers ARP has not been measured -- some network
    /// cards answer for a sleeping machine, some do not. If this one does not, the unicast goes nowhere once
    /// the entry has expired, and only a broadcast from inside the LAN can wake it.
    public static func addresses(forRecorderAt host: String) -> [String] {
        var out = LocalNetwork.broadcastAddresses()
        for candidate in [LocalNetwork.broadcast(forHost: host), host].compacted() where !out.contains(candidate) {
            out.append(candidate)
        }
        return out
    }

    /// Sends the packet to every address on every port a recorder might be listening on. Returns how many
    /// sends the system accepted; anything above zero means the packet went out, which is as much as the
    /// sender can ever know — nothing answers a magic packet. With local network access refused, nothing
    /// is accepted and this is zero.
    ///
    /// A plain BSD socket with `SO_BROADCAST`, not the Network framework, which has no way to broadcast.
    /// What each destination did is logged at debug level (subsystem `RecorderKit`, category `wake`):
    /// which of the broadcasts an iPhone lets out is known from reading the kernel rather than from
    /// watching one, and the log is how to watch.
    @discardableResult
    public static func wake(_ mac: String, addresses: [String] = LocalNetwork.broadcastAddresses(),
                            ports: [UInt16] = [9, 7]) -> Int {
        guard let packet = magicPacket(for: mac) else { return 0 }
        var sent = 0
        for address in addresses {
            for port in ports where send(packet, to: address, port: port) {
                sent += 1
            }
        }
        return sent
    }

    private static let log = Logger(subsystem: "RecorderKit", category: "wake")

    private static func send(_ packet: Data, to address: String, port: UInt16) -> Bool {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else {
            failed("socket", address, port)
            return false
        }
        defer { close(handle) }

        var on: Int32 = 1
        guard setsockopt(handle, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            failed("setsockopt", address, port)
            return false
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else {
            log.debug("magic packet: \(address, privacy: .public) is not an IPv4 address")
            return false
        }

        let count = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddress in
                packet.withUnsafeBytes { bytes in
                    sendto(handle, bytes.baseAddress, bytes.count, 0, sockaddress,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard count == packet.count else {
            failed("sendto", address, port)
            return false
        }
        log.debug("magic packet: sent to \(address, privacy: .public):\(port, privacy: .public)")
        return true
    }

    /// Logs the errno the last call left, with where the packet was going. Read at once, before anything
    /// else can overwrite it.
    private static func failed(_ call: String, _ address: String, _ port: UInt16) {
        let code = errno
        let reason = String(cString: strerror(code))
        log.debug("""
            magic packet: \(call, privacy: .public) to \(address, privacy: .public):\(port, privacy: .public) \
            failed, errno \(code, privacy: .public) (\(reason, privacy: .public))
            """)
    }
}

private extension Array {
    func compacted<Wrapped>() -> [Wrapped] where Element == Wrapped? { compactMap { $0 } }
}

private extension Data {
    func repeated(_ times: Int) -> Data {
        var out = Data(capacity: count * times)
        for _ in 0..<times { out.append(self) }
        return out
    }
}
