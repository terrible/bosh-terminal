#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Managed publication preserves an edit made at the publication boundary" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
source_file="$HOME/replacement"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$source_file"

# Model an editor saving to this test fixture at the publication boundary.
mv() {
    if [[ "${*: -1}" == "$destination" ]]; then
        printf 'EDITOR\n' > "$destination"
    fi
    command mv "$@"
}

status=0
install_managed_file "$source_file" "$destination" fixture || status=$?
actual="$(cat -- "$destination")"
if (( status == 0 )); then
    printf 'Expected a conflict, got status=%s destination=%s\n' "$status" "$actual" >&2
    exit 1
fi
[[ "$status" == 1 && "$actual" == BOSH ]]
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "${#slots[@]}" -eq 1 && "$(cat -- "${slots[0]}")" == EDITOR ]]
[[ -f "$BOSH_STATE/.fixture.managed-pending/record" ]]
[[ ! -e "$BOSH_STATE/fixture_manifest" ]]
if bosh_managed_txn_recover fixture "$destination"; then
    echo "Recovery accepted the displaced edit" >&2
    exit 1
fi
[[ "$(cat -- "${slots[0]}")" == EDITOR ]]
CASE

test_case "Managed exchange refuses a replacement inode even when its bytes match" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
cp -- "$destination" "$HOME/editor-save"
printf 'BOSH\n' > "$HOME/replacement"
external_inode="$(stat -c '%d:%i' -- "$HOME/editor-save")"

mv() {
    if [[ "${*: -1}" == "$destination" ]]; then
        command mv -T -- "$HOME/editor-save" "$destination"
    fi
    command mv "$@"
}

status=0
install_managed_file "$HOME/replacement" "$destination" fixture || status=$?
[[ "$status" == 1 && "$(cat -- "$destination")" == BOSH ]]
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "${#slots[@]}" -eq 1 ]]
[[ "$(stat -c '%d:%i' -- "${slots[0]}")" == "$external_inode" ]]
[[ "$(cat -- "${slots[0]}")" == ORIGINAL ]]
[[ ! -e "$BOSH_STATE/fixture_manifest" ]]
CASE

test_case "Managed exchange preserves a write through the original descriptor before manifest commit" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"
exec {editor_fd}>>"$destination"

mv() {
    command mv "$@" || return 1
    if [[ "${*: -1}" == "$destination" ]]; then
        printf 'EDITOR\n' >&"$editor_fd"
    fi
}

status=0
install_managed_file "$HOME/replacement" "$destination" fixture || status=$?
exec {editor_fd}>&-
[[ "$status" == 1 && "$(cat -- "$destination")" == BOSH ]]
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "${#slots[@]}" -eq 1 && "$(cat -- "${slots[0]}")" == $'ORIGINAL\nEDITOR' ]]
[[ ! -e "$BOSH_STATE/fixture_manifest" ]]
CASE

test_case "Managed exchange retains the original inode after successful completion" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
chmod 644 -- "$destination"
printf 'BOSH\n' > "$HOME/replacement"
original_inode="$(stat -c '%d:%i' -- "$destination")"
exec {editor_fd}>>"$destination"

install_managed_file "$HOME/replacement" "$destination" fixture
printf 'LATE EDIT\n' >&"$editor_fd"
exec {editor_fd}>&-

slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "${#slots[@]}" -eq 1 ]]
[[ "$(stat -c '%d:%i' -- "${slots[0]}")" == "$original_inode" ]]
[[ "$(stat -c '%a' -- "${slots[0]}")" == 644 ]]
[[ "$(stat -c '%a' -- "${slots[0]%/*}")" == 700 ]]
[[ "$(cat -- "${slots[0]}")" == $'ORIGINAL\nLATE EDIT' ]]
[[ "$(cat -- "$destination")" == BOSH ]]
[[ ! -e "$BOSH_STATE/.fixture.managed-pending" ]]
read_manifest fixture
backup="$(printf '%s' "${BOSH_MANIFEST[backup_path_b64]}" | base64 --decode)"
[[ "$(cat -- "$backup")" == ORIGINAL ]]
CASE

test_case "H1 exchange recovers after SIGKILL on either side of the exchange" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
printf 'BOSH\n' > "$HOME/replacement"
for phase in before after; do
    destination="$HOME/$phase.conf"
    printf 'ORIGINAL\n' > "$destination"
    original_inode="$(stat -c '%d:%i' -- "$destination")"
    status=0
    bash --noprofile --norc -euo pipefail -c '
        source "$BOSH_TEST_PROJECT/install.sh"
        phase="$1"
        destination="$2"
        mv() {
            if [[ "${1:-}" == --exchange && "${*: -1}" == "$destination" ]]; then
                if [[ "$phase" == before ]]; then kill -KILL "$BASHPID"; fi
                command mv "$@" || return 1
                kill -KILL "$BASHPID"
            fi
            command mv "$@"
        }
        install_managed_file "$HOME/replacement" "$destination" "$phase"
    ' _ "$phase" "$destination" || status=$?
    [[ "$status" == 137 && -f "$BOSH_STATE/.${phase}.managed-pending/record" ]]
    [[ ! -e "$BOSH_STATE/${phase}_manifest" ]]
    bosh_managed_txn_recover "$phase" "$destination"
    bosh_managed_txn_recover "$phase" "$destination"
    [[ ! -e "$BOSH_STATE/.${phase}.managed-pending" ]]

    shopt -s nullglob
    slots=("$HOME"/.bosh-managed-"$phase".*/file)
    if [[ "$phase" == before ]]; then
        [[ "$(cat -- "$destination")" == ORIGINAL && ! -e "$BOSH_STATE/${phase}_manifest" ]]
        [[ "${#slots[@]}" -eq 0 ]]
    else
        read_manifest "$phase"
        [[ "$(cat -- "$destination")" == BOSH && "${#slots[@]}" -eq 1 ]]
        [[ "$(stat -c '%d:%i' -- "${slots[0]}")" == "$original_inode" ]]
        [[ "$(cat -- "${slots[0]}")" == ORIGINAL ]]
    fi
done
CASE

test_case "H1 retains a pending conflict if the displaced inode changes at manifest commit" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"
exec {editor_fd}>>"$destination"

mv() {
    command mv "$@" || return 1
    if [[ "${*: -1}" == "$BOSH_STATE/fixture_manifest" ]]; then
        printf 'EDITOR\n' >&"$editor_fd"
    fi
}

status=0
install_managed_file "$HOME/replacement" "$destination" fixture || status=$?
exec {editor_fd}>&-
[[ "$status" == 1 && -f "$BOSH_STATE/fixture_manifest" ]]
[[ -f "$BOSH_STATE/.fixture.managed-pending/record" ]]
if bosh_managed_txn_recover fixture "$destination"; then
    echo "Recovery accepted a conflict after manifest commit" >&2
    exit 1
fi
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "${#slots[@]}" -eq 1 && "$(cat -- "${slots[0]}")" == $'ORIGINAL\nEDITOR' ]]
[[ "$(cat -- "$destination")" == BOSH ]]
CASE

test_case "Managed replacement fails safely when atomic exchange is unavailable" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"
original_inode="$(stat -c '%d:%i' -- "$destination")"

mv() {
    if [[ "${1:-}" == --exchange ]]; then
        return 1
    fi
    command mv "$@"
}

status=0
install_managed_file "$HOME/replacement" "$destination" fixture || status=$?
[[ "$status" == 1 ]]
[[ "$(cat -- "$destination")" == ORIGINAL ]]
[[ "$(stat -c '%d:%i' -- "$destination")" == "$original_inode" ]]
[[ ! -e "$BOSH_STATE/fixture_manifest" && ! -e "$BOSH_BACKUP" ]]
[[ ! -e "$BOSH_STATE/.fixture.managed-pending" ]]
shopt -s nullglob
slots=("$HOME"/.bosh-managed-fixture.* "$HOME"/.bosh-exchange-probe.*)
[[ "${#slots[@]}" -eq 0 ]]
CASE

test_case "Managed creation never adopts an unrelated inode that appears with candidate bytes" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'BOSH\n' > "$HOME/replacement"
ln() {
    cp -- "$HOME/replacement" "$destination"
    command ln "$@"
}

status=0
install_managed_file "$HOME/replacement" "$destination" fixture || status=$?
[[ "$status" == 1 && "$(cat -- "$destination")" == BOSH ]]
[[ -f "$BOSH_STATE/.fixture.managed-pending/record" ]]
if bosh_managed_txn_recover fixture "$destination"; then
    echo "Recovery adopted the externally created file" >&2
    exit 1
