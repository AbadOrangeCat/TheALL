import Foundation
import Darwin

/// Explicit private IPv4 selection avoids publishing on VPN/public interfaces.
struct MobileLANAddress: Identifiable, Equatable {
    let interface: String
    let address: String
    var id: String { address }
    var title: String { "\(address) (\(interface))" }

    static func isPrivate(_ value: String) -> Bool {
        guard let bytes = bytes(value) else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168)
    }
    static func isLoopback(_ value: String) -> Bool { bytes(value)?.first == 127 }
    private static func bytes(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { UInt8($0) }
        guard parts.count == 4, values.count == 4, zip(parts, values).allSatisfy({ String($0.1) == $0.0 }) else { return nil }
        return values
    }

    static func available() -> [MobileLANAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var current = interfaces, result: [MobileLANAddress] = []
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard isPrivate(address), !result.contains(where: { $0.address == address }) else { continue }
            result.append(.init(interface: String(cString: item.pointee.ifa_name), address: address))
        }
        return result.sorted { ($0.interface, $0.address) < ($1.interface, $1.address) }
    }
}
