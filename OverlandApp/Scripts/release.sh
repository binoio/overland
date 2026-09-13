#!/bin/zsh
#
# release.sh: Build, sign, notarize (App Store Connect API), EdDSA-sign,
# and publish an Overland release with an updated Sparkle appcast.
#
# One-time setup:
#   1. App Store Connect API key stored as a notarytool profile
#      (xcrun notarytool store-credentials <profile> --key AuthKey.p8 --key-id … --issuer …).
#   2. Sparkle EdDSA key pair in the login Keychain: generate_keys --account Overland
#      (public key in Scripts/bundle.sh as SPARKLE_ED_PUBLIC_KEY).
#   3. gh auth login with access to binoio/overland.
#
# Usage: zsh OverlandApp/Scripts/release.sh
#   OVERLAND_SIGN_IDENTITY   Developer ID Application identity (default: first in keychain)
#   OVERLAND_NOTARY_PROFILE  notarytool keychain profile (default: atmo-notary)
set -euo pipefail

REPO="binoio/overland"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="${REPO_ROOT}/OverlandApp"
cd "$REPO_ROOT"

IDENTITY="${OVERLAND_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
NOTARY_PROFILE="${OVERLAND_NOTARY_PROFILE:-atmo-notary}"
SPARKLE_ACCOUNT="Overland"

VERSION=$(tr -d '[:space:]' < "${APP_DIR}/VERSION")
TAG="v${VERSION}"
APP="dist/Overland.app"
ZIP="dist/Overland-${VERSION}.zip"
NOTES_MD="ReleaseNotes/Overland-${VERSION}.md"
NOTES_HTML="ReleaseNotes/Overland-${VERSION}.html"

echo "==> Preflight for Overland ${VERSION}"
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity in keychain" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean" >&2; exit 1; }
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2; exit 1
fi
LATEST_TAG=$(git tag -l 'v*' | sort -V | tail -1)
if [[ -n "$LATEST_TAG" && "$(print -l "$LATEST_TAG" "$TAG" | sort -V | tail -1)" != "$TAG" ]]; then
    echo "error: VERSION ($VERSION) is not newer than latest tag ($LATEST_TAG)" >&2; exit 1
fi
[[ -f "$NOTES_MD" ]] || { echo "error: $NOTES_MD missing" >&2; exit 1; }
[[ -f "$NOTES_HTML" ]] || { echo "error: $NOTES_HTML missing" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || { echo "error: notarytool profile '$NOTARY_PROFILE' not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated" >&2; exit 1; }
security find-generic-password -a "$SPARKLE_ACCOUNT" -l "Private key for signing Sparkle updates" >/dev/null 2>&1 \
    || { echo "error: Sparkle EdDSA key for account '$SPARKLE_ACCOUNT' not in keychain" >&2; exit 1; }

echo "==> Building"
zsh "${APP_DIR}/Scripts/build_gpclient.sh"
OVERLAND_SIGN_IDENTITY="$IDENTITY" zsh "${APP_DIR}/Scripts/bundle.sh"

SPARKLE_BIN=$(find "${APP_DIR}/.build/artifacts" -type d -name bin -path "*parkle*" | head -1)
[[ -n "$SPARKLE_BIN" ]] || { echo "error: Sparkle tools not found under OverlandApp/.build/artifacts" >&2; exit 1; }

echo "==> Verifying bundle"
PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" == "io.bino.overland" ]] || { echo "error: wrong bundle id" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] || { echo "error: bundle version mismatch" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$PLIST")" == https://* ]] || { echo "error: SUFeedURL missing or not https" >&2; exit 1; }
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")" ]] || { echo "error: SUPublicEDKey missing" >&2; exit 1; }
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || { echo "error: Sparkle.framework not embedded" >&2; exit 1; }
for f in gpclient gpauth overland-exec OverlandHelper; do
    [[ -x "$APP/Contents/MacOS/$f" ]] || { echo "error: $f missing" >&2; exit 1; }
done
[[ -f "$APP/Contents/Library/LaunchDaemons/io.bino.overland.helper.plist" ]] || { echo "error: helper plist missing" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
[[ "$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')" != "not set" ]] || { echo "error: bundle is not Developer ID signed" >&2; exit 1; }

echo "==> Notarizing via App Store Connect API"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Generating appcast (EdDSA signature from login Keychain)"
WORK="dist/appcast-work"
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ZIP" "$WORK/"
cp "$NOTES_HTML" "$WORK/Overland-${VERSION}.html"
"$SPARKLE_BIN/generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
    --embed-release-notes \
    -o docs/appcast.xml "$WORK"

echo "==> Publishing (release first so the asset exists before the appcast goes live)"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Overland ${VERSION}" --notes-file "$NOTES_MD"

git add docs/appcast.xml
git commit -m "Publish appcast for ${VERSION}"
git push origin HEAD

echo "==> Done: Overland ${VERSION} released. Pages will deploy the appcast shortly."
