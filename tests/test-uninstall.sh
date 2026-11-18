#!/usr/bin/env bash

set -uo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "O-5: archivo gestionado restaura permisos originales 644" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

mkdir -p "$BOSH_HOME"
printf 'configuración original del usuario\n' > "$BOSH_HOME/starship.toml"
chmod 644 "$BOSH_HOME/starship.toml"

install_managed_file \
    "$STARSHIP_CONFIG" "$BOSH_HOME/starship.toml" starship

read_manifest starship
[[ "${#BOSH_MANIFEST[@]}" -eq 8 ]]
[[ "${BOSH_MANIFEST[original_mode]}" == "644" ]]

backup_path="$(
    printf '%s' "${BOSH_MANIFEST[backup_path_b64]}" | base64 --decode
)"
[[ "$(stat -c '%a' "$backup_path")" == "600" ]]

bosh_uninstall_process_managed_file starship

[[ "$(cat "$BOSH_HOME/starship.toml")" == "configuración original del usuario" ]]
[[ "$(stat -c '%a' "$BOSH_HOME/starship.toml")" == "644" ]]
[[ ! -e "$BOSH_STATE/starship_manifest" ]]
[[ "$BOSH_UNINSTALL_RESTORED" -eq 1 ]]

echo "Archivo y permisos originales 644 restaurados."
CASE

test_case "O-5: manifiesto managed antiguo de 7 campos compatible" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

mkdir -p "$BOSH_HOME"
printf 'contenido anterior\n' > "$BOSH_HOME/starship.toml"
chmod 644 "$BOSH_HOME/starship.toml"

install_managed_file \
    "$STARSHIP_CONFIG" "$BOSH_HOME/starship.toml" starship

read_manifest starship

installed_hash="${BOSH_MANIFEST[sha256]}"
destination_b64="${BOSH_MANIFEST[destination_b64]}"
backup_path_b64="${BOSH_MANIFEST[backup_path_b64]}"
backup_sha256="${BOSH_MANIFEST[backup_sha256]}"

write_manifest starship managed_file \
    sha256 "$installed_hash" \
    preexisting "1" \
    destination_b64 "$destination_b64" \
    backup_path_b64 "$backup_path_b64" \
    backup_sha256 "$backup_sha256"

read_manifest starship
[[ "${#BOSH_MANIFEST[@]}" -eq 7 ]]

bosh_uninstall_process_managed_file starship

[[ "$(cat "$BOSH_HOME/starship.toml")" == "contenido anterior" ]]
[[ "$(stat -c '%a' "$BOSH_HOME/starship.toml")" == "600" ]]
[[ "$BOSH_UNINSTALL_RESTORED" -eq 1 ]]

echo "Esquema antiguo aceptado; no se inventaron permisos originales."
CASE

test_case "O-5: modo managed inválido rechazado sin modificar archivos" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

mkdir -p "$BOSH_HOME"
printf 'contenido anterior\n' > "$BOSH_HOME/starship.toml"
chmod 644 "$BOSH_HOME/starship.toml"

install_managed_file \
    "$STARSHIP_CONFIG" "$BOSH_HOME/starship.toml" starship

read_manifest starship

installed_hash="${BOSH_MANIFEST[sha256]}"
destination_b64="${BOSH_MANIFEST[destination_b64]}"
backup_path_b64="${BOSH_MANIFEST[backup_path_b64]}"
backup_sha256="${BOSH_MANIFEST[backup_sha256]}"

write_manifest starship managed_file \
    sha256 "$installed_hash" \
    preexisting "1" \
    destination_b64 "$destination_b64" \
    backup_path_b64 "$backup_path_b64" \
    backup_sha256 "$backup_sha256" \
    original_mode "0648"

manifest_before="$(sha256sum "$BOSH_STATE/starship_manifest")"
manifest_before="${manifest_before%% *}"
file_before="$(sha256sum "$BOSH_HOME/starship.toml")"
file_before="${file_before%% *}"

if bosh_uninstall_process_managed_file starship; then
    echo "ERROR: se aceptó un modo original inválido."
    false
fi

