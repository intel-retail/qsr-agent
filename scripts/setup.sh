#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Model comes from .env.example (single source); an exported MODEL_ID overrides it.
MODEL_ID=${MODEL_ID:-$(sed -n 's/^MODEL_ID=//p' "$ROOT_DIR/.env.example")}
[[ -n "$MODEL_ID" ]] || { echo "[qsr-setup] ERROR: set MODEL_ID in .env.example" >&2; exit 1; }
# Same model directory as `make up` (MODEL_ROOT), so the two install paths share one copy.
MODEL_ROOT=${MODEL_ROOT:-$(sed -n 's/^MODEL_ROOT=//p' "$ROOT_DIR/.env.example")}
MODEL_ROOT=${MODEL_ROOT:-./models}
[[ $MODEL_ROOT == /* ]] || MODEL_ROOT="$ROOT_DIR/${MODEL_ROOT#./}"
# OVMS, the Inference Router and Hermes are installed by agent-harness-install
# (open-edge-platform/edge-ai-libraries), fetched at the commit pinned in
# scripts/fetch-harness.sh. HARNESS_* variables are read by that installer.
HARNESS_DIR=${HARNESS_DIR:-"$ROOT_DIR/.harness"}
# Default off 8000 to avoid clashing with SAD's alert-service (make up binds :8000).
OVMS_PORT=${OVMS_PORT:-4444}
HARNESS_OVMS_REST_PORT=$OVMS_PORT
# Next to OVMS; 8010/8011 are the Order Accuracy MCP defaults and 8014 the kiosk's.
HARNESS_IR_PORT=${HARNESS_IR_PORT:-4445}
if [[ $OVMS_PORT == "$HARNESS_IR_PORT" ]]; then
    echo "[qsr-setup] ERROR: OVMS_PORT and HARNESS_IR_PORT are both $OVMS_PORT; set different ports." >&2
    exit 1
fi
HARNESS_MODELS_DIR=${HARNESS_MODELS_DIR:-$MODEL_ROOT}
# Earlier versions exported models under the harness state directory. Reuse such an export
# rather than downloading a second copy; install_inference_and_hermes says how to consolidate.
LEGACY_MODELS_DIR="$HOME/.agent-harness-install/models"
if [[ $HARNESS_MODELS_DIR == "$MODEL_ROOT" && -f "$LEGACY_MODELS_DIR/$MODEL_ID/graph.pbtxt" && ! -e "$MODEL_ROOT/$MODEL_ID" ]]; then
    HARNESS_MODELS_DIR=$LEGACY_MODELS_DIR
fi
HARNESS_OVMS_CONTAINER=${HARNESS_OVMS_CONTAINER:-agent-harness-install-ovms}
HARNESS_IR_CONTAINER=${HARNESS_IR_CONTAINER:-agent-harness-install-ir}
# The harness runs OVMS with --config_path, which rejects model flags such as --tool_parser and
# --task (the container crash-loops), so leave this empty.
HARNESS_OVMS_EXTRA_ARGS=${HARNESS_OVMS_EXTRA_ARGS:-}
# Set to 1 to accept OVMS running on the CPU (debugging only; the agent is unusably slow).
ALLOW_CPU_INFERENCE=${ALLOW_CPU_INFERENCE:-0}
export HARNESS_OVMS_REST_PORT HARNESS_IR_PORT HARNESS_OVMS_EXTRA_ARGS HARNESS_MODELS_DIR HARNESS_OVMS_CONTAINER HARNESS_IR_CONTAINER
ROUTER_URL=http://127.0.0.1:$HARNESS_IR_PORT/v1
# The Router matches model names exactly and serves the Hugging Face id without its org prefix.
SERVED_MODEL=${MODEL_ID##*/}
HERMES_CONFIG=${HERMES_CONFIG:-"$HOME/.hermes/config.yaml"}
SETUP_VENV=${SETUP_VENV:-"$ROOT_DIR/.venv/qsr-setup"}
SETUP_TARGET=${SETUP_TARGET:-"$ROOT_DIR/.venv/qsr-setup-target"}
# Dedicated venv whose interpreter launches the FastMCP kiosk/order-accuracy
# MCP servers and the operator UI (autonomy). Hermes runs the servers as subprocesses.
MCP_VENV=${MCP_VENV:-"$ROOT_DIR/.venv/mcp"}
MCP_VENV_PY="$MCP_VENV/bin/python"
# Operator UI: started automatically at the end of setup. Set START_UI=false to
# skip, or override host/port.
START_UI=${START_UI:-true}
# The direct model warm-up above is sufficient for first-inference compilation.
# A UI warm-up starts a full Hermes turn and can wait on remote MCP services, so
# keep it opt-in for distributed deployments.
WARM_UP_UI=${WARM_UP_UI:-false}
# Bind on all interfaces by default so the UI is reachable from a browser on
# another machine without SSH port forwarding. Set QSR_UI_HOST=127.0.0.1 to
# restrict to loopback.
QSR_UI_HOST=${QSR_UI_HOST:-0.0.0.0}
QSR_UI_PORT=${QSR_UI_PORT:-8600}
# Weather MCP service (services/weather), installed into the MCP venv. Keep the
# port in sync with the `weather` entry in agent-config/hermes/remote-mcp.example.yaml.
START_WEATHER=${START_WEATHER:-true}
WEATHER_SERVICE_DIR="$ROOT_DIR/services/weather"
WEATHER_HOST=${WEATHER_HOST:-127.0.0.1}
WEATHER_PORT=${WEATHER_PORT:-8090}
# Set by start_weather_service; empty disables weather reads in autonomy.
WEATHER_MCP_URL=""
# Store services (kiosk, order accuracy, ...) are remote MCP servers configured in
# agent-config/hermes/remote-mcp.example.yaml. This script never changes to add a service.
SETUP_PYTHON=python3
SETUP_PYTHONPATH=
CHECK_ONLY=false

# Run completely unattended: never block on an interactive prompt. Standard
# "assume defaults" signals for the tools this script drives; unknown ones are
# harmless. Commands that might still try to read a TTY are invoked with stdin
# closed (< /dev/null) at their call sites.
export DEBIAN_FRONTEND=noninteractive
export CI=1
export HERMES_NONINTERACTIVE=1
export HERMES_NO_ANALYTICS=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_INPUT=1
export HF_HUB_DISABLE_TELEMETRY=1

# The model and MCP services are all on loopback. If a proxy is configured,
# localhost must bypass it or the OVMS call fails with "403 incorrect proxy
# service". Ensure loopback is always in no_proxy for setup-time calls.
# The caller's own bypass list, either spelling, for the Hermes .env written by configure_hermes.
# NO_PROXY itself stays as before because agent-harness-install derives the Docker daemon's proxy
# drop-in from it, and a changed drop-in restarts dockerd.
export QSR_CALLER_NO_PROXY="${NO_PROXY:-}${no_proxy:+,$no_proxy}"
export NO_PROXY="localhost,127.0.0.1,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

usage() {
    cat <<'EOF'
Usage: scripts/setup.sh [--check]

Without arguments, install and configure the complete local QSR agent stack.
Use --check to validate an existing installation without changing it.

Optional environment variables:
    MODEL_ID            Hugging Face model ID
    MODEL_ROOT          Model directory shared with `make up` (default: from .env.example, ./models)
    HARNESS_INSTALL_REF agent-harness-install commit SHA (default: pinned in scripts/fetch-harness.sh)
    HERMES_INSTALL_COMMIT / HERMES_INSTALL_SHA256  Hermes installer revision and its SHA-256, set together
                        (default: pinned in scripts/hermes-pin.sh)
    HARNESS_DIR         Where the installer is fetched (default: <repo>/.harness)
    HARNESS_IR_PORT     Loopback port for the Inference Router (default: 4445)
    HARNESS_OVMS_IMAGE  OVMS image (default: the one agent-harness-install recommends)
    HARNESS_OVMS_EXTRA_ARGS  Extra OVMS server flags (default: none; model flags are rejected in config mode)
    HARNESS_MODELS_DIR  Where the harness stores OVMS models (default: MODEL_ROOT, or an existing
                        export under ~/.agent-harness-install/models from an earlier version)
    HARNESS_OVMS_CONTAINER  OVMS container name (default: agent-harness-install-ovms)
    HARNESS_IR_CONTAINER  Inference Router container name (default: agent-harness-install-ir)
    OVMS_PORT           Loopback port for OVMS (default: 4444)
    ALLOW_CPU_INFERENCE Set to 1 to accept OVMS without GPU access (default: fail)
    HERMES_CONFIG       Hermes YAML path
    SETUP_VENV          Helper virtual environment path
    SETUP_TARGET        Fallback isolated dependency path
    MCP_VENV            Venv for the weather service and autonomy runtime
    START_UI            Auto-start the operator UI after setup (default true)
    WARM_UP_UI          Run one warm-up UI chat request during setup (default false)
    QSR_UI_HOST         Operator UI bind host (default 0.0.0.0)
    QSR_UI_PORT         Operator UI bind port (default 8600)
    START_WEATHER       Start the weather MCP service (default true)
    WEATHER_HOST        Weather service bind host (default 127.0.0.1)
    WEATHER_PORT        Weather service port (default 8090)
EOF
}

log() {
    printf '[qsr-setup] %s\n' "$*"
}

fail() {
    printf '[qsr-setup] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing command '$1'. $2"
}

check_python_version() {
    python3 - <<'PY' || fail "Python 3.11 or newer is required."
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY
}

render_node() {
    local nodes=(/dev/dri/render*)
    [[ -e "${nodes[0]}" ]] || fail "No Intel render device found at /dev/dri/render*."
    printf '%s\n' "${nodes[0]}"
}

wait_for_router() {
    ROUTER_MODELS_URL="$ROUTER_URL/models" SERVED_MODEL="$SERVED_MODEL" \
        python3 - <<'PY'
import json
import os
import time
import urllib.request

deadline = time.monotonic() + 300
url = os.environ["ROUTER_MODELS_URL"]
model_id = os.environ["SERVED_MODEL"]
while time.monotonic() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            models = json.load(response).get("data", [])
        if any(model.get("id") == model_id for model in models):
            raise SystemExit(0)
    except Exception:
        pass
    time.sleep(2)
raise SystemExit(f"The Inference Router did not serve {model_id} within 300 seconds")
PY
}

check_prerequisites() {
    [[ $(uname -s) == Linux ]] || fail "This setup targets Linux."
    require_command curl "Install curl and rerun setup."
    require_command docker "Install Docker Engine and rerun setup."
    require_command python3 "Install Python 3.11 or newer and python3-venv."
    require_command stat "Install GNU coreutils and rerun setup."
    check_python_version
    check_python_venv
    docker info >/dev/null 2>&1 || fail "Docker is not running or this user cannot access it."
    render_node >/dev/null
}

# Everything that would need `sudo apt-get` is checked here, because stdin is closed for the
# installers below: a sudo password prompt cannot be answered and would just fail mid-run.
# Docker is required above (never installed here); the harness installs Node.js through nvm
# in the user's home without sudo.
check_python_venv() {
    python3 -c 'import venv, ensurepip, yaml' >/dev/null 2>&1 && return 0
    if sudo -n true 2>/dev/null; then
        return 0  # the harness installs python3-venv / python3-yaml itself
    fi
    fail "python3-venv or PyYAML is missing and passwordless sudo is unavailable. Install them first: sudo apt-get install -y python3-venv python3-pip python3-yaml"
}

# Pre-install the packages the Hermes installer would otherwise apt-install via
# an interactive `sudo` mid-run. Installing them here (only when passwordless
# sudo is available) removes the sudo password pause during install, so the
# script never stalls before configure_hermes writes the provider config.
ensure_build_packages() {
    command -v apt-get >/dev/null 2>&1 || return 0
    local pkgs=(build-essential python3-dev libffi-dev ripgrep ffmpeg)
    local missing=()
    local p
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    if sudo -n true 2>/dev/null; then
        log "Pre-installing build packages: ${missing[*]}"
        sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 || true
    else
        log "NOTE: optional packages missing (${missing[*]}) and passwordless sudo unavailable."
        log "      The Hermes installer may prompt for a sudo password, or you can pre-install:"
        log "        sudo apt-get install -y ${missing[*]}"
    fi
}

ensure_helper_venv() {
    if PYTHONPATH="$SETUP_TARGET" python3 -c \
        'import yaml' >/dev/null 2>&1; then
        SETUP_PYTHON=python3
        SETUP_PYTHONPATH=$SETUP_TARGET
        log "Using isolated setup helpers at $SETUP_TARGET"
        return
    fi
    if [[ ! -x "$SETUP_VENV/bin/python" ]] ||
        ! "$SETUP_VENV/bin/python" -m pip --version >/dev/null 2>&1; then
        log "Creating setup virtual environment"
        if ! python3 -m venv "$SETUP_VENV" 2>/dev/null; then
            log "venv support unavailable; using isolated pip --target fallback"
            mkdir -p "$SETUP_TARGET"
            python3 -m pip install --quiet --upgrade --target "$SETUP_TARGET" \
                PyYAML ||
                fail "Could not install setup helpers. Install python3-venv or pip."
            SETUP_PYTHON=python3
            SETUP_PYTHONPATH=$SETUP_TARGET
            return
        fi
    fi
    "$SETUP_VENV/bin/python" -m pip install --quiet --upgrade pip
    "$SETUP_VENV/bin/python" -m pip install --quiet --upgrade PyYAML
    SETUP_PYTHON="$SETUP_VENV/bin/python"
}

ensure_mcp_venv() {
    if [[ ! -x "$MCP_VENV_PY" ]]; then
        log "Creating MCP service venv at $MCP_VENV"
        python3 -m venv "$MCP_VENV" || fail "Could not create $MCP_VENV. Install python3-venv."
    fi
    "$MCP_VENV_PY" -m pip install --quiet --upgrade pip
    log "Installing weather service and autonomy dependencies into $MCP_VENV"
    "$MCP_VENV_PY" -m pip install --quiet --upgrade \
        -r "$ROOT_DIR/autonomy/requirements.txt" \
        -e "$WEATHER_SERVICE_DIR" ||
        fail "Failed to install MCP service dependencies into $MCP_VENV"
}

setup_python() {
    if [[ -n $SETUP_PYTHONPATH ]]; then
        PYTHONPATH="$SETUP_PYTHONPATH${PYTHONPATH:+:$PYTHONPATH}" "$SETUP_PYTHON" "$@"
    else
        "$SETUP_PYTHON" "$@"
    fi
}

install_inference_and_hermes() {
    local harness legacy=${LEGACY_OVMS_CONTAINER:-ovms-qwen3-30b-a3b}
    # Earlier versions of this script ran OVMS in this container, with a restart policy, on the
    # same default port the harness OVMS now binds.
    if docker container inspect "$legacy" >/dev/null 2>&1; then
        log "Removing OVMS container $legacy from an earlier setup; the harness OVMS replaces it"
        docker rm -f "$legacy" >/dev/null
    fi
    # Earlier versions exported models under the harness state directory; the default is now
    # MODEL_ROOT. Say so instead of silently downloading a second copy.
    if [[ $HARNESS_MODELS_DIR == "$LEGACY_MODELS_DIR" && $MODEL_ROOT != "$LEGACY_MODELS_DIR" ]]; then
        log "NOTE: reusing $MODEL_ID exported in $LEGACY_MODELS_DIR (the default location is now MODEL_ROOT=$MODEL_ROOT)."
        log "      To share one copy with 'make up', stop the stack and move it once:"
        log "        mkdir -p '$MODEL_ROOT/${MODEL_ID%/*}' && mv '$LEGACY_MODELS_DIR/$MODEL_ID' '$MODEL_ROOT/$MODEL_ID' && scripts/setup.sh"
    fi
    log "Fetching agent-harness-install"
    harness=$(bash "$ROOT_DIR/scripts/fetch-harness.sh" "$HARNESS_DIR") ||
        fail "Could not fetch agent-harness-install."
    # Installs Docker/Node prerequisites, OVMS and the Inference Router in Docker, and
    # Hermes; it only prints how to configure Hermes, which configure_hermes below does.
    # stdin is closed so nothing can read a TTY.
    export_hermes_pin
    log "Running agent-harness-install for $MODEL_ID (OVMS, Inference Router, Hermes)"
    bash "$harness/install.sh" --harness hermes --model "$MODEL_ID" --non-interactive </dev/null ||
        fail "agent-harness-install failed; see its output above."
    export PATH="$HOME/.local/bin:$PATH"
    require_command hermes "Add $HOME/.local/bin to PATH after installation."
    log "Using $(hermes --version | head -n 1)"
}

# The harness installs the Hermes release named by HERMES_PINNED_COMMIT/HERMES_PINNED_SHA256 (both
# required together; it verifies the installer's SHA-256 and checks out that commit). Pass ours
# from scripts/hermes-pin.sh so the host install and the container image ship the same release.
export_hermes_pin() {
    HERMES_PINNED_COMMIT=$(source "$ROOT_DIR/scripts/hermes-pin.sh" && printf '%s' "$HERMES_INSTALL_COMMIT") ||
        fail "Could not read the Hermes pin from scripts/hermes-pin.sh."
    HERMES_PINNED_SHA256=$(source "$ROOT_DIR/scripts/hermes-pin.sh" && printf '%s' "$HERMES_INSTALL_SHA256") ||
        fail "Could not read the Hermes pin from scripts/hermes-pin.sh."
    export HERMES_PINNED_COMMIT HERMES_PINNED_SHA256
    log "Hermes pinned to installer commit ${HERMES_PINNED_COMMIT:0:12}"
}

wait_for_ovms_model() {
    local deadline=$((SECONDS + 300))
    until curl -fsS --noproxy '*' -o /dev/null "http://127.0.0.1:$OVMS_PORT/v2/models/$SERVED_MODEL/ready"; do
        ((SECONDS < deadline)) || fail "OVMS did not report $SERVED_MODEL ready within 300 seconds; check: docker logs $HARNESS_OVMS_CONTAINER"
        sleep 3
    done
}
# OpenVINO compiles the model on the first inference, not at load. Without this,
# the operator's first question after setup pays a 30-60s one-time compile.
# Sending one throwaway completion here moves that cost into setup instead.
warm_up_model() {
    log "Warming up the model (first-inference compile)"
    ROUTER_URL="$ROUTER_URL" SERVED_MODEL="$SERVED_MODEL" \
        python3 - <<'PY' || log "NOTE: model warm-up call did not complete; first query may be slow."
import json
import os
import urllib.request

url = os.environ["ROUTER_URL"] + "/chat/completions"
payload = json.dumps({
    "model": os.environ["SERVED_MODEL"],
    "messages": [{"role": "user", "content": "ready"}],
    "max_tokens": 1,
}).encode()
req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=180) as response:
    response.read()
PY
}

