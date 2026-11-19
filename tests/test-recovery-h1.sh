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
[[ -f "$BOSH_STATE/.starship.managed-pending/previous_destination" ]]
[[ "$(stat -c '%a' "$BOSH_STATE/.starship.managed-pending")" == 700 ]]
if compgen -G "${destination}.bosh-rollback.*" >/dev/null; then
    echo "ERROR: detached rollback snapshot leaked"; exit 1
fi
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


test_case "H1: crash after manifest commit is idempotently finalized" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'CANDIDATE\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    bosh_managed_txn_finish() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == CANDIDATE ]]
[[ -f "$BOSH_STATE/starship_manifest" ]]
[[ -d "$BOSH_STATE/.starship.managed-pending" ]]
bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"
[[ ! -e "$BOSH_STATE/.starship.managed-pending" ]]
read_manifest starship
[[ "${BOSH_MANIFEST[backup_path_b64]}" != '-' ]]
CASE

test_case "H1: wrong journal permissions prevent recovery" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'CANDIDATE\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
pending="$BOSH_STATE/.starship.managed-pending"
chmod 755 "$pending"
if bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"; then
    echo "ERROR: insecure journal accepted"; exit 1
fi
[[ "$(cat "$BOSH_HOME/starship.toml")" == CANDIDATE ]]
[[ ! -e "$BOSH_STATE/starship_manifest" ]]
[[ -d "$pending" ]]
CASE

test_case "H1: symlinked journal record cannot be trusted" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'CANDIDATE\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
pending="$BOSH_STATE/.starship.managed-pending"
mv -- "$pending/record" "$pending/record.saved"
ln -s record.saved "$pending/record"
if bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"; then
    echo "ERROR: symlinked record accepted"; exit 1
fi
[[ -L "$pending/record" && -f "$pending/record.saved" ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == CANDIDATE ]]
[[ ! -e "$BOSH_STATE/starship_manifest" ]]
CASE


test_case "H1: crash during journal preparation must not block next install" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
destination="$BOSH_HOME/starship.toml"
printf 'ORIGINAL\n' > "$destination"
printf 'REPLACEMENT\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == */record ]]; then
            exit 86
        fi
        command mv "$@"
    }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
[[ "$(cat "$destination")" == ORIGINAL ]]
[[ ! -e "$BOSH_STATE/starship_manifest" ]]
[[ ! -e "$BOSH_STATE/.starship.managed-pending" ]]

install_managed_file "$HOME/replacement" "$destination" starship
read_manifest starship
[[ "${BOSH_MANIFEST[preexisting]}" == 1 ]]
[[ "${BOSH_MANIFEST[backup_path_b64]}" != '-' ]]
[[ "$(cat "$destination")" == REPLACEMENT ]]
CASE

test_case "H1: corrupted candidate manifest remains quarantined" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'REPLACEMENT\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
printf '\nUNTRUSTED\n' >> "$BOSH_STATE/.starship.managed-pending/next"
if bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"; then
    echo "ERROR: corrupt manifest accepted"; exit 1
fi
[[ "$(cat "$BOSH_HOME/starship.toml")" == REPLACEMENT ]]
[[ ! -e "$BOSH_STATE/starship_manifest" ]]
[[ -d "$BOSH_STATE/.starship.managed-pending" ]]
CASE


test_case "H1: unexpected file inside journal must be preserved" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'REPLACEMENT\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    bosh_managed_txn_finish() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
dir="$BOSH_STATE/.starship.managed-pending"
[[ -d "$dir" ]]
printf 'EXTERNAL-CONTENT\n' > "$dir/unexpected-file"
if bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"; then
    echo "ERROR: a journal with unexpected entries was deleted"; exit 1
fi
[[ -f "$dir/unexpected-file" ]]
[[ "$(cat "$dir/unexpected-file")" == EXTERNAL-CONTENT ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == REPLACEMENT ]]
CASE


test_case "H1: interruption inside recovery after manifest commit is idempotent" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'PERSONAL\n' > "$BOSH_HOME/starship.toml"
printf 'MANAGED\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    bosh_managed_txn_finish() { exit 87; }
    bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"
' || status=$?
[[ "$status" -eq 87 ]]
[[ -d "$BOSH_STATE/.starship.managed-pending" ]]
[[ -f "$BOSH_STATE/starship_manifest" ]]
bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"
bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"
[[ ! -e "$BOSH_STATE/.starship.managed-pending" ]]
read_manifest starship
[[ "${BOSH_MANIFEST[backup_path_b64]}" != '-' ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == MANAGED ]]
CASE

