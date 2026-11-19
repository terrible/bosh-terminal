#!/usr/bin/env bash

set -uo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "C-2: Starship personalizado, continuidad y errores" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

echo "=== INSTALACIÓN INICIAL DE STARSHIP ==="

install_managed_file_or_skip \
    "$STARSHIP_CONFIG" \
    "$BOSH_HOME/starship.toml" starship

manifest="$BOSH_STATE/starship_manifest"
manifest_before="$(sha256sum "$manifest")"
manifest_before="${manifest_before%% *}"

echo ""
echo "=== PERSONALIZACIÓN DEL USUARIO ==="

printf '\n# User customization for automated tests\n' \
    >> "$BOSH_HOME/starship.toml"

file_before="$(sha256sum "$BOSH_HOME/starship.toml")"
file_before="${file_before%% *}"

echo ""
echo "=== REINSTALACIÓN DE STARSHIP ==="

output="$(install_managed_file_or_skip \
    "$STARSHIP_CONFIG" \
    "$BOSH_HOME/starship.toml" starship 2>&1)" || {
        printf '%s\n' "$output"
        exit 1
    }

printf '%s\n' "$output"

file_after="$(sha256sum "$BOSH_HOME/starship.toml")"
file_after="${file_after%% *}"

manifest_after="$(sha256sum "$manifest")"
manifest_after="${manifest_after%% *}"

[[ "$file_before" == "$file_after" ]]
[[ "$manifest_before" == "$manifest_after" ]]

grep -Fq '# User customization for automated tests' \
    "$BOSH_HOME/starship.toml"

grep -Fq 'preserving it:' <<< "$output"
grep -Fq 'Review and reconcile your local changes' <<< "$output"

echo "Personalización y manifiesto preservados."

echo ""
echo "=== CONTINUAR CON FASTFETCH ==="

install_managed_file_or_skip \
    "$FASTFETCH_CONFIG" \
    "$BOSH_HOME/fastfetch.jsonc" fastfetch

[[ -f "$BOSH_HOME/fastfetch.jsonc" ]]
[[ -f "$BOSH_STATE/fastfetch_manifest" ]]

echo "Fastfetch instalado después del conflicto."

echo ""
echo "=== PROPAGACIÓN DE ERRORES REALES ==="

if output="$(install_managed_file_or_skip \
    "$HOME/source-inexistente" \
    "$BOSH_HOME/test-file" testfatal 2>&1)"; then
    printf '%s\n' "$output"
    echo "ERROR: se ocultó un error real."
    exit 1
else
    status=$?
fi

printf '%s\n' "$output"

[[ "$status" -eq 1 ]]
grep -Fq 'Source is not a regular file' <<< "$output"

echo "Error real propagado con código 1."
CASE

test_case "C-2: perfil Konsole personalizado y esquema pendiente" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

# Prevent package checks from invoking package installation.
package_installed() {
    return 0
}

[[ -f "$KONSOLE_PROFILE" && -f "$KONSOLE_SCHEME" ]]

echo "=== INSTALACIÓN INICIAL ==="

install_managed_file \
    "$KONSOLE_PROFILE" \
    "$KONSOLE_DIR/bosh.profile" konsole_profile

install_managed_file \
    "$KONSOLE_SCHEME" \
    "$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme" konsole_scheme

profile="$KONSOLE_DIR/bosh.profile"
profile_manifest="$BOSH_STATE/konsole_profile_manifest"
scheme="$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme"
scheme_manifest="$BOSH_STATE/konsole_scheme_manifest"

echo ""
echo "=== PERSONALIZAR EL PERFIL ==="

printf '\n# User customization for automated Konsole tests\n' \
    >> "$profile"

profile_hash="$(sha256sum "$profile")"
profile_hash="${profile_hash%% *}"

profile_manifest_hash="$(sha256sum "$profile_manifest")"
profile_manifest_hash="${profile_manifest_hash%% *}"

echo ""
echo "=== SIMULAR ESQUEMA NO INSTALADO ==="

rm -- "$scheme" "$scheme_manifest"

echo ""
echo "=== EJECUTAR COMPONENTE KONSOLE ==="

output="$(install_konsole_component 2>&1)" || {
    printf '%s\n' "$output"
    echo "ERROR: Konsole abortó."
    exit 1
}

