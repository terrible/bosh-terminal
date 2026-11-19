#!/usr/bin/env bash
# Private anime rollback snapshots and original destination-mode preservation.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Anime rollback: SIGKILL keeps rollback private for 600/640/644" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_DEST="$HOME/images"
mkdir -p "$HOME/original-assets"
for mode in 600 640 644; do
    filename="bosh$mode.png"
    source_dir="$HOME/original-assets/$mode"
    mkdir -p "$source_dir"
    printf 'ORIGINAL-%s\n' "$mode" > "$source_dir/$filename"
    chmod "$mode" "$source_dir/$filename"
    ANIME_SOURCE="$source_dir"
    install_anime_images
    [[ "$(stat -c '%a' "$ANIME_DEST/$filename")" == "$mode" ]]
    printf 'UPDATED-%s\n' "$mode" > "$source_dir/$filename"
    result=0
    bash --noprofile --norc -euo pipefail -c '
        source "$BOSH_TEST_PROJECT/install.sh"
        ANIME_DEST="$HOME/images"
        ANIME_SOURCE="$HOME/original-assets/$1"
        name_hash="$(printf "bosh%s.png" "$1" | sha256sum)"
        TEST_MANIFEST_PATH="$BOSH_STATE/anime_${name_hash%% *}"
        mv() {
            if [[ "${*: -1}" == "$TEST_MANIFEST_PATH" ]]; then
                kill -KILL "$BASHPID"
            fi
            command mv "$@"
        }
        install_anime_images
    ' _ "$mode" || result=$?
    [[ "$result" -eq 137 ]]
    shopt -s nullglob
    snapshots=( "$ANIME_DEST/$filename".bosh-rollback.* )
    [[ "${#snapshots[@]}" == 1 ]]
    [[ "$(cat "${snapshots[0]}")" == "ORIGINAL-$mode" ]]
    [[ "$(stat -c '%a' "${snapshots[0]}")" == 600 ]]
    name_hash="$(printf "%s" "$filename" | sha256sum)"
    grep -Fxq "previous_mode=$mode" "$BOSH_STATE/anime_${name_hash%% *}_txn"
done
CASE

test_case "Anime rollback: failed manifest restores original content/modes 600/640/644" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_DEST="$HOME/images"
mkdir -p "$HOME/mode-assets"
for mode in 600 640 644; do
    filename="bosh$mode.png"
    source_dir="$HOME/mode-assets/$mode"
    mkdir -p "$source_dir"
    printf 'ORIGINAL-%s\n' "$mode" > "$source_dir/$filename"
    chmod "$mode" "$source_dir/$filename"
    ANIME_SOURCE="$source_dir"
    install_anime_images
    name_hash="$(printf '%s' "$filename" | sha256sum)"
    key="anime_${name_hash%% *}"
    manifest_before="$(bosh_file_sha256 "$BOSH_STATE/$key")"
    printf 'UPDATED-%s\n' "$mode" > "$source_dir/$filename"
    result=0
    bash --noprofile --norc -euo pipefail -c '
        source "$BOSH_TEST_PROJECT/install.sh"
        ANIME_DEST="$HOME/images"
        ANIME_SOURCE="$HOME/mode-assets/$1"
        name_hash="$(printf "bosh%s.png" "$1" | sha256sum)"
        TEST_MANIFEST_PATH="$BOSH_STATE/anime_${name_hash%% *}"
        mv() {
            if [[ "${*: -1}" == "$TEST_MANIFEST_PATH" ]]; then return 86; fi
            command mv "$@"
        }
        install_anime_images
    ' _ "$mode" || result=$?
    [[ "$result" -ne 0 ]]
    [[ "$(cat "$ANIME_DEST/$filename")" == "ORIGINAL-$mode" ]]
    [[ "$(stat -c '%a' "$ANIME_DEST/$filename")" == "$mode" ]]
    [[ "$(bosh_file_sha256 "$BOSH_STATE/$key")" == "$manifest_before" ]]
    shopt -s nullglob
    leftovers=( "$ANIME_DEST/$filename".bosh-rollback.* "$ANIME_DEST/$filename".bosh-restore.* )
    [[ "${#leftovers[@]}" -eq 0 ]]
    bosh_anime_txn_recover_all
