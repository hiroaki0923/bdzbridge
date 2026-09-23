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
        /// Whether the interface has neighbours to broadcast to (`IFF_BROADCAST`): Wi-Fi or Ethernet. Cellular
        /// (`pdp_ip`) and VPN tunnels (`utun`) are point-to-point links and do not.
        public var broadcasts: Bool

        /// True for a network the recorder could be sitting on beside this device. Cellular and VPN tunnels
        /// are left out by name as well as by the flag, because what they would add is worse than nothing:
        /// a /32 on `pdp_ip` put this device's own address among the places to broadcast to, and the
        /// local network permission is never asked about on either, so a check aimed there says yes.
        public var isLAN: Bool {
            broadcasts && !Self.tunnelPrefixes.contains { name.hasPrefix($0) }
        }

        private static let tunnelPrefixes = ["pdp_ip", "utun", "ipsec"]
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
                                   netmask: netmask, broadcasts: flags & IFF_BROADCAST != 0))
        }
        return found
    }

    /// A short description of the network this device is on at this moment: every interface that is up,
    /// with the address and mask it holds. Joining another Wi-Fi, falling back to cellular or bringing a VPN
    /// up all change it, and sitting still does not -- which is what makes it a fair thing to decide by
    /// whether reaching a recorder that did not answer is worth trying again.
    ///
    /// Cellular is left out. The carrier hands out a new address whenever it likes, at home on the Wi-Fi as
    /// much as anywhere, and a recorder is never reached through it: what matters about cellular is the
    /// Wi-Fi going, and that changes the Wi-Fi's part. Counting it had a phone lying on the table spend half
    /// a minute waking a recorder the app had given up on, each time the carrier moved it.
    public static func signature() -> String {
        signature(of: interfaces())
    }

    static func signature(of interfaces: [Interface]) -> String {
        interfaces.filter { !$0.name.hasPrefix("pdp_ip") }
            .map { "\($0.name)=\($0.address)/\($0.netmask)" }.sorted().joined(separator: ",")
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

    /// The interfaces a recorder could be found on: Wi-Fi, or Ethernet on a Mac. Empty when this device is
    /// on cellular alone, or reaches home only through a VPN, which is when a scan has nothing to look at.
    public static func lanInterfaces() -> [Interface] {
        interfaces().filter(\.isLAN)
    }

    /// The addresses worth trying, nearest interface first. Only the LAN ones: the subnet of a VPN tunnel is
    /// the tunnel's own, not the home network the recorder is on.
    public static func hostsToScan(maxHosts: Int = 512) -> [String] {
        lanInterfaces().flatMap { hosts(around: $0, maxHosts: maxHosts) }
    }

    /// The addresses to look through for a recorder last seen at `host`: the subnet of each interface that
    /// `host` belongs to, and nothing when it belongs to none. A router hands a lease out again within its
    /// own subnet, so that is where the recorder has gone if it has moved. On any other network -- away from
    /// home, a café's Wi-Fi, a VPN whose tunnel is not among `interfaces` -- the recorder is not there to be
    /// found, and knocking on every address of somebody else's LAN is not this app's business.
    public static func hostsToScan(near host: String, on interfaces: [Interface] = lanInterfaces(),
                                   maxHosts: Int = 512) -> [String] {
        guard let target = packed(host) else { return [] }
        var out: [String] = []
        for interface in interfaces {
            guard let address = packed(interface.address), let mask = packed(interface.netmask),
                  address & mask == target & mask else { continue }
            for candidate in hosts(around: interface, maxHosts: maxHosts) where !out.contains(candidate) {
                out.append(candidate)
            }
        }
        return out
    }

    /// Somebody else on the interface's subnet, to aim the local network check at (see `waitForAccess`):
    /// the first address of the subnet, which is usually the router, or the second when that is this
    /// device. Whether anything answers there does not matter; the check reads the path, not a reply.
    public static func neighbour(on interface: Interface) -> String? {
        guard let address = packed(interface.address), let mask = packed(interface.netmask) else { return nil }
        let network = address & mask
        let broadcast = network | ~mask
        return [network &+ 1, network &+ 2]
            .first { $0 > network && $0 < broadcast && $0 != address }
            .map(dotted)
    }

    /// Where to send something that everything on the subnet should hear: the broadcast address of each
    /// LAN interface's subnet, then 255.255.255.255.
    ///
    /// The subnet's own address comes first because, as far as the kernel's source says, it is the one an
    /// iPhone app may send to. Apple's documentation says broadcasting needs the multicast entitlement,
    /// which this app does not have, but the check that enforces it (`necp_check_restricted_multicast_drop`
    /// in xnu's bsd/net/necp.c) drops only 224.0.0.0/4 and the all-ones address, and a subnet broadcast
    /// arriving has been reported on Apple's forums. So 255.255.255.255 is expected to fail on an iPhone,
    /// with EHOSTUNREACH, every time. It is sent anyway, because it costs nothing and a Mac lets it
    /// through; `WakeOnLan` logs what each destination did, which is how a real iPhone settles it.
    public static func broadcastAddresses() -> [String] {
        var out: [String] = []
        for interface in lanInterfaces() {
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
