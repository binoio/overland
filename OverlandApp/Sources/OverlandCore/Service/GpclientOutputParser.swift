import Foundation

/// Something meaningful observed in gpclient's output.
public enum GpclientEvent: Equatable, Sendable {
    case log(LogEntry)
    case cookie(String)
    case host(String)
    /// gpauth's `SamlAuthResult` JSON line (success). Carries the raw line,
    /// which is exactly what `gpclient --cookie-on-stdin` consumes.
    case authResult(String)
    case authFailure(String)
    case gatewayCount(Int)
    case gatewayDiscovered(Gateway)
    /// gpclient announced which gateway it is logging in to.
    case gatewaySelected(name: String, server: String)
    case browserLaunched
    case manualAuthURL(String)
    /// gpauth's local sign-in page (`auth server started at: <url>`).
    case signInURL(String)
    case awaitingBrowser
    case authDataReceived
    case tunnelConnected
    case sessionInfo(lifetimeSeconds: Int?, userExpires: Date?, allowExtend: Bool)
    case sessionExtended
    case sessionWarning(String)
    case fatalError(String)
}

/// Parses `gpclient --log-format json` output line by line.
///
/// Log records are `{"timestamp","level","target","message"}` objects, one per
/// line on stderr. `--cookie-only` prints `COOKIE='…'` and `HOST='…'` on
/// stdout. Anything else (sudo complaints, stray text) is surfaced as a plain
/// log entry so nothing is silently dropped.
public struct GpclientOutputParser: Sendable {
    public init() {}