fi
[[ ! -e "$BOSH_STATE/fixture_manifest" ]]
CASE

test_case "H1 recovers a version 1 journal created by an older installer" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
pending="$BOSH_STATE/.fixture.managed-pending"
mkdir -p -- "$BOSH_STATE"
mkdir -m 700 -- "$pending"
printf 'BOSH\n' > "$destination"
hash="$(bosh_managed_txn_hash "$destination")"
encoded="$(printf '%s' "$destination" | base64 -w 0)"
(
    umask 077
    printf '%s\n' version=1 component=managed_file "sha256=$hash" preexisting=0 \
        "destination_b64=$encoded" backup_path_b64=- backup_sha256=- original_mode=- > "$pending/next"
    manifest_hash="$(bosh_managed_txn_hash "$pending/next")"
    printf '%s\n' version=1 "destination_b64=$encoded" previous_sha256=- \
        "next_sha256=$hash" previous_manifest_sha256=- "next_manifest_sha256=$manifest_hash" > "$pending/record"
)
bosh_managed_txn_recover fixture "$destination"
read_manifest fixture
[[ "${BOSH_MANIFEST[preexisting]}" == 0 && ! -e "$pending" ]]
CASE

test_case "H1 reclaims a recorded candidate if preparation was interrupted" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"

status=0
(
    mv() {
        if [[ "${*: -1}" == */record ]]; then exit 86; fi
        command mv "$@"
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
[[ "$status" == 86 && "$(cat -- "$destination")" == ORIGINAL ]]
[[ ! -e "$BOSH_STATE/.fixture.managed-pending" ]]
shopt -s nullglob
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "${#slots[@]}" -eq 1 && "$(cat -- "${slots[0]}")" == BOSH ]]
bosh_managed_txn_recover fixture "$destination"
[[ ! -e "${slots[0]%/*}" ]]
[[ "$(cat -- "$destination")" == ORIGINAL ]]
CASE

test_case "H1 finalizes an interrupted creation and removes its private alias" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'BOSH\n' > "$HOME/replacement"