configure_hermes() {
    local config_dir backup_path
    config_dir=$(dirname "$HERMES_CONFIG")
    mkdir -p "$config_dir"
    if [[ -f "$HERMES_CONFIG" ]]; then
        backup_path="$HERMES_CONFIG.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        cp -p "$HERMES_CONFIG" "$backup_path"
        log "Backed up Hermes config to $backup_path"
    fi

    ROOT_DIR="$ROOT_DIR" HERMES_CONFIG="$HERMES_CONFIG" MODEL_ID="$SERVED_MODEL" \
        LLM_BASE_URL="$ROUTER_URL" QSR_WEATHER_MCP_URL="$WEATHER_MCP_URL" \
        setup_python - <<'PY'
import os
import re
import socket
import ssl
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import yaml

root = Path(os.environ["ROOT_DIR"])
config_path = Path(os.environ["HERMES_CONFIG"])
model_id = os.environ["MODEL_ID"]
ovms_base_url = os.environ["LLM_BASE_URL"]
# Base config + remote/external service registrations (kiosk, order accuracy, SAD, ...).
fragments = [
    root / "agent-config/hermes/config.example.yaml",
    root / "agent-config/hermes/remote-mcp.example.yaml",
]


def merge(current: Any, update: Any) -> Any:
    if isinstance(current, dict) and isinstance(update, dict):
        result = dict(current)
        for key, value in update.items():
            result[key] = merge(result[key], value) if key in result else value
        return result
    if isinstance(current, list) and isinstance(update, list):
        return current + [item for item in update if item not in current]
    return update


def replace_repo_path(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: replace_repo_path(item) for key, item in value.items()}
    if isinstance(value, list):
        return [replace_repo_path(item) for item in value]
    if isinstance(value, str):
        return value.replace("/absolute/path/to/qsr-agentic-svc", str(root))
    return value


# Same ${VAR} / ${VAR:-default} expansion as the container entrypoint.
ENV_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


def expand_env(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: expand_env(item) for key, item in value.items()}
    if isinstance(value, list):
        return [expand_env(item) for item in value]
    if isinstance(value, str):
        return ENV_PATTERN.sub(lambda m: os.environ.get(m.group(1)) or m.group(2) or "", value)
    return value


current = {}
if config_path.exists():
    current = yaml.safe_load(config_path.read_text()) or {}
for fragment in fragments:
    current = merge(current, expand_env(replace_repo_path(yaml.safe_load(fragment.read_text()) or {})))
current["model"]["default"] = model_id
current["model"]["provider"] = "custom"
current["model"]["base_url"] = ovms_base_url
current.setdefault("providers", {}).setdefault("custom", {})
current["providers"]["custom"]["base_url"] = ovms_base_url

servers = current.setdefault("mcp_servers", {})
# Drop remote services whose ${VAR} URL expanded to empty (not configured).
for name in list(servers):
    entry = servers[name]
    if isinstance(entry, dict) and "command" not in entry and not str(entry.get("url", "")).strip():
        del servers[name]


# A remote MCP server (one with a `url`) is only enabled if its endpoint is
# reachable right now. This prevents a stopped/dead service (e.g. SAD not
# running) from costing an 8s connect-timeout on every agent turn. Servers with
# a `command` are spawned on demand, so they are left enabled. Purely
# convention-based: no per-service code, and a service comes back online by
# rerunning setup (or re-enabling it) once its endpoint responds.
def _endpoint_alive(url: str, timeout: float = 2.0) -> bool:
    try:
        parsed = urlparse(url)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


for name, spec in servers.items():
    if isinstance(spec, dict) and spec.get("url"):
        alive = _endpoint_alive(str(spec["url"]))
        spec["enabled"] = alive
        print(f"[qsr-setup] remote MCP '{name}' {'reachable, enabled' if alive else 'unreachable, disabled'} ({spec['url']})")


# Host install: do for the `hermes` process what the container does for it.
# The reachability probe above is a direct socket connect, so Hermes must reach
# the same hosts directly, and an https service with a self-signed cert (e.g.
# digital-signage's nginx) must be trusted or its tools never register.
env_path = config_path.parent / ".env"
CA_BUNDLE = config_path.parent / "remote-mcp-ca-bundle.pem"


def read_env_file() -> dict[str, str]:
    values: dict[str, str] = {}
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and not key.lstrip().startswith("#"):
                values[key.strip()] = value.strip()
    return values


def update_env_file(updates: dict[str, str]) -> None:
    lines = env_path.read_text().splitlines() if env_path.exists() else []
    kept = [line for line in lines if line.partition("=")[0].strip() not in updates]
    kept += [f"{key}={value}" for key, value in updates.items()]
    text = "\n".join(kept) + "\n"
    # Leave the mtime alone when nothing changed: setup.sh restarts the UI only if it moved.
    if not env_path.exists() or env_path.read_text() != text:
        env_path.write_text(text)
    env_path.chmod(0o600)


enabled_remotes = {
    name: urlparse(str(spec["url"]))
    for name, spec in servers.items()
    if isinstance(spec, dict) and spec.get("url") and spec.get("enabled")
}

# Loopback, the caller's own NO_PROXY and QSR_EXTRA_NO_PROXY (merged by the
# shell above), entries already in the file, plus the host of every enabled
# remote service.
current_env = read_env_file()
no_proxy = []
for extra in (os.environ.get("NO_PROXY", "") + "," + os.environ.get("QSR_CALLER_NO_PROXY", "") + "," + os.environ.get("QSR_EXTRA_NO_PROXY", "") + "," + current_env.get("NO_PROXY", "")).split(","):
    if extra and extra not in no_proxy:
        no_proxy.append(extra)
for parsed in enabled_remotes.values():
    if parsed.hostname and parsed.hostname not in no_proxy:
        no_proxy.append(parsed.hostname)
env_updates = {"NO_PROXY": ",".join(no_proxy), "no_proxy": ",".join(no_proxy)}

# Trust-on-first-use for https services, same tradeoff as the container
# entrypoint: only reasonable on an internal, trusted network. The bundle is
# system CAs plus the services' current leaf certs. A self-signed service that
# regenerates its cert on restart needs another setup.sh run.
user_bundle = current_env.get("SSL_CERT_FILE")
if user_bundle and Path(user_bundle) != CA_BUNDLE:
    print(f"[qsr-setup] keeping SSL_CERT_FILE={user_bundle} from {env_path}; not adding service certs")
else:
    fetched = []
    for name, parsed in enabled_remotes.items():
        if parsed.scheme != "https" or not parsed.hostname:
            continue
        try:
            fetched.append(ssl.get_server_certificate((parsed.hostname, parsed.port or 443), timeout=5.0))
            print(f"[qsr-setup] trusting current TLS cert for remote MCP '{name}' ({parsed.hostname}:{parsed.port or 443})")
        except (OSError, ssl.SSLError) as exc:
            print(f"[qsr-setup] could not fetch TLS cert for '{name}' ({exc}); it may fail verification if self-signed")
    if fetched:
        system_ca = [
            Path(p) for p in (ssl.get_default_verify_paths().cafile, "/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt")
            if p and Path(p).is_file()
        ]
        base = system_ca[0].read_text() if system_ca else ""
        bundle_text = base + "\n" + "\n".join(fetched)
        if not CA_BUNDLE.exists() or CA_BUNDLE.read_text() != bundle_text:
            CA_BUNDLE.write_text(bundle_text)
        CA_BUNDLE.chmod(0o600)
        env_updates["SSL_CERT_FILE"] = str(CA_BUNDLE)

update_env_file(env_updates)
print(f"[qsr-setup] wrote {', '.join(env_updates)} to {env_path}")

# Derive the lean CLI toolset from the ENABLED services only (reachable remote
# services), so Hermes' heavy default preset never bloats the prompt,
# new services are picked up automatically, and disabled/dead remotes are not
# referenced.
enabled_servers = [
    name for name, spec in servers.items()
    if not isinstance(spec, dict) or spec.get("enabled", True)
]
current.setdefault("platform_toolsets", {})["cli"] = sorted(enabled_servers)

temporary = config_path.with_suffix(config_path.suffix + ".tmp")
temporary.write_text(yaml.safe_dump(current, sort_keys=False))
temporary.chmod(0o600)
temporary.replace(config_path)
PY

    # The proxy bypass (loopback, remote MCP hosts) and the service CA bundle are
    # persisted to $config_dir/.env by the Python block above.
    hermes config migrate >/dev/null </dev/null
    hermes config check </dev/null
}