done
CASE

test_case "Rollback helper restores explicit mode without exposing snapshot" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
for mode in 600 640 644; do
    previous="$HOME/original-$mode"
    destination="$HOME/active-$mode"
    printf 'ORIGINAL\n' > "$previous"
    printf 'NEW\n' > "$destination"
    chmod "$mode" "$previous"
    snapshot="$(mktemp "$HOME/active-$mode.bosh-rollback.XXXXXX")"
    cp -- "$previous" "$snapshot"
    [[ "$(stat -c '%a' "$snapshot")" == 600 ]]
    old_hash="$(bosh_file_sha256 "$previous")"
    new_hash="$(bosh_file_sha256 "$destination")"
    bosh_restore_rollback_file "$snapshot" "$destination" "$new_hash" "$old_hash" "$mode"
    [[ "$(cat "$destination")" == ORIGINAL ]]
    [[ "$(stat -c '%a' "$destination")" == "$mode" ]]
    [[ ! -e "$snapshot" ]]
done
CASE

test_case "Rollback helper rejects invalid requested mode without mutation" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
previous="$HOME/previous"
destination="$HOME/active"
printf 'ORIGINAL\n' > "$previous"
printf 'CURRENT\n' > "$destination"
snapshot="$(mktemp "$HOME/active.bosh-rollback.XXXXXX")"
cp -- "$previous" "$snapshot"
before="$(bosh_file_sha256 "$destination")"
if bosh_restore_rollback_file "$snapshot" "$destination" "$before" "$(bosh_file_sha256 "$previous")" 'u+x'; then
    echo 'ERROR: invalid restore mode accepted'
    exit 1
fi
[[ "$(bosh_file_sha256 "$destination")" == "$before" ]]
[[ -f "$snapshot" && "$(stat -c '%a' "$snapshot")" == 600 ]]
CASE

test_case "Rollback helper keeps staging private when publish fails" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
previous="$HOME/previous"
destination="$HOME/active"
printf 'ORIGINAL\n' > "$previous"
printf 'CURRENT\n' > "$destination"
snapshot="$(mktemp "$HOME/active.bosh-rollback.XXXXXX")"
cp -- "$previous" "$snapshot"
old_hash="$(bosh_file_sha256 "$previous")"
new_hash="$(bosh_file_sha256 "$destination")"
mv() {
    if [[ "${*: -1}" == "$destination" ]]; then
        [[ "$(stat -c '%a' -- "$3")" == 600 ]] || return 96
        return 97
    fi
    command mv "$@"
}
if bosh_restore_rollback_file "$snapshot" "$destination" "$new_hash" "$old_hash" 644; then
    echo 'ERROR: accepted failed restore rename'
    exit 1
fi
[[ "$(cat "$destination")" == CURRENT ]]
[[ -f "$snapshot" && "$(stat -c '%a' "$snapshot")" == 600 ]]
CASE


test_case "Anime journal: old 7-line format remains recoverable" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/assets"
ANIME_DEST="$HOME/images"
mkdir -p "$ANIME_SOURCE"
printf 'ORIGINAL\n' > "$ANIME_SOURCE/bosh1.png"
chmod 640 "$ANIME_SOURCE/bosh1.png"
install_anime_images
printf 'CANDIDATE\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
result=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/assets"
    ANIME_DEST="$HOME/images"
    mv() {
        if [[ "${*: -1}" == "$ANIME_DEST/bosh1.png" ]]; then exit 86; fi
        command mv "$@"
    }
    install_anime_images
