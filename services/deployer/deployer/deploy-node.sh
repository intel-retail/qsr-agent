#!/usr/bin/env bash
# Clone (or update) a service repository on this node, apply its environment, then build and start it.
#
# Not run directly: the deployer streams this file over SSH stdin after a header that sets
#   DEPLOY_NAME DEPLOY_REPO DEPLOY_REF DEPLOY_BASE DEPLOY_DIR DEPLOY_ENV_FILE DEPLOY_BUILD DEPLOY_PRE DEPLOY_START
#   DEPLOY_ENV        array of KEY=VALUE written into the service's env file
#   DEPLOY_SHELL_ENV  array of KEY=VALUE exported for git, the build and the start commands
# Secrets travel on stdin, never on the command line.

main() {
    set -euo pipefail
    log() { printf '[deploy %s] %s\n' "$DEPLOY_NAME" "$*"; }
    fail() { log "ERROR: $*"; exit "${2:-1}"; }

    # Lets the deployer end on our exit status (a detached start command can hold the channel open) and kill us on timeout.
    if [[ -n "${DEPLOY_TOKEN:-}" ]]; then
        printf '__deploy:%s:pgid:%s\n' "$DEPLOY_TOKEN" "$$"
        trap 'printf "__deploy:%s:exit:%s\n" "$DEPLOY_TOKEN" "$?"' EXIT
    fi

    command -v git >/dev/null 2>&1 || fail "git is not installed on this node" 10
    command -v awk >/dev/null 2>&1 || fail "awk is not installed on this node" 10

    local base="$DEPLOY_BASE"
    case "$base" in
        "~") base="$HOME" ;;
        "~/"*) base="$HOME/${base#\~/}" ;;
        /*) ;;
        *) base="$HOME/$base" ;;
    esac
    local checkout="$base/$DEPLOY_NAME"
    mkdir -p "$base"

    # Before git too: a non-login SSH shell has no proxy settings of its own.
    local entry
    if ((${#DEPLOY_SHELL_ENV[@]})); then
        for entry in "${DEPLOY_SHELL_ENV[@]}"; do
            export "${entry%%=*}=${entry#*=}"
        done
    fi
    export GIT_TERMINAL_PROMPT=0

    if [[ -d "$checkout/.git" ]]; then
        # Fix state a previous start left behind (e.g. root-owned files) so the update below can replace it.
        if [[ -n "${DEPLOY_PRE:-}" ]]; then
            log "Preparing: $DEPLOY_PRE"
            (cd "$checkout" && bash -c "$DEPLOY_PRE")
        fi
        log "Updating $checkout"
        git -C "$checkout" remote set-url origin "$DEPLOY_REPO"
        git -C "$checkout" fetch --tags --prune --force origin
    else
        log "Cloning $DEPLOY_REPO into $checkout"
        git clone "$DEPLOY_REPO" "$checkout"
    fi

    # Branch names resolve to the remote tip; tags and commits resolve as given.
    # Local edits to tracked files are discarded: the inventory is the source of truth.
    local target="$DEPLOY_REF"
    if git -C "$checkout" rev-parse --verify --quiet "refs/remotes/origin/$DEPLOY_REF" >/dev/null; then
        target="origin/$DEPLOY_REF"
    fi
    log "Checking out $DEPLOY_REF"
    git -C "$checkout" checkout --force --detach "$target" --
    git -C "$checkout" submodule update --init --recursive --force

    local workdir="$checkout"
    [[ -z "$DEPLOY_DIR" ]] || workdir="$checkout/$DEPLOY_DIR"
    [[ -d "$workdir" ]] || fail "directory '$DEPLOY_DIR' does not exist in the repository" 11
    cd "$workdir"

    if ((${#DEPLOY_ENV[@]})); then
        local env_file="$DEPLOY_ENV_FILE"
        if [[ ! -f "$env_file" ]]; then
            if [[ -f "$env_file.example" ]]; then cp "$env_file.example" "$env_file"; else : > "$env_file"; fi
        fi
        chmod 600 "$env_file"
        log "Writing ${#DEPLOY_ENV[@]} variable(s) to $env_file"
        local tmp
        for entry in "${DEPLOY_ENV[@]}"; do
            tmp=$(mktemp)
            ENV_KEY="${entry%%=*}" ENV_VALUE="${entry#*=}" awk '
                BEGIN { key = ENVIRON["ENV_KEY"]; value = ENVIRON["ENV_VALUE"]; seen = 0 }
                index($0, key "=") == 1 { print key "=" value; seen = 1; next }
                { print }
                END { if (!seen) print key "=" value }' "$env_file" > "$tmp"
            cat "$tmp" > "$env_file"
            rm -f "$tmp"
        done
    fi

    if [[ -n "$DEPLOY_BUILD" ]]; then
        log "Building: $DEPLOY_BUILD"
        bash -c "$DEPLOY_BUILD"
    fi
    log "Starting: $DEPLOY_START"
    bash -c "$DEPLOY_START"
    log "Started $DEPLOY_NAME"
}

# stdin is the script itself, so nothing launched from here may read it.
main </dev/null
