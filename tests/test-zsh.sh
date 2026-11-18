#!/usr/bin/env bash

set -uo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "C-1: alias externo y reinstalación" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

integrate_zsh

read_manifest zshrc
manifest_before="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
manifest_before="${manifest_before%% *}"

printf '\nalias ll="ls -lah"\n' >> "$HOME/.zshrc"

before="$(sha256sum "$HOME/.zshrc")"
before="${before%% *}"

output="$(integrate_zsh 2>&1)"
printf '%s\n' "$output"

after="$(sha256sum "$HOME/.zshrc")"
after="${after%% *}"

[[ "$before" == "$after" ]]
grep -Fqx 'alias ll="ls -lah"' "$HOME/.zshrc"
grep -Fq 'block integrity verified' <<< "$output"

manifest_after="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
manifest_after="${manifest_after%% *}"

[[ "$manifest_before" == "$manifest_after" ]]
[[ "${BOSH_MANIFEST[block_sha256]:-}" =~ ^[a-f0-9]{64}$ ]]

echo "Alias, bloque y manifiesto preservados."
CASE

test_case "C-1: bloque modificado con manifiesto" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

integrate_zsh

manifest_before="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
manifest_before="${manifest_before%% *}"

sed -i \
    '/^source /s/$/ # modified-by-test/' \
    "$HOME/.zshrc"

grep -Fq 'modified-by-test' "$HOME/.zshrc"

before="$(sha256sum "$HOME/.zshrc")"
before="${before%% *}"

output="$(integrate_zsh 2>&1)"
printf '%s\n' "$output"

after="$(sha256sum "$HOME/.zshrc")"
after="${after%% *}"

[[ "$before" == "$after" ]]
grep -Fq 'was edited; leaving it untouched' <<< "$output"

manifest_after="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
manifest_after="${manifest_after%% *}"

[[ "$manifest_before" == "$manifest_after" ]]

echo "Modificación detectada y preservada."
CASE

test_case "C-1: bloque modificado sin manifiesto" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

integrate_zsh
rm -- "$BOSH_STATE/zshrc_manifest"

sed -i \
    '/^source /s/$/ # modified-without-manifest/' \
    "$HOME/.zshrc"

before="$(sha256sum "$HOME/.zshrc")"
before="${before%% *}"

output="$(integrate_zsh 2>&1)"
printf '%s\n' "$output"

after="$(sha256sum "$HOME/.zshrc")"
after="${after%% *}"

[[ "$before" == "$after" ]]
grep -Fq 'was edited; leaving it untouched' <<< "$output"
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]

echo "Bloque modificado preservado; manifiesto no recreado."
CASE

test_case "C-1: bloque intacto sin manifiesto" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

integrate_zsh
rm -- "$BOSH_STATE/zshrc_manifest"

before="$(sha256sum "$HOME/.zshrc")"
before="${before%% *}"

output="$(integrate_zsh 2>&1)"
printf '%s\n' "$output"

after="$(sha256sum "$HOME/.zshrc")"
after="${after%% *}"

[[ "$before" == "$after" ]]
grep -Fq 'content verified; no manifest exists' <<< "$output"
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]

echo "Bloque intacto verificado sin crear manifiesto."
CASE

test_case "C-1: migración de manifiesto versionado y respaldo" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

printf '%s\n' \
    '# User-owned configuration' \
    'alias ll="ls -lah"' > "$HOME/.zshrc"

original_hash="$(sha256sum "$HOME/.zshrc")"
original_hash="${original_hash%% *}"

integrate_zsh
read_manifest zshrc

backup_b64="${BOSH_MANIFEST[backup_path_b64]}"
backup_hash="${BOSH_MANIFEST[backup_sha256]}"

decoded=()
mapfile -d '' -t decoded < <(
    printf '%s' "$backup_b64" | base64 --decode
)
[[ "${#decoded[@]}" -eq 1 ]]
backup_path="${decoded[0]}"

[[ -f "$backup_path" && ! -L "$backup_path" ]]

actual_backup_hash="$(sha256sum "$backup_path")"
actual_backup_hash="${actual_backup_hash%% *}"
[[ "$actual_backup_hash" == "$original_hash" ]]
[[ "$actual_backup_hash" == "$backup_hash" ]]

installed_hash="$(sha256sum "$HOME/.zshrc")"
installed_hash="${installed_hash%% *}"

