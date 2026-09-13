#!/bin/zsh
#
# notarize.sh: Sign dist/Overland.app with a Developer ID certificate,
# notarize it with Apple, staple the ticket, and produce a distributable zip.
#
# One-time setup:
#   xcrun notarytool store-credentials overland-notary \
#       --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#
# Usage: zsh OverlandApp/Scripts/notarize.sh
#   OVERLAND_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  (required)
#   OVERLAND_NOTARY_PROFILE=overland-notary                       (default)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="${REPO_ROOT}/OverlandApp"
APP="${REPO_ROOT}/dist/Overland.app"
ENTITLEMENTS="${APP_DIR}/Support/Overland.entitlements"
IDENTITY="${OVERLAND_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${OVERLAND_NOTARY_PROFILE:-overland-notary}"

[[ -d "$APP" ]] || { echo "error: ${APP} missing; run Scripts/bundle.sh first" >&2; exit 1; }
[[ -n "$IDENTITY" ]] || { echo "error: set OVERLAND_SIGN_IDENTITY to your Developer ID Application identity" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" || { echo "error: identity not in keychain: ${IDENTITY}" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
ZIP="${REPO_ROOT}/dist/Overland-${VERSION}.zip"

echo "==> Signing inside-out (never --deep for the final pass)"
for lib in "${APP}/Contents/Frameworks"/*.dylib(N); do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$lib"
done
for helper in gpclient gpauth overland-exec; do
    if [[ -x "${APP}/Contents/MacOS/${helper}" ]]; then
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "${APP}/Contents/MacOS/${helper}"
    fi
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"

echo "✓ ${ZIP}"
