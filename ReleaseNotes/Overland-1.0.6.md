## Overland 1.0.6

Complete macOS network settings reset, sleep/wake tunnel resilience, and disconnect reliability improvements.

### Highlights
- **Reset Network Settings**: Added a one-click **Reset Network Settings…** action (available in **Settings ▸ Network ▸ Troubleshooting**, the menu bar, the app menu, and as **Force Reset Network…** while disconnecting). It stops any lingering VPN processes, removes stale `scutil` Dynamic Store entries and `utun` default routes, resets persistent DNS and search-domain overrides to automatic (DHCP), flushes macOS DNS caches, and refreshes active interfaces so macOS restores default routing, DNS, and Wi-Fi reachability.
- **Disconnect & Sleep/Wake Resilience**: Escalated forced tunnel termination to `SIGKILL` when `gpclient` becomes unresponsive after waking from sleep, guaranteed UI state recovery out of disconnecting, and added wake-from-sleep tunnel health checks.
- **Cleaner Disconnect DNS Flush**: Flushed macOS DNS caches (`dscacheutil` / `mDNSResponder`) during standard `vpnc-script` teardown so local DNS resumes immediately.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` or `~/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
