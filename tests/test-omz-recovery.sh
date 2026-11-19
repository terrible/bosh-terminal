#!/usr/bin/env bash
# First-install OMZ journal: no internet; every test gets isolated HOME.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "OMZ H1: interruption after manifest and before clone publication" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == "$HOME/.oh-my-zsh" ]]; then exit 86; fi
        command mv "$@"
    }
    install_oh_my_zsh
' || status=$?
[[ "$status" -eq 86 ]]
[[ ! -e "$HOME/.oh-my-zsh" ]]
[[ -f "$BOSH_STATE/oh_my_zsh_manifest" && -f "$BOSH_STATE/oh_my_zsh_txn" ]]
bosh_omz_txn_recover
[[ ! -e "$BOSH_STATE/oh_my_zsh_manifest" && ! -e "$BOSH_STATE/oh_my_zsh_txn" ]]
compgen -G "$BOSH_STATE/oh_my_zsh_manifest.archived-*" > /dev/null
install_oh_my_zsh
[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" && ! -e "$BOSH_STATE/oh_my_zsh_txn" ]]
read_manifest oh_my_zsh
[[ "${BOSH_MANIFEST[ownership]}" == created ]]
CASE

test_case "OMZ H1: SIGKILL before clone rename preserves uninvolved paths" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
printf 'PERSONAL-UNTOUCHED\n' > "$HOME/foreign.txt"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    mv() {
        if [[ "${*: -1}" == "$HOME/.oh-my-zsh" ]]; then kill -KILL "$BASHPID"; fi
        command mv "$@"
    }
    install_oh_my_zsh
' || status=$?
[[ "$status" -eq 137 ]]
[[ ! -e "$HOME/.oh-my-zsh" && -f "$BOSH_STATE/oh_my_zsh_txn" ]]
bosh_omz_txn_recover
[[ ! -e "$BOSH_STATE/oh_my_zsh_manifest" ]]
[[ "$(cat "$HOME/foreign.txt")" == PERSONAL-UNTOUCHED ]]
CASE

test_case "OMZ H1: manifest registration fails after journal publication" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_oh_my_zsh
' || status=$?
[[ "$status" -eq 86 ]]
[[ -f "$BOSH_STATE/oh_my_zsh_txn" ]]
[[ ! -e "$BOSH_STATE/oh_my_zsh_manifest" && ! -e "$HOME/.oh-my-zsh" ]]
bosh_omz_txn_recover
[[ ! -e "$BOSH_STATE/oh_my_zsh_txn" ]]
install_oh_my_zsh
[[ -f "$BOSH_STATE/oh_my_zsh_manifest" ]]
CASE

test_case "OMZ H1: interrupted cleanup after published repository retries safely" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    archive_state() {
        if [[ "$1" == oh_my_zsh_txn ]]; then exit 87; fi
        return 1
    }
    install_oh_my_zsh
' || status=$?
[[ "$status" -eq 87 ]]
[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]
[[ -f "$BOSH_STATE/oh_my_zsh_txn" && -f "$BOSH_STATE/oh_my_zsh_manifest" ]]
bosh_omz_txn_recover
[[ ! -e "$BOSH_STATE/oh_my_zsh_txn" ]]
old_hash="$(bosh_omz_txn_hash "$BOSH_STATE/oh_my_zsh_manifest")"
install_oh_my_zsh
[[ "$(bosh_omz_txn_hash "$BOSH_STATE/oh_my_zsh_manifest")" == "$old_hash" ]]
CASE

test_case "OMZ H1: external plugin modification blocks journal completion" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    archive_state() {
        if [[ "$1" == oh_my_zsh_txn ]]; then exit 87; fi
        return 1
    }
    install_oh_my_zsh
' || status=$?
[[ "$status" -eq 87 ]]
printf 'CUSTOM PLUGIN\n' >> "$HOME/.oh-my-zsh/plugins/example/example.plugin.zsh"
if bosh_omz_txn_recover; then
    echo 'ERROR: modified plugin accepted'; exit 1
fi
grep -Fqx 'CUSTOM PLUGIN' "$HOME/.oh-my-zsh/plugins/example/example.plugin.zsh"
[[ -f "$BOSH_STATE/oh_my_zsh_txn" ]]
[[ -f "$BOSH_STATE/oh_my_zsh_manifest" ]]
CASE

test_case "OMZ H1: changed Git remote blocks journal completion" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    archive_state() {
        if [[ "$1" == oh_my_zsh_txn ]]; then exit 87; fi
        return 1
    }
    install_oh_my_zsh
' || status=$?
[[ "$status" -eq 87 ]]
"$TEST_REAL_GIT" -C "$HOME/.oh-my-zsh" remote set-url origin "https://invalid.example/git"
if bosh_omz_txn_recover; then
    echo 'ERROR: modified origin accepted'; exit 1
fi
[[ -f "$BOSH_STATE/oh_my_zsh_txn" ]]
[[ "$("$TEST_REAL_GIT" -C "$HOME/.oh-my-zsh" remote get-url origin)" == https://invalid.example/git ]]
CASE

test_case "OMZ H1: corrupted journal is not sourced, executed or erased" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_oh_my_zsh
' || status=$?
[[ "$status" -eq 86 ]]
printf '\n$(touch "$HOME"/journal-executed)\n' >> "$BOSH_STATE/oh_my_zsh_txn"
if bosh_omz_txn_recover; then
    echo 'ERROR: corrupted journal accepted'; exit 1
fi
[[ ! -e "$HOME/journal-executed" ]]
[[ -f "$BOSH_STATE/oh_my_zsh_txn" ]]
[[ ! -e "$HOME/.oh-my-zsh" ]]
CASE

test_case "OMZ H1: symlinked journal cannot redirect read or cleanup" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    write_manifest() { exit 86; }
    install_oh_my_zsh
' || status=$?
[[ "$status" -eq 86 ]]
mv "$BOSH_STATE/oh_my_zsh_txn" "$BOSH_STATE/txn-original"
ln -s txn-original "$BOSH_STATE/oh_my_zsh_txn"
if bosh_omz_txn_recover; then
    echo 'ERROR: linked journal accepted'; exit 1
fi
[[ -L "$BOSH_STATE/oh_my_zsh_txn" ]]
[[ -f "$BOSH_STATE/txn-original" ]]
CASE

test_summary
