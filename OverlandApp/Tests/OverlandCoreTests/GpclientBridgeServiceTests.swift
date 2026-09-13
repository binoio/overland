import XCTest
@testable import OverlandCore

final class GpclientBridgeServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("gp-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Fixtures

    private static let samlJSON = #"{"success":{"username":"alice","preloginCookie":"abc"}}"#
    private static let isGpauth: @Sendable (CommandLine) -> Bool = { $0.executable == "/fake/gpauth" }
    private static let isDiscovery: @Sendable (CommandLine) -> Bool = { $0.arguments.contains("--cookie-only") }
    private static let isTunnel: @Sendable (CommandLine) -> Bool = {
        $0.executable == "/fake/gpclient" && $0.arguments.contains("connect") && !$0.arguments.contains("--cookie-only")
    }

    private var gpauthSuccessLines: [(ProcessStream, String)] {
        [
            (.stderr, jsonLog("INFO", "gpauth started: 2.6.5")),
            (.stderr, jsonLog("INFO", "Launching the default browser...")),
            (.stderr, jsonLog("INFO", "Please continue the authentication process in the default browser")),
            (.stderr, jsonLog("INFO", "Received the browser authentication data from the socket")),
            (.stdout, Self.samlJSON)
        ]
    }

    private var portalConfigLines: [(ProcessStream, String)] {
        [
            (.stderr, jsonLog("INFO", "gpclient started: 2.6.5")),
            (.stderr, jsonLog("INFO", "Reading cookie from standard input")),
            (.stderr, jsonLog("INFO", "Found 2 gateways in portal config")),
            (.stderr, jsonLog("INFO", "Gateway: US East (us1.vpn.example.com) priority=1")),
            (.stderr, jsonLog("INFO", "Gateway: EU Central (eu1.vpn.example.com) priority=2"))
        ]
    }

    private var tunnelUpLines: [(ProcessStream, String)] {
        portalConfigLines + [
            (.stderr, jsonLog("INFO", "Auto-gateway: attempting gateway US East (us1.vpn.example.com)")),
            (.stderr, jsonLog("INFO", "Gateway login with portal auth cookies succeeded")),
            (.stderr, jsonLog("INFO", "ESP session established with server")),
            (.stderr, jsonLog("INFO", "Connected to VPN, pipe_fd: 7")),
            (.stderr, jsonLog("INFO", "VPN session info: lifetime_secs=28800 (8h), user_expires=none, lifetime_warning_prior=300 (5m), allow_extend_session=true"))
        ]
    }

    /// The bridge snapshots interfaces once before launching the tunnel and
    /// again when gpclient reports the tunnel up; the first read returns
    /// `before`, every later read returns `after`.
    private final class IfconfigState: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var before = ""
        var after = ""

        func read() -> String {
            lock.withLock {
                reads += 1
                return reads == 1 ? before : after
            }
        }
    }

    private func makeService(
        scripts: [FakeProcessRunner.Script],
        journal: FakeProcessRunner.Journal,
        ifconfig: IfconfigState = IfconfigState(),
        gpclientAvailable: Bool = true,
        gpauthAvailable: Bool = true,
        privilegedScripts: [FakeProcessRunner.Script]? = nil,
        privilegedJournal: FakeProcessRunner.Journal? = nil
    ) -> GpclientBridgeService {
        let locator = BinaryLocator(
            fileExists: { _ in true },
            isExecutable: { path in
                switch path {
                case "/fake/gpclient": return gpclientAvailable
                case "/fake/gpauth": return gpauthAvailable
                case "/fake/vpnc-script": return true
                default: return false
                }
            },
            bundleURL: nil,
            searchPath: [],
            workingDirectory: "/nowhere"
        )
        return GpclientBridgeService(
            customGpclientPath: "/fake/gpclient",
            locator: locator,
            askpass: SudoAskpass(directory: tempDir),
            tunInspector: TunInterfaceInspector(readIfconfig: { ifconfig.read() }),
            temporaryDirectory: tempDir,
            disconnectGracePeriod: 1,
            runnerFactory: { FakeProcessRunner(scripts: scripts, journal: journal) },
            privilegedRunnerFactory: { _ in
                FakeProcessRunner(scripts: privilegedScripts ?? scripts, journal: privilegedJournal ?? journal)
            },
            orphanScanner: { [] }
        )
    }

    private func ssoProfile() -> ConnectionProfile {
        var p = ConnectionProfile(portal: "vpn.example.com", authMethod: .browserSSO)
        p.vpncScriptPath = "/fake/vpnc-script"
        return p
    }

    private func passwordProfile() -> ConnectionProfile {
        var p = ConnectionProfile(portal: "vpn.example.com", username: "alice", authMethod: .credentials)
        p.vpncScriptPath = "/fake/vpnc-script"
        return p
    }

    // MARK: Tests

    func testSSOConnectThenDisconnect() async throws {
        let journal = FakeProcessRunner.Journal()
        let ifconfig = IfconfigState()
        ifconfig.before = "utun0: flags=0 mtu 1\n\tinet 10.0.0.1 --> 10.0.0.2 netmask 0xffffffff\n"
        ifconfig.after = ifconfig.before + "utun5: flags=0 mtu 1400\n\tinet 10.250.4.18 --> 10.250.4.18 netmask 0xffffffff\n"

        let service = makeService(
            scripts: [
                .init(matches: Self.isGpauth, lines: gpauthSuccessLines),
                .init(matches: Self.isTunnel, lines: tunnelUpLines, waitForSignal: true, exitCodeAfterSignal: 0)
            ],
            journal: journal,
            ifconfig: ifconfig
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        try await service.connect(profile: ssoProfile(), password: nil)

        let connected = await recorder.wait { events in
            events.contains { if case .state(.connected) = $0 { return true } else { return false } }
        }
        XCTAssertTrue(connected, "states: \(recorder.states)")

        guard case .connected(let details)? = recorder.states.last(where: { $0.isConnected }) else {
            return XCTFail("no connected state")
        }
        XCTAssertEqual(details.gatewayServer, "us1.vpn.example.com")
        XCTAssertEqual(details.gatewayName, "US East")
        XCTAssertEqual(details.interfaceName, "utun5")
        XCTAssertEqual(details.assignedIP, "10.250.4.18")

        XCTAssertTrue(recorder.states.contains { if case .connecting(let s) = $0 { return s.contains("browser") } else { return false } })
        XCTAssertTrue(recorder.states.contains { if case .connecting(let s) = $0 { return s.contains("administrator") } else { return false } })

        let hasExpiry = await recorder.wait { events in
            events.contains { if case .state(.connected(let d)) = $0 { return d.sessionExpiresAt != nil && d.allowExtendSession } else { return false } }
        }
        XCTAssertTrue(hasExpiry)

        // Gateways are learned from the privileged phase's portal config.
        XCTAssertTrue(recorder.events.contains(.gateways([
            Gateway(name: "US East", server: "us1.vpn.example.com", priority: 1),
            Gateway(name: "EU Central", server: "eu1.vpn.example.com", priority: 2)
        ])))

        // Command shape: gpauth as the user, then gpclient with the JSON on stdin.
        XCTAssertEqual(journal.commands.count, 2)
        XCTAssertEqual(journal.commands[0].executable, "/fake/gpauth")
        XCTAssertNil(journal.commands[0].stdin)
        XCTAssertEqual(journal.commands[1].executable, "/fake/gpclient")
        XCTAssertEqual(journal.commands[1].stdin, Self.samlJSON + "\n")
        XCTAssertTrue(journal.commands[1].arguments.contains("--cookie-on-stdin"))
        XCTAssertTrue(journal.commands[1].arguments.contains("vpn.example.com"))
        XCTAssertFalse(journal.commands[1].arguments.contains("--as-gateway"))

        try await service.disconnect()
        let disconnected = await recorder.wait { $0.last == .state(.disconnected) }
        XCTAssertTrue(disconnected, "states: \(recorder.states)")
        XCTAssertEqual(journal.interrupts, 1)
        XCTAssertEqual(journal.terminates, 0)
        XCTAssertTrue(recorder.states.contains(.disconnecting))
    }

    func testAdoptsOrphanedSessionAndCanDisconnectIt() async throws {
        let journal = FakeProcessRunner.Journal()
        let orphan = PrivilegedProcessRunner.OrphanSession(
            directory: tempDir.appendingPathComponent("sessions/S1"),
            pid: 4242,
            command: ["/fake/gpclient", "--log-format", "json", "connect", "vpn.example.com", "--auto-gateway", "--cookie-on-stdin"]
        )
        let ifconfig = IfconfigState()
        ifconfig.before = "utun7: flags=0 mtu 1400\n\tinet 172.20.0.9 --> 172.20.0.9 netmask 0xffffffff\n"
        ifconfig.after = ifconfig.before
        let replay = tunnelUpLines
        let service = GpclientBridgeService(
            customGpclientPath: "/fake/gpclient",
            locator: BinaryLocator(fileExists: { _ in true }, isExecutable: { _ in true }, bundleURL: nil, searchPath: [], workingDirectory: "/x"),
            askpass: SudoAskpass(directory: tempDir),
            tunInspector: TunInterfaceInspector(readIfconfig: { ifconfig.read() }),
            temporaryDirectory: tempDir,
            disconnectGracePeriod: 1,
            orphanScanner: { [orphan] },
            adoptedRunnerFactory: { _ in
                FakeProcessRunner(scripts: [.init(matches: { _ in true }, lines: replay, waitForSignal: true, exitCodeAfterSignal: 0)], journal: journal)
            }
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        let adopted = await service.adoptOrphanedSession()
        XCTAssertTrue(adopted)

        let connected = await recorder.wait { $0.contains { if case .state(.connected) = $0 { return true } else { return false } } }
        XCTAssertTrue(connected, "states: \(recorder.states)")
        guard case .connected(let details)? = recorder.states.last(where: { $0.isConnected }) else { return XCTFail() }
        XCTAssertEqual(details.portal, "vpn.example.com")
        XCTAssertEqual(details.gatewayServer, "us1.vpn.example.com", "gateway recovered from the replayed log")
        XCTAssertEqual(details.assignedIP, "172.20.0.9", "the single utun with an IPv4 address is taken as the tunnel")
        XCTAssertTrue(recorder.logs.contains { $0.message.contains("Re-attaching") })

        // A second adoption attempt while attached is a no-op.
        let again = await service.adoptOrphanedSession()
        XCTAssertFalse(again)

        try await service.disconnect()
        let disconnected = await recorder.wait { $0.last == .state(.disconnected) }
        XCTAssertTrue(disconnected, "states: \(recorder.states)")
        XCTAssertEqual(journal.interrupts, 1)
    }

    func testNoOrphanMeansNothingAdopted() async {
        let service = makeService(scripts: [], journal: FakeProcessRunner.Journal())
        let adopted = await service.adoptOrphanedSession()
        XCTAssertFalse(adopted)
        let state = await service.currentState
        XCTAssertEqual(state, .disconnected)
    }

    func testPasswordConnectSkipsBrowserStep() async throws {
        let journal = FakeProcessRunner.Journal()
        let service = makeService(
            scripts: [.init(matches: Self.isTunnel, lines: tunnelUpLines, waitForSignal: true)],
            journal: journal
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        try await service.connect(profile: passwordProfile(), password: "pw")
        let connected = await recorder.wait { $0.contains { if case .state(.connected) = $0 { return true } else { return false } } }
        XCTAssertTrue(connected, "states: \(recorder.states)")

        XCTAssertEqual(journal.commands.count, 1)
        XCTAssertEqual(journal.commands[0].stdin, "pw\n")
        XCTAssertTrue(journal.commands[0].arguments.contains("--passwd-on-stdin"))
        try await service.disconnect()
    }

    func testSudoAskpassModeWrapsTunnelWithSudo() async throws {
        let journal = FakeProcessRunner.Journal()
        let service = makeService(
            scripts: [.init(matches: { $0.executable == "/usr/bin/sudo" }, lines: [], exitCode: 0)],
            journal: journal
        )
        var p = passwordProfile()
        p.privilegeMode = .sudoAskpass
        try await service.connect(profile: p, password: "pw")
        _ = await EventRecorderWait.settle()
        XCTAssertEqual(journal.commands.first?.executable, "/usr/bin/sudo")
        XCTAssertEqual(journal.commands.first?.environment["SUDO_ASKPASS"], tempDir.appendingPathComponent("overland-askpass.sh").path)
    }

    func testBrowserSignInFailureIsReported() async {
        let service = makeService(
            scripts: [.init(matches: Self.isGpauth, lines: [(.stdout, #"{"failure":"No auth data found"}"#)], exitCode: 1)],
            journal: FakeProcessRunner.Journal()
        )
        do {
            try await service.connect(profile: ssoProfile(), password: nil)
            XCTFail("expected failure")
        } catch let error as BridgeError {
            XCTAssertEqual(error, .authFailed("Sign-in failed: No auth data found"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        let state = await service.currentState
        XCTAssertEqual(state, .failed(message: "Sign-in failed: No auth data found"))
    }

    func testGpauthCrashWithoutResultIsReported() async {
        let service = makeService(
            scripts: [.init(matches: Self.isGpauth, lines: [(.stderr, jsonLog("ERROR", "Portal prelogin failed\n\nCaused by:\n    0: dns error"))], exitCode: 1)],
            journal: FakeProcessRunner.Journal()
        )
        do {
            try await service.connect(profile: ssoProfile(), password: nil)
            XCTFail()
        } catch let error as BridgeError {
            XCTAssertEqual(error, .authFailed("Portal prelogin failed — dns error"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAuthorizationCancelledIsReportedAsPrivilegeProblem() async throws {
        let service = makeService(
            scripts: [],
            journal: FakeProcessRunner.Journal(),
            privilegedScripts: [],
            privilegedJournal: FakeProcessRunner.Journal()
        )
        // A privileged runner that throws the cancellation error.
        let cancelling = GpclientBridgeService(
            customGpclientPath: "/fake/gpclient",
            locator: BinaryLocator(fileExists: { _ in true }, isExecutable: { _ in true }, bundleURL: nil, searchPath: [], workingDirectory: "/x"),
            askpass: SudoAskpass(directory: tempDir),
            tunInspector: TunInterfaceInspector(readIfconfig: { "" }),
            temporaryDirectory: tempDir,
            privilegedRunnerFactory: { _ in ThrowingRunner(error: PrivilegedRunError.authorizationCancelled) }
        )
        _ = service
        let recorder = EventRecorder()
        recorder.attach(await cancelling.events())
        defer { recorder.stop() }

        try await cancelling.connect(profile: passwordProfile(), password: "pw")
        let failed = await recorder.wait { events in
            events.contains { if case .state(.failed(let m)) = $0 { return m.contains("Administrator authorization") } else { return false } }
        }
        XCTAssertTrue(failed, "states: \(recorder.states)")
    }

    func testSudoDenialIsReportedAsPrivilegeProblem() async throws {
        let service = makeService(
            scripts: [.init(matches: { $0.executable == "/usr/bin/sudo" }, lines: [(.stderr, "sudo: a password is required")], exitCode: 1)],
            journal: FakeProcessRunner.Journal()
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        var p = passwordProfile()
        p.privilegeMode = .sudoAskpass
        try await service.connect(profile: p, password: "pw")

        let failed = await recorder.wait { events in
            events.contains { if case .state(.failed(let m)) = $0 { return m.contains("Administrator authorization") } else { return false } }
        }
        XCTAssertTrue(failed, "states: \(recorder.states)")
    }

    func testTunnelDropIsReportedAsFailure() async throws {
        let service = makeService(
            scripts: [.init(matches: Self.isTunnel, lines: tunnelUpLines + [(.stderr, jsonLog("ERROR", "Reconnect failed: Connection refused"))], exitCode: 2)],
            journal: FakeProcessRunner.Journal()
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        try await service.connect(profile: passwordProfile(), password: "pw")

        let failed = await recorder.wait { events in
            events.contains { if case .state(.failed(let m)) = $0 { return m.contains("Reconnect failed") } else { return false } }
        }
        XCTAssertTrue(failed, "states: \(recorder.states)")
        XCTAssertTrue(recorder.states.contains { $0.isConnected }, "it was connected before dropping")
    }

    func testWrongCredentialsBeforeTunnelIsFailure() async throws {
        let service = makeService(
            scripts: [.init(matches: Self.isTunnel, lines: [
                (.stderr, jsonLog("INFO", "gpclient started")),
                (.stderr, jsonLog("ERROR", "Portal login failed: invalid credentials"))
            ], exitCode: 1)],
            journal: FakeProcessRunner.Journal()
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        try await service.connect(profile: passwordProfile(), password: "bad")
        let failed = await recorder.wait { $0.contains { $0 == .state(.failed(message: "Portal login failed: invalid credentials")) } }
        XCTAssertTrue(failed, "states: \(recorder.states)")
    }

    func testMissingBinariesAreErrors() async {
        let noClient = makeService(scripts: [], journal: FakeProcessRunner.Journal(), gpclientAvailable: false)
        do {
            try await noClient.connect(profile: passwordProfile(), password: nil)
            XCTFail()
        } catch let error as BridgeError {
            XCTAssertEqual(error, .gpclientNotFound)
        } catch { XCTFail("unexpected \(error)") }

        let noAuth = makeService(scripts: [], journal: FakeProcessRunner.Journal(), gpauthAvailable: false)
        do {
            try await noAuth.connect(profile: ssoProfile(), password: nil)
            XCTFail()
        } catch let error as BridgeError {
            XCTAssertEqual(error, .gpauthNotFound)
        } catch { XCTFail("unexpected \(error)") }

        // Password profiles do not need gpauth.
        let pwNoAuth = makeService(scripts: [.init(matches: Self.isTunnel, lines: [], exitCode: 0)], journal: FakeProcessRunner.Journal(), gpauthAvailable: false)
        do {
            try await pwNoAuth.connect(profile: passwordProfile(), password: "pw")
        } catch {
            XCTFail("password login must not require gpauth: \(error)")
        }
    }

    func testMissingVpncScriptAndPortalAreErrors() async {
        let service = makeService(scripts: [], journal: FakeProcessRunner.Journal())
        var p = passwordProfile()
        p.vpncScriptPath = "/does/not/exist"
        do {
            try await service.connect(profile: p, password: nil)
            XCTFail()
        } catch let error as BridgeError {
            XCTAssertEqual(error, .vpncScriptNotFound)
        } catch { XCTFail("unexpected \(error)") }

        do {
            try await service.connect(profile: ConnectionProfile(portal: ""), password: nil)
            XCTFail()
        } catch let error as BridgeError {
            XCTAssertEqual(error, .portalMissing)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testDiscoverGatewaysForSSORunsGpauthThenCookieOnly() async throws {
        let journal = FakeProcessRunner.Journal()
        let service = makeService(
            scripts: [
                .init(matches: Self.isGpauth, lines: gpauthSuccessLines),
                .init(matches: Self.isDiscovery, lines: portalConfigLines + [(.stdout, "COOKIE='x'"), (.stdout, "HOST='us1.vpn.example.com'")])
            ],
            journal: journal
        )

        var p = ssoProfile()
        p.selectedGatewayServer = "eu1.vpn.example.com"
        let gateways = try await service.discoverGateways(profile: p, password: nil)

        XCTAssertEqual(gateways.map(\.server), ["us1.vpn.example.com", "eu1.vpn.example.com"])
        XCTAssertEqual(journal.commands.count, 2)
        XCTAssertEqual(journal.commands[0].executable, "/fake/gpauth")
        let args = journal.commands[1].arguments
        XCTAssertTrue(args.contains("--cookie-only"))
        XCTAssertTrue(args.contains("--cookie-on-stdin"))
        XCTAssertTrue(args.contains("--auto-gateway"), "discovery must not pin a gateway or it would prompt")
        XCTAssertEqual(journal.commands[1].stdin, Self.samlJSON + "\n")
        let state = await service.currentState
        XCTAssertEqual(state, .disconnected, "discovery restores the previous state")
    }

    func testDiscoverGatewaysForPasswordProfile() async throws {
        let journal = FakeProcessRunner.Journal()
        let service = makeService(
            scripts: [.init(matches: Self.isDiscovery, lines: portalConfigLines)],
            journal: journal
        )
        let gateways = try await service.discoverGateways(profile: passwordProfile(), password: "pw")
        XCTAssertEqual(gateways.count, 2)
        XCTAssertEqual(journal.commands.count, 1)
        XCTAssertTrue(journal.commands[0].arguments.contains("--passwd-on-stdin"))
    }

    func testDisconnectDuringBrowserSignInTerminatesGpauth() async throws {
        let journal = FakeProcessRunner.Journal()
        let service = makeService(
            scripts: [.init(matches: Self.isGpauth, lines: [(.stderr, jsonLog("INFO", "Please continue the authentication process in the default browser"))], waitForSignal: true, exitCodeAfterSignal: 1)],
            journal: journal
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        let connectProfile = ssoProfile()
        let connectTask = Task { try await service.connect(profile: connectProfile, password: nil) }
        let waiting = await recorder.wait { events in
            events.contains { if case .state(.connecting(let s)) = $0 { return s.contains("browser") } else { return false } }
        }
        XCTAssertTrue(waiting)

        try await service.disconnect()
        _ = try? await connectTask.value

        let disconnected = await recorder.wait { $0.last == .state(.disconnected) }
        XCTAssertTrue(disconnected, "states: \(recorder.states)")
        XCTAssertEqual(journal.terminates, 1)
        XCTAssertEqual(journal.commands.count, 1, "the privileged step must not start")
    }

    func testDisconnectFallsBackToTerminateWhenInterruptIgnored() async throws {
        let journal = FakeProcessRunner.Journal()
        let tunnelLines = tunnelUpLines
        let service = GpclientBridgeService(
            customGpclientPath: "/fake/gpclient",
            locator: BinaryLocator(fileExists: { _ in true }, isExecutable: { _ in true }, bundleURL: nil, searchPath: [], workingDirectory: "/x"),
            askpass: SudoAskpass(directory: tempDir),
            tunInspector: TunInterfaceInspector(readIfconfig: { "" }),
            temporaryDirectory: tempDir,
            disconnectGracePeriod: 0.3,
            privilegedRunnerFactory: { _ in
                StubbornProcessRunner(scripts: [
                    .init(matches: Self.isTunnel, lines: tunnelLines, waitForSignal: true, exitCodeAfterSignal: 0)
                ], journal: journal)
            }
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        try await service.connect(profile: passwordProfile(), password: "pw")
        _ = await recorder.wait { $0.contains { if case .state(.connected) = $0 { return true } else { return false } } }

        try await service.disconnect()
        let disconnected = await recorder.wait { $0.last == .state(.disconnected) }
        XCTAssertTrue(disconnected, "states: \(recorder.states)")
        XCTAssertEqual(journal.interrupts, 1)
        XCTAssertEqual(journal.terminates, 1)
    }
}

enum EventRecorderWait {
    static func settle() async -> Bool {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return true
    }
}

/// A runner whose `run` fails immediately with a given error.
actor ThrowingRunner: ProcessRunning {
    let error: Error
    var isRunning: Bool { false }
    init(error: Error) { self.error = error }
    func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult { throw error }
    func interrupt() {}
    func terminate() {}
}

/// Like `FakeProcessRunner` but ignores SIGINT, to exercise the terminate fallback.
actor StubbornProcessRunner: ProcessRunning {
    private let inner: FakeProcessRunner
    private let journal: FakeProcessRunner.Journal
    private var running = false

    init(scripts: [FakeProcessRunner.Script], journal: FakeProcessRunner.Journal) {
        self.inner = FakeProcessRunner(scripts: scripts, journal: journal)
        self.journal = journal
    }

    var isRunning: Bool { running }

    func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        running = true
        defer { running = false }
        return try await inner.run(command, onLine: onLine)
    }

    func interrupt() {
        journal.recordInterrupt()
    }

    func terminate() {
        Task { await inner.terminate() }
    }
}
