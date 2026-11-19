#!/usr/bin/env bash
# ============================================================
# Bosh Terminal - Installer
# Version: 0.1.0
# Supported: Arch Linux and Arch-based distributions
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# Load common library
# ------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

source "$PROJECT_DIR/scripts/lib/common.sh"
source "$PROJECT_DIR/scripts/lib/managed-transaction.sh"
source "$PROJECT_DIR/scripts/lib/zsh-transaction.sh"
source "$PROJECT_DIR/scripts/lib/omz-transaction.sh"
source "$PROJECT_DIR/scripts/lib/anime-transaction.sh"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

ANIME_SOURCE="$PROJECT_DIR/assets/anime"

ANIME_DEST="$DATA_HOME/fastfetch/anime"
KONSOLE_DIR="$DATA_HOME/konsole"

ZSH_CONFIG="$PROJECT_DIR/config/zsh/zshrc.candidate"
STARSHIP_CONFIG="$PROJECT_DIR/config/starship/starship.toml.candidate"
FASTFETCH_CONFIG="$PROJECT_DIR/config/fastfetch/config.jsonc.candidate"
KONSOLE_PROFILE="$PROJECT_DIR/config/konsole/bosh.profile.candidate"
KONSOLE_SCHEME="$PROJECT_DIR/config/konsole/Utterly-Sweet-Konsole.colorscheme.candidate"

# ------------------------------------------------------------
# Package dependencies
# ------------------------------------------------------------

PACKAGES=(
    zsh
    starship
    fastfetch
    chafa
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
    git
)

# ------------------------------------------------------------
BOSH_SYSTEM_UPGRADED=0

# Language helper
# ------------------------------------------------------------

say() {
    if [[ "$BOSH_LANG" == "es" ]]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "$2"
    fi
}

# ------------------------------------------------------------
# Installation lock and exit cleanup
# ------------------------------------------------------------

BOSH_LOCK_FD=""

acquire_install_lock() {
    local lock_file="$BOSH_STATE/install.lock"
    local saved_umask=""

    require_command flock || return 1
    ensure_directory "$BOSH_STATE" || return 1

    if [[ -L "$lock_file" || ( -e "$lock_file" && ! -f "$lock_file" ) ]]; then
        msg error "Installation lock path is not a regular file."
        return 1
    fi

    saved_umask="$(umask)" || return 1
    umask 077

    if ! exec {BOSH_LOCK_FD}>>"$lock_file"; then
        umask "$saved_umask"
        BOSH_LOCK_FD=""
        msg error "Could not open the installation lock file."
        return 1
    fi

    umask "$saved_umask"

    if ! flock -n "$BOSH_LOCK_FD"; then
        exec {BOSH_LOCK_FD}>&-
        BOSH_LOCK_FD=""
        msg error "Another Bosh Terminal installation is already running."
        return 1
    fi

    msg info "Exclusive installation lock acquired."
}

bosh_install_exit_cleanup() {
    local exit_status=$?

    trap - EXIT
    trap - HUP INT TERM

    bosh_cleanup_temps || true

    if [[ -n "${BOSH_LOCK_FD:-}" ]]; then
        flock -u "$BOSH_LOCK_FD" 2>/dev/null || true
        exec {BOSH_LOCK_FD}>&-
        BOSH_LOCK_FD=""
    fi

    exit "$exit_status"
}

