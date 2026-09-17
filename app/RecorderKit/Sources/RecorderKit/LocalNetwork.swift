import Darwin
import Foundation

/// Which addresses to look through for a recorder.
///
/// SSDP would be the polite way to ask, but sending multicast from an iOS app needs an entitlement Apple
/// grants by request, so this looks through the subnet the device is already on instead. That is also what
/// the server falls back to here, where SSDP replies never arrive.
public enum LocalNetwork {
    public struct Interface: Sendable, Equatable {
        public var name: String
        public var address: String
        public var netmask: String
    }

    /// The device's own IPv4 interfaces, loopback and anything that is down left out.
    public static func interfaces() -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var found: [Interface] = []
        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(cursor.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = cursor.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = cursor.pointee.ifa_netmask,
                  let address = text(of: addr), let netmask = text(of: mask) else { continue }
            found.append(Interface(name: String(cString: cursor.pointee.ifa_name), address: address,
                                   netmask: netmask))
        }
        return found
    }

    /// A short description of the network this device is on at this moment: every interface that is up,
    /// with the address and mask it holds. Joining another Wi-Fi, falling back to cellular or bringing a VPN
    /// up all change it, and sitting still does not -- which is what makes it a fair thing to decide by
    /// whether reaching a recorder that did not answer is worth trying again.
    public static func signature() -> String {
        interfaces().map { "\($0.name)=\($0.address)/\($0.netmask)" }.sorted().joined(separator: ",")
    }

    /// Every host on the same subnet as `interface`, without the network and broadcast addresses or the
    /// device itself. A mask wider than `maxHosts` allows is narrowed to the addresses nearest this device,
    /// so a /16 does not turn into sixty-five thousand requests.
    public static func hosts(around interface: Interface, maxHosts: Int = 512) -> [String] {
        guard let address = packed(interface.address), let mask = packed(interface.netmask) else { return [] }
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }

        var low = network + 1
        var high = broadcast - 1
        if Int(high - low) + 1 > maxHosts {
            let half = UInt32(maxHosts / 2)
            low = max(network + 1, address > half ? address - half : network + 1)
            high = min(broadcast - 1, address &+ half)
        }
        return (low...high).compactMap { $0 == address ? nil : dotted($0) }
    }

    /// The addresses worth trying, nearest interface first.
    public static func hostsToScan(maxHosts: Int = 512) -> [String] {
        interfaces().flatMap { hosts(around: $0, maxHosts: maxHosts) }
    }

    /// Where to send something that everything on the subnet should hear. The subnet's own broadcast
    /// address first, since a router is likelier to pass that than the all-ones one, and 255.255.255.255
    /// after it for the case where the netmask could not be read.
    public static func broadcastAddresses() -> [String] {
        var out: [String] = []
        for interface in interfaces() {
            guard let address = packed(interface.address), let mask = packed(interface.netmask) else {
                continue
            }
            let broadcast = dotted((address & mask) | ~mask)
            if !out.contains(broadcast) { out.append(broadcast) }
        }
        out.append("255.255.255.255")
        return out
    }

    /// The broadcast address of the subnet another host is on, read from its address alone. The mask is a
    /// guess — /24, which is what a home network is — because the only thing that knows the real one is the
    /// network this device is not on. For reaching a recorder from the other side of a VPN, where this
    /// device's own interfaces say nothing about the subnet the recorder lives in.
    public static func broadcast(forHost host: String) -> String? {
        guard let address = packed(host) else { return nil }
        return dotted(address | 0xFF)
    }

    private static func text(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        guard inet_ntop(AF_INET, &sin, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    static func packed(_ dotted: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, dotted, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func dotted(_ packed: UInt32) -> String {
        "\(packed >> 24 & 0xFF).\(packed >> 16 & 0xFF).\(packed >> 8 & 0xFF).\(packed & 0xFF)"
    }
}
