#!/usr/bin/env bash
# Hermes installer revision used by this repo: the installer script at the commit tagged
# v0.22.6, with its SHA-256. The agent-harness-install default (v0.22.2) predates the
# gateway API server this repo depends on, so the pin is kept here instead.
# The image build (install-hermes.sh) and the host install (setup.sh, which sets the same values
# in the agent-harness-install checkout) both install exactly this release, verified by SHA-256.
# Override both together (HERMES_INSTALL_COMMIT + HERMES_INSTALL_SHA256) to adopt another release.
HERMES_INSTALL_COMMIT=${HERMES_INSTALL_COMMIT:-f0d94882e89ab8d4098b5bb2f166adfb9ee0a0ab}
HERMES_INSTALL_SHA256=${HERMES_INSTALL_SHA256:-abf338605dae6dd28d101673ac6aed7995c955745db46d47676bc591a7957209}
HERMES_INSTALL_URL=${HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/$HERMES_INSTALL_COMMIT/scripts/install.sh}