test_case "H1: interrupted cleanup of completed journal is resumed" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'PERSONAL\n' > "$BOSH_HOME/starship.toml"
printf 'MANAGED\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    rm() {
        if [[ "$*" == *".starship.managed-completed."* ]]; then exit 87; fi
        command rm "$@"
    }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 87 ]]
[[ -f "$BOSH_STATE/starship_manifest" ]]
[[ ! -e "$BOSH_STATE/.starship.managed-pending" ]]
compgen -G "$BOSH_STATE/.starship.managed-completed.*" >/dev/null

bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"
if compgen -G "$BOSH_STATE/.starship.managed-completed.*" >/dev/null; then
    echo "ERROR: completed journal still present after recovery"
    exit 1
fi
read_manifest starship
[[ "${BOSH_MANIFEST[backup_path_b64]}" != '-' ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == MANAGED ]]
CASE

test_case "H1: foreign entry in completed journal blocks cleanup" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'PERSONAL\n' > "$BOSH_HOME/starship.toml"
printf 'MANAGED\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    rm() {
        if [[ "$*" == *".starship.managed-completed."* ]]; then exit 87; fi
        command rm "$@"
    }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 87 ]]
completed=( "$BOSH_STATE"/.starship.managed-completed.* )
[[ "${#completed[@]}" -eq 1 && -d "${completed[0]}" ]]
printf 'USER-SENTINEL\n' > "${completed[0]}/unrecognized"
if bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"; then
    echo "ERROR: recovery accepted a foreign completed entry"
    exit 1
fi
[[ "$(cat "${completed[0]}/unrecognized")" == USER-SENTINEL ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == MANAGED ]]
[[ -f "$BOSH_STATE/starship_manifest" ]]
CASE

test_case "H1: interrupted prepare directory is safely garbage collected" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'PERSONAL\n' > "$BOSH_HOME/starship.toml"
printf 'MANAGED\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == */record ]]; then exit 86; fi
        command mv "$@"
    }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
compgen -G "$BOSH_STATE/.starship.managed-prepare.*" >/dev/null
[[ "$(cat "$BOSH_HOME/starship.toml")" == PERSONAL ]]
install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
if compgen -G "$BOSH_STATE/.starship.managed-prepare.*" >/dev/null; then
    echo "ERROR: interrupted preparation left private residuals"
    exit 1
fi
[[ "$(cat "$BOSH_HOME/starship.toml")" == MANAGED ]]
CASE


test_case "H1: SIGKILL in middle of completed cleanup is retryable" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'CANDIDATE\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    rm() {
        if [[ "$*" == *".starship.managed-completed."*"/previous_destination" ]]; then
            command rm "$@"
            kill -KILL "$BASHPID"
        fi
        command rm "$@"
    }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 137 ]]
[[ -f "$BOSH_STATE/starship_manifest" ]]
completed=( "$BOSH_STATE"/.starship.managed-completed.* )
[[ "${#completed[@]}" -eq 1 && -d "${completed[0]}" ]]
[[ ! -e "${completed[0]}/previous_destination" ]]
[[ -f "${completed[0]}/record" ]]
bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"
[[ ! -e "${completed[0]}" ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == CANDIDATE ]]
CASE

test_case "H1: symlink inside stale preparation is preserved" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'CANDIDATE\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == */record ]]; then exit 86; fi
        command mv "$@"
    }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
staging=( "$BOSH_STATE"/.starship.managed-prepare.* )
[[ "${#staging[@]}" -eq 1 ]]
printf 'SENTINEL\n' > "$HOME/external"
ln -s "$HOME/external" "${staging[0]}/unexpected-link"
if bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"; then
    echo "ERROR: linked staging artifact was deleted"; exit 1
fi
[[ -L "${staging[0]}/unexpected-link" ]]
[[ "$(cat "$HOME/external")" == SENTINEL ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == ORIGINAL ]]
CASE

test_case "H1: hardlinked staging snapshot is never silently deleted" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p "$BOSH_HOME"
printf 'ORIGINAL\n' > "$BOSH_HOME/starship.toml"
printf 'CANDIDATE\n' > "$HOME/replacement"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == */record ]]; then exit 86; fi
        command mv "$@"
    }
    install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' || status=$?
[[ "$status" -eq 86 ]]
staging=( "$BOSH_STATE"/.starship.managed-prepare.* )
[[ "${#staging[@]}" -eq 1 ]]
ln "${staging[0]}/previous_destination" "$HOME/shared-link"
if bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml"; then
    echo "ERROR: multiply-linked snapshot was removed"; exit 1
fi
[[ -f "$HOME/shared-link" ]]
[[ "$(cat "$HOME/shared-link")" == ORIGINAL ]]
[[ -f "${staging[0]}/previous_destination" ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == ORIGINAL ]]
CASE

test_summary
