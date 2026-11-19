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
    result="$(sha256sum < "$1")" || return 1
    printf '%s\n' "${result%% *}"
}

# Compare inode metadata and content, and reject a change observed while hashing.
# ctime is used only within a read because rename updates it.
bosh_managed_txn_fingerprint() {
    local path="$1" before digest
    local format='%d:%i:%u:%g:%a %s %y %z'
    [[ ! -L "$path" && -f "$path" ]] || return 1
    before="$(stat -c "$format" -- "$path")" || return 1
    digest="$(bosh_managed_txn_hash "$path")" || return 1
    [[ "$(stat -c "$format" -- "$path")" == "$before" ]] || return 1
    printf '%s/%s\n' "${before%% *}" "$digest"
}

bosh_managed_txn_read_record() {
    local file="$1" destination="$2" encoded field index=0
    local -n txn_data="$3"
    local hash='^[a-f0-9]{64}$' identity='^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-7]{1,4}$'
    local -a lines=() fields=(
        version destination_b64 previous_sha256 next_sha256
        previous_manifest_sha256 next_manifest_sha256
    )

    [[ ! -L "$file" && -f "$file" ]] || return 1
    mapfile -t lines < "$file" || return 1
    case "${lines[0]:-}" in
        version=1) ;;
        version=2) fields+=(previous_id next_id slot_suffix slot_id) ;;
        *) return 1 ;;
    esac
    (( ${#lines[@]} == ${#fields[@]} )) || return 1
    for field in "${fields[@]}"; do
        [[ "${lines[index]}" == "$field="* ]] || return 1
        txn_data["$field"]="${lines[index]#*=}"
        index=$((index + 1))
    done

    encoded="$(printf '%s' "$destination" | base64 -w 0)" || return 1
    [[ "${txn_data[destination_b64]}" == "$encoded" &&
       ( "${txn_data[previous_sha256]}" == '-' || "${txn_data[previous_sha256]}" =~ $hash ) &&
       "${txn_data[next_sha256]}" =~ $hash &&
       "${txn_data[previous_sha256]}" != "${txn_data[next_sha256]}" &&
       ( "${txn_data[previous_manifest_sha256]}" == '-' || "${txn_data[previous_manifest_sha256]}" =~ $hash ) &&
       "${txn_data[next_manifest_sha256]}" =~ $hash ]] || return 1

    if [[ "${txn_data[version]}" == 2 ]]; then
        [[ "${txn_data[next_id]}" =~ $identity &&
           "${txn_data[slot_suffix]}" =~ ^[A-Za-z0-9]{8}$ &&
           "${txn_data[slot_id]}" =~ ^[0-9]+:[0-9]+$ &&
           "${txn_data[next_id]%%:*}" == "${txn_data[slot_id]%%:*}" ]] || return 1
        if [[ "${txn_data[previous_sha256]}" == '-' ]]; then
            [[ "${txn_data[previous_id]}" == '-' ]] || return 1
        else
            [[ "${txn_data[previous_id]}" =~ $identity &&
               "${txn_data[previous_id]%%:*}" == "${txn_data[next_id]%%:*}" &&
               "${txn_data[previous_id]}" != "${txn_data[next_id]}" ]] || return 1
        fi
    fi
}

# The slot lives on the destination filesystem even when XDG state does not.
bosh_managed_txn_slot_matches() {
    local slot="$1" slot_id="$2"
    bosh_managed_txn_safe_directory "$slot" || return 1
    [[ "$(stat -c '%d:%i:%u:%a' -- "$slot")" == "$slot_id:$EUID:700" ]]
}

# Probe the destination filesystem with two synthetic inodes before taking
# backups or preparing a replacement. The real exchange must still succeed.
bosh_managed_txn_check_exchange() {
    local destination="$1" parent="${1%/*}/" version probe probe_id device entry entry_id
    local first='' second=''
    local result=1
    local gnu_version='^mv [(]GNU coreutils[)] ([0-9]+)[.]([0-9]+)([.]|[[:space:]]|$)'
    version="$(LC_ALL=C mv --version 2>/dev/null)" || version=''
    if [[ ! "$version" =~ $gnu_version ]] ||
       ! (( 10#${BASH_REMATCH[1]} > 9 ||
              ( 10#${BASH_REMATCH[1]} == 9 && 10#${BASH_REMATCH[2]} >= 5 ) )); then
        msg error "Replacing a managed file requires GNU coreutils 9.5 or newer."
        return 1
    fi

    bosh_managed_txn_safe_directory "$parent" || return 1
    device="$(stat -c '%d' -- "$destination")" || return 1
    if [[ "$(stat -c '%d' -- "$parent")" != "$device" ]]; then
        msg error "Destination and parent must be on the same filesystem for atomic exchange: $destination"
        return 1
    fi

    probe="$(mktemp -d "${parent}.bosh-exchange-probe.XXXXXXXX")" || return 1
    chmod 00700 -- "$probe" || return 1
    probe_id="$(stat -c '%d:%i' -- "$probe")" || return 1
    if (umask 077; set -o noclobber; : > "$probe/first" && : > "$probe/second") &&
       first="$(stat -c '%d:%i' -- "$probe/first")" &&
       second="$(stat -c '%d:%i' -- "$probe/second")" &&
       [[ "$first" != "$second" ]] &&
       mv --exchange --no-copy -T -- "$probe/first" "$probe/second" &&
       [[ "$(stat -c '%d:%i' -- "$probe/first")" == "$second" &&
          "$(stat -c '%d:%i' -- "$probe/second")" == "$first" ]]; then
        result=0
    fi
    bosh_managed_txn_slot_matches "$probe" "$probe_id" || return 1
    for entry in "$probe/first" "$probe/second"; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        entry_id="$(stat -c '%d:%i:%u:%h' -- "$entry")" || return 1
        if [[ -L "$entry" || ! -f "$entry" || -s "$entry" ||
              ( "$entry_id" != "$first:$EUID:1" && "$entry_id" != "$second:$EUID:1" ) ]]; then
            msg error "Unexpected exchange probe entry preserved: $entry"
            return 1
        fi
    done
    rm -f -- "$probe/first" "$probe/second" && rmdir -- "$probe" || return 1
    if (( result )); then
        msg error "Atomic exchange probe failed for the managed destination filesystem: $destination"
        return 1
    fi
}

# Remove only a proven candidate. A displaced inode never takes this
# cleanup path. Missing components allow resumption between unlink and rmdir.
bosh_managed_txn_remove_candidate() {
    local slot="$1" slot_id="$2" expected="$3" links="$4" entry
    [[ -e "$slot" || -L "$slot" ]] || return 0
    # Return 2 for an identity/content conflict and 1 for a cleanup error.
    bosh_managed_txn_slot_matches "$slot" "$slot_id" || return 2
    for entry in "$slot"/* "$slot"/.[!.]* "$slot"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        [[ "$entry" == "$slot/file" ]] || return 2
        [[ "$(bosh_managed_txn_fingerprint "$entry")" == "$expected" &&
           "$(stat -c '%u:%h' -- "$entry")" == "$EUID:$links" ]] || return 2
    done
    rm -f -- "$slot/file" || return 1
    rmdir -- "$slot" || return 1
}

# A receipt written before copying binds the unpublished candidate inode
# to its slot and expected payload. Only empty or complete files qualify.
bosh_managed_txn_reap_preparation() {
    local slot="$1" destination="$2" receipt="$3"
    local slot_id candidate_id expected_hash encoded fingerprint inode digest
    local empty_sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    local -a receipt_lines=()

    [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
    [[ "$(stat -c '%u:%a:%h' -- "$receipt")" == "$EUID:600:1" ]] || return 1
    mapfile -t receipt_lines < "$receipt" || return 1
    (( ${#receipt_lines[@]} == 5 )) || return 1
    encoded="$(printf '%s' "$destination" | base64 -w 0)" || return 1
    [[ "${receipt_lines[0]}" == version=1 &&
       "${receipt_lines[1]}" == "destination_b64=$encoded" &&
       "${receipt_lines[2]}" =~ ^slot_id=([0-9]+:[0-9]+)$ ]] || return 1
    slot_id="${BASH_REMATCH[1]}"
    [[ "${receipt_lines[3]}" =~ ^candidate_id=([0-9]+:[0-9]+)$ ]] || return 1
    candidate_id="${BASH_REMATCH[1]}"
    [[ "${receipt_lines[4]}" =~ ^sha256=([a-f0-9]{64})$ ]] || return 1
    expected_hash="${BASH_REMATCH[1]}"
    [[ "${slot_id%%:*}" == "${candidate_id%%:*}" ]] || return 1
    bosh_managed_txn_slot_matches "$slot" "$slot_id" || return 1

    if [[ -e "$slot/file" || -L "$slot/file" ]]; then
        fingerprint="$(bosh_managed_txn_fingerprint "$slot/file")" || return 1
        inode="${fingerprint%/*}"
        digest="${fingerprint#*/}"
        [[ "$inode" == "$candidate_id:$EUID:"* &&
           ( "$digest" == "$expected_hash" || "$digest" == "$empty_sha256" ) ]] || return 1
    fi
    bosh_managed_txn_remove_candidate "$slot" "$slot_id" "${fingerprint:-}" 1
}

# A detected conflict after manifest publication needs explicit review even
# if later edits make the live bytes look consistent again.
bosh_managed_txn_mark_conflict() {
    local dir="$1"
    if [[ ! -e "$dir/conflict" && ! -L "$dir/conflict" ]]; then
        (umask 077; set -o noclobber; : > "$dir/conflict") || return 1
    fi
    msg error "Published managed manifest has a conflict requiring manual review: $dir"
}

# Completed work may already have pruned the unused candidate or the private
# alias of a published creation.
bosh_managed_txn_phase() {
    local key="$1" destination="$2" completed="$4"
    local -n phase_data="$3"
    local current='-' previous next slot slot_file slot_links
    previous="${phase_data[previous_sha256]}"
    next="${phase_data[next_sha256]}"

    bosh_managed_txn_safe_directory "${destination%/*}/" || return 1
    [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || return 1

    if [[ "${phase_data[version]}" == 1 ]]; then
        if [[ -f "$destination" ]]; then
            current="$(bosh_managed_txn_hash "$destination")" || return 1
        fi
    else
        next="${phase_data[next_id]}/$next"
        if [[ -f "$destination" ]]; then
            current="$(bosh_managed_txn_fingerprint "$destination")" || return 1
        fi
        if [[ "$previous" != '-' ]]; then
            previous="${phase_data[previous_id]}/$previous"
        fi

        slot="${destination%/*}/.bosh-managed-$key.${phase_data[slot_suffix]}"
        slot_file='-'
        if [[ -e "$slot" || -L "$slot" ]]; then
            bosh_managed_txn_slot_matches "$slot" "${phase_data[slot_id]}" || return 1
            if [[ -e "$slot/file" || -L "$slot/file" ]]; then
                slot_file="$(bosh_managed_txn_fingerprint "$slot/file")" || return 1
                slot_links="$(stat -c '%h' -- "$slot/file")" || return 1
            fi
        fi

        if [[ "$current" == "$previous" || "$previous" == '-' ]]; then
            # Creation uses link(2); while pending both names refer to the
            # same candidate inode. Before publication only the slot exists.
            if [[ "$slot_file" == "$next" ]]; then
                if [[ "$previous" == '-' && "$current" == "$next" ]]; then
                    [[ "$slot_links" == 2 ]] || return 1
                else
                    [[ "$slot_links" == 1 ]] || return 1
                fi
            else
                [[ "$completed" == yes && "$slot_file" == '-' ]] || return 1
            fi
        elif [[ "$slot_file" != "$previous" ]]; then
            return 1
        fi
    fi

    case "$current" in
        "$previous") printf 'before\n' ;;
        "$next") printf 'after\n' ;;
        *) return 1 ;;
    esac
}

bosh_managed_txn_manifest_hash() {
    local manifest="$1"
    if [[ ! -e "$manifest" && ! -L "$manifest" ]]; then
        printf '%s\n' '-'
        return
    fi
    [[ ! -L "$manifest" && -f "$manifest" ]] || return 1
    [[ "$(stat -c '%u:%h' -- "$manifest")" == "$EUID:1" ]] || return 1
    bosh_managed_txn_hash "$manifest"
}

bosh_managed_txn_publish_manifest() {
    local key="$1" file="$2" line
    local -a lines=() fields=()
    mapfile -t lines < "$file" || return 1
    for line in "${lines[@]:2}"; do
        fields+=("${line%%=*}" "${line#*=}")
    done
    write_manifest "$key" managed_file "${fields[@]}"
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


bosh_managed_txn_validate_dir() {
    local dir="$1" phase="$2" entry
    bosh_managed_txn_safe_directory "$dir" || return 1
    [[ "$(stat -c '%u:%a' -- "$dir")" == "$EUID:700" ]] || return 1
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case "${entry##*/}" in
            record|next|previous|previous_destination) ;;
            record.tmp) [[ "$phase" == prepare ]] || return 1 ;;
            candidate) ;;
            conflict) [[ "$phase" != prepare ]] || return 1 ;;
            *) msg error "Foreign journal entry preserved: $entry"; return 1 ;;
        esac
        [[ ! -L "$entry" && -f "$entry" ]] || return 1
        [[ "$(stat -c '%u:%h' -- "$entry")" == "$EUID:1" ]] || return 1
    done
}

