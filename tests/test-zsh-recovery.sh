#!/usr/bin/env bash
# H1 Zsh interruption and recovery tests; isolated HOME per test.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Zsh H1: created mode crash after manifest, before .zshrc rename" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == "$HOME/.zshrc" ]]; then exit 86; fi
        command mv "$@"
    }
    integrate_zsh
' || status=$?
[[ "$status" -eq 86 ]]
[[ ! -e "$HOME/.zshrc" ]]
[[ -f "$BOSH_STATE/zshrc_manifest" && -f "$BOSH_STATE/zshrc_txn" ]]
bosh_zsh_txn_recover
[[ ! -e "$BOSH_STATE/zshrc_txn" && ! -e "$BOSH_STATE/zshrc_manifest" ]]
[[ ! -e "$HOME/.zshrc" ]]
compgen -G "$BOSH_STATE/zshrc_manifest.archived-*" >/dev/null
integrate_zsh
[[ -f "$HOME/.zshrc" ]]
[[ "$(grep -Fxc '# >>> Bosh Terminal >>>' "$HOME/.zshrc")" == 1 ]]
[[ ! -e "$BOSH_STATE/zshrc_txn" ]]
source "$BOSH_TEST_PROJECT/uninstall.sh"
bosh_uninstall_process_zsh
[[ ! -e "$HOME/.zshrc" ]]
CASE

test_case "Zsh H1: appended crash preserves alias and original mode" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'alias ll="ls -lah"\n' > "$HOME/.zshrc"
chmod 640 "$HOME/.zshrc"
original="$(sha256sum "$HOME/.zshrc")"
original="${original%% *}"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == "$HOME/.zshrc" ]]; then exit 86; fi
        command mv "$@"
    }
    integrate_zsh
' || status=$?
[[ "$status" -eq 86 ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == 640 ]]
[[ -f "$BOSH_STATE/zshrc_manifest" && -f "$BOSH_STATE/zshrc_txn" ]]
bosh_zsh_txn_recover
[[ ! -e "$BOSH_STATE/zshrc_manifest" && ! -e "$BOSH_STATE/zshrc_txn" ]]
integrate_zsh
read_manifest zshrc
[[ "${BOSH_MANIFEST[mode]}" == appended ]]
[[ "${BOSH_MANIFEST[original_mode]}" == 640 ]]
[[ "${BOSH_MANIFEST[backup_sha256]}" == "$original" ]]
source "$BOSH_TEST_PROJECT/uninstall.sh"
bosh_uninstall_process_zsh
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == 640 ]]
CASE

test_case "Zsh H1: process exits after .zshrc publication before journal archival" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'alias custom="printf hello"\n' > "$HOME/.zshrc"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    archive_state() {
        if [[ "$1" == zshrc_txn ]]; then exit 87; fi
        command false
    }
    integrate_zsh
' || status=$?
[[ "$status" -eq 87 ]]
[[ -f "$BOSH_STATE/zshrc_manifest" && -f "$BOSH_STATE/zshrc_txn" ]]
[[ "$(grep -Fxc '# >>> Bosh Terminal >>>' "$HOME/.zshrc")" == 1 ]]
bosh_zsh_txn_recover
bosh_zsh_txn_recover
[[ ! -e "$BOSH_STATE/zshrc_txn" ]]
integrate_zsh
[[ "$(grep -Fxc '# >>> Bosh Terminal >>>' "$HOME/.zshrc")" == 1 ]]
grep -Fqx 'alias custom="printf hello"' "$HOME/.zshrc"
source "$BOSH_TEST_PROJECT/uninstall.sh"
bosh_uninstall_process_zsh
[[ "$(cat "$HOME/.zshrc")" == 'alias custom="printf hello"' ]]
CASE

