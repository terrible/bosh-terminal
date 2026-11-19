#!/usr/bin/env bash
# Read-only inventory of possible abandoned Bosh Terminal temporary artifacts.
# Deliberately NEVER deletes, renames, chmods, or evaluates file content.
set -Eeuo pipefail
shopt -s nullglob
export LC_ALL=C

usage() {
    cat <<'USAGE'
Usage: bash scripts/audit-temp-artifacts.sh [--help]

Read-only inventory of possible Bosh Terminal temporary artifacts:
  ~/.oh-my-zsh.bosh-tmp.XXXXXX
  $XDG_DATA_HOME/fastfetch/anime/*.png.bosh-{tmp,rollback,restore}.XXXXXX

REVIEW  = plausible leftover, provenance NOT established
WARNING = permissions expose content or checksum cannot be read
UNSAFE  = symbolic link, hard link, wrong owner/type, or unsafe path

Exit status 0: no WARNING/UNSAFE; 2: at least one WARNING/UNSAFE.
No artifact is ever automatically removed.
USAGE
}

if (( $# )); then
    if (( $# == 1 )) && [[ "$1" == --help ]]; then
        usage
        exit 0
    fi
    printf 'Unsupported arguments. Run with --help.\n' >&2
    exit 2
fi

home="${HOME:-}"
data_home="${XDG_DATA_HOME:-$home/.local/share}"
anime_dir="$data_home/fastfetch/anime"
review=0
warning=0
unsafe=0
owner_uid="$(id -u)"

# Avoid following a symlink in any directory component before inspecting files.
safe_dir() {
    local path="$1" part current='/'
    local -a parts=()
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$part" != '.' && "$part" != '..' ]] || return 1
        current="${current%/}/$part"
        [[ ! -L "$current" && -d "$current" ]] || return 1
    done
}

emit() {
    local status="$1" kind="$2" path="$3" reason="$4"
    local quoted
    printf -v quoted '%q' "$path"
    printf '%s\t%s\t%s\t%s\n' "$status" "$kind" "$reason" "$quoted"
    case "$status" in
        REVIEW) review=$((review + 1)) ;;
        WARNING) warning=$((warning + 1)) ;;
        UNSAFE) unsafe=$((unsafe + 1)) ;;
    esac
}

inspect_clone() {
    local path="$1" name="${1##*/}" uid mode nlink
    if [[ ! "$name" =~ ^\.oh-my-zsh\.bosh-tmp\.[A-Za-z0-9]{6}$ ]]; then
        emit UNSAFE omz-stage "$path" "unrecognized-name"
        return
    fi
    if [[ -L "$path" || ! -d "$path" ]]; then
        emit UNSAFE omz-stage "$path" "symlink-or-nondirectory"
        return
    fi
    uid="$(stat -c '%u' -- "$path")" || {
        emit WARNING omz-stage "$path" "unreadable-metadata"
        return
    }
    mode="$(stat -c '%a' -- "$path")" || return 1
    nlink="$(stat -c '%h' -- "$path")" || return 1
    if [[ "$uid" != "$owner_uid" || "$mode" != 700 ]]; then
        emit UNSAFE omz-stage "$path" "owner-or-mode-not-private"
        return
    fi
    # Directories normally have more than one link: don't interpret their
    # nlink as the hardlink count of a regular file.
    if [[ -L "$path/repo" || ( -e "$path/repo" && ! -d "$path/repo" ) ||
          -L "$path/repo/.git" ]]; then
        emit UNSAFE omz-stage "$path" "unsafe-repo-entry"
        return
    fi
    # An in-memory temp registry is lost on SIGKILL. This is only a candidate.
    emit REVIEW omz-stage "$path" "private-dir;ownership-unproven;links=$nlink"
}

inspect_image() {
    local path="$1" name="${1##*/}" kind uid mode links checksum
    local basename
    if [[ ! "$name" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*\.png)\.bosh-(tmp|rollback|restore)\.([A-Za-z0-9]{6})$ ]]; then
        emit UNSAFE anime-stage "$path" "unrecognized-name"
        return
    fi
    basename="${BASH_REMATCH[1]}"
    kind="anime-${BASH_REMATCH[2]}"
    if [[ "$basename" == *'..'* || -L "$path" || ! -f "$path" ]]; then
        emit UNSAFE "$kind" "$path" "symlink-nonregular-or-unsafe-name"
        return
    fi
    uid="$(stat -c '%u' -- "$path")" || {
        emit WARNING "$kind" "$path" "unreadable-metadata"
        return
    }
    mode="$(stat -c '%a' -- "$path")" || return 1
    links="$(stat -c '%h' -- "$path")" || return 1
    if [[ "$uid" != "$owner_uid" || "$links" != 1 ]]; then
        emit UNSAFE "$kind" "$path" "unexpected-owner-or-hardlink"
        return
    fi
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || {
        emit UNSAFE "$kind" "$path" "invalid-file-mode"
        return
    }
    if (( (8#$mode & 0077) != 0 )); then
        emit WARNING "$kind" "$path" "group-or-world-access;mode=$mode"
        return
    fi
    checksum="$(sha256sum -- "$path")" || {
        emit WARNING "$kind" "$path" "unreadable-checksum"
        return
    }
    checksum="${checksum%% *}"
    emit REVIEW "$kind" "$path" "owner-ok;mode=$mode;sha256=$checksum;ownership-unproven"
}

printf 'STATUS\tKIND\tASSESSMENT\tPATH\n'
if ! safe_dir "$home"; then
    emit UNSAFE audit-root "$home" "unsafe-HOME-components"
else
    for candidate in "$home"/.oh-my-zsh.bosh-tmp.*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        inspect_clone "$candidate"
    done
fi

if [[ -e "$anime_dir" || -L "$anime_dir" ]]; then
    if ! safe_dir "$anime_dir"; then
        emit UNSAFE anime-root "$anime_dir" "unsafe-directory-components"
    else
        for candidate in "$anime_dir"/*.png.bosh-*.*; do
            [[ -e "$candidate" || -L "$candidate" ]] || continue
            inspect_image "$candidate"
        done
    fi
fi

printf 'SUMMARY\treview=%d\twarning=%d\tunsafe=%d\n' \
    "$review" "$warning" "$unsafe"
if (( warning > 0 || unsafe > 0 )); then
    exit 2
fi
