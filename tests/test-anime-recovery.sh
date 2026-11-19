#!/usr/bin/env bash
# H1 anime interruption tests; all images are local fixtures in isolated HOME.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Anime H1: first image crash before manifest is adopted and removable" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/mock-source"
ANIME_DEST="$HOME/mock-dest"
mkdir -p "$ANIME_SOURCE"
printf 'V1 ANIME\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/mock-source"
    ANIME_DEST="$HOME/mock-dest"
    name_hash="$(printf bosh1.png | sha256sum)"
    key="anime_${name_hash%% *}"
    TEST_MANIFEST_PATH="$BOSH_STATE/$key"
    mv() {
        if [[ "${*: -1}" == "$TEST_MANIFEST_PATH" ]]; then exit 86; fi
        command mv "$@"
    }
    install_anime_images
' || status=$?
[[ "$status" -eq 86 ]]
[[ -f "$ANIME_DEST/bosh1.png" ]]
[[ -f "$BOSH_STATE/${key}_txn" && ! -e "$BOSH_STATE/$key" ]]
bosh_anime_txn_recover_all
[[ -f "$BOSH_STATE/$key" && ! -e "$BOSH_STATE/${key}_txn" ]]
source "$BOSH_TEST_PROJECT/uninstall.sh"
bosh_uninstall_process_anime
[[ ! -e "$ANIME_DEST/bosh1.png" ]]
CASE

test_case "Anime H1: managed image update is reconciled after SIGKILL" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/mock-source"
ANIME_DEST="$HOME/mock-dest"
mkdir -p "$ANIME_SOURCE"
printf 'V1 ANIME\n' > "$ANIME_SOURCE/bosh1.png"
install_anime_images
printf 'V2 ANIME\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
old_manifest="$(bosh_anime_txn_hash "$BOSH_STATE/$key")"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/mock-source"
    ANIME_DEST="$HOME/mock-dest"
    name_hash="$(printf bosh1.png | sha256sum)"
    key="anime_${name_hash%% *}"
    TEST_MANIFEST_PATH="$BOSH_STATE/$key"
    mv() {
        if [[ "${*: -1}" == "$TEST_MANIFEST_PATH" ]]; then kill -KILL "$BASHPID"; fi
        command mv "$@"
    }
    install_anime_images
' || status=$?
[[ "$status" -eq 137 ]]
[[ "$(cat "$ANIME_DEST/bosh1.png")" == "V2 ANIME" ]]
[[ "$(bosh_anime_txn_hash "$BOSH_STATE/$key")" == "$old_manifest" ]]
[[ -f "$BOSH_STATE/${key}_txn" ]]
bosh_anime_txn_recover_all
[[ ! -e "$BOSH_STATE/${key}_txn" ]]
grep -Fxq "sha256=$(bosh_anime_txn_hash "$ANIME_DEST/bosh1.png")" "$BOSH_STATE/$key"
install_anime_images
[[ "$(cat "$ANIME_DEST/bosh1.png")" == "V2 ANIME" ]]
CASE

test_case "Anime H1: crash before destination rename keeps prior version" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/mock-source"
ANIME_DEST="$HOME/mock-dest"
mkdir -p "$ANIME_SOURCE"
printf 'ORIGINAL\n' > "$ANIME_SOURCE/bosh1.png"
install_anime_images
printf 'CANDIDATE\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
old_manifest="$(bosh_anime_txn_hash "$BOSH_STATE/$key")"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/mock-source"
    ANIME_DEST="$HOME/mock-dest"
    mv() {
        if [[ "${*: -1}" == "$ANIME_DEST/bosh1.png" ]]; then exit 86; fi
        command mv "$@"
    }
    install_anime_images
' || status=$?
[[ "$status" -eq 86 ]]
[[ "$(cat "$ANIME_DEST/bosh1.png")" == ORIGINAL ]]
bosh_anime_txn_recover_all
[[ ! -e "$BOSH_STATE/${key}_txn" ]]
[[ "$(bosh_anime_txn_hash "$BOSH_STATE/$key")" == "$old_manifest" ]]
install_anime_images
[[ "$(cat "$ANIME_DEST/bosh1.png")" == CANDIDATE ]]
CASE

