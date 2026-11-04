#!/usr/bin/env bash
# Fetch agent-harness-install (open-edge-platform/edge-ai-libraries) at the pinned
# commit and print the path of its directory. It installs Hermes and the OVMS +
# Inference Router stack, so this repo does not reimplement them.
#
# Usage: scripts/fetch-harness.sh <dest-dir>
# Bump HARNESS_INSTALL_REF to adopt a newer installer; it must be a full commit SHA.
set -Eeuo pipefail

HARNESS_INSTALL_REPO=${HARNESS_INSTALL_REPO:-https://github.com/open-edge-platform/edge-ai-libraries.git}
HARNESS_INSTALL_REF=${HARNESS_INSTALL_REF:-b3676656a6001a9d86b783823da7fe715fef5b36}
HARNESS_SUBDIR=frameworks/agent-harness-install
dest=${1:?usage: fetch-harness.sh <dest-dir>}

fail() { printf '[fetch-harness] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $HARNESS_INSTALL_REF =~ ^[0-9a-f]{40}$ ]] ||
    fail "HARNESS_INSTALL_REF must be a full 40-character commit SHA, got '$HARNESS_INSTALL_REF'."

if [[ -f "$dest/$HARNESS_SUBDIR/install.sh" && -d "$dest/.git" ]] &&
    [[ $(git -C "$dest" rev-parse HEAD 2>/dev/null || true) == "$HARNESS_INSTALL_REF" ]]; then
    printf '%s\n' "$dest/$HARNESS_SUBDIR"
    exit 0
fi

# HARNESS_DIR is user-settable: only replace a directory that is empty or is a previous checkout
# of this same repository, never an unrelated directory.
if [[ -e $dest && -n $(ls -A -- "$dest" 2>/dev/null) ]]; then
    [[ $(git -C "$dest" remote get-url origin 2>/dev/null || true) == "$HARNESS_INSTALL_REPO" ]] ||
        fail "$dest is not empty and is not a checkout of $HARNESS_INSTALL_REPO; refusing to replace it. Set HARNESS_DIR to an empty or new directory."
fi
rm -rf -- "$dest"
mkdir -p "$dest"
# A SHA fetch from a fresh repo; retried because corporate proxies drop single fetches.
for attempt in 1 2 3; do
    if (
        cd "$dest" &&
        rm -rf .git &&
        git init -q &&
        git remote add origin "$HARNESS_INSTALL_REPO" &&
        git fetch -q --depth 1 origin "$HARNESS_INSTALL_REF" &&
        git checkout -q FETCH_HEAD -- "$HARNESS_SUBDIR" &&
        git update-ref HEAD FETCH_HEAD
    ) >&2; then
        [[ -f "$dest/$HARNESS_SUBDIR/install.sh" ]] || fail "$HARNESS_SUBDIR/install.sh missing at $HARNESS_INSTALL_REF."
        printf '%s\n' "$dest/$HARNESS_SUBDIR"
        exit 0
    fi
    [[ $attempt -lt 3 ]] || break
    printf '[fetch-harness] fetch failed (attempt %s/3); retrying\n' "$attempt" >&2
    sleep 5
done
fail "Could not fetch $HARNESS_SUBDIR at $HARNESS_INSTALL_REF from $HARNESS_INSTALL_REPO."
