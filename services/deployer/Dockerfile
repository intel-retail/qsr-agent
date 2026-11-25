# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_NO_INPUT=1 \
    QSR_DEPLOYER_INVENTORY=/run/deployer/inventory.yaml

RUN useradd --create-home --uid 10003 --shell /usr/sbin/nologin deployer

WORKDIR /opt/qsr-deployer
COPY pyproject.toml ./
COPY deployer ./deployer
RUN pip install .

# docker-compose runs this as the host user (HOST_UID) so mounted 0600 SSH keys stay readable.
USER deployer
EXPOSE 8095
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=5 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8095/health', timeout=3)"]
ENTRYPOINT ["qsr-deployer"]
CMD ["serve", "--transport", "http", "--host", "0.0.0.0", "--port", "8095"]