write_manifest zshrc zsh_integration \
    mode appended \
    sha256 "$installed_hash" \
    backup_path_b64 "$backup_b64" \
    backup_sha256 "$backup_hash"

printf '\nalias gs="git status"\n' >> "$HOME/.zshrc"

before="$(sha256sum "$HOME/.zshrc")"
before="${before%% *}"

output="$(integrate_zsh 2>&1)"
printf '%s\n' "$output"

after="$(sha256sum "$HOME/.zshrc")"
after="${after%% *}"

[[ "$before" == "$after" ]]
grep -Fqx 'alias gs="git status"' "$HOME/.zshrc"

read_manifest zshrc

[[ "${BOSH_MANIFEST[block_sha256]:-}" =~ ^[a-f0-9]{64}$ ]]
[[ -z "${BOSH_MANIFEST[sha256]+present}" ]]
[[ "${BOSH_MANIFEST[mode]}" == "appended" ]]
[[ "${BOSH_MANIFEST[backup_path_b64]}" == "$backup_b64" ]]
[[ "${BOSH_MANIFEST[backup_sha256]}" == "$backup_hash" ]]

echo "Manifiesto versionado migrado; respaldo y SHA-256 conservados."
CASE

test_case "C-1: migración de manifiesto posicional y respaldo" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

printf '%s\n' \
    '# User-owned configuration' \
    'alias ll="ls -lah"' > "$HOME/.zshrc"

original_hash="$(sha256sum "$HOME/.zshrc")"
original_hash="${original_hash%% *}"

integrate_zsh
read_manifest zshrc

backup_b64="${BOSH_MANIFEST[backup_path_b64]}"
backup_hash="${BOSH_MANIFEST[backup_sha256]}"

decoded=()
mapfile -d '' -t decoded < <(
    printf '%s' "$backup_b64" | base64 --decode
)
[[ "${#decoded[@]}" -eq 1 ]]
backup_path="${decoded[0]}"

actual_backup_hash="$(sha256sum "$backup_path")"
actual_backup_hash="${actual_backup_hash%% *}"

[[ "$actual_backup_hash" == "$original_hash" ]]
[[ "$actual_backup_hash" == "$backup_hash" ]]

installed_hash="$(sha256sum "$HOME/.zshrc")"
installed_hash="${installed_hash%% *}"

printf '%s\n' \
    appended \
    "$installed_hash" \
    "$backup_path" \
    "$backup_hash" > "$BOSH_STATE/zshrc_manifest"

printf '\nalias gs="git status"\n' >> "$HOME/.zshrc"

before="$(sha256sum "$HOME/.zshrc")"
before="${before%% *}"

output="$(integrate_zsh 2>&1)"
printf '%s\n' "$output"

after="$(sha256sum "$HOME/.zshrc")"
after="${after%% *}"

[[ "$before" == "$after" ]]
grep -Fqx 'alias gs="git status"' "$HOME/.zshrc"

read_manifest zshrc

[[ "${BOSH_MANIFEST[block_sha256]:-}" =~ ^[a-f0-9]{64}$ ]]
[[ -z "${BOSH_MANIFEST[sha256]+present}" ]]
[[ "${BOSH_MANIFEST[mode]}" == "appended" ]]
[[ "${BOSH_MANIFEST[backup_path_b64]}" == "$backup_b64" ]]
[[ "${BOSH_MANIFEST[backup_sha256]}" == "$backup_hash" ]]

final_hash="$(sha256sum "$backup_path")"
final_hash="${final_hash%% *}"
[[ "$final_hash" == "$original_hash" ]]

echo "Manifiesto posicional migrado; respaldo y SHA-256 conservados."
CASE


test_case "C-3: eliminar bloque y recuperar manifiesto huérfano" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

echo "=== CONFIGURACIÓN PERSONAL E INTEGRACIÓN ==="

printf "%s\n" \
    "# User configuration" \
    'alias ll="ls -lah"' > "$HOME/.zshrc"

original_hash="$(sha256sum "$HOME/.zshrc")"
original_hash="${original_hash%% *}"

integrate_zsh
read_manifest zshrc

old_manifest_hash="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
old_manifest_hash="${old_manifest_hash%% *}"

old_backup_b64="${BOSH_MANIFEST[backup_path_b64]}"
old_backup_hash="${BOSH_MANIFEST[backup_sha256]}"

