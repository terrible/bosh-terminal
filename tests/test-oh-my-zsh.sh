#!/usr/bin/env bash

set -uo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

TEST_OMZ_REMOTE="https://github.com/ohmyzsh/ohmyzsh.git"
export TEST_OMZ_REMOTE

# Create a local repository and a git wrapper that redirects only the
# installer's official Oh My Zsh clone to that local repository.
test_setup_omz_git() {
    local source="$HOME/omz-source"
    local bin="$HOME/test-bin"

    TEST_REAL_GIT="$(command -v git)" || {
        echo "ERROR: Git is required for Oh My Zsh tests."
        return 1
    }

    TEST_OMZ_SOURCE="$source"

    mkdir -p "$source/plugins/example" "$bin"

    printf '%s\n' '# Test Oh My Zsh entry point' > "$source/oh-my-zsh.sh"
    printf '%s\n' '# Test plugin' > "$source/plugins/example/example.plugin.zsh"
    printf '%s\n' '# Test library' > "$source/lib-test.zsh"

    "$TEST_REAL_GIT" -C "$source" init -q
    "$TEST_REAL_GIT" -C "$source" config user.name "Bosh Test"
    "$TEST_REAL_GIT" -C "$source" config user.email "bosh-test@example.invalid"
    "$TEST_REAL_GIT" -C "$source" add .
    "$TEST_REAL_GIT" -C "$source" commit -qm "Initial test commit"

    export TEST_REAL_GIT TEST_OMZ_SOURCE TEST_OMZ_REMOTE

    cat > "$bin/git" <<'GIT_WRAPPER'
#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" == "clone" &&
      "${2:-}" == "--depth" &&
      "${3:-}" == "1" &&
      "${4:-}" == "$TEST_OMZ_REMOTE" ]]; then

    destination="${5:-}"

    [[ -n "$destination" ]] || exit 90

    if [[ "${TEST_OMZ_CLONE_FAIL:-0}" == "1" ]]; then
        exit 42
    fi

    "$TEST_REAL_GIT" clone --depth 1 \
        "$TEST_OMZ_SOURCE" "$destination"

    "$TEST_REAL_GIT" -C "$destination" \
        remote set-url origin "$TEST_OMZ_REMOTE"

    exit 0
fi

exec "$TEST_REAL_GIT" "$@"
GIT_WRAPPER

    chmod 700 "$bin/git"
    PATH="$bin:$PATH"
    export PATH
}

test_prepare_existing_omz() {
    local destination="$HOME/.oh-my-zsh"

    "$TEST_REAL_GIT" clone --depth 1 \
        "$TEST_OMZ_SOURCE" "$destination"

    "$TEST_REAL_GIT" -C "$destination" \
        remote set-url origin "$TEST_OMZ_REMOTE"
}

test_omz_tree_hash() {
    local result

    result="$(tar \
        --sort=name \
        --format=gnu \
        --mtime='@0' \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        --exclude='./.git' \
        -cf - -C "$1" . | sha256sum)" || return 1

    printf '%s' "${result%% *}"
}

export -f test_setup_omz_git test_prepare_existing_omz test_omz_tree_hash

test_case "Oh My Zsh: instalación nueva, manifiesto e integridad" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

test_setup_omz_git

echo "=== INSTALACIÓN NUEVA ==="
install_oh_my_zsh

omz_dir="$HOME/.oh-my-zsh"
manifest="$BOSH_STATE/oh_my_zsh_manifest"

[[ -d "$omz_dir" && ! -L "$omz_dir" ]]
[[ -f "$omz_dir/oh-my-zsh.sh" ]]
[[ -f "$manifest" && ! -L "$manifest" ]]

echo ""
echo "=== VERIFICAR MANIFIESTO ==="

read_manifest oh_my_zsh

[[ "${#BOSH_MANIFEST[@]}" -eq 6 ]]
[[ "${BOSH_MANIFEST[version]}" == "1" ]]
[[ "${BOSH_MANIFEST[component]}" == "oh_my_zsh" ]]
[[ "${BOSH_MANIFEST[ownership]}" == "created" ]]
[[ "${BOSH_MANIFEST[remote]}" == "$TEST_OMZ_REMOTE" ]]
[[ "${BOSH_MANIFEST[commit]}" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]]
[[ "${BOSH_MANIFEST[tree_sha256]}" =~ ^[a-f0-9]{64}$ ]]