' || result=$?
[[ "$result" -eq 86 ]]
journal="$BOSH_STATE/${key}_txn"
[[ "$(wc -l < "$journal")" -eq 8 ]]
# Remove only the last field to emulate a journal from the previous version.
sed -i '$d' "$journal"
[[ "$(wc -l < "$journal")" -eq 7 ]]
[[ "$(stat -c '%a' "$journal")" == 600 ]]
bosh_anime_txn_recover_all
[[ ! -e "$journal" ]]
[[ "$(cat "$ANIME_DEST/bosh1.png")" == ORIGINAL ]]
[[ "$(stat -c '%a' "$ANIME_DEST/bosh1.png")" == 640 ]]
CASE

test_case "Anime journal: SIGKILL between rename and chmod preserves original mode evidence" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/assets"
ANIME_DEST="$HOME/images"
mkdir -p "$ANIME_SOURCE"
printf 'ORIGINAL\n' > "$ANIME_SOURCE/bosh1.png"
chmod 644 "$ANIME_SOURCE/bosh1.png"
install_anime_images
printf 'CANDIDATE\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
result=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/assets"
    ANIME_DEST="$HOME/images"
    TEST_MANIFEST="$BOSH_STATE/$1"
    mv() {
        if [[ "${*: -1}" == "$TEST_MANIFEST" ]]; then return 86; fi
        command mv "$@"
    }
    chmod() {
        if [[ "${*: -1}" == "$ANIME_DEST/bosh1.png" ]]; then
            kill -KILL "$BASHPID"
        fi
        command chmod "$@"
    }
    install_anime_images
' _ "$key" || result=$?
[[ "$result" -eq 137 ]]
[[ "$(cat "$ANIME_DEST/bosh1.png")" == ORIGINAL ]]
[[ "$(stat -c '%a' "$ANIME_DEST/bosh1.png")" == 600 ]]
journal="$BOSH_STATE/${key}_txn"
[[ -f "$journal" ]]
grep -Fxq 'previous_mode=644' "$journal"
shopt -s nullglob
snapshots=( "$ANIME_DEST"/bosh1.png.bosh-rollback.* )
[[ "${#snapshots[@]}" -eq 1 ]]
[[ "$(stat -c '%a' "${snapshots[0]}")" == 600 ]]
if bosh_anime_txn_recover_all; then
    echo 'ERROR: uncertain original image mode silently reconciled'
    exit 1
fi
[[ -f "$journal" && -f "${snapshots[0]}" ]]
CASE

test_case "Anime journal: invalid original mode is rejected without modifying data" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/assets"
ANIME_DEST="$HOME/images"
mkdir -p "$ANIME_SOURCE"
printf 'ORIGINAL\n' > "$ANIME_SOURCE/bosh1.png"
chmod 640 "$ANIME_SOURCE/bosh1.png"
install_anime_images
printf 'CANDIDATE\n' > "$ANIME_SOURCE/bosh1.png"
name_hash="$(printf bosh1.png | sha256sum)"
key="anime_${name_hash%% *}"
result=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/assets"
    ANIME_DEST="$HOME/images"
    mv() {
        if [[ "${*: -1}" == "$ANIME_DEST/bosh1.png" ]]; then exit 86; fi
        command mv "$@"
    }
    install_anime_images
' || result=$?
[[ "$result" -eq 86 ]]
journal="$BOSH_STATE/${key}_txn"
sed -i 's/^previous_mode=640$/previous_mode=bad/' "$journal"
before="$(bosh_file_sha256 "$ANIME_DEST/bosh1.png")"
if bosh_anime_txn_recover_all; then
    echo 'ERROR: corrupted mode accepted'
    exit 1
fi
[[ "$(bosh_file_sha256 "$ANIME_DEST/bosh1.png")" == "$before" ]]
[[ -f "$journal" && "$(stat -c '%a' "$ANIME_DEST/bosh1.png")" == 640 ]]
CASE

test_summary
