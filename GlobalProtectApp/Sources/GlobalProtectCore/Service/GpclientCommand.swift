import Foundation

/// A fully resolved command line ready to hand to a `ProcessRunning`.
public struct CommandLine: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var stdin: String?

    public init(executable: String, arguments: [String], environment: [String: String] = [:], stdin: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stdin = stdin
    }

    /// A shell-ish rendering for logs. Secrets on stdin are never included.
    public var displayString: String {
        ([executable] + arguments).map { arg in
            arg.contains(" ") ? "'\(arg)'" : arg
        }.joined(separator: " ")
    }
}

/// Builds `gpclient` / `gpauth` invocations from a `ConnectionProfile`.
///
/// A connection is split the way the CLI documents it for SAML portals:
///
///   1. `gpauth <portal> --browser …` runs as the user, drives the browser
///      login and prints one JSON `SamlAuthResult` line on stdout.
///   2. `gpclient connect <portal> --cookie-on-stdin …` runs as root, reads
///      that JSON, retrieves the portal config (which lists the gateways),
///      logs in to the gateway and opens the tunnel.
///
/// Password and certificate logins need no browser, so they skip step 1 and
/// hand the credentials to the privileged gpclient directly.
///
/// Every flag is placed where clap expects it: `--fix-openssl`,
/// `--ignore-tls-errors` and `--log-format` are global and must precede the
/// `connect` subcommand.
public struct GpclientCommandBuilder: Sendable {
    public var gpclientPath: String
    public var gpauthPath: String
    public var sudoPath: String
    public var askpassPath: String?
    /// Directory `gpauth` uses for `gpcallback.port`; forwarded as `TMPDIR`
    /// so the app knows where to find it when the browser callback arrives.
    public var tempDirectory: String?

    public init(
        gpclientPath: String,
        gpauthPath: String,
        sudoPath: String = "/usr/bin/sudo",
        askpassPath: String? = nil,
        tempDirectory: String? = nil
    ) {
        self.gpclientPath = gpclientPath
        self.gpauthPath = gpauthPath
        self.sudoPath = sudoPath
        self.askpassPath = askpassPath
        self.tempDirectory = tempDirectory
    }

    /// Whether the profile needs the unprivileged browser step.
    public static func needsBrowserAuth(_ profile: ConnectionProfile) -> Bool {
        profile.authMethod == .browserSSO
    }

    private func globalFlags(for profile: ConnectionProfile) -> [String] {
        var flags = ["--log-format", "json"]
        if profile.fixOpenSSL { flags.append("--fix-openssl") }
        if profile.ignoreTLSErrors { flags.append("--ignore-tls-errors") }
        return flags
    }

    private func certificateFlags(for profile: ConnectionProfile) -> [String] {
        var flags: [String] = []
        if let cert = profile.certificatePath, !cert.isEmpty {
            flags += ["--certificate", cert]
        }
        if let key = profile.sslKeyPath, !key.isEmpty {
            flags += ["--sslkey", key]
        }
        return flags
    }

    private func gatewaySelectionFlags(for profile: ConnectionProfile) -> [String] {
        if profile.asGateway {
            return ["--as-gateway"]
        }
        if let gateway = profile.selectedGatewayServer, !gateway.isEmpty {
            return ["--gateway", gateway]
        }
        // Without a TTY gpclient cannot show its interactive gateway picker.
        return ["--auto-gateway"]
    }

    /// Credential flags for a non-browser login, plus what goes on stdin.
    private func credentialFlags(for profile: ConnectionProfile, password: String?) -> (flags: [String], stdin: String?) {
        var flags: [String] = []
        var stdin: String? = nil
        switch profile.authMethod {
        case .credentials:
            if !profile.username.isEmpty {
                flags += ["--user", profile.username]
            }
            if let password, !password.isEmpty {
                flags.append("--passwd-on-stdin")
                stdin = password + "\n"
            }
        case .clientCertificate:
            if !profile.username.isEmpty {
                flags += ["--user", profile.username]
            }
        case .browserSSO:
            break
        }
        return (flags, stdin)
    }

