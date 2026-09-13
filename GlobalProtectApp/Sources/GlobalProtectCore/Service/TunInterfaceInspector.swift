import Foundation

/// Reads the point-to-point `utun` interfaces macOS creates for OpenConnect,
/// so the app can show the tunnel's assigned address without root.
public struct TunInterfaceInspector: Sendable {
    public struct Interface: Equatable, Sendable, Hashable {
        public var name: String
        public var address: String
        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    public var readIfconfig: @Sendable () -> String

    public init(readIfconfig: @escaping @Sendable () -> String = TunInterfaceInspector.runIfconfig) {
        self.readIfconfig = readIfconfig
    }

    public static let runIfconfig: @Sendable () -> String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = ["-a"]
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

    public func snapshot() -> [Interface] {
        Self.parse(readIfconfig())
    }

    /// Parse `ifconfig -a` output into utun interfaces that carry an IPv4 address.
    public static func parse(_ output: String) -> [Interface] {
        var result: [Interface] = []
        var currentName: String? = nil

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !line.hasPrefix("\t") && !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon])
                currentName = name.hasPrefix("utun") ? name : nil
                continue
            }
            guard let name = currentName else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else { continue }
            let parts = trimmed.split(separator: " ")
            if parts.count >= 2 {
                result.append(Interface(name: name, address: String(parts[1])))
            }
        }
        return result
    }

    /// The interface that appeared since `before`, if exactly one did.
    public static func newInterface(before: [Interface], after: [Interface]) -> Interface? {
        let beforeNames = Set(before.map(\.name))
        let added = after.filter { !beforeNames.contains($0.name) }
        return added.count == 1 ? added[0] : nil
    }
}