setup_install_traps() {
    trap 'bosh_install_exit_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# ------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------

preflight() {
    msg welcome

    require_non_root || return 1

    local command_name
    for command_name in pacman flock git tar base64 awk cmp sha256sum; do
        require_command "$command_name" || return 1
    done

    detect_arch_system || return 1

    local zshrc="$HOME/.zshrc"

    if [[ -L "$zshrc" || ( -e "$zshrc" && ! -f "$zshrc" ) ]]; then
        msg error "Zsh configuration destination is not a safe regular file: $zshrc"
        return 1
    fi

    local file
    local asset
    local -a anime_files=()

    for file in \
        "$ZSH_CONFIG" \
        "$STARSHIP_CONFIG" \
        "$FASTFETCH_CONFIG"
    do
        if [[ -L "$file" || ! -f "$file" ]]; then
            msg error "Required project file is not a regular file: $file"
            return 1
        fi
    done

    if [[ -L "$ANIME_SOURCE" || ! -d "$ANIME_SOURCE" ]]; then
        msg error "Anime asset path is not a real directory."
        return 1
    fi

    local nullglob_was_set=0

    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    anime_files=("$ANIME_SOURCE"/*.png)

    if (( ! nullglob_was_set )); then
        shopt -u nullglob
    fi

    if (( ${#anime_files[@]} == 0 )); then
        msg error "No anime PNG images found."
        return 1
    fi

    for asset in "${anime_files[@]}"; do
        if [[ -L "$asset" || ! -f "$asset" ]]; then
            msg error "Anime asset is not a regular file: $asset"
            return 1
        fi
    done

    if [[ -L "$KONSOLE_PROFILE" || ! -f "$KONSOLE_PROFILE" ||
          -L "$KONSOLE_SCHEME" || ! -f "$KONSOLE_SCHEME" ]]; then
        msg warning "Konsole configuration files are incomplete. Konsole integration will be skipped."
    fi

    msg success "Preflight checks passed."
}

# ------------------------------------------------------------
# Install missing packages
# ------------------------------------------------------------

install_dependencies() {
    local missing=()
    local package

    for package in "${PACKAGES[@]}"; do
        if ! package_installed "$package"; then
            missing+=("$package")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        msg success "All required dependencies are already installed."
        return 0
    fi

    msg info "Missing packages: ${missing[*]}"
    say \
        "Se actualizará el sistema y se instalarán los paquetes faltantes." \
        "The system will be upgraded and the missing packages will be installed."

    if ! confirm \
        "¿Continuar con la actualización e instalación?" \
        "Continue with the system upgrade and installation?"; then
        msg info "Dependency installation cancelled."
        return 1
    fi

    require_command sudo || return 1
    sudo pacman -Syu --needed "${missing[@]}" || return 1
    BOSH_SYSTEM_UPGRADED=1

    for package in "${missing[@]}"; do
        if ! package_installed "$package"; then
            msg error "Package installation could not be verified: $package"
            return 1
        fi
    done

    for package in "${missing[@]}"; do
        write_state "package_$package" "1" || return 1
    done
}

# ------------------------------------------------------------
# Optional Konsole component
# ------------------------------------------------------------

install_konsole_component() {
    local missing=()
    local package

    if [[ -L "$KONSOLE_PROFILE" || ! -f "$KONSOLE_PROFILE" ||
          -L "$KONSOLE_SCHEME" || ! -f "$KONSOLE_SCHEME" ]]; then
        msg warning "Konsole configuration files are unavailable or invalid. Skipping."
        return 0
    fi

    if ! package_installed konsole; then
        missing+=(konsole)
    fi

    if ! package_installed ttf-hack; then
        missing+=(ttf-hack)
    fi

    if (( ${#missing[@]} )); then
        say \
            "Componente visual opcional: Konsole y fuente Hack." \
            "Optional visual component: Konsole and Hack font."
        say \
            "Se actualizará el sistema para instalar los paquetes faltantes." \
            "The system will be upgraded to install the missing packages."

        if ! confirm \
            "¿Continuar con la actualización e instalación de Konsole?" \
            "Continue with the system upgrade and Konsole installation?"; then
            msg info "Konsole component skipped."
            return 0
        fi

        require_command sudo || return 1
        if (( BOSH_SYSTEM_UPGRADED )); then
            sudo pacman -S --needed "${missing[@]}" || return 1
        else
            sudo pacman -Syu --needed "${missing[@]}" || return 1
            BOSH_SYSTEM_UPGRADED=1
        fi

        for package in "${missing[@]}"; do
            if ! package_installed "$package"; then
                msg error "Package installation could not be verified: $package"
                return 1
            fi
        done

        for package in "${missing[@]}"; do
            write_state "package_$package" "1" || return 1
        done
    fi

    install_managed_file_or_skip \
        "$KONSOLE_PROFILE" \
        "$KONSOLE_DIR/bosh.profile" "konsole_profile" || return 1

    install_managed_file_or_skip \
        "$KONSOLE_SCHEME" \
        "$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme" "konsole_scheme" || return 1

    msg success "Konsole configuration processing completed."
}

# ------------------------------------------------------------
# Install Oh My Zsh
# ------------------------------------------------------------

# Validate and migrate an existing positional Oh My Zsh manifest.
migrate_oh_my_zsh_manifest() {
    local manifest_file="$BOSH_STATE/oh_my_zsh_manifest"
    local omz_dir="$HOME/.oh-my-zsh"
    local expected_remote="https://github.com/ohmyzsh/ohmyzsh.git"
    local expected_commit=""
    local expected_tree_hash=""
    local actual_remote=""
    local actual_commit=""
    local versioned=0
    local -a legacy=()

    if [[ ! -e "$manifest_file" && ! -L "$manifest_file" ]]; then
        return 0
    fi

    if [[ -L "$BOSH_STATE" || ! -d "$BOSH_STATE" ||
          -L "$manifest_file" || ! -f "$manifest_file" ]]; then
        msg error "Oh My Zsh state record is not a safe regular file."
        return 1
    fi

    mapfile -t legacy < "$manifest_file" || return 1

    if [[ "${legacy[0]:-}" == "version=1" ]]; then
        read_manifest oh_my_zsh || return 1

        if (( ${#BOSH_MANIFEST[@]} != 6 )) ||
           [[ "${BOSH_MANIFEST[component]:-}" != "oh_my_zsh" ||
              "${BOSH_MANIFEST[ownership]:-}" != "created" ||
              ! "${BOSH_MANIFEST[commit]:-}" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ||
              "${BOSH_MANIFEST[remote]:-}" != "$expected_remote" ||
              ! "${BOSH_MANIFEST[tree_sha256]:-}" =~ ^[a-f0-9]{64}$ ]]; then
            msg error "Oh My Zsh versioned manifest has an invalid schema."
            return 1
        fi

        versioned=1
        expected_commit="${BOSH_MANIFEST[commit]}"
        expected_tree_hash="${BOSH_MANIFEST[tree_sha256]}"
    else
        if (( ${#legacy[@]} != 4 )) ||
           [[ "${legacy[0]:-}" != "created" ||
              ! "${legacy[1]:-}" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ||
              "${legacy[2]:-}" != "$expected_remote" ||
              ! "${legacy[3]:-}" =~ ^[a-f0-9]{64}$ ]]; then
            msg error "Legacy Oh My Zsh manifest is invalid; preserving it."
            return 1
        fi

        expected_commit="${legacy[1]}"
        expected_tree_hash="${legacy[3]}"
    fi

    require_command git || return 1

    actual_remote="$(git -C "$omz_dir" config --get remote.origin.url)" || {
        msg error "Could not verify the existing Oh My Zsh repository origin."
        return 1
    }

    actual_commit="$(git -C "$omz_dir" rev-parse --verify HEAD)" || {
        msg error "Could not verify the existing Oh My Zsh commit."
        return 1
    }

    if [[ "$actual_remote" != "$expected_remote" ]]; then
        msg error "Oh My Zsh manifest does not match the installed repository origin."
        msg warning "The installation and state record have been preserved."
        return 1
    fi

    if [[ ! "$actual_commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]]; then
        msg error "The installed Oh My Zsh commit has an invalid format."
        return 1
    fi

    if [[ "$actual_commit" != "$expected_commit" ]]; then
        msg warning "Oh My Zsh commit changed on the official repository; updating the recorded commit."

        if ! write_manifest oh_my_zsh oh_my_zsh ownership "created" commit "$actual_commit" remote "$actual_remote" tree_sha256 "$expected_tree_hash"; then
            msg error "Could not update the Oh My Zsh commit record."
            return 1
        fi

        msg info "Oh My Zsh commit record updated; local customizations preserved."
        return 0
    fi

    if (( versioned )); then
        msg info "Existing Oh My Zsh repository verified; local customizations preserved."
        return 0
    fi

    write_manifest oh_my_zsh oh_my_zsh \
        ownership "created" \
        commit "$actual_commit" \
        remote "$actual_remote" \
        tree_sha256 "$expected_tree_hash" || {
        msg error "Could not migrate the Oh My Zsh manifest."
        return 1
    }

    msg success "Legacy Oh My Zsh manifest migrated and repository verified."
}
install_oh_my_zsh() {
    local omz_dir="$HOME/.oh-my-zsh"
    local manifest_file="$BOSH_STATE/oh_my_zsh_manifest"
    local clone_parent=""
    local clone_dir=""
    local remote=""
    local commit=""
    local tree_hash=""

    # Heal a pending first installation before inspecting any directory.
    bosh_omz_txn_recover || return 1

    if [[ -L "$omz_dir" ]]; then
        msg error "Refusing to use a symbolic link at $omz_dir"
        return 1
    fi

    if [[ -e "$omz_dir" ]]; then
        if [[ -d "$omz_dir" && -f "$omz_dir/oh-my-zsh.sh" ]]; then
            migrate_oh_my_zsh_manifest || return 1
            msg info "Existing Oh My Zsh installation preserved."
            return 0
        fi

        msg error "An incompatible path already exists: $omz_dir"
        return 1
    fi

    if [[ -e "$manifest_file" || -L "$manifest_file" ]]; then
        msg warning "Found an orphaned Oh My Zsh state record."
        archive_state "oh_my_zsh_manifest" || return 1
    fi

    require_command git || return 1
    require_command tar || return 1
    ensure_directory "$BOSH_STATE" || return 1

    clone_parent="$(mktemp -d "$HOME/.oh-my-zsh.bosh-tmp.XXXXXX")" || return 1

    bosh_register_temp "$clone_parent" dir || {
        rmdir -- "$clone_parent" 2>/dev/null || true
        return 1
    }

    clone_dir="$clone_parent/repo"

    msg info "Cloning official Oh My Zsh repository."

    if ! git clone --depth 1 \
        https://github.com/ohmyzsh/ohmyzsh.git \
        "$clone_dir"; then
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        msg error "Oh My Zsh clone failed."
        return 1
    fi

    if [[ -L "$clone_dir" || ! -d "$clone_dir" || ! -f "$clone_dir/oh-my-zsh.sh" ]]; then
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        msg error "Cloned Oh My Zsh directory is invalid."
        return 1
    fi

    remote="$(git -C "$clone_dir" config --get remote.origin.url)" || {
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        return 1
    }

    if [[ "$remote" != "https://github.com/ohmyzsh/ohmyzsh.git" ]]; then
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        msg error "Unexpected Oh My Zsh repository origin."
        return 1
    fi

    commit="$(git -C "$clone_dir" rev-parse HEAD)" || {
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        return 1
    }

    tree_hash="$(tar \
        --sort=name \
        --format=gnu \
        --mtime='@0' \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        --exclude='./.git' \
        -cf - -C "$clone_dir" . | sha256sum)" || {
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        msg error "Could not calculate the Oh My Zsh integrity hash."
        return 1
    }
    tree_hash="${tree_hash%% *}"

    # Publish the new clone's identity BEFORE its manifest or directory.
    bosh_omz_txn_prepare "$commit" "$tree_hash" || return 1

    if ! write_manifest "oh_my_zsh" oh_my_zsh \
        ownership "created" \
        commit "$commit" \
        remote "$remote" \
        tree_sha256 "$tree_hash"; then
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        msg error "Could not register the Oh My Zsh installation."
        return 1
    fi

    if [[ -e "$omz_dir" || -L "$omz_dir" ]]; then
        rm -f -- "$manifest_file"
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        msg error "The Oh My Zsh destination appeared during installation."
        return 1
    fi

    if ! mv -Tn -- "$clone_dir" "$omz_dir"; then
        rm -f -- "$manifest_file"
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        return 1
    fi

    if [[ -e "$clone_dir" || -L "$clone_dir" ]]; then
        rm -f -- "$manifest_file"
        if rm -rf -- "$clone_parent"; then
            bosh_forget_temp "$clone_parent"
        fi
        msg error "Oh My Zsh destination was not installed safely."
        return 1
    fi

    if rmdir -- "$clone_parent"; then
        bosh_forget_temp "$clone_parent"
    fi

    # Can also be retried on the next install/uninstall after SIGKILL.
    bosh_omz_txn_recover || return 1
    msg success "Oh My Zsh installed and registered."
}
# ------------------------------------------------------------
# Install managed configuration files
# ------------------------------------------------------------


install_managed_file() {
    local source_file="$1"
    local destination="$2"
    local state_key="${3:-}"
    local manifest_file=""
    local source_hash=""
    local current_hash=""
    local initial_destination_hash=""
    local initial_destination_id="-"
    local initial_destination_fingerprint=""
    local needs_backup=0
    local existed_before=0
    local destination_exists=0
    local manifest_exists=0
    local legacy_manifest=0
    local previous_hash=""
    local backup_path="-"
    local backup_path_b64="-"
    local backup_hash="-"
    local original_mode=""
    local destination_b64=""
    local decoded_path=""
    local canonical_b64=""
    local temp_file=""
    local -a previous=()
    local -a decoded_values=()
    local -a manifest_fields=()
    local pending_manifest=""
    local manifest_index=0

    if [[ ! "$state_key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        msg error "Invalid or missing state key."
        return 1
    fi

    if [[ -L "$source_file" || ! -f "$source_file" ]]; then
        msg error "Source is not a regular file: $source_file"
        return 1
    fi

    ensure_directory "$BOSH_STATE" || return 1
    ensure_directory "$(dirname "$destination")" || return 1
    bosh_managed_txn_recover "$state_key" "$destination" || return 1

    manifest_file="$BOSH_STATE/${state_key}_manifest"

    destination_b64="$(printf '%s' "$destination" | base64 -w 0)" || return 1
    source_hash="$(bosh_managed_txn_hash "$source_file")" || return 1

    if [[ -L "$manifest_file" ]]; then
        msg error "Refusing to read a symbolic link: $manifest_file"
        return 1
    fi

    if [[ -e "$manifest_file" && ! -f "$manifest_file" ]]; then
        msg error "Managed-file manifest is not a regular file: $manifest_file"
        return 1
    fi

    if [[ -f "$manifest_file" ]]; then
        manifest_exists=1
        mapfile -t previous < "$manifest_file" || return 1

        if [[ "${previous[0]:-}" == "version=1" ]]; then
            read_manifest "$state_key" || return 1

            if (( ${#BOSH_MANIFEST[@]} != 7 &&
                  ${#BOSH_MANIFEST[@]} != 8 )) ||
               [[ "${BOSH_MANIFEST[component]:-}" != "managed_file" ]]; then
                msg error "Managed-file manifest has an unexpected schema."
                return 1
            fi

            previous_hash="${BOSH_MANIFEST[sha256]:-}"
            existed_before="${BOSH_MANIFEST[preexisting]:-}"
            backup_path_b64="${BOSH_MANIFEST[backup_path_b64]:-}"
            backup_hash="${BOSH_MANIFEST[backup_sha256]:-}"

            if (( ${#BOSH_MANIFEST[@]} == 8 )); then
                original_mode="${BOSH_MANIFEST[original_mode]:-}"

                if [[ "$backup_path_b64" == "-" ]]; then
                    if [[ "$original_mode" != "-" ]]; then
                        msg error "Managed-file original mode metadata is inconsistent."
                        return 1
                    fi
                elif [[ ! "$original_mode" =~ ^[0-7]{3,4}$ ]]; then
                    msg error "Managed-file original mode is invalid."
                    return 1
                fi
            else
                # Previous schema did not record the original permissions.
                original_mode=""
            fi

            if [[ ! "$previous_hash" =~ ^[a-f0-9]{64}$ ||
                  ! "$existed_before" =~ ^[01]$ ]]; then
                msg error "Managed-file manifest contains invalid ownership data."
                return 1
            fi

            # Decode and verify the destination recorded in the manifest.
            local recorded_destination_b64
            recorded_destination_b64="${BOSH_MANIFEST[destination_b64]:-}"

            if [[ ! "$recorded_destination_b64" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]]; then
                msg error "Invalid destination encoding in managed-file manifest."
                return 1
            fi

            decoded_values=()
            mapfile -d '' -t decoded_values < <(
                printf '%s' "$recorded_destination_b64" | base64 --decode 2>/dev/null
            )

            if (( ${#decoded_values[@]} != 1 )); then
                msg error "Could not decode managed destination."
                return 1
            fi

            decoded_path="${decoded_values[0]}"
            canonical_b64="$(printf '%s' "$decoded_path" | base64 -w 0)" || return 1

            if [[ "$canonical_b64" != "$recorded_destination_b64" ||
                  "$decoded_path" != "$destination" ]]; then
                msg error "Managed-file destination does not match its manifest."
                return 1
            fi

            if [[ "$backup_path_b64" == "-" ]]; then
                backup_path="-"
                if [[ "$backup_hash" != "-" ]]; then
                    msg error "Managed-file backup metadata is inconsistent."
                    return 1
                fi
            else
                if [[ ! "$backup_path_b64" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ||
                      "$existed_before" != "1" ||
                      ! "$backup_hash" =~ ^[a-f0-9]{64}$ ]]; then
                    msg error "Managed-file backup metadata is invalid."
                    return 1
                fi

                decoded_values=()
                mapfile -d '' -t decoded_values < <(
                    printf '%s' "$backup_path_b64" | base64 --decode 2>/dev/null
                )

                if (( ${#decoded_values[@]} != 1 )); then
                    msg error "Could not decode managed-file backup path."
                    return 1
                fi

                backup_path="${decoded_values[0]}"
                canonical_b64="$(printf '%s' "$backup_path" | base64 -w 0)" || return 1

                if [[ "$canonical_b64" != "$backup_path_b64" ||
                      -L "$backup_path" || ! -f "$backup_path" ]]; then
                    msg error "Managed-file backup is missing or invalid."
                    return 1
                fi

                current_hash="$(sha256sum -- "$backup_path")" || return 1
                current_hash="${current_hash%% *}"

                if [[ "$current_hash" != "$backup_hash" ]]; then
                    msg error "Managed-file backup hash does not match."
                    return 1
                fi
            fi
        else
            # Legacy positional manifest: hash, preexisting, backup path, backup hash.
            legacy_manifest=1

            if (( ${#previous[@]} != 4 )) ||
               [[ ! "${previous[0]}" =~ ^[a-f0-9]{64}$ ]] ||
               [[ ! "${previous[1]}" =~ ^[01]$ ]]; then
                msg error "Legacy managed-file manifest is invalid."
                return 1
            fi

            previous_hash="${previous[0]}"
            existed_before="${previous[1]}"
            backup_path="${previous[2]}"
            backup_hash="${previous[3]}"

            if [[ "$backup_path" == "-" ]]; then
                if [[ "$backup_hash" != "-" ]]; then
                    msg error "Legacy backup metadata is inconsistent."
                    return 1
                fi
            else
                if [[ "$existed_before" != "1" ||
                      -L "$backup_path" || ! -f "$backup_path" ||
                      ! "$backup_hash" =~ ^[a-f0-9]{64}$ ]]; then
                    msg error "Legacy backup is missing or invalid."
                    return 1
                fi

                current_hash="$(sha256sum -- "$backup_path")" || return 1
                current_hash="${current_hash%% *}"

                if [[ "$current_hash" != "$backup_hash" ]]; then
                    msg error "Legacy backup hash does not match."
                    return 1
                fi

                backup_path_b64="$(printf '%s' "$backup_path" | base64 -w 0)" || return 1
            fi

            if [[ "$existed_before" == "0" && "$backup_path" != "-" ]]; then
                msg error "Legacy ownership metadata is inconsistent."
                return 1
            fi
        fi
    fi

    if [[ -L "$destination" ]]; then
        msg error "Refusing to overwrite a symbolic link: $destination"
        return 1
    fi

    if [[ -e "$destination" && ! -f "$destination" ]]; then
        msg error "Destination is not a regular file: $destination"
        return 1
    fi

    if [[ -f "$destination" ]]; then
        destination_exists=1
        initial_destination_fingerprint="$(bosh_managed_txn_fingerprint "$destination")" || return 1
        initial_destination_id="${initial_destination_fingerprint%/*}"
        initial_destination_hash="${initial_destination_fingerprint#*/}"
        current_hash="$initial_destination_hash"
    fi

    if (( manifest_exists )); then
        if (( destination_exists )) && [[ "$current_hash" != "$previous_hash" ]]; then
            msg warning "Managed file was modified outside Bosh Terminal; preserving it: $destination"
            msg info "Review and reconcile your local changes before rerunning the installer."
            return 2
        fi

        if (( destination_exists )) && [[ "$current_hash" == "$source_hash" ]]; then
            if (( legacy_manifest )); then
                write_manifest "$state_key" managed_file \
                    sha256 "$previous_hash" \
                    preexisting "$existed_before" \
                    destination_b64 "$destination_b64" \
                    backup_path_b64 "$backup_path_b64" \
                    backup_sha256 "$backup_hash" || return 1

                msg info "Legacy managed-file manifest migrated: $destination"
            else
                msg info "Already up to date: $destination"
            fi
            return 0
        fi

        if (( ! destination_exists )) &&
           [[ "$existed_before" == "1" && "$backup_path" == "-" ]]; then
            msg info "Previously identical pre-existing file was removed; its recreated copy will be managed by Bosh Terminal."
            existed_before=0
        fi

        if (( destination_exists )) &&
           [[ "$existed_before" == "1" && "$backup_path" == "-" ]]; then
            needs_backup=1
        fi
    else
        if (( destination_exists )); then
            existed_before=1

            if [[ "$current_hash" == "$source_hash" ]]; then
                write_manifest "$state_key" managed_file \
                    sha256 "$source_hash" \
                    preexisting "1" \
                    destination_b64 "$destination_b64" \
                    backup_path_b64 "-" \
                    backup_sha256 "-" \
                    original_mode "-" || return 1

                msg info "Existing file already matches: $destination"
                return 0
            fi

            needs_backup=1
        fi
    fi

    if (( destination_exists )); then
        bosh_managed_txn_check_exchange "$destination" || return 1
    fi
    if (( needs_backup )); then
        create_backup "$destination" || return 1
        backup_path="$BOSH_LAST_BACKUP"
        original_mode="$BOSH_LAST_BACKUP_MODE"

        if [[ ! "$original_mode" =~ ^[0-7]{3,4}$ ]]; then
            msg error "Could not capture the original file permissions."
            return 1
        fi

        if [[ -z "$backup_path" || -L "$backup_path" || ! -f "$backup_path" ]]; then
            msg error "Backup path could not be verified."
            return 1
        fi

        backup_hash="$(bosh_managed_txn_hash "$backup_path")" || return 1
        backup_path_b64="$(printf '%s' "$backup_path" | base64 -w 0)" || return 1
        if [[ "$backup_hash" != "$initial_destination_hash" ||
              "$original_mode" != "${initial_destination_id##*:}" ]]; then
            msg error "Destination changed while its backup was being prepared: $destination"
            return 1
        fi
    fi

    # Journal the expected manifest before publication.
    if [[ "$backup_path_b64" == "-" ]]; then
        original_mode="-"
    fi
    manifest_fields=(
        sha256 "$source_hash"
        preexisting "$existed_before"
        destination_b64 "$destination_b64"
        backup_path_b64 "$backup_path_b64"
        backup_sha256 "$backup_hash"
    )
    if [[ -n "$original_mode" ]]; then
        manifest_fields+=(original_mode "$original_mode")
    fi
    pending_manifest="version=1"$'\n'"component=managed_file"
    for ((manifest_index = 0; manifest_index < ${#manifest_fields[@]}; manifest_index += 2)); do
        pending_manifest+=$'\n'"${manifest_fields[manifest_index]}=${manifest_fields[manifest_index+1]}"
    done

    # The candidate is private, persistent transaction data. A successful
    # exchange will leave the displaced inode at that same private path.
    bosh_managed_txn_prepare \
        "$state_key" "$destination" "${initial_destination_hash:--}" \
        "$source_hash" "$pending_manifest" "$initial_destination_id" "$source_file" temp_file || return 1

    if (( destination_exists )); then
        if [[ "$(bosh_managed_txn_fingerprint "$destination")" != "$initial_destination_fingerprint" ]]; then
            msg error "Destination changed before publication; journal preserved: $destination"
            return 1
        fi
        if ! mv --exchange --no-copy -T -- "$temp_file" "$destination"; then
            msg error "Managed publication requires a same-filesystem atomic exchange; journal and slot preserved: ${temp_file%/*}"
            return 1
        fi
    else
        # link(2) publishes only if the destination is absent, including on
        # filesystems where a no-clobber rename may require a userspace check.
        if ! ln -T -- "$temp_file" "$destination"; then
            msg error "Could not create managed destination without overwriting: $destination"
            return 1
        fi
    fi

    bosh_managed_txn_recover "$state_key" "$destination" after || return 1

    if (( existed_before )); then
        msg success "Updated: $destination"
    else
        msg success "Installed: $destination"
    fi
}

# Preserve user-modified files without aborting the whole installation.
# install_managed_file returns 2 only for this intentional skip.
install_managed_file_or_skip() {
    local status=0

    if install_managed_file "$@"; then
        return 0
    else
        status=$?
    fi

    if (( status == 2 )); then
        return 0
    fi

    return "$status"
}

# ------------------------------------------------------------
# Install anime images without overwriting personal files
# ------------------------------------------------------------

# Staging paths are only cleaned by the invocation that created them.
bosh_anime_stage_matches() {
    local directory="$1" identity="$2"

    [[ ! -L "$directory" && -d "$directory" &&
       "$(stat -c '%d:%i:%u:%a' -- "$directory")" == "$identity" ]]
}

bosh_anime_candidate_matches() {
    local path="$1" identity="$2"
    local link_count=""

    [[ ! -L "$path" && -f "$path" ]] || return 1
    link_count="$(stat -c '%h' -- "$path")" || return 1
    # A linked inode could be reachable outside the private 0700 staging dir.
    [[ "$link_count" == 1 &&
       "$(stat -c '%d:%i:%u:%a:%h:%z' -- "$path")" == "$identity" ]]
}

bosh_cleanup_anime_stage() {
    local directory="$1" stage_identity="$2" path="$3" file_identity="$4" hash="$5"

    if bosh_anime_stage_matches "$directory" "$stage_identity"; then
        if [[ -e "$path" || -L "$path" ]]; then
            if ! bosh_anime_candidate_matches "$path" "$file_identity" ||
               ! bosh_remove_file_if_hash_matches "$path" "$hash"; then
                msg warning "Anime staging candidate changed; preserved: $path"
                return 1
            fi
        fi

        # rmdir succeeds only when no other entries are present.
        rmdir -- "$directory" 2>/dev/null && return 0
    fi

    msg warning "Anime staging directory preserved: $directory"
    return 1
}

install_anime_images() {
    local source_file filename destination_file
    local name_hash state_key manifest_file
    local filename_b64 source_hash current_hash previous_hash
    local legacy_key legacy_state_file legacy_value
    local candidate candidate_filename candidate_key
    local legacy_matches
    local file_hash temp_file rollback_file manifest_value
    local stage_dir stage_identity file_identity destination_device
    local rollback_original_mode
    local manifest_owned
    local -a source_files=()
    local -a manifest_lines=()
    local -a stage_cleanup=()

    ensure_directory "$ANIME_DEST" || return 1
    ensure_directory "$BOSH_STATE" || return 1

    source_files=("$ANIME_SOURCE"/*.png)

    if (( ${#source_files[@]} == 0 )); then
        msg error "No anime PNG images found."
        return 1
    fi

    for source_file in "${source_files[@]}"; do
        if [[ -L "$source_file" || ! -f "$source_file" ]]; then
            msg error "Invalid anime asset: $source_file"
            return 1
        fi

        filename="${source_file##*/}"
        destination_file="$ANIME_DEST/$filename"

        name_hash="$(printf '%s' "$filename" | sha256sum)" || return 1
        name_hash="${name_hash%% *}"
        state_key="anime_${name_hash}"
        manifest_file="$BOSH_STATE/$state_key"

        filename_b64="$(printf '%s' "$filename" | base64 -w 0)" || return 1

        source_hash="$(sha256sum -- "$source_file")" || return 1
        source_hash="${source_hash%% *}"

        # Heal an interrupted publication before trusting image ownership.
        bosh_anime_txn_recover "$state_key" "$filename" || return 1

        if [[ -L "$manifest_file" ]]; then
            msg error "Refusing to read a symbolic link: $manifest_file"
            return 1
        fi

        if [[ -e "$manifest_file" && ! -f "$manifest_file" ]]; then
            msg error "Anime manifest is not a regular file: $manifest_file"
            return 1
        fi

        manifest_owned=0
        previous_hash=""

        # Read the current versioned manifest, if present.
        if [[ -f "$manifest_file" ]]; then
            if ! mapfile -t manifest_lines < "$manifest_file"; then
                msg error "Could not read anime manifest: $filename"
                return 1
            fi

            if (( ${#manifest_lines[@]} != 4 )) ||
               [[ "${manifest_lines[0]}" != "version=1" ||
                  "${manifest_lines[1]}" != "component=anime_image" ||
                  "${manifest_lines[2]}" != "filename_b64=$filename_b64" ||
                  ! "${manifest_lines[3]}" =~ ^sha256=[a-f0-9]{64}$ ]]; then
                msg error "Anime manifest is invalid or belongs to another filename: $filename"
                return 1
            fi

            previous_hash="${manifest_lines[3]#sha256=}"
            manifest_owned=1
        else
            # Attempt legacy migration only when the old key is unambiguous.
            legacy_key="anime_${filename//./_}"
            legacy_state_file="$BOSH_STATE/$legacy_key"

            if [[ "$legacy_key" =~ ^[a-zA-Z0-9_-]+$ ]] &&
               [[ -e "$legacy_state_file" || -L "$legacy_state_file" ]]; then

                if [[ -L "$legacy_state_file" ]]; then
                    msg warning "Legacy anime state is a symbolic link; preserved: $legacy_key"
                elif [[ -f "$legacy_state_file" &&
                        -f "$destination_file" && ! -L "$destination_file" ]]; then

                    legacy_matches=0

                    for candidate in "${source_files[@]}"; do
                        candidate_filename="${candidate##*/}"
                        candidate_key="anime_${candidate_filename//./_}"

                        if [[ "$candidate_key" == "$legacy_key" ]]; then
                            legacy_matches=$((legacy_matches + 1))
                        fi
                    done

                    legacy_value="$(cat -- "$legacy_state_file")" || return 1
                    current_hash="$(sha256sum -- "$destination_file")" || return 1
                    current_hash="${current_hash%% *}"

                    if (( legacy_matches == 1 )) &&
                       { [[ "$legacy_value" == "1" ]] && cmp -s "$source_file" "$destination_file" ||
                         [[ "$legacy_value" =~ ^[a-f0-9]{64}$ && "$legacy_value" == "$current_hash" ]]; }; then

                        printf -v manifest_value '%s\n%s\n%s\n%s' \
                            "version=1" \
                            "component=anime_image" \
                            "filename_b64=$filename_b64" \
                            "sha256=$current_hash"

                        write_state "$state_key" "$manifest_value" || return 1
                        previous_hash="$current_hash"
                        manifest_owned=1

                        msg info "Legacy anime ownership migrated: $filename"
                    else
                        msg warning "Ambiguous or unverifiable legacy anime state preserved: $legacy_key"
                    fi
                fi
            fi
        fi

        # Existing managed files may be updated only if their content
        # still matches the previously recorded hash.
        if (( manifest_owned )); then
            if [[ -L "$destination_file" ]]; then
                msg warning "Managed anime destination became a symbolic link; preserved: $filename"
                continue
            fi

            if [[ -e "$destination_file" && ! -f "$destination_file" ]]; then
                msg warning "Managed anime destination is not a regular file; preserved: $filename"
                continue
            fi

            if [[ -f "$destination_file" ]]; then
                current_hash="$(sha256sum -- "$destination_file")" || return 1
                current_hash="${current_hash%% *}"

                if [[ "$current_hash" != "$previous_hash" ]]; then
                    msg warning "Anime image was modified outside Bosh Terminal; preserved: $filename"
                    continue
                fi

                if [[ "$current_hash" == "$source_hash" ]]; then
                    msg info "Anime image already installed: $filename"
                    continue
                fi
            fi
        else
            # An existing image without verified ownership is personal.
            if [[ -e "$destination_file" || -L "$destination_file" ]]; then
                if [[ -f "$destination_file" && ! -L "$destination_file" ]] &&
                   cmp -s "$source_file" "$destination_file"; then
                    msg info "Existing anime image preserved (not managed): $filename"
                else
                    msg warning "Personal image preserved: $filename"
                fi
                continue
            fi
        fi

        # Preserve the source mode for the atomic rename while keeping the
        # candidate private, even if SIGKILL prevents cleanup.
        destination_device="$(stat -c '%d' -- "$ANIME_DEST")" || return 1
        stage_dir="$(umask 077; mktemp -d -- "${destination_file}.bosh-tmp.XXXXXX")" || return 1
        stage_identity="$(stat -c '%d:%i:%u:%a' -- "$stage_dir")" || return 1
        if [[ "$stage_identity" != "$destination_device":*:"$EUID":700 &&
              "$stage_identity" != "$destination_device":*:"$EUID":2700 ]] ||
           ! bosh_anime_stage_matches "$stage_dir" "$stage_identity"; then
            msg error "Unsafe anime staging directory; preserved: $stage_dir"
            return 1
        fi

        # A setgid destination can pass the bit to a newly created directory.
        if [[ "$stage_identity" == *:2700 ]]; then
            chmod g-s -- "$stage_dir" || return 1
            stage_identity="${stage_identity%:*}:700"
            bosh_anime_stage_matches "$stage_dir" "$stage_identity" || return 1
        fi

        temp_file="$stage_dir/image"
        if ! cp -pT -- "$source_file" "$temp_file"; then
            msg warning "Incomplete anime staging directory preserved: $stage_dir"
            return 1
        fi
        file_identity="$(stat -c '%d:%i:%u:%a:%h:%z' -- "$temp_file")" || return 1

        stage_cleanup=("$stage_dir" "$stage_identity" "$temp_file" "$file_identity" "$source_hash")

        # Journal the expected hash before modifying the user's image path.
        if ! bosh_anime_txn_prepare "$state_key" "$filename" "$source_hash"; then
            bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
            return 1
        fi

        rollback_file=""
        rollback_original_mode=""

        if (( manifest_owned )) && [[ -f "$destination_file" ]]; then
            # Capture the old image mode independently of the snapshot:
            # the snapshot is private even when the image was 0644.
            rollback_original_mode="$(stat -c '%a' -- "$destination_file")" || {
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                return 1
            }
            if [[ ! "$rollback_original_mode" =~ ^[0-7]{3,4}$ ]]; then
                msg error "Invalid original anime image mode: $destination_file"
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                return 1
            fi

            rollback_file="$(mktemp "${destination_file}.bosh-rollback.XXXXXX")" || {
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                return 1
            }

            # mktemp creates a 0600 file. cp (without -p) does not copy the
            # source mode onto an existing destination. Verify before use.
            if [[ -L "$rollback_file" || ! -f "$rollback_file" ]] ||
               ! cp -- "$destination_file" "$rollback_file" ||
               [[ "$(stat -c '%a' -- "$rollback_file")" != 600 ]]; then
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                bosh_remove_rollback_file "$rollback_file" || true
                msg error "Could not prepare a private anime snapshot: $filename"
                return 1
            fi

            if ! bosh_verify_rollback_file "$rollback_file" "$previous_hash"; then
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                msg error "Anime rollback snapshot verification failed; preserved: $rollback_file"
                return 1
            fi

            current_hash="$(sha256sum -- "$destination_file")" || {
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                bosh_remove_rollback_file "$rollback_file" || true
                return 1
            }
            current_hash="${current_hash%% *}"

            if [[ "$current_hash" != "$previous_hash" ]]; then
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                bosh_remove_rollback_file "$rollback_file" || true
                msg warning "Anime image changed during update; preserved: $filename"
                continue
            fi

            if ! bosh_anime_stage_matches "$stage_dir" "$stage_identity" ||
               ! bosh_anime_candidate_matches "$temp_file" "$file_identity" ||
               ! mv -fT -- "$temp_file" "$destination_file"; then
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                bosh_remove_rollback_file "$rollback_file" || true
                return 1
            fi
        else
            if [[ -e "$destination_file" || -L "$destination_file" ]]; then
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                msg warning "Existing destination preserved: $filename"
                continue
            fi

            if ! bosh_anime_stage_matches "$stage_dir" "$stage_identity" ||
               ! bosh_anime_candidate_matches "$temp_file" "$file_identity" ||
               ! mv -nT -- "$temp_file" "$destination_file"; then
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                return 1
            fi

            if [[ -e "$temp_file" || -L "$temp_file" ]]; then
                bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true
                msg warning "Destination appeared during installation; preserved: $filename"
                continue
            fi
        fi
        bosh_cleanup_anime_stage "${stage_cleanup[@]}" || true

        file_hash="$(sha256sum -- "$destination_file")" || {
            if [[ -n "$rollback_file" ]]; then
                bosh_restore_rollback_file \
                    "$rollback_file" "$destination_file" \
                    "$source_hash" "$previous_hash" "$rollback_original_mode" ||
                    msg error "Anime rollback recovery needs attention; snapshot path: $rollback_file"
            else
                msg warning "Could not verify anime image; destination preserved: $destination_file"
            fi
            return 1
        }
        file_hash="${file_hash%% *}"

        if [[ "$file_hash" != "$source_hash" ]]; then
            if [[ -n "$rollback_file" ]]; then
                bosh_restore_rollback_file \
                    "$rollback_file" "$destination_file" \
                    "$source_hash" "$previous_hash" "$rollback_original_mode" ||
                    msg error "Anime rollback recovery needs attention; snapshot path: $rollback_file"
            else
                msg warning "Unexpected anime image content; destination preserved: $destination_file"
            fi

            msg error "Installed anime image hash does not match: $filename"
            return 1
        fi

        printf -v manifest_value '%s\n%s\n%s\n%s' \
            "version=1" \
            "component=anime_image" \
            "filename_b64=$filename_b64" \
            "sha256=$file_hash"

        if ! write_state "$state_key" "$manifest_value"; then
            if [[ -n "$rollback_file" ]]; then
                bosh_restore_rollback_file \
                    "$rollback_file" "$destination_file" \
                    "$file_hash" "$previous_hash" "$rollback_original_mode" ||
                    msg error "Anime rollback recovery needs attention; snapshot path: $rollback_file"
            else
                bosh_remove_file_if_hash_matches "$destination_file" "$file_hash" || true
            fi

            msg error "Could not register anime image: $filename"
            return 1
        fi

        [[ -z "$rollback_file" ]] || bosh_remove_rollback_file "$rollback_file" || true
        bosh_anime_txn_recover "$state_key" "$filename" || return 1

        msg success "Installed or updated anime image: $filename"
    done
}
# Validate and migrate an existing positional Zsh integration manifest.
migrate_zsh_manifest() {
    local zshrc="$HOME/.zshrc"
    local manifest_file="$BOSH_STATE/zshrc_manifest"
    local start_marker="${1:-}"
    local end_marker="${2:-}"
    local source_line="${3:-}"
    local source_command="${4:-}"
    local mode=""
    local actual_hash=""
    local expected_block_hash=""
    local actual_block_hash=""
    local backup_path=""
    local backup_path_b64="-"
    local backup_hash="-"
    local original_mode=""
    local canonical_b64=""
    local versioned=0
    local -a legacy=()
    local -a decoded_values=()

    if [[ -L "$BOSH_STATE" ||
          ( -e "$BOSH_STATE" && ! -d "$BOSH_STATE" ) ||
          -L "$manifest_file" ||
          ( -e "$manifest_file" && ! -f "$manifest_file" ) ]]; then
        msg error "Zsh state path or record is not safe."
        return 1
    fi

    if [[ -L "$zshrc" || ! -f "$zshrc" ]]; then
        msg error "Cannot verify Zsh integration without a regular .zshrc."
        return 1
    fi

    if [[ -z "$start_marker" || -z "$end_marker" ||
          -z "$source_line" || -z "$source_command" ]]; then
        msg error "Missing Zsh block validation parameters."
        return 1
    fi

    if [[ "$(grep -Fxc -- "$start_marker" "$zshrc" || true)" != "1" ||
          "$(grep -Fxc -- "$end_marker" "$zshrc" || true)" != "1" ]]; then
        msg error "Zsh block markers are incomplete or duplicated."
        return 1
    fi

    expected_block_hash="$(
        printf '%s\n' \
            "$start_marker" \
            "$source_line" \
            "$source_command" \
            "$end_marker" | sha256sum
    )" || return 1
    expected_block_hash="${expected_block_hash%% *}"

    actual_block_hash="$(
        awk -v start="$start_marker" -v end="$end_marker" '
            $0 == start {
                if (seen_start) {
                    invalid=1
                    exit
                }
                seen_start=1
                inside=1
            }
            inside {
                print
            }
            $0 == end && inside {
                seen_end=1
                inside=0
                exit
            }
            END {
                if (invalid || !seen_start || !seen_end || inside) {
                    exit 1
                }
            }
        ' "$zshrc" | sha256sum
    )" || {
        msg error "Could not extract the Bosh block from .zshrc."
        return 1
    }
    actual_block_hash="${actual_block_hash%% *}"

    if [[ ! -e "$manifest_file" && ! -L "$manifest_file" ]]; then
        if [[ "$actual_block_hash" != "$expected_block_hash" ]]; then
            msg warning "The Bosh block in $HOME/.zshrc was edited; leaving it untouched."
        else
            msg info "Bosh Terminal block content verified; no manifest exists."
        fi
        return 0
    fi

    mapfile -t legacy < "$manifest_file" || return 1

    if [[ "${legacy[0]:-}" == "version=1" ]]; then
        read_manifest zshrc || return 1

        if (( ${#BOSH_MANIFEST[@]} != 6 &&
              ${#BOSH_MANIFEST[@]} != 7 )) ||
           [[ "${BOSH_MANIFEST[component]:-}" != "zsh_integration" ||
              ! "${BOSH_MANIFEST[mode]:-}" =~ ^(created|appended|legacy_replaced)$ ]]; then
            msg error "Versioned Zsh manifest has an invalid schema."
            return 1
        fi

        mode="${BOSH_MANIFEST[mode]}"
        backup_path_b64="${BOSH_MANIFEST[backup_path_b64]:-}"
        backup_hash="${BOSH_MANIFEST[backup_sha256]:-}"

        if (( ${#BOSH_MANIFEST[@]} == 7 )); then
            original_mode="${BOSH_MANIFEST[original_mode]:-}"

            if [[ "$backup_path_b64" == "-" ]]; then
                if [[ "$original_mode" != "-" ]]; then
                    msg error "Versioned Zsh original mode metadata is inconsistent."
                    return 1
                fi
            elif [[ ! "$original_mode" =~ ^[0-7]{3,4}$ ]]; then
                msg error "Versioned Zsh original mode is invalid."
                return 1
            fi
        else
            # Previous schema did not record the original permissions.
            original_mode=""
        fi

        if [[ -n "${BOSH_MANIFEST[block_sha256]+present}" &&
              -z "${BOSH_MANIFEST[sha256]+present}" ]]; then

            if [[ ! "${BOSH_MANIFEST[block_sha256]}" =~ ^[a-f0-9]{64}$ ]]; then
                msg error "Invalid Bosh block hash in Zsh manifest."
                return 1
            fi

            expected_block_hash="${BOSH_MANIFEST[block_sha256]}"
            versioned=1

        elif [[ -n "${BOSH_MANIFEST[sha256]+present}" &&
                -z "${BOSH_MANIFEST[block_sha256]+present}" ]]; then

            # Previous schema stored the hash of the entire .zshrc.
            # That hash cannot validate a file with user-owned additions.
            if [[ ! "${BOSH_MANIFEST[sha256]}" =~ ^[a-f0-9]{64}$ ]]; then
                msg error "Invalid legacy Zsh file hash."
                return 1
            fi

        else
            msg error "Zsh manifest has an ambiguous hash schema."
            return 1
        fi

        if [[ "$backup_path_b64" == "-" ]]; then
            if [[ "$mode" != "created" || "$backup_hash" != "-" ]]; then
                msg error "Versioned Zsh backup metadata is inconsistent."
                return 1
            fi
        else
            if [[ "$mode" == "created" ||
                  ! "$backup_path_b64" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ||
                  ! "$backup_hash" =~ ^[a-f0-9]{64}$ ]]; then
                msg error "Versioned Zsh backup metadata is invalid."
                return 1
            fi

            decoded_values=()
            mapfile -d '' -t decoded_values < <(
                printf '%s' "$backup_path_b64" | base64 --decode 2>/dev/null
            )

            if (( ${#decoded_values[@]} != 1 )); then
                msg error "Could not decode the Zsh backup path."
                return 1
            fi

            backup_path="${decoded_values[0]}"
            canonical_b64="$(printf '%s' "$backup_path" | base64 -w 0)" || return 1

            if [[ "$canonical_b64" != "$backup_path_b64" ||
                  "$backup_path" != /* ||
                  -L "$backup_path" || ! -f "$backup_path" ]]; then
                msg error "Zsh backup file is missing or invalid."
                return 1
            fi

            actual_hash="$(sha256sum -- "$backup_path")" || return 1
            actual_hash="${actual_hash%% *}"

            if [[ "$actual_hash" != "$backup_hash" ]]; then
                msg error "Zsh backup hash does not match its manifest."
                return 1
            fi
        fi

    else
        # Positional legacy manifest.
        if (( ${#legacy[@]} != 4 )) ||
           [[ ! "${legacy[0]:-}" =~ ^(created|appended|legacy_replaced)$ ||
              ! "${legacy[1]:-}" =~ ^[a-f0-9]{64}$ ]]; then
            msg error "Legacy Zsh manifest is invalid; preserving it."
            return 1
        fi

        mode="${legacy[0]}"
        backup_path="${legacy[2]}"
        backup_hash="${legacy[3]}"
        backup_path_b64="-"

        if [[ "$backup_path" == "-" ]]; then
            if [[ "$mode" != "created" || "$backup_hash" != "-" ]]; then
                msg error "Legacy Zsh backup metadata is inconsistent."
                return 1
            fi
        else
            if [[ "$mode" == "created" || "$backup_path" != /* ||
                  -L "$backup_path" || ! -f "$backup_path" ||
                  ! "$backup_hash" =~ ^[a-f0-9]{64}$ ]]; then
                msg error "Legacy Zsh backup is missing or invalid."
                return 1
            fi

            actual_hash="$(sha256sum -- "$backup_path")" || return 1
            actual_hash="${actual_hash%% *}"

            if [[ "$actual_hash" != "$backup_hash" ]]; then
                msg error "Legacy Zsh backup hash does not match."
                return 1
            fi

            backup_path_b64="$(printf '%s' "$backup_path" | base64 -w 0)" || return 1
        fi
    fi

    if [[ "$actual_block_hash" != "$expected_block_hash" ]]; then
        msg warning "The Bosh block in $HOME/.zshrc was edited; leaving it untouched."
    else
        msg info "Bosh Terminal block integrity verified."
    fi

    if (( versioned )); then
        return 0
    fi

    write_manifest zshrc zsh_integration \
        mode "$mode" \
        block_sha256 "$expected_block_hash" \
        backup_path_b64 "$backup_path_b64" \
        backup_sha256 "$backup_hash" || {
        msg error "Could not migrate the legacy Zsh manifest."
        return 1
    }

    msg success "Legacy Zsh manifest migrated to block-based integrity."
}
# Integrate Bosh Terminal with .zshrc
# ------------------------------------------------------------

integrate_zsh() {
    local zshrc="$HOME/.zshrc"
    local start_marker="# >>> Bosh Terminal >>>"
    local end_marker="# <<< Bosh Terminal <<<"
    # shellcheck disable=SC2016
   local source_line='export BOSH_CONFIG_DIR="${BOSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/bosh-terminal}"'
    # shellcheck disable=SC2016
   local source_command='source "$BOSH_CONFIG_DIR/zshrc"'
    local manifest_file="$BOSH_STATE/zshrc_manifest"
    local start_count=0
    local end_count=0
   local mode=""
    local original_hash=""
    local current_hash=""
    local backup_path=""
    local backup_record="-"
    local backup_hash="-"
    local temp_file=""
    local block_hash=""
    local backup_path_b64=""
    local current_umask=""
    local created_mode=""
    local original_mode="-"
    local next_zshrc_hash=""
    local manifest_payload=""

    # Reconcile an interrupted previous integration before touching .zshrc.
    bosh_zsh_uninstall_txn_recover || return 1
    bosh_zsh_txn_recover || return 1

    if [[ -L "$zshrc" ]]; then
        msg error "Refusing to modify a symbolic link at $HOME/.zshrc."
        return 1
    fi

    if [[ -e "$zshrc" && ! -f "$zshrc" ]]; then
        msg error "$HOME/.zshrc exists but is not a regular file."
        return 1
    fi

    if [[ -f "$zshrc" ]]; then
        start_count="$(grep -Fxc -- "$start_marker" "$zshrc" || true)"
        end_count="$(grep -Fxc -- "$end_marker" "$zshrc" || true)"

        if (( start_count > 0 || end_count > 0 )); then
            if (( start_count != 1 || end_count != 1 )); then
                msg error "Incomplete or duplicated Bosh Terminal block."
                return 1
            fi

            migrate_zsh_manifest \
                "$start_marker" \
                "$end_marker" \
                "$source_line" \
                "$source_command" || return 1

            msg info "Bosh Terminal block already exists."
            return 0
        fi

        original_hash="$(sha256sum -- "$zshrc")" || return 1
        original_hash="${original_hash%% *}"

        if grep -Eq 'fastfetch --chafa auto --logo|Bosh Terminal - Zsh' "$zshrc"; then
            msg warning "A previous Bosh configuration was detected."

            confirm \
                "¿Reemplazar $HOME/.zshrc por el cargador de Bosh? Se creará una copia completa de respaldo." \
                "Replace $HOME/.zshrc with the Bosh loader? A complete backup will be created." || return 1

            mode="legacy_replaced"
        else
            mode="appended"
        fi
    else
        mode="created"
    fi

    if [[ -e "$manifest_file" || -L "$manifest_file" ]]; then
        msg warning "Found an orphaned Zsh integration state record; archiving it before re-integration."
        archive_state "zshrc_manifest" || return 1
    fi

    if [[ "$mode" != "created" ]]; then
        create_backup "$zshrc" || return 1
        backup_path="$BOSH_LAST_BACKUP"
        original_mode="$BOSH_LAST_BACKUP_MODE"

        if [[ ! "$original_mode" =~ ^[0-7]{3,4}$ ]]; then
            msg error "Could not capture the original .zshrc permissions."
            return 1
        fi

        if [[ -z "$backup_path" || -L "$backup_path" || ! -f "$backup_path" ]]; then
            msg error "The original Zsh backup could not be verified."
            return 1
        fi
        backup_record="$backup_path"
        backup_hash="$(sha256sum -- "$backup_path")" || return 1
        backup_hash="${backup_hash%% *}"
    fi

    temp_file="$(mktemp "$HOME/.zshrc.bosh-tmp.XXXXXX")" || return 1

    bosh_register_temp "$temp_file" file || {
        bosh_remove_temp_file "$temp_file"
        return 1
    }

    if [[ "$mode" == "appended" || "$mode" == "legacy_replaced" ]]; then
        if ! cp -a -- "$zshrc" "$temp_file"; then
            bosh_remove_temp_file "$temp_file"
            return 1
        fi
    fi

    if [[ "$mode" == "legacy_replaced" ]]; then
        if ! : > "$temp_file"; then
            bosh_remove_temp_file "$temp_file"
            return 1
        fi
    fi

    if [[ "$mode" == "appended" && -s "$zshrc" ]]; then
        if ! printf '\n' >> "$temp_file"; then
            bosh_remove_temp_file "$temp_file"
            return 1
        fi
    fi

    if ! printf '%s\n' \
        "$start_marker" \
        "$source_line" \
        "$source_command" \
        "$end_marker" >> "$temp_file"; then
        bosh_remove_temp_file "$temp_file"
        return 1
    fi

    if [[ "$mode" == "created" ]]; then
        current_umask="$(umask)" || {
            bosh_remove_temp_file "$temp_file"
            return 1
        }

        if [[ ! "$current_umask" =~ ^[0-7]{3,4}$ ]]; then
            bosh_remove_temp_file "$temp_file"
            msg error "Could not determine the current umask."
            return 1
        fi

        printf -v created_mode '%o' "$(( 0666 & ~(8#$current_umask) ))"

        if ! chmod "$created_mode" "$temp_file"; then
            bosh_remove_temp_file "$temp_file"
            msg error "Could not set the new .zshrc permissions."
            return 1
        fi
    fi

    block_hash="$(printf '%s\n' \
        "$start_marker" \
        "$source_line" \
        "$source_command" \
        "$end_marker" | sha256sum)" || {
        bosh_remove_temp_file "$temp_file"
        return 1
    }
    block_hash="${block_hash%% *}"

    if [[ "$mode" != "created" ]]; then
        if [[ -L "$zshrc" || ! -f "$zshrc" ]]; then
            bosh_remove_temp_file "$temp_file"
            msg error "$HOME/.zshrc changed during installation."
            return 1
        fi

        current_hash="$(sha256sum -- "$zshrc")" || {
            bosh_remove_temp_file "$temp_file"
            return 1
        }
        current_hash="${current_hash%% *}"

        if [[ "$current_hash" != "$original_hash" ]]; then
            bosh_remove_temp_file "$temp_file"
            msg error "$HOME/.zshrc changed during installation. Original preserved."
            return 1
        fi
    else
        if [[ -e "$zshrc" || -L "$zshrc" ]]; then
            bosh_remove_temp_file "$temp_file"
            msg error "$HOME/.zshrc appeared during installation. Existing file preserved."
            return 1
        fi
    fi

    if [[ "$backup_record" == "-" ]]; then
        backup_path_b64="-"
    else
        backup_path_b64="$(printf '%s' "$backup_record" | base64 -w 0)" || {
            bosh_remove_temp_file "$temp_file"
            return 1
        }
    fi

    # Publish intent before the manifest or user-owned .zshrc can change.
    next_zshrc_hash="$(bosh_zsh_txn_hash "$temp_file")" || return 1
    printf -v manifest_payload \
        'version=1\ncomponent=zsh_integration\nmode=%s\nblock_sha256=%s\nbackup_path_b64=%s\nbackup_sha256=%s\noriginal_mode=%s' \
        "$mode" "$block_hash" "$backup_path_b64" "$backup_hash" "$original_mode"
    bosh_zsh_txn_prepare \
        "$mode" "${original_hash:--}" "$next_zshrc_hash" "$manifest_payload" || return 1

    if ! write_manifest "zshrc" zsh_integration \
        mode "$mode" \
        block_sha256 "$block_hash" \
        backup_path_b64 "$backup_path_b64" \
        backup_sha256 "$backup_hash" \
        original_mode "$original_mode"; then
        bosh_remove_temp_file "$temp_file"
        bosh_zsh_txn_recover || true
        msg error "Could not register the Zsh integration."
        return 1
    fi

    if [[ "$mode" == "created" ]]; then
        if ! mv -nT -- "$temp_file" "$zshrc"; then
            bosh_remove_temp_file "$temp_file"
            bosh_zsh_txn_recover || true
            return 1
        fi

        if [[ -e "$temp_file" ]]; then
            bosh_remove_temp_file "$temp_file"
            bosh_zsh_txn_recover || true
            msg error "Another $HOME/.zshrc appeared. Existing file preserved."
            return 1
        fi

        bosh_forget_temp "$temp_file"
    else
        if ! mv -fT -- "$temp_file" "$zshrc"; then
            bosh_remove_temp_file "$temp_file"
            bosh_zsh_txn_recover || true
            return 1
        fi

        bosh_forget_temp "$temp_file"
    fi

    # Verify destination + manifest before retiring the pending journal.
    bosh_zsh_txn_recover || return 1
    msg success "Bosh Terminal integrated into $HOME/.zshrc."
}
# ------------------------------------------------------------
# Main installation
# ------------------------------------------------------------

request_install_consent() {
  say \
    "Bosh Terminal instalará o actualizará configuraciones y podrá recuperar operaciones interrumpidas." \
    "Bosh Terminal will install or update configurations and may recover interrupted operations."

  printf 'HOME: %s\n' "$HOME"
  printf 'BOSH_HOME: %s\n' "$BOSH_HOME"
  printf 'BOSH_STATE: %s\n' "$BOSH_STATE"
  printf 'BOSH_BACKUP: %s\n' "$BOSH_BACKUP"

  if ! confirm \
    "¿Autorizas la instalación y recuperación de Bosh Terminal?" \
    "Do you authorize Bosh Terminal installation and recovery?"; then
    msg warning "Installation authorization declined."
    return 1
  fi
}

main() {
    preflight || return 1

  request_install_consent || return 1

    acquire_install_lock || return 1
    setup_install_traps

    # Recover before further installation changes, while holding the lock.
    bosh_managed_txn_recover zsh_config "$BOSH_HOME/zshrc" || return 1
    bosh_managed_txn_recover starship "$BOSH_HOME/starship.toml" || return 1
    bosh_managed_txn_recover fastfetch "$BOSH_HOME/fastfetch.jsonc" || return 1
    bosh_managed_txn_recover konsole_profile "$KONSOLE_DIR/bosh.profile" || return 1
    bosh_managed_txn_recover konsole_scheme "$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme" || return 1
    bosh_zsh_uninstall_txn_recover || return 1
    bosh_zsh_txn_recover || return 1
    bosh_omz_txn_recover || return 1
    bosh_anime_txn_recover_all || return 1

    install_dependencies || return 1
    install_oh_my_zsh || return 1

    install_managed_file_or_skip \
        "$ZSH_CONFIG" \
        "$BOSH_HOME/zshrc" "zsh_config" || return 1

    install_managed_file_or_skip \
        "$STARSHIP_CONFIG" \
        "$BOSH_HOME/starship.toml" "starship" || return 1

    install_managed_file_or_skip \
        "$FASTFETCH_CONFIG" \
        "$BOSH_HOME/fastfetch.jsonc" "fastfetch" || return 1

    install_anime_images || return 1

    integrate_zsh || return 1

    install_konsole_component || return 1

    msg success "Bosh Terminal installation completed."

    say \
        "Abre una nueva sesión de Zsh para utilizar Bosh Terminal." \
        "Open a new Zsh session to use Bosh Terminal."

    say \
        "Selecciona el perfil 'bosh' en Konsole si instalaste el componente visual." \
        "Select the 'bosh' profile in Konsole if you installed the visual component."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
