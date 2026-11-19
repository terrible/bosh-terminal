#!/usr/bin/env bash
# Per-image write-ahead ownership journal (process interruption recovery).
# Journal entries are inert data and are never sourced or evaluated.
# Call under the shared Bosh installer/uninstaller flock lock.

bosh_anime_txn_hash() {
    local result
    [[ ! -L "$1" && -f "$1" ]] || return 1
    result="$(sha256sum -- "$1")" || return 1
    printf '%s\n' "${result%% *}"
}

bosh_anime_txn_expected() {
    local filename_encoded="$1" next_hash="$2"
    printf 'version=1\ncomponent=anime_image\nfilename_b64=%s\nsha256=%s\n' \
        "$filename_encoded" "$next_hash"
}

bosh_anime_txn_validate_key() {
    local key="$1" filename="$2" hash
    [[ "$key" =~ ^anime_[a-f0-9]{64}$ ]] || return 1
    [[ "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.png$ &&
       "$filename" != *'..'* ]] || return 1
    hash="$(printf '%s' "$filename" | sha256sum)" || return 1
    [[ "$key" == "anime_${hash%% *}" ]]
}

bosh_anime_txn_prepare() {
    local key="$1" filename="$2" new_hash="$3"
    local destination="$ANIME_DEST/$filename"
    local state="$BOSH_STATE/$key" journal="$BOSH_STATE/${key}_txn"
    local encoded old_hash='-' old_state_hash='-'
    local expected_hash

    bosh_anime_txn_validate_key "$key" "$filename" || return 1
    [[ "$new_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$ANIME_DEST" || return 1
    [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || return 1
    [[ ! -L "$state" && ( ! -e "$state" || -f "$state" ) ]] || return 1
    [[ ! -e "$journal" && ! -L "$journal" ]] || return 1
    if [[ -f "$destination" ]]; then
        old_hash="$(bosh_anime_txn_hash "$destination")" || return 1
    fi
    if [[ -f "$state" ]]; then
        old_state_hash="$(bosh_anime_txn_hash "$state")" || return 1
    fi

    encoded="$(printf '%s' "$filename" | base64 -w 0)" || return 1
    expected_hash="$(bosh_anime_txn_expected "$encoded" "$new_hash" | sha256sum)" || return 1
    expected_hash="${expected_hash%% *}"
    [[ "$old_hash" != "$new_hash" ]] || return 1

    # write_state is an atomic temp-file rename. If the process stops
    # before it succeeds, no destination or ownership record has changed.
    write_state "${key}_txn" \
        "version=1
component=anime_image
filename_b64=$encoded
previous_sha256=$old_hash
next_sha256=$new_hash
previous_state_sha256=$old_state_hash
next_state_sha256=$expected_hash"
}

bosh_anime_txn_recover() {
    local key="$1" filename="$2" encoded
    local destination="$ANIME_DEST/$filename"
    local state="$BOSH_STATE/$key" journal="$BOSH_STATE/${key}_txn"
    local previous_hash next_hash previous_state next_state
    local current_hash='-' current_state='-' expected_payload expected_hash
    local uid
    local -a record=()

    bosh_anime_txn_validate_key "$key" "$filename" || return 1
    [[ ! -L "$BOSH_STATE" ]] || return 1
    [[ -e "$journal" || -L "$journal" ]] || return 0
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$ANIME_DEST" || return 1
    [[ ! -L "$journal" && -f "$journal" ]] || return 1
    uid="$(id -u)" || return 1
    [[ "$(stat -c '%u' -- "$journal")" == "$uid" &&
       "$(stat -c '%a' -- "$journal")" == 600 ]] || return 1
    mapfile -t record < "$journal" || return 1
    (( ${#record[@]} == 7 )) || return 1

    encoded="$(printf '%s' "$filename" | base64 -w 0)" || return 1
    [[ "${record[0]}" == version=1 &&
       "${record[1]}" == component=anime_image &&
       "${record[2]}" == "filename_b64=$encoded" &&
       "${record[3]}" == previous_sha256=* &&
       "${record[4]}" == next_sha256=* &&
       "${record[5]}" == previous_state_sha256=* &&
       "${record[6]}" == next_state_sha256=* ]] || return 1

    previous_hash="${record[3]#previous_sha256=}"
    next_hash="${record[4]#next_sha256=}"
    previous_state="${record[5]#previous_state_sha256=}"
    next_state="${record[6]#next_state_sha256=}"
    [[ ( "$previous_hash" == '-' || "$previous_hash" =~ ^[a-f0-9]{64}$ ) &&
       "$next_hash" =~ ^[a-f0-9]{64}$ &&
       ( "$previous_state" == '-' || "$previous_state" =~ ^[a-f0-9]{64}$ ) &&
       "$next_state" =~ ^[a-f0-9]{64}$ &&
       "$previous_hash" != "$next_hash" ]] || return 1

    expected_payload="$(bosh_anime_txn_expected "$encoded" "$next_hash")" || return 1
    expected_hash="$(printf '%s\n' "$expected_payload" | sha256sum)" || return 1
    [[ "${expected_hash%% *}" == "$next_state" ]] || return 1

    [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || return 1
    [[ ! -L "$state" && ( ! -e "$state" || -f "$state" ) ]] || return 1
    if [[ -f "$destination" ]]; then
        current_hash="$(bosh_anime_txn_hash "$destination")" || return 1
    fi
    if [[ -f "$state" ]]; then
        current_state="$(bosh_anime_txn_hash "$state")" || return 1
    fi

    if [[ "$current_hash" == "$next_hash" ]]; then
        if [[ "$current_state" == "$previous_state" ]]; then
            write_state "$key" "$expected_payload" || return 1
            current_state="$(bosh_anime_txn_hash "$state")" || return 1
        fi
        [[ "$current_state" == "$next_state" ]] || {
            msg error "Anime destination has unexpected ownership state: $filename"
            return 1
        }
        # Retire journal only after verifying both destination and state.
        archive_state "${key}_txn" || return 1
        msg info "Interrupted anime installation recovered: $filename"
        return 0
    fi

    if [[ "$current_hash" == "$previous_hash" &&
          "$current_state" == "$previous_state" ]]; then
        archive_state "${key}_txn" || return 1
        msg info "Unpublished anime transaction archived: $filename"
        return 0
    fi

    msg error "Ambiguous anime transaction; image preserved: $filename"
    return 1
}
