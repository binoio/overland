import Foundation

public enum AuthMethod: String, Codable, CaseIterable, Sendable {
    case credentials = "Username & Password"
    case browserSSO = "Single Sign-On (Browser / SAML)"
    case clientCertificate = "Client Certificate"
}

/// Which browser `gpclient` should launch for SAML/SSO authentication.
/// Mirrors the `--browser` values accepted by the CLI.
public enum BrowserMode: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case systemDefault = "default"
    case chrome = "chrome"
    case firefox = "firefox"

    public var title: String {
        switch self {
        case .auto: return "Automatic (Chrome, Firefox, then default)"
        case .systemDefault: return "System default browser"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        }
    }
}

/// How the app obtains root for the tunnel phase. OpenConnect must create the
/// `utun` device as root, so `gpclient connect` is wrapped accordingly.
public enum PrivilegeMode: String, Codable, CaseIterable, Sendable {
    /// The standard macOS administrator authorization dialog ("GlobalProtect
    /// wants to make changes"), obtained through `osascript … with
    /// administrator privileges`. Supports Touch ID where the system allows it.
    case adminPrompt
    /// `sudo -A` with a password dialog supplied via `SUDO_ASKPASS`.
    case sudoAskpass
    /// `sudo -n` — for users who configured a NOPASSWD sudoers rule for gpclient.
    case sudoNonInteractive
    /// Run gpclient directly (setuid binary, or the app itself runs as root).
    case direct

    public var title: String {
        switch self {
        case .adminPrompt: return "macOS administrator authorization (recommended)"
        case .sudoAskpass: return "sudo with password dialog"
        case .sudoNonInteractive: return "sudo without prompt (NOPASSWD sudoers rule)"
        case .direct: return "No privilege escalation"
        }
    }
}

public struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var portal: String
    public var selectedGatewayServer: String?
    public var username: String
    public var authMethod: AuthMethod
    public var browserMode: BrowserMode
    public var certificatePath: String?
    public var sslKeyPath: String?
    public var disableIPv6: Bool
    public var noDTLS: Bool
    public var ignoreTLSErrors: Bool
    public var fixOpenSSL: Bool
    public var mtu: Int
    public var forceDPD: Int
    public var reconnectTimeout: Int
    public var enableHIP: Bool
    public var asGateway: Bool
    public var vpncScriptPath: String?
    public var privilegeMode: PrivilegeMode
    public var autoConnect: Bool
    /// Gateways learned from the portal config on a previous login, so the
    /// user can pick one before the next connection.
    public var knownGateways: [Gateway]

    public init(
        id: UUID = UUID(),
        name: String = "Default Profile",
        portal: String = "",
        selectedGatewayServer: String? = nil,
        username: String = "",
        authMethod: AuthMethod = .credentials,
        browserMode: BrowserMode = .systemDefault,
        certificatePath: String? = nil,
        sslKeyPath: String? = nil,
        disableIPv6: Bool = false,
        noDTLS: Bool = false,
        ignoreTLSErrors: Bool = false,
        fixOpenSSL: Bool = false,
        mtu: Int = 0,
        forceDPD: Int = 0,
        reconnectTimeout: Int = 300,
        enableHIP: Bool = false,
        asGateway: Bool = false,
        vpncScriptPath: String? = nil,
        privilegeMode: PrivilegeMode = .adminPrompt,
        autoConnect: Bool = false,
        knownGateways: [Gateway] = []
    ) {
        self.id = id
        self.name = name
        self.portal = portal
        self.selectedGatewayServer = selectedGatewayServer
        self.username = username
        self.authMethod = authMethod
        self.browserMode = browserMode
        self.certificatePath = certificatePath
        self.sslKeyPath = sslKeyPath
        self.disableIPv6 = disableIPv6
        self.noDTLS = noDTLS
        self.ignoreTLSErrors = ignoreTLSErrors
        self.fixOpenSSL = fixOpenSSL
        self.mtu = mtu
        self.forceDPD = forceDPD
        self.reconnectTimeout = reconnectTimeout
        self.enableHIP = enableHIP
        self.asGateway = asGateway
        self.vpncScriptPath = vpncScriptPath
        self.privilegeMode = privilegeMode
        self.autoConnect = autoConnect
        self.knownGateways = knownGateways
    }

    // Profiles saved by older builds lack the newer keys; decode them with
    // defaults instead of discarding the whole profile.
    private enum CodingKeys: String, CodingKey {
        case id, name, portal, selectedGatewayServer, username, authMethod, browserMode
        case certificatePath, sslKeyPath, disableIPv6, noDTLS, ignoreTLSErrors, fixOpenSSL
        case mtu, forceDPD, reconnectTimeout, enableHIP, asGateway
        case vpncScriptPath, privilegeMode, autoConnect, knownGateways
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConnectionProfile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        portal = try c.decodeIfPresent(String.self, forKey: .portal) ?? ""
        selectedGatewayServer = try c.decodeIfPresent(String.self, forKey: .selectedGatewayServer)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? defaults.authMethod
        browserMode = try c.decodeIfPresent(BrowserMode.self, forKey: .browserMode) ?? defaults.browserMode
        certificatePath = try c.decodeIfPresent(String.self, forKey: .certificatePath)
        sslKeyPath = try c.decodeIfPresent(String.self, forKey: .sslKeyPath)
        disableIPv6 = try c.decodeIfPresent(Bool.self, forKey: .disableIPv6) ?? false
        noDTLS = try c.decodeIfPresent(Bool.self, forKey: .noDTLS) ?? false
        ignoreTLSErrors = try c.decodeIfPresent(Bool.self, forKey: .ignoreTLSErrors) ?? false
        fixOpenSSL = try c.decodeIfPresent(Bool.self, forKey: .fixOpenSSL) ?? false
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu) ?? 0
        forceDPD = try c.decodeIfPresent(Int.self, forKey: .forceDPD) ?? 0
        reconnectTimeout = try c.decodeIfPresent(Int.self, forKey: .reconnectTimeout) ?? defaults.reconnectTimeout
        enableHIP = try c.decodeIfPresent(Bool.self, forKey: .enableHIP) ?? false
        asGateway = try c.decodeIfPresent(Bool.self, forKey: .asGateway) ?? false
        vpncScriptPath = try c.decodeIfPresent(String.self, forKey: .vpncScriptPath)
        privilegeMode = try c.decodeIfPresent(PrivilegeMode.self, forKey: .privilegeMode) ?? defaults.privilegeMode
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        knownGateways = try c.decodeIfPresent([Gateway].self, forKey: .knownGateways) ?? []
    }

    public static var `default`: ConnectionProfile {
        ConnectionProfile(name: "Work VPN", portal: "", username: "")
    }
}