# Event decisions reach the gateway through the `qsr-events` profile: same model, no tools, its
# own API key (autonomy/hermes_gateway.py reads it from the profile's .env). The container
# entrypoint creates this profile; without it every event decision fails on a host install.
configure_events_profile() {
    local profile=${QSR_HERMES_EVENTS_PROFILE:-qsr-events}
    local home output
    home="$(dirname "$HERMES_CONFIG")/profiles/$profile"
    if [[ ! -f "$home/config.yaml" ]]; then
        log "Creating Hermes profile $profile for event decisions"
        # A leftover directory without config.yaml (e.g. from a running gateway) makes this refuse.
        output=$(hermes profile create "$profile" --no-skills --no-alias </dev/null 2>&1) ||
            fail "hermes profile create $profile failed: $output (if $home is a leftover, stop 'hermes gateway' and remove it)"
    fi
    HERMES_CONFIG="$HERMES_CONFIG" PROFILE_HOME="$home" setup_python - <<'PY'
import os
import secrets
from pathlib import Path

import yaml

main = yaml.safe_load(Path(os.environ["HERMES_CONFIG"]).read_text()) or {}
home = Path(os.environ["PROFILE_HOME"])
path = home / "config.yaml"
profile = (yaml.safe_load(path.read_text()) or {}) if path.is_file() else {}
for key in ("model", "providers", "custom_providers", "tools"):
    if key in main:
        profile[key] = main[key]
profile["mcp_servers"] = {}
# Toolset without tools: Hermes can only recommend on untrusted event data.
profile["platform_toolsets"] = {"api_server": ["context_engine"]}
profile.setdefault("agent", {}).update({
    "max_turns": 1,
    "reasoning_effort": os.environ.get("QSR_ADVISOR_REASONING", "none"),
})
path.write_text(yaml.safe_dump(profile, sort_keys=False))
path.chmod(0o600)

# The multiplexed gateway authenticates /p/<profile>/ with this key. Kept across reruns because a
# rerun may leave the running gateway (and the key it loaded) in place.
env_path = home / ".env"
lines = env_path.read_text().splitlines() if env_path.is_file() else []
if not any(line.startswith("API_SERVER_KEY=") and line.split("=", 1)[1].strip() for line in lines):
    lines = [line for line in lines if not line.startswith("API_SERVER_KEY=")]
    lines.append(f"API_SERVER_KEY={secrets.token_urlsafe(32)}")
    env_path.write_text("\n".join(lines) + "\n")
env_path.chmod(0o600)
print(f"[qsr-setup] Event decisions use Hermes profile {home.name}")
PY
}

