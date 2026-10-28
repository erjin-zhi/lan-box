import Foundation
import IOKit.ps
import SystemConfiguration

/// 一个可供局域网访问的本机 IPv4 地址。
struct NetInterface: Hashable, Identifiable {
    let bsdName: String
    let displayName: String
    let address: String
    var id: String { "\(bsdName)-\(address)" }
}

enum NetworkInfo {
    private static let ignoredPrefixes = ["utun", "awdl", "llw", "anpi", "gif", "stf", "ipsec", "ppp", "ap"]

    static func interfaces() -> [NetInterface] {
        var displayNames: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for item in all {
                if let bsd = SCNetworkInterfaceGetBSDName(item) as String?,
                   let name = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? {
                    displayNames[bsd] = name
                }
            }
        }

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [NetInterface] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            if ignoredPrefixes.contains(where: { name.hasPrefix($0) }) { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if address.hasPrefix("169.254.") { continue }

            result.append(NetInterface(bsdName: name, displayName: displayNames[name] ?? name, address: address))
        }
        return result.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ i: NetInterface) -> Int {
        if i.bsdName == "en0" { return 0 }
        if i.bsdName.hasPrefix("en") { return 1 }
        if i.bsdName.hasPrefix("bridge") { return 3 }
        return 2
    }

    /// 例如 “alexzhao-MacBook-Pro.local”
    static var bonjourHostName: String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else { return nil }
        return name + ".local"
    }

    /// 例如 “eb1xss 的 MacBook Pro”
    static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? { return name }
        return Host.current().localizedName ?? "Mac"
    }

    static var isLaptop: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }
    }
}
