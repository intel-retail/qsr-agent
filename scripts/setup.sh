#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Model comes from .env.example (single source); an exported MODEL_ID overrides it.
MODEL_ID=${MODEL_ID:-$(sed -n 's/^MODEL_ID=//p' "$ROOT_DIR/.env.example")}
[[ -n "$MODEL_ID" ]] || { echo "[qsr-setup] ERROR: set MODEL_ID in .env.example" >&2; exit 1; }
# OVMS, the Inference Router and Hermes are installed by agent-harness-install
# (open-edge-platform/edge-ai-libraries), fetched at the commit pinned in
# scripts/fetch-harness.sh. HARNESS_* variables are read by that installer.
HARNESS_DIR=${HARNESS_DIR:-"$ROOT_DIR/.harness"}
# Default off 8000 to avoid clashing with SAD's alert-service (make up binds :8000).
OVMS_PORT=${OVMS_PORT:-4444}
HARNESS_OVMS_REST_PORT=$OVMS_PORT
HARNESS_IR_PORT=${HARNESS_IR_PORT:-8010}
if [[ $OVMS_PORT == "$HARNESS_IR_PORT" ]]; then
    echo "[qsr-setup] ERROR: OVMS_PORT and HARNESS_IR_PORT are both $OVMS_PORT; set different ports." >&2
    exit 1
fi
HARNESS_MODELS_DIR=${HARNESS_MODELS_DIR:-"$HOME/.agent-harness-install/models"}
HARNESS_OVMS_CONTAINER=${HARNESS_OVMS_CONTAINER:-agent-harness-install-ovms}
# The harness runs OVMS with --config_path, which rejects model flags such as --tool_parser and
# --task (the container crash-loops), so leave this empty; enable_tool_calls sets the parser in graph.pbtxt.
HARNESS_OVMS_EXTRA_ARGS=${HARNESS_OVMS_EXTRA_ARGS:-}
export HARNESS_OVMS_REST_PORT HARNESS_IR_PORT HARNESS_OVMS_EXTRA_ARGS HARNESS_MODELS_DIR HARNESS_OVMS_CONTAINER
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
export NO_PROXY="localhost,127.0.0.1,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

usage() {
    cat <<'EOF'
Usage: scripts/setup.sh [--check]

Without arguments, install and configure the complete local QSR agent stack.
Use --check to validate an existing installation without changing it.

Optional environment variables:
    MODEL_ID            Hugging Face model ID
    HARNESS_INSTALL_REF agent-harness-install commit SHA (default: pinned in scripts/fetch-harness.sh)
    HERMES_INSTALL_COMMIT / HERMES_INSTALL_SHA256  Hermes installer revision and its SHA-256, set together
                        (default: pinned in scripts/hermes-pin.sh)
    HARNESS_DIR         Where the installer is fetched (default: <repo>/.harness)
    HARNESS_IR_PORT     Loopback port for the Inference Router (default: 8010)
    HARNESS_OVMS_EXTRA_ARGS  Extra OVMS server flags (default: none; model flags are rejected in config mode)
    HARNESS_MODELS_DIR  Where the harness stores OVMS models (default: ~/.agent-harness-install/models)
    OVMS_PORT           Loopback port for OVMS (default: 4444)
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
    docker info >/dev/null 2>&1 || fail "Docker is not running or this user cannot access it."
    render_node >/dev/null
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
    log "Fetching agent-harness-install"
    harness=$(bash "$ROOT_DIR/scripts/fetch-harness.sh" "$HARNESS_DIR") ||
        fail "Could not fetch agent-harness-install."
    # Installs Docker/Node prerequisites, OVMS and the Inference Router in Docker, and
    # Hermes; it only prints how to configure Hermes, which configure_hermes below does.
    # stdin is closed so nothing can read a TTY.
    pin_hermes_in_harness "$harness"
    log "Running agent-harness-install for $MODEL_ID (OVMS, Inference Router, Hermes)"
    bash "$harness/install.sh" --harness hermes --model "$MODEL_ID" --non-interactive </dev/null ||
        fail "agent-harness-install failed; see its output above."
    export PATH="$HOME/.local/bin:$PATH"
    require_command hermes "Add $HOME/.local/bin to PATH after installation."
    log "Using $(hermes --version | head -n 1)"
}