actual_commit="$("$TEST_REAL_GIT" -C "$omz_dir" rev-parse HEAD)"
actual_tree_hash="$(test_omz_tree_hash "$omz_dir")"

[[ "${BOSH_MANIFEST[commit]}" == "$actual_commit" ]]
[[ "${BOSH_MANIFEST[tree_sha256]}" == "$actual_tree_hash" ]]

echo "Manifiesto, remoto, commit y árbol verificados."

echo ""
echo "=== REINSTALACIÓN SIN CAMBIOS ==="

manifest_before="$(sha256sum "$manifest")"
manifest_before="${manifest_before%% *}"

output="$(install_oh_my_zsh 2>&1)"
printf '%s\n' "$output"

manifest_after="$(sha256sum "$manifest")"
manifest_after="${manifest_after%% *}"

[[ "$manifest_before" == "$manifest_after" ]]
grep -Fq 'Existing Oh My Zsh installation preserved.' <<< "$output"

shopt -s nullglob
temps=("$HOME"/.oh-my-zsh.bosh-tmp.*)
[[ "${#temps[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]

echo "Reinstalación idempotente; instalación y manifiesto preservados."
CASE

test_case "Oh My Zsh: instalación preexistente sin manifiesto" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

omz_dir="$HOME/.oh-my-zsh"

mkdir -p "$omz_dir"
printf '%s\n' '# Existing user installation' > "$omz_dir/oh-my-zsh.sh"
printf '%s\n' '# User customization' > "$omz_dir/custom.zsh"

before_entry="$(sha256sum "$omz_dir/oh-my-zsh.sh")"
before_entry="${before_entry%% *}"

before_custom="$(sha256sum "$omz_dir/custom.zsh")"
before_custom="${before_custom%% *}"

echo "=== PRESERVAR INSTALACIÓN AJENA ==="

output="$(install_oh_my_zsh 2>&1)"
printf '%s\n' "$output"

after_entry="$(sha256sum "$omz_dir/oh-my-zsh.sh")"
after_entry="${after_entry%% *}"

after_custom="$(sha256sum "$omz_dir/custom.zsh")"
after_custom="${after_custom%% *}"

[[ "$before_entry" == "$after_entry" ]]
[[ "$before_custom" == "$after_custom" ]]
[[ ! -e "$BOSH_STATE/oh_my_zsh_manifest" ]]

echo "Instalación preexistente preservada sin apropiarse de ella."
CASE

test_case "Oh My Zsh: migración de manifiesto legado" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

test_setup_omz_git
test_prepare_existing_omz

ensure_directory "$BOSH_STATE"

omz_dir="$HOME/.oh-my-zsh"
manifest="$BOSH_STATE/oh_my_zsh_manifest"

commit="$("$TEST_REAL_GIT" -C "$omz_dir" rev-parse HEAD)"
remote="$("$TEST_REAL_GIT" -C "$omz_dir" config --get remote.origin.url)"
tree_hash="$(test_omz_tree_hash "$omz_dir")"

printf '%s\n' \
    "created" \
    "$commit" \
    "$remote" \
    "$tree_hash" > "$manifest"

legacy_hash="$(sha256sum "$manifest")"
legacy_hash="${legacy_hash%% *}"

echo "=== MIGRAR MANIFIESTO POSICIONAL ==="

output="$(install_oh_my_zsh 2>&1)"
printf '%s\n' "$output"

read_manifest oh_my_zsh

[[ "${#BOSH_MANIFEST[@]}" -eq 6 ]]
[[ "${BOSH_MANIFEST[version]}" == "1" ]]
[[ "${BOSH_MANIFEST[component]}" == "oh_my_zsh" ]]
[[ "${BOSH_MANIFEST[ownership]}" == "created" ]]
[[ "${BOSH_MANIFEST[commit]}" == "$commit" ]]
[[ "${BOSH_MANIFEST[remote]}" == "$remote" ]]
[[ "${BOSH_MANIFEST[tree_sha256]}" == "$tree_hash" ]]

new_hash="$(sha256sum "$manifest")"
new_hash="${new_hash%% *}"

[[ "$legacy_hash" != "$new_hash" ]]

echo "Manifiesto legado migrado y repositorio verificado."
CASE

test_case "Oh My Zsh: personalizaciones locales preservadas" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

test_setup_omz_git
install_oh_my_zsh

omz_dir="$HOME/.oh-my-zsh"
manifest="$BOSH_STATE/oh_my_zsh_manifest"

printf '%s\n' '# User modification' >> "$omz_dir/plugins/example/example.plugin.zsh"
printf '%s\n' '# User custom file' > "$omz_dir/custom-local.zsh"

file_before="$(sha256sum "$omz_dir/plugins/example/example.plugin.zsh")"
file_before="${file_before%% *}"
custom_before="$(sha256sum "$omz_dir/custom-local.zsh")"
custom_before="${custom_before%% *}"
manifest_before="$(sha256sum "$manifest")"
manifest_before="${manifest_before%% *}"

output="$(install_oh_my_zsh 2>&1)"
printf '%s\n' "$output"

grep -Fq 'local customizations preserved.' <<< "$output"

file_after="$(sha256sum "$omz_dir/plugins/example/example.plugin.zsh")"
file_after="${file_after%% *}"
custom_after="$(sha256sum "$omz_dir/custom-local.zsh")"
custom_after="${custom_after%% *}"
manifest_after="$(sha256sum "$manifest")"
manifest_after="${manifest_after%% *}"

[[ "$file_before" == "$file_after" ]]
[[ "$custom_before" == "$custom_after" ]]
[[ "$manifest_before" == "$manifest_after" ]]
grep -Fq '# User modification' "$omz_dir/plugins/example/example.plugin.zsh"
grep -Fq '# User custom file' "$omz_dir/custom-local.zsh"

echo "Personalizaciones locales preservadas; repositorio reconocido."
CASE

test_case "Oh My Zsh: commit oficial actualizado y manifiesto preservado" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

test_setup_omz_git
install_oh_my_zsh

omz_dir="$HOME/.oh-my-zsh"
manifest="$BOSH_STATE/oh_my_zsh_manifest"

# Simular una personalización local que no debe perderse.
printf '%s\n' '# User custom file' > "$omz_dir/custom-local.zsh"
custom_before="$(sha256sum "$omz_dir/custom-local.zsh")"
custom_before="${custom_before%% *}"

read_manifest oh_my_zsh
tree_before="${BOSH_MANIFEST[tree_sha256]}"

"$TEST_REAL_GIT" -C "$omz_dir" config user.name "Bosh Test"
"$TEST_REAL_GIT" -C "$omz_dir" config user.email "bosh-test@example.invalid"
"$TEST_REAL_GIT" -C "$omz_dir" commit --allow-empty -qm "Official repository update"

actual_commit="$("$TEST_REAL_GIT" -C "$omz_dir" rev-parse --verify HEAD)"

echo "=== REINSTALACIÓN CON COMMIT OFICIAL DISTINTO ==="

output="$(install_oh_my_zsh 2>&1)" || {
    printf '%s\n' "$output"
    echo "ERROR: se rechazó el cambio de commit del remoto oficial."
    exit 1
}
printf '%s\n' "$output"

grep -Fq 'Oh My Zsh commit changed on the official repository' <<< "$output"

read_manifest oh_my_zsh
[[ "${BOSH_MANIFEST[commit]}" == "$actual_commit" ]]
[[ "${BOSH_MANIFEST[remote]}" == "$TEST_OMZ_REMOTE" ]]
[[ "${BOSH_MANIFEST[tree_sha256]}" == "$tree_before" ]]

custom_after="$(sha256sum "$omz_dir/custom-local.zsh")"
custom_after="${custom_after%% *}"
[[ "$custom_before" == "$custom_after" ]]

echo "Commit actualizado; remoto oficial, hash del árbol y personalización local preservados."
CASE

test_case "Oh My Zsh: remoto alterado detectado y preservado" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

test_setup_omz_git
install_oh_my_zsh

omz_dir="$HOME/.oh-my-zsh"
manifest="$BOSH_STATE/oh_my_zsh_manifest"

"$TEST_REAL_GIT" -C "$omz_dir" \
    remote set-url origin "https://example.invalid/changed.git"

manifest_before="$(sha256sum "$manifest")"
manifest_before="${manifest_before%% *}"

echo "=== REINSTALACIÓN CON REMOTO ALTERADO ==="

if output="$(install_oh_my_zsh 2>&1)"; then
    printf '%s\n' "$output"
    echo "ERROR: se aceptó un remoto distinto."
    exit 1
else
    status=$?
fi

printf '%s\n' "$output"

[[ "$status" -eq 1 ]]

actual_remote="$("$TEST_REAL_GIT" -C "$omz_dir" config --get remote.origin.url)"
[[ "$actual_remote" == "https://example.invalid/changed.git" ]]

manifest_after="$(sha256sum "$manifest")"
manifest_after="${manifest_after%% *}"

[[ "$manifest_before" == "$manifest_after" ]]

echo "Remoto alterado detectado; instalación y manifiesto preservados."
CASE

test_case "Oh My Zsh: manifiesto huérfano archivado antes de instalar" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

test_setup_omz_git
ensure_directory "$BOSH_STATE"

manifest="$BOSH_STATE/oh_my_zsh_manifest"
printf '%s\n' 'orphaned-test-record' > "$manifest"

orphan_hash="$(sha256sum "$manifest")"
orphan_hash="${orphan_hash%% *}"

echo "=== INSTALAR CON REGISTRO HUÉRFANO ==="

output="$(install_oh_my_zsh 2>&1)"
printf '%s\n' "$output"

grep -Fq 'Found an orphaned Oh My Zsh state record.' <<< "$output"
grep -Fq 'State record archived and verified' <<< "$output"

shopt -s nullglob
archives=("$BOSH_STATE"/oh_my_zsh_manifest.archived-*)

[[ "${#archives[@]}" -eq 1 ]]
[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]
[[ -f "$manifest" ]]

archived_hash="$(sha256sum "${archives[0]}")"
archived_hash="${archived_hash%% *}"

[[ "$archived_hash" == "$orphan_hash" ]]
grep -Fxq 'orphaned-test-record' "${archives[0]}"

read_manifest oh_my_zsh
[[ "${BOSH_MANIFEST[component]}" == "oh_my_zsh" ]]

echo "Registro huérfano archivado íntegramente; nueva instalación registrada."
CASE

test_case "Oh My Zsh: fallo de clonación sin residuos" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

test_setup_omz_git
export TEST_OMZ_CLONE_FAIL=1

echo "=== SIMULAR FALLO DE CLONACIÓN ==="

output_file="$HOME/omz-install-output"

if install_oh_my_zsh >"$output_file" 2>&1; then
    cat "$output_file"
    echo "ERROR: la instalación debía fallar."
    exit 1
else
    status=$?
fi

cat "$output_file"

[[ "$status" -eq 1 ]]
[[ ! -e "$HOME/.oh-my-zsh" ]]
[[ ! -L "$HOME/.oh-my-zsh" ]]
[[ ! -e "$BOSH_STATE/oh_my_zsh_manifest" ]]

shopt -s nullglob
temps=("$HOME"/.oh-my-zsh.bosh-tmp.*)
[[ "${#temps[@]}" -eq 0 ]]

[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]

echo "Fallo propagado; destino, manifiesto y temporales sin residuos."
CASE

test_case "Oh My Zsh: rm fallido conserva temporal para reintento" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

real_rm="$(command -v rm)"
test_setup_omz_git

cat > "$HOME/test-bin/rm" <<'RM_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEST_OMZ_RM_FAIL:-0}" == "1" &&
      "${2:-}" == "--" &&
      ( ( "${1:-}" == "-rf" &&
          "${3:-}" == "$HOME"/.oh-my-zsh.bosh-tmp.* ) ||
        ( "${1:-}" == "-f" &&
          "${3:-}" == "$HOME/omz-extra-temp-file" ) ) ]]; then
    printf 'failure\n' >> "$HOME/rm-failure-triggered"
    exit 43
