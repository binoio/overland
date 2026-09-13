import Foundation

/// What the privileged helper is willing to run.
///
/// The app builds the exact `gpclient` argv with `GpclientCommandBuilder`; the
/// helper does not trust it. It only executes the `gpclient` sealed inside its
/// own bundle, only the `connect`/`disconnect` subcommands, only flags from
/// `GpclientCommandBuilder.allowedTunnelFlags`, and only values that look like
/// what those flags expect. Files handed to a root process must belong to the
/// user asking.
public struct HelperRequestValidator: Sendable {
    public enum Rejection: Error, Equatable, LocalizedError {
        case wrongExecutable(String)
        case missingSubcommand
        case unknownSubcommand(String)
        case unknownFlag(String)
        case missingValue(String)
        case badHostname(String)
        case badNumber(String, String)
        case badLogFormat(String)
        case scriptNotBundled(String)
        case fileNotOwnedByCaller(String)
        case fileNotReadable(String)
        case duplicateFlag(String)

        public var errorDescription: String? {
            switch self {
            case .wrongExecutable(let p): return "refusing to run \(p): only the bundled gpclient is allowed"
            case .missingSubcommand: return "no gpclient subcommand given"
            case .unknownSubcommand(let s): return "gpclient subcommand not allowed: \(s)"
            case .unknownFlag(let f): return "gpclient flag not allowed: \(f)"
            case .missingValue(let f): return "flag \(f) needs a value"
            case .badHostname(let h): return "not a hostname: \(h)"
            case .badNumber(let f, let v): return "flag \(f) needs a number, got \(v)"
            case .badLogFormat(let v): return "unsupported log format: \(v)"
            case .scriptNotBundled(let p): return "vpnc-script must be the bundled copy, got \(p)"
            case .fileNotOwnedByCaller(let p): return "\(p) is not owned by the requesting user"
            case .fileNotReadable(let p): return "\(p) is not a readable regular file"
            case .duplicateFlag(let f): return "flag given twice: \(f)"
            }
        }
    }

    /// A validated request, safe to hand to `ProcessRunner`.
    public struct Approved: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
    }

    public struct FileInfo: Equatable, Sendable {
        public var isRegularFile: Bool
        public var ownerUID: UInt32
        public init(isRegularFile: Bool, ownerUID: UInt32) {
            self.isRegularFile = isRegularFile
            self.ownerUID = ownerUID
        }
    }

    public var gpclientPath: String
    public var vpncScriptPath: String
    /// Injectable for tests; the default stats the real file.
    public var fileInfo: @Sendable (String) -> FileInfo?

    public init(
        gpclientPath: String,
        vpncScriptPath: String,
        fileInfo: @escaping @Sendable (String) -> FileInfo? = HelperRequestValidator.statFile
    ) {
        self.gpclientPath = gpclientPath
        self.vpncScriptPath = vpncScriptPath
        self.fileInfo = fileInfo
    }

    public static let statFile: @Sendable (String) -> FileInfo? = { path in
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? UInt32.max
        return FileInfo(isRegularFile: type == .typeRegular, ownerUID: owner)
    }

    private static let hostnamePattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?(:\d{1,5})?$"#)

    /// Resolve symlinks and firmlinks (`/Applications` is one on APFS) so the
    /// same file always compares equal however it was spelled.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func validate(executable: String, arguments: [String], callerUID: UInt32) throws -> Approved {
        guard Self.canonical(executable) == Self.canonical(gpclientPath) else { throw Rejection.wrongExecutable(executable) }

        var globals: [String] = []
        var index = 0
        var seen = Set<String>()

        // Global flags precede the subcommand.
        while index < arguments.count, arguments[index].hasPrefix("--") {
            let flag = arguments[index]
            try consumeFlag(flag, arguments: arguments, index: &index, seen: &seen, callerUID: callerUID, into: &globals, globalOnly: true)
        }

        guard index < arguments.count else { throw Rejection.missingSubcommand }
        let subcommand = arguments[index]
        index += 1

        switch subcommand {
        case "disconnect":
            guard index == arguments.count else { throw Rejection.unknownFlag(arguments[index]) }
            return Approved(executable: executable, arguments: globals + ["disconnect"])
        case "connect":
            break
        default:
            throw Rejection.unknownSubcommand(subcommand)
        }

        guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw Rejection.missingValue("connect <server>") }
        let server = arguments[index]
        try Self.checkHostname(server)
        index += 1

        var rest: [String] = []
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else { throw Rejection.unknownFlag(flag) }
            try consumeFlag(flag, arguments: arguments, index: &index, seen: &seen, callerUID: callerUID, into: &rest, globalOnly: false)
        }

        return Approved(executable: executable, arguments: globals + ["connect", server] + rest)
    }

    private static let globalFlags: Set<String> = ["--log-format", "--fix-openssl", "--ignore-tls-errors"]

    private func consumeFlag(
        _ flag: String,
        arguments: [String],
        index: inout Int,
        seen: inout Set<String>,
        callerUID: UInt32,
        into out: inout [String],
        globalOnly: Bool
    ) throws {
        guard let valueCount = GpclientCommandBuilder.allowedTunnelFlags[flag] else { throw Rejection.unknownFlag(flag) }
        if globalOnly, !Self.globalFlags.contains(flag) { throw Rejection.unknownFlag(flag) }
        guard seen.insert(flag).inserted else { throw Rejection.duplicateFlag(flag) }
        index += 1
        out.append(flag)

        if flag == "--hip" {
            if index < arguments.count && !arguments[index].hasPrefix("--") {
                let value = arguments[index]
                index += 1
                guard let info = fileInfo(value), info.isRegularFile else { throw Rejection.fileNotReadable(value) }
                guard info.ownerUID == callerUID else { throw Rejection.fileNotOwnedByCaller(value) }
                out.append(value)
            }
            return
        }

        guard valueCount == 1 else { return }
        guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw Rejection.missingValue(flag) }
        let value = arguments[index]
        index += 1

        switch flag {
        case "--log-format":
            guard value == "json" || value == "text" else { throw Rejection.badLogFormat(value) }
        case "--gateway":
            try Self.checkHostname(value)
        case "--user":
            guard !value.isEmpty, value.count <= 256, !value.contains("\n") else { throw Rejection.missingValue(flag) }
        case "--mtu", "--force-dpd", "--reconnect-timeout":
            guard UInt32(value) != nil else { throw Rejection.badNumber(flag, value) }
        case "--script":
            guard Self.canonical(value) == Self.canonical(vpncScriptPath) else { throw Rejection.scriptNotBundled(value) }
        case "--certificate", "--sslkey":
            guard let info = fileInfo(value), info.isRegularFile else { throw Rejection.fileNotReadable(value) }
            guard info.ownerUID == callerUID else { throw Rejection.fileNotOwnedByCaller(value) }
        default:
            break
        }
        out.append(value)
    }

    static func checkHostname(_ value: String) throws {
        let range = NSRange(value.startIndex..., in: value)
        guard hostnamePattern.firstMatch(in: value, range: range) != nil else { throw Rejection.badHostname(value) }
    }
}
