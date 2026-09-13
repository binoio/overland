## Overland 1.0.2

Bug fixes and improvements for privileged helper detection and user-level Applications support.

### Highlights
- **Privileged Helper Status Detection**: Fixed an issue where a fresh installation reported "Helper missing from the app bundle" because launchd returns a `notFound` status prior to initial registration. Overland now distinguishes uninstalled background daemons from missing binaries and displays the "Enable…" action.
- **User Applications & Auto-Detranslocation**: Full support for running from `~/Applications` in addition to `/Applications`. When launched from an approved Applications directory under Gatekeeper App Translocation, Overland automatically clears quarantine attributes and relaunches un-translocated so helper registration succeeds reliably.
- **Permission Fallback**: If `/Applications` is not writable by the current user, Overland automatically relocates to `~/Applications`.
- **Diagnostics & Recovery**: Added a manual "Re-check" button under Settings ▸ Privileged Helper to re-verify bundle integrity without restarting the app.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` or `~/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
