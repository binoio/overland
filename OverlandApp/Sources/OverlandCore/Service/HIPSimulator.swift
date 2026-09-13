import Foundation

/// A simulated machine identity used to populate HIP (Host Integrity Protection) reports
/// with rotated test values.
public struct SimulatedHostIdentity: Equatable, Sendable, Codable {
    public var index: Int
    public var computerName: String
    public var hostId: String
    public var macAddress: String
    public var ipv4Address: String
    public var ipv6Address: String

    public init(
        index: Int,
        computerName: String,
        hostId: String,
        macAddress: String,
        ipv4Address: String,
        ipv6Address: String
    ) {
        self.index = index
        self.computerName = computerName
        self.hostId = hostId
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
    }
}

/// Generates simulated, rotated Host Information Profile (HIP) values and scripts for testing.
public enum HIPSimulator {
    /// Derives a deterministic simulated host identity for a given rotation index.
    public static func identity(for index: Int) -> SimulatedHostIdentity {
        let normalized = max(0, index)
        let seq = (normalized % 999) + 1
        let computerName = String(format: "Overland-Test-Mac-%02d", (normalized % 99) + 1)

        // Locally administered, unicast MAC address (02:50:41:xx:xx:xx)
        let b3 = UInt8((normalized >> 16) & 0xFF)
        let b4 = UInt8((normalized >> 8) & 0xFF)
        let b5 = UInt8((normalized % 254) + 1)
        let macAddress = String(format: "02:50:41:%02X:%02X:%02X", b3, b4, b5)

        // On macOS GlobalProtect, the primary network interface MAC is used as host-id
        let hostId = macAddress

        let ipSubnet = (normalized / 250) % 250 + 1
        let ipHost = (normalized % 250) + 1
        let ipv4Address = "10.254.\(ipSubnet).\(ipHost)"
        let ipv6Address = String(format: "fd00:5041::%x", seq)

        return SimulatedHostIdentity(
            index: normalized,
            computerName: computerName,
            hostId: hostId,
            macAddress: macAddress,
            ipv4Address: ipv4Address,
            ipv6Address: ipv6Address
        )
    }