# The harness pins Hermes v0.22.2, which predates the gateway API server this repo needs, and its
# pin variables are plain assignments that the environment cannot override. A custom installer URL
# would skip the harness's own `--commit`, leaving Hermes unpinned, so set the harness's two pin
# values to ours (scripts/hermes-pin.sh). It then installs exactly that release, checksum-verified.
pin_hermes_in_harness() {
    local agents="$1/scripts/lib/agents.sh" commit sha
    commit=$(source "$ROOT_DIR/scripts/hermes-pin.sh" && printf '%s' "$HERMES_INSTALL_COMMIT")
    sha=$(source "$ROOT_DIR/scripts/hermes-pin.sh" && printf '%s' "$HERMES_INSTALL_SHA256")
    [[ $commit =~ ^[0-9a-f]{40}$ && $sha =~ ^[0-9a-f]{64}$ ]] ||
        fail "HERMES_INSTALL_COMMIT must be a 40-character SHA and HERMES_INSTALL_SHA256 a 64-character SHA-256."
    grep -q '^HERMES_PINNED_COMMIT=' "$agents" && grep -q '^HERMES_PINNED_SHA256=' "$agents" ||
        fail "Hermes pin variables not found in $agents; update scripts/fetch-harness.sh and pin_hermes_in_harness together."
    sed -i -e "s|^HERMES_PINNED_COMMIT=.*|HERMES_PINNED_COMMIT=\"$commit\"|" \
        -e "s|^HERMES_PINNED_SHA256=.*|HERMES_PINNED_SHA256=\"$sha\"|" "$agents"
    grep -q "^HERMES_PINNED_COMMIT=\"$commit\"\$" "$agents" || fail "Could not pin Hermes in $agents."
    log "Hermes pinned to installer commit ${commit:0:12}"
}

# Hermes needs OpenAI-style tool calls, which OVMS only parses when graph.pbtxt names a tool
# parser. The harness-generated graph has none, so add it and restart OVMS to reload it.
enable_tool_calls() {
    local graph="$HARNESS_MODELS_DIR/$MODEL_ID/graph.pbtxt"
    [[ -f $graph ]] || fail "OVMS graph not found at $graph."
    if ! grep -q 'tool_parser' "$graph"; then
        log "Enabling tool calls (tool_parser hermes3) in $graph"
        sed -i '/models_path:/a\            tool_parser: "hermes3",' "$graph"
        grep -q 'tool_parser' "$graph" || fail "Could not add tool_parser to $graph."
        docker restart "$HARNESS_OVMS_CONTAINER" >/dev/null || fail "Could not restart $HARNESS_OVMS_CONTAINER."
    fi
    wait_for_ovms_model
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
# The fragment reinstalls the action-gate hooks; a stale entry from a moved checkout would fail closed forever.
hooks = current.get("hooks")
if isinstance(hooks, dict):
    for event, entries in list(hooks.items()):
        if isinstance(entries, list):
            kept = [e for e in entries if not (isinstance(e, dict) and "action_gate.py" in str(e.get("command", "")))]
            if kept:
                hooks[event] = kept
            else:
                del hooks[event]
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

    # Persist the loopback proxy bypass so the runtime `hermes` process reaches
    # OVMS on 127.0.0.1 even when a corporate proxy is set in the shell.
    local env_file
    env_file="$config_dir/.env"
    touch "$env_file"
    chmod 600 "$env_file"
    if ! grep -q '^NO_PROXY=' "$env_file" 2>/dev/null; then
        {
            echo "NO_PROXY=localhost,127.0.0.1,::1"
            echo "no_proxy=localhost,127.0.0.1,::1"
        } >> "$env_file"
    fi

    hermes config migrate >/dev/null </dev/null
    hermes config check </dev/null
}

