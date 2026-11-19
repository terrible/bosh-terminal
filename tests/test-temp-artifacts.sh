#!/usr/bin/env bash
# Read-only temporary artifact audit tests; no user files are ever altered.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Temp audit: empty home has no findings" <<'CASE'
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")"
grep -Fq $'SUMMARY\treview=0\twarning=0\tunsafe=0' <<< "$output"
[[ ! -e "$HOME/.oh-my-zsh" ]]
CASE

test_case "Temp audit: private OMZ staging is flagged for manual review" <<'CASE'
tmpdir="$(mktemp -d "$HOME/.oh-my-zsh.bosh-tmp.XXXXXX")"
mkdir -p "$tmpdir/repo/.git"
printf 'sentinel\n' > "$tmpdir/repo/oh-my-zsh.sh"
before="$(sha256sum "$tmpdir/repo/oh-my-zsh.sh")"
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")"
grep -Fq $'REVIEW\tomz-stage\t' <<< "$output"
grep -Fq 'ownership-unproven' <<< "$output"
grep -Fq $'SUMMARY\treview=1\twarning=0\tunsafe=0' <<< "$output"
[[ "$(sha256sum "$tmpdir/repo/oh-my-zsh.sh")" == "$before" ]]
[[ "$(stat -c '%a' -- "$tmpdir")" == 700 ]]
CASE

test_case "Temp audit: private anime rollback reports SHA without changing it" <<'CASE'
dir="$HOME/.local/share/fastfetch/anime"
mkdir -p "$dir"
file="$(mktemp "$dir/bosh1.png.bosh-rollback.XXXXXX")"
printf 'private-image-snapshot\n' > "$file"
chmod 600 "$file"
before="$(sha256sum -- "$file")"
digest="${before%% *}"
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")"
grep -Fq $'REVIEW\tanime-rollback\t' <<< "$output"
grep -Fq "sha256=$digest" <<< "$output"
grep -Fq 'mode=600' <<< "$output"
grep -Fq $'SUMMARY\treview=1\twarning=0\tunsafe=0' <<< "$output"
[[ "$(sha256sum -- "$file")" == "$before" && "$(stat -c '%a' "$file")" == 600 ]]
CASE

test_case "Temp audit: tmp and restore files are reported, not deleted" <<'CASE'
dir="$HOME/.local/share/fastfetch/anime"
mkdir -p "$dir"
tmp="$(mktemp "$dir/bosh2.png.bosh-tmp.XXXXXX")"
restore="$(mktemp "$dir/bosh2.png.bosh-restore.XXXXXX")"
printf 'original A\n' > "$tmp"
printf 'original B\n' > "$restore"
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")"
grep -Fq $'REVIEW\tanime-tmp\t' <<< "$output"
grep -Fq $'REVIEW\tanime-restore\t' <<< "$output"
grep -Fq $'SUMMARY\treview=2\twarning=0\tunsafe=0' <<< "$output"
[[ "$(cat "$tmp")" == 'original A' && "$(cat "$restore")" == 'original B' ]]
CASE

test_case "Temp audit: group-readable snapshot is flagged without chmod" <<'CASE'
dir="$HOME/.local/share/fastfetch/anime"
mkdir -p "$dir"
file="$(mktemp "$dir/bosh1.png.bosh-rollback.XXXXXX")"
printf 'sensitive contents\n' > "$file"
chmod 644 "$file"
rc=0
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")" || rc=$?
[[ "$rc" == 2 ]]
grep -Fq $'WARNING\tanime-rollback\tgroup-or-world-access;mode=644' <<< "$output"
[[ "$(stat -c '%a' -- "$file")" == 644 ]]
[[ "$(cat "$file")" == 'sensitive contents' ]]
CASE

test_case "Temp audit: symbolic link is never followed or removed" <<'CASE'
dir="$HOME/.local/share/fastfetch/anime"
mkdir -p "$dir"
printf 'KEEP TARGET\n' > "$HOME/outside.txt"
link="$dir/bosh1.png.bosh-rollback.ABCDEF"
ln -s "$HOME/outside.txt" "$link"
rc=0
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")" || rc=$?
[[ "$rc" == 2 ]]
grep -Fq $'UNSAFE\tanime-rollback\t' <<< "$output"
[[ -L "$link" && "$(cat "$HOME/outside.txt")" == 'KEEP TARGET' ]]
CASE

test_case "Temp audit: hardlinked snapshot is flagged, both links preserved" <<'CASE'
dir="$HOME/.local/share/fastfetch/anime"
mkdir -p "$dir"
file="$(mktemp "$dir/bosh1.png.bosh-rollback.XXXXXX")"
printf 'SHARED\n' > "$file"
ln "$file" "$HOME/shared"
rc=0
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")" || rc=$?
[[ "$rc" == 2 ]]
grep -Fq $'UNSAFE\tanime-rollback\tunexpected-owner-or-hardlink' <<< "$output"
[[ "$(cat "$HOME/shared")" == SHARED && -f "$file" ]]
[[ "$(stat -c '%h' "$file")" == 2 ]]
CASE

test_case "Temp audit: malformed filename cannot be assumed disposable" <<'CASE'
dir="$HOME/.local/share/fastfetch/anime"
mkdir -p "$dir"
printf 'KEEP\n' > "$dir/bosh1.png.bosh-rollback.bad!"
rc=0
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")" || rc=$?
[[ "$rc" == 2 ]]
grep -Fq $'UNSAFE\tanime-stage\tunrecognized-name' <<< "$output"
[[ "$(cat "$dir/bosh1.png.bosh-rollback.bad!")" == KEEP ]]
CASE

