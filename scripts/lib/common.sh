#!/usr/bin/env bash
# ============================================================
# Bosh Terminal - Common Library
# Shared functions for installer and uninstaller.
# ============================================================

# Prevent direct execution.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'This file is a library. / Este archivo es una biblioteca.\n'
    exit 1
fi

# ------------------------------------------------------------
# Project paths
# ------------------------------------------------------------

BOSH_VERSION="0.1.0"

BOSH_HOME="${BOSH_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/bosh-terminal}"
BOSH_STATE="${BOSH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/bosh-terminal}"
BOSH_BACKUP="${BOSH_BACKUP:-${XDG_CONFIG_HOME:-$HOME/.config}/bosh-backups/bosh-terminal}"

# ------------------------------------------------------------
# Language detection
# ------------------------------------------------------------

BOSH_LANG="${BOSH_LANG:-${LANG:-en}}"

if [[ "$BOSH_LANG" == es* ]]; then
    BOSH_LANG="es"
else
    BOSH_LANG="en"
fi

# ------------------------------------------------------------
# Messages
# ------------------------------------------------------------

msg() {
    local key="$1"
    shift

    case "$BOSH_LANG:$key" in
        es:welcome)     printf 'Bosh Terminal %s\n' "$BOSH_VERSION" ;;
        en:welcome)     printf 'Bosh Terminal %s\n' "$BOSH_VERSION" ;;
        es:info)        printf '[INFO] %s\n' "$*" ;;
        en:info)        printf '[INFO] %s\n' "$*" ;;
        es:success)     printf '[OK] %s\n' "$*" ;;
        en:success)     printf '[OK] %s\n' "$*" ;;
        es:warning)     printf '[AVISO] %s\n' "$*" ;;
        en:warning)     printf '[WARNING] %s\n' "$*" ;;
        es:error)       printf '[ERROR] %s\n' "$*" >&2 ;;
        en:error)       printf '[ERROR] %s\n' "$*" >&2 ;;
        es:cancelled)   printf 'Operación cancelada.\n' ;;
        en:cancelled)   printf 'Operation cancelled.\n' ;;
        *)              printf '%s\n' "$*" ;;
    esac
}

# ------------------------------------------------------------
# System detection
# ------------------------------------------------------------

detect_arch_system() {
    if [[ ! -r /etc/os-release ]]; then
        msg error "Cannot read /etc/os-release."
        return 1
    fi

    local os_id=""
    local os_like=""

    # Load distribution metadata safely.
    . /etc/os-release

    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"

    if [[ "$os_id" == "arch" ]]; then
        return 0
    fi

    local item
    for item in $os_like; do
        if [[ "$item" == "arch" ]]; then
            return 0
        fi
    done

    msg error "Unsupported distribution. Arch Linux or an Arch derivative is required."
    return 1
}

# ------------------------------------------------------------
# Command and package checks
# ------------------------------------------------------------

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        msg error "Missing command: $command_name"
        return 1
    fi
}

