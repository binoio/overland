#!/bin/zsh
#
# test.sh: Run the app's test suites.
#
#   zsh JeepNetApp/Scripts/test.sh            # Swift tests on this Mac (core + app)
#   zsh JeepNetApp/Scripts/test.sh --docker   # core tests in a Linux container (what CI runs)
#   zsh JeepNetApp/Scripts/test.sh --all      # both, plus the Rust gpapi tests touched by the app
#
# The RealGpclientIntegrationTests run automatically when a gpclient binary
# is found (target/release/gpclient or Homebrew) and are skipped otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="${REPO_ROOT}/JeepNetApp"
MODE="${1:-local}"

run_local() {
    echo "==> swift test (macOS)"
    (cd "$REPO_ROOT" && xcrun swift test --package-path "$APP_DIR")
}

run_docker() {
    echo "==> JeepNetCore tests in Docker"
    local compose="docker compose"
    $compose version >/dev/null 2>&1 || compose="docker-compose"
    (cd "$APP_DIR" && $compose run --rm --build core-tests)
}

run_rust() {
    echo "==> cargo test -p gpapi (portal config gateway inventory used by the app)"
    export PATH="$(brew --prefix)/bin:${PATH}"
    (cd "$REPO_ROOT" && cargo test -p gpapi --lib portal::config)
}

case "$MODE" in
    local)    run_local ;;
    --docker) run_docker ;;
    --all)    run_local; run_docker; run_rust ;;
    *) echo "usage: $0 [--docker|--all]" >&2; exit 2 ;;
esac