test_case "Temp audit: OMZ symlink cannot redirect audit" <<'CASE'
mkdir -p "$HOME/important"
printf 'PRIVATE\n' > "$HOME/important/owned"
ln -s "$HOME/important" "$HOME/.oh-my-zsh.bosh-tmp.ABCDEF"
rc=0
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")" || rc=$?
[[ "$rc" == 2 ]]
grep -Fq $'UNSAFE\tomz-stage\tsymlink-or-nondirectory' <<< "$output"
[[ "$(cat "$HOME/important/owned")" == PRIVATE ]]
CASE

test_case "Temp audit: unexpected OMZ staging permissions are detected" <<'CASE'
dir="$(mktemp -d "$HOME/.oh-my-zsh.bosh-tmp.XXXXXX")"
chmod 755 "$dir"
rc=0
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")" || rc=$?
[[ "$rc" == 2 ]]
grep -Fq $'UNSAFE\tomz-stage\towner-or-mode-not-private' <<< "$output"
[[ -d "$dir" && "$(stat -c '%a' "$dir")" == 755 ]]
CASE

test_case "Temp audit: symlinked XDG ancestor is not traversed" <<'CASE'
mkdir -p "$HOME/external/fastfetch/anime"
printf 'SENTINEL\n' > "$HOME/external/fastfetch/anime/bosh1.png.bosh-rollback.ABCDEF"
ln -s "$HOME/external" "$HOME/symlink-data"
rc=0
output="$(XDG_DATA_HOME="$HOME/symlink-data" bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")" || rc=$?
[[ "$rc" == 2 ]]
grep -Fq $'UNSAFE\tanime-root\tunsafe-directory-components' <<< "$output"
[[ "$(cat "$HOME/external/fastfetch/anime/bosh1.png.bosh-rollback.ABCDEF")" == SENTINEL ]]
CASE

test_case "Temp audit: help offers no destructive mode" <<'CASE'
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh" --help)"
grep -Fq 'No artifact is ever automatically removed.' <<< "$output"
if bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh" --delete > "$HOME/invalid-arg" 2>&1; then
    echo 'ERROR: unsupported destructive action accepted'
    exit 1
fi
grep -Fq 'Unsupported arguments' "$HOME/invalid-arg"
CASE


test_case "Temp audit: SIGKILL during actual OMZ publication leaves a reviewable clone" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source "$BOSH_TEST_PROJECT/tests/omz-recovery-fixture.sh"
test_setup_omz_recovery_git
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
shopt -s nullglob
parents=( "$HOME"/.oh-my-zsh.bosh-tmp.* )
[[ "${#parents[@]}" == 1 && -d "${parents[0]}/repo" ]]
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")"
grep -Fq 'omz-stage' <<< "$output"
grep -Fq 'review=1' <<< "$output"
[[ -f "${parents[0]}/repo/oh-my-zsh.sh" ]]
[[ -f "$BOSH_STATE/oh_my_zsh_txn" ]]
CASE

test_case "Temp audit: interrupted anime update keeps 0600 rollback despite 0644 image" <<'CASE'
set -x
source "$BOSH_TEST_PROJECT/install.sh"
ANIME_SOURCE="$HOME/anime-source"
ANIME_DEST="$HOME/.local/share/fastfetch/anime"
mkdir -p "$ANIME_SOURCE"
printf 'ORIGINAL SNAPSHOT\n' > "$ANIME_SOURCE/bosh1.png"
chmod 644 "$ANIME_SOURCE/bosh1.png"
install_anime_images
printf 'UPDATED SNAPSHOT\n' > "$ANIME_SOURCE/bosh1.png"
status=0
bash --noprofile --norc -euo pipefail -c '
    source "$BOSH_TEST_PROJECT/install.sh"
    ANIME_SOURCE="$HOME/anime-source"
    ANIME_DEST="$HOME/.local/share/fastfetch/anime"
    mv() {
        if [[ "${*: -1}" == "$ANIME_DEST/bosh1.png" ]]; then exit 86; fi
        command mv "$@"
    }
    install_anime_images
' || status=$?
[[ "$status" -eq 86 ]]
shopt -s nullglob
rollbacks=( "$ANIME_DEST"/bosh1.png.bosh-rollback.* )
[[ "${#rollbacks[@]}" -eq 1 ]]
[[ "$(cat "${rollbacks[0]}")" == 'ORIGINAL SNAPSHOT' ]]
[[ "$(stat -c '%a' -- "${rollbacks[0]}")" == 600 ]]
status=0
output="$(bash "$BOSH_TEST_PROJECT/scripts/audit-temp-artifacts.sh")" || status=$?
[[ "$status" -eq 0 ]]
grep -Fq 
[[ -f "${rollbacks[0]}" ]]
[[ "$(cat "$ANIME_DEST/bosh1.png")" == 'ORIGINAL SNAPSHOT' ]]REVIEW\tanime-rollback\t' <<< "$output"
grep -Fq 'mode=600' <<< "$output"
[[ -f "${rollbacks[0]}" ]]
[[ "$(cat "$ANIME_DEST/bosh1.png")" == 'ORIGINAL SNAPSHOT' ]]
CASE

test_summary
