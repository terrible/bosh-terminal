#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "H1: exit before manifest preserves original backup on retry" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source_file="$HOME/replacement"
destination="$BOSH_HOME/starship.toml"
manifest="$BOSH_STATE/starship_manifest"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL-H1\n' > "$destination"
chmod 644 "$destination"
printf 'REPLACEMENT-H1\n' > "$source_file"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
[[ "$(cat "$destination")" == "REPLACEMENT-H1" && ! -e "$manifest" ]]
[[ -d "$BOSH_STATE/.starship.managed-pending" ]]

install_managed_file "$source_file" "$destination" starship
read_manifest starship
[[ "${BOSH_MANIFEST[preexisting]}" == 1 ]]
[[ "${BOSH_MANIFEST[backup_path_b64]}" != '-' ]]
path="$(printf '%s' "${BOSH_MANIFEST[backup_path_b64]}" | base64 --decode)"
[[ "$(cat "$path")" == "ORIGINAL-H1" ]]
[[ "$(stat -c '%a' "$path")" == 600 ]]
[[ ! -e "$BOSH_STATE/.starship.managed-pending" ]]

source "$BOSH_TEST_PROJECT/uninstall.sh"
bosh_uninstall_process_managed_file starship
[[ "$(cat "$destination")" == "ORIGINAL-H1" ]]
[[ "$(stat -c '%a' "$destination")" == 644 ]]
CASE

test_case "H1: SIGKILL during manifest write is recovered by uninstaller" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source_file="$HOME/replacement"
destination="$BOSH_HOME/starship.toml"
manifest="$BOSH_STATE/starship_manifest"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$destination"
printf 'NEW\n' > "$source_file"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { kill -KILL "$BASHPID"; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 137 ]]
[[ "$(cat "$destination")" == "NEW" && ! -e "$manifest" ]]
source "$BOSH_TEST_PROJECT/uninstall.sh"
bosh_uninstall_process_managed_file starship
[[ "$(cat "$destination")" == "ORIGINAL" ]]
[[ ! -e "$BOSH_STATE/.starship.managed-pending" ]]
CASE

test_case "H1: new file interrupted without predecessor is removable" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'NEW\n' > "$HOME/replacement"
destination="$BOSH_HOME/starship.toml"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
[[ -f "$destination" && ! -e "$BOSH_STATE/starship_manifest" ]]
source "$BOSH_TEST_PROJECT/uninstall.sh"
bosh_uninstall_process_managed_file starship
[[ ! -e "$destination" && ! -e "$BOSH_STATE/.starship.managed-pending" ]]
CASE

test_case "H1: already managed update retains first original backup" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'USER-ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'V1\n' > "$HOME/replacement"
install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
read_manifest starship
old_backup="${BOSH_MANIFEST[backup_path_b64]}"
[[ "$old_backup" != '-' ]]
printf 'V2\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"
read_manifest starship
[[ "${BOSH_MANIFEST[backup_path_b64]}" == "$old_backup" ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == V2 ]]
CASE

test_case "H1: external edit after crash is preserved and recovery blocked" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'NEW\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
printf 'PERSONAL-EDIT\n' > "$BOSH_HOME/starship.toml"
if bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"; then
    echo "ERROR: external edit accepted"; exit 1
fi
[[ "$(cat "$BOSH_HOME/starship.toml")" == "PERSONAL-EDIT" ]]
[[ -d "$BOSH_STATE/.starship.managed-pending" ]]
[[ ! -e "$BOSH_STATE/starship_manifest" ]]
CASE

test_case "H1: abort before destination mv cleans an uncommitted journal" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'OLD\n' > "$BOSH_HOME/starship.toml"
printf 'NEW\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == "$BOSH_HOME/starship.toml" ]]; then exit 86; fi
        command mv "$@"
    }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == OLD ]]
[[ -d "$BOSH_STATE/.starship.managed-pending" ]]
bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"
[[ ! -e "$BOSH_STATE/.starship.managed-pending" ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == OLD ]]
CASE

test_summary
