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
#   OVERLAND_SIGN_IDENTITY="…"       Developer ID Application identity to sign with
#                                    (default: the first one in the keychain; ad-hoc if none).
#                                    The privileged helper only works in a Developer ID-signed build.
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
xcrun swift build -c release --package-path "$APP_DIR" --product overland-exec
xcrun swift build -c release --package-path "$APP_DIR" --product OverlandHelper
BIN_PATH="$(xcrun swift build -c release --package-path "$APP_DIR" --show-bin-path)"

echo "==> Assembling bundle at ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "${CONTENTS}/Library/LaunchDaemons"

cp "${BIN_PATH}/Overland" "${MACOS_DIR}/Overland"
chmod +x "${MACOS_DIR}/Overland"
# Signal-reset exec shim used by the privileged wrapper (see Sources/overland-exec).
cp "${BIN_PATH}/overland-exec" "${MACOS_DIR}/overland-exec"
chmod +x "${MACOS_DIR}/overland-exec"
# Sparkle.framework (the executable links it via @rpath/../Frameworks).
SPARKLE_FRAMEWORK=$(find "${APP_DIR}/.build" -type d -name "Sparkle.framework" -path "*artifacts*" -not -path "*dSYM*" 2>/dev/null | head -1)
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "error: Sparkle.framework not found under OverlandApp/.build; run 'swift build --package-path OverlandApp' first" >&2
    exit 1
fi
# ditto preserves the framework's Versions symlink structure; cp -R would not
ditto "$SPARKLE_FRAMEWORK" "${FRAMEWORKS_DIR}/Sparkle.framework"

# Privileged helper daemon + its launchd plist (registered via SMAppService).
cp "${BIN_PATH}/OverlandHelper" "${MACOS_DIR}/OverlandHelper"
chmod +x "${MACOS_DIR}/OverlandHelper"
cp "${APP_DIR}/Support/io.bino.overland.helper.plist" "${CONTENTS}/Library/LaunchDaemons/io.bino.overland.helper.plist"

# SwiftPM resource bundle (icon etc.) plus a flat copy of the icon for CFBundleIconFile.
if [[ -d "${BIN_PATH}/Overland_Overland.bundle" ]]; then
    ditto "${BIN_PATH}/Overland_Overland.bundle" "${RESOURCES_DIR}/Overland_Overland.bundle"
fi
cp "${APP_DIR}/Sources/Overland/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

cp "${APP_DIR}/Support/Info.plist" "${CONTENTS}/Info.plist"
# App version from OverlandApp/VERSION (the gpclient version is shown at runtime).
VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "${APP_DIR}/VERSION")}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS}/Info.plist"

# Sparkle update feed (served from the bino.io/overland GitHub Pages site) and EdDSA public key.
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://bino.io/overland/appcast.xml}"
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-OQFwn9WVxQKkQPZe3YR8ZQuxspf2RfaEGaUZgkmeGvY=}"
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "${CONTENTS}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${SPARKLE_FEED_URL}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "${CONTENTS}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_ED_PUBLIC_KEY}" "${CONTENTS}/Info.plist"
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

    HIPREPORT_SCRIPT="${HIPREPORT_SCRIPT:-}"
    if [[ -z "$HIPREPORT_SCRIPT" ]]; then
        for candidate in \
            "${REPO_ROOT}/packaging/files/usr/libexec/gpclient/hipreport.sh" \
            "${BREW_PREFIX}/opt/openconnect/libexec/openconnect/hipreport.sh"; do
            [[ -f "$candidate" ]] && { HIPREPORT_SCRIPT="$candidate"; break; }
        done
    fi
    if [[ -n "$HIPREPORT_SCRIPT" ]]; then
        echo "==> Embedding hipreport.sh from ${HIPREPORT_SCRIPT}"
        cp "$HIPREPORT_SCRIPT" "${RESOURCES_DIR}/hipreport.sh"
        chmod 755 "${RESOURCES_DIR}/hipreport.sh"
    fi
fi

# ---------------------------------------------------------------------------
# Signing. A Developer ID signature (same Team ID on the app and the helper)
# is what lets SMAppService register the privileged helper; without one the
# bundle is ad-hoc signed and the app falls back to the administrator dialog.
# Signed inside-out; never --deep for the final pass.
# ---------------------------------------------------------------------------
IDENTITY="${OVERLAND_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

# Strip extended attributes (such as com.apple.macl) before signing
xattr -cr "$APP_BUNDLE"

if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing with: ${IDENTITY}"
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
    for lib in "${FRAMEWORKS_DIR}"/*.dylib(N); do "${SIGN[@]}" "$lib" >/dev/null; done
    # Sparkle's helpers are signed individually, inside-out; the XPC services keep their entitlements.
    SF="${FRAMEWORKS_DIR}/Sparkle.framework"
    "${SIGN[@]}" "$SF/Versions/B/Autoupdate" >/dev/null
    "${SIGN[@]}" "$SF/Versions/B/Updater.app" >/dev/null
    "${SIGN[@]}" --preserve-metadata=entitlements "$SF/Versions/B/XPCServices/Installer.xpc" >/dev/null
    "${SIGN[@]}" --preserve-metadata=entitlements "$SF/Versions/B/XPCServices/Downloader.xpc" >/dev/null
    "${SIGN[@]}" "$SF" >/dev/null
    for helper in gpclient gpauth overland-exec; do
        [[ -x "${MACOS_DIR}/${helper}" ]] && "${SIGN[@]}" "${MACOS_DIR}/${helper}" >/dev/null
    done
    "${SIGN[@]}" --identifier "io.bino.overland.helper" --entitlements "${APP_DIR}/Support/OverlandHelper.entitlements" "${MACOS_DIR}/OverlandHelper" >/dev/null
    "${SIGN[@]}" --entitlements "${APP_DIR}/Support/Overland.entitlements" "$APP_BUNDLE" >/dev/null
    codesign --verify --deep --strict "$APP_BUNDLE"
    echo "    Team ID: $(codesign -dv "$APP_BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
else
    echo "==> No Developer ID identity found; ad-hoc signing (privileged helper unavailable, admin dialog is used)"
    codesign --force --deep --sign - --entitlements "${APP_DIR}/Support/Overland.entitlements" "$APP_BUNDLE" >/dev/null
fi

echo "✓ ${APP_BUNDLE} (version ${VERSION})"