manifest_after="$(sha256sum "$BOSH_STATE/starship_manifest")"
manifest_after="${manifest_after%% *}"
file_after="$(sha256sum "$BOSH_HOME/starship.toml")"
file_after="${file_after%% *}"

[[ "$manifest_before" == "$manifest_after" ]]
[[ "$file_before" == "$file_after" ]]
[[ "$(stat -c '%a' "$BOSH_HOME/starship.toml")" == "644" ]]
[[ "$BOSH_UNINSTALL_ERRORS" -eq 1 ]]
[[ "$BOSH_UNINSTALL_PRESERVED" -eq 1 ]]

echo "Metadatos inválidos rechazados; archivo y manifiesto preservados."
CASE

test_case "O-5: Zsh legacy_replaced restaura permisos originales 644" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

printf '# Bosh Terminal - Zsh legacy\nalias usuario="preservar"\n' > "$HOME/.zshrc"
chmod 644 "$HOME/.zshrc"

confirm() {
    return 0
}

integrate_zsh

read_manifest zshrc
[[ "${#BOSH_MANIFEST[@]}" -eq 7 ]]
[[ "${BOSH_MANIFEST[mode]}" == "legacy_replaced" ]]
[[ "${BOSH_MANIFEST[original_mode]}" == "644" ]]

backup_path="$(
    printf '%s' "${BOSH_MANIFEST[backup_path_b64]}" | base64 --decode
)"
[[ "$(stat -c '%a' "$backup_path")" == "600" ]]

bosh_uninstall_process_zsh

grep -Fqx '# Bosh Terminal - Zsh legacy' "$HOME/.zshrc"
grep -Fqx 'alias usuario="preservar"' "$HOME/.zshrc"
[[ "$(stat -c '%a' "$HOME/.zshrc")" == "644" ]]
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]
[[ "$BOSH_UNINSTALL_RESTORED" -eq 1 ]]

echo ".zshrc original y permisos 644 restaurados."
CASE

test_case "O-5: manifiesto Zsh antiguo de 6 campos compatible" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

printf '# Bosh Terminal - Zsh legacy\nalias usuario="preservar"\n' > "$HOME/.zshrc"
chmod 644 "$HOME/.zshrc"

confirm() {
    return 0
}

integrate_zsh

read_manifest zshrc

mode="${BOSH_MANIFEST[mode]}"
block_sha256="${BOSH_MANIFEST[block_sha256]}"
backup_path_b64="${BOSH_MANIFEST[backup_path_b64]}"
backup_sha256="${BOSH_MANIFEST[backup_sha256]}"

write_manifest zshrc zsh_integration \
    mode "$mode" \
    block_sha256 "$block_sha256" \
    backup_path_b64 "$backup_path_b64" \
    backup_sha256 "$backup_sha256"

read_manifest zshrc
[[ "${#BOSH_MANIFEST[@]}" -eq 6 ]]

bosh_uninstall_process_zsh

grep -Fqx '# Bosh Terminal - Zsh legacy' "$HOME/.zshrc"
grep -Fqx 'alias usuario="preservar"' "$HOME/.zshrc"
[[ "$(stat -c '%a' "$HOME/.zshrc")" == "600" ]]
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]
[[ "$BOSH_UNINSTALL_RESTORED" -eq 1 ]]

echo "Esquema Zsh antiguo aceptado sin inventar permisos."
CASE

test_case "O-5: modo Zsh inválido rechazado y configuración preservada" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

printf '# Bosh Terminal - Zsh legacy\nalias usuario="preservar"\n' > "$HOME/.zshrc"
chmod 644 "$HOME/.zshrc"

confirm() {
    return 0
}

integrate_zsh

read_manifest zshrc

mode="${BOSH_MANIFEST[mode]}"
block_sha256="${BOSH_MANIFEST[block_sha256]}"
backup_path_b64="${BOSH_MANIFEST[backup_path_b64]}"
backup_sha256="${BOSH_MANIFEST[backup_sha256]}"

