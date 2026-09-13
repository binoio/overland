# Overland — developer guide

This is the engineering README for the app under `OverlandApp/`; the
project overview, install steps and the relationship to
GlobalProtect-openconnect are in the [top-level README](../README.md).

Overland is a native SwiftUI/AppKit macOS client for GlobalProtect VPN portals.
It drives the [`gpclient`](../apps/gpclient) and [`gpauth`](../apps/gpauth)
CLIs built from this repository, giving them a menu bar item, a connection
window, gateway selection, live tunnel metrics and a log console — without a
Tauri/WebKit runtime.

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
* **Root** comes from the **Overland privileged helper**: a small launchd
  daemon inside the bundle (`Contents/MacOS/OverlandHelper`, registered with
  `SMAppService` from `Contents/Library/LaunchDaemons/io.bino.overland.helper.plist`).
  It is approved once in System Settings › Login Items & Extensions; from then
  on connecting never prompts. The daemon owns the `gpclient` process, so it
  survives app quits and crashes, and the app simply re-attaches over XPC.
  Security: only a client signed with the helper's own Team ID and the
  `io.bino.overland` bundle id is accepted; every request is checked by
  `HelperRequestValidator` (only the bundled `gpclient`, only
  `connect`/`disconnect`, an allow-list of flags, hostname-shaped servers, the
  bundled `vpnc-script`, cert/key files owned by the caller); `gpclient` and the
  bundle's code signature are verified immediately before each launch; the
  SAML result or password travels over XPC to the process's stdin only.
  The daemon exits when idle and launchd restarts it on demand.
* **Fallback:** an unsigned (ad-hoc) build, or a user who declines the
  background item, gets the standard macOS administrator authorization dialog
  on every connect (`osascript … with administrator privileges`). Because
  `do shell script` is synchronous, a wrapper
  (`~/Library/Application Support/Overland/overland-privileged-wrapper.sh`)
  detaches a supervisor that runs gpclient, mirrors its output to a per-run
  log the app tails, and relays `stop`/`kill` from a FIFO. Processes started
  through the trampoline inherit a signal mask with SIGINT/SIGTERM/SIGALRM
  blocked, so the wrapper re-execs through `overland-exec`, a shim that resets
  the mask first — without it neither gpclient nor the supervisor could be
  signalled.
* Disconnect sends SIGINT to gpclient (via the helper, or the fallback's
  FIFO); gpclient tears the tunnel down cleanly and restores routes and DNS.
  If it ignores the signal the app terminates it after a grace period.
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
├── Sources/OverlandHelperShared/ XPC protocols, TunnelManager, HelperService, listener delegate
├── Sources/OverlandHelper/       the root daemon (code-signature checks, VerifiedRunner)
├── Sources/overland-exec/        signal-mask reset shim for the fallback path
├── Sources/Overland/        SwiftUI views, VpnViewModel, HelperManager, HelperProcessRunner, Keychain
├── Tests/OverlandCoreTests/ runs on macOS and Linux (Docker) — 70+ tests
├── Tests/OverlandTests/     view model, HelperService and XPC round-trip tests (macOS)
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

`bundle.sh` signs with the first "Developer ID Application" identity in the
keychain (`OVERLAND_SIGN_IDENTITY` overrides). The privileged helper only
registers from a Developer ID-signed bundle, and the registration is tied to
the bundle's location — install to `/Applications`. Without an identity the
bundle is ad-hoc signed and the app uses the administrator dialog. `swift run`
(unbundled) always uses the dialog.

`Overland --helper-status [--helper-register|--helper-unregister]` prints the
helper's registration state from the app's point of view.

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

## Uninstalling

Settings ▸ Backend ▸ **Uninstall…** disconnects if needed and removes the
helper's background item; after that, trashing the app leaves nothing behind.
`zsh OverlandApp/Scripts/uninstall.sh` does the same from the command line and
also deletes the bundle, Application Support folder, preferences and saved
passwords.

## Releasing

Overland ships auto-updates with Sparkle 2: an EdDSA-signed appcast at
`docs/appcast.xml` is served from the bino.io/overland GitHub Pages site
(`https://bino.io/overland/appcast.xml`) and the zips live on GitHub Releases.

1. Bump `OverlandApp/VERSION`
2. Write `ReleaseNotes/Overland-X.Y.Z.md` (GitHub release body) and
   `ReleaseNotes/Overland-X.Y.Z.html` (embedded in the appcast)
3. Commit, then run `zsh OverlandApp/Scripts/release.sh` — it builds gpclient
   and the app, signs everything, notarizes and staples, generates the
   appcast, tags (`overland-vX.Y.Z` — the repository also carries upstream's
   `vX.Y.Z` tags), publishes the GitHub release, and pushes the appcast

One-time prerequisites: the Developer ID identity and the Sparkle EdDSA
private key (`generate_keys --account Overland`) in the login Keychain, a
notarytool keychain profile (`atmo-notary` by default, or
`OVERLAND_NOTARY_PROFILE`), and an authenticated `gh`.

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
* Quitting the app while connected disconnects first (the quit is deferred
  until gpclient has torn the tunnel down, up to 10 s). After a crash or force
  quit the helper keeps the tunnel up and the next launch re-attaches to it
  (log replay, Disconnect works). The same holds for the fallback path via
  its session directory.
* Running a second copy of the app from another location: it can re-attach
  to a helper-run tunnel, but a fresh connect is refused because its
  `gpclient` is not the one the registered helper validates against.
* The app talks to `gpclient` only; `gpservice`/`gpgui` are not used.

## Host Integrity (HIP) reporting

When a connection enables HIP (Settings ▸ Network ▸ "Send HIP report"), the
bundled `gpclient` reports this Mac's **actual** security posture rather than
fixed placeholder values: FileVault state (`fdesetup`), the application
firewall (`socketfilterfw`), Gatekeeper (`spctl`), the installed XProtect
version, and whether automatic Software Update checks are on. Each probe is
read-only and needs no root; if one cannot run, that item is reported in its
off/absent state rather than as falsely present. A gateway that enforces HIP
therefore sees the truth — including, for example, a disabled firewall — so a
non-compliant device may be refused, which is the intended behavior.

## License

GPL-3.0, the same as the rest of this repository (see the root `LICENSE`).
The bundled `gpclient`/`gpauth` are GPL-3.0, OpenConnect is LGPL-2.1 and
`vpnc-script` is GPL-2.0+; all are compatible with GPL-3.0.
