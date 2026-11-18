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

bosh_managed_txn_prepare() {
    local key="$1" destination="$2" previous_hash="$3" next_hash="$4" payload="$5"
    local dir="$BOSH_STATE/.${key}.managed-pending"
    local manifest="$BOSH_STATE/${key}_manifest"
    local old_manifest_hash='-' next_manifest_hash encoded

    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ && "$destination" == /* ]] || return 1
    [[ "$next_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$previous_hash" == '-' || "$previous_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$next_hash" != "$previous_hash" ]] || return 1
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$(dirname -- "$destination")" || return 1
    [[ ! -e "$dir" && ! -L "$dir" ]] || return 1
    [[ ! -L "$manifest" && ( ! -e "$manifest" || -f "$manifest" ) ]] || return 1

    (umask 077; mkdir -m 700 -- "$dir") || return 1
    if ! (umask 077; printf '%s\n' "$payload" > "$dir/next"); then
        return 1
    fi
    bosh_managed_txn_validate_next "$dir/next" "$destination" "$next_hash" || return 1
    next_manifest_hash="$(bosh_managed_txn_hash "$dir/next")" || return 1

    if [[ -f "$manifest" ]]; then
        cp -p -- "$manifest" "$dir/previous" || return 1
        chmod 600 -- "$dir/previous" || return 1
        old_manifest_hash="$(bosh_managed_txn_hash "$dir/previous")" || return 1
        [[ "$(bosh_managed_txn_hash "$manifest")" == "$old_manifest_hash" ]] || return 1
    fi

    # Keep the original destination snapshot inside the private journal.
    if [[ "$previous_hash" != '-' ]]; then
        cp -p -- "$destination" "$dir/previous_destination" || return 1
        [[ "$(bosh_managed_txn_hash "$dir/previous_destination")" == "$previous_hash" ]] || return 1
    fi

    encoded="$(printf '%s' "$destination" | base64 -w 0)" || return 1
    if ! (umask 077; printf '%s\n' \
        'version=1' \
        "destination_b64=$encoded" \
        "previous_sha256=$previous_hash" \
        "next_sha256=$next_hash" \
        "previous_manifest_sha256=$old_manifest_hash" \
        "next_manifest_sha256=$next_manifest_hash" > "$dir/record.tmp"); then
        return 1
    fi
    mv -T -- "$dir/record.tmp" "$dir/record" || return 1
}

bosh_managed_txn_finish() {
    local dir="$1" key="$2" completed
    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$dir" == "$BOSH_STATE/.${key}.managed-pending" ]] || return 1
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$dir" || return 1
    completed="$(mktemp -d "$BOSH_STATE/.${key}.managed-completed.XXXXXXXX")" || return 1
    rmdir -- "$completed" || return 1
    mv -T -- "$dir" "$completed" || return 1
    rm -rf -- "$completed" || {
        msg warning "Committed transaction journal needs cleanup: $completed"
        return 0
    }
}

bosh_managed_txn_recover() {
    local key="$1" destination="$2"
    local dir="$BOSH_STATE/.${key}.managed-pending"
    local manifest="$BOSH_STATE/${key}_manifest"
    local expected_encoded previous_hash next_hash previous_manifest_hash next_manifest_hash
    local destination_hash='-' manifest_hash='-' actual
    local -a record=()

    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ && "$destination" == /* ]] || return 1
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
        bosh_managed_txn_finish "$dir" "$key" || return 1
        msg info "Recovered interrupted managed-file transaction: $destination"
        return 0
    fi

    if [[ "$destination_hash" == "$previous_hash" &&
          "$manifest_hash" == "$previous_manifest_hash" ]]; then
        bosh_managed_txn_finish "$dir" "$key" || return 1
        msg info "Cleared uncommitted managed-file transaction: $destination"
        return 0
    fi

    msg error "Ambiguous managed-file transaction; no files changed: $dir"
    return 1
}
