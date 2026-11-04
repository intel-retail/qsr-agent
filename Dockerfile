# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# Operator UI: compile the React app; the runtime image only receives the static output.
FROM node:20-slim AS ui-builder
WORKDIR /ui
COPY operator-ui/frontend/package.json operator-ui/frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY operator-ui/frontend/ ./
# vite.config.ts writes to ../dist, i.e. /dist inside this stage.
RUN npm run build


FROM python:3.12-slim AS builder

# Hermes installer revision; empty keeps the commit and SHA-256 pinned in scripts/hermes-pin.sh.
# To override, set both.
ARG HERMES_INSTALL_COMMIT=
ARG HERMES_INSTALL_SHA256=

ENV HOME=/home/qsr \
    PATH=/home/qsr/.local/bin:/opt/qsr/.venv/mcp/bin:$PATH \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    PIP_NO_CACHE_DIR=1 \
    # Hermes installs a standalone Python that ignores Debian's /etc/ssl/certs;
    # point it at the system CA bundle so its urllib-based downloads verify TLS.
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash build-essential ca-certificates curl git libffi-dev python3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /bin/bash qsr \
    && mkdir -p /opt/qsr && chown -R qsr:qsr /opt/qsr /home/qsr

WORKDIR /opt/qsr

# Installed before the app source so code edits don't re-run this slow, flaky download.
USER qsr
COPY --chown=qsr:qsr scripts/hermes-pin.sh scripts/install-hermes.sh /tmp/qsr-install/
RUN if [ -n "$HERMES_INSTALL_COMMIT" ]; then export HERMES_INSTALL_COMMIT; fi \
    && if [ -n "$HERMES_INSTALL_SHA256" ]; then export HERMES_INSTALL_SHA256; fi \
    && bash /tmp/qsr-install/install-hermes.sh \
    && rm -rf /tmp/qsr-install

COPY --chown=qsr:qsr autonomy/requirements.txt /opt/qsr/autonomy/requirements.txt
RUN python3 -m venv /opt/qsr/.venv/mcp \
    && /opt/qsr/.venv/mcp/bin/python -m pip install --upgrade pip \
    && /opt/qsr/.venv/mcp/bin/python -m pip install \
    -r /opt/qsr/autonomy/requirements.txt PyYAML \
    && rm -rf /home/qsr/.cache


# Runtime stage: no compilers, git, or install caches — only what the app runs on.
FROM python:3.12-slim

ENV HOME=/home/qsr \
    PATH=/home/qsr/.local/bin:/opt/qsr/.venv/mcp/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash ca-certificates ffmpeg ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /bin/bash qsr \
    && mkdir -p /opt/qsr /home/qsr/.hermes /home/qsr/.local/state/qsr-agent \
    && chown -R qsr:qsr /opt/qsr /home/qsr

WORKDIR /opt/qsr
USER qsr

# Hermes CLI + standalone runtime and the MCP venv, built in the builder stage.
# ~/.hermes holds the actual hermes binary and seeds the hermes-home volume on
# first run, so it must be baked in; ~/.local has the launcher on PATH.
COPY --from=builder --chown=qsr:qsr /home/qsr/.local /home/qsr/.local
COPY --from=builder --chown=qsr:qsr /home/qsr/.hermes /home/qsr/.hermes
COPY --from=builder --chown=qsr:qsr /opt/qsr/.venv /opt/qsr/.venv

COPY --chown=qsr:qsr . .
COPY --from=ui-builder --chown=qsr:qsr /dist /opt/qsr/operator-ui/dist

EXPOSE 8600
ENTRYPOINT ["/opt/qsr/.venv/mcp/bin/python", "/opt/qsr/entrypoint.py"]