test_case "Anime H1: external edit after crash is preserved without adoption" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/mock-source"
ANIME_DEST="$HOME/mock-dest"
mkdir -p "$ANIME_SOURCE"
printf 'OLD\n' > "$ANIME_SOURCE/bosh1.png"
install_anime_images
printf 'NEW\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
old_manifest="$(bosh_anime_txn_hash "$BOSH_STATE/$key")"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/mock-source"
    ANIME_DEST="$HOME/mock-dest"
    name_hash="$(printf bosh1.png | sha256sum)"
    key="anime_${name_hash%% *}"
    TEST_MANIFEST_PATH="$BOSH_STATE/$key"
    mv() {
        if [[ "${*: -1}" == "$TEST_MANIFEST_PATH" ]]; then exit 86; fi
        command mv "$@"
    }
    install_anime_images
' || status=$?
[[ "$status" -eq 86 ]]
printf 'USER EDIT\n' >> "$ANIME_DEST/bosh1.png"
new_hash="$(bosh_anime_txn_hash "$ANIME_DEST/bosh1.png")"
if bosh_anime_txn_recover_all; then
    echo "ERROR: tampered image adopted"; exit 1
fi
[[ "$(bosh_anime_txn_hash "$ANIME_DEST/bosh1.png")" == "$new_hash" ]]
[[ "$(bosh_anime_txn_hash "$BOSH_STATE/$key")" == "$old_manifest" ]]
[[ -f "$BOSH_STATE/${key}_txn" ]]
CASE

test_case "Anime H1: preexisting personal image is never acquired" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/mock-source"
ANIME_DEST="$HOME/mock-dest"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"
printf 'PROJECT IMAGE\n' > "$ANIME_SOURCE/bosh1.png"
printf 'PERSONAL IMAGE\n' > "$ANIME_DEST/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
install_anime_images
[[ "$(cat "$ANIME_DEST/bosh1.png")" == "PERSONAL IMAGE" ]]
[[ ! -e "$BOSH_STATE/$key" && ! -e "$BOSH_STATE/${key}_txn" ]]
CASE

test_case "Anime H1: malformed or symbolic journal blocks file changes" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/mock-source"
ANIME_DEST="$HOME/mock-dest"
mkdir -p "$ANIME_SOURCE"
printf 'ORIGINAL\n' > "$ANIME_SOURCE/bosh1.png"
install_anime_images
printf 'CANDIDATE\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/mock-source"
    ANIME_DEST="$HOME/mock-dest"
    mv() {
        if [[ "${*: -1}" == "$ANIME_DEST/bosh1.png" ]]; then exit 86; fi
        command mv "$@"
    }
    install_anime_images
' || status=$?
[[ "$status" -eq 86 ]]
journal="$BOSH_STATE/${key}_txn"
mv "$journal" "$journal.original"
ln -s "$journal.original" "$journal"
if bosh_anime_txn_recover_all; then
    echo "ERROR: symlinked journal accepted"; exit 1
fi
[[ -L "$journal" && -f "$journal.original" ]]
[[ "$(cat "$ANIME_DEST/bosh1.png")" == ORIGINAL ]]
CASE

test_case "Anime H1: uninstaller recovers journal before removing an image" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/mock-source"
ANIME_DEST="$HOME/mock-dest"
mkdir -p "$ANIME_SOURCE"
printf 'BASE\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/mock-source"
    ANIME_DEST="$HOME/mock-dest"
    name_hash="$(printf bosh1.png | sha256sum)"
    key="anime_${name_hash%% *}"
    TEST_MANIFEST_PATH="$BOSH_STATE/$key"
    mv() {
        if [[ "${*: -1}" == "$TEST_MANIFEST_PATH" ]]; then exit 86; fi
        command mv "$@"
    }
    install_anime_images
' || status=$?
[[ "$status" -eq 86 ]]
[[ -f "$ANIME_DEST/bosh1.png" && -f "$BOSH_STATE/${key}_txn" && ! -e "$BOSH_STATE/$key" ]]
source "$BOSH_TEST_PROJECT/uninstall.sh"
bosh_uninstall_process_anime
[[ ! -e "$ANIME_DEST/bosh1.png" ]]
[[ ! -e "$BOSH_STATE/${key}_txn" ]]
CASE

test_summary
