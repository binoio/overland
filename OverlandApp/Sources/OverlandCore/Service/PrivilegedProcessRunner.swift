import Foundation

/// Quoting helpers, kept separate so they can be unit-tested.
public enum ShellQuoting {
    /// Single-quote `s` for POSIX `sh`.
    public static func posix(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func posixCommand(_ words: [String]) -> String {
        words.map(posix).joined(separator: " ")
    }

    /// Escape `s` for use inside an AppleScript string literal.
    public static func appleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum PrivilegedRunError: Error, LocalizedError, Equatable {
    case authorizationCancelled
    case authorizationFailed(String)
    case launchTimeout

    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled:
            return "Administrator authorization was cancelled."
        case .authorizationFailed(let detail):
            return "Administrator authorization failed: \(detail)"
        case .launchTimeout:
            return "The privileged gpclient did not start in time."
        }
    }
}

/// Runs one command as root using macOS's own administrator authorization
/// dialog (`osascript … with administrator privileges`, i.e. the same
/// Security Agent prompt installers use, with Touch ID where enabled).
///
/// `do shell script` is synchronous and captures output, which does not suit
/// a tunnel that lives for hours. So what runs under authorization is a tiny
/// root-side wrapper that returns at once after detaching a supervisor; the
/// supervisor runs the real command, mirrors its output to a log file, and
/// listens on a FIFO for `stop`/`kill`. This actor
/// tails the log to stream lines back, and `interrupt()`/`terminate()` write
/// to the FIFO — the app itself never needs root, and a cancelled dialog is
/// reported as `authorizationCancelled`.
///
/// Per-run state lives in a 0700 session directory under the app's
/// Application Support folder. Anything handed to the command on stdin (the
/// SAML result or a password) is written there 0600 and unlinked by the
/// wrapper the moment the command has been spawned.
public actor PrivilegedProcessRunner: ProcessRunning {
    public static let wrapperScript = """
    #!/bin/bash
    # Overland: root-side launcher.
    # Usage: overland-privileged-wrapper.sh <session-dir> <executable> [args…]
    #
    # Detaches a supervisor that runs the command with stdin from
    # <session>/stdin.txt (deleted right after spawn), appends its output to
    # <session>/tunnel.log, relays "stop" (SIGINT) / "kill" (SIGTERM) read from
    # <session>/control.fifo, and writes the exit status to <session>/exit.
    #
    # This script itself returns immediately so `do shell script` completes.
    # Job control (set -m) matters: without it a shell starts background jobs
    # with SIGINT ignored, and gpclient would inherit that and never see the
    # disconnect request.
    SESSION="$1"; shift
    LOG="$SESSION/tunnel.log"
    STDIN_FILE="$SESSION/stdin.txt"
    [ -f "$STDIN_FILE" ] || STDIN_FILE=/dev/null

    : >> "$LOG"
    chmod 644 "$LOG"

    set -m
    (
      set -m
      # Drop every descriptor inherited from the launcher: the supervisor
      # outlives it and must not keep its pipes or sockets alive.
      fd=3
      while [ "$fd" -le 255 ]; do eval "exec $fd>&-"; fd=$((fd + 1)); done
      # Hold the control FIFO open before the child exists, so the app can
      # write to it as soon as it sees the pid file.
      exec 3<> "$SESSION/control.fifo"
      (
        /bin/sh -c 'echo $$ > "$0/pid"; exec "$@"' "$SESSION" "$@" < "$STDIN_FILE" >> "$LOG" 2>&1 3>&-
        echo $? > "$SESSION/exit.tmp"
        mv "$SESSION/exit.tmp" "$SESSION/exit"
      ) &

      # Give the child a moment to open its stdin, then remove the secret.
      sleep 0.2
      rm -f "$SESSION/stdin.txt"

      while [ ! -f "$SESSION/exit" ] && [ -d "$SESSION" ]; do
        if read -t 1 -u 3 cmd; then
          PID="$(cat "$SESSION/pid" 2>/dev/null)"
          [ -n "$PID" ] || continue
          case "$cmd" in
            stop) kill -INT "$PID" 2>/dev/null ;;
            kill) kill -TERM "$PID" 2>/dev/null ;;
          esac
        fi
      done
      exec 3>&-
    ) > /dev/null 2>&1 < /dev/null &
    disown
    exit 0

    """

    /// A privileged session whose supervisor is still alive but whose app
    /// process is gone (the app quit or crashed while connected).
    public struct OrphanSession: Equatable, Sendable {
        public var directory: URL
        public var pid: Int32
        /// The command that was launched, as recorded by `prepareSession`.
        public var command: [String]

        public init(directory: URL, pid: Int32, command: [String]) {
            self.directory = directory
            self.pid = pid
            self.command = command
        }

        /// The portal or gateway `gpclient connect` was given, if recognisable.
        public var server: String? {
            guard let i = command.firstIndex(of: "connect"), i + 1 < command.count else { return nil }
            return command[i + 1]
        }
    }

    public static let defaultSessionsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Overland/sessions", isDirectory: true)
    }()

    /// Sessions under `directory` whose command is still running.
    public static func findOrphans(in directory: URL = defaultSessionsDirectory) -> [OrphanSession] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var result: [OrphanSession] = []
        for session in entries {
            guard !fm.fileExists(atPath: session.appendingPathComponent("exit").path),
                  let pidText = try? String(contentsOf: session.appendingPathComponent("pid"), encoding: .utf8),
                  let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  processIsAlive(pid) else { continue }
            let command = (try? String(contentsOf: session.appendingPathComponent("command.txt"), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            result.append(OrphanSession(directory: session, pid: pid, command: command))
        }
        return result.sorted { $0.directory.lastPathComponent < $1.directory.lastPathComponent }
    }

    /// `kill(pid, 0)` succeeds for our own processes and fails with EPERM for
    /// root's — either way the process exists.
    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public var sessionsDirectory: URL
    public var osascriptPath: String
    public var prompt: String
    public var pollInterval: TimeInterval
    public var launchTimeout: TimeInterval
    /// How the osascript process itself is launched (injectable for tests).
    private let makeRunner: @Sendable () -> any ProcessRunning

    private var currentSession: URL?
    private var running = false

    public init(
        sessionsDirectory: URL? = nil,
        osascriptPath: String = "/usr/bin/osascript",
        prompt: String = "Overland needs administrator privileges to start the VPN tunnel.",
        pollInterval: TimeInterval = 0.15,
        launchTimeout: TimeInterval = 20,
        runnerFactory: @escaping @Sendable () -> any ProcessRunning = { ProcessRunner() }
    ) {
        self.sessionsDirectory = sessionsDirectory ?? Self.defaultSessionsDirectory
        self.osascriptPath = osascriptPath
        self.prompt = prompt
        self.pollInterval = pollInterval
        self.launchTimeout = launchTimeout
        self.makeRunner = runnerFactory
    }

    public var isRunning: Bool { running }

    public var wrapperURL: URL {
        sessionsDirectory.deletingLastPathComponent().appendingPathComponent("overland-privileged-wrapper.sh")
    }

    // MARK: - Setup (pure enough to test without root)

    /// Create the session directory, secrets file, FIFO and wrapper script.
    public func prepareSession(for command: CommandLine) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsDirectory.path)

        let session = sessionsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        if let stdin = command.stdin {
            let stdinURL = session.appendingPathComponent("stdin.txt")
            try stdin.write(to: stdinURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stdinURL.path)
        }

        // Recorded so an orphaned session can be identified after a restart.
        try ([command.executable] + command.arguments).joined(separator: "\n")
            .write(to: session.appendingPathComponent("command.txt"), atomically: true, encoding: .utf8)

        let fifo = session.appendingPathComponent("control.fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "mkfifo failed: \(String(cString: strerror(errno)))"])
        }

        let existing = try? String(contentsOf: wrapperURL, encoding: .utf8)
        if existing != Self.wrapperScript {
            try Self.wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)

        return session
    }

    /// The `osascript` invocation that shows the authorization dialog and
    /// starts the wrapper detached.
    public func osascriptCommand(session: URL, command: CommandLine) -> CommandLine {
        // Run the wrapper in the foreground: it detaches its own supervisor. A
        // trailing `&` here would hand the whole tree SIGINT=ignored.
        let words = ["/bin/bash", wrapperURL.path, session.path, command.executable] + command.arguments
        let shell = ShellQuoting.posixCommand(words)
        let script = "do shell script \"\(ShellQuoting.appleScript(shell))\" with prompt \"\(ShellQuoting.appleScript(prompt))\" with administrator privileges"
        return CommandLine(executable: osascriptPath, arguments: ["-e", script])
    }

    // MARK: - ProcessRunning

    public func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        let session = try prepareSession(for: command)
        currentSession = session
        running = true
        defer { detach(from: session) }

        let launcher = makeRunner()
        let result = try await launcher.run(osascriptCommand(session: session, command: command), onLine: nil)
        if !result.isSuccess {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("User canceled") || detail.contains("-128") {
                throw PrivilegedRunError.authorizationCancelled
            }
            throw PrivilegedRunError.authorizationFailed(detail.isEmpty ? "osascript exited with \(result.exitCode)" : detail)
        }

        // Wait for the wrapper to spawn the command.
        let pidURL = session.appendingPathComponent("pid")
        let exitURL = session.appendingPathComponent("exit")
        let deadline = Date().addingTimeInterval(launchTimeout)
        while !FileManager.default.fileExists(atPath: pidURL.path), !FileManager.default.fileExists(atPath: exitURL.path) {
            if Date() > deadline { throw PrivilegedRunError.launchTimeout }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        return try await tail(session: session, onLine: onLine)
    }

    /// Re-attach to a session started by a previous app process: replay its
    /// log so far, keep streaming it, and report the exit status when the
    /// command ends. `interrupt()`/`terminate()` work as for a fresh run.
    public func adopt(_ orphan: OrphanSession, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        let session = orphan.directory
        currentSession = session
        running = true
        defer { detach(from: session) }
        return try await tail(session: session, onLine: onLine)
    }

    /// Stop tracking `session`. Its directory is removed only once the
    /// command has exited (or never started); if the tail was cancelled while
    /// the command is still running, the session stays on disk so a later
    /// app process can adopt it.
    private func detach(from session: URL) {
        running = false
        currentSession = nil
        let fm = FileManager.default
        let exited = fm.fileExists(atPath: session.appendingPathComponent("exit").path)
        let started = fm.fileExists(atPath: session.appendingPathComponent("pid").path)
        if exited || !started {
            try? fm.removeItem(at: session)
        }
    }

    /// Tail the log until the exit file appears and the log is drained.
    private func tail(session: URL, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        let exitURL = session.appendingPathComponent("exit")
        let logURL = session.appendingPathComponent("tunnel.log")
        let buffer = LineBuffer()
        var offset: UInt64 = 0
        var finished = false
        while true {
            if let handle = try? FileHandle(forReadingFrom: logURL) {
                try? handle.seek(toOffset: offset)
                let data = handle.readDataToEndOfFile()
                try? handle.close()
                if !data.isEmpty {
                    offset += UInt64(data.count)
                    for line in buffer.append(data) {
                        onLine?(.stderr, line)
                    }
                }
            }
            if finished { break }
            if FileManager.default.fileExists(atPath: exitURL.path) {
                finished = true   // one more pass to drain what was written just before exit
                continue
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        for line in buffer.flush() {
            onLine?(.stderr, line)
        }

        let exitText = (try? String(contentsOf: exitURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProcessResult(exitCode: Int32(exitText) ?? -1, stdout: "", stderr: buffer.text)
    }

    public func interrupt() {
        sendControl("stop")
    }

    public func terminate() {
        sendControl("kill")
    }

    private func sendControl(_ word: String) {
        guard let session = currentSession else { return }
        let fifo = session.appendingPathComponent("control.fifo").path
        // The supervisor holds the FIFO open read/write, so a non-blocking open
        // succeeds once it is up; retry briefly in case it is still starting.
        var fd: Int32 = -1
        for _ in 0..<40 {
            fd = open(fifo, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { break }
            usleep(50_000)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((word + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}