printf '%s\n' "$output"

echo ""
echo "=== VERIFICAR PERFIL ==="

profile_after="$(sha256sum "$profile")"
profile_after="${profile_after%% *}"

profile_manifest_after="$(sha256sum "$profile_manifest")"
profile_manifest_after="${profile_manifest_after%% *}"

[[ "$profile_hash" == "$profile_after" ]]
[[ "$profile_manifest_hash" == "$profile_manifest_after" ]]

grep -Fq '# User customization for automated Konsole tests' "$profile"
grep -Fq 'preserving it:' <<< "$output"
grep -Fq 'Review and reconcile your local changes' <<< "$output"

echo "Perfil personalizado y manifiesto preservados."

echo ""
echo "=== VERIFICAR ESQUEMA ==="

[[ -f "$scheme" && -f "$scheme_manifest" ]]
cmp -s "$KONSOLE_SCHEME" "$scheme"

read_manifest konsole_scheme
[[ "${BOSH_MANIFEST[component]:-}" == "managed_file" ]]

grep -Fq 'Installed: ' <<< "$output"

echo "Esquema instalado y registrado después del conflicto."
CASE


test_case "Temporary file removal helper: retry and symlink safety" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

real_rm="$(command -v rm)"
mkdir -p "$HOME/test-bin"

cat > "$HOME/test-bin/rm" <<'RM_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${TEST_REMOVE_FAIL:-0}" == "1" &&
      "${1:-}" == "-f" &&
      "${2:-}" == "--" &&
      "${3:-}" == "${TEST_REMOVE_FAIL_PATH:-}" ]]; then
    printf 'failure\n' >> "$HOME/remove-attempts"
    exit 43
fi

exec "$TEST_REAL_RM" "$@"
RM_WRAPPER

chmod 700 "$HOME/test-bin/rm"
export TEST_REAL_RM="$real_rm"
PATH="$HOME/test-bin:$PATH"
export PATH

printf '%s\n' "successful temporary" > "$HOME/remove-success"
bosh_register_temp "$HOME/remove-success" file
bosh_remove_temp_file "$HOME/remove-success"