# Remote MCP services behind a self-signed TLS proxy (e.g. digital-signage's nginx) fail Hermes's
# certificate check, and none of their tools register. Same trust-on-first-use approach as the
# container entrypoint: fetch each enabled https server's current cert and trust it through a CA
# bundle (system CAs + those certs) that SSL_CERT_FILE points at. Only for internal, trusted networks.
# Such certs are often regenerated when the service restarts; rerun setup to refresh.
trust_remote_mcp_certs() {
    local bundle env_file="$(dirname "$HERMES_CONFIG")/.env"
    bundle="$(dirname "$HERMES_CONFIG")/remote-mcp-ca-bundle.pem"
    local written
    written=$(HERMES_CONFIG="$HERMES_CONFIG" BUNDLE="$bundle" setup_python - <<'PY'
import os
import ssl
import sys
from pathlib import Path
from urllib.parse import urlparse

import yaml

config = yaml.safe_load(Path(os.environ["HERMES_CONFIG"]).read_text()) or {}
certs = []
for name, spec in (config.get("mcp_servers") or {}).items():
    url = str(spec.get("url", "")) if isinstance(spec, dict) else ""
    if not url.startswith("https://") or not spec.get("enabled", True):
        continue
    parsed = urlparse(url)
    port = parsed.port or 443
    try:
        certs.append(ssl.get_server_certificate((parsed.hostname, port), timeout=5.0))
        print(f"[qsr-setup] trusting current TLS cert of MCP server '{name}' ({parsed.hostname}:{port})", file=sys.stderr)
    except (OSError, ssl.SSLError) as exc:
        print(f"[qsr-setup] could not fetch TLS cert of '{name}' ({exc})", file=sys.stderr)
if not certs:
    sys.exit(0)

verify = ssl.get_default_verify_paths()
system = next((Path(p) for p in (verify.cafile, verify.openssl_cafile, "/etc/ssl/certs/ca-certificates.crt") if p and Path(p).is_file()), None)
if system is None:
    print("[qsr-setup] no system CA bundle found; not overriding SSL_CERT_FILE", file=sys.stderr)
    sys.exit(0)
bundle = Path(os.environ["BUNDLE"])
bundle.write_text(system.read_text() + "\n" + "\n".join(certs))
bundle.chmod(0o600)
print(bundle)
PY
    ) || { log "WARNING: could not prepare trusted certificates for remote MCP servers."; return 0; }
    [[ -n $written ]] || return 0
    export SSL_CERT_FILE="$written"
    # Persist for the runtime `hermes` CLI too (the operator UI gets it from this environment).
    touch "$env_file"
    chmod 600 "$env_file"
    sed -i '/^SSL_CERT_FILE=/d' "$env_file"
    echo "SSL_CERT_FILE=$written" >> "$env_file"
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
    local pid current_args
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        # Always replace it: a rerun restarts the weather service and rewrites the Hermes config,
        # so a kept UI (and the Hermes gateway it supervises) would hold an expired MCP session.
        current_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
        if [[ "$current_args" == *"$ui"* ]]; then
            log "Replacing operator UI process (pid $pid) to pick up the restarted services and config"
            kill "$pid" 2>/dev/null || true
            for attempt in {1..20}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        else
            fail "Refusing to reuse $pid_file because pid $pid is a different live process: $current_args"
        fi
    elif [[ -f "$pid_file" ]]; then
        rm -f "$pid_file"
    fi
    log "Starting operator UI on http://$QSR_UI_HOST:$QSR_UI_PORT"
    QSR_UI_HOST="$QSR_UI_HOST" QSR_UI_PORT="$QSR_UI_PORT" \
        QSR_WEATHER_MCP_URL="$WEATHER_MCP_URL" \
        QSR_ADVISOR_BASE_URL="http://127.0.0.1:$OVMS_PORT/v3" QSR_ADVISOR_MODEL="$SERVED_MODEL" \
        nohup "$MCP_VENV_PY" -u "$ui" > "$log_file" 2>&1 &
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
    require_command hermes "Run scripts/setup.sh without --check to install Hermes."
    local name
    for name in "$HARNESS_OVMS_CONTAINER" agent-harness-install-ir; do
        docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true ||
            fail "Container $name is not running; rerun scripts/setup.sh."
    done
    wait_for_router || fail "The Inference Router did not report $SERVED_MODEL as available."

    [[ -x "$MCP_VENV_PY" ]] || ensure_mcp_venv
    log "Running model-independent service tests"
    PYTHONDONTWRITEBYTECODE=1 "$MCP_VENV_PY" -m unittest discover \
        -s "$WEATHER_SERVICE_DIR/tests"
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
        enable_tool_calls
        wait_for_router
        warm_up_model
        ensure_mcp_venv
        start_weather_service
        configure_hermes
        trust_remote_mcp_certs
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