#!/usr/bin/env bash
# Merge settings into an env file. Reads stdin lines: KEY=VALUE sets KEY; +KEY=VALUE adds VALUE to a
# comma-separated list. Used by `make deployer` and `make connect-services` on .env.example.
set -euo pipefail

file=${1:?usage: set-env.sh FILE < lines}
[[ -f "$file" ]] || : > "$file"

while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ -n "$line" ]] || continue
    mode=set
    if [[ "$line" == +* ]]; then mode=add; line=${line#+}; fi
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "set-env: ignoring invalid line" >&2; continue; }
    tmp=$(mktemp)
    ENV_KEY="${line%%=*}" ENV_VALUE="${line#*=}" ENV_MODE="$mode" awk '
        BEGIN { key = ENVIRON["ENV_KEY"]; value = ENVIRON["ENV_VALUE"]; mode = ENVIRON["ENV_MODE"]; seen = 0 }
        index($0, key "=") == 1 {
            if (!seen) {
                current = substr($0, length(key) + 2)
                out = value
                if (mode == "add" && current != "") {
                    n = split(current, items, ","); has = 0
                    for (i = 1; i <= n; i++) if (items[i] == value) has = 1
                    out = has ? current : current "," value
                }
                print key "=" out
                seen = 1
            }
            next
        }
        { print }
        END { if (!seen) print key "=" value }' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
done