test_case "Zsh H1: aborted manifest write keeps original and cleans journal" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'export MY_VARIABLE=value\n' > "$HOME/.zshrc"
before="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    integrate_zsh
' || status=$?
[[ "$status" -eq 86 ]]
[[ -f "$BOSH_STATE/zshrc_txn" && ! -e "$BOSH_STATE/zshrc_manifest" ]]
bosh_zsh_txn_recover
[[ ! -e "$BOSH_STATE/zshrc_txn" ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$before" ]]
integrate_zsh
grep -Fqx 'export MY_VARIABLE=value' "$HOME/.zshrc"
CASE

test_case "Zsh H1: external edit during interruption blocks recovery" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'alias old="echo old"\n' > "$HOME/.zshrc"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == "$HOME/.zshrc" ]]; then exit 86; fi
        command mv "$@"
    }
    integrate_zsh
' || status=$?
[[ "$status" -eq 86 ]]
printf 'alias own="echo own"\n' >> "$HOME/.zshrc"
before="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
if bosh_zsh_txn_recover; then
    echo 'ERROR: user modification accepted'; exit 1
fi
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$before" ]]
[[ -f "$BOSH_STATE/zshrc_txn" && -f "$BOSH_STATE/zshrc_manifest" ]]
source "$BOSH_TEST_PROJECT/uninstall.sh"
if bosh_uninstall_process_zsh; then
    echo 'ERROR: uninstaller ignored pending conflicted journal'; exit 1
fi
[[ "$BOSH_UNINSTALL_ERRORS" -eq 1 ]]
[[ -f "$BOSH_STATE/zshrc_txn" ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$before" ]]
CASE

test_case "Zsh H1: symlinked pending journal is preserved and rejected" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'alias old="echo old"\n' > "$HOME/.zshrc"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    integrate_zsh
' || status=$?
[[ "$status" -eq 86 ]]
mv "$BOSH_STATE/zshrc_txn" "$BOSH_STATE/transaction.bak"
ln -s "transaction.bak" "$BOSH_STATE/zshrc_txn"
if bosh_zsh_txn_recover; then
    echo 'ERROR: symlinked journal was accepted'; exit 1
fi
[[ -L "$BOSH_STATE/zshrc_txn" && -f "$BOSH_STATE/transaction.bak" ]]
grep -Fxq 'alias old="echo old"' "$HOME/.zshrc"
CASE

test_case "Zsh H1: malformed journal does not replace user configuration" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'alias old="echo old"\n' > "$HOME/.zshrc"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    integrate_zsh
' || status=$?
[[ "$status" -eq 86 ]]
printf '\nFOREIGN=1\n' >> "$BOSH_STATE/zshrc_txn"
if bosh_zsh_txn_recover; then
    echo 'ERROR: malformed journal was accepted'; exit 1
fi
[[ -f "$BOSH_STATE/zshrc_txn" ]]
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]
grep -Fxq 'alias old="echo old"' "$HOME/.zshrc"
CASE

test_case "Zsh H1: completed integration remains idempotent across rerun" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'alias x="echo x"\n' > "$HOME/.zshrc"
integrate_zsh
[[ ! -e "$BOSH_STATE/zshrc_txn" && -f "$BOSH_STATE/zshrc_manifest" ]]
before="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
integrate_zsh
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$before" ]]
[[ "$(grep -Fxc '# >>> Bosh Terminal >>>' "$HOME/.zshrc")" == 1 ]]
CASE


test_case "Zsh H1: SIGKILL before .zshrc rename preserves original" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'alias original="echo original"\n' > "$HOME/.zshrc"
original_hash="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == "$HOME/.zshrc" ]]; then kill -KILL "$BASHPID"; fi
        command mv "$@"
    }
    integrate_zsh
' || status=$?
[[ "$status" -eq 137 ]]
[[ -f "$BOSH_STATE/zshrc_manifest" && -f "$BOSH_STATE/zshrc_txn" ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original_hash" ]]
bosh_zsh_txn_recover
[[ ! -e "$BOSH_STATE/zshrc_txn" && ! -e "$BOSH_STATE/zshrc_manifest" ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original_hash" ]]
CASE

test_summary
