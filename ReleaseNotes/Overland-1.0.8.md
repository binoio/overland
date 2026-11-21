## Overland 1.0.8

Fixes repeated administrator password prompts by preserving `SMAppService` helper approval across Sparkle updates.

### Highlights
- **Seamless Helper Reload on Update**: `OverlandHelper` now detects when its binary on disk has been replaced by an in-place Sparkle update and exits cleanly while idle so `launchd` spawns the updated helper automatically—without ever calling `SMAppService.unregister()` or revoking Login Items approval.
- **No More Unexpected Password Prompts**: Removed automatic helper unregistration on launch/connect so existing System Settings approvals stay intact across updates.
- **Helper Approval Banner**: Added a clear banner on the main Connection view with one-click **Open System Settings…** and **Re-check** buttons whenever Login Items approval is needed.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` or `~/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
