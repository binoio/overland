## Overland 1.0.9

Incorporates key upstream GlobalProtect-openconnect fixes for macOS DNS & split-tunnel handling, log redaction, URL/port parsing, client certificate validation, and native macOS HIP host info.

### Highlights
- **Ephemeral macOS DNS & Split-Tunnel Support**: Adopted upstream's `scutil`-only macOS DNS resolver configuration (`OverridePrimary` + `SearchOrder` + split-tunnel source tracking) and removed persistent `networksetup -setdnsservers` writes so physical Wi-Fi/Ethernet DNS settings are never left modified across crashes or reboots.
- **Faster Disconnect on Unresponsive Gateways**: Reduced the disconnect grace timeout before escalating to forced teardown when a gateway stops responding to logout.
- **Security & Log Hygiene**: Redacted sensitive cookies, passwords, SAML payloads, and `globalprotectcallback:` tokens from Activity Logs, and enforced server certificate pins in OpenConnect's peer validation callback.
- **Custom Port & URL Normalization**: Pasting full portal or gateway URLs (including explicit `:port` and IPv6 `[host]:port`) now strips schemes/paths while preserving custom ports.
- **Client Certificate Validation & macOS HIP Info**: Added pre-connect checks for missing or unreadable client certificate/key files, and updated HIP posture reporting to detect real macOS version (`sw_vers`) and built-in Wi-Fi MAC (`networksetup`) as the host ID.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` or `~/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
