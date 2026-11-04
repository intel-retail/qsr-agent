#!/usr/bin/env bash
# Install Hermes inside a container image from the installer revision pinned in
# scripts/hermes-pin.sh, verified by SHA-256. The agent-harness-install flow needs a Docker
# host, so the image build runs the Hermes installer directly with image-specific flags.
#
# Usage: scripts/install-hermes.sh   (HOME must be the target user's home)
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=hermes-pin.sh
source "$SCRIPT_DIR/hermes-pin.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() { printf '[install-hermes] ERROR: %s\n' "$*" >&2; exit 1; }

installer=$work/install-hermes.sh
curl -fsSL "$HERMES_INSTALL_URL" -o "$installer"
echo "$HERMES_INSTALL_SHA256  $installer" | sha256sum -c - >/dev/null || fail "Hermes installer failed its SHA-256 check."

# Retries cover GitHub rate limits (HTTP 429) and intermittent TLS chain failures.
for attempt in 1 2 3 4 5; do
    if bash "$installer" --skip-setup --non-interactive --skip-browser --skip-computer-use --commit "$HERMES_INSTALL_COMMIT"; then
        exit 0
    fi
    [[ $attempt -lt 5 ]] || fail "Hermes install failed after $attempt attempts."
    wait_seconds=$((attempt * 60))
    echo "Hermes install attempt $attempt failed; retrying in ${wait_seconds}s" >&2
    sleep "$wait_seconds"
done