[[ ! -e "$HOME/remove-success" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]
echo "Eliminación exitosa y registro retirado."

retry_file="$HOME/remove-retry"
printf '%s\n' "retry temporary" > "$retry_file"
bosh_register_temp "$retry_file" file

export TEST_REMOVE_FAIL=1
export TEST_REMOVE_FAIL_PATH="$retry_file"

if bosh_remove_temp_file "$retry_file"; then
    echo "ERROR: la eliminación debía fallar."
    exit 1
else
    status=$?
fi

[[ "$status" -ne 0 ]]
[[ -f "$retry_file" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 1 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 1 ]]
[[ "${BOSH_TEMP_PATHS[0]}" == "$retry_file" ]]
[[ "${BOSH_TEMP_TYPES[0]}" == "file" ]]
[[ "$(wc -l < "$HOME/remove-attempts")" -eq 1 ]]
echo "Fallo de rm: temporal conservado y registrado."

unset TEST_REMOVE_FAIL TEST_REMOVE_FAIL_PATH
bosh_remove_temp_file "$retry_file"

[[ ! -e "$retry_file" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]
echo "Reintento exitoso y registro retirado."

foreign_file="$HOME/foreign-file"
replaced_file="$HOME/replaced-temporary"
printf '%s\n' "user data" > "$foreign_file"
printf '%s\n' "temporary data" > "$replaced_file"
bosh_register_temp "$replaced_file" file

"$TEST_REAL_RM" -f -- "$replaced_file"
ln -s -- "$foreign_file" "$replaced_file"

if bosh_remove_temp_file "$replaced_file"; then
    echo "ERROR: se aceptó una ruta temporal reemplazada por symlink."
    exit 1
fi

[[ -L "$replaced_file" ]]
[[ "$(cat "$foreign_file")" == "user data" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 1 ]]
[[ "${BOSH_TEMP_PATHS[0]}" == "$replaced_file" ]]
[[ "${BOSH_TEMP_TYPES[0]}" == "file" ]]
echo "Symlink y destino real preservados."

bosh_cleanup_temps

[[ -L "$replaced_file" ]]
[[ "$(cat "$foreign_file")" == "user data" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]
echo "Limpieza central retiró el registro sin tocar el symlink ni su destino."
CASE

test_case "Temporary cleanup: verify file and directory removal" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

real_rm="$(command -v rm)"
mkdir -p "$HOME/test-bin"

file="$HOME/cleanup-noop-file"
printf '%s\n' "temporary file" > "$file"
bosh_register_temp "$file" file

rm() {
    if [[ "${1:-}" == "-f" && "${2:-}" == "--" && "${3:-}" == "$file" ]]; then
        return 0
    fi
    "$real_rm" "$@"
}

bosh_cleanup_temps

[[ -f "$file" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 1 ]]
[[ "${BOSH_TEMP_PATHS[0]}" == "$file" ]]
[[ "${BOSH_TEMP_TYPES[0]}" == "file" ]]

unset -f rm
bosh_cleanup_temps
[[ ! -e "$file" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]

echo "Archivo persistente tras rm exitoso: registro conservado y reintento correcto."

directory="$HOME/cleanup-noop-directory"
mkdir -p "$directory"
bosh_register_temp "$directory" dir

rm() {
    if [[ "${1:-}" == "-rf" && "${2:-}" == "--" && "${3:-}" == "$directory" ]]; then
        return 0
    fi
    "$real_rm" "$@"
}

bosh_cleanup_temps

[[ -d "$directory" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 1 ]]
[[ "${BOSH_TEMP_PATHS[0]}" == "$directory" ]]
[[ "${BOSH_TEMP_TYPES[0]}" == "dir" ]]

unset -f rm
bosh_cleanup_temps
[[ ! -e "$directory" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]

echo "Directorio persistente tras rm exitoso: registro conservado y reintento correcto."
CASE


test_case "Rollback staging: failed registration and failed cleanup" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

previous="$HOME/staging-previous"
rollback="$HOME/staging-destination.bosh-rollback"
destination="$HOME/staging-destination"

printf '%s\n' "previous content" > "$previous"
cp -p -- "$previous" "$rollback"
printf '%s\n' "installed content" > "$destination"

previous_hash="$(bosh_file_sha256 "$previous")"
installed_hash="$(bosh_file_sha256 "$destination")"
real_rm="$(command -v rm)"

bosh_register_temp() {
    return 1
}

rm() {
    if [[ "${1:-}" == "-f" &&
          "${2:-}" == "--" &&
          "${3:-}" == *.bosh-restore.* ]]; then
        return 43
    fi
    "$real_rm" "$@"
}

if bosh_restore_rollback_file \
    "$rollback" "$destination" "$installed_hash" "$previous_hash"; then
    echo "ERROR: la restauración debía fallar al registrar staging."
    exit 1
fi

unset -f bosh_register_temp
unset -f rm

[[ "$(cat "$destination")" == "installed content" ]]
[[ -f "$rollback" ]]
bosh_verify_rollback_file "$rollback" "$previous_hash"

staging_count=0
for stage in "$HOME"/staging-destination.bosh-restore.*; do
    [[ -e "$stage" || -L "$stage" ]] || continue
    [[ -f "$stage" && ! -L "$stage" ]]
    ((staging_count += 1))
    "$real_rm" -f -- "$stage"
done

[[ "$staging_count" -eq 1 ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]

"$real_rm" -f -- "$rollback"
echo "Fallos de registro y eliminación detectados; staging residual identificado y retirado."
CASE


test_case "Installation lock: reject concurrent acquisition" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

export BOSH_STATE
acquire_install_lock
[[ -n "$BOSH_LOCK_FD" ]]

if flock -n "$BOSH_STATE/install.lock" -c true; then
    echo "ERROR: se permitió una segunda adquisición del bloqueo."
    exit 1
fi

flock -u "$BOSH_LOCK_FD"
exec {BOSH_LOCK_FD}>&-
BOSH_LOCK_FD=""

acquire_install_lock
[[ -n "$BOSH_LOCK_FD" ]]

flock -u "$BOSH_LOCK_FD"
exec {BOSH_LOCK_FD}>&-
BOSH_LOCK_FD=""

echo "Segunda instalación rechazada; bloqueo disponible tras liberación."
CASE


test_case "Rollback helpers: verification, restoration and preservation" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

previous="$HOME/previous-content"
destination="$HOME/managed-destination"
rollback="$HOME/managed-destination.bosh-rollback"
user_backup="$HOME/permanent-user-backup"

printf '%s\n' "previous user content" > "$previous"
printf '%s\n' "permanent backup sentinel" > "$user_backup"

previous_hash="$(bosh_file_sha256 "$previous")"

echo "=== VERIFICACIÓN Y RESTAURACIÓN CORRECTA ==="

cp -p -- "$previous" "$rollback"
printf '%s\n' "new installed content" > "$destination"
installed_hash="$(bosh_file_sha256 "$destination")"

bosh_verify_rollback_file "$rollback" "$previous_hash"
bosh_restore_rollback_file \
    "$rollback" "$destination" "$installed_hash" "$previous_hash"

cmp -s "$previous" "$destination"
[[ ! -e "$rollback" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]

echo "Restauración verificada y staging retirado del registro."

echo ""
echo "=== LIMPIEZA DE SNAPSHOT FALLIDA TRAS RESTAURAR ==="

cleanup_rollback="$HOME/cleanup-failure.bosh-rollback"
cleanup_destination="$HOME/cleanup-failure-destination"

cp -p -- "$previous" "$cleanup_rollback"
printf '%s\n' "new installed content" > "$cleanup_destination"
cleanup_installed_hash="$(bosh_file_sha256 "$cleanup_destination")"
real_rm="$(command -v rm)"

rm() {
    if [[ "${1:-}" == "-f" &&
          "${2:-}" == "--" &&
          "${3:-}" == "$cleanup_rollback" ]]; then
        return 43
    fi

    "$real_rm" "$@"
}

bosh_restore_rollback_file \
    "$cleanup_rollback" "$cleanup_destination" \
    "$cleanup_installed_hash" "$previous_hash"

unset -f rm

cmp -s "$previous" "$cleanup_destination"
[[ -f "$cleanup_rollback" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]

"$real_rm" -f -- "$cleanup_rollback"

echo "Restauración exitosa; snapshot conservado tras el fallo de limpieza."


echo ""
echo "=== DESTINO MODIFICADO: NO SOBRESCRIBIR ==="

cp -p -- "$previous" "$rollback"
printf '%s\n' "expected installed content" > "$destination"
installed_hash="$(bosh_file_sha256 "$destination")"
printf '%s\n' "external user modification" > "$destination"

if bosh_restore_rollback_file \
    "$rollback" "$destination" "$installed_hash" "$previous_hash"; then
    echo "ERROR: se sobrescribió una modificación externa."
    exit 1
else
    restore_exit=$?
fi

[[ "$restore_exit" -ne 0 ]]
[[ "$(cat "$destination")" == "external user modification" ]]
[[ -f "$rollback" ]]
bosh_verify_rollback_file "$rollback" "$previous_hash"
bosh_remove_rollback_file "$rollback"

echo "Modificación externa y snapshot preservados."

echo ""
echo "=== SNAPSHOT ALTERADO: NO RESTAURAR ==="

cp -p -- "$previous" "$rollback"
printf '%s\n' "tampered snapshot" > "$rollback"

if bosh_verify_rollback_file "$rollback" "$previous_hash"; then
    echo "ERROR: se aceptó un snapshot alterado."
    exit 1
fi

[[ -f "$rollback" ]]
bosh_remove_rollback_file "$rollback"

echo "Snapshot alterado detectado y no utilizado."

echo ""
echo "=== SYMLINK: NO ACEPTAR COMO SNAPSHOT ==="

rollback_link="$HOME/rollback-link"
ln -s -- "$previous" "$rollback_link"

if bosh_verify_rollback_file "$rollback_link" "$previous_hash"; then
    echo "ERROR: se aceptó un symlink como snapshot."
    exit 1
fi

[[ -L "$rollback_link" ]]
[[ "$(cat "$previous")" == "previous user content" ]]
rm -f -- "$rollback_link"

echo "Symlink rechazado sin tocar su destino."

echo ""
echo "=== ELIMINACIÓN CON HASH ESPERADO ==="

protected="$HOME/protected-file"
printf '%s\n' "external content" > "$protected"

if bosh_remove_file_if_hash_matches "$protected" "$previous_hash"; then
    echo "ERROR: se eliminó un archivo con hash diferente."
    exit 1
fi

[[ -f "$protected" ]]

protected_hash="$(bosh_file_sha256 "$protected")"
bosh_remove_file_if_hash_matches "$protected" "$protected_hash"
[[ ! -e "$protected" ]]

echo "Solo se eliminó el archivo con hash coincidente."

[[ "$(cat "$user_backup")" == "permanent backup sentinel" ]]
echo "Backup permanente de prueba intacto."
CASE



test_case "Managed-file integration: manifest failure is retried without another displacement" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

source_file="$HOME/source-managed"
destination="$HOME/managed-destination"
state_key="manifest_retry"
manifest="$BOSH_STATE/${state_key}_manifest"
pending="$BOSH_STATE/.${state_key}.managed-pending"

printf '%s' "original managed content" > "$source_file"
install_managed_file "$source_file" "$destination" "$state_key"
original_inode="$(stat -c '%d:%i' -- "$destination")"
manifest_hash="$(bosh_file_sha256 "$manifest")"
printf '%s' "replacement managed content" > "$source_file"

status=0
(
    # Fail before the atomic manifest rename, through the normal writer.
    mv() {
        if [[ "${*: -1}" == "$manifest" ]]; then
            return 1
        fi
        command mv "$@"
    }
    install_managed_file "$source_file" "$destination" "$state_key"
) || status=$?
[[ "$status" == 1 && -f "$pending/record" ]]
cmp -s "$source_file" "$destination"
[[ "$(bosh_file_sha256 "$manifest")" == "$manifest_hash" ]]
slots=("$HOME"/.bosh-managed-manifest_retry.*/file)
[[ "${#slots[@]}" -eq 1 && "$(cat -- "${slots[0]}")" == "original managed content" ]]
[[ "$(stat -c '%d:%i' -- "${slots[0]}")" == "$original_inode" ]]
candidate_inode="$(stat -c '%d:%i' -- "$destination")"

install_managed_file "$source_file" "$destination" "$state_key"
read_manifest "$state_key"
[[ "${BOSH_MANIFEST[sha256]}" == "$(bosh_file_sha256 "$source_file")" ]]
[[ "$(stat -c '%d:%i' -- "$destination")" == "$candidate_inode" ]]
[[ ! -e "$pending" ]]
[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]
CASE

test_case "Anime integration: rollback after state failure" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

ANIME_SOURCE="$HOME/anime-source"
ANIME_DEST="$HOME/anime-destination"

mkdir -p "$ANIME_SOURCE"
filename="integration-test.png"
source_file="$ANIME_SOURCE/$filename"
destination="$ANIME_DEST/$filename"

printf '%s' "original anime image content" > "$source_file"

install_anime_images

[[ -f "$destination" ]]

expected="$HOME/expected-anime-content"
cp -p -- "$destination" "$expected"

name_hash="$(printf '%s' "$filename" | sha256sum)"
name_hash="${name_hash%% *}"
state_key="anime_${name_hash}"
manifest="$BOSH_STATE/$state_key"

[[ -f "$manifest" ]]
manifest_hash="$(bosh_file_sha256 "$manifest")"

printf '%s' "replacement anime image content" > "$source_file"

# Fail only when the installer attempts to update this image state.
write_state() {
    if [[ "${1:-}" == "$state_key" ]]; then
        msg error "Simulated anime state write failure: $state_key"
        return 1
    fi

    msg error "Unexpected state write request: ${1:-}"
    return 1
}

if install_anime_images; then
    echo "ERROR: la instalación anime debía fallar al escribir el estado."
    exit 1
else
    install_exit=$?
fi

[[ "$install_exit" -eq 1 ]]
cmp -s "$expected" "$destination"
[[ "$(bosh_file_sha256 "$manifest")" == "$manifest_hash" ]]

if compgen -G "${destination}.bosh-rollback.*" >/dev/null; then
    echo "ERROR: quedó un snapshot anime de rollback."
    exit 1
fi

if compgen -G "${destination}.bosh-restore.*" >/dev/null; then
    echo "ERROR: quedó un staging anime de restauración."
    exit 1
fi

[[ "${#BOSH_TEMP_PATHS[@]}" -eq 0 ]]
[[ "${#BOSH_TEMP_TYPES[@]}" -eq 0 ]]

echo "Fallo de estado propagado; imagen y manifiesto anteriores preservados."
echo "Sin snapshots ni temporales residuales."
CASE


test_case "Konsole optional component rejects symlinked resources" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

package_installed() {
    return 0
}

profile="$HOME/konsole.profile"
scheme="$HOME/konsole.colorscheme"
printf 'profile\n' > "$profile"
printf 'scheme\n' > "$scheme"

KONSOLE_PROFILE="$HOME/profile-link"
KONSOLE_SCHEME="$scheme"
ln -s "$profile" "$KONSOLE_PROFILE"

output="$(install_konsole_component 2>&1)"
printf '%s\n' "$output"
grep -Fq 'unavailable or invalid. Skipping.' <<< "$output"
[[ ! -e "$KONSOLE_DIR/bosh.profile" ]]

rm -- "$KONSOLE_PROFILE"

KONSOLE_PROFILE="$profile"
KONSOLE_SCHEME="$HOME/scheme-link"
ln -s "$scheme" "$KONSOLE_SCHEME"

output="$(install_konsole_component 2>&1)"
printf '%s\n' "$output"
grep -Fq 'unavailable or invalid. Skipping.' <<< "$output"
[[ ! -e "$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme" ]]

echo "Ambos enlaces simbólicos rechazados; integración omitida."
CASE

test_case "create_backup: private permissions and collision handling" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

source_file="$HOME/private-config"
printf 'contenido privado\n' > "$source_file"
chmod 644 "$source_file"

create_backup "$source_file"
first_backup="$BOSH_LAST_BACKUP"
[[ "$BOSH_LAST_BACKUP_MODE" == "644" ]]

[[ -f "$first_backup" ]]
[[ "$(cat "$first_backup")" == "contenido privado" ]]
[[ "$(stat -c '%a' "$first_backup")" == "600" ]]
[[ "$(stat -c '%a' "$BOSH_BACKUP")" == "700" ]]

while IFS= read -r directory; do
    [[ "$(stat -c '%a' "$directory")" == "700" ]]
done < <(find "$BOSH_BACKUP" -type d -print)

create_backup "$source_file"
second_backup="$BOSH_LAST_BACKUP"
[[ "$BOSH_LAST_BACKUP_MODE" == "644" ]]

[[ -f "$second_backup" ]]
[[ "$first_backup" != "$second_backup" ]]
[[ "$(stat -c '%a' "$second_backup")" == "600" ]]
[[ "$(cat "$second_backup")" == "contenido privado" ]]

[[ ! -e "$HOME/missing-backup-source" ]]
create_backup "$HOME/missing-backup-source"
[[ -z "$BOSH_LAST_BACKUP" ]]
[[ -z "$BOSH_LAST_BACKUP_MODE" ]]

echo "Backups privados, modo original preservado y colisión resuelta."
CASE

test_case "create_backup: reject parent traversal paths" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

mkdir -p "$HOME/path-guard"
printf 'contenido privado\n' > "$HOME/private-config"
printf 'contenido de prueba\n' > "$HOME/path-guard/source"

if create_backup "$HOME/path-guard/../private-config"; then
    echo "ERROR: se aceptó una ruta de origen con .."
    exit 1
fi

[[ -z "$BOSH_LAST_BACKUP" ]]
[[ -z "$BOSH_LAST_BACKUP_MODE" ]]
[[ ! -e "$BOSH_BACKUP" ]]

original_backup="$BOSH_BACKUP"
BOSH_BACKUP="$HOME/path-guard/../outside-backups"

if create_backup "$HOME/path-guard/source"; then
    echo "ERROR: se aceptó una raíz de backups con .."
    exit 1
fi

[[ -z "$BOSH_LAST_BACKUP" ]]
[[ ! -e "$HOME/outside-backups" ]]
BOSH_BACKUP="$original_backup"

echo "Rutas con traversal rechazadas sin crear backups."
CASE

test_summary
