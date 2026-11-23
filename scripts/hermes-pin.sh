#!/usr/bin/env bash
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Hermes installer revision used by this repo: the installer script at the commit tagged
# v0.23.0 (the release intel/qsr-agent:2026.3.0-rc1 ships), with its SHA-256.
# The image build (install-hermes.sh) and the host install (setup.sh, which passes the same values
# to agent-harness-install as HERMES_PINNED_COMMIT/HERMES_PINNED_SHA256) both install exactly this
# release, verified by SHA-256.
# Override both together (HERMES_INSTALL_COMMIT + HERMES_INSTALL_SHA256) to adopt another release;
# HERMES_INSTALL_URL may point at a mirror of the same installer script.
if [[ -n ${HERMES_INSTALL_COMMIT:-} && -z ${HERMES_INSTALL_SHA256:-} ]] ||
    [[ -z ${HERMES_INSTALL_COMMIT:-} && -n ${HERMES_INSTALL_SHA256:-} ]]; then
    printf '[hermes-pin] ERROR: set HERMES_INSTALL_COMMIT and HERMES_INSTALL_SHA256 together; the SHA-256 is that of scripts/install.sh at that hermes-agent commit.\n' >&2
    # `return` when sourced (install-hermes.sh, setup.sh), `exit` when executed.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi
HERMES_INSTALL_COMMIT=${HERMES_INSTALL_COMMIT:-2bd378ed1b8d6bf2192cb26e0a55ff3091e6bd19}
HERMES_INSTALL_SHA256=${HERMES_INSTALL_SHA256:-abf338605dae6dd28d101673ac6aed7995c955745db46d47676bc591a7957209}
HERMES_INSTALL_URL=${HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/$HERMES_INSTALL_COMMIT/scripts/install.sh}
