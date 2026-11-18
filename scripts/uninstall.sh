#!/usr/bin/env bash
# Uninstall the QSR stack installed by scripts/setup.sh: Hermes, the OVMS and
# Inference Router containers, the agent-harness-install checkout and state, and
# the operator UI. Runs fully unattended (no prompts). Safe to run repeatedly.
#
# Usage:
#   scripts/uninstall.sh                 # remove Hermes + ~/.hermes + OVMS/router + harness + UI
#   KEEP_DATA=1 scripts/uninstall.sh     # keep ~/.hermes (config/history)
#   KEEP_UV=1  scripts/uninstall.sh      # keep uv/uvx if bundled under ~/.hermes/bin
#   REMOVE_OVMS=0 scripts/uninstall.sh   # leave the OVMS/router containers running
#   REMOVE_HARNESS=0 scripts/uninstall.sh  # keep <repo>/.harness and ~/.agent-harness-install
#   REMOVE_MODELS=1 scripts/uninstall.sh   # also delete the downloaded models (MODEL_ROOT, several GB)
#   REMOVE_IMAGES=1 scripts/uninstall.sh   # also delete the OVMS and Inference Router images
#
# Kept on purpose: Node.js installed through nvm (~/.nvm) and the repository's .venv/
# directories; delete them yourself if nothing else uses them.
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERMES_HOME=${HERMES_HOME:-"$HOME/.hermes"}
BIN_DIR=${BIN_DIR:-"$HOME/.local/bin"}
# Same variables setup.sh passes to agent-harness-install, so a custom name set for setup is removed too.
OVMS_CONTAINER=${OVMS_CONTAINER:-${HARNESS_OVMS_CONTAINER:-agent-harness-install-ovms}}
ROUTER_CONTAINER=${ROUTER_CONTAINER:-${HARNESS_IR_CONTAINER:-agent-harness-install-ir}}
LEGACY_OVMS_CONTAINER=${LEGACY_OVMS_CONTAINER:-ovms-qwen3-30b-a3b}
HARNESS_DIR=${HARNESS_DIR:-"$ROOT_DIR/.harness"}
HARNESS_STATE_DIR=${HARNESS_STATE_DIR:-"$HOME/.agent-harness-install"}
# Models: setup.sh defaults HARNESS_MODELS_DIR to MODEL_ROOT from .env.example (./models).
MODEL_ROOT=${MODEL_ROOT:-$(sed -n 's/^MODEL_ROOT=//p' "$ROOT_DIR/.env.example" 2>/dev/null)}
MODEL_ROOT=${MODEL_ROOT:-./models}
[[ $MODEL_ROOT == /* ]] || MODEL_ROOT="$ROOT_DIR/${MODEL_ROOT#./}"
MODELS_DIR=${HARNESS_MODELS_DIR:-$MODEL_ROOT}
UI_PID_FILE=${UI_PID_FILE:-/tmp/qsr-operator-ui.pid}
KEEP_DATA=${KEEP_DATA:-0}
KEEP_UV=${KEEP_UV:-0}
# OVMS and the UI are removed by default; set REMOVE_OVMS=0 to keep OVMS and the router.
REMOVE_OVMS=${REMOVE_OVMS:-1}
REMOVE_HARNESS=${REMOVE_HARNESS:-1}
REMOVE_MODELS=${REMOVE_MODELS:-0}
REMOVE_IMAGES=${REMOVE_IMAGES:-0}

log() { printf '[hermes-uninstall] %s\n' "$*"; }

stop_processes() {
    log "Stopping Hermes processes"
    pkill -TERM -f 'hermes-agent/hermes' 2>/dev/null || true
    pkill -TERM -f "$HERMES_HOME/" 2>/dev/null || true
    sleep 2
    pkill -KILL -f 'hermes-agent/hermes' 2>/dev/null || true
    pkill -KILL -f "$HERMES_HOME/" 2>/dev/null || true
}

stop_operator_ui() {
    log "Stopping operator UI"
    if [[ -f "$UI_PID_FILE" ]]; then
        local pid; pid=$(cat "$UI_PID_FILE" 2>/dev/null || true)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$UI_PID_FILE"
    fi
    pkill -f 'operator-ui/app.py' 2>/dev/null || true
}

stop_weather_service() {
    log "Stopping weather MCP service"
    local pid_file=/tmp/qsr-weather-service.pid
    if [[ -f "$pid_file" ]]; then
        local pid; pid=$(cat "$pid_file" 2>/dev/null || true)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi
}

preserve_uv() {
    # Move uv/uvx out of ~/.hermes/bin into ~/.local/bin so they survive removal.
    [[ $KEEP_UV == 1 ]] || return 0
    local tool
    for tool in uv uvx; do
        if [[ -e "$HERMES_HOME/bin/$tool" && ! -e "$BIN_DIR/$tool" ]]; then
            log "Preserving $tool -> $BIN_DIR/$tool"
            cp -a "$HERMES_HOME/bin/$tool" "$BIN_DIR/$tool" 2>/dev/null || true
        fi
    done
}

remove_launchers() {
    log "Removing Hermes launchers from $BIN_DIR"
    rm -f "$BIN_DIR/hermes" "$BIN_DIR/hermes-acp" "$BIN_DIR/hermes-agent"
    # Only remove node/npm/npx if they are symlinks pointing into ~/.hermes.
    local link target
    for link in node npm npx; do
        target=$(readlink -f "$BIN_DIR/$link" 2>/dev/null || true)
        if [[ -L "$BIN_DIR/$link" && $target == "$HERMES_HOME"/* ]]; then
            log "Removing bundled $link symlink"
            rm -f "$BIN_DIR/$link"
        fi
    done
}

remove_data() {
    if [[ $KEEP_DATA == 1 ]]; then
        log "KEEP_DATA=1 set; leaving $HERMES_HOME in place"
        return 0
    fi
    if [[ -d "$HERMES_HOME" ]]; then
        log "Deleting $HERMES_HOME"
        rm -rf "$HERMES_HOME"
    fi
}

remove_ovms() {
    [[ $REMOVE_OVMS == 1 ]] || return 0
    command -v docker >/dev/null 2>&1 || { log "docker not found; skipping OVMS removal"; return 0; }
    local name image
    # Record the images before the containers go, so REMOVE_IMAGES deletes exactly what ran.
    local -a images=()
    for name in "$ROUTER_CONTAINER" "$OVMS_CONTAINER" "$LEGACY_OVMS_CONTAINER"; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            image=$(docker container inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)
            [[ -n $image ]] && images+=("$image")
            log "Removing container $name"
            docker rm -f "$name" >/dev/null 2>&1 || true
        fi
    done
    # The harness's user-defined network joining OVMS and the router.
    docker network rm "${HARNESS_BACKEND_NETWORK:-agent-harness-install-backend}" >/dev/null 2>&1 || true
    if [[ $REMOVE_IMAGES == 1 ]]; then
        for image in "${images[@]}"; do
            log "Removing image $image"
            docker rmi "$image" >/dev/null 2>&1 || log "NOTE: image $image is still in use elsewhere; left in place"
        done
    elif [[ ${#images[@]} -gt 0 ]]; then
        log "Images kept (REMOVE_IMAGES=1 deletes them): ${images[*]}"
    fi
}

remove_harness() {
    [[ $REMOVE_HARNESS == 1 ]] || return 0
    if [[ -d $HARNESS_DIR ]]; then
        log "Deleting agent-harness-install checkout $HARNESS_DIR"
        rm -rf "$HARNESS_DIR"
    fi
    if [[ -d $HARNESS_STATE_DIR ]]; then
        # Older setups kept the models under the state dir; those follow REMOVE_MODELS.
        log "Deleting agent-harness-install state $HARNESS_STATE_DIR (models follow REMOVE_MODELS)"
        find "$HARNESS_STATE_DIR" -mindepth 1 -maxdepth 1 ! -name models -exec rm -rf {} +
        [[ -d "$HARNESS_STATE_DIR/models" ]] || rmdir "$HARNESS_STATE_DIR" 2>/dev/null || true
    fi
}

remove_models() {
    local dir
    if [[ $REMOVE_MODELS != 1 ]]; then
        for dir in "$MODELS_DIR" "$HARNESS_STATE_DIR/models"; do
            [[ -d $dir ]] && log "Models kept in $dir (REMOVE_MODELS=1 deletes them)"
        done
        return 0
    fi
    for dir in "$MODELS_DIR" "$HARNESS_STATE_DIR/models"; do
        if [[ -d $dir ]]; then
            log "Deleting models in $dir"
            rm -rf "$dir"
        fi
    done
    rmdir "$HARNESS_STATE_DIR" 2>/dev/null || true
}

verify() {
    log "Verifying removal"
    command -v hermes >/dev/null 2>&1 && log "WARNING: 'hermes' still on PATH at $(command -v hermes)" || log "hermes: not found (good)"
    [[ -d "$HERMES_HOME" ]] && [[ $KEEP_DATA != 1 ]] && log "WARNING: $HERMES_HOME still exists" || true
    if [[ $REMOVE_OVMS == 1 ]] && command -v docker >/dev/null 2>&1; then
        local name
        for name in "$ROUTER_CONTAINER" "$OVMS_CONTAINER"; do
            docker container inspect "$name" >/dev/null 2>&1 \
                && log "WARNING: container $name still exists" \
                || log "$name: removed (good)"
        done
    fi
}

main() {
    stop_processes
    stop_operator_ui
    stop_weather_service
    preserve_uv
    remove_launchers
    remove_data
    remove_ovms
    remove_harness
    remove_models
    verify
    log "Done. Kept: Node.js under ~/.nvm (if the harness installed it) and the repository's .venv/ directories."
}

main "$@"
