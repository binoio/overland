import Foundation

/// Finds the `gpclient` executable and OpenConnect's `vpnc-script` on this
/// machine. Order: explicit override, bundled copy, Homebrew (Apple Silicon,
/// Intel, and custom prefixes on `PATH`), then a Cargo build tree for
/// development.
public struct BinaryLocator: Sendable {
    public var fileExists: @Sendable (String) -> Bool
    public var isExecutable: @Sendable (String) -> Bool
    public var bundleURL: URL?
    public var searchPath: [String]
    public var workingDirectory: String

    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        bundleURL: URL? = Bundle.main.bundleURL,
        searchPath: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init),
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.fileExists = fileExists
        self.isExecutable = isExecutable
        self.bundleURL = bundleURL
        self.searchPath = searchPath
        self.workingDirectory = workingDirectory
    }

    public func candidates(named name: String, custom: String?) -> [String] {
        var candidates: [String] = []
        if let custom, !custom.isEmpty { candidates.append(custom) }

        if let bundleURL {
            candidates.append(bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path)
            candidates.append(bundleURL.appendingPathComponent("Contents/Resources/\(name)").path)
        }

        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        candidates += searchPath.map { $0 + "/\(name)" }

        // Cargo build trees when running via `swift run` from the repo.
        let cwd = URL(fileURLWithPath: workingDirectory)
        for base in [cwd, cwd.deletingLastPathComponent()] {
            candidates.append(base.appendingPathComponent("target/release/\(name)").path)
            candidates.append(base.appendingPathComponent("target/debug/\(name)").path)
        }
        return candidates
    }

    public func gpclientCandidates(custom: String?) -> [String] {
        candidates(named: "gpclient", custom: custom)
    }

    public func resolveGpclient(custom: String?) -> String? {
        gpclientCandidates(custom: custom).first(where: isExecutable)
    }

    /// gpauth is expected next to gpclient (that is where gpclient itself
    /// looks); fall back to the usual locations.
    public func resolveGpauth(gpclientPath: String?) -> String? {
        var candidates: [String] = []
        if let gpclientPath {
            candidates.append(URL(fileURLWithPath: gpclientPath).deletingLastPathComponent().appendingPathComponent("gpauth").path)
        }
        candidates += self.candidates(named: "gpauth", custom: nil)
        return candidates.first(where: isExecutable)
    }

    public func vpncScriptCandidates(custom: String?) -> [String] {
        var candidates: [String] = []
        if let custom, !custom.isEmpty { candidates.append(custom) }

        if let bundleURL {
            candidates.append(bundleURL.appendingPathComponent("Contents/Resources/vpnc-script").path)
        }

        candidates += [
            "/opt/homebrew/etc/vpnc/vpnc-script",
            "/usr/local/etc/vpnc/vpnc-script",
            "/etc/vpnc/vpnc-script"
        ]
        // Homebrew at a custom prefix: <prefix>/bin is on PATH, script is at <prefix>/etc/vpnc.
        for dir in searchPath where dir.hasSuffix("/bin") {
            let prefix = String(dir.dropLast("/bin".count))
            candidates.append(prefix + "/etc/vpnc/vpnc-script")
        }

        // The script vendored for the Linux packages, when running from the repo.
        let cwd = URL(fileURLWithPath: workingDirectory)
        for base in [cwd, cwd.deletingLastPathComponent()] {
            candidates.append(base.appendingPathComponent("packaging/files/usr/libexec/gpclient/vpnc-script").path)
        }
        return candidates
    }

    public func resolveVpncScript(custom: String?) -> String? {
        vpncScriptCandidates(custom: custom).first(where: isExecutable)
    }
}
