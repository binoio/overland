import Foundation

/// Byte and packet counters for one network interface, from `netstat -ibn`.
public struct InterfaceStatsReader: Sendable {
    public struct Counters: Equatable, Sendable {
        public var packetsIn: UInt64
        public var bytesIn: UInt64
        public var packetsOut: UInt64
        public var bytesOut: UInt64

        public init(packetsIn: UInt64 = 0, bytesIn: UInt64 = 0, packetsOut: UInt64 = 0, bytesOut: UInt64 = 0) {
            self.packetsIn = packetsIn
            self.bytesIn = bytesIn
            self.packetsOut = packetsOut
            self.bytesOut = bytesOut
        }
    }

    public var readNetstat: @Sendable () -> String

    public init(readNetstat: @escaping @Sendable () -> String = InterfaceStatsReader.runNetstat) {
        self.readNetstat = readNetstat
    }

    public static let runNetstat: @Sendable () -> String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public func counters(for interface: String) -> Counters? {
        Self.parse(readNetstat(), interface: interface)
    }

    /// `netstat -ibn` prints one row per interface/address. The `<Link#n>`
    /// row carries the interface totals:
    ///
    ///     Name  Mtu   Network  Address   Ipkts Ierrs  Ibytes Opkts Oerrs  Obytes Coll
    ///     utun6 1400  <Link#22>           1234     0  567890   999     0  123456    0
    public static func parse(_ output: String, interface: String) -> Counters? {
        for rawLine in output.split(separator: "\n") {
            let cols = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 10, cols[0] == interface, cols[2].hasPrefix("<Link#") else { continue }
            // With no address column present: Name Mtu Network Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            // With it:                          Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            let numeric = cols.dropFirst(3).compactMap { UInt64($0) }
            guard numeric.count >= 7 else { continue }
            return Counters(
                packetsIn: numeric[0],
                bytesIn: numeric[2],
                packetsOut: numeric[3],
                bytesOut: numeric[5]
            )
        }
        return nil
    }
}
