## Overland 1.0.0

The first release: a native macOS client for GlobalProtect VPN portals, built on gpclient and gpauth from GlobalProtect-openconnect.

### Highlights
- **Single Sign-On** in your own browser, with password and client-certificate logins as alternatives.
- **Approve once, never prompt again.** A privileged helper inside the app (launchd + SMAppService, approved once in System Settings) opens the tunnel; unsigned builds fall back to the standard administrator dialog.
- **Menu bar first.** Status, Connect/Disconnect, Activity Logs, Settings and Quit as a standard menu; optional menu-bar-only mode.
- **Live session view** with gateway, session expiry, tunnel address and throughput sparklines; a searchable activity log.
- **Robust lifecycle.** Quit disconnects cleanly; after a crash, Overland re-attaches to the running tunnel.
- **Gateway discovery** from the portal, manual gateways, and per-connection tunnel options.

### Requirements
- macOS 14 or later. Move Overland to /Applications so the helper's approval sticks.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
