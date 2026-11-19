#!/usr/bin/env bash
# Zsh integration write-ahead journal (process interruption recovery).
# Shared by installer and uninstaller via install.sh. Never eval/source state.

bosh_zsh_txn_hash() {
    local result
    [[ ! -L "$1" && -f "$1" ]] || return 1
    result="$(sha256sum -- "$1")" || return 1
    printf '%s\n' "${result%% *}"
}

bosh_zsh_txn_prepare() {
    local mode="$1" previous="$2" next="$3" manifest_payload="$4"
    local journal="$BOSH_STATE/zshrc_txn"
    local manifest="$BOSH_STATE/zshrc_manifest"
    local manifest_hash

    [[ "$mode" =~ ^(created|appended|legacy_replaced)$ ]] || return 1
    [[ "$previous" == '-' || "$previous" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$next" =~ ^[a-f0-9]{64}$ && "$previous" != "$next" ]] || return 1
    if [[ "$mode" == created ]]; then
        [[ "$previous" == '-' ]] || return 1
    else
        [[ "$previous" =~ ^[a-f0-9]{64}$ ]] || return 1
    fi

    ensure_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$HOME" || return 1
    [[ ! -e "$journal" && ! -L "$journal" &&
       ! -e "$manifest" && ! -L "$manifest" ]] || return 1

    manifest_hash="$(printf '%s\n' "$manifest_payload" | sha256sum)" || return 1
    manifest_hash="${manifest_hash%% *}"
    [[ "$manifest_hash" =~ ^[a-f0-9]{64}$ ]] || return 1

    # write_state publishes via a private, atomic rename. If the process
    # stops before this succeeds, neither .zshrc nor its manifest changes.
    write_state zshrc_txn \
        "version=1
component=zsh_integration
mode=$mode
previous_sha256=$previous
next_sha256=$next
manifest_sha256=$manifest_hash"
}

bosh_zsh_txn_recover() {
    local journal="$BOSH_STATE/zshrc_txn"
    local manifest="$BOSH_STATE/zshrc_manifest"
    local zshrc="$HOME/.zshrc"
    local old_hash new_hash manifest_expected mode
    local current_hash='-' manifest_hash='-'
    local backup_encoded backup_path backup_hash decoded_hash
    local file_mode actual_uid
    local -a record=()

    [[ ! -L "$BOSH_STATE" ]] || return 1
    [[ -e "$journal" || -L "$journal" ]] || return 0
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$HOME" || return 1
    [[ ! -L "$journal" && -f "$journal" ]] || return 1
    actual_uid="$(id -u)" || return 1
    [[ "$(stat -c '%u' -- "$journal")" == "$actual_uid" &&
       "$(stat -c '%a' -- "$journal")" == 600 ]] || return 1
    mapfile -t record < "$journal" || return 1
    (( ${#record[@]} == 6 )) || return 1
    [[ "${record[0]}" == 'version=1' &&
       "${record[1]}" == 'component=zsh_integration' &&
       "${record[2]}" == mode=* &&
       "${record[3]}" == previous_sha256=* &&
       "${record[4]}" == next_sha256=* &&
       "${record[5]}" == manifest_sha256=* ]] || return 1
    mode="${record[2]#mode=}"
    old_hash="${record[3]#previous_sha256=}"
    new_hash="${record[4]#next_sha256=}"
    manifest_expected="${record[5]#manifest_sha256=}"
    [[ "$mode" =~ ^(created|appended|legacy_replaced)$ &&
       ( "$old_hash" == '-' || "$old_hash" =~ ^[a-f0-9]{64}$ ) &&
       "$new_hash" =~ ^[a-f0-9]{64}$ &&
       "$manifest_expected" =~ ^[a-f0-9]{64}$ &&
       "$old_hash" != "$new_hash" ]] || return 1
    if [[ "$mode" == created ]]; then
        [[ "$old_hash" == '-' ]] || return 1
    else
        [[ "$old_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    fi

    [[ ! -L "$zshrc" && ( ! -e "$zshrc" || -f "$zshrc" ) ]] || return 1
    [[ ! -L "$manifest" && ( ! -e "$manifest" || -f "$manifest" ) ]] || return 1
    if [[ -f "$zshrc" ]]; then
        current_hash="$(bosh_zsh_txn_hash "$zshrc")" || return 1
    fi
    if [[ -f "$manifest" ]]; then
        manifest_hash="$(bosh_zsh_txn_hash "$manifest")" || return 1
    fi

    # Recheck backup association whenever a committed manifest exists.
    if [[ "$manifest_hash" == "$manifest_expected" ]]; then
        read_manifest zshrc || return 1
        (( ${#BOSH_MANIFEST[@]} == 7 )) || return 1
        [[ "${BOSH_MANIFEST[component]:-}" == zsh_integration &&
           "${BOSH_MANIFEST[mode]:-}" == "$mode" &&
           "${BOSH_MANIFEST[block_sha256]:-}" =~ ^[a-f0-9]{64}$ ]] || return 1
        backup_encoded="${BOSH_MANIFEST[backup_path_b64]:-}"
        backup_hash="${BOSH_MANIFEST[backup_sha256]:-}"
        file_mode="${BOSH_MANIFEST[original_mode]:-}"
        if [[ "$mode" == created ]]; then
            [[ "$backup_encoded" == '-' && "$backup_hash" == '-' &&
               "$file_mode" == '-' ]] || return 1
        else
            [[ "$backup_encoded" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ &&
               "$backup_hash" == "$old_hash" &&
               "$file_mode" =~ ^[0-7]{3,4}$ ]] || return 1
            backup_path="$(printf '%s' "$backup_encoded" | base64 --decode 2>/dev/null)" || return 1
            [[ "$(printf '%s' "$backup_path" | base64 -w 0)" == "$backup_encoded" &&
               "$backup_path" == "$BOSH_BACKUP/"* ]] || return 1
            bosh_managed_txn_safe_directory "$(dirname -- "$backup_path")" || return 1
            decoded_hash="$(bosh_zsh_txn_hash "$backup_path")" || return 1
            [[ "$decoded_hash" == "$backup_hash" ]] || return 1
        fi
    elif [[ "$manifest_hash" != '-' ]]; then
        msg error "Unexpected Zsh manifest; pending transaction preserved."
        return 1
    fi

    if [[ "$current_hash" == "$new_hash" &&
          "$manifest_hash" == "$manifest_expected" ]]; then
        archive_state zshrc_txn || return 1
        msg info "Committed Zsh integration transaction recovered."
        return 0
    fi

    if [[ "$current_hash" == "$old_hash" ]]; then
        if [[ "$manifest_hash" == "$manifest_expected" ]]; then
            # Before rename: old user .zshrc is intact. Retire only the
            # expected premature manifest, and retain an archive for audit.
            archive_state zshrc_manifest || return 1
        elif [[ "$manifest_hash" != '-' ]]; then
            return 1
        fi
        archive_state zshrc_txn || return 1
        msg info "Interrupted Zsh integration rolled back without touching .zshrc."
        return 0
    fi

    msg error "Ambiguous Zsh transaction; user file and manifest preserved: $journal"
    return 1
}

# Uninstallation uses a separate journal because the final .zshrc may be
# absent, restored from backup, or contain user-owned content without Bosh.
bosh_zsh_uninstall_txn_prepare() {
    local mode="$1" previous="$2" next="$3" manifest_expected="$4"
    local journal="$BOSH_STATE/zshrc_uninstall_txn"
    local manifest="$BOSH_STATE/zshrc_manifest"
    local zshrc="$HOME/.zshrc"

    [[ "$mode" =~ ^(created|appended|legacy_replaced)$ ]] || return 1
    [[ "$previous" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$next" == '-' || "$next" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$manifest_expected" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$previous" != "$next" ]] || return 1
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$HOME" || return 1
    [[ ! -e "$journal" && ! -L "$journal" ]] || return 1
    [[ "$(bosh_zsh_txn_hash "$zshrc")" == "$previous" ]] || return 1
    [[ "$(bosh_zsh_txn_hash "$manifest")" == "$manifest_expected" ]] || return 1

    write_state zshrc_uninstall_txn \
        "version=1
component=zsh_uninstall
mode=$mode
previous_sha256=$previous
next_sha256=$next
manifest_sha256=$manifest_expected"
}

bosh_zsh_uninstall_txn_recover() {
    local journal="$BOSH_STATE/zshrc_uninstall_txn"
    local manifest="$BOSH_STATE/zshrc_manifest"
    local zshrc="$HOME/.zshrc"
    local mode previous next expected_manifest
    local dest_hash='-' manifest_hash='-' uid
    local -a record=()

    [[ ! -L "$BOSH_STATE" ]] || return 1
    [[ -e "$journal" || -L "$journal" ]] || return 0
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$HOME" || return 1
    [[ ! -L "$journal" && -f "$journal" ]] || return 1
    uid="$(id -u)" || return 1
    [[ "$(stat -c '%u' -- "$journal")" == "$uid" &&
       "$(stat -c '%a' -- "$journal")" == 600 ]] || return 1
    mapfile -t record < "$journal" || return 1
    (( ${#record[@]} == 6 )) || return 1
    [[ "${record[0]}" == version=1 &&
       "${record[1]}" == component=zsh_uninstall &&
       "${record[2]}" == mode=* &&
       "${record[3]}" == previous_sha256=* &&
       "${record[4]}" == next_sha256=* &&
       "${record[5]}" == manifest_sha256=* ]] || return 1

    mode="${record[2]#mode=}"
    previous="${record[3]#previous_sha256=}"
    next="${record[4]#next_sha256=}"
    expected_manifest="${record[5]#manifest_sha256=}"

    [[ "$mode" =~ ^(created|appended|legacy_replaced)$ &&
       "$previous" =~ ^[a-f0-9]{64}$ &&
       ( "$next" == '-' || "$next" =~ ^[a-f0-9]{64}$ ) &&
       "$previous" != "$next" &&
       "$expected_manifest" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ ! -L "$zshrc" && ( ! -e "$zshrc" || -f "$zshrc" ) ]] || return 1
    [[ ! -L "$manifest" && ( ! -e "$manifest" || -f "$manifest" ) ]] || return 1

    if [[ -f "$zshrc" ]]; then
        dest_hash="$(bosh_zsh_txn_hash "$zshrc")" || return 1
    fi
    if [[ -f "$manifest" ]]; then
        manifest_hash="$(bosh_zsh_txn_hash "$manifest")" || return 1
    fi
    [[ "$manifest_hash" == '-' || "$manifest_hash" == "$expected_manifest" ]] || {
        msg error "Unrecognized Zsh uninstall manifest; transaction preserved."
        return 1
    }

    if [[ "$dest_hash" == "$previous" &&
          "$manifest_hash" == "$expected_manifest" ]]; then
        # No .zshrc modification occurred. Cancel the planned uninstall;
        # next attempt can rebuild the stage safely.
        archive_state zshrc_uninstall_txn || return 1
        msg info "Incomplete Zsh uninstallation cancelled; original retained."
        return 0
    fi

    if [[ "$dest_hash" == "$next" ]]; then
        if [[ "$manifest_hash" == "$expected_manifest" ]]; then
            archive_state zshrc_manifest || return 1
        fi
        # An interrupted archive_state may already have archived the
        # manifest. Finish idempotently without touching the user file.
        archive_state zshrc_uninstall_txn || return 1
        msg info "Interrupted Zsh uninstallation finalized safely."
        return 0
    fi

    msg error "Ambiguous Zsh uninstallation state; preserving: $journal"
    return 1
}