    private static func parseTimestamp(_ text: String) -> Date? {
        // Foundation's parse strategy is a value type, unlike ISO8601DateFormatter.
        if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: .iso8601)
    }

    private static let gatewayRegex = try! NSRegularExpression(
        pattern: #"^Gateway: (.*) \(([^()\s]+)\) priority=(\d+)$"#
    )
    private static let gatewaySelectedRegex = try! NSRegularExpression(
        pattern: #"^(?:Connecting to the selected gateway: |Connecting to the only available gateway: |Auto-gateway: attempting gateway )(.*) \(([^()\s]+)\)$"#
    )
    private static let gatewayCountRegex = try! NSRegularExpression(
        pattern: #"^Found (\d+) gateways in portal config$"#
    )
    private static let lifetimeRegex = try! NSRegularExpression(pattern: #"lifetime_secs=(\d+)"#)
    private static let userExpiresRegex = try! NSRegularExpression(pattern: #"user_expires=(\d+)"#)
    private static let allowExtendRegex = try! NSRegularExpression(pattern: #"allow_extend_session=(true|false)"#)
    private static let manualURLRegex = try! NSRegularExpression(pattern: #"(https?://\S+)"#)

    /// Parse one line of output into zero or more events.
    public func parse(line rawLine: String) -> [GpclientEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }

        if let value = Self.quotedValue(line, prefix: "COOKIE=") {
            return [.cookie(value)]
        }
        if let value = Self.quotedValue(line, prefix: "HOST=") {
            return [.host(value)]
        }

        if line.hasPrefix("{"), let result = Self.decodeAuthResult(line) {
            return [result]
        }

        let entry: LogEntry
        if line.hasPrefix("{"), let record = Self.decodeRecord(line) {
            entry = record
        } else {
            entry = LogEntry(level: Self.heuristicLevel(for: line), message: line)
        }

        var events: [GpclientEvent] = [.log(entry)]
        events.append(contentsOf: derivedEvents(from: entry))
        return events
    }

    // MARK: - Helpers

    private static func quotedValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// gpauth prints `{"success":{…}}` or `{"failure":"…"}` on stdout.
    private static func decodeAuthResult(_ line: String) -> GpclientEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object["success"] != nil {
            return .authResult(line)
        }
        if let failure = object["failure"] as? String {
            return .authFailure(failure)
        }
        return nil
    }

    private static func decodeRecord(_ line: String) -> LogEntry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String else {
            return nil
        }
        let levelString = (object["level"] as? String ?? "INFO").uppercased()
        let level: LogLevel
        switch levelString {
        case "TRACE", "DEBUG": level = .debug
        case "WARN", "WARNING": level = .warn
        case "ERROR": level = .error
        default: level = .info
        }
        var timestamp = Date()
        if let ts = object["timestamp"] as? String {
            timestamp = parseTimestamp(ts) ?? Date()
        }
        return LogEntry(timestamp: timestamp, level: level, message: message)
    }

    private static func heuristicLevel(for line: String) -> LogLevel {
        let lower = line.lowercased()
        if lower.hasPrefix("sudo:") || lower.contains("error") || lower.contains("failed") {
            return .error
        }
        if lower.contains("warn") {
            return .warn
        }
        return .info
    }

    private func derivedEvents(from entry: LogEntry) -> [GpclientEvent] {
        let message = entry.message
        let range = NSRange(message.startIndex..., in: message)

        if let m = Self.gatewayRegex.firstMatch(in: message, range: range),
           let nameRange = Range(m.range(at: 1), in: message),
           let serverRange = Range(m.range(at: 2), in: message),
           let prioRange = Range(m.range(at: 3), in: message) {
            let name = String(message[nameRange])
            let server = String(message[serverRange])
            let priority = Int(message[prioRange]) ?? 0
            return [.gatewayDiscovered(Gateway(name: name.isEmpty ? server : name, server: server, priority: priority))]
        }

        if let m = Self.gatewaySelectedRegex.firstMatch(in: message, range: range),
           let nameRange = Range(m.range(at: 1), in: message),
           let serverRange = Range(m.range(at: 2), in: message) {
            let name = String(message[nameRange])
            let server = String(message[serverRange])
            return [.gatewaySelected(name: name.isEmpty ? server : name, server: server)]
        }

        if let m = Self.gatewayCountRegex.firstMatch(in: message, range: range),
           let countRange = Range(m.range(at: 1), in: message),
           let count = Int(message[countRange]) {
            return [.gatewayCount(count)]
        }

        if message.hasPrefix("Connected to VPN, pipe_fd") {
            return [.tunnelConnected]
        }

        if message.hasPrefix("VPN session info:") {
            return [Self.parseSessionInfo(message)]
        }

        if message == "Session extended." {
            return [.sessionExtended]
        }

        if message.hasPrefix("WARNING:") {
            return [.sessionWarning(String(message.dropFirst("WARNING:".count)).trimmingCharacters(in: .whitespaces))]
        }

        if message.hasPrefix("auth server started at: "),
           let m = Self.manualURLRegex.firstMatch(in: message, range: range),
           let urlRange = Range(m.range(at: 1), in: message) {
            return [.signInURL(String(message[urlRange]))]
        }

        if message.hasPrefix("Launching browser") || message.hasPrefix("Launching the default browser")
            || message.hasPrefix("No preferred browser found") {
            return [.browserLaunched]
        }

        if message.contains("Manual Authentication Required"),
           let m = Self.manualURLRegex.firstMatch(in: message, range: range),
           let urlRange = Range(m.range(at: 1), in: message) {
            return [.manualAuthURL(String(message[urlRange]))]
        }

        if message.hasPrefix("Please continue the authentication process") || message.hasPrefix("Listening authentication data on port") {
            return [.awaitingBrowser]
        }

        if message.hasPrefix("Received the browser authentication data") {
            return [.authDataReceived]
        }

        if entry.level == .error {
            return [.fatalError(Self.summarizeError(message))]
        }

        return []
    }

    private static let causeRegex = try! NSRegularExpression(pattern: #"^\s*\d+: (.+)$"#)

    /// anyhow renders errors as a headline plus an indented "Caused by" chain.
    /// Keep the headline and the innermost cause — that is where the DNS or
    /// TLS detail lives.
    static func summarizeError(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first else { return text }
        var rootCause: String? = nil
        for line in lines.dropFirst() {
            let range = NSRange(line.startIndex..., in: line)
            if let m = causeRegex.firstMatch(in: line, range: range), let r = Range(m.range(at: 1), in: line) {
                rootCause = String(line[r])
            }
        }
        if let rootCause, rootCause != first {
            return "\(first) — \(rootCause)"
        }
        return first
    }

    private static func parseSessionInfo(_ message: String) -> GpclientEvent {
        let range = NSRange(message.startIndex..., in: message)
        var lifetime: Int? = nil
        var expires: Date? = nil
        var allowExtend = false

        if let m = lifetimeRegex.firstMatch(in: message, range: range),
           let r = Range(m.range(at: 1), in: message) {
            lifetime = Int(message[r])
        }
        if let m = userExpiresRegex.firstMatch(in: message, range: range),
           let r = Range(m.range(at: 1), in: message),
           let epoch = TimeInterval(message[r]) {
            expires = Date(timeIntervalSince1970: epoch)
        }
        if let m = allowExtendRegex.firstMatch(in: message, range: range),
           let r = Range(m.range(at: 1), in: message) {
            allowExtend = message[r] == "true"
        }
        return .sessionInfo(lifetimeSeconds: lifetime, userExpires: expires, allowExtend: allowExtend)
    }
}