fi

exec "$TEST_REAL_RM" "$@"
RM_WRAPPER

chmod 700 "$HOME/test-bin/rm"
export TEST_REAL_RM="$real_rm"
export TEST_OMZ_CLONE_FAIL=1
export TEST_OMZ_RM_FAIL=1

echo "=== SIMULAR FALLO DE CLONACIÓN Y ELIMINACIÓN ==="

if install_oh_my_zsh; then
    echo "ERROR: la instalación debía fallar."
    exit 1
else
    status=$?
fi

[[ "$status" -eq 1 ]]
[[ -f "$HOME/rm-failure-triggered" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 1 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 1 ]]

temp_path="${BOSH_TEMP_PATHS[0]}"

[[ "$temp_path" == "$HOME"/.oh-my-zsh.bosh-tmp.* ]]
[[ "${BOSH_TEMP_TYPES[0]}" == "dir" ]]
[[ -d "$temp_path" ]]

echo "Fallo de rm simulado; temporal de instalación sigue registrado."

extra_file="$HOME/omz-extra-temp-file"
extra_dir="$HOME/omz-extra-temp-dir"

printf '%s\\n' "temporary test file" > "$extra_file"
mkdir -p "$extra_dir"

bosh_register_temp "$extra_file" file
bosh_register_temp "$extra_dir" dir

