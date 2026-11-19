#!/usr/bin/env bash

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

TEST_OMZ_REMOTE="https://github.com/ohmyzsh/ohmyzsh.git"

test_setup_omz_git() {
    local source="$HOME/omz-source"
    local bin="$HOME/test-bin"

    TEST_REAL_GIT="$(command -v git)" || return 1
    TEST_OMZ_SOURCE="$source"
    TEST_OMZ_REMOTE="https://github.com/ohmyzsh/ohmyzsh.git"
    export TEST_REAL_GIT TEST_OMZ_SOURCE TEST_OMZ_REMOTE

    mkdir -p "$source/plugins/example" "$bin" || return 1
    printf '%s\n' '# Test entry point' > "$source/oh-my-zsh.sh"
    printf '%s\n' '# Test plugin' > "$source/plugins/example/example.plugin.zsh"

    "$TEST_REAL_GIT" -C "$source" init -q || return 1
    "$TEST_REAL_GIT" -C "$source" config user.name "Bosh Test"
    "$TEST_REAL_GIT" -C "$source" config user.email "bosh-test@example.invalid"
    "$TEST_REAL_GIT" -C "$source" add .
    "$TEST_REAL_GIT" -C "$source" commit -qm "Initial test commit"

    cat > "$bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == clone && "${2:-}" == --depth &&
      "${3:-}" == 1 && "${4:-}" == "$TEST_OMZ_REMOTE" ]]; then
    "$TEST_REAL_GIT" clone --depth 1 "$TEST_OMZ_SOURCE" "${5:?}"
    "$TEST_REAL_GIT" -C "$5" remote set-url origin "$TEST_OMZ_REMOTE"
    exit
fi
exec "$TEST_REAL_GIT" "$@"
GIT
    chmod 700 "$bin/git"
    PATH="$bin:$PATH"
    export PATH
}

export -f test_setup_omz_git

test_case "E2E: instalación completa, repetición y personalizaciones" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
request_install_consent() {
    # Consentimiento simulado solo en este caso aislado.
    return 0
}

test_setup_omz_git
package_installed() { return 0; }

printf '%s\n' 'alias bosh-e2e="echo preserved"' > "$HOME/.zshrc"

main

[[ -f "$BOSH_HOME/zshrc" ]]
[[ -f "$BOSH_HOME/starship.toml" ]]
[[ -f "$BOSH_HOME/fastfetch.jsonc" ]]
[[ -f "$HOME/.zshrc" ]]
grep -Fq 'alias bosh-e2e=' "$HOME/.zshrc"
grep -Fq '# >>> Bosh Terminal >>>' "$HOME/.zshrc"
[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]
[[ -f "$KONSOLE_DIR/bosh.profile" ]]
[[ -f "$KONSOLE_DIR/Utterly-Sweet-Konsole.colorscheme" ]]

