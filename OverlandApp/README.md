# Overland

Overland is a native SwiftUI/AppKit macOS client for GlobalProtect VPN portals. It drives the
[`gpclient`](../apps/gpclient) CLI from this repository. It gives the CLI a
menu bar item, a connection window, gateway selection, live tunnel metrics and
a log console — without a Tauri/WebKit runtime.

## How it works

`gpclient connect` needs root to create the `utun` device, but SAML logins
want your browser, your Keychain and the `globalprotectcallback:` URL handler,
which only work as your user. The app therefore splits a connection the way
the CLI documents it (`gpauth … | sudo gpclient connect … --cookie-on-stdin`):

| Phase | Runs as | Command |
| --- | --- | --- |
| Sign in (SSO profiles) | you | `gpauth --log-format json <portal> --browser <mode>` → prints a `SamlAuthResult` JSON line |
| Tunnel | root | `gpclient --log-format json connect <portal> [--auto-gateway \| --gateway X] --cookie-on-stdin --script <vpnc-script> …` |

Password and certificate profiles skip the sign-in step and pass
`--user U --passwd-on-stdin` / `--certificate` to the privileged gpclient.

* The sign-in result (or password) reaches the privileged gpclient on stdin
  only; it never appears on a command line.
* **Root** comes from the standard macOS authorization dialog by default
  (`osascript … with administrator privileges`, the same Security Agent sheet
  installers use). It asks for an administrator's *name and password*, so a
  non-administrator account can connect with an admin's credentials. Because
  `do shell script` is synchronous, what runs under authorization is a small
  wrapper (`~/Library/Application Support/Overland/overland-privileged-wrapper.sh`)
  that detaches a supervisor: it runs gpclient, mirrors its output to a per-run
  log the app tails, and relays `stop`/`kill` from a FIFO. Settings ▸ Backend
  can switch to `sudo -A` (askpass dialog), `sudo -n` (NOPASSWD sudoers rule),
  or no escalation.
* Disconnect sends SIGINT to gpclient (through the supervisor's FIFO, or via
  sudo which relays it); gpclient tears the tunnel down cleanly. If it ignores
  the signal the app terminates it after a grace period.
* The JSON log stream (`--log-format json`) is parsed into structured entries:
  gateway inventory, tunnel-up, session lifetime, warnings and errors drive the
  UI state. The tunnel's `utun` interface and address come from `ifconfig`;
  throughput comes from `netstat -ibn`.
* Browser SSO: `gpauth --browser` serves the SAML page on localhost and waits
  for the identity provider's `globalprotectcallback:` redirect. macOS delivers
  that URL to the app (`CFBundleURLTypes`), which relays it to the waiting
  gpauth over loopback exactly like `gpclient launch-gui <data>` does on Linux.
* Gateway discovery (the **Discover** button) runs the unprivileged
  `gpclient connect --cookie-only --auto-gateway`, whose portal config lists
  every gateway. Gateways are also learned on every connection.

## Layout

```
OverlandApp/
├── Package.swift                 OverlandCore (portable) + Overland (macOS app)
├── Sources/OverlandCore/    models, GpclientCommandBuilder, GpclientOutputParser,
│                                 ProcessRunner, GpclientBridgeService, MockBridgeService,
│                                 PrivilegedProcessRunner (admin dialog), BinaryLocator,
│                                 SudoAskpass, TunInterfaceInspector, …
├── Sources/Overland/        SwiftUI views, VpnViewModel, AppDelegate, Keychain
├── Tests/OverlandCoreTests/ runs on macOS and Linux (Docker) — 70+ tests
├── Tests/OverlandTests/     view model tests (macOS)
├── Scripts/                      build_gpclient.sh, bundle.sh, run.sh, test.sh, notarize.sh
├── Dockerfile, docker-compose.yml   containerised core tests (what CI runs)
└── Support/                      Info.plist, entitlements
```

## Building

```zsh
# 1. Build gpclient + gpauth for macOS (installs Homebrew deps, fetches the openconnect submodule)
zsh OverlandApp/Scripts/build_gpclient.sh

# 2. Run the app from source (finds target/release/gpclient automatically)
zsh OverlandApp/Scripts/run.sh

# 3. Or assemble a self-contained dist/Overland.app
#    (embeds gpclient, gpauth, their Homebrew dylibs, and the vendored vpnc-script)
zsh OverlandApp/Scripts/bundle.sh
open dist/Overland.app
```

Requirements: macOS 14+, Xcode 16 (Swift 6), Homebrew, Rust 1.89+.

SAML/SSO portals are handled by `gpauth`, which `gpclient` looks for next to
its own executable (`Contents/MacOS/gpauth` in the bundle, `target/release/gpauth`
in the repo); `GP_AUTH_BINARY` overrides that.

`gpclient` is located in this order: Settings ▸ Backend override, the copy
inside the app bundle, `/opt/homebrew/bin`, `/usr/local/bin`, anything on
`PATH`, then `target/release` or `target/debug` in the repository.

## Testing

```zsh
zsh OverlandApp/Scripts/test.sh            # swift test on this Mac
zsh OverlandApp/Scripts/test.sh --docker   # OverlandCore in a Linux container
zsh OverlandApp/Scripts/test.sh --all      # both + the gpapi Rust tests the app depends on
```

The bridge is tested against a scripted fake process runner (full connect,
disconnect, sudo denial, tunnel drop, cancel-during-auth, gateway discovery).
`RealGpclientIntegrationTests` additionally drive the real `gpclient` binary
through the real process runner when one is found, using a `.invalid` portal
so no network is needed. CI (`.github/workflows/macos-app.yaml`) runs the core
suite in Docker on an Ubuntu runner.

Settings ▸ Developer ▸ **Use Mock Bridge** simulates the whole lifecycle in
the UI without a portal, a gpclient build or administrator privileges.

## Signing and notarizing

```zsh
OVERLAND_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  zsh OverlandApp/Scripts/notarize.sh
```

Signs the embedded dylibs and gpclient, then the app with hardened runtime and
`Support/Overland.entitlements`, submits to Apple with `notarytool`
(keychain profile `overland-notary`), staples, and writes
`dist/Overland-<version>.zip`.

## Known limitations

* Portals that ask for a one-time code after the password (`inquire` MFA
  prompt) and the interactive key-passphrase prompt are terminal-only in
  gpclient; use Single Sign-On or the CLI for those.
* Session extension is performed automatically by gpclient when the gateway
  allows it; the app shows the expiry it reports but has no manual "extend".
* The authorization dialog appears on every connect (nothing is installed
  system-wide). A `SMAppService` privileged helper would make it a one-time
  approval and is the natural next step.
* If the app quits while connected, the root-side gpclient keeps the tunnel
  up and a later connect fails with "Another instance of the client is already
  running"; `sudo gpclient disconnect` ends the orphaned tunnel.
* The app talks to `gpclient` only; `gpservice`/`gpgui` are not used.

## License

GPL-3.0, the same as the rest of this repository (see the root `LICENSE`).
The bundled `gpclient`/`gpauth` are GPL-3.0, OpenConnect is LGPL-2.1 and
`vpnc-script` is GPL-2.0+; all are compatible with GPL-3.0.