[[ "${#BOSH_TEMP_PATHS[@]}" -eq 3 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 3 ]]

echo "Tres temporales registrados: directorio, archivo y directorio."

bosh_cleanup_temps

[[ "$(wc -l < "$HOME/rm-failure-triggered")" -eq 3 ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 2 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 2 ]]
[[ "${BOSH_TEMP_PATHS[0]}" == "$temp_path" ]]
[[ "${BOSH_TEMP_TYPES[0]}" == "dir" ]]
[[ "${BOSH_TEMP_PATHS[1]}" == "$extra_file" ]]
[[ "${BOSH_TEMP_TYPES[1]}" == "file" ]]
[[ -d "$temp_path" ]]
[[ -f "$extra_file" ]]
[[ ! -e "$extra_dir" ]]

echo "Limpieza parcial: dos fallos conservados y un directorio eliminado."

bosh_cleanup_temps

[[ "$(wc -l < "$HOME/rm-failure-triggered")" -eq 5 ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 2 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 2 ]]
[[ "${BOSH_TEMP_PATHS[0]}" == "$temp_path" ]]
[[ "${BOSH_TEMP_TYPES[0]}" == "dir" ]]
[[ "${BOSH_TEMP_PATHS[1]}" == "$extra_file" ]]
[[ "${BOSH_TEMP_TYPES[1]}" == "file" ]]

