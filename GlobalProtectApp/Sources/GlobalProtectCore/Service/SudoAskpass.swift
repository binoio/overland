import Foundation

/// Installs the helper `sudo -A` runs to collect the administrator password.
///
/// The helper shows a native password sheet through `osascript` and prints the
/// result; sudo reads it from stdout. Cancelling the dialog makes osascript
/// exit non-zero, so sudo fails instead of retrying.
public struct SudoAskpass: Sendable {
    public static let scriptBody = """
    #!/bin/sh
    # GlobalProtect for macOS: SUDO_ASKPASS helper.
    # Presents a native password dialog and prints the password for sudo.
    exec /usr/bin/osascript <<'APPLESCRIPT'
    set promptText to "GlobalProtect needs administrator privileges to start the VPN tunnel (OpenConnect must create the utun device).\\n\\nEnter your macOS password:"
    set dialogResult to display dialog promptText default answer "" with hidden answer with title "GlobalProtect" with icon caution buttons {"Cancel", "OK"} default button "OK"
    return text returned of dialogResult
    APPLESCRIPT

    """

    public var directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("GlobalProtect", isDirectory: true)
        }
    }

    public var scriptURL: URL {
        directory.appendingPathComponent("gp-askpass.sh")
    }

    /// Write the helper if missing or stale, mark it owner-executable only,
    /// and return its path.
    @discardableResult
    public func install() throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try? String(contentsOf: scriptURL, encoding: .utf8)
        if existing != Self.scriptBody {
            try Self.scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }
}
