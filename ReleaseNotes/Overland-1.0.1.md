## Overland 1.0.1

Bug fixes and enhancements for the privileged helper installation and testing tooling.

### Highlights
- **Privileged Helper & Release Packaging Fix**: Fixed an issue where release archives contained AppleDouble metadata files (`._*`) that invalidated code signatures upon extraction, causing the app to report "Helper missing from the app bundle".
- **App Translocation & Move Prompt**: Enhanced app location detection to recognize Gatekeeper App Translocation when launched from Downloads or temporary folders. Overland now reliably prompts to relocate itself to `/Applications` so background helper authorization persists.
- **HIP Simulation & Testing**: Added an option under Settings ▸ Network to simulate and automatically rotate client host identity (computer name, rotating MAC address/Host ID, and IP address) per connection attempt for testing without modifying upstream binaries.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