echo "Segundo intento: rutas y tipos siguen sincronizados."

unset TEST_OMZ_RM_FAIL
bosh_cleanup_temps

[[ ! -e "$temp_path" ]]
[[ ! -e "$extra_file" ]]
[[ ! -e "$extra_dir" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]

echo "Tercer intento exitoso; todos los temporales eliminados."
CASE

test_case "Oh My Zsh: rechazo de destino simbólico" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

real_dir="$HOME/real-oh-my-zsh"
omz_dir="$HOME/.oh-my-zsh"

mkdir -p "$real_dir"
printf '%s\n' '# User-owned installation' > "$real_dir/oh-my-zsh.sh"
ln -s "$real_dir" "$omz_dir"

echo "=== RECHAZAR SYMLINK ==="

if output="$(install_oh_my_zsh 2>&1)"; then
    printf '%s\n' "$output"
    echo "ERROR: se aceptó un destino simbólico."
    exit 1
else
    status=$?
fi

printf '%s\n' "$output"

[[ "$status" -eq 1 ]]
[[ -L "$omz_dir" ]]
[[ -f "$real_dir/oh-my-zsh.sh" ]]
grep -Fq '# User-owned installation' "$real_dir/oh-my-zsh.sh"
[[ ! -e "$BOSH_STATE/oh_my_zsh_manifest" ]]

echo "Symlink rechazado; destino real y contenido preservados."
CASE

test_summary
