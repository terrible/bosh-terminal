#!/usr/bin/env bash
# H1: recoverable managed-file publication. Source from install.sh after common.sh.
# Journal files are persistent evidence, never temporary resources for EXIT cleanup.

bosh_managed_txn_safe_directory() {
    local path="${1:-}" component current="/"
    local -a parts=()
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    IFS='/' read -r -a parts <<< "${path#/}"
    for component in "${parts[@]}"; do
        [[ -n "$component" ]] || continue
        [[ "$component" != '.' && "$component" != '..' ]] || return 1
        current="${current%/}/$component"
        [[ ! -L "$current" && -d "$current" ]] || return 1
    done
}

bosh_managed_txn_hash() {
    local result
    [[ ! -L "$1" && -f "$1" ]] || return 1
    result="$(sha256sum -- "$1")" || return 1
    printf '%s\n' "${result%% *}"
}

bosh_managed_txn_validate_next() {
    local file="$1" destination="$2" expected_hash="$3"
    local encoded backup_encoded backup_hash backup_path mode ownership actual
    local -a entries=()

    [[ ! -L "$file" && -f "$file" ]] || return 1
    mapfile -t entries < "$file" || return 1
    (( ${#entries[@]} == 7 || ${#entries[@]} == 8 )) || return 1
    encoded="$(printf '%s' "$destination" | base64 -w 0)" || return 1

    [[ "${entries[0]}" == 'version=1' &&
       "${entries[1]}" == 'component=managed_file' &&
       "${entries[2]}" == "sha256=$expected_hash" &&
       "${entries[4]}" == "destination_b64=$encoded" ]] || return 1

    ownership="${entries[3]#preexisting=}"
    [[ "${entries[3]}" == "preexisting=$ownership" && "$ownership" =~ ^[01]$ ]] || return 1
    [[ "${entries[5]}" == backup_path_b64=* && "${entries[6]}" == backup_sha256=* ]] || return 1
    backup_encoded="${entries[5]#backup_path_b64=}"
    backup_hash="${entries[6]#backup_sha256=}"

    if (( ${#entries[@]} == 8 )); then
        [[ "${entries[7]}" == original_mode=* ]] || return 1
        mode="${entries[7]#original_mode=}"
    else
        mode=""
    fi

    if [[ "$backup_encoded" == '-' ]]; then
        [[ "$ownership" == '0' && "$backup_hash" == '-' &&
           ( -z "$mode" || "$mode" == '-' ) ]] || return 1
    else
        [[ "$ownership" == '1' && "$backup_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
        [[ "$backup_encoded" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || return 1
        [[ -z "$mode" || "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        backup_path="$(printf '%s' "$backup_encoded" | base64 --decode 2>/dev/null)" || return 1
        [[ "$(printf '%s' "$backup_path" | base64 -w 0)" == "$backup_encoded" ]] || return 1
        [[ "$backup_path" == "$BOSH_BACKUP/"* ]] || return 1
        bosh_managed_txn_safe_directory "$(dirname -- "$backup_path")" || return 1
        actual="$(bosh_managed_txn_hash "$backup_path")" || return 1
        [[ "$actual" == "$backup_hash" ]] || return 1
    fi
}


# Remove only private, regular, single-linked journal artifacts. An interrupted
# cleanup may be retried. Never follow symlinks or recursively remove unknown
# content, and do not touch pending transactions here.
bosh_managed_txn_prune_dir() {
    local key="$1" dir="$2" phase="$3" destination="$4"
    local prefix suffix own_uid entry name manifest manifest_hash='-' dest_hash='-'
    local prev_hash next_hash prev_manifest_hash next_manifest_hash encoded
    local -a record=()
    local entries=0

    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ && "$destination" == /* ]] || return 1
    [[ "$phase" == prepare || "$phase" == completed ]] || return 1
    prefix="$BOSH_STATE/.${key}.managed-${phase}."
    [[ "$dir" == "$prefix"* ]] || return 1
    suffix="${dir#"$prefix"}"
    [[ "$suffix" =~ ^[A-Za-z0-9]{8}$ ]] || return 1

    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$dir" || return 1
    own_uid="$(id -u)" || return 1
    [[ "$(stat -c '%u' -- "$dir")" == "$own_uid" &&
       "$(stat -c '%a' -- "$dir")" == 700 ]] || return 1

    # Scan before deleting anything. Unknown entries or symlinks fail closed.
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name="${entry##*/}"
        case "$name" in
            record|next|previous|previous_destination) ;;
            record.tmp)
                [[ "$phase" == prepare ]] || return 1
                ;;
            *) msg error "Foreign journal entry preserved: $entry"; return 1 ;;
        esac
        [[ ! -L "$entry" && -f "$entry" ]] || return 1
        [[ "$(stat -c '%u' -- "$entry")" == "$own_uid" ]] || return 1
        [[ "$(stat -c '%h' -- "$entry")" == 1 ]] || return 1
        entries=$((entries + 1))
    done

    # For a completed journal, prove that the system still matches the state
    # in its record. The record is removed LAST so interrupted cleanup can be
    # retried. An empty directory can arise before the pending rename.
    if [[ "$phase" == completed && -f "$dir/record" ]]; then
        mapfile -t record < "$dir/record" || return 1
        (( ${#record[@]} == 6 )) || return 1
        encoded="$(printf '%s' "$destination" | base64 -w 0)" || return 1
        [[ "${record[0]}" == version=1 &&
           "${record[1]}" == "destination_b64=$encoded" &&
           "${record[2]}" == previous_sha256=* &&
           "${record[3]}" == next_sha256=* &&
           "${record[4]}" == previous_manifest_sha256=* &&
           "${record[5]}" == next_manifest_sha256=* ]] || return 1
        prev_hash="${record[2]#previous_sha256=}"
        next_hash="${record[3]#next_sha256=}"
        prev_manifest_hash="${record[4]#previous_manifest_sha256=}"
        next_manifest_hash="${record[5]#next_manifest_sha256=}"
        [[ ( "$prev_hash" == '-' || "$prev_hash" =~ ^[a-f0-9]{64}$ ) &&
           "$next_hash" =~ ^[a-f0-9]{64}$ &&
           ( "$prev_manifest_hash" == '-' || "$prev_manifest_hash" =~ ^[a-f0-9]{64}$ ) &&
           "$next_manifest_hash" =~ ^[a-f0-9]{64}$ ]] || return 1

        bosh_managed_txn_safe_directory "$(dirname -- "$destination")" || return 1
        [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || return 1
        manifest="$BOSH_STATE/${key}_manifest"
        [[ ! -L "$manifest" && ( ! -e "$manifest" || -f "$manifest" ) ]] || return 1
        if [[ -f "$destination" ]]; then
            dest_hash="$(bosh_managed_txn_hash "$destination")" || return 1
        fi
        if [[ -f "$manifest" ]]; then
            manifest_hash="$(bosh_managed_txn_hash "$manifest")" || return 1
        fi
        if [[ "$dest_hash" != "$next_hash" || "$manifest_hash" != "$next_manifest_hash" ]]; then
            [[ "$dest_hash" == "$prev_hash" &&
               "$manifest_hash" == "$prev_manifest_hash" ]] || {
                msg error "Completed journal does not match disk state: $dir"
                return 1
            }
        fi
    elif [[ "$phase" == completed && "$entries" != 0 ]]; then
        # Missing record with remaining files is ambiguous, not disposable.
        msg error "Incomplete completed journal preserved: $dir"
        return 1
    fi

    # Explicit known-file deletion, not rm -rf. Record is deleted last.
    for name in previous_destination previous next record.tmp record; do
        entry="$dir/$name"
        [[ -e "$entry" || -L "$entry" ]] || continue
        [[ ! -L "$entry" && -f "$entry" ]] || return 1
        [[ "$(stat -c '%u' -- "$entry")" == "$own_uid" ]] || return 1
        [[ "$(stat -c '%h' -- "$entry")" == 1 ]] || return 1
        rm -f -- "$entry" || return 1
    done
    rmdir -- "$dir" || return 1
}

# This function is used only from serialized installer/uninstaller operations.
# Never collect from a concurrent writer without holding the shared lock.
bosh_managed_txn_collect() {
    local key="$1" destination="$2" path phase
    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ ! -L "$BOSH_STATE" && ( ! -e "$BOSH_STATE" || -d "$BOSH_STATE" ) ]] || return 1
    [[ -d "$BOSH_STATE" ]] || return 0
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1

    for path in "$BOSH_STATE/.${key}.managed-prepare."* \
                "$BOSH_STATE/.${key}.managed-completed."*; do
        [[ -e "$path" || -L "$path" ]] || continue
        case "$path" in
            "$BOSH_STATE/.${key}.managed-prepare."*) phase=prepare ;;
            "$BOSH_STATE/.${key}.managed-completed."*) phase=completed ;;
            *) return 1 ;;
        esac
        if ! bosh_managed_txn_prune_dir "$key" "$path" "$phase" "$destination"; then
            msg error "Journal residual requires manual inspection: $path"
            return 1
        fi
        msg info "Safely cleaned orphaned journal: $path"
    done
}

bosh_managed_txn_prepare() {
    local key="$1" destination="$2" previous_hash="$3" next_hash="$4" payload="$5"
    local dir="$BOSH_STATE/.${key}.managed-pending"
    local manifest="$BOSH_STATE/${key}_manifest"
    local old_manifest_hash='-' next_manifest_hash encoded stage=""

    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ && "$destination" == /* ]] || return 1
    [[ "$next_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$previous_hash" == '-' || "$previous_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$next_hash" != "$previous_hash" ]] || return 1
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$(dirname -- "$destination")" || return 1
    [[ ! -e "$dir" && ! -L "$dir" ]] || return 1
    [[ ! -L "$manifest" && ( ! -e "$manifest" || -f "$manifest" ) ]] || return 1

    # Prepare in a unique private directory: an interrupted preparation
    # must not create the authoritative .managed-pending marker.
    stage="$(mktemp -d "$BOSH_STATE/.${key}.managed-prepare.XXXXXXXX")" || return 1
    if ! (umask 077; printf '%s\n' "$payload" > "$stage/next"); then
        return 1
    fi
    bosh_managed_txn_validate_next "$stage/next" "$destination" "$next_hash" || return 1
    next_manifest_hash="$(bosh_managed_txn_hash "$stage/next")" || return 1

    if [[ -f "$manifest" ]]; then
        cp -p -- "$manifest" "$stage/previous" || return 1
        chmod 600 -- "$stage/previous" || return 1
        old_manifest_hash="$(bosh_managed_txn_hash "$stage/previous")" || return 1
        [[ "$(bosh_managed_txn_hash "$manifest")" == "$old_manifest_hash" ]] || return 1
    fi

    # Keep the original destination snapshot inside the private journal.
    if [[ "$previous_hash" != '-' ]]; then
        cp -p -- "$destination" "$stage/previous_destination" || return 1
        [[ "$(bosh_managed_txn_hash "$stage/previous_destination")" == "$previous_hash" ]] || return 1
    fi

    encoded="$(printf '%s' "$destination" | base64 -w 0)" || return 1
    if ! (umask 077; printf '%s\n' \
        'version=1' \
        "destination_b64=$encoded" \
        "previous_sha256=$previous_hash" \
        "next_sha256=$next_hash" \
        "previous_manifest_sha256=$old_manifest_hash" \
        "next_manifest_sha256=$next_manifest_hash" > "$stage/record.tmp"); then
        return 1
    fi
    mv -T -- "$stage/record.tmp" "$stage/record" || return 1
    # The directory rename is the point at which the transaction becomes
    # visible to recovery. Never clobber a concurrently created journal.
    [[ ! -e "$dir" && ! -L "$dir" ]] || return 1
    mv -nT -- "$stage" "$dir" || return 1
    [[ ! -e "$stage" && ! -L "$stage" ]] || return 1
}

bosh_managed_txn_finish() {
    local dir="$1" key="$2" destination="$3" completed entry filename
    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$dir" == "$BOSH_STATE/.${key}.managed-pending" ]] || return 1
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$dir" || return 1

    # Do not recursively delete an unexpected or user-modified journal
    # directory. Only known private regular files may be cleaned.
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        filename="${entry##*/}"
        case "$filename" in
            record|next|previous|previous_destination) ;;
            *) msg error "Unexpected recovery journal entry preserved: $entry"; return 1 ;;
        esac
        if [[ -L "$entry" || ! -f "$entry" ]]; then
            msg error "Unsafe recovery journal entry preserved: $entry"
            return 1
        fi
    done

    completed="$(mktemp -d "$BOSH_STATE/.${key}.managed-completed.XXXXXXXX")" || return 1
    rmdir -- "$completed" || return 1
    mv -T -- "$dir" "$completed" || return 1
    # Do not recursively delete snapshots or unknown files.
    bosh_managed_txn_prune_dir "$key" "$completed" completed "$destination"
}

bosh_managed_txn_recover() {
    local key="$1" destination="$2"
    local dir="$BOSH_STATE/.${key}.managed-pending"
    local manifest="$BOSH_STATE/${key}_manifest"
    local expected_encoded previous_hash next_hash previous_manifest_hash next_manifest_hash
    local destination_hash='-' manifest_hash='-' actual
    local -a record=()

    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ && "$destination" == /* ]] || return 1
    # Any stale prepare/completed directories are reaped with strict checks.
    bosh_managed_txn_collect "$key" "$destination" || return 1
    [[ ! -e "$dir" && ! -L "$dir" ]] && return 0
    if ! bosh_managed_txn_safe_directory "$BOSH_STATE" ||
       ! bosh_managed_txn_safe_directory "$dir" ||
       [[ -L "$dir/record" || ! -f "$dir/record" ||
          -L "$dir/next" || ! -f "$dir/next" ]]; then
        msg error "Unsafe or incomplete managed transaction; preserved: $dir"
        return 1
    fi
    [[ "$(stat -c '%a' -- "$dir")" == 700 ]] || return 1
    [[ "$(stat -c '%a' -- "$dir/record")" == 600 ]] || return 1
    [[ "$(stat -c '%a' -- "$dir/next")" == 600 ]] || return 1
    mapfile -t record < "$dir/record" || return 1
    (( ${#record[@]} == 6 )) || { msg error "Invalid transaction record: $dir"; return 1; }
    expected_encoded="$(printf '%s' "$destination" | base64 -w 0)" || return 1
    [[ "${record[0]}" == 'version=1' &&
       "${record[1]}" == "destination_b64=$expected_encoded" &&
       "${record[2]}" == previous_sha256=* &&
       "${record[3]}" == next_sha256=* &&
       "${record[4]}" == previous_manifest_sha256=* &&
       "${record[5]}" == next_manifest_sha256=* ]] || return 1
    previous_hash="${record[2]#previous_sha256=}"
    next_hash="${record[3]#next_sha256=}"
    previous_manifest_hash="${record[4]#previous_manifest_sha256=}"
    next_manifest_hash="${record[5]#next_manifest_sha256=}"
    [[ ( "$previous_hash" == '-' || "$previous_hash" =~ ^[a-f0-9]{64}$ ) &&
       "$next_hash" =~ ^[a-f0-9]{64}$ &&
       ( "$previous_manifest_hash" == '-' || "$previous_manifest_hash" =~ ^[a-f0-9]{64}$ ) &&
       "$next_manifest_hash" =~ ^[a-f0-9]{64}$ &&
       "$previous_hash" != "$next_hash" ]] || return 1
    actual="$(bosh_managed_txn_hash "$dir/next")" || return 1
    [[ "$actual" == "$next_manifest_hash" ]] || return 1
    bosh_managed_txn_validate_next "$dir/next" "$destination" "$next_hash" || return 1

    if [[ "$previous_manifest_hash" == '-' ]]; then
        [[ ! -e "$dir/previous" && ! -L "$dir/previous" ]] || return 1
    else
        actual="$(bosh_managed_txn_hash "$dir/previous")" || return 1
        [[ "$actual" == "$previous_manifest_hash" ]] || return 1
    fi
    if [[ -e "$dir/previous_destination" || -L "$dir/previous_destination" ]]; then
        [[ "$previous_hash" != '-' ]] || return 1
        actual="$(bosh_managed_txn_hash "$dir/previous_destination")" || return 1
        [[ "$actual" == "$previous_hash" ]] || return 1
    fi
    bosh_managed_txn_safe_directory "$(dirname -- "$destination")" || return 1
    [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || return 1
    [[ ! -L "$manifest" && ( ! -e "$manifest" || -f "$manifest" ) ]] || return 1
    if [[ -f "$destination" ]]; then
        destination_hash="$(bosh_managed_txn_hash "$destination")" || return 1
    fi
    if [[ -f "$manifest" ]]; then
        manifest_hash="$(bosh_managed_txn_hash "$manifest")" || return 1
    fi

    if [[ "$destination_hash" == "$next_hash" ]]; then
        if [[ "$manifest_hash" == "$previous_manifest_hash" ]]; then
            write_state "${key}_manifest" "$(cat -- "$dir/next")" || return 1
            manifest_hash="$(bosh_managed_txn_hash "$manifest")" || return 1
        fi
        if [[ "$manifest_hash" != "$next_manifest_hash" ]]; then
            msg error "Transaction manifest differs from expected state: $dir"
            return 1
        fi
        bosh_managed_txn_finish "$dir" "$key" "$destination" || return 1
        msg info "Recovered interrupted managed-file transaction: $destination"
        return 0
    fi

    if [[ "$destination_hash" == "$previous_hash" &&
          "$manifest_hash" == "$previous_manifest_hash" ]]; then
        bosh_managed_txn_finish "$dir" "$key" "$destination" || return 1
        msg info "Cleared uncommitted managed-file transaction: $destination"
        return 0
    fi

    msg error "Ambiguous managed-file transaction; no files changed: $dir"
    return 1
}