images=("$ANIME_DEST"/*.png)
[[ "${#images[@]}" -eq 5 ]]

printf '\n# E2E local customization\n' >> "$BOSH_HOME/starship.toml"
printf '\n# E2E local image customization\n' >> "$ANIME_DEST/bosh1.png"
printf '\n# E2E local plugin customization\n' >> "$HOME/.oh-my-zsh/plugins/example/example.plugin.zsh"
printf '\n# E2E local Konsole customization\n' >> "$KONSOLE_DIR/bosh.profile"

trap - EXIT HUP INT TERM
if [[ -n "$BOSH_LOCK_FD" ]]; then
    flock -u "$BOSH_LOCK_FD"
    exec {BOSH_LOCK_FD}>&-
    BOSH_LOCK_FD=""
fi

main

grep -Fq '# E2E local customization' "$BOSH_HOME/starship.toml"
grep -Fq 'E2E local image customization' "$ANIME_DEST/bosh1.png"
grep -Fq 'E2E local plugin customization' "$HOME/.oh-my-zsh/plugins/example/example.plugin.zsh"
grep -Fq 'E2E local Konsole customization' "$KONSOLE_DIR/bosh.profile"
grep -Fq 'alias bosh-e2e=' "$HOME/.zshrc"
grep -Fq '# >>> Bosh Terminal >>>' "$HOME/.zshrc"

echo "Instalación inicial, repetición y personalizaciones verificadas."
CASE

test_case "E2E: symlink en .zshrc aborta antes de modificar el sistema" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

package_installed() { return 0; }
printf '%s\n' 'external zshrc' > "$HOME/external-zshrc"
ln -s "$HOME/external-zshrc" "$HOME/.zshrc"

if main; then
    echo "ERROR: main aceptó un .zshrc simbólico."
    exit 1
fi

[[ -L "$HOME/.zshrc" ]]
grep -Fxq 'external zshrc' "$HOME/external-zshrc"
[[ ! -e "$BOSH_STATE" ]]

echo "Symlink rechazado durante preflight; estado intacto."
CASE


test_case "E2E S4: bloque eliminado, manifiesto huérfano y reintegración" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
request_install_consent() {
    # Consentimiento simulado solo en este caso aislado.
    return 0
}
test_setup_omz_git
package_installed() { return 0; }

printf '%s\n' 'alias bosh-e2e="echo preserved"' > "$HOME/.zshrc"
main

sed -i '/^# >>> Bosh Terminal >>>$/,/^# <<< Bosh Terminal <<<$/{d;}' "$HOME/.zshrc"
! grep -Fq '# >>> Bosh Terminal >>>' "$HOME/.zshrc"

trap - EXIT HUP INT TERM
flock -u "$BOSH_LOCK_FD"
exec {BOSH_LOCK_FD}>&-
BOSH_LOCK_FD=""

output="$(main 2>&1)"
printf '%s\n' "$output"

grep -Fq 'Found an orphaned Zsh integration state record' <<< "$output"
grep -Fq 'State record archived and verified' <<< "$output"
grep -Fqx 'alias bosh-e2e="echo preserved"' "$HOME/.zshrc"
[[ "$(grep -Fxc '# >>> Bosh Terminal >>>' "$HOME/.zshrc")" == 1 ]]
[[ "$(grep -Fxc '# <<< Bosh Terminal <<<' "$HOME/.zshrc")" == 1 ]]

shopt -s nullglob
archives=("$BOSH_STATE"/zshrc_manifest.archived-*)
[[ "${#archives[@]}" -eq 1 ]]
[[ -f "$BOSH_STATE/zshrc_manifest" ]]

echo "Manifiesto huérfano archivado; integración reconstruida y alias preservado."
CASE

test_case "E2E S10: edición del bloque Zsh preservada durante reinstalación" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"
request_install_consent() {
    # Consentimiento simulado solo en este caso aislado.
    return 0
}
test_setup_omz_git
package_installed() { return 0; }

printf '%s\n' 'alias bosh-e2e="echo preserved"' > "$HOME/.zshrc"
main

sed -i '/^source /s/$/ # modified-by-e2e/' "$HOME/.zshrc"
grep -Fq 'modified-by-e2e' "$HOME/.zshrc"

before="$(sha256sum "$HOME/.zshrc")"
before="${before%% *}"
manifest_before="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
manifest_before="${manifest_before%% *}"

trap - EXIT HUP INT TERM
flock -u "$BOSH_LOCK_FD"
exec {BOSH_LOCK_FD}>&-
BOSH_LOCK_FD=""

output="$(main 2>&1)"
printf '%s\n' "$output"

after="$(sha256sum "$HOME/.zshrc")"
after="${after%% *}"
manifest_after="$(sha256sum "$BOSH_STATE/zshrc_manifest")"
manifest_after="${manifest_after%% *}"

[[ "$before" == "$after" ]]
[[ "$manifest_before" == "$manifest_after" ]]
grep -Fq 'modified-by-e2e' "$HOME/.zshrc"
grep -Fq 'alias bosh-e2e="echo preserved"' "$HOME/.zshrc"

echo "Bloque editado y manifiesto preservados durante main()."
CASE

test_summary