warn_weather_disabled() {
    log "WARNING: $1. Weather reads are disabled; weather/queue events still run without them."
    WEATHER_MCP_URL=""
}

# Must run before configure_hermes: Hermes only enables remote MCP servers that
# are reachable at setup time.
start_weather_service() {
    if [[ "${START_WEATHER,,}" != "true" ]]; then
        log "START_WEATHER=false; not managing the weather MCP service."
        WEATHER_MCP_URL="http://$WEATHER_HOST:$WEATHER_PORT/mcp"
        return 0
    fi
    local health_url="http://$WEATHER_HOST:$WEATHER_PORT/health"
    local pid_file="/tmp/qsr-weather-service.pid"
    local log_file="/tmp/qsr-weather-service.log"
    local weather_bin="$MCP_VENV/bin/weather-simulator"
    local pid attempt

    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$pid" ]] && ps -p "$pid" -o args= 2>/dev/null | grep -q 'weather-simulator serve'; then
        log "Restarting weather MCP service (pid $pid) to apply code and configuration"
        kill "$pid" 2>/dev/null || true
        for attempt in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    elif curl -fsS --max-time 2 "$health_url" >/dev/null 2>&1; then
        log "Using existing weather MCP service at $health_url (not managed by setup)"
        WEATHER_MCP_URL="http://$WEATHER_HOST:$WEATHER_PORT/mcp"
        return 0
    fi
    rm -f "$pid_file"

    if [[ ! -x "$weather_bin" ]]; then
        warn_weather_disabled "$weather_bin is missing; rerun setup to install the MCP venv"
        return 0
    fi

    log "Starting weather MCP service on http://$WEATHER_HOST:$WEATHER_PORT/mcp"
    WEATHER_EVENT_WEBHOOK_URL="${WEATHER_EVENT_WEBHOOK_URL:-http://127.0.0.1:$QSR_UI_PORT/autonomy/events}" \
        WEATHER_STORE_ID="${WEATHER_STORE_ID:-${QSR_RESTAURANT_ID:-qsr-001}}" \
        WEATHER_LOCATION_NAME="${WEATHER_LOCATION_NAME:-Demo QSR Restaurant}" \
        nohup "$weather_bin" serve --transport http \
        --host "$WEATHER_HOST" --port "$WEATHER_PORT" > "$log_file" 2>&1 &
    echo $! > "$pid_file"
    for attempt in {1..20}; do
        if curl -fsS --max-time 2 "$health_url" >/dev/null 2>&1; then
            WEATHER_MCP_URL="http://$WEATHER_HOST:$WEATHER_PORT/mcp"
            log "Weather MCP service started (pid $(cat "$pid_file"), log: $log_file)"
            return 0
        fi
        kill -0 "$(cat "$pid_file")" 2>/dev/null || break
        sleep 1
    done
    tail -n 20 "$log_file" >&2 || true
    rm -f "$pid_file"
    warn_weather_disabled "Weather MCP service did not become ready on $health_url"
}

