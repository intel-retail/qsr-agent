#!/usr/bin/env bash
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
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

# Retries cover GitHub rate limits (HTTP 429) and intermittent TLS chain failures on the
# installer download as well as on the downloads the installer itself performs. A failed
# SHA-256 check is retried once (a truncated download looks the same as a wrong pin); the
# same wrong digest twice means the pin is wrong, and that fails immediately.
last_actual=
for attempt in 1 2 3 4 5; do
    step="download of $HERMES_INSTALL_URL"
    if curl -fsSL --retry 3 --retry-all-errors --retry-delay 5 "$HERMES_INSTALL_URL" -o "$installer"; then
        actual=$(sha256sum "$installer" | cut -d' ' -f1)
        step="SHA-256 check of the Hermes installer (expected $HERMES_INSTALL_SHA256, got $actual)"
        if [[ $actual == "$HERMES_INSTALL_SHA256" ]]; then
            step="Hermes installer run"
            if bash "$installer" --skip-setup --non-interactive --skip-browser --skip-computer-use --commit "$HERMES_INSTALL_COMMIT"; then
                exit 0
            fi
        elif [[ $actual == "$last_actual" ]]; then
            fail "Hermes installer digest mismatch on two downloads: $step. Update HERMES_INSTALL_SHA256 for this commit/URL."
        fi
        last_actual=$actual
    fi
    [[ $attempt -lt 5 ]] || fail "Hermes install failed after $attempt attempts; last failure: $step."
    wait_seconds=$((attempt * 60))
    echo "Hermes install attempt $attempt failed ($step); retrying in ${wait_seconds}s" >&2
    sleep "$wait_seconds"
done