    /// Generates a complete POSIX shell script that acts as OpenConnect's `--csd-wrapper`
    /// and emits a simulated, rotated HIP XML report to stdout.
    /// If `allowGpclientProbe` is true and a valid `gpclient` binary is available,
    /// it queries real macOS security posture, falling back to simulated XML.
    public static func generateScript(
        for identity: SimulatedHostIdentity,
        gpclientPath: String? = nil,
        allowGpclientProbe: Bool = true
    ) -> String {
        let probeBlock: String
        if allowGpclientProbe {
            let directCandidate = gpclientPath.map { "\"\($0)\"" } ?? "\"\""
            probeBlock = """
            GPCLIENT_EXEC=""
            for candidate in \
                \(directCandidate) \
                "/Applications/Overland.app/Contents/MacOS/gpclient" \
                "${HOME}/Applications/Overland.app/Contents/MacOS/gpclient" \
                "/opt/homebrew/bin/gpclient" \
                "/usr/local/bin/gpclient" \
                "/usr/bin/gpclient"; do
              if [ -n "$candidate" ] && [ -x "$candidate" ]; then
                GPCLIENT_EXEC="$candidate"
                break
              fi
            done

            if [ -z "$GPCLIENT_EXEC" ]; then
              GPCLIENT_EXEC="$(command -v gpclient 2>/dev/null || true)"
            fi

            if [ -n "$GPCLIENT_EXEC" ] && [ -x "$GPCLIENT_EXEC" ]; then
              EXTRA_ARGS=""
              [ -n "$CLIENT_IP" ] && EXTRA_ARGS="$EXTRA_ARGS --client-ip $CLIENT_IP"
              [ -n "$CLIENT_IPV6" ] && EXTRA_ARGS="$EXTRA_ARGS --client-ipv6 $CLIENT_IPV6"
              REAL_REPORT=$("$GPCLIENT_EXEC" hip --client-version "$CLIENT_VERSION" --client-os "$CLIENT_OS" --cookie "$COOKIE" --md5 "$MD5" $EXTRA_ARGS 2>/dev/null || true)
              if printf '%s\\n' "$REAL_REPORT" | grep -q '<hip-report'; then
                printf '%s\\n' "$REAL_REPORT"
                exit 0
              fi
            fi
            """
        } else {
            probeBlock = ""
        }

        return """
        #!/bin/sh
        # Overland HIP report script (auto-generated)
        COOKIE=""
        MD5=""
        CLIENT_VERSION="6.2.4-49"
        CLIENT_OS="Mac"
        OS_VERSION="Apple Mac OS X 14.5.0"
        CLIENT_IP=""
        CLIENT_IPV6=""

        while [ $# -gt 0 ]; do
          case "$1" in
            --cookie) COOKIE="$2"; shift 2 ;;
            --md5) MD5="$2"; shift 2 ;;
            --client-version) CLIENT_VERSION="$2"; shift 2 ;;
            --client-os) CLIENT_OS="$2"; shift 2 ;;
            --os-version) OS_VERSION="$2"; shift 2 ;;
            --client-ip) CLIENT_IP="$2"; shift 2 ;;
            --client-ipv6) CLIENT_IPV6="$2"; shift 2 ;;
            *) shift ;;
          esac
        done

        \(probeBlock)

        USER_NAME=""
        DOMAIN=""
        if [ -n "$COOKIE" ]; then
          USER_NAME=$(printf '%s\\n' "$COOKIE" | tr '&' '\\n' | grep '^user=' | head -n 1 | cut -d= -f2-)
          DOMAIN=$(printf '%s\\n' "$COOKIE" | tr '&' '\\n' | grep '^domain=' | head -n 1 | cut -d= -f2-)
        fi

        GEN_TIME=$(date '+%m/%d/%Y %H:%M:%S')
        DAY=$(date '+%d')
        MON=$(date '+%m')
        YEAR=$(date '+%Y')

        if [ -n "$DOMAIN" ]; then
          DOMAIN_FULL="${DOMAIN}.internal"
        else
          DOMAIN_FULL=".internal"
        fi

        cat <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <hip-report name="hip-report">
        \t<md5-sum>${MD5}</md5-sum>
        \t<user-name>${USER_NAME}</user-name>
        \t<domain>${DOMAIN_FULL}</domain>
        \t<host-name>\(identity.computerName)</host-name>
        \t<host-id>\(identity.hostId)</host-id>
        \t<ip-address>\(identity.ipv4Address)</ip-address>
        \t<ipv6-address>\(identity.ipv6Address)</ipv6-address>
        \t<generate-time>${GEN_TIME}</generate-time>
        \t<hip-report-version>4</hip-report-version>
        \t<categories>
        \t\t<entry name="host-info">
        \t\t\t<client-version>${CLIENT_VERSION}</client-version>
        \t\t\t<os>${OS_VERSION}</os>
        \t\t\t<os-vendor>Apple</os-vendor>
        \t\t\t<domain>${DOMAIN_FULL}</domain>
        \t\t\t<host-name>\(identity.computerName)</host-name>
        \t\t\t<host-id>\(identity.hostId)</host-id>
        \t\t\t<network-interface>
        \t\t\t\t<entry name="en0">
        \t\t\t\t\t<description>en0</description>
        \t\t\t\t\t<mac-address>\(identity.macAddress)</mac-address>
        \t\t\t\t\t<ip-address>
        \t\t\t\t\t\t<entry name="\(identity.ipv4Address)"/>
        \t\t\t\t\t</ip-address>
        \t\t\t\t\t<ipv6-address>
        \t\t\t\t\t\t<entry name="\(identity.ipv6Address)"/>
        \t\t\t\t\t</ipv6-address>
        \t\t\t\t</entry>
        \t\t\t</network-interface>
        \t\t</entry>
        \t\t<entry name="anti-malware">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Xprotect" version="2167" defver="235000000000000" engver="" datemon="${MON}" dateday="${DAY}" dateyear="${YEAR}" prodType="3" osType="4"/>
        \t\t\t\t\t\t<real-time-protection>yes</real-time-protection>
        \t\t\t\t\t\t<last-full-scan-time>n/a</last-full-scan-time>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Gatekeeper" version="14.5.0" defver="" engver="" datemon="${MON}" dateday="${DAY}" dateyear="${YEAR}" prodType="3" osType="4"/>
        \t\t\t\t\t\t<real-time-protection>yes</real-time-protection>
        \t\t\t\t\t\t<last-full-scan-time>n/a</last-full-scan-time>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t</entry>
        \t\t<entry name="disk-backup">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Time Machine" version="1.3"/>
        \t\t\t\t\t\t<last-backup-time>n/a</last-backup-time>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t</entry>
        \t\t<entry name="disk-encryption">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="FileVault" version="14.5.0"/>
        \t\t\t\t\t\t<drives>
        \t\t\t\t\t\t\t<entry>
        \t\t\t\t\t\t\t\t<drive-name>Macintosh HD</drive-name>
        \t\t\t\t\t\t\t\t<enc-state>encrypted</enc-state>
        \t\t\t\t\t\t\t</entry>
        \t\t\t\t\t\t\t<entry>
        \t\t\t\t\t\t\t\t<drive-name>Data</drive-name>
        \t\t\t\t\t\t\t\t<enc-state>encrypted</enc-state>
        \t\t\t\t\t\t\t</entry>
        \t\t\t\t\t\t\t<entry>
        \t\t\t\t\t\t\t\t<drive-name>All</drive-name>
        \t\t\t\t\t\t\t\t<enc-state>encrypted</enc-state>
        \t\t\t\t\t\t\t</entry>
        \t\t\t\t\t\t</drives>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t</entry>
        \t\t<entry name="firewall">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Mac OS X Builtin Firewall" version="14.5.0"/>
        \t\t\t\t\t\t<is-enabled>yes</is-enabled>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="OpenBSD" name="Packet Filter" version="14.5.0"/>
        \t\t\t\t\t\t<is-enabled>no</is-enabled>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t</entry>
        \t\t<entry name="patch-management">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Software Update" version="3.0"/>
        \t\t\t\t\t\t<is-enabled>yes</is-enabled>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t\t<missing-patches/>
        \t\t</entry>
        \t\t<entry name="data-loss-prevention">
        \t\t\t<list/>
        \t\t</entry>
        \t</categories>
        </hip-report>
        EOF
        """
    }