write_manifest zshrc zsh_integration \
    mode "$mode" \
    block_sha256 "$block_sha256" \
    backup_path_b64 "$backup_path_b64" \
    backup_sha256 "$backup_sha256" \
    original_mode "0648"

manifest_before="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
manifest_before="${manifest_before%% *}"
file_before="$(sha256sum "$HOME/.zshrc")"
file_before="${file_before%% *}"

bosh_uninstall_process_zsh

manifest_after="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
manifest_after="${manifest_after%% *}"
file_after="$(sha256sum "$HOME/.zshrc")"
file_after="${file_after%% *}"

[[ "$manifest_before" == "$manifest_after" ]]
[[ "$file_before" == "$file_after" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == "644" ]]
[[ "$BOSH_UNINSTALL_PRESERVED" -eq 1 ]]
[[ "$BOSH_UNINSTALL_RESTORED" -eq 0 ]]

echo "Metadatos Zsh inválidos rechazados; configuración preservada."
CASE



test_case "O-1: imagen anime gestionada e intacta eliminada" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

filename="bosh-test.png"
printf 'image content owned by Bosh\n' > "$ANIME_SOURCE/$filename"
cp -p "$ANIME_SOURCE/$filename" "$ANIME_DEST/$filename"

name_hash="$(printf '%s' "$filename" | sha256sum)"
name_hash="${name_hash%% *}"
state_key="anime_$name_hash"
filename_b64="$(printf '%s' "$filename" | base64 -w 0)"
file_hash="$(bosh_uninstall_hash "$ANIME_DEST/$filename")"

printf -v manifest '%s\n%s\n%s\n%s' \
    "version=1" \
    "component=anime_image" \
    "filename_b64=$filename_b64" \
    "sha256=$file_hash"

write_state "$state_key" "$manifest"

bosh_uninstall_process_anime

[[ ! -e "$ANIME_DEST/$filename" ]]
[[ ! -e "$BOSH_STATE/$state_key" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 1 ]]

shopt -s nullglob
archives=("$BOSH_STATE/${state_key}.archived-"*)
[[ "${#archives[@]}" -eq 1 ]]

echo "Imagen intacta eliminada y manifiesto archivado."
CASE

test_case "O-1: imagen anime modificada y manifiesto preservados" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

filename="customized.png"
printf 'original image\n' > "$ANIME_SOURCE/$filename"
cp -p "$ANIME_SOURCE/$filename" "$ANIME_DEST/$filename"

name_hash="$(printf '%s' "$filename" | sha256sum)"
name_hash="${name_hash%% *}"
state_key="anime_$name_hash"
filename_b64="$(printf '%s' "$filename" | base64 -w 0)"
file_hash="$(bosh_uninstall_hash "$ANIME_DEST/$filename")"

printf -v manifest '%s\n%s\n%s\n%s' \
    "version=1" \
    "component=anime_image" \
    "filename_b64=$filename_b64" \
    "sha256=$file_hash"
write_state "$state_key" "$manifest"

printf 'user customization\n' >> "$ANIME_DEST/$filename"
file_before="$(bosh_uninstall_hash "$ANIME_DEST/$filename")"
manifest_before="$(bosh_uninstall_hash "$BOSH_STATE/$state_key")"

bosh_uninstall_process_anime

[[ -f "$ANIME_DEST/$filename" ]]
[[ "$(bosh_uninstall_hash "$ANIME_DEST/$filename")" == "$file_before" ]]
[[ "$(bosh_uninstall_hash "$BOSH_STATE/$state_key")" == "$manifest_before" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 0 ]]
[[ "$BOSH_UNINSTALL_PRESERVED" -eq 1 ]]

echo "Personalización y manifiesto preservados."
CASE

test_case "O-1: imagen preexistente sin propiedad preservada" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

printf 'personal image\n' > "$ANIME_DEST/personal.png"
before="$(bosh_uninstall_hash "$ANIME_DEST/personal.png")"

bosh_uninstall_process_anime

[[ -f "$ANIME_DEST/personal.png" ]]
[[ "$(bosh_uninstall_hash "$ANIME_DEST/personal.png")" == "$before" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 0 ]]

