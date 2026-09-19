# Overland

<p align="center">
  <img src="docs/icon.png" width="160" alt="Overland icon">
</p>

**Overland is a native macOS menu bar client for enterprise VPN portals, built
on OpenConnect.** Sign in with your browser, approve a small privileged helper
once, and connect or disconnect from the menu bar without ever typing a
password for the tunnel. It works with the SSL VPN portals OpenConnect supports
through its `gp` protocol.

Overland is a front end: the VPN work is done by [`gpclient`](apps/gpclient)
and [`gpauth`](apps/gpauth) from Kevin Yue's
[GlobalProtect-openconnect](https://github.com/yuezk/GlobalProtect-openconnect),
which in turn builds on [OpenConnect](https://www.infradead.org/openconnect/).
This repository carries that project's source so the two CLI binaries can be
built for macOS and embedded in the app; see [Relationship to
GlobalProtect-openconnect](#relationship-to-globalprotect-openconnect).

## Features

- **Single Sign-On** via your own browser (SAML), plus username/password and
  client-certificate logins.
- **Approve once.** A launchd daemon inside the app bundle, registered with
  `SMAppService`, opens the tunnel. After the one-time approval in System
  Settings › Login Items & Extensions there are no more prompts. Unsigned
  builds fall back to the standard macOS administrator dialog.
- **Menu bar first.** Status and connect/disconnect from a standard menu;
  optional menu-bar-only mode without a Dock icon.
- **Live session view.** Gateway, session expiry, tunnel address, throughput
  sparklines, and a full activity log.
- **Robust lifecycle.** Quit disconnects cleanly (routes and DNS restored);
  after a crash the app re-attaches to the still-running tunnel.
- **Gateway discovery** from the portal, with manual entries and per-profile
  tunnel options (IPv6, DTLS/ESP, MTU, DPD, HIP, TLS quirks).

## Install

1. Download the latest `Overland.app` from
   [Releases](https://github.com/binoio/overland/releases/latest) and move it to
   `/Applications`.
2. Open it, enter your portal address, leave **Single Sign-On** selected, and
   click **Enable…** to approve the helper in System Settings.
3. **Connect**, finish signing in in the browser, and allow it to open Overland.

Requires macOS 14 or later.

## Build from source

```zsh
zsh OverlandApp/Scripts/build_gpclient.sh   # builds gpclient + gpauth for macOS (Homebrew deps, Rust)
zsh OverlandApp/Scripts/bundle.sh           # builds the app and assembles dist/Overland.app
open dist/Overland.app
```

`bundle.sh` signs with the first Developer ID identity in your keychain; the
privileged helper needs that signature to register. Tests, packaging,
notarization and the architecture are described in
[`OverlandApp/README.md`](OverlandApp/README.md).

```zsh
zsh OverlandApp/Scripts/test.sh --all       # Swift tests (macOS), the core suite in Docker, and the Rust tests the app relies on
```

## How it works

| Phase | Runs as | What happens |
| --- | --- | --- |
| Sign in | you | `gpauth <portal> --browser …` serves the SAML page, opens the browser, and receives the result through the `globalprotectcallback:` URL macOS routes to Overland. |
| Tunnel | root | The privileged helper runs the bundled `gpclient connect <portal> --cookie-on-stdin …` with the sign-in result on stdin, retrieves the portal config, logs in to the gateway and keeps the tunnel up. |

The helper accepts only a client signed with its own Team ID and bundle
identifier, verifies `gpclient` and the bundle's signature immediately before
every launch, and allow-lists every argument it will pass. Its JSON log stream
drives the UI. Details: [`OverlandApp/README.md`](OverlandApp/README.md).

## Relationship to GlobalProtect-openconnect

Overland is a downstream project, not a fork intended for upstream
contribution. The Rust workspace here (`apps/`, `crates/`, `packaging/`,
`Makefile`, the Linux CI workflows) is GlobalProtect-openconnect's, kept intact
so upstream changes can be merged with `git merge upstream/main`. Upstream's
GitHub Actions workflows (Linux packages, Docker images, AUR/PPA/Nix) are
disabled in this repository's settings rather than deleted, so merges stay
conflict-free; only the `macOS App` workflow runs here. Overland's
own code lives in [`OverlandApp/`](OverlandApp/) and [`docs/`](docs/), plus one
small addition to `crates/gpapi` (a per-gateway log line the app parses).

Upstream's original README, covering the Linux GUI and CLI packages, is kept
as [`README.upstream.md`](README.upstream.md). For the Linux client, its
documentation, and issues about `gpclient` itself, go to
[yuezk/GlobalProtect-openconnect](https://github.com/yuezk/GlobalProtect-openconnect).

## Repository layout

```
OverlandApp/      the macOS app: Swift package, scripts, tests, Dockerfile, README
docs/             the bino.io/overland page (GitHub Pages)
apps/, crates/    GlobalProtect-openconnect sources (gpclient, gpauth, gpapi, openconnect FFI)
packaging/        upstream packaging; Overland reuses its vendored vpnc-script
```

## License

GPL-3.0 for the whole repository (see [`LICENSE`](LICENSE)), matching
GlobalProtect-openconnect. OpenConnect is LGPL-2.1 and `vpnc-script` is
GPL-2.0+; both are embedded in the app bundle.

GlobalProtect is a trademark of Palo Alto Networks, Inc. Overland is an
independent project and is not affiliated with or endorsed by Palo Alto
Networks.
