#!/bin/zsh
#
# run.sh: Launch the app for development.
#
#   zsh OverlandApp/Scripts/run.sh          # swift run (debug, from the package)
#   zsh OverlandApp/Scripts/run.sh --bundle # build dist/Overland.app and open it
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="${REPO_ROOT}/OverlandApp"

if [[ "${1:-}" == "--bundle" ]]; then
    zsh "${APP_DIR}/Scripts/bundle.sh" "${@:2}"
    open "${REPO_ROOT}/dist/Overland.app"
    exit 0
fi

# Running from the repository root lets BinaryLocator find target/release/gpclient.
cd "$REPO_ROOT"
exec xcrun swift run --package-path "$APP_DIR" Overland