    /// Writes the HIP script to `destination` with executable permissions (0755).
    @discardableResult
    public static func writeScript(
        to destination: URL,
        identity: SimulatedHostIdentity,
        gpclientPath: String? = nil,
        allowGpclientProbe: Bool = true
    ) throws -> String {
        let content = generateScript(for: identity, gpclientPath: gpclientPath, allowGpclientProbe: allowGpclientProbe)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination.path
    }

    /// Directly formats and returns the raw XML string for the given simulated identity and parameters.
    public static func generateXML(
        identity: SimulatedHostIdentity,
        md5: String = "simulated-md5",
        userName: String = "testuser",
        domain: String = "",
        clientVersion: String = "6.2.4-49",
        softwareVersion: String = "14.5.0",
        osVersion: String = "Apple Mac OS X 14.5.0",
        date: Date = Date()
    ) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "MM/dd/yyyy HH:mm:ss"
        let generateTime = df.string(from: date)
        df.dateFormat = "dd"
        let day = df.string(from: date)
        df.dateFormat = "MM"
        let month = df.string(from: date)
        df.dateFormat = "yyyy"
        let year = df.string(from: date)

        let domainField = domain.isEmpty ? ".internal" : "\(domain).internal"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <hip-report name="hip-report">
        \t<md5-sum>\(md5)</md5-sum>
        \t<user-name>\(userName)</user-name>
        \t<domain>\(domainField)</domain>
        \t<host-name>\(identity.computerName)</host-name>
        \t<host-id>\(identity.hostId)</host-id>
        \t<ip-address>\(identity.ipv4Address)</ip-address>
        \t<ipv6-address>\(identity.ipv6Address)</ipv6-address>
        \t<generate-time>\(generateTime)</generate-time>
        \t<hip-report-version>4</hip-report-version>
        \t<categories>
        \t\t<entry name="host-info">
        \t\t\t<client-version>\(clientVersion)</client-version>
        \t\t\t<os>\(osVersion)</os>
        \t\t\t<os-vendor>Apple</os-vendor>
        \t\t\t<domain>\(domainField)</domain>
        \t\t\t<host-name>\(identity.computerName)</host-name>
        \t\t\t<host-id>\(identity.hostId)</host-id>
        \t\t\t<network-interface>
        \t\t\t\t<entry name="en0">
        \t\t\t\t\t<description>en0</description>
        \t\t\t\t\t<mac-address>\(identity.macAddress)</mac-address>
        \t\t\t\t\t<ip-address>
        \t\t\t\t\t\t<entry name="\(identity.ipv4Address)"/>
        \t\t\t\t\t</ip-address>
        \t\t\t\t\t<ipv6-address>
        \t\t\t\t\t\t<entry name="\(identity.ipv6Address)"/>
        \t\t\t\t\t</ipv6-address>
        \t\t\t\t</entry>
        \t\t\t</network-interface>
        \t\t</entry>
        \t\t<entry name="anti-malware">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Xprotect" version="2167" defver="235000000000000" engver="" datemon="\(month)" dateday="\(day)" dateyear="\(year)" prodType="3" osType="4"/>
        \t\t\t\t\t\t<real-time-protection>yes</real-time-protection>
        \t\t\t\t\t\t<last-full-scan-time>n/a</last-full-scan-time>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Gatekeeper" version="\(softwareVersion)" defver="" engver="" datemon="\(month)" dateday="\(day)" dateyear="\(year)" prodType="3" osType="4"/>
        \t\t\t\t\t\t<real-time-protection>yes</real-time-protection>
        \t\t\t\t\t\t<last-full-scan-time>n/a</last-full-scan-time>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t</entry>
        \t\t<entry name="disk-backup">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Time Machine" version="1.3"/>
        \t\t\t\t\t\t<last-backup-time>n/a</last-backup-time>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t</entry>
        \t\t<entry name="disk-encryption">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="FileVault" version="\(softwareVersion)"/>
        \t\t\t\t\t\t<drives>
        \t\t\t\t\t\t\t<entry>
        \t\t\t\t\t\t\t\t<drive-name>Macintosh HD</drive-name>
        \t\t\t\t\t\t\t\t<enc-state>encrypted</enc-state>
        \t\t\t\t\t\t\t</entry>
        \t\t\t\t\t\t\t<entry>
        \t\t\t\t\t\t\t\t<drive-name>Data</drive-name>
        \t\t\t\t\t\t\t\t<enc-state>encrypted</enc-state>
        \t\t\t\t\t\t\t</entry>
        \t\t\t\t\t\t\t<entry>
        \t\t\t\t\t\t\t\t<drive-name>All</drive-name>
        \t\t\t\t\t\t\t\t<enc-state>encrypted</enc-state>
        \t\t\t\t\t\t\t</entry>
        \t\t\t\t\t\t</drives>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t</entry>
        \t\t<entry name="firewall">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Mac OS X Builtin Firewall" version="\(softwareVersion)"/>
        \t\t\t\t\t\t<is-enabled>yes</is-enabled>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="OpenBSD" name="Packet Filter" version="\(softwareVersion)"/>
        \t\t\t\t\t\t<is-enabled>no</is-enabled>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t</entry>
        \t\t<entry name="patch-management">
        \t\t\t<list>
        \t\t\t\t<entry>
        \t\t\t\t\t<ProductInfo>
        \t\t\t\t\t\t<Prod vendor="Apple Inc." name="Software Update" version="3.0"/>
        \t\t\t\t\t\t<is-enabled>yes</is-enabled>
        \t\t\t\t\t</ProductInfo>
        \t\t\t\t</entry>
        \t\t\t</list>
        \t\t\t<missing-patches/>
        \t\t</entry>
        \t\t<entry name="data-loss-prevention">
        \t\t\t<list/>
        \t\t</entry>
        \t</categories>
        </hip-report>
        """
    }
}
