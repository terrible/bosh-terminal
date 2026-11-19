#!/usr/bin/env bash
# Offline Git fixture. Only the exact official OMZ clone URL is redirected.
test_setup_omz_recovery_git() {
    TEST_REAL_GIT="$(command -v git)" || return 1
    TEST_OMZ_SOURCE="$HOME/omz-test-source"
    TEST_OMZ_REMOTE="https://github.com/ohmyzsh/ohmyzsh.git"
    export TEST_REAL_GIT TEST_OMZ_SOURCE TEST_OMZ_REMOTE
    mkdir -p "$TEST_OMZ_SOURCE/plugins/example" "$HOME/test-bin" || return 1
    printf '# fixture OMZ entry\n' > "$TEST_OMZ_SOURCE/oh-my-zsh.sh"
    printf '# fixture OMZ plugin\n' > "$TEST_OMZ_SOURCE/plugins/example/example.plugin.zsh"
    "$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" init -q || return 1
    "$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" config user.name "Bosh Test"
    "$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" config user.email "test@example.invalid"
    "$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" add .
    "$TEST_REAL_GIT" -C "$TEST_OMZ_SOURCE" commit -qm "Offline OMZ fixture"
    cat > "$HOME/test-bin/git" <<'GIT_MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == clone && "${2:-}" == --depth &&
      "${3:-}" == 1 && "${4:-}" == "$TEST_OMZ_REMOTE" ]]; then
    "$TEST_REAL_GIT" clone --depth 1 "$TEST_OMZ_SOURCE" "${5:?}"
    "$TEST_REAL_GIT" -C "$5" remote set-url origin "$TEST_OMZ_REMOTE"
    exit 0
fi
exec "$TEST_REAL_GIT" "$@"
GIT_MOCK
    chmod 700 "$HOME/test-bin/git"
    PATH="$HOME/test-bin:$PATH"
    export PATH
}