wait_for_operator_ui() {
    local url="$1"
    local pid_file="$2"
    local attempt pid
    for attempt in {1..20}; do
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
            return 0
        fi
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

build_operator_ui_frontend() {
    local frontend="$ROOT_DIR/operator-ui/frontend"
    local dist="$ROOT_DIR/operator-ui/dist/index.html"
    [[ -f "$dist" ]] && return 0
    [[ -f "$frontend/package.json" ]] || return 0
    # agent-harness-install installs Node.js through nvm, which is only on PATH in a new shell.
    if ! command -v npm >/dev/null 2>&1 && [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
        # shellcheck disable=SC1091
        source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1 || true
    fi
    if ! command -v npm >/dev/null 2>&1; then
        log "operator-ui/dist is missing and npm is not installed; the UI will return 503 until you run: cd operator-ui/frontend && npm ci && npm run build"
        return 0
    fi
    log "Building the operator UI frontend (first run)"
    (cd "$frontend" && npm ci --no-audit --no-fund && npm run build) \
        || fail "Operator UI build failed. Needs Node.js >= 20.19; see docs/operator-ui.md"
}

start_operator_ui() {
    if [[ "${START_UI,,}" != "true" ]]; then
        log "START_UI=false; not starting the operator UI."
        return 0
    fi
    local ui="$ROOT_DIR/operator-ui/app.py"
    [[ -f "$ui" ]] || { log "Operator UI not found at $ui; skipping."; return 0; }
    build_operator_ui_frontend
    local pid_file="/tmp/qsr-operator-ui.pid"
    local log_file="/tmp/qsr-operator-ui.log"
    # Probe over loopback even when binding on 0.0.0.0.
    local probe_host="$QSR_UI_HOST"
    [[ "$probe_host" == "0.0.0.0" ]] && probe_host="127.0.0.1"
    local url="http://$probe_host:$QSR_UI_PORT/health"
    local pid current_args current_weather current_model
    # The agent runtime reads proxy bypass and the service CA bundle from ~/.hermes/.env when it
    # starts, so a UI started before those changed must be replaced. Only the bundle that
    # configure_hermes manages is handed to the UI; the harness install stage never sees it.
    local hermes_dir env_file ca_bundle
    local -a ui_env=()
    hermes_dir=$(dirname "$HERMES_CONFIG")
    env_file="$hermes_dir/.env"
    ca_bundle="$hermes_dir/remote-mcp-ca-bundle.pem"
    if grep -qx "SSL_CERT_FILE=$ca_bundle" "$env_file" 2>/dev/null; then
        ui_env=("SSL_CERT_FILE=$ca_bundle")
    fi
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        current_weather=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^QSR_WEATHER_MCP_URL=//p' || true)
        current_model=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^QSR_MODEL_BASE_URL=//p' || true)
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1 &&
            [[ "$current_weather" == "$WEATHER_MCP_URL" ]] &&
            [[ "$current_model" == "$ROUTER_URL" ]] &&
            [[ ! "$env_file" -nt "$pid_file" && ! "$ca_bundle" -nt "$pid_file" ]]; then
            log "Operator UI already running (pid $pid, http://$QSR_UI_HOST:$QSR_UI_PORT)"
            return 0
        fi
        current_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
        if [[ "$current_args" == *"$ui"* ]]; then
            log "Replacing operator UI process (pid $pid) to apply configuration"
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        else
            fail "Refusing to reuse $pid_file because pid $pid is a different live process: $current_args"
        fi
    elif [[ -f "$pid_file" ]]; then
        rm -f "$pid_file"
    fi
    log "Starting operator UI on http://$QSR_UI_HOST:$QSR_UI_PORT"
    QSR_UI_HOST="$QSR_UI_HOST" QSR_UI_PORT="$QSR_UI_PORT" \
        QSR_WEATHER_MCP_URL="$WEATHER_MCP_URL" QSR_MODEL_BASE_URL="$ROUTER_URL" \
        QSR_ADVISOR_BASE_URL="http://127.0.0.1:$OVMS_PORT/v3" QSR_ADVISOR_MODEL="$SERVED_MODEL" \
        nohup env ${ui_env[@]+"${ui_env[@]}"} "$MCP_VENV_PY" -u "$ui" > "$log_file" 2>&1 &
    echo $! > "$pid_file"
    if ! wait_for_operator_ui "$url" "$pid_file"; then
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pid_file"
        fi
        tail -n 20 "$log_file" >&2 || true
        fail "Operator UI did not become ready on $url"
    fi
    log "Operator UI started (pid $(cat "$pid_file"), http://$QSR_UI_HOST:$QSR_UI_PORT, log: $log_file)"
}

operator_ui_probe_url() {
    local probe_host="$QSR_UI_HOST"
    [[ "$probe_host" == "0.0.0.0" ]] && probe_host="127.0.0.1"
    printf 'http://%s:%s' "$probe_host" "$QSR_UI_PORT"
}

warm_up_operator_ui() {
    if [[ "${START_UI,,}" != "true" || "${WARM_UP_UI,,}" != "true" ]]; then
        return 0
    fi
    local base_url
    base_url=$(operator_ui_probe_url)
    log "Warming up Hermes through the operator UI"
    curl -fsS --max-time 180 \
        -H 'Content-Type: application/json' \
        -d '{"question":"Reply with exactly: ready"}' \
        "$base_url/ask" >/dev/null ||
        log "NOTE: operator UI warm-up did not complete; first query may be slow."
}

validate_stack() {
    export PATH="$HOME/.local/bin:$PATH"
    require_command hermes "Run scripts/setup.sh without --check to install Hermes."
    local name
    for name in "$HARNESS_OVMS_CONTAINER" "$HARNESS_IR_CONTAINER"; do
        docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true ||
            fail "Container $name is not running; rerun scripts/setup.sh."
    done
    verify_ovms_on_gpu
    wait_for_router || fail "The Inference Router did not report $SERVED_MODEL as available."

    [[ -x "$MCP_VENV_PY" ]] || ensure_mcp_venv
    log "Running model-independent service tests"
    PYTHONDONTWRITEBYTECODE=1 "$MCP_VENV_PY" -m unittest discover \
        -s "$WEATHER_SERVICE_DIR/tests"
}

# The harness falls back to the CPU when Docker has no GPU access, which this stack cannot use:
# the container must have a render node and OVMS must report the GPU as an available device.
verify_ovms_on_gpu() {
    local devices available
    devices=$(docker inspect -f '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}' "$HARNESS_OVMS_CONTAINER" 2>/dev/null || true)
    available=$(docker logs "$HARNESS_OVMS_CONTAINER" 2>&1 | grep -o 'Available devices for Open VINO: .*' | tail -n 1 || true)
    if [[ $devices == */dev/dri/* && $available == *GPU* ]]; then
        log "OVMS runs on the Intel GPU (${devices% })"
        return 0
    fi
    local reason="container devices: '${devices:-none}'; OVMS reports: '${available:-no device list in logs}'"
    if [[ $ALLOW_CPU_INFERENCE == 1 ]]; then
        log "WARNING: OVMS is not using the GPU ($reason); continuing because ALLOW_CPU_INFERENCE=1."
        return 0
    fi
    fail "OVMS is not running on the Intel GPU ($reason). Check the GPU driver and that this user can access /dev/dri, or set ALLOW_CPU_INFERENCE=1 to accept CPU inference."
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        usage
        exit 0
    fi
    if [[ ${1:-} == --check ]]; then
        CHECK_ONLY=true
        shift
    fi
    [[ $# -eq 0 ]] || fail "Unknown argument: $1"

    check_prerequisites
    if [[ $CHECK_ONLY == false ]]; then
        ensure_build_packages
        ensure_helper_venv
        install_inference_and_hermes
        wait_for_ovms_model
        wait_for_router
        warm_up_model
        ensure_mcp_venv
        start_weather_service
        configure_hermes
        configure_events_profile
    fi
    validate_stack
    if [[ $CHECK_ONLY == false ]]; then
        start_operator_ui
        warm_up_operator_ui
    fi
    log "Setup is ready. Start the agent from this repository with: hermes"
    log "Operator UI: http://$QSR_UI_HOST:$QSR_UI_PORT  (START_UI=false to skip; WARM_UP_UI=false to skip warm-up; log: /tmp/qsr-operator-ui.log)"
}

main "$@"