# Remove only private, regular, single-linked journal artifacts. An interrupted
# cleanup may be retried. Never follow symlinks or recursively remove unknown
# content, and do not touch pending transactions here.
bosh_managed_txn_prune_dir() {
    local key="$1" dir="$2" phase="$3" destination="$4"
    local prefix suffix entry name manifest manifest_hash observed slot record_file links
    local -A record=()
    local cleanup_status=0

    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ && "$destination" == /* ]] || return 1
    [[ "$phase" == prepare || "$phase" == completed ]] || return 1
    prefix="$BOSH_STATE/.${key}.managed-${phase}."
    [[ "$dir" == "$prefix"* ]] || return 1
    suffix="${dir#"$prefix"}"
    [[ "$suffix" =~ ^[A-Za-z0-9]{8}$ ]] || return 1

    bosh_managed_txn_validate_dir "$dir" "$phase" || return 1

    # For a completed journal, prove that the system still matches the state
    # in its record. The record is removed LAST so interrupted cleanup can be
    # retried. An empty directory can arise before the pending rename.
    if [[ "$phase" == completed && -f "$dir/record" ]]; then
        bosh_managed_txn_read_record "$dir/record" "$destination" record || return 1
        if [[ -e "$dir/conflict" ]]; then
            bosh_managed_txn_mark_conflict "$dir"
            return 1
        fi
        manifest="$BOSH_STATE/${key}_manifest"
        manifest_hash="$(bosh_managed_txn_manifest_hash "$manifest")" || return 1
        observed="$(bosh_managed_txn_phase "$key" "$destination" record yes)" || observed=conflict
        if [[ "$manifest_hash" == "${record[next_manifest_sha256]}" ]]; then
            if [[ "$observed" != after ]]; then
                if [[ "${record[version]}" == 2 ]]; then bosh_managed_txn_mark_conflict "$dir"; fi
                return 1
            fi
        elif [[ "$observed" != before || "$manifest_hash" != "${record[previous_manifest_sha256]}" ]]; then
            return 1
        fi
        if [[ "${record[version]}" == 2 &&
              ( "$observed" == before || "${record[previous_sha256]}" == '-' ) ]]; then
            slot="${destination%/*}/.bosh-managed-$key.${record[slot_suffix]}"
            if [[ "$(bosh_managed_txn_phase "$key" "$destination" record yes)" != "$observed" ]]; then
                if [[ "$observed" == after ]]; then
                    bosh_managed_txn_mark_conflict "$dir" || return 1
                fi
                return 1
            fi
            links=1
            if [[ "$observed" == after ]]; then links=2; fi
            bosh_managed_txn_remove_candidate "$slot" "${record[slot_id]}" \
                "${record[next_id]}/${record[next_sha256]}" "$links" || cleanup_status=$?
            if (( cleanup_status )); then
                if [[ "$cleanup_status" == 2 && "$observed" == after ]]; then
                    bosh_managed_txn_mark_conflict "$dir"
                fi
                return 1
            fi
        fi
    elif [[ "$phase" == completed ]]; then
        # Only an empty completed directory can legitimately lack a record.
        rmdir -- "$dir"
        return
    else
        # A complete record in a still-private preparation proves its slot
        # was never published. The slot shares the preparation's suffix.
        slot="${destination%/*}/.bosh-managed-$key.$suffix"
        if [[ -e "$slot" || -L "$slot" ]]; then
            record_file="$dir/record"
            [[ -f "$record_file" ]] || record_file="$dir/record.tmp"
            if bosh_managed_txn_read_record "$record_file" "$destination" record &&
               [[ "${record[version]}" == 2 && "${record[slot_suffix]}" == "$suffix" ]]; then
                bosh_managed_txn_remove_candidate "$slot" "${record[slot_id]}" \
                    "${record[next_id]}/${record[next_sha256]}" 1 || return 1
            elif ! bosh_managed_txn_reap_preparation "$slot" "$destination" "$dir/candidate"; then
                msg error "Unverified managed candidate and preparation preserved: $slot"
                return 1
            fi
        fi
    fi

    # Explicit known-file deletion, not rm -rf. Record is deleted last.
    for name in previous_destination previous next candidate record.tmp record; do
        entry="$dir/$name"
        [[ -e "$entry" || -L "$entry" ]] || continue
        [[ ! -L "$entry" && -f "$entry" ]] || return 1
        [[ "$(stat -c '%u:%h' -- "$entry")" == "$EUID:1" ]] || return 1
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
    local previous_id="$6" source_file="$7" next_fingerprint slot slot_id slot_suffix candidate_id
    local -n prepared_candidate="$8"
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
    chmod 00700 -- "$stage" || return 1
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

    slot_suffix="${stage##*.}"
    slot="${destination%/*}/.bosh-managed-$key.$slot_suffix"
    mkdir -m 700 -- "$slot" || return 1
    chmod 00700 -- "$slot" || return 1
    slot_id="$(stat -c '%d:%i' -- "$slot")" || return 1
    bosh_managed_txn_slot_matches "$slot" "$slot_id" || return 1
    encoded="$(printf '%s' "$destination" | base64 -w 0)" || return 1
    (umask 077; set -o noclobber; : > "$slot/file") || return 1
    candidate_id="$(stat -c '%d:%i' -- "$slot/file")" || return 1
    if ! (umask 077; set -o noclobber; printf '%s\n' version=1 "destination_b64=$encoded" \
        "slot_id=$slot_id" "candidate_id=$candidate_id" "sha256=$next_hash" > "$stage/candidate"); then
        return 1
    fi
    if ! cp -p -- "$source_file" "$slot/file" ||
       ! next_fingerprint="$(bosh_managed_txn_fingerprint "$slot/file")" ||
       [[ "${next_fingerprint#*/}" != "$next_hash" ||
          "$next_fingerprint" != "$candidate_id:$EUID:"* ||
          "$(stat -c '%h' -- "$slot/file")" != 1 ]]; then
        msg error "Managed candidate preparation failed; inspect: $slot"
        return 1
    fi
    [[ "${next_fingerprint%%:*}" == "${slot_id%%:*}" &&
       ( "$previous_id" == '-' || "${previous_id%%:*}" == "${slot_id%%:*}" ) ]] || {
        msg error "Managed candidate and destination must be on the same filesystem: $slot"
        return 1
    }

    if ! (umask 077; printf '%s\n' \
        'version=2' \
        "destination_b64=$encoded" \
        "previous_sha256=$previous_hash" \
        "next_sha256=$next_hash" \
        "previous_manifest_sha256=$old_manifest_hash" \
        "next_manifest_sha256=$next_manifest_hash" \
        "previous_id=$previous_id" \
        "next_id=${next_fingerprint%/*}" \
        "slot_suffix=$slot_suffix" \
        "slot_id=$slot_id" > "$stage/record.tmp"); then
        return 1
    fi
    mv -T -- "$stage/record.tmp" "$stage/record" || return 1
    # The directory rename is the point at which the transaction becomes
    # visible to recovery. Never clobber a concurrently created journal.
    [[ ! -e "$dir" && ! -L "$dir" ]] || return 1
    mv -nT -- "$stage" "$dir" || return 1
    [[ ! -e "$stage" && ! -L "$stage" ]] || return 1
    # This nameref returns the path to the installer.
    # shellcheck disable=SC2034
    prepared_candidate="$slot/file"
}

