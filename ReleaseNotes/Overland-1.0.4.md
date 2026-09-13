## Overland 1.0.4

Network DNS configuration fixes and automatic Host Integrity Protection (HIP) report submission.

### Highlights
- **macOS DNS Configuration Fix**: Resolved an issue where establishing a tunnel failed to configure DNS with the error `is not a recognized network service`. The routing script now resolves the physical network service via the VPN gateway route instead of querying the redirected default tunnel interface, backing up original DNS configurations and cleanly restoring them on disconnect.
- **Automatic Host Integrity Protection (HIP) Submission**: Enabled HIP reporting by default and added automatic generation and submission of compliant HIP posture reports. Gateways enforcing endpoint security posture checks (such as university and enterprise networks) receive the host's actual security posture (FileVault, Application Firewall, Gatekeeper, XProtect, and Software Update status), preventing network traffic from being quarantined or isolated.
- **Self-Contained Posture Probe**: Bundled the `hipreport.sh` helper inside the application package and updated the posture probe to run standalone without external Homebrew or system dependencies.
- **Testing & Simulated Identity Support**: Maintained support for rotated simulated host identities for diagnostic and testing environments.

### Requirements
- macOS 14 or later. Run Overland from `/Applications` or `~/Applications` for seamless privileged helper registration.

### Notes
- GlobalProtect is a trademark of Palo Alto Networks; Overland is an independent open-source project (GPL-3.0).
