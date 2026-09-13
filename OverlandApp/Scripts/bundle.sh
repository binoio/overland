#!/bin/zsh
#
# bundle.sh: Build the SwiftUI app in release mode and assemble
# dist/Overland.app, embedding gpclient, its Homebrew dylibs, and
# OpenConnect's vpnc-script so the bundle is self-contained.
#
# Usage: zsh OverlandApp/Scripts/bundle.sh [--skip-gpclient]   (--skip-gpclient: do not embed gpclient; rely on Homebrew or a custom path)
#   GPCLIENT=/path/to/gpclient       override the gpclient binary to embed
#   GPAUTH=/path/to/gpauth           override the gpauth binary to embed (SAML logins)
#   VPNC_SCRIPT=/path/to/vpnc-script override the vpnc-script to embed
#   APP_VERSION=x.y.z                override the version stamped into Info.plist
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="${REPO_ROOT}/OverlandApp"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/Overland.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
FRAMEWORKS_DIR="${CONTENTS}/Frameworks"

SKIP_GPCLIENT=0
[[ "${1:-}" == "--skip-gpclient" ]] && SKIP_GPCLIENT=1

cd "$REPO_ROOT"

echo "==> Building Overland (release)"
xcrun swift build -c release --package-path "$APP_DIR" --product Overland
BIN_PATH="$(xcrun swift build -c release --package-path "$APP_DIR" --show-bin-path)"

echo "==> Assembling bundle at ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "${BIN_PATH}/Overland" "${MACOS_DIR}/Overland"
chmod +x "${MACOS_DIR}/Overland"

# SwiftPM resource bundle (icon etc.) plus a flat copy of the icon for CFBundleIconFile.
if [[ -d "${BIN_PATH}/Overland_Overland.bundle" ]]; then
    ditto "${BIN_PATH}/Overland_Overland.bundle" "${RESOURCES_DIR}/Overland_Overland.bundle"
fi
cp "${APP_DIR}/Sources/Overland/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

cp "${APP_DIR}/Support/Info.plist" "${CONTENTS}/Info.plist"
VERSION="${APP_VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS}/Info.plist"
echo "APPL????" > "${CONTENTS}/PkgInfo"

# ---------------------------------------------------------------------------
# gpclient + dylib closure
# ---------------------------------------------------------------------------
if (( ! SKIP_GPCLIENT )); then
    GPCLIENT="${GPCLIENT:-${REPO_ROOT}/target/release/gpclient}"
    if [[ ! -x "$GPCLIENT" ]]; then
        echo "error: gpclient not found at ${GPCLIENT}; run Scripts/build_gpclient.sh or pass GPCLIENT=" >&2
        exit 1
    fi
    echo "==> Embedding gpclient from ${GPCLIENT}"
    cp "$GPCLIENT" "${MACOS_DIR}/gpclient"
    chmod +x "${MACOS_DIR}/gpclient"

    # gpclient looks for gpauth next to its own executable for SAML portals.
    GPAUTH="${GPAUTH:-${GPCLIENT:h}/gpauth}"
    if [[ -x "$GPAUTH" ]]; then
        echo "==> Embedding gpauth from ${GPAUTH}"
        cp "$GPAUTH" "${MACOS_DIR}/gpauth"
        chmod +x "${MACOS_DIR}/gpauth"
    else
        echo "warning: gpauth not found at ${GPAUTH}; SAML/SSO portals will not work" >&2
    fi

    BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"

    # Collect every non-system dylib gpclient (transitively) links against.
    typeset -A SEEN
    QUEUE=("${MACOS_DIR}/gpclient")
    [[ -x "${MACOS_DIR}/gpauth" ]] && QUEUE+=("${MACOS_DIR}/gpauth")
    while (( ${#QUEUE[@]} )); do
        FILE="${QUEUE[1]}"
        QUEUE=("${QUEUE[@]:1}")
        for dep in $(otool -L "$FILE" | tail -n +2 | awk '{print $1}'); do
            case "$dep" in
                /usr/lib/*|/System/*|@*) continue ;;
            esac
            name="${dep:t}"
            if [[ -z "${SEEN[$name]:-}" ]]; then
                SEEN[$name]="$dep"
                cp "$dep" "${FRAMEWORKS_DIR}/${name}"
                chmod u+w "${FRAMEWORKS_DIR}/${name}"
                QUEUE+=("${FRAMEWORKS_DIR}/${name}")
            fi
        done
    done

    echo "==> Rewriting install names for ${#SEEN[@]} dylibs"
    for name in "${(@k)SEEN}"; do
        install_name_tool -id "@executable_path/../Frameworks/${name}" "${FRAMEWORKS_DIR}/${name}"
    done
    for target in "${MACOS_DIR}/gpclient" "${MACOS_DIR}"/gpauth(N) "${FRAMEWORKS_DIR}"/*.dylib; do
        for name in "${(@k)SEEN}"; do
            install_name_tool -change "${SEEN[$name]}" "@executable_path/../Frameworks/${name}" "$target" 2>/dev/null || true
            # Homebrew also links via @loader_path/@rpath in places.
            for alt in $(otool -L "$target" | tail -n +2 | awk '{print $1}' | grep "/${name}$" || true); do
                install_name_tool -change "$alt" "@executable_path/../Frameworks/${name}" "$target" 2>/dev/null || true
            done
        done
        # Modified Mach-O files need a fresh (ad-hoc) signature on Apple Silicon.
        codesign --force --sign - "$target" >/dev/null 2>&1 || true
    done

    LEFTOVER="$(otool -L "${MACOS_DIR}/gpclient" "${MACOS_DIR}"/gpauth(N) "${FRAMEWORKS_DIR}"/*.dylib | grep -E "^\s+${BREW_PREFIX:-/opt/homebrew}" || true)"
    if [[ -n "$LEFTOVER" ]]; then
        echo "error: Homebrew paths remain after rewriting:" >&2
        echo "$LEFTOVER" >&2
        exit 1
    fi

    # vpnc-script: prefer an explicit path, then the copy vendored for the Linux
    # packages (upstream vpnc-scripts, handles macOS utun/route/DNS), then Homebrew.
    VPNC_SCRIPT="${VPNC_SCRIPT:-}"
    if [[ -z "$VPNC_SCRIPT" ]]; then
        for candidate in \
            "${REPO_ROOT}/packaging/files/usr/libexec/gpclient/vpnc-script" \
            "${BREW_PREFIX}/etc/vpnc/vpnc-script" \
            /etc/vpnc/vpnc-script; do
            [[ -f "$candidate" ]] && { VPNC_SCRIPT="$candidate"; break; }
        done
    fi
    if [[ -z "$VPNC_SCRIPT" ]]; then
        echo "warning: no vpnc-script found; the app will need one configured in Settings ▸ Backend" >&2
    else
        echo "==> Embedding vpnc-script from ${VPNC_SCRIPT}"
        cp "$VPNC_SCRIPT" "${RESOURCES_DIR}/vpnc-script"
        chmod 755 "${RESOURCES_DIR}/vpnc-script"
    fi
fi

# Ad-hoc sign the whole bundle so Gatekeeper/TCC treat it as a stable identity
# during local runs. notarize.sh replaces this with a Developer ID signature.
codesign --force --deep --sign - --entitlements "${APP_DIR}/Support/Overland.entitlements" "$APP_BUNDLE" >/dev/null

echo "✓ ${APP_BUNDLE} (version ${VERSION})"
