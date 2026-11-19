#!/usr/bin/env bash
# Recovery for interrupted first-time Oh My Zsh publication.
# Run under the shared Bosh install/uninstall lock. Never execute journal data.

bosh_omz_txn_hash() {
    local value
    [[ ! -L "$1" && -f "$1" ]] || return 1
    value="$(sha256sum -- "$1")" || return 1
    printf '%s\n' "${value%% *}"
}

bosh_omz_txn_tree_hash() {
    local value directory="$1"
    bosh_managed_txn_safe_directory "$directory" || return 1
    [[ ! -L "$directory/oh-my-zsh.sh" && -f "$directory/oh-my-zsh.sh" ]] || return 1
    value="$(tar --sort=name --format=gnu --mtime='@0' \
        --owner=0 --group=0 --numeric-owner --exclude='./.git' \
        -cf - -C "$directory" . | sha256sum)" || return 1
    printf '%s\n' "${value%% *}"
}

bosh_omz_txn_prepare() {
    local commit="$1" tree_hash="$2"
    local manifest_hash payload
    local omz_dir="$HOME/.oh-my-zsh"
    local state_file="$BOSH_STATE/oh_my_zsh_txn"
    local manifest="$BOSH_STATE/oh_my_zsh_manifest"
    local official="https://github.com/ohmyzsh/ohmyzsh.git"

    [[ "$commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ &&
       "$tree_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    bosh_managed_txn_safe_directory "$HOME" || return 1
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    [[ ! -e "$omz_dir" && ! -L "$omz_dir" &&
       ! -e "$state_file" && ! -L "$state_file" &&
       ! -e "$manifest" && ! -L "$manifest" ]] || return 1

    payload="version=1"$'\n'"component=oh_my_zsh"$'\n'"ownership=created"$'\n'\
"commit=$commit"$'\n'"remote=$official"$'\n'"tree_sha256=$tree_hash"
    manifest_hash="$(printf '%s\n' "$payload" | sha256sum)" || return 1
    manifest_hash="${manifest_hash%% *}"

    # The atomic state write publishes the intent before the manifest/dir.
    write_state oh_my_zsh_txn \
        "version=1
component=oh_my_zsh
commit=$commit
tree_sha256=$tree_hash
manifest_sha256=$manifest_hash"
}

bosh_omz_txn_recover() {
    local journal="$BOSH_STATE/oh_my_zsh_txn"
    local manifest="$BOSH_STATE/oh_my_zsh_manifest"
    local omz_dir="$HOME/.oh-my-zsh"
    local official="https://github.com/ohmyzsh/ohmyzsh.git"
    local commit expected_tree expected_manifest
    local manifest_hash='-' actual_commit actual_remote actual_tree
    local actual_uid
    local -a lines=()

    [[ ! -L "$BOSH_STATE" ]] || return 1
    [[ -e "$journal" || -L "$journal" ]] || return 0
    bosh_managed_txn_safe_directory "$BOSH_STATE" || return 1
    bosh_managed_txn_safe_directory "$HOME" || return 1
    [[ ! -L "$journal" && -f "$journal" ]] || return 1
    actual_uid="$(id -u)" || return 1
    [[ "$(stat -c '%u' -- "$journal")" == "$actual_uid" &&
       "$(stat -c '%a' -- "$journal")" == 600 ]] || return 1
    mapfile -t lines < "$journal" || return 1
    (( ${#lines[@]} == 5 )) || return 1
    [[ "${lines[0]}" == 'version=1' &&
       "${lines[1]}" == 'component=oh_my_zsh' &&
       "${lines[2]}" == commit=* &&
       "${lines[3]}" == tree_sha256=* &&
       "${lines[4]}" == manifest_sha256=* ]] || return 1

    commit="${lines[2]#commit=}"
    expected_tree="${lines[3]#tree_sha256=}"
    expected_manifest="${lines[4]#manifest_sha256=}"
    [[ "$commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ &&
       "$expected_tree" =~ ^[a-f0-9]{64}$ &&
       "$expected_manifest" =~ ^[a-f0-9]{64}$ ]] || return 1

    [[ ! -L "$manifest" && ( ! -e "$manifest" || -f "$manifest" ) ]] || return 1
    if [[ -f "$manifest" ]]; then
        manifest_hash="$(bosh_omz_txn_hash "$manifest")" || return 1
    fi
    [[ "$manifest_hash" == '-' || "$manifest_hash" == "$expected_manifest" ]] || {
        msg error "Oh My Zsh manifest differs from pending transaction; preserved."
        return 1
    }

    # Never take ownership of a preexisting or altered repository. A
    # completed publication must match the exact clone and its manifest.
    if [[ -e "$omz_dir" || -L "$omz_dir" ]]; then
        [[ ! -L "$omz_dir" && -d "$omz_dir" &&
           "$manifest_hash" == "$expected_manifest" ]] || return 1
        bosh_managed_txn_safe_directory "$omz_dir" || return 1
        [[ ! -L "$omz_dir/.git" && -d "$omz_dir/.git" ]] || return 1
        actual_remote="$(git -C "$omz_dir" config --get remote.origin.url)" || return 1
        actual_commit="$(git -C "$omz_dir" rev-parse --verify HEAD)" || return 1
        [[ "$actual_remote" == "$official" && "$actual_commit" == "$commit" ]] || {
            msg error "Oh My Zsh checkout differs from pending transaction; preserved."
            return 1
        }
        actual_tree="$(bosh_omz_txn_tree_hash "$omz_dir")" || return 1
        [[ "$actual_tree" == "$expected_tree" ]] || {
            msg error "Oh My Zsh tree changed during interrupted install; preserved."
            return 1
        }
        archive_state oh_my_zsh_txn || return 1
        msg info "Interrupted Oh My Zsh publication finalized."
        return 0
    fi

    if [[ "$manifest_hash" == "$expected_manifest" ]]; then
        archive_state oh_my_zsh_manifest || return 1
    fi
    archive_state oh_my_zsh_txn || return 1
    msg info "Unpublished Oh My Zsh transaction archived; no repository removed."
}