bosh_managed_txn_finish() {
    local dir="$1" key="$2" destination="$3" completed
    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$dir" == "$BOSH_STATE/.${key}.managed-pending" ]] || return 1
    bosh_managed_txn_validate_dir "$dir" pending || return 1

    completed="$(mktemp -d "$BOSH_STATE/.${key}.managed-completed.XXXXXXXX")" || return 1
    rmdir -- "$completed" || return 1
    mv -T -- "$dir" "$completed" || return 1
    # Do not recursively delete snapshots or unknown files.
    bosh_managed_txn_prune_dir "$key" "$completed" completed "$destination"
}

bosh_managed_txn_recover() {
    local key="$1" destination="$2" required_phase="${3:-}"
    local dir="$BOSH_STATE/.${key}.managed-pending"
    local manifest="$BOSH_STATE/${key}_manifest"
    local previous_hash next_hash previous_manifest_hash next_manifest_hash
    local manifest_hash actual observed slot
    local -A record=()

    [[ "$key" =~ ^[a-zA-Z0-9_-]+$ && "$destination" == /* ]] || return 1
    # Any stale prepare/completed directories are reaped with strict checks.
    bosh_managed_txn_collect "$key" "$destination" || return 1
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        [[ -z "$required_phase" ]]
        return
    fi
    if ! bosh_managed_txn_validate_dir "$dir" pending ||
       [[ -L "$dir/record" || ! -f "$dir/record" ||
          -L "$dir/next" || ! -f "$dir/next" ]]; then
        msg error "Unsafe or incomplete managed transaction; preserved: $dir"
        return 1
    fi
    [[ "$(stat -c '%a' -- "$dir/record")" == 600 ]] || return 1
    [[ "$(stat -c '%a' -- "$dir/next")" == 600 ]] || return 1
    if [[ -e "$dir/conflict" ]]; then
        bosh_managed_txn_mark_conflict "$dir"
        return 1
    fi
    bosh_managed_txn_read_record "$dir/record" "$destination" record || {
        msg error "Invalid transaction record: $dir"
        return 1
    }
    previous_hash="${record[previous_sha256]}"
    next_hash="${record[next_sha256]}"
    previous_manifest_hash="${record[previous_manifest_sha256]}"
    next_manifest_hash="${record[next_manifest_sha256]}"
    actual="$(bosh_managed_txn_hash "$dir/next")" || return 1
    [[ "$actual" == "$next_manifest_hash" ]] || return 1
    bosh_managed_txn_validate_next "$dir/next" "$destination" "$next_hash" || return 1

    if [[ "$previous_manifest_hash" == '-' ]]; then
        [[ ! -e "$dir/previous" && ! -L "$dir/previous" ]] || return 1
    else
        actual="$(bosh_managed_txn_hash "$dir/previous")" || return 1
        [[ "$actual" == "$previous_manifest_hash" ]] || return 1
    fi
    if [[ ( "${record[version]}" == 2 && "$previous_hash" != '-' ) ||
          -e "$dir/previous_destination" || -L "$dir/previous_destination" ]]; then
        [[ "$previous_hash" != '-' ]] || return 1
        actual="$(bosh_managed_txn_hash "$dir/previous_destination")" || return 1
        [[ "$actual" == "$previous_hash" ]] || return 1
    fi
    if ! manifest_hash="$(bosh_managed_txn_manifest_hash "$manifest")"; then
        msg error "Unsafe managed manifest preserved: $manifest"
        return 1
    fi

    observed="$(bosh_managed_txn_phase "$key" "$destination" record no)" || observed=conflict
    if [[ "$observed" == after ]]; then
        if [[ "$manifest_hash" == "$previous_manifest_hash" ]]; then
            if ! bosh_managed_txn_publish_manifest "$key" "$dir/next"; then
                # A failed writer may have already renamed its manifest.
                if [[ "${record[version]}" == 2 &&
                      "$(bosh_managed_txn_manifest_hash "$manifest")" == "$next_manifest_hash" &&
                      "$(bosh_managed_txn_phase "$key" "$destination" record no)" != after ]]; then
                    bosh_managed_txn_mark_conflict "$dir" || return 1
                fi
                msg error "Could not register the managed file; recovery remains pending: $dir"
                return 1
            fi
            manifest_hash="$(bosh_managed_txn_manifest_hash "$manifest")" || return 1
        fi
        if [[ "$manifest_hash" == "$next_manifest_hash" &&
              "$(bosh_managed_txn_phase "$key" "$destination" record no)" == after ]]; then
            if [[ "${record[version]}" == 2 && "$previous_hash" != "-" ]]; then
                slot="${destination%/*}/.bosh-managed-$key.${record[slot_suffix]}"
                msg info "Displaced managed file retained: $slot/file"
            fi
            bosh_managed_txn_finish "$dir" "$key" "$destination" || return 1
            msg info "Finalized managed-file transaction: $destination"
            return 0
        fi
    elif [[ "$observed" == before && -z "$required_phase" &&
            "$manifest_hash" == "$previous_manifest_hash" ]]; then
        bosh_managed_txn_finish "$dir" "$key" "$destination" || return 1
        msg info "Cleared uncommitted managed-file transaction: $destination"
        return 0
    fi

    msg error "Ambiguous managed-file transaction; files preserved: $dir"
    if [[ "${record[version]}" == 2 ]]; then
        if [[ "$manifest_hash" == "$next_manifest_hash" ]]; then
            bosh_managed_txn_mark_conflict "$dir" || return 1
        fi
        slot="${destination%/*}/.bosh-managed-$key.${record[slot_suffix]}"
        msg error "Review managed destination and exchange slot: $destination ; $slot/file"
    fi
    return 1
}