package_installed() {
    pacman -Q "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------
# User and privilege checks
# ------------------------------------------------------------

require_non_root() {
    if [[ "$EUID" -eq 0 ]]; then
        msg error "Do not run Bosh Terminal as root."
        return 1
    fi
}

# ------------------------------------------------------------
# Safe directory creation
# ------------------------------------------------------------

ensure_directory() {
    local directory="${1:-}"

    if [[ -z "$directory" ]]; then
        msg error "Directory path is empty."
        return 1
    fi

    if [[ -L "$directory" ]]; then
        msg error "Refusing to use a symbolic link as a directory: $directory"
        return 1
    fi

    if [[ -e "$directory" && ! -d "$directory" ]]; then
        msg error "A non-directory file already exists at: $directory"
        return 1
    fi

    mkdir -p -- "$directory" || return 1

    if [[ -L "$directory" || ! -d "$directory" ]]; then
        msg error "Directory path is not a safe directory: $directory"
        return 1
    fi
}

# ------------------------------------------------------------
# Backup utilities
# ------------------------------------------------------------


create_backup() {
    local source_file="$1"
    local relative_path
    local backup_root="${BOSH_BACKUP%/}"
    local destination
    local destination_base
    local backup_parent
    local current_dir
    local timestamp
    local original_mode
    local counter=1

    # Reset the result from any previous backup.
    BOSH_LAST_BACKUP=""
    # shellcheck disable=SC2034
    BOSH_LAST_BACKUP_MODE=""

    if [[ ! -e "$source_file" && ! -L "$source_file" ]]; then
        return 0
    fi

    if [[ -L "$source_file" || ! -f "$source_file" ]]; then
        msg error "Cannot back up a symbolic link or non-regular file: $source_file"
        return 1
    fi

    case "$source_file" in
        /*) ;;
        *)
            msg error "Backup source path must be absolute: $source_file"
            return 1
            ;;
    esac

    case "/$source_file/" in
        */../*)
            msg error "Backup source path contains an unsafe parent component."
            return 1
            ;;
    esac

    case "$backup_root" in
        /*) ;;
        *)
            msg error "Backup directory must be an absolute path: $BOSH_BACKUP"
            return 1
            ;;
    esac

    case "/$backup_root/" in
        */../*)
            msg error "Backup directory contains an unsafe parent component."
            return 1
            ;;
    esac

    if [[ -z "$backup_root" || "$backup_root" == "/" ]]; then
        msg error "Invalid backup directory: $BOSH_BACKUP"
        return 1
    fi

    original_mode="$(stat -c '%a' -- "$source_file" 2>/dev/null)" || {
        msg error "Could not read original file permissions: $source_file"
        return 1
    }
    if [[ ! "$original_mode" =~ ^[0-7]{3,4}$ ]]; then
        msg error "Invalid original file permissions: $source_file"
        return 1
    fi

    relative_path="${source_file#/}"
    destination="$backup_root/$relative_path"
    backup_parent="$(dirname "$destination")"

    # Create new backup directories with a private umask.
    if ! (
        umask 077
        ensure_directory "$backup_root" &&
            ensure_directory "$backup_parent"
    ); then
        return 1
    fi

    # Tighten every directory between the backup root and destination.
    current_dir="$backup_parent"
    while :; do
        if [[ -L "$current_dir" || ! -d "$current_dir" ]]; then
            msg error "Unsafe backup directory: $current_dir"
            return 1
        fi

        chmod 700 -- "$current_dir" || return 1

        [[ "$current_dir" == "$backup_root" ]] && break

        case "$current_dir" in
            "$backup_root"/*) ;;
            *)
                msg error "Backup destination escapes its root."
                return 1
                ;;
        esac

        current_dir="$(dirname "$current_dir")"
    done

    if [[ -e "$destination" || -L "$destination" ]]; then
        timestamp="$(date '+%Y%m%d-%H%M%S')"
        destination_base="${destination}.${timestamp}"
        destination="$destination_base"

        while [[ -e "$destination" || -L "$destination" ]]; do
            destination="${destination_base}.${counter}"
            counter=$((counter + 1))
        done
    fi

    cp -a -- "$source_file" "$destination" || {
        msg error "Backup failed: $source_file"
        return 1
    }

    # Backups may contain private configuration or credentials.
    if ! chmod 600 -- "$destination" ||
       [[ "$(stat -c '%a' -- "$destination" 2>/dev/null)" != "600" ]]; then
        rm -f -- "$destination" || true
        msg error "Could not secure backup permissions: $destination"
        return 1
    fi

    # Expose the exact backup path to the calling function.
    # shellcheck disable=SC2034
   BOSH_LAST_BACKUP="$destination"
    # shellcheck disable=SC2034
    BOSH_LAST_BACKUP_MODE="$original_mode"

    msg success "Backup created: $destination"
}


# ------------------------------------------------------------
# Temporary resource registry
# Only disposable temporary files/directories belong here.
# Rollback copies and user backups must never be registered.
# ------------------------------------------------------------

declare -ag BOSH_TEMP_PATHS=()
declare -ag BOSH_TEMP_TYPES=()

bosh_register_temp() {
    local path="${1:-}"
    local kind="${2:-file}"

    if [[ -z "$path" || ( "$kind" != "file" && "$kind" != "dir" ) ]]; then
        msg error "Invalid temporary resource registration."
        return 1
    fi

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        msg error "Temporary resource does not exist: $path"
        return 1
    fi

    if [[ "$kind" == "dir" && ( -L "$path" || ! -d "$path" ) ]]; then
        msg error "Temporary directory is not a real directory: $path"
        return 1
    fi

    if [[ "$kind" == "file" && ( -L "$path" || ! -f "$path" ) ]]; then
        msg error "Temporary file is not a regular file: $path"
        return 1
    fi

    BOSH_TEMP_PATHS+=("$path")
    BOSH_TEMP_TYPES+=("$kind")
}

bosh_forget_temp() {
    local target="${1:-}"
    local i
    local -a remaining_paths=()
    local -a remaining_types=()

    [[ -n "$target" ]] || return 0

    for ((i = 0; i < ${#BOSH_TEMP_PATHS[@]}; i++)); do
        if [[ "${BOSH_TEMP_PATHS[i]}" != "$target" ]]; then
            remaining_paths+=("${BOSH_TEMP_PATHS[i]}")
            remaining_types+=("${BOSH_TEMP_TYPES[i]}")
        fi
    done

    BOSH_TEMP_PATHS=("${remaining_paths[@]}")
    BOSH_TEMP_TYPES=("${remaining_types[@]}")
}

bosh_remove_temp_file() {
    local path="${1:-}"

    if [[ -z "$path" ]]; then
        msg error "Missing temporary file path."
        return 1
    fi

    if [[ -L "$path" ]]; then
        msg warning "Preserving temporary file path replaced by a symbolic link: $path"
        return 1
    fi

    if [[ -e "$path" && ! -f "$path" ]]; then
        msg warning "Preserving temporary file path replaced by a non-regular file: $path"
        return 1
    fi

    if ! rm -f -- "$path"; then
        msg warning "Could not remove temporary file: $path"
        if [[ -e "$path" || -L "$path" ]]; then
            return 1
        fi
    fi

    if [[ -e "$path" || -L "$path" ]]; then
        msg warning "Temporary file remains after removal: $path"
        return 1
    fi

    bosh_forget_temp "$path"
}

# ------------------------------------------------------------
# Rollback snapshot helpers
# Rollback files are persistent recovery copies, never temp entries.
# ------------------------------------------------------------

bosh_file_sha256() {
    local path="${1:-}"
    local result=""

    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || return 1

    result="$(sha256sum -- "$path")" || return 1
    printf '%s\n' "${result%% *}"
}

bosh_verify_rollback_file() {
    local rollback="${1:-}"
    local expected_hash="${2:-}"
    local actual_hash=""

    if [[ -z "$rollback" ||
          ! "$expected_hash" =~ ^[a-f0-9]{64}$ ||
          -L "$rollback" || ! -f "$rollback" ]]; then
        msg error "Rollback snapshot is missing or invalid: $rollback"
        return 1
    fi

    actual_hash="$(bosh_file_sha256 "$rollback")" || {
        msg error "Could not verify rollback snapshot: $rollback"
        return 1
    }

    if [[ "$actual_hash" != "$expected_hash" ]]; then
        msg error "Rollback snapshot hash mismatch; preserved: $rollback"
        return 1
    fi

    return 0
}

bosh_remove_rollback_file() {
    local rollback="${1:-}"

    [[ -n "$rollback" ]] || return 0

    if [[ -L "$rollback" || ( -e "$rollback" && ! -f "$rollback" ) ]]; then
        msg warning "Rollback path changed; preserving it: $rollback"
        return 1
    fi

    if ! rm -f -- "$rollback" ||
       [[ -e "$rollback" || -L "$rollback" ]]; then
        msg warning "Could not remove rollback snapshot; preserved: $rollback"
        return 1
    fi
}

bosh_remove_file_if_hash_matches() {
    local path="${1:-}"
    local expected_hash="${2:-}"
    local actual_hash=""

    if [[ -z "$path" ||
          ! "$expected_hash" =~ ^[a-f0-9]{64}$ ||
          -L "$path" || ! -f "$path" ]]; then
        msg warning "Refusing to remove an invalid or changed file: $path"
        return 1
    fi

    actual_hash="$(bosh_file_sha256 "$path")" || {
        msg warning "Could not verify file before removal; preserved: $path"
        return 1
    }

    if [[ "$actual_hash" != "$expected_hash" ]]; then
        msg warning "File changed; preserving it: $path"
        return 1
    fi

    if ! rm -f -- "$path" ||
       [[ -e "$path" || -L "$path" ]]; then
        msg warning "Could not remove verified file: $path"
        return 1
    fi

    return 0
}

bosh_restore_rollback_file() {
    local rollback="${1:-}"
    local destination="${2:-}"
    local expected_current="${3:-}"
    local expected_previous="${4:-}"
    local current_hash=""
    local stage=""
    local stage_hash=""

    if [[ -z "$rollback" || -z "$destination" ||
          ! "$expected_current" =~ ^[a-f0-9]{64}$ ||
          ! "$expected_previous" =~ ^[a-f0-9]{64}$ ]]; then
        msg error "Invalid rollback restoration arguments."
        return 1
    fi

    bosh_verify_rollback_file "$rollback" "$expected_previous" || return 1

    if [[ -L "$destination" || ! -f "$destination" ]]; then
        msg warning "Destination changed; rollback preserved: $rollback"
        return 1
    fi

    current_hash="$(bosh_file_sha256 "$destination")" || return 1
    if [[ "$current_hash" != "$expected_current" ]]; then
        msg warning "Destination was modified externally; rollback preserved: $rollback"
        return 1
    fi

    stage="$(mktemp "${destination}.bosh-restore.XXXXXX")" || {
        msg error "Could not create rollback staging file; preserved: $rollback"
        return 1
    }

    if ! bosh_register_temp "$stage" file; then
        bosh_remove_temp_file "$stage" || true
        msg error "Could not register rollback staging file; preserved: $rollback"
        return 1
    fi

    if ! cp -p -- "$rollback" "$stage"; then
        bosh_remove_temp_file "$stage" || true
        msg error "Could not stage rollback snapshot; preserved: $rollback"
        return 1
    fi

    stage_hash="$(bosh_file_sha256 "$stage")" || {
        bosh_remove_temp_file "$stage" || true
        msg error "Could not verify rollback staging file; preserved: $rollback"
        return 1
    }

    if [[ "$stage_hash" != "$expected_previous" ]]; then
        bosh_remove_temp_file "$stage" || true
        msg error "Rollback staging hash mismatch; preserved: $rollback"
        return 1
    fi

    # Recheck immediately before the atomic replacement.
    current_hash="$(bosh_file_sha256 "$destination")" || {
        bosh_remove_temp_file "$stage" || true
        msg warning "Could not recheck destination; rollback preserved: $rollback"
        return 1
    }

    if [[ "$current_hash" != "$expected_current" ]]; then
        bosh_remove_temp_file "$stage" || true
        msg warning "Destination changed before restoration; rollback preserved: $rollback"
        return 1
    fi

    if ! mv -fT -- "$stage" "$destination"; then
        bosh_remove_temp_file "$stage" || true
        msg error "Atomic rollback restoration failed; preserved: $rollback"
        return 1
    fi

    bosh_forget_temp "$stage"

    current_hash="$(bosh_file_sha256 "$destination")" || {
        msg error "Restored destination could not be verified; rollback preserved: $rollback"
        return 1
    }

    if [[ "$current_hash" != "$expected_previous" ]]; then
        msg error "Restored destination hash mismatch; rollback preserved: $rollback"
        return 1
    fi

    bosh_remove_rollback_file "$rollback" || true
    return 0
}

bosh_cleanup_temps() {
    local i path kind keep
    local -a remaining_paths=()
    local -a remaining_types=()

    for ((i = ${#BOSH_TEMP_PATHS[@]} - 1; i >= 0; i--)); do
        path="${BOSH_TEMP_PATHS[i]}"
        kind="${BOSH_TEMP_TYPES[i]}"
        [[ -n "$path" ]] || continue

        keep=0

        case "$kind" in
            file)
                if [[ -L "$path" ]]; then
                    msg warning "Preserving temporary path replaced by a symbolic link: $path"
                elif [[ -f "$path" ]]; then
                    if ! rm -f -- "$path"; then
                        msg warning "Could not remove temporary file: $path"
                    fi

                    if [[ -e "$path" || -L "$path" ]]; then
                        msg warning "Temporary file remains after cleanup: $path"
                        if [[ -f "$path" && ! -L "$path" ]]; then
                            keep=1
                        fi
                    fi
                elif [[ -e "$path" ]]; then
                    msg warning "Preserving temporary path replaced by a non-regular file: $path"
                fi
                ;;
            dir)
                if [[ -L "$path" ]]; then
                    msg warning "Preserving temporary directory path replaced by a symbolic link: $path"
                elif [[ -d "$path" ]]; then
                    if ! rm -rf -- "$path"; then
                        msg warning "Could not remove temporary directory: $path"
                    fi

                    if [[ -e "$path" || -L "$path" ]]; then
                        msg warning "Temporary directory remains after cleanup: $path"
                        if [[ -d "$path" && ! -L "$path" ]]; then
                            keep=1
                        fi
                    fi
                elif [[ -e "$path" ]]; then
                    msg warning "Preserving temporary directory path replaced by a non-directory: $path"
                fi
                ;;
        esac

        if ((keep)); then
            remaining_paths=("$path" "${remaining_paths[@]}")
            remaining_types=("$kind" "${remaining_types[@]}")
        fi
    done

    BOSH_TEMP_PATHS=("${remaining_paths[@]}")
    BOSH_TEMP_TYPES=("${remaining_types[@]}")
}

# ------------------------------------------------------------
# State management
# ------------------------------------------------------------

write_state() {
    local key="${1:-}"
    local value="${2-}"
    local state_file
    local temp_file

    if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        msg error "Invalid state key: $key"
        return 1
    fi

    ensure_directory "$BOSH_STATE" || return 1

    state_file="$BOSH_STATE/$key"

    if [[ -L "$state_file" ]]; then
        msg error "Refusing to overwrite a symbolic link: $state_file"
        return 1
    fi

    if [[ -e "$state_file" && ! -f "$state_file" ]]; then
        msg error "State destination is not a regular file: $state_file"
        return 1
    fi

    temp_file="$(mktemp "$BOSH_STATE/.${key}.tmp.XXXXXX")" || return 1
    bosh_register_temp "$temp_file" file || {
        bosh_remove_temp_file "$temp_file"
        return 1
    }

    if ! printf '%s\n' "$value" > "$temp_file"; then
        bosh_remove_temp_file "$temp_file"
        msg error "Could not write state: $key"
        return 1
    fi

    if ! mv -fT -- "$temp_file" "$state_file"; then
        bosh_remove_temp_file "$temp_file"
        msg error "Could not update state: $key"
        return 1
    fi

    bosh_forget_temp "$temp_file"
}

read_state() {
    local key="${1:-}"
    local state_file

    if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        msg error "Invalid state key: $key"
        return 1
    fi

    if [[ ! -e "$BOSH_STATE" && ! -L "$BOSH_STATE" ]]; then
        return 0
    fi

    if [[ -L "$BOSH_STATE" || ! -d "$BOSH_STATE" ]]; then
        msg error "State path is not a safe directory: $BOSH_STATE"
        return 1
    fi

    state_file="$BOSH_STATE/$key"

    if [[ -L "$state_file" ]]; then
        msg error "Refusing to read a symbolic link: $state_file"
        return 1
    fi

    if [[ -e "$state_file" ]]; then
        if [[ ! -f "$state_file" ]]; then
            msg error "State entry is not a regular file: $state_file"
            return 1
        fi

        cat -- "$state_file"
    fi
}

# Archive an obsolete state record without deleting its contents.
archive_state() {
    local key="${1:-}"
    local state_file=""
    local archive_base=""
    local archive_file=""
    local timestamp=""
    local before_hash=""
    local after_hash=""
    local counter=1


    if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        msg error "Invalid state key to archive: $key"
        return 1
    fi

    if [[ -L "$BOSH_STATE" || ! -d "$BOSH_STATE" ]]; then
        msg error "State path is not a safe directory: $BOSH_STATE"
        return 1
    fi

    state_file="$BOSH_STATE/$key"

    if [[ -L "$state_file" || ! -f "$state_file" ]]; then
        msg error "State record is missing or is not a regular file: $state_file"
        return 1
    fi

    before_hash="$(sha256sum -- "$state_file")" || return 1
    before_hash="${before_hash%% *}"

    timestamp="$(date '+%Y%m%d-%H%M%S')" || return 1
    archive_base="${state_file}.archived-${timestamp}"
    archive_file="$archive_base"

    while [[ -e "$archive_file" || -L "$archive_file" ]]; do
        archive_file="${archive_base}.${counter}"
        counter=$((counter + 1))
    done

    if ! mv -nT -- "$state_file" "$archive_file"; then
        msg error "Could not archive state record: $key"
        return 1
    fi

    if [[ -e "$state_file" || -L "$state_file" ]]; then
        msg error "State record changed during archival; original preserved."
        return 1
    fi

    if [[ -L "$archive_file" || ! -f "$archive_file" ]]; then
        msg error "Archived state record is not a regular file."
        return 1
    fi

    after_hash="$(sha256sum -- "$archive_file")" || {
        if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then
            mv -nT -- "$archive_file" "$state_file" || \
                msg error "Could not restore the state record after verification failure."
        fi
        return 1
    }
    after_hash="${after_hash%% *}"

    if [[ "$after_hash" != "$before_hash" ]]; then
        msg error "Archived state hash does not match the original."

        if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then
            mv -nT -- "$archive_file" "$state_file" || \
                msg error "Could not restore the state record after verification failure."
        fi
        return 1
    fi

   msg info "State record archived and verified: $archive_file"
}

# ------------------------------------------------------------
# Versioned manifest management
# Values containing special characters must be Base64 encoded.
# Manifests are data: never source or evaluate their contents.
# ------------------------------------------------------------

write_manifest() {
    local name="${1:-}"
    local component="${2:-}"
    local field value
    local payload
    local -A seen=()

    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]] ||
       [[ ! "$component" =~ ^[a-z][a-z0-9_]*$ ]]; then
        msg error "Invalid manifest name or component."
        return 1
    fi

    if (( $# < 2 )); then
        msg error "Manifest component is missing."
        return 1
    fi

    shift 2

    if (( $# % 2 != 0 )); then
        msg error "Manifest fields must be supplied as key-value pairs."
        return 1
    fi

    payload="version=1"$'\n'"component=$component"

    while (( $# )); do
        field="$1"
        value="$2"
        shift 2

        if [[ ! "$field" =~ ^[a-z][a-z0-9_]*$ ]] ||
           [[ "$field" == "version" || "$field" == "component" ]]; then
            msg error "Invalid or reserved manifest field: $field"
            return 1
        fi

        if [[ -n "${seen[$field]+present}" ]]; then
            msg error "Duplicate manifest field: $field"
            return 1
        fi

        if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
            msg error "Manifest values must occupy one line: $field"
            return 1
        fi

        seen["$field"]=1
        payload+=$'\n'"$field=$value"
    done

    write_state "${name}_manifest" "$payload"
}

read_manifest() {
    local name="${1:-}"
    local content=""
    local line field value

    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        msg error "Invalid manifest name."
        return 1
    fi

    content="$(read_state "${name}_manifest")" || return 1

    if [[ -z "$content" ]]; then
        msg error "Manifest does not exist or is empty: $name"
        return 1
    fi

    declare -gA BOSH_MANIFEST=()
    BOSH_MANIFEST=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "$line" != *=* ]]; then
            msg error "Malformed manifest entry: $name"
            BOSH_MANIFEST=()
            return 1
        fi

        field="${line%%=*}"
        value="${line#*=}"

        if [[ ! "$field" =~ ^[a-z][a-z0-9_]*$ ]]; then
            msg error "Invalid manifest field: $field"
            BOSH_MANIFEST=()
            return 1
        fi

        if [[ -n "${BOSH_MANIFEST[$field]+present}" ]]; then
            msg error "Duplicate manifest field: $field"
            BOSH_MANIFEST=()
            return 1
        fi

        BOSH_MANIFEST["$field"]="$value"
    done <<< "$content"

    if [[ "${BOSH_MANIFEST[version]:-}" != "1" ||
          ! "${BOSH_MANIFEST[component]:-}" =~ ^[a-z][a-z0-9_]*$ ]]; then
        msg error "Unsupported or incomplete manifest: $name"
        BOSH_MANIFEST=()
        return 1
    fi
}

# ------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------

confirm() {
    local prompt_es="$1"
    local prompt_en="$2"
    local answer=""
    local tty_fd

    if ! { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
        msg error "Interactive confirmation required."
        return 1
    fi

    if [[ "$BOSH_LANG" == "es" ]]; then
        if ! printf '%s [s/N]: ' "$prompt_es" >&"$tty_fd"; then
            exec {tty_fd}>&-
            msg error "Could not write confirmation prompt to terminal."
            return 1
        fi
    else
        if ! printf '%s [y/N]: ' "$prompt_en" >&"$tty_fd"; then
            exec {tty_fd}>&-
            msg error "Could not write confirmation prompt to terminal."
            return 1
        fi
    fi

    if ! IFS= read -r -u "$tty_fd" answer; then
        exec {tty_fd}>&-
        msg error "Could not read confirmation from terminal."
        return 1
    fi

    exec {tty_fd}>&-

    if [[ "$BOSH_LANG" == "es" ]]; then
        [[ "$answer" =~ ^([sS]|[sS][iI])$ ]]
    else
        [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
    fi
}