echo "Imagen sin manifiesto de propiedad preservada."
CASE

test_case "O-1: symlink en destino anime preservado" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

filename="linked.png"
printf 'source image\n' > "$ANIME_SOURCE/$filename"
printf 'external target\n' > "$HOME/external-image"
ln -s "$HOME/external-image" "$ANIME_DEST/$filename"

name_hash="$(printf '%s' "$filename" | sha256sum)"
name_hash="${name_hash%% *}"
state_key="anime_$name_hash"
filename_b64="$(printf '%s' "$filename" | base64 -w 0)"
target_hash="$(bosh_uninstall_hash "$HOME/external-image")"

printf -v manifest '%s\n%s\n%s\n%s' \
    "version=1" \
    "component=anime_image" \
    "filename_b64=$filename_b64" \
    "sha256=$target_hash"
write_state "$state_key" "$manifest"

bosh_uninstall_process_anime

[[ -L "$ANIME_DEST/$filename" ]]
[[ "$(cat "$HOME/external-image")" == "external target" ]]
[[ -f "$BOSH_STATE/$state_key" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 0 ]]

echo "Symlink, destino externo y manifiesto preservados."
CASE

test_case "O-1: filename manipulado en manifiesto anime rechazado" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

filename="../outside.png"
name_hash="$(printf '%s' "$filename" | sha256sum)"
name_hash="${name_hash%% *}"
state_key="anime_$name_hash"
filename_b64="$(printf '%s' "$filename" | base64 -w 0)"
printf 'outside content\n' > "$HOME/outside.png"
outside_before="$(bosh_uninstall_hash "$HOME/outside.png")"

printf -v manifest '%s\n%s\n%s\n%s' \
    "version=1" \
    "component=anime_image" \
    "filename_b64=$filename_b64" \
    "sha256=$outside_before"
write_state "$state_key" "$manifest"

bosh_uninstall_process_anime

[[ -f "$HOME/outside.png" ]]
[[ "$(bosh_uninstall_hash "$HOME/outside.png")" == "$outside_before" ]]
[[ -f "$BOSH_STATE/$state_key" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 0 ]]

echo "Ruta manipulada rechazada; archivo externo intacto."
CASE

test_case "O-1: componente padre simbólico en ruta anime rechazado" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
mkdir -p "$ANIME_SOURCE" "$HOME/real/anime"
ln -s "$HOME/real" "$HOME/linked"
ANIME_DEST="$HOME/linked/anime"

filename="path-guard.png"
printf 'source image\n' > "$ANIME_SOURCE/$filename"
printf 'managed image\n' > "$HOME/real/anime/$filename"

name_hash="$(printf '%s' "$filename" | sha256sum)"
name_hash="${name_hash%% *}"
state_key="anime_$name_hash"
filename_b64="$(printf '%s' "$filename" | base64 -w 0)"
file_hash="$(bosh_uninstall_hash "$HOME/real/anime/$filename")"

printf -v manifest '%s\n%s\n%s\n%s' \
    "version=1" \
    "component=anime_image" \
    "filename_b64=$filename_b64" \
    "sha256=$file_hash"
write_state "$state_key" "$manifest"

bosh_uninstall_process_anime

[[ -f "$HOME/real/anime/$filename" ]]
[[ -f "$BOSH_STATE/$state_key" ]]
[[ -L "$HOME/linked" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 0 ]]

echo "Ruta con componente simbólico rechazada y contenido preservado."
CASE

test_case "O-1: manifiesto anime legado con SHA-256 compatible" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

filename="legacy.png"
printf 'legacy image content\n' > "$ANIME_SOURCE/$filename"
cp -p "$ANIME_SOURCE/$filename" "$ANIME_DEST/$filename"

legacy_key="anime_${filename//./_}"
legacy_hash="$(bosh_uninstall_hash "$ANIME_DEST/$filename")"
write_state "$legacy_key" "$legacy_hash"

bosh_uninstall_process_anime

[[ ! -e "$ANIME_DEST/$filename" ]]
[[ ! -e "$BOSH_STATE/$legacy_key" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 1 ]]

