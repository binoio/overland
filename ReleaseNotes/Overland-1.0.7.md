## Overland 1.0.7

Automatic privileged helper updates after Sparkle installs, reconnect/disconnect route & DNS preservation fixes, and main window navigation improvements.

### Highlights
- **Automatic Privileged Helper Updates**: Overland now detects stale privileged helper versions or XPC protocol mismatches on launch and during connect (such as after an in-place Sparkle update) and automatically re-registers the updated helper daemon without requiring manual uninstall/reinstall.
- **Reconnect / Disconnect Network Fix**: Fixed `vpnc-script` bugs where reconnecting overwrote the original default route and DNS backups with VPN addresses, and where missing `resolv.conf` backups skipped macOS `scutil`/`networksetup` teardown. Disconnect now preserves original backups, always cleans up macOS DNS/resolver state, and automatically triggers DHCP recovery if the default route is missing.
- **Main Window Navigation Fix**: Fixed `NavigationSplitView` sidebar selection so switching to Activity Logs (or Gateways) reliably switches back to the current Connection view, added a **Connection** back button in the toolbar when away from the Connection tab, and opened Activity Logs from failure cards in the dedicated Logs window.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` or `~/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
