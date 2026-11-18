#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

H2_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bosh-h2-sentinel.XXXXXXXX")"

h2_cleanup() {
    test_cleanup_active_home
    if [[ -n "${H2_ROOT:-}" && -d "$H2_ROOT" ]]; then
        rm -rf -- "$H2_ROOT"
    fi
}

trap h2_cleanup EXIT

for name in config state backup; do
    mkdir -p "$H2_ROOT/$name"
    printf 'protected-%s\n' "$name" > "$H2_ROOT/$name/marker"
    chmod 600 "$H2_ROOT/$name/marker"
done

export BOSH_HOME="$H2_ROOT/config"
export BOSH_STATE="$H2_ROOT/state"
export BOSH_BACKUP="$H2_ROOT/backup"

test_case "H2: inherited overrides are isolated" <<'CASE'
source "$BOSH_TEST_PROJECT/scripts/lib/common.sh"

[[ "$BOSH_HOME" == "$HOME/.config/bosh-terminal" ]]
[[ "$BOSH_STATE" == "$HOME/.local/state/bosh-terminal" ]]
[[ "$BOSH_BACKUP" == "$HOME/.config/bosh-backups/bosh-terminal" ]]

mkdir -p "$BOSH_HOME" "$BOSH_STATE" "$BOSH_BACKUP"
printf 'test\n' > "$BOSH_HOME/h2-probe"

[[ -f "$BOSH_HOME/h2-probe" ]]
CASE

unset BOSH_HOME BOSH_STATE BOSH_BACKUP

test_case "H2: default paths remain isolated" <<'CASE'
source "$BOSH_TEST_PROJECT/scripts/lib/common.sh"

[[ "$BOSH_HOME" == "$HOME/.config/bosh-terminal" ]]
[[ "$BOSH_STATE" == "$HOME/.local/state/bosh-terminal" ]]
[[ "$BOSH_BACKUP" == "$HOME/.config/bosh-backups/bosh-terminal" ]]
CASE

for name in config state backup; do
    [[ "$(cat "$H2_ROOT/$name/marker")" == "protected-$name" ]]
    [[ "$(stat -c '%a' "$H2_ROOT/$name/marker")" == "600" ]]
    [[ "$(find "$H2_ROOT/$name" -type f | wc -l)" -eq 1 ]]
done

echo "[PASS] External sentinel files and permissions preserved"

test_summary
