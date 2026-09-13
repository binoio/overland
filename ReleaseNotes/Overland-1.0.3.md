## Overland 1.0.3

Bug fixes and improvements for single sign-on (SSO) authentication and browser callback delivery.

### Highlights
- **Browser SSO Callback Handling**: Fixed an issue where browser-based authentication (such as university or corporate SAML/Duo SSO) hung indefinitely at "Waiting for browser sign-in" even though the browser showed "Authentication complete". Registered a system-level AppleEvent handler (`kAEGetURL`) via `NSAppleEventManager` alongside SwiftUI `.onOpenURL` handlers to ensure `globalprotectcallback:` URLs are captured across all app states.
- **LaunchServices Handler Registration**: Overland now dynamically registers its active bundle path with LaunchServices on launch, ensuring macOS directs browser callbacks to the currently running instance.
- **Manual Callback Fallback**: Added a "Paste callback URL…" option to the sign-in progress view so users can manually paste the callback URL if browser extensions or security policies block custom protocol redirects.
- **Enhanced Activity Logging**: Added real-time log entries in the Activity Logs window when an authentication callback is received and relayed to the helper.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` or `~/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
