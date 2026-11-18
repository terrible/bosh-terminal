#!/usr/bin/env bash
# Offline fixture for the online launcher. No network or system installs.
# Source only inside an isolated tests/helpers.sh test_case HOME.

online_fixture_setup() {
    mkdir -p "$HOME/test-bin" "$HOME/test-tmp"
    export ONLINE_LOG="$HOME/online-trace.log"
    export ONLINE_PINNED="3fc14e53813bab8d31e16c57c716695549ab9d72"
    export ONLINE_MARKER="$HOME/online-marker"
    export TMPDIR="$HOME/test-tmp"
    export PATH="$HOME/test-bin:$PATH"
    : > "$ONLINE_LOG"
    printf 'KEEP\n' > "$TMPDIR/sentinel"

    cat > "$HOME/test-bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$ONLINE_LOG"
[[ "${1:-}" == -C && -n "${2:-}" ]] || exit 92
worktree="$2"
shift 2
case "${1:-}" in
    init)
        [[ "$*" == "init -q" ]] || exit 92
        [[ "${ONLINE_FAIL_STEP:-}" != init ]] || exit 42
        ;;
    remote)
        [[ "$*" == "remote add origin https://github.com/terrible/bosh-terminal.git" ]] || exit 92
        [[ "${ONLINE_FAIL_STEP:-}" != remote ]] || exit 42
        ;;
    -c)
        if [[ "$*" == "-c protocol.version=2 fetch --quiet --depth 1 origin $ONLINE_PINNED" ]]; then
            [[ "${GIT_TERMINAL_PROMPT:-}" == 0 ]] || exit 92
            [[ "${ONLINE_FAIL_STEP:-}" != fetch ]] || exit 42
        elif [[ "$*" == "-c advice.detachedHead=false checkout --quiet --detach $ONLINE_PINNED" ]]; then
            [[ "${ONLINE_FAIL_STEP:-}" != checkout ]] || exit 42
            mkdir -p "$worktree/scripts/lib"
            if [[ "${ONLINE_MISSING_FILE:-}" != install ]]; then
                cat > "$worktree/install.sh" <<'MOCK_INSTALL'
#!/usr/bin/env bash
set -euo pipefail
[[ -t 0 ]] || exit 31
printf 'child-tty-ok\n' >> "$ONLINE_LOG"
if [[ "${ONLINE_ASK_PROMPT:-0}" == 1 ]]; then
    printf 'CONFIRM? '
    IFS= read -r answer || exit 32
    [[ "$answer" == yes ]] || exit 33
fi
printf 'child-started\n' >> "$ONLINE_LOG"
exit "${ONLINE_CHILD_RC:-0}"
MOCK_INSTALL
            fi
            if [[ "${ONLINE_MISSING_FILE:-}" != common ]]; then
                printf '# mock library\n' > "$worktree/scripts/lib/common.sh"
            fi
        else
            exit 92
        fi
        ;;
    rev-parse)
        [[ "$*" == "rev-parse --verify FETCH_HEAD^{commit}" ]] || exit 92
        [[ "${ONLINE_FAIL_STEP:-}" != verify ]] || exit 42
        printf '%s\n' "${ONLINE_ACTUAL_SHA:-$ONLINE_PINNED}"
        ;;
    *)
        exit 92
        ;;
esac
MOCK_GIT
    chmod 700 "$HOME/test-bin/git"
}

online_run_tty() {
    # The launcher's stdin can be a pipe while /dev/tty remains interactive.
    local command_string="$1"
    local input="${2:-}"
    local result=0
    if printf '%s' "$input" | script -q -e -c "$command_string" /dev/null > "$HOME/online-output.log" 2>&1; then
        return 0
    else
        result=$?
    fi
    return "$result"
}

online_assert_clean() {
    [[ "$(cat "$TMPDIR/sentinel")" == KEEP ]] || return 1
    [[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'bosh-terminal-online.*' -print -quit)" ]]
}

online_assert_not_run() {
    [[ ! -e "$ONLINE_MARKER" ]] || return 1
    ! grep -Fqx 'child-started' "$ONLINE_LOG"
}
