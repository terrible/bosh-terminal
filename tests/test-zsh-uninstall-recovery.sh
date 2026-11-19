#!/usr/bin/env bash
# H1: interrupted Zsh uninstallation, idempotence and preservation tests.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Zsh uninstall H1: created .zshrc removal crash before manifest archival" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
integrate_zsh
[[ -f "$HOME/.zshrc" && -f "$BOSH_STATE/zshrc_manifest" ]]
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/uninstall.sh"
    archive_state() {
        [[ "$1" != zshrc_manifest ]] || exit 88
        command false
    }
    bosh_uninstall_process_zsh
' || status=$?
[[ "$status" -eq 88 ]]
[[ ! -e "$HOME/.zshrc" ]]
[[ -f "$BOSH_STATE/zshrc_manifest" && -f "$BOSH_STATE/zshrc_uninstall_txn" ]]
bosh_uninstall_process_zsh
[[ ! -e "$HOME/.zshrc" ]]
[[ ! -e "$BOSH_STATE/zshrc_manifest" && ! -e "$BOSH_STATE/zshrc_uninstall_txn" ]]
compgen -G "$BOSH_STATE/zshrc_manifest.archived-*" >/dev/null
CASE

test_case "Zsh uninstall H1: appended crash preserves aliases and mode" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
printf 'alias keep="echo yes"\n' > "$HOME/.zshrc"
chmod 640 "$HOME/.zshrc"
original="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
integrate_zsh
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/uninstall.sh"
    archive_state() {
        [[ "$1" != zshrc_manifest ]] || exit 88
        command false
    }
    bosh_uninstall_process_zsh
' || status=$?
[[ "$status" -eq 88 ]]
[[ -f "$BOSH_STATE/zshrc_uninstall_txn" && -f "$BOSH_STATE/zshrc_manifest" ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original" ]]
bosh_uninstall_process_zsh
[[ ! -e "$BOSH_STATE/zshrc_manifest" && ! -e "$BOSH_STATE/zshrc_uninstall_txn" ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == 640 ]]
CASE

test_case "Zsh uninstall H1: legacy replacement restore survives crash" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
printf '# Bosh Terminal - Zsh\nalias legacy="echo legacy"\n' > "$HOME/.zshrc"
chmod 640 "$HOME/.zshrc"
original="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
confirm() { return 0; }
integrate_zsh
read_manifest zshrc
[[ "${BOSH_MANIFEST[mode]}" == legacy_replaced ]]
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/uninstall.sh"
    archive_state() {
        [[ "$1" != zshrc_manifest ]] || exit 88
        command false
    }
    bosh_uninstall_process_zsh
' || status=$?
[[ "$status" -eq 88 ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original" ]]
[[ -f "$BOSH_STATE/zshrc_uninstall_txn" ]]
bosh_uninstall_process_zsh
[[ ! -e "$BOSH_STATE/zshrc_manifest" && ! -e "$BOSH_STATE/zshrc_uninstall_txn" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == 640 ]]
CASE

test_case "Zsh uninstall H1: crash before file mutation safely retries" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
printf 'alias user="echo user"\n' > "$HOME/.zshrc"
integrate_zsh
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/uninstall.sh"
    mv() {
        if [[ "${*: -1}" == "$HOME/.zshrc" ]]; then exit 86; fi
        command mv "$@"
    }
    bosh_uninstall_process_zsh
' || status=$?
[[ "$status" -eq 86 ]]
[[ -f "$BOSH_STATE/zshrc_uninstall_txn" ]]
grep -Fqx '# >>> Bosh Terminal >>>' "$HOME/.zshrc"
bosh_uninstall_process_zsh
[[ ! -e "$BOSH_STATE/zshrc_uninstall_txn" ]]
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]
[[ "$(cat "$HOME/.zshrc")" == 'alias user="echo user"' ]]
CASE

test_case "Zsh uninstall H1: external edit after deletion blocks cleanup" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
printf 'alias user="echo user"\n' > "$HOME/.zshrc"
integrate_zsh
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/uninstall.sh"
    archive_state() {
        [[ "$1" != zshrc_manifest ]] || exit 88
        command false
    }
    bosh_uninstall_process_zsh
' || status=$?
[[ "$status" -eq 88 ]]
printf 'alias new="echo new"\n' >> "$HOME/.zshrc"
before="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
if bosh_uninstall_process_zsh; then
    echo 'ERROR: external edit during cleanup accepted'; exit 1
fi
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$before" ]]
[[ -f "$BOSH_STATE/zshrc_uninstall_txn" && -f "$BOSH_STATE/zshrc_manifest" ]]
[[ "$BOSH_UNINSTALL_ERRORS" -eq 1 ]]
CASE

test_case "Zsh uninstall H1: crash between manifest and journal archival" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
printf 'alias original="echo original"\n' > "$HOME/.zshrc"
integrate_zsh
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/uninstall.sh"
    archive_state() {
        if [[ "$1" == zshrc_uninstall_txn ]]; then exit 89; fi
        command mv -nT -- "$BOSH_STATE/zshrc_manifest" "$BOSH_STATE/zshrc_manifest.archived-crash"
    }
    bosh_uninstall_process_zsh
' || status=$?
[[ "$status" -eq 89 ]]
[[ -f "$BOSH_STATE/zshrc_uninstall_txn" ]]
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]
[[ "$(cat "$HOME/.zshrc")" == 'alias original="echo original"' ]]
bosh_uninstall_process_zsh
[[ ! -e "$BOSH_STATE/zshrc_uninstall_txn" ]]
[[ "$(cat "$HOME/.zshrc")" == 'alias original="echo original"' ]]
CASE

test_case "Zsh uninstall H1: malformed journal blocks uninstall" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
printf 'alias user="echo user"\n' > "$HOME/.zshrc"
integrate_zsh
write_state zshrc_uninstall_txn 'version=invalid'
before="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
if bosh_uninstall_process_zsh; then
    echo 'ERROR: malformed journal accepted'; exit 1
fi
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$before" ]]
[[ -f "$BOSH_STATE/zshrc_uninstall_txn" ]]
CASE


test_case "Zsh uninstall H1: SIGKILL after removing block preserves custom aliases" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
printf 'alias important="echo important"\n' > "$HOME/.zshrc"
original_hash="$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)"
integrate_zsh
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/uninstall.sh"
    archive_state() {
        if [[ "$1" == zshrc_manifest ]]; then kill -KILL "$BASHPID"; fi
        command false
    }
    bosh_uninstall_process_zsh
' || status=$?
[[ "$status" -eq 137 ]]
[[ -f "$BOSH_STATE/zshrc_manifest" && -f "$BOSH_STATE/zshrc_uninstall_txn" ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original_hash" ]]
bosh_uninstall_process_zsh
[[ ! -e "$BOSH_STATE/zshrc_manifest" && ! -e "$BOSH_STATE/zshrc_uninstall_txn" ]]
[[ "$(sha256sum "$HOME/.zshrc" | cut -d ' ' -f 1)" == "$original_hash" ]]
CASE

test_summary
