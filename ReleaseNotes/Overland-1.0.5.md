## Overland 1.0.5

UI stabilization, native window management, and connection configuration improvements.

### Highlights
- **Layout Stabilization**: Anchored UI element locations and widened layouts in the Welcome onboarding screen and main views, preventing controls and buttons from shifting horizontally when typing portal addresses or updating connection parameters.
- **Dedicated Windows for Modals**: Replaced modal sheets across the app with native macOS windows for editing connections (⌘E), adding manual gateways, and submitting authentication callback URLs.
- **Edit Connection Sizing & Accessibility**: Widened the Edit Connection window to accommodate all portal, authentication method, and gateway controls without clipping. Replaced the link text with an inline "Edit Connection…" button in the connection detail header.
- **Boundary & Clipping Safeguards**: Adjusted minimum window constraints and layout alignment to guarantee that all action buttons and status rows remain fully accessible and visible across different window sizes.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` or `~/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