status=0
(
    ln() {
        command ln "$@" || return 1
        exit 86
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
[[ "$status" == 86 && "$(stat -c '%h' -- "$destination")" == 2 ]]
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "${#slots[@]}" -eq 1 && "${slots[0]}" -ef "$destination" ]]
[[ "$(stat -c '%a' -- "${slots[0]%/*}")" == 700 ]]

bosh_managed_txn_recover fixture "$destination"
bosh_managed_txn_recover fixture "$destination"
read_manifest fixture
[[ "${BOSH_MANIFEST[preexisting]}" == 0 ]]
[[ "$(stat -c '%h' -- "$destination")" == 1 && ! -e "${slots[0]%/*}" ]]
CASE

test_case "Managed exchange works in a setgid destination directory" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
mkdir -p -- "$BOSH_HOME" "$BOSH_STATE"
chmod g+s -- "$BOSH_HOME" "$BOSH_STATE"
destination="$BOSH_HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"
install_managed_file "$HOME/replacement" "$destination" fixture
slots=("$BOSH_HOME"/.bosh-managed-fixture.*/file)
[[ "${#slots[@]}" -eq 1 && "$(cat -- "${slots[0]}")" == ORIGINAL ]]
[[ "$(stat -c '%a' -- "${slots[0]%/*}")" == 700 ]]
[[ "$(cat -- "$destination")" == BOSH ]]
CASE

test_case "H1 blocks install and uninstall while a displaced inode has conflicting edits" <<'CASE'
source "$BOSH_TEST_PROJECT/uninstall.sh"
mkdir -p -- "$BOSH_HOME"
destination="$BOSH_HOME/starship.toml"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"

status=0
(
    mv() {
        if [[ "${1:-}" == --exchange && "${*: -1}" == "$destination" ]]; then
            printf 'EXTERNAL\n' > "$destination"
        fi
        command mv "$@"
    }
    install_managed_file "$HOME/replacement" "$destination" starship
) || status=$?
[[ "$status" == 1 ]]
if install_managed_file "$HOME/replacement" "$destination" starship ||
   bosh_uninstall_process_managed_file starship; then
    echo "A retry ignored the pending managed conflict" >&2
    exit 1
fi
slots=("$BOSH_HOME"/.bosh-managed-starship.*/file)
[[ "${#slots[@]}" -eq 1 && "$(cat -- "${slots[0]}")" == EXTERNAL ]]
[[ "$(cat -- "$destination")" == BOSH ]]
[[ ! -e "$BOSH_STATE/starship_manifest" ]]
CASE

test_case "H1 reclaims a complete candidate after SIGKILL before the full record" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"

status=0
(
    cp() {
        command cp "$@" || return 1
        if [[ "${*: -1}" == "$HOME"/.bosh-managed-fixture.*/file ]]; then
            kill -KILL "$BASHPID"
        fi
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
[[ "$status" == 137 ]]
slots=("$HOME"/.bosh-managed-fixture.*/file)
stages=("$BOSH_STATE"/.fixture.managed-prepare.*)
[[ -f "${slots[0]}" && -d "${stages[0]}" && ! -e "${stages[0]}/record" ]]

bosh_managed_txn_recover fixture "$destination"
bosh_managed_txn_recover fixture "$destination"
[[ ! -e "${slots[0]%/*}" && ! -e "${stages[0]}" ]]
[[ "$(cat -- "$destination")" == ORIGINAL ]]
CASE

test_case "H1 can retry cleanup of a receipted empty candidate after a second interruption" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"

status=0
(
    cp() {
        if [[ "${*: -1}" == "$HOME"/.bosh-managed-fixture.*/file ]]; then
            kill -KILL "$BASHPID"
        fi
        command cp "$@"
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
[[ "$status" == 137 ]]
slots=("$HOME"/.bosh-managed-fixture.*/file)
stages=("$BOSH_STATE"/.fixture.managed-prepare.*)
[[ -f "${slots[0]}" && ! -s "${slots[0]}" && -f "${stages[0]}/candidate" ]]

status=0
(
    rm() {
        command rm "$@" || return 1
        if [[ "${*: -1}" == "${slots[0]}" ]]; then
            kill -KILL "$BASHPID"
        fi
    }
    bosh_managed_txn_recover fixture "$destination"
) || status=$?
[[ "$status" == 137 && -d "${slots[0]%/*}" && ! -e "${slots[0]}" ]]
bosh_managed_txn_recover fixture "$destination"
[[ ! -e "${slots[0]%/*}" && ! -e "${stages[0]}" ]]
[[ "$(cat -- "$destination")" == ORIGINAL ]]
CASE

test_case "H1 preserves the journal and slot when a partial candidate cannot be verified" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"

status=0
(
    cp() {
        if [[ "${*: -1}" == "$HOME"/.bosh-managed-fixture.*/file ]]; then
            printf 'PARTIAL' > "${*: -1}"
            kill -KILL "$BASHPID"
        fi
        command cp "$@"
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
[[ "$status" == 137 ]]
slots=("$HOME"/.bosh-managed-fixture.*/file)
stages=("$BOSH_STATE"/.fixture.managed-prepare.*)
if bosh_managed_txn_recover fixture "$destination"; then
    echo 'Unverified candidate was accepted' >&2
    exit 1
fi
[[ -d "${stages[0]}" && "$(cat -- "${slots[0]}")" == PARTIAL ]]
[[ "$(cat -- "$destination")" == ORIGINAL && ! -e "$BOSH_STATE/fixture_manifest" ]]
CASE

test_case "H1 remembers a post-manifest conflict even if the bytes later match" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
manifest="$BOSH_STATE/fixture_manifest"
pending="$BOSH_STATE/.fixture.managed-pending"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"
exec {editor_fd}>>"$destination"
status=0
(
    mv() {
        command mv "$@" || return 1
        if [[ "${*: -1}" == "$manifest" ]]; then
            printf 'EDITOR\n' >&"$editor_fd"
        fi
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
exec {editor_fd}>&-
[[ "$status" == 1 && -f "$manifest" && -d "$pending" ]]
cp -- "$manifest" "$HOME/manifest.saved"
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "$(cat -- "${slots[0]}")" == $'ORIGINAL\nEDITOR' ]]
printf 'ORIGINAL\n' > "${slots[0]}"
if bosh_managed_txn_recover fixture "$destination"; then
    echo 'Previously observed post-commit conflict was forgotten' >&2
    exit 1
fi
[[ -d "$pending" && -f "$pending/conflict" ]]
cmp -s -- "$manifest" "$HOME/manifest.saved"
[[ "$(cat -- "$destination")" == BOSH ]]
CASE

test_case "Managed replacement rejects GNU coreutils 9.4 before backup and preparation" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"

mv() {
    if [[ "${1:-}" == --version ]]; then
        printf 'mv (GNU coreutils) 9.4\n'
        return
    fi
    command mv "$@"
}

if install_managed_file "$HOME/replacement" "$destination" fixture; then
    echo 'Unsupported mv version was accepted' >&2
    exit 1
fi
[[ "$(cat -- "$destination")" == ORIGINAL && ! -e "$BOSH_BACKUP" ]]
[[ ! -e "$BOSH_STATE/.fixture.managed-pending" ]]
shopt -s nullglob
stages=("$BOSH_STATE"/.fixture.managed-prepare.* "$HOME"/.bosh-managed-*)
[[ "${#stages[@]}" == 0 ]]
# A first creation still uses an exclusive link.
install_managed_file "$HOME/replacement" "$HOME/created.conf" created
[[ "$(cat -- "$HOME/created.conf")" == BOSH ]]
CASE

test_case "H1 refuses linked candidate entries after an interrupted preparation" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"

for kind in symlink hardlink; do
    status=0
    (
        cp() {
            command cp "$@" || return 1
            if [[ "${*: -1}" == "$HOME"/.bosh-managed-"$kind".*/file ]]; then
                kill -KILL "$BASHPID"
            fi
        }
        install_managed_file "$HOME/replacement" "$destination" "$kind"
    ) || status=$?
    [[ "$status" == 137 ]]
    slots=("$HOME"/.bosh-managed-"$kind".*/file)
    stages=("$BOSH_STATE"/."$kind".managed-prepare.*)
    external="$HOME/external-$kind"
    if [[ "$kind" == symlink ]]; then
        mv -- "${slots[0]}" "$external"
        ln -s -- "$external" "${slots[0]}"
    else
        ln -- "${slots[0]}" "$external"
    fi
    if bosh_managed_txn_recover "$kind" "$destination"; then
        echo "Recovery accepted a $kind in the candidate slot" >&2
        exit 1
    fi
    [[ -d "${stages[0]}" && "$(cat -- "$external")" == BOSH ]]
    if [[ "$kind" == symlink ]]; then
        [[ -L "${slots[0]}" ]]
    else
        [[ "${slots[0]}" -ef "$external" ]]
    fi
    [[ "$(cat -- "$destination")" == ORIGINAL && ! -e "$BOSH_STATE/${kind}_manifest" ]]
done
CASE

test_case "H1 preserves linked or corrupt installed manifests after SIGKILL at publication" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
manifest="$BOSH_STATE/fixture_manifest"
pending="$BOSH_STATE/.fixture.managed-pending"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"
status=0
(
    mv() {
        command mv "$@" || return 1
        if [[ "${*: -1}" == "$manifest" ]]; then
            kill -KILL "$BASHPID"
        fi
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
[[ "$status" == 137 && -f "$manifest" && -d "$pending" ]]
mv -- "$manifest" "$HOME/manifest.saved"
ln -s -- "$HOME/manifest.saved" "$manifest"
if bosh_managed_txn_recover fixture "$destination"; then
    echo 'Recovery accepted a symlink as the installed manifest' >&2
    exit 1
fi
[[ -L "$manifest" && -d "$pending" ]]
rm -- "$manifest"
ln -- "$HOME/manifest.saved" "$manifest"
if bosh_managed_txn_recover fixture "$destination"; then
    echo 'Recovery accepted a hardlink as the installed manifest' >&2
    exit 1
fi
[[ "$manifest" -ef "$HOME/manifest.saved" && -d "$pending" ]]
rm -- "$manifest"
cp -- "$HOME/manifest.saved" "$manifest"
printf 'CORRUPT\n' >> "$manifest"
cp -- "$manifest" "$HOME/manifest.corrupt"

if bosh_managed_txn_recover fixture "$destination"; then
    echo 'Recovery overwrote or accepted a corrupt published manifest' >&2
    exit 1
fi
cmp -s -- "$manifest" "$HOME/manifest.corrupt"
[[ -d "$pending" && "$(cat -- "$destination")" == BOSH ]]
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ "$(cat -- "${slots[0]}")" == ORIGINAL ]]

# Explicit operator restoration of the verified manifest allows finalization.
cp -- "$HOME/manifest.saved" "$manifest"
bosh_managed_txn_recover fixture "$destination"
bosh_managed_txn_recover fixture "$destination"
[[ ! -e "$pending" && "$(cat -- "${slots[0]}")" == ORIGINAL ]]
CASE

test_case "H1 keeps a completed journal conflicted after SIGKILL and a write on the old inode" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
manifest="$BOSH_STATE/fixture_manifest"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"
exec {editor_fd}>>"$destination"
status=0
(
    mv() {
        command mv "$@" || return 1
        if [[ "${*: -1}" == "$BOSH_STATE"/.fixture.managed-completed.* ]]; then
            printf 'EDITOR\n' >&"$editor_fd"
            kill -KILL "$BASHPID"
        fi
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
exec {editor_fd}>&-
[[ "$status" == 137 && -f "$manifest" ]]
completed=("$BOSH_STATE"/.fixture.managed-completed.*)
slots=("$HOME"/.bosh-managed-fixture.*/file)
[[ -f "${completed[0]}/record" && "$(cat -- "${slots[0]}")" == $'ORIGINAL\nEDITOR' ]]
if bosh_managed_txn_recover fixture "$destination"; then
    echo 'Recovery accepted a conflict during completed cleanup' >&2
    exit 1
fi
[[ -f "${completed[0]}/conflict" ]]
printf 'ORIGINAL\n' > "${slots[0]}"
if bosh_managed_txn_recover fixture "$destination"; then
    echo 'Recovery forgot the completed conflict' >&2
    exit 1
fi
[[ "$(cat -- "$destination")" == BOSH && -f "${completed[0]}/conflict" ]]
CASE

test_case "H1 keeps the journal when committed creation cleanup finds an unexpected slot entry" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'BOSH\n' > "$HOME/replacement"
status=0
(
    mv() {
        command mv "$@" || return 1
        if [[ "${*: -1}" == "$BOSH_STATE"/.fixture.managed-completed.* ]]; then
            local -a slots=("$HOME"/.bosh-managed-fixture.*)
            printf 'FOREIGN\n' > "${slots[0]}/sentinel"
        fi
    }
    install_managed_file "$HOME/replacement" "$destination" fixture
) || status=$?
[[ "$status" == 1 && -f "$BOSH_STATE/fixture_manifest" ]]
completed=("$BOSH_STATE"/.fixture.managed-completed.*)
slots=("$HOME"/.bosh-managed-fixture.*)
[[ -f "${completed[0]}/conflict" && "${slots[0]}/file" -ef "$destination" ]]
[[ "$(cat -- "${slots[0]}/sentinel")" == FOREIGN ]]
mv -- "${slots[0]}/sentinel" "$HOME/evidence"
if bosh_managed_txn_recover fixture "$destination"; then
    echo 'Recovery forgot the conflict found during alias cleanup' >&2
    exit 1
fi
[[ -f "${completed[0]}/conflict" && "$(cat -- "$HOME/evidence")" == FOREIGN ]]
CASE

test_case "Managed exchange probe rejects a successful command that leaves inodes in place" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
destination="$HOME/managed.conf"
printf 'ORIGINAL\n' > "$destination"
printf 'BOSH\n' > "$HOME/replacement"

mv() {
    if [[ "${1:-}" == --exchange ]]; then
        return 0
    fi
    command mv "$@"
}

if install_managed_file "$HOME/replacement" "$destination" fixture; then
    echo 'A successful no-op was accepted as atomic exchange' >&2
    exit 1
fi
[[ "$(cat -- "$destination")" == ORIGINAL && ! -e "$BOSH_BACKUP" ]]
[[ ! -e "$BOSH_STATE/.fixture.managed-pending" ]]
shopt -s nullglob
probes=("$HOME"/.bosh-exchange-probe.*)
[[ "${#probes[@]}" == 0 ]]
CASE

test_summary