shopt -s nullglob
archives=("$BOSH_STATE/${legacy_key}.archived-"*)
[[ "${#archives[@]}" -eq 1 ]]

echo "Formato legado con hash verificado y eliminado."
CASE

test_case "O-1: manifiesto anime legado booleano compatible" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

filename="legacy-boolean.png"
printf 'legacy boolean image\n' > "$ANIME_SOURCE/$filename"
cp -p "$ANIME_SOURCE/$filename" "$ANIME_DEST/$filename"

legacy_key="anime_${filename//./_}"
write_state "$legacy_key" "1"

bosh_uninstall_process_anime

[[ ! -e "$ANIME_DEST/$filename" ]]
[[ ! -e "$BOSH_STATE/$legacy_key" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 1 ]]

echo "Formato legado booleano aceptado tras comparación exacta."
CASE

test_case "O-1: clave anime legada ambigua preservada" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

printf 'first source\n' > "$ANIME_SOURCE/a.b_c.png"
printf 'second source\n' > "$ANIME_SOURCE/a_b.c.png"
printf 'installed image\n' > "$ANIME_DEST/a.b_c.png"

legacy_key="anime_a_b_c_png"
write_state "$legacy_key" "1"

before="$(bosh_uninstall_hash "$ANIME_DEST/a.b_c.png")"

bosh_uninstall_process_anime

[[ -f "$ANIME_DEST/a.b_c.png" ]]
[[ "$(bosh_uninstall_hash "$ANIME_DEST/a.b_c.png")" == "$before" ]]
[[ -f "$BOSH_STATE/$legacy_key" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 0 ]]
[[ "$BOSH_UNINSTALL_PRESERVED" -eq 1 ]]

echo "Clave legada ambigua preservada sin borrar archivos."
CASE

test_case "O-1: rama appended de Zsh conserva contenido y modo" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

printf 'alias personal="echo conservar"\n' > "$HOME/.zshrc"
chmod 640 "$HOME/.zshrc"
original_hash="$(bosh_uninstall_hash "$HOME/.zshrc")"

integrate_zsh
read_manifest zshrc
[[ "${BOSH_MANIFEST[mode]}" == "appended" ]]

bosh_uninstall_process_zsh

[[ -f "$HOME/.zshrc" ]]
grep -Fqx 'alias personal="echo conservar"' "$HOME/.zshrc"
! grep -Fq '# >>> Bosh Terminal >>>' "$HOME/.zshrc"
[[ "$(stat -c '%a' "$HOME/.zshrc")" == "640" ]]
[[ "$(bosh_uninstall_hash "$HOME/.zshrc")" == "$original_hash" ]]
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]

echo "Bloque retirado; contenido y modo originales conservados."
CASE



test_case "O-1: roundtrip completo con personalizaciones y recursos preservados" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

TEST_OMZ_REMOTE="https://github.com/ohmyzsh/ohmyzsh.git"
TEST_REAL_GIT="$(command -v git)"
TEST_OMZ_SOURCE="$HOME/omz-source"
TEST_GIT_BIN="$HOME/test-bin"
export TEST_OMZ_REMOTE TEST_REAL_GIT TEST_OMZ_SOURCE

mkdir -p "$TEST_OMZ_SOURCE/plugins/example" "$TEST_GIT_BIN"
printf '%s\n' '# Test entry point' > "$TEST_OMZ_SOURCE/oh-my-zsh.sh"
printf '%s\n' '# Test plugin' > "$TEST_OMZ_SOURCE/plugins/example/example.plugin.zsh"

"$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" init -q
"$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" config user.name "Bosh Test"
"$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" config user.email "bosh-test@example.invalid"
"$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" add .
"$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" commit -qm "Initial test commit"

cat > "$TEST_GIT_BIN/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == clone && "${2:-}" == --depth &&
      "${3:-}" == 1 && "${4:-}" == "$TEST_OMZ_REMOTE" ]]; then
    "$TEST_REAL_GIT" clone --depth 1 "$TEST_OMZ_SOURCE" "${5:?}"
    "$TEST_REAL_GIT" -C "$5" remote set-url origin "$TEST_OMZ_REMOTE"
    exit
