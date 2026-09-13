#!/bin/sh

# Wrapper for gpclient hip
LOGFILE="/tmp/gpclient-hipreport.log"

GPCLIENT_EXEC=""
for candidate in \
    "${GPCLIENT_BIN:-}" \
    "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/gpclient" \
    "$(cd "$(dirname "$0")/../MacOS" 2>/dev/null && pwd)/gpclient" \
    "/Applications/Overland.app/Contents/MacOS/gpclient" \
    "${HOME}/Applications/Overland.app/Contents/MacOS/gpclient" \
    "/opt/homebrew/bin/gpclient" \
    "/usr/local/bin/gpclient" \
    "/usr/bin/gpclient"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        GPCLIENT_EXEC="$candidate"
        break
    fi
done

if [ -z "$GPCLIENT_EXEC" ]; then
    GPCLIENT_EXEC="$(command -v gpclient 2>/dev/null || true)"
fi

if [ -z "$GPCLIENT_EXEC" ] || [ ! -x "$GPCLIENT_EXEC" ]; then
    echo "Error: gpclient binary not found." > "$LOGFILE"
    exit 1
fi

# Ensure --client-version is supplied if not already present in arguments
EXTRA_ARGS=""
if ! printf '%s\n' "$@" | grep -q -- '--client-version'; then
    EXTRA_ARGS="--client-version ${APP_VERSION:-6.2.4-49}"
fi

# Redirect the debug output to logfile and emit XML report to stdout
HIP_REPORT_OUTPUT=$(exec 2> "$LOGFILE" "$GPCLIENT_EXEC" hip $EXTRA_ARGS "$@")
echo "$HIP_REPORT_OUTPUT"