decoded=()
mapfile -d '' -t decoded < <(
    printf '%s' "$old_backup_b64" | base64 --decode
)

[[ "${#decoded[@]}" -eq 1 ]]
old_backup="${decoded[0]}"

[[ -f "$old_backup" && ! -L "$old_backup" ]]

actual_old_hash="$(sha256sum "$old_backup")"
actual_old_hash="${actual_old_hash%% *}"

[[ "$actual_old_hash" == "$original_hash" ]]
[[ "$actual_old_hash" == "$old_backup_hash" ]]

echo "Respaldo histórico inicial verificado."

echo ""
echo "=== ELIMINAR BLOQUE BOSH ==="

awk '
    $0 == "# >>> Bosh Terminal >>>" {
        inside=1
        next
    }
    $0 == "# <<< Bosh Terminal <<<" {
        inside=0
        next
    }
    !inside {
        print
    }
' "$HOME/.zshrc" > "$HOME/.zshrc.test"

mv -- "$HOME/.zshrc.test" "$HOME/.zshrc"

printf '\nalias gs="git status"\n' >> "$HOME/.zshrc"

! grep -Fq "# >>> Bosh Terminal >>>" "$HOME/.zshrc"
grep -Fqx 'alias ll="ls -lah"' "$HOME/.zshrc"
grep -Fqx 'alias gs="git status"' "$HOME/.zshrc"

personal_hash="$(sha256sum "$HOME/.zshrc")"
personal_hash="${personal_hash%% *}"

echo "Configuración personal conservada."

echo ""
echo "=== REINTEGRACIÓN Y ARCHIVADO ==="

output="$(integrate_zsh 2>&1)"
printf '%s\n' "$output"

grep -Fq 'Found an orphaned Zsh integration state record' <<< "$output"
grep -Fq 'State record archived and verified' <<< "$output"

shopt -s nullglob
archives=("$BOSH_STATE"/zshrc_manifest.archived-*)

[[ "${#archives[@]}" -eq 1 ]]
archived_manifest="${archives[0]}"

archived_hash="$(sha256sum "$archived_manifest")"
archived_hash="${archived_hash%% *}"

[[ "$archived_hash" == "$old_manifest_hash" ]]
grep -Fxq "backup_path_b64=$old_backup_b64" "$archived_manifest"
grep -Fxq "backup_sha256=$old_backup_hash" "$archived_manifest"

echo "Manifiesto anterior archivado y verificado."

echo ""
echo "=== RESPALDO HISTÓRICO ==="

[[ -f "$old_backup" && ! -L "$old_backup" ]]

final_old_hash="$(sha256sum "$old_backup")"
final_old_hash="${final_old_hash%% *}"

[[ "$final_old_hash" == "$original_hash" ]]

echo "Respaldo histórico conservado."

echo ""
echo "=== NUEVA INTEGRACIÓN ==="

read_manifest zshrc

[[ "${BOSH_MANIFEST[component]}" == "zsh_integration" ]]
[[ "${BOSH_MANIFEST[mode]}" == "appended" ]]
[[ "${BOSH_MANIFEST[block_sha256]}" =~ ^[a-f0-9]{64}$ ]]

new_backup_b64="${BOSH_MANIFEST[backup_path_b64]}"

decoded=()
mapfile -d '' -t decoded < <(
    printf '%s' "$new_backup_b64" | base64 --decode
)

[[ "${#decoded[@]}" -eq 1 ]]
new_backup="${decoded[0]}"

[[ -f "$new_backup" && ! -L "$new_backup" ]]
[[ "$new_backup" != "$old_backup" ]]

new_backup_hash="$(sha256sum "$new_backup")"
new_backup_hash="${new_backup_hash%% *}"

[[ "$new_backup_hash" == "$personal_hash" ]]
[[ "$new_backup_hash" == "${BOSH_MANIFEST[backup_sha256]}" ]]

[[ "$(grep -Fxc "# >>> Bosh Terminal >>>" "$HOME/.zshrc")" == "1" ]]
[[ "$(grep -Fxc "# <<< Bosh Terminal <<<" "$HOME/.zshrc")" == "1" ]]

grep -Fqx 'alias ll="ls -lah"' "$HOME/.zshrc"
grep -Fqx 'alias gs="git status"' "$HOME/.zshrc"

echo "Nuevo manifiesto y respaldo verificados."
echo "Configuración personal y bloque Bosh conservados."
CASE


test_summary
