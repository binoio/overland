#!/bin/zsh
#
# build_gpclient.sh: Build the gpclient CLI for macOS from this repository.
#
# The macOS app drives gpclient as a subprocess, and gpclient spawns gpauth for
# SAML logins; this produces both binaries the bundle script embeds
# (target/release/gpclient, target/release/gpauth). Installs the Homebrew build
# dependencies OpenConnect needs, checks out the openconnect submodule, and
# runs cargo. Re-runnable; skips work that is already done.
#
# Usage: zsh OverlandApp/Scripts/build_gpclient.sh [--debug]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PROFILE="release"
CARGO_FLAGS=(--release)
if [[ "${1:-}" == "--debug" ]]; then
    PROFILE="debug"
    CARGO_FLAGS=()
fi

command -v brew >/dev/null || { echo "error: Homebrew is required (https://brew.sh)" >&2; exit 1; }
command -v cargo >/dev/null || { echo "error: cargo not found; install Rust via rustup or 'brew install rustup'" >&2; exit 1; }

BREW_PREFIX="$(brew --prefix)"
DEPS=(gnutls nettle gmp p11-kit libxml2 lz4 autoconf automake libtool pkg-config)
MISSING=()
for dep in "${DEPS[@]}"; do
    brew list --versions "$dep" >/dev/null 2>&1 || MISSING+=("$dep")
done
if (( ${#MISSING[@]} )); then
    echo "==> Installing Homebrew dependencies: ${MISSING[*]}"
    brew install "${MISSING[@]}"
fi

if [[ ! -f crates/openconnect/deps/openconnect/configure.ac ]]; then
    echo "==> Fetching openconnect submodule"
    git submodule update --init --recursive
fi

# libxml2 is keg-only; make its pkg-config file visible.
export PKG_CONFIG_PATH="${BREW_PREFIX}/opt/libxml2/lib/pkgconfig:${BREW_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="${BREW_PREFIX}/bin:${PATH}"

echo "==> Building gpclient and gpauth (${PROFILE})"
# gpclient hands SAML portals to a sibling gpauth binary. webview-auth pulls
# in a Tauri/WebKit window the macOS app does not use; both binaries are
# built without it and authenticate through the external browser instead.
cargo build "${CARGO_FLAGS[@]}" -p gpclient -p gpauth --no-default-features

for bin in gpclient gpauth; do
    echo "==> $("target/${PROFILE}/${bin}" --version)"
    echo "✓ target/${PROFILE}/${bin}"
done
