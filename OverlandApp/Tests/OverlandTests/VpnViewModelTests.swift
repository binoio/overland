import XCTest
@testable import Overland
@testable import OverlandCore

@MainActor
final class VpnViewModelTests: XCTestCase {
    private func makeViewModel(
        bridge: BridgeServiceProtocol? = nil,
        storage: VpnViewModelStorage = .ephemeral(),
        stats: InterfaceStatsReader = InterfaceStatsReader(readNetstat: { "" })
    ) -> VpnViewModel {
        VpnViewModel(
            bridge: bridge ?? MockBridgeService(stepDelayNanoseconds: 0),
            storage: storage,
            statsReader: stats,
            mockBridge: MockBridgeService(stepDelayNanoseconds: 0)
        )
    }

    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.state.isConnected)
        XCTAssertEqual(vm.selectedTab, .connection)
        XCTAssertTrue(vm.gateways.isEmpty)
        XCTAssertFalse(vm.useMockBridge, "real backend is the default")
    }

    func testConnectAndDisconnectThroughMockBridge() async {
        let vm = makeViewModel()
        vm.profile.portal = "vpn.example.com"

        vm.connect()
        let ok1 = await eventually { vm.state.isConnected }
        XCTAssertTrue(ok1, "state: \(vm.state)")
        XCTAssertEqual(vm.gateways.count, MockBridgeService.sampleGateways.count, "gateways learned during login are kept")
        XCTAssertFalse(vm.logs.isEmpty)

        vm.disconnect()
        let ok2 = await eventually { vm.state.isDisconnected }
        XCTAssertTrue(ok2)
        XCTAssertEqual(vm.metrics, SessionMetrics())
    }

    func testToggleCancelsWhileConnecting() async {
        let vm = makeViewModel(bridge: MockBridgeService(stepDelayNanoseconds: 200_000_000))
        vm.profile.portal = "vpn.example.com"
        vm.connect()
        let ok3 = await eventually { vm.state.isConnecting }
        XCTAssertTrue(ok3)
        vm.toggleConnection()
        let ok4 = await eventually(timeout: 5) { vm.state.isDisconnected }
        XCTAssertTrue(ok4, "state: \(vm.state)")
    }

    func testRefreshGatewaysMergesAndKeepsManualEntries() async {
        let vm = makeViewModel()
        vm.profile.portal = "vpn.example.com"
        vm.addManualGateway(name: "Lab", server: "lab.example.com")
        vm.addManualGateway(name: "dup", server: "lab.example.com")
        XCTAssertEqual(vm.gateways.count, 1)

        vm.refreshGateways()
        let ok5 = await eventually { vm.gateways.count == MockBridgeService.sampleGateways.count + 1 }
        XCTAssertTrue(ok5)
        XCTAssertEqual(vm.gateways.last?.server, "lab.example.com")
        XCTAssertEqual(vm.gateways.first?.priority, 1)

        vm.selectGateway("lab.example.com")
        vm.removeGateway(vm.gateways.last!)
        XCTAssertNil(vm.profile.selectedGatewayServer)
        XCTAssertEqual(vm.gateways.count, MockBridgeService.sampleGateways.count)
    }

    func testRefreshGatewaysRequiresPortal() async {
        let vm = makeViewModel(bridge: GpclientBridgeService(
            customGpclientPath: "/nope",
            locator: BinaryLocator(fileExists: { _ in false }, isExecutable: { _ in false }, bundleURL: nil, searchPath: [], workingDirectory: "/")
        ))
        vm.profile.portal = ""
        vm.refreshGateways()
        let ok6 = await eventually { vm.statusMessage != nil }
        XCTAssertTrue(ok6)
        XCTAssertEqual(vm.statusMessage, BridgeError.portalMissing.localizedDescription)
    }

    func testProfileAndPasswordPersistence() async {
        let storage = VpnViewModelStorage.ephemeral()
        let vm = makeViewModel(storage: storage)
        vm.profile.portal = "vpn.persist.com"
        vm.profile.username = "carol"
        vm.password = "hunter2"
        vm.rememberPassword = true
        vm.profile.knownGateways = [Gateway(name: "A", server: "a.example.com")]
        vm.saveProfile()

        let reloaded = makeViewModel(storage: storage)
        XCTAssertEqual(reloaded.profile.portal, "vpn.persist.com")
        XCTAssertEqual(reloaded.profile.username, "carol")
        XCTAssertEqual(reloaded.password, "hunter2")
        XCTAssertEqual(reloaded.gateways.map(\.server), ["a.example.com"])

        reloaded.rememberPassword = false
        reloaded.saveProfile()
        XCTAssertNil(storage.loadPassword("carol"))
    }

    func testMockBridgeSwitchPersists() {
        let storage = VpnViewModelStorage.ephemeral()
        let vm = makeViewModel(storage: storage)
        vm.setUseMockBridge(true)
        XCTAssertTrue(vm.useMockBridge)
        XCTAssertTrue(makeViewModel(storage: storage).useMockBridge)
    }

    func testMetricsComeFromInterfaceCounters() async {
        let counters = Counters()
        counters.text = netstat(bytesIn: 1000, bytesOut: 500)
        let vm = makeViewModel(stats: InterfaceStatsReader(readNetstat: { counters.text }))
        vm.profile.portal = "vpn.example.com"

        vm.connect()
        let ok7 = await eventually { vm.state.isConnected }
        XCTAssertTrue(ok7)
        XCTAssertEqual(vm.metrics.bytesReceived, 0, "baseline is taken at connect time")

        counters.text = netstat(bytesIn: 6000, bytesOut: 2500)
        guard case .connected(let details) = vm.state else { return XCTFail() }
        vm.refreshMetrics(interface: details.interfaceName, connectedAt: details.connectedAt)
        XCTAssertEqual(vm.metrics.bytesReceived, 5000)
        XCTAssertEqual(vm.metrics.bytesSent, 2000)
    }

    func testLogsAsTextAndClear() {
        let vm = makeViewModel()
        vm.logs = [LogEntry(level: .warn, message: "hello")]
        XCTAssertTrue(vm.logsAsText.contains("[WARN] hello"))
        vm.clearLogs()
        XCTAssertTrue(vm.logs.isEmpty)
    }

    func testAutoConnectOnLaunch() async {
        let vm = makeViewModel()
        vm.profile.portal = "vpn.example.com"
        vm.profile.autoConnect = true
        vm.handleLaunch()
        let ok8 = await eventually { vm.state.isConnected }
        XCTAssertTrue(ok8)
    }

    func testPrepareForTerminationDisconnects() async {
        let vm = makeViewModel()
        vm.profile.portal = "vpn.example.com"
        vm.connect()
        let ok = await eventually { vm.state.isConnected }
        XCTAssertTrue(ok)
        XCTAssertTrue(vm.hasActiveSession)

        await vm.prepareForTermination(timeout: 5)
        XCTAssertTrue(vm.state.isDisconnected)
        XCTAssertFalse(vm.hasActiveSession)
        XCTAssertTrue(vm.logs.contains { $0.message.contains("Quitting") })
    }

    func testPrepareForTerminationIsNoopWhenIdle() async {
        let vm = makeViewModel()
        await vm.prepareForTermination(timeout: 1)
        XCTAssertTrue(vm.state.isDisconnected)
        XCTAssertFalse(vm.logs.contains { $0.message.contains("Quitting") })
    }

    func testUninstallHelperDisconnectsFirst() async {
        let vm = makeViewModel()
        vm.profile.portal = "vpn.example.com"
        vm.connect()
        let connected = await eventually { vm.state.isConnected }
        XCTAssertTrue(connected)

        await vm.uninstallHelper()
        XCTAssertTrue(vm.state.isDisconnected, "the helper owns the tunnel, so it is torn down before unregistering")
        XCTAssertTrue(vm.logs.contains { $0.message.contains("Uninstalling the helper: disconnecting") })
        // In this unsigned test process there is nothing registered; the manager reports that, not an error.
        XCTAssertNotEqual(vm.helperManager.status, .enabled)
    }

    func testAuthCallbackNotificationIsForwardedToBridge() async {
        let vm = makeViewModel()
        NotificationCenter.default.post(
            name: .overlandAuthCallbackReceived,
            object: nil,
            userInfo: ["authData": "globalprotectcallback:abc"]
        )
        let ok9 = await eventually { vm.logs.contains { $0.message.contains("Received auth callback data (mock)") } }
        XCTAssertTrue(ok9)
    }

    func testHipRotationAdvancesIndexOnConnect() async {
        let storage = VpnViewModelStorage.ephemeral()
        let vm = makeViewModel(storage: storage)
        vm.profile.portal = "vpn.example.com"
        vm.profile.enableHIP = true
        vm.profile.rotateHIPValues = true
        vm.profile.hipRotationIndex = 0
        vm.saveProfile()

        vm.connect()
        XCTAssertEqual(vm.profile.hipRotationIndex, 1)

        let reloaded = makeViewModel(storage: storage)
        XCTAssertEqual(reloaded.profile.hipRotationIndex, 1)

        // Reset state so it's not busy, then connect again
        vm.state = .disconnected
        vm.connect()
        XCTAssertEqual(vm.profile.hipRotationIndex, 2)
    }

    // MARK: helpers

    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var _text = ""
        var text: String {
            get { lock.withLock { _text } }
            set { lock.withLock { _text = newValue } }
        }
    }

    private func netstat(bytesIn: Int, bytesOut: Int) -> String {
        """
        Name  Mtu  Network  Address  Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
        utun6 1400 <Link#9>            10     0 \(bytesIn)     8     0 \(bytesOut)    0
        """
    }
}


/// Poll a condition on the main actor.
@MainActor
private func eventually(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
