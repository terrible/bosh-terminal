#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# Load shared paths, validation, locking and state helpers.
source "$PROJECT_DIR/install.sh"

BOSH_UNINSTALL_REMOVED=0
BOSH_UNINSTALL_RESTORED=0
BOSH_UNINSTALL_ANIME_REMOVED=0
BOSH_UNINSTALL_PRESERVED=0
BOSH_UNINSTALL_ERRORS=0

bosh_uninstall_hash() {
    local result=""
    result="$(sha256sum -- "$1")" || return 1
    printf '%s\n' "${result%% *}"
}

bosh_uninstall_archive() {
    local key="${1:-}"
    archive_state "$key"
}

bosh_uninstall_decode_backup() {
    local encoded="${1:-}"
    local expected_hash="${2:-}"
    local decoded=""
    local canonical=""
    local actual=""

    BOSH_UNINSTALL_BACKUP_PATH=""

    if [[ "$encoded" == "-" ]]; then
        [[ "$expected_hash" == "-" ]]
        return
    fi

    [[ "$encoded" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || return 1
    [[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || return 1

    decoded="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)" || return 1
    canonical="$(printf '%s' "$decoded" | base64 -w 0)" || return 1

    [[ "$canonical" == "$encoded" ]] || return 1
    [[ "$decoded" == "$BOSH_BACKUP/"* ]] || return 1
    [[ ! -L "$BOSH_BACKUP" && -d "$BOSH_BACKUP" ]] || return 1
    [[ ! -L "$decoded" && -f "$decoded" ]] || return 1

    actual="$(bosh_uninstall_hash "$decoded")" || return 1
    [[ "$actual" == "$expected_hash" ]] || return 1

    BOSH_UNINSTALL_BACKUP_PATH="$decoded"
}


# Validate every existing directory component without following symlinks.
bosh_uninstall_safe_directory() {
    local path="${1:-}"
    local current="/"
    local part
    local -a parts=()

    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    IFS='/' read -r -a parts <<< "${path#/}"

    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$part" != "." && "$part" != ".." ]] || return 1
        current="${current%/}/$part"
        [[ ! -L "$current" && -d "$current" ]] || return 1
    done
}

# Validate existing path components without requiring the final directory
# to exist. Reject symlinks and non-directory components at every level.
bosh_uninstall_safe_path_components() {
    local path="${1:-}"
    local current="/"
    local part
    local -a parts=()

    [[ "$path" == /* &&
       "$path" != *$'\n'* &&
       "$path" != *$'\r'* ]] || return 1

    IFS='/' read -r -a parts <<< "${path#/}"

    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$part" != "." && "$part" != ".." ]] || return 1

        current="${current%/}/$part"

        [[ ! -L "$current" ]] || return 1

        if [[ -e "$current" && ! -d "$current" ]]; then
            return 1
        fi
    done
}

# Never let a manifest choose an arbitrary destination.
bosh_uninstall_managed_destination() {
    case "${1:-}" in
        zsh_config)      printf '%s\n' "$BOSH_HOME/zshrc" ;;
        starship)        printf '%s\n' "$BOSH_HOME/starship.toml" ;;
        fastfetch)       printf '%s\n' "$BOSH_HOME/fastfetch.jsonc" ;;
        konsole_profile) printf '%s\n' "$KONSOLE_DIR/bosh.profile" ;;
        konsole_scheme)  printf '%s\n' "$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme" ;;
        *) return 1 ;;
    esac
}

bosh_uninstall_validate_managed_manifest() {
    local key="${1:-}"
    local destination="${2:-}"
    local encoded=""
    local decoded=""
    local canonical=""
    local backup_encoded=""
    local backup_hash=""
    local original_mode=""

    read_manifest "$key" || return 1

    (( ${#BOSH_MANIFEST[@]} == 7 || ${#BOSH_MANIFEST[@]} == 8 )) || return 1
    [[ "${BOSH_MANIFEST[version]:-}" == "1" ]] || return 1
    [[ "${BOSH_MANIFEST[component]:-}" == "managed_file" ]] || return 1
    [[ "${BOSH_MANIFEST[sha256]:-}" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "${BOSH_MANIFEST[preexisting]:-}" =~ ^[01]$ ]] || return 1
    [[ -n "${BOSH_MANIFEST[destination_b64]:-}" ]] || return 1
    [[ -n "${BOSH_MANIFEST[backup_path_b64]:-}" ]] || return 1
    [[ -n "${BOSH_MANIFEST[backup_sha256]:-}" ]] || return 1

    encoded="${BOSH_MANIFEST[destination_b64]}"
    [[ "$encoded" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || return 1

    decoded="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)" || return 1
    canonical="$(printf '%s' "$decoded" | base64 -w 0)" || return 1
    [[ "$canonical" == "$encoded" && "$decoded" == "$destination" ]] || return 1

    backup_encoded="${BOSH_MANIFEST[backup_path_b64]}"
    backup_hash="${BOSH_MANIFEST[backup_sha256]}"

    if (( ${#BOSH_MANIFEST[@]} == 8 )); then
        original_mode="${BOSH_MANIFEST[original_mode]:-}"

        if [[ "$backup_encoded" == "-" ]]; then
            [[ "$backup_hash" == "-" && "$original_mode" == "-" ]] || return 1
        else
            [[ "$original_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        fi
    fi

    if [[ "$backup_encoded" == "-" ]]; then
        [[ "$backup_hash" == "-" ]] || return 1
        BOSH_UNINSTALL_BACKUP_PATH=""
    else
        [[ "${BOSH_MANIFEST[preexisting]}" == "1" ]] || return 1
        [[ "$backup_hash" =~ ^[a-f0-9]{64}$ ]] || return 1

        bosh_uninstall_decode_backup "$backup_encoded" "$backup_hash" || return 1
        bosh_uninstall_safe_directory \
            "$(dirname -- "$BOSH_UNINSTALL_BACKUP_PATH")" || return 1
    fi
}

bosh_uninstall_process_managed_file() {
    local key="${1:-}"
    local destination=""
    local manifest_file=""
    local expected_hash=""
    local preexisting=""
    local backup_path=""
    local current_hash=""
    local parent=""
    local stage=""
    local original_mode=""
    local expected_mode=""
    local actual_mode=""

    destination="$(bosh_uninstall_managed_destination "$key")" || {
        msg error "Unknown managed-file key: $key"
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    }

    manifest_file="$BOSH_STATE/${key}_manifest"

    # Reconcile a killed installation BEFORE interpreting an absent manifest.
    # Ambiguous transactions are preserved and block this component removal.
    if ! bosh_managed_txn_recover "$key" "$destination"; then
        msg warning "Pending managed-file transaction requires attention: $key"
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    [[ -e "$manifest_file" || -L "$manifest_file" ]] || return 0

    if ! bosh_uninstall_safe_directory "$BOSH_STATE" ||
       [[ -L "$manifest_file" || ! -f "$manifest_file" ]]; then
        msg warning "Unsafe manifest preserved: $manifest_file"
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    if ! bosh_uninstall_validate_managed_manifest "$key" "$destination"; then
        msg warning "Invalid or unsupported manifest preserved: $manifest_file"
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    expected_hash="${BOSH_MANIFEST[sha256]}"
    preexisting="${BOSH_MANIFEST[preexisting]}"
    backup_path="$BOSH_UNINSTALL_BACKUP_PATH"
    original_mode="${BOSH_MANIFEST[original_mode]:-}"
    parent="$(dirname -- "$destination")"

    if ! bosh_uninstall_safe_directory "$parent"; then
        msg warning "Unsafe destination directory preserved: $parent"
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    if [[ "$preexisting" == "1" &&
          "${BOSH_MANIFEST[backup_path_b64]}" == "-" ]]; then
        msg info "Pre-existing file without backup preserved: $destination"
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        if [[ "$preexisting" == "1" ]]; then
            msg warning "Original file absent; backup and manifest preserved: $destination"
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            return 0
        fi

        bosh_uninstall_archive "${key}_manifest" || {
            BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
            return 1
        }
        return 0
    fi

    if [[ -L "$destination" || ! -f "$destination" ]]; then
        msg warning "Unsafe destination preserved: $destination"
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    current_hash="$(bosh_uninstall_hash "$destination")" || return 1

    if [[ "$current_hash" != "$expected_hash" ]]; then
        msg warning "Modified managed file preserved: $destination"
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    if [[ "$preexisting" == "0" ]]; then
        bosh_remove_file_if_hash_matches "$destination" "$expected_hash" || {
            BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
            return 1
        }
        BOSH_UNINSTALL_REMOVED=$((BOSH_UNINSTALL_REMOVED + 1))
    else
        stage="$(mktemp --tmpdir="$parent" '.bosh-terminal-uninstall.XXXXXX')" || return 1

        bosh_register_temp "$stage" file || {
            rm -f -- "$stage"
            return 1
        }

        cp -p -- "$backup_path" "$stage" || return 1

        current_hash="$(bosh_uninstall_hash "$stage")" || return 1
        [[ "$current_hash" == "${BOSH_MANIFEST[backup_sha256]}" ]] || return 1

        if [[ -n "$original_mode" && "$original_mode" != "-" ]]; then
            chmod "$original_mode" -- "$stage" || return 1
            printf -v expected_mode '%o' "$((8#$original_mode))" || return 1
            actual_mode="$(stat -c '%a' -- "$stage")" || return 1
            [[ "$actual_mode" == "$expected_mode" ]] || return 1
        fi

        [[ ! -L "$destination" && -f "$destination" ]] || return 1
        current_hash="$(bosh_uninstall_hash "$destination")" || return 1
        [[ "$current_hash" == "$expected_hash" ]] || return 1

        mv -fT -- "$stage" "$destination" || return 1
        bosh_forget_temp "$stage"

        current_hash="$(bosh_uninstall_hash "$destination")" || return 1
        [[ "$current_hash" == "${BOSH_MANIFEST[backup_sha256]}" ]] || return 1

        if [[ -n "$original_mode" && "$original_mode" != "-" ]]; then
            actual_mode="$(stat -c '%a' -- "$destination")" || return 1
            [[ "$actual_mode" == "$expected_mode" ]] || return 1
        fi

        BOSH_UNINSTALL_RESTORED=$((BOSH_UNINSTALL_RESTORED + 1))
    fi

    bosh_uninstall_archive "${key}_manifest" || {
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    }

    return 0
}

bosh_uninstall_process_anime() {
    local manifest_file=""
    local key=""
    local suffix=""
    local filename_b64=""
    local filename=""
    local canonical=""
    local filename_hash=""
    local expected_hash=""
    local actual_hash=""
    local destination_file=""
    local source_file=""
    local candidate_file=""
    local candidate_filename=""
    local candidate_key=""
    local legacy_value=""
    local legacy_matches=0
    local is_legacy=0
    local -a manifest_lines=()
    local -a source_files=()

    if [[ ! -e "$BOSH_STATE" && ! -L "$BOSH_STATE" ]]; then
        return 0
    fi

    if ! bosh_uninstall_safe_directory "$BOSH_STATE"; then
        msg warning "Unsafe state directory; anime manifests preserved."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    # Reconcile crash-consistency journals BEFORE interpreting any image state.
    if ! bosh_anime_txn_recover_all; then
        msg warning "Pending anime image transactions need review; preserving them."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    # Legacy records can only be mapped using unambiguous project assets.
    if bosh_uninstall_safe_directory "$ANIME_SOURCE"; then
        source_files=("$ANIME_SOURCE"/*.png)
    fi

    for manifest_file in "$BOSH_STATE"/anime_*; do
        [[ -e "$manifest_file" || -L "$manifest_file" ]] || continue

        key="${manifest_file##*/}"
        [[ "$key" == *.archived-* ]] && continue
        suffix="${key#anime_}"

        if [[ -L "$manifest_file" || ! -f "$manifest_file" ]]; then
            msg warning "Unsafe anime state record preserved: $key"
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            continue
        fi

        is_legacy=0
        filename=""
        expected_hash=""
        legacy_value=""

        if [[ "$suffix" =~ ^[a-f0-9]{64}$ ]]; then
            # Current format: anime_<sha256(filename)> with four fields.
            manifest_lines=()

            if ! mapfile -t manifest_lines < "$manifest_file"; then
                msg warning "Could not read anime manifest; preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
                continue
            fi

            if (( ${#manifest_lines[@]} != 4 )) ||
               [[ "${manifest_lines[0]:-}" != "version=1" ||
                  "${manifest_lines[1]:-}" != "component=anime_image" ||
                  "${manifest_lines[2]:-}" != filename_b64=* ||
                  ! "${manifest_lines[3]:-}" =~ ^sha256=[a-f0-9]{64}$ ]]; then
                msg warning "Invalid anime manifest preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            fi

            filename_b64="${manifest_lines[2]#filename_b64=}"

            if [[ ! "$filename_b64" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]]; then
                msg warning "Invalid anime filename encoding preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            fi

            filename="$(printf '%s' "$filename_b64" | base64 --decode 2>/dev/null)" || {
                msg warning "Could not decode anime filename; preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            }

            canonical="$(printf '%s' "$filename" | base64 -w 0)" || {
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            }

            if [[ "$canonical" != "$filename_b64" ||
                  ! "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.png$ ]]; then
                msg warning "Unsafe anime filename preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            fi

            filename_hash="$(printf '%s' "$filename" | sha256sum)" || {
                BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            }
            filename_hash="${filename_hash%% *}"

            if [[ "$filename_hash" != "$suffix" ]]; then
                msg warning "Anime manifest key does not match its filename; preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            fi

            expected_hash="${manifest_lines[3]#sha256=}"
        else
            # Legacy format: anime_<filename with dots replaced by underscores>.
            is_legacy=1
            legacy_matches=0
            source_file=""

            for candidate_file in "${source_files[@]}"; do
                [[ ! -L "$candidate_file" && -f "$candidate_file" ]] || continue

                candidate_filename="${candidate_file##*/}"
                candidate_key="anime_${candidate_filename//./_}"

                if [[ "$candidate_key" == "$key" ]]; then
                    legacy_matches=$((legacy_matches + 1))
                    source_file="$candidate_file"
                fi
            done

            if (( legacy_matches != 1 )); then
                msg warning "Unknown or ambiguous legacy anime state preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            fi

            filename="${source_file##*/}"
            legacy_value="$(cat -- "$manifest_file")" || {
                msg warning "Could not read legacy anime state; preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
                continue
            }

            if [[ "$legacy_value" != "1" &&
                  ! "$legacy_value" =~ ^[a-f0-9]{64}$ ]]; then
                msg warning "Invalid legacy anime ownership record preserved: $key"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            fi
        fi

        if ! bosh_uninstall_safe_path_components "$ANIME_DEST"; then
            msg warning "Unsafe anime destination path; preserved: $filename"
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            continue
        fi

        destination_file="$ANIME_DEST/$filename"

        if [[ -L "$destination_file" ]]; then
            msg warning "Anime destination is a symbolic link; preserved: $filename"
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            continue
        fi

        if [[ ! -e "$destination_file" ]]; then
            if bosh_uninstall_archive "$key"; then
                msg info "Anime image already absent; state archived: $filename"
            else
                msg error "Could not archive stale anime state: $key"
                BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
            fi
            continue
        fi

        if [[ ! -f "$destination_file" ]]; then
            msg warning "Anime destination is not a regular file; preserved: $filename"
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            continue
        fi

        actual_hash="$(bosh_uninstall_hash "$destination_file")" || {
            msg warning "Could not verify anime image; preserved: $filename"
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
            continue
        }

        if (( is_legacy )); then
            if [[ "$legacy_value" == "1" ]]; then
                if ! cmp -s -- "$source_file" "$destination_file"; then
                    msg warning "Legacy anime image changed or cannot be verified; preserved: $filename"
                    BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                    continue
                fi
            elif [[ "$actual_hash" != "$legacy_value" ]]; then
                msg warning "Legacy anime image hash changed; preserved: $filename"
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                continue
            fi
        elif [[ "$actual_hash" != "$expected_hash" ]]; then
            msg warning "Anime image was modified outside Bosh Terminal; preserved: $filename"
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            continue
        fi

        if ! bosh_remove_file_if_hash_matches "$destination_file" "$actual_hash"; then
            msg warning "Could not safely remove anime image; preserved: $filename"
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
            continue
        fi

        if ! bosh_uninstall_archive "$key"; then
            msg error "Anime image removed but its state record could not be archived: $key"
            BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
            continue
        fi

        BOSH_UNINSTALL_ANIME_REMOVED=$((BOSH_UNINSTALL_ANIME_REMOVED + 1))
        msg info "Managed anime image removed: $filename"
    done
}

bosh_uninstall_report() {
    printf 'Managed files removed: %s\n' "$BOSH_UNINSTALL_REMOVED"
    printf 'Anime images removed: %s\n' "$BOSH_UNINSTALL_ANIME_REMOVED"
    printf 'Original files restored: %s\n' "$BOSH_UNINSTALL_RESTORED"
    printf 'Files preserved: %s\n' "$BOSH_UNINSTALL_PRESERVED"
    printf 'Oh My Zsh: preserved (not removed)\n'
    printf 'System packages: not uninstalled\n'
    printf 'Errors: %s\n' "$BOSH_UNINSTALL_ERRORS"
}


# Remove exactly the one LF inserted before an appended Bosh block.
# This preserves the original final-newline state, including files that
# originally did not end with LF.
bosh_uninstall_remove_appended_separator() {
    local stage="${1:-}"
    local separator_offset="${2:-}"
    local separator_byte=""
    local trimmed=""

    [[ -f "$stage" && ! -L "$stage" ]] || return 1
    [[ "$separator_offset" =~ ^[0-9]+$ ]] || return 1

    separator_byte="$(
        od -An -tu1 -j "$separator_offset" -N 1 -- "$stage" | tr -d '[:space:]'
    )" || return 1

    [[ "$separator_byte" == "10" ]] || return 1

    trimmed="$(mktemp "$(dirname -- "$stage")/.bosh-terminal-uninstall-trim.XXXXXX")" || return 1

    bosh_register_temp "$trimmed" file || {
        bosh_remove_temp_file "$trimmed" || true
        return 1
    }

    if (( separator_offset > 0 )); then
        head -c "$separator_offset" -- "$stage" > "$trimmed" || {
            bosh_remove_temp_file "$trimmed" || true
            return 1
        }
    fi

    tail -c "+$((separator_offset + 2))" -- "$stage" >> "$trimmed" || {
        bosh_remove_temp_file "$trimmed" || true
        return 1
    }

    chmod --reference="$stage" -- "$trimmed" || {
        bosh_remove_temp_file "$trimmed" || true
        return 1
    }

    mv -fT -- "$trimmed" "$stage" || {
        bosh_remove_temp_file "$trimmed" || true
        return 1
    }

    bosh_forget_temp "$trimmed"
}
bosh_uninstall_process_zsh() {
    local zshrc="$HOME/.zshrc"
    local manifest_file="$BOSH_STATE/zshrc_manifest"
    local start_marker="# >>> Bosh Terminal >>>"
    local end_marker="# <<< Bosh Terminal <<<"
    local mode=""
    local expected_hash=""
    local actual_hash=""
    local current_hash=""
    local backup_path=""
    local backup_hash=""
    local stage=""
    local original_mode=""
    local expected_mode=""
    local actual_mode=""
    local marker_position=""
    local marker_offset=""
    local separator_offset=""
    local zsh_uninstall_next_hash=""
    local zsh_uninstall_manifest_hash=""
    local start_count=0
    local end_count=0

    # First reconcile any incomplete uninstallation or installation.
    if ! bosh_zsh_uninstall_txn_recover; then
        msg warning "Pending Zsh uninstallation requires manual inspection."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    # A killed installer may have written the manifest but not yet .zshrc.
    # Never interpret that partial state as a completed integration.
    if ! bosh_zsh_txn_recover; then
        msg warning "Pending Zsh integration requires manual inspection."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    fi

    if [[ ! -e "$manifest_file" && ! -L "$manifest_file" ]]; then
        return 0
    fi

    if [[ -L "$manifest_file" || ! -f "$manifest_file" ]] ||
       ! bosh_uninstall_safe_directory "$BOSH_STATE" ||
       ! bosh_uninstall_safe_directory "$HOME"; then
        msg warning "Unsafe Zsh state or HOME path; preserving Zsh integration."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    if ! read_manifest zshrc; then
        msg warning "Invalid Zsh manifest; preserving it and .zshrc."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    if (( ${#BOSH_MANIFEST[@]} != 6 && ${#BOSH_MANIFEST[@]} != 7 )) ||
       [[ "${BOSH_MANIFEST[version]:-}" != "1" ||
          "${BOSH_MANIFEST[component]:-}" != "zsh_integration" ]]; then
        msg warning "Unsupported Zsh manifest schema; preserving it."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    mode="${BOSH_MANIFEST[mode]:-}"
    expected_hash="${BOSH_MANIFEST[block_sha256]:-}"
    backup_hash="${BOSH_MANIFEST[backup_sha256]:-}"

    if [[ ! "$mode" =~ ^(created|appended|legacy_replaced)$ ||
          ! "$expected_hash" =~ ^[a-f0-9]{64}$ ]]; then
        msg warning "Invalid Zsh manifest metadata; preserving it."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    if (( ${#BOSH_MANIFEST[@]} == 7 )); then
        original_mode="${BOSH_MANIFEST[original_mode]:-}"

        if [[ "${BOSH_MANIFEST[backup_path_b64]:-}" == "-" ]]; then
            if [[ "$mode" != "created" || "$backup_hash" != "-" || "$original_mode" != "-" ]]; then
                msg warning "Inconsistent Zsh original-mode metadata; preserving it."
                BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
                return 0
            fi
        elif [[ "$mode" == "created" || ! "$original_mode" =~ ^[0-7]{3,4}$ ]]; then
            msg warning "Invalid Zsh original-mode metadata; preserving it."
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            return 0
        fi
    fi

    if [[ "${BOSH_MANIFEST[backup_path_b64]:-}" == "-" ]]; then
        if [[ "$mode" != "created" || "$backup_hash" != "-" ]]; then
            msg warning "Inconsistent Zsh backup metadata; preserving it."
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            return 0
        fi
    else
        if ! bosh_uninstall_decode_backup \
            "${BOSH_MANIFEST[backup_path_b64]:-}" "$backup_hash"; then
            msg warning "Zsh backup is invalid; preserving .zshrc and its manifest."
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            return 0
        fi
        backup_path="$BOSH_UNINSTALL_BACKUP_PATH"

        if ! bosh_uninstall_safe_directory "$(dirname -- "$backup_path")"; then
            msg warning "Unsafe Zsh backup directory; preserving integration."
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            return 0
        fi
    fi

    if [[ ! -e "$zshrc" && ! -L "$zshrc" ]]; then
        msg info ".zshrc is already absent; archiving its state record."
        bosh_uninstall_archive zshrc_manifest || {
            BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
            return 1
        }
        return 0
    fi

    if [[ -L "$zshrc" || ! -f "$zshrc" ]]; then
        msg warning ".zshrc is not a regular file; preserving it."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    start_count="$(grep -Fxc -- "$start_marker" "$zshrc" || true)"
    end_count="$(grep -Fxc -- "$end_marker" "$zshrc" || true)"

    if (( start_count != 1 || end_count != 1 )); then
        msg warning "Missing or duplicated Zsh markers; preserving .zshrc."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    actual_hash="$(
        sed -n \
            -e "/^${start_marker}$/,/^${end_marker}$/p" \
            "$zshrc" | sha256sum
    )" || return 1
    actual_hash="${actual_hash%% *}"

    if [[ "$actual_hash" != "$expected_hash" ]]; then
        msg warning "Bosh block was edited; preserving .zshrc and manifest."
        BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
        return 0
    fi

    current_hash="$(bosh_uninstall_hash "$zshrc")" || return 1

    if [[ "$mode" == "legacy_replaced" ]]; then
        if [[ -z "$backup_path" || "$current_hash" != "$expected_hash" ]]; then
            msg warning "Legacy-replaced .zshrc contains other content; preserving it."
            BOSH_UNINSTALL_PRESERVED=$((BOSH_UNINSTALL_PRESERVED + 1))
            return 0
        fi

        stage="$(mktemp "$HOME/.zshrc.bosh-uninstall.XXXXXX")" || return 1
        bosh_register_temp "$stage" file || {
            rm -f -- "$stage"
            return 1
        }

        cp -p -- "$backup_path" "$stage" || return 1
        actual_hash="$(bosh_uninstall_hash "$stage")" || return 1
        [[ "$actual_hash" == "$backup_hash" ]] || return 1

        if [[ -n "$original_mode" && "$original_mode" != "-" ]]; then
            chmod "$original_mode" -- "$stage" || return 1
            printf -v expected_mode '%o' "$((8#$original_mode))" || return 1
            actual_mode="$(stat -c '%a' -- "$stage")" || return 1
            [[ "$actual_mode" == "$expected_mode" ]] || return 1
        fi

        [[ ! -L "$zshrc" && -f "$zshrc" ]] || return 1
        current_hash="$(bosh_uninstall_hash "$zshrc")" || return 1
        [[ "$current_hash" == "$expected_hash" ]] || return 1

        zsh_uninstall_manifest_hash="$(bosh_zsh_txn_hash "$manifest_file")" || return 1
        bosh_zsh_uninstall_txn_prepare \
            "$mode" "$current_hash" "$backup_hash" \
            "$zsh_uninstall_manifest_hash" || return 1

        mv -fT -- "$stage" "$zshrc" || return 1
        bosh_forget_temp "$stage"

        actual_hash="$(bosh_uninstall_hash "$zshrc")" || return 1
        [[ "$actual_hash" == "$backup_hash" ]] || return 1

        if [[ -n "$original_mode" && "$original_mode" != "-" ]]; then
            actual_mode="$(stat -c '%a' -- "$zshrc")" || return 1
            [[ "$actual_mode" == "$expected_mode" ]] || return 1
        fi

        BOSH_UNINSTALL_RESTORED=$((BOSH_UNINSTALL_RESTORED + 1))
    else
        stage="$(mktemp "$HOME/.zshrc.bosh-uninstall.XXXXXX")" || return 1
        bosh_register_temp "$stage" file || {
            rm -f -- "$stage"
            return 1
        }

        cp -a -- "$zshrc" "$stage" || return 1

        if [[ "$mode" == "appended" ]]; then
            marker_position="$(grep -aobF -m 1 -- "$start_marker" "$stage")" || return 1
            marker_offset="${marker_position%%:*}"
            [[ "$marker_offset" =~ ^[0-9]+$ ]] || return 1
            if (( marker_offset > 0 )); then
                separator_offset=$((marker_offset - 1))
            fi
        fi

        sed -i \
            -e "/^${start_marker}$/,/^${end_marker}$/d" \
            "$stage" || return 1

        if [[ "$mode" == "appended" && -n "$separator_offset" ]]; then
            bosh_uninstall_remove_appended_separator "$stage" "$separator_offset" || return 1
        fi

        [[ ! -L "$zshrc" && -f "$zshrc" ]] || return 1
        actual_hash="$(bosh_uninstall_hash "$zshrc")" || return 1
        [[ "$actual_hash" == "$current_hash" ]] || return 1

        if [[ "$mode" == "created" && ! -s "$stage" ]]; then
            zsh_uninstall_next_hash="-"
        else
            zsh_uninstall_next_hash="$(bosh_zsh_txn_hash "$stage")" || return 1
        fi
        zsh_uninstall_manifest_hash="$(bosh_zsh_txn_hash "$manifest_file")" || return 1
        bosh_zsh_uninstall_txn_prepare \
            "$mode" "$current_hash" "$zsh_uninstall_next_hash" \
            "$zsh_uninstall_manifest_hash" || return 1

        if [[ "$mode" == "created" && ! -s "$stage" ]]; then
            bosh_remove_file_if_hash_matches "$zshrc" "$current_hash" || return 1
            bosh_forget_temp "$stage"
            rm -f -- "$stage"
        else
            mv -fT -- "$stage" "$zshrc" || return 1
            bosh_forget_temp "$stage"
        fi

        BOSH_UNINSTALL_REMOVED=$((BOSH_UNINSTALL_REMOVED + 1))
    fi

    bosh_zsh_uninstall_txn_recover || {
        BOSH_UNINSTALL_ERRORS=$((BOSH_UNINSTALL_ERRORS + 1))
        return 1
    }

    return 0
}

main() {
    local status=0
    local key=""

    acquire_install_lock || return 1
    setup_install_traps

    # Recover any interrupted first-time OMZ publication before other writes.
    bosh_omz_txn_recover || return 1
    bosh_anime_txn_recover_all || return 1

    for key in \
        zsh_config \
        starship \
        fastfetch \
        konsole_profile \
        konsole_scheme
    do
        if ! bosh_uninstall_process_managed_file "$key"; then
            status=1
        fi
    done

    if ! bosh_uninstall_process_anime; then
        status=1
    fi

    if ! bosh_uninstall_process_zsh; then
        status=1
    fi

    printf '\n'
    bosh_uninstall_report

    if (( BOSH_UNINSTALL_ERRORS > 0 )); then
        status=1
    fi

    if (( status == 0 )); then
        msg success "Bosh Terminal managed files have been processed."
    else
        msg warning "Uninstallation finished with errors; review preserved files."
    fi

    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