fi
exec "$TEST_REAL_GIT" "$@"
GIT
chmod 700 "$TEST_GIT_BIN/git"
PATH="$TEST_GIT_BIN:$PATH"
export PATH

package_installed() {
    return 0
}

printf 'alias personal="echo roundtrip"\n' > "$HOME/.zshrc"
chmod 640 "$HOME/.zshrc"
zshrc_before="$(bosh_file_sha256 "$HOME/.zshrc")"

echo "=== INSTALACIÓN AISLADA ==="
main

[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]
[[ -f "$BOSH_STATE/oh_my_zsh_manifest" ]]
[[ -f "$BOSH_HOME/zshrc" ]]
[[ -f "$BOSH_HOME/starship.toml" ]]
[[ -f "$BOSH_HOME/fastfetch.jsonc" ]]
[[ -f "$KONSOLE_DIR/bosh.profile" ]]
[[ -f "$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme" ]]

images=("$ANIME_DEST"/*.png)
[[ "${#images[@]}" -eq 5 ]]

# Simulate personal modifications after installation.
printf '\n# User customization\n' >> "$BOSH_HOME/starship.toml"
printf '\n# User customization\n' >> "$KONSOLE_DIR/bosh.profile"
printf '\n# User image customization\n' >> "$ANIME_DEST/bosh1.png"
printf '\n# User plugin customization\n' >> "$HOME/.oh-my-zsh/plugins/example/example.plugin.zsh"

starship_hash="$(bosh_file_sha256 "$BOSH_HOME/starship.toml")"
profile_hash="$(bosh_file_sha256 "$KONSOLE_DIR/bosh.profile")"
anime1_hash="$(bosh_file_sha256 "$ANIME_DEST/bosh1.png")"
omz_plugin_hash="$(bosh_file_sha256 "$HOME/.oh-my-zsh/plugins/example/example.plugin.zsh")"

name_hash="$(printf '%s' 'bosh1.png' | sha256sum)"
name_hash="${name_hash%% *}"
anime1_state_key="anime_$name_hash"

write_state package_starship "1"
[[ -f "$BOSH_STATE/package_starship" ]]

# The installer EXIT trap owns the lock. Release it before invoking
# the separately sourced uninstaller in this same isolated process.
trap - EXIT HUP INT TERM
if [[ -n "$BOSH_LOCK_FD" ]]; then
    flock -u "$BOSH_LOCK_FD"
    exec {BOSH_LOCK_FD}>&-
    BOSH_LOCK_FD=""
fi

echo "=== DESINSTALACIÓN AISLADA ==="
source "$BOSH_TEST_PROJECT/uninstall.sh"
main

echo "=== VERIFICACIÓN DE RECURSOS ==="

# Unmodified managed files are removed.
[[ ! -e "$BOSH_HOME/zshrc" ]]
[[ ! -e "$BOSH_HOME/fastfetch.jsonc" ]]
[[ ! -e "$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme" ]]

# User-modified managed files remain unchanged.
[[ -f "$BOSH_HOME/starship.toml" ]]
[[ "$(bosh_file_sha256 "$BOSH_HOME/starship.toml")" == "$starship_hash" ]]
[[ -f "$KONSOLE_DIR/bosh.profile" ]]
[[ "$(bosh_file_sha256 "$KONSOLE_DIR/bosh.profile")" == "$profile_hash" ]]

# The modified anime image remains; the four untouched images are removed.
[[ -f "$ANIME_DEST/bosh1.png" ]]
[[ "$(bosh_file_sha256 "$ANIME_DEST/bosh1.png")" == "$anime1_hash" ]]
[[ -f "$BOSH_STATE/$anime1_state_key" ]]

for filename in bosh2.png bosh3.png bosh4.png bosh5.png; do
    [[ ! -e "$ANIME_DEST/$filename" ]]

    name_hash="$(printf '%s' "$filename" | sha256sum)"
    name_hash="${name_hash%% *}"
    state_key="anime_$name_hash"

    [[ ! -e "$BOSH_STATE/$state_key" ]]
done

[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 4 ]]

# The Zsh block is removed and the user's original bytes and mode return.
[[ "$(bosh_file_sha256 "$HOME/.zshrc")" == "$zshrc_before" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == "640" ]]
grep -Fqx 'alias personal="echo roundtrip"' "$HOME/.zshrc"
! grep -Fq '# >>> Bosh Terminal >>>' "$HOME/.zshrc"

# Oh My Zsh, its customization and package state are retained.
[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]
[[ "$(bosh_file_sha256 "$HOME/.oh-my-zsh/plugins/example/example.plugin.zsh")" == "$omz_plugin_hash" ]]
[[ -f "$BOSH_STATE/oh_my_zsh_manifest" ]]
[[ -f "$BOSH_STATE/package_starship" ]]

# Backups and state archives remain available.
[[ -d "$BOSH_BACKUP" ]]
find "$BOSH_BACKUP" -type f -print -quit | grep -q .
[[ ! -e "$BOSH_STATE/zshrc_manifest" ]]
shopt -s nullglob
zsh_archives=("$BOSH_STATE"/zshrc_manifest.archived-*)
[[ "${#zsh_archives[@]}" -eq 1 ]]

echo "Roundtrip verificado: recursos propios retirados; personalizaciones, OMZ, paquetes y respaldos preservados."
CASE



test_case "O-1: manifiestos anime archivados ignorados en segunda pasada" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

ANIME_SOURCE="$HOME/project-assets"
ANIME_DEST="$HOME/data/fastfetch/anime"
mkdir -p "$ANIME_SOURCE" "$ANIME_DEST"

filename="repeat.png"
printf 'repeat image\n' > "$ANIME_SOURCE/$filename"
cp -p "$ANIME_SOURCE/$filename" "$ANIME_DEST/$filename"

name_hash="$(printf '%s' "$filename" | sha256sum)"
name_hash="${name_hash%% *}"
state_key="anime_$name_hash"
filename_b64="$(printf '%s' "$filename" | base64 -w 0)"
file_hash="$(bosh_uninstall_hash "$ANIME_DEST/$filename")"

printf -v manifest '%s\n%s\n%s\n%s' \
    "version=1" \
    "component=anime_image" \
    "filename_b64=$filename_b64" \
    "sha256=$file_hash"
write_state "$state_key" "$manifest"

bosh_uninstall_process_anime
[[ ! -e "$ANIME_DEST/$filename" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 1 ]]

preserved_before="$BOSH_UNINSTALL_PRESERVED"
errors_before="$BOSH_UNINSTALL_ERRORS"

bosh_uninstall_process_anime

[[ "$BOSH_UNINSTALL_PRESERVED" -eq "$preserved_before" ]]
[[ "$BOSH_UNINSTALL_ERRORS" -eq "$errors_before" ]]
[[ "$BOSH_UNINSTALL_ANIME_REMOVED" -eq 1 ]]

echo "Segunda pasada idempotente; archivo archivado ignorado."
CASE

test_case "O-1: appended Zsh conserva archivo original sin LF final" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"

printf 'alias sin_salto="echo conservar"' > "$HOME/.zshrc"
chmod 640 "$HOME/.zshrc"
original_hash="$(bosh_uninstall_hash "$HOME/.zshrc")"

integrate_zsh
read_manifest zshrc
[[ "${BOSH_MANIFEST[mode]}" == "appended" ]]

bosh_uninstall_process_zsh

[[ "$(bosh_uninstall_hash "$HOME/.zshrc")" == "$original_hash" ]]
[[ "$(stat -c '%a' "$HOME/.zshrc")" == "640" ]]
[[ "$(tail -c 1 "$HOME/.zshrc" | od -An -tu1 | tr -d ' ')" != "10" ]]
grep -Fqx 'alias sin_salto="echo conservar"' "$HOME/.zshrc"
! grep -Fq '# >>> Bosh Terminal >>>' "$HOME/.zshrc"

echo "Contenido byte a byte y ausencia de LF final conservados."
CASE

test_summary