    private func baseEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        if let tmp = tempDirectory { env["TMPDIR"] = tmp }
        return env
    }

    // MARK: Phase 1 — browser login (unprivileged)

    /// `gpauth`: opens the browser, waits for the SAML callback, prints the
    /// `SamlAuthResult` JSON that gpclient's `--cookie-on-stdin` consumes.
    public func browserAuthCommand(profile: ConnectionProfile) -> CommandLine {
        var args = globalFlags(for: profile)
        args.append(profile.portal)
        if profile.asGateway {
            args.append("--gateway")
        }
        args += ["--browser", profile.browserMode.rawValue]
        args += certificateFlags(for: profile)
        return CommandLine(executable: gpauthPath, arguments: args, environment: baseEnvironment())
    }

    // MARK: Gateway discovery (unprivileged)

    /// `gpclient connect --cookie-only`: full portal login with no tunnel and
    /// no root; the portal config it retrieves lists every gateway.
    /// `authResult` is the gpauth JSON for SSO profiles, nil otherwise.
    public func discoveryCommand(profile: ConnectionProfile, password: String?, authResult: String?) -> CommandLine {
        var args = globalFlags(for: profile)
        args += ["connect", profile.portal, "--cookie-only", "--auto-gateway"]
        var stdin: String? = nil
        if let authResult {
            args.append("--cookie-on-stdin")
            stdin = authResult + "\n"
        } else {
            let cred = credentialFlags(for: profile, password: password)
            args += cred.flags
            stdin = cred.stdin
        }
        args += certificateFlags(for: profile)
        return CommandLine(executable: gpclientPath, arguments: args, environment: baseEnvironment(), stdin: stdin)
    }

    // MARK: Phase 2 — tunnel (privileged)

    /// The privileged `gpclient connect`. `authResult` is the gpauth JSON for
    /// SSO profiles; password/certificate profiles pass their credentials here.
    /// The result is *not* yet wrapped for privilege escalation — see `escalate`.
    public func tunnelCommand(profile: ConnectionProfile, password: String?, authResult: String?) -> CommandLine {
        var args = globalFlags(for: profile)
        args += ["connect", profile.portal]
        args += gatewaySelectionFlags(for: profile)

        var stdin: String? = nil
        if let authResult {
            args.append("--cookie-on-stdin")
            stdin = authResult + "\n"
        } else {
            let cred = credentialFlags(for: profile, password: password)
            args += cred.flags
            stdin = cred.stdin
        }
        args += certificateFlags(for: profile)

        if let script = profile.vpncScriptPath, !script.isEmpty {
            args += ["--script", script]
        }
        if profile.enableHIP {
            args.append("--hip")
        }
        if profile.disableIPv6 { args.append("--disable-ipv6") }
        if profile.noDTLS { args.append("--no-dtls") }
        if profile.mtu > 0 { args += ["--mtu", String(profile.mtu)] }
        if profile.forceDPD > 0 { args += ["--force-dpd", String(profile.forceDPD)] }
        if profile.reconnectTimeout > 0 && profile.reconnectTimeout != 300 {
            args += ["--reconnect-timeout", String(profile.reconnectTimeout)]
        }

        return CommandLine(executable: gpclientPath, arguments: args, environment: baseEnvironment(), stdin: stdin)
    }

    /// `gpclient disconnect` signals whichever gpclient owns the lock file.
    public func disconnectCommand(profile: ConnectionProfile) -> CommandLine {
        CommandLine(executable: gpclientPath, arguments: ["disconnect"], environment: baseEnvironment())
    }

    /// Wrap `command` with sudo according to `mode`. `.adminPrompt` and
    /// `.direct` leave the command untouched: the former is executed by
    /// `PrivilegedProcessRunner`, the latter needs no escalation.
    public func escalate(_ command: CommandLine, mode: PrivilegeMode) -> CommandLine {
        switch mode {
        case .direct, .adminPrompt:
            return command
        case .sudoNonInteractive:
            return CommandLine(
                executable: sudoPath,
                arguments: ["-n", "--", command.executable] + command.arguments,
                environment: command.environment,
                stdin: command.stdin
            )
        case .sudoAskpass:
            var env = command.environment
            if let askpassPath { env["SUDO_ASKPASS"] = askpassPath }
            return CommandLine(
                executable: sudoPath,
                arguments: ["-A", "--", command.executable] + command.arguments,
                environment: env,
                stdin: command.stdin
            )
        }
    }
}
