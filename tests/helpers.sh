#!/usr/bin/env bash

# Shared test helpers for Bosh Terminal.
# Every functional case receives an isolated HOME and XDG environment.

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

TEST_PASS_COUNT=0
TEST_FAIL_COUNT=0
TEST_ACTIVE_HOME=""

test_cleanup_active_home() {
    if [[ -n "${TEST_ACTIVE_HOME:-}" &&
          -d "$TEST_ACTIVE_HOME" ]]; then
        rm -rf -- "$TEST_ACTIVE_HOME"
    fi

    TEST_ACTIVE_HOME=""
}

trap test_cleanup_active_home EXIT

test_case() {
    local case_name="${1:?Missing test name}"
    local case_script=""
    local result=0

    case_script="$(cat)" || return 1

    TEST_ACTIVE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/bosh-terminal-test.XXXXXX")" ||
        return 1

    printf '\n=== %s ===\n' "$case_name"

    if env \
        BOSH_TEST_PROJECT="$TEST_ROOT" \
        HOME="$TEST_ACTIVE_HOME" \
        XDG_CONFIG_HOME="$TEST_ACTIVE_HOME/.config" \
        XDG_STATE_HOME="$TEST_ACTIVE_HOME/.local/state" \
        XDG_DATA_HOME="$TEST_ACTIVE_HOME/.local/share" \
        BOSH_HOME="$TEST_ACTIVE_HOME/.config/bosh-terminal" \
        BOSH_STATE="$TEST_ACTIVE_HOME/.local/state/bosh-terminal" \
        BOSH_BACKUP="$TEST_ACTIVE_HOME/.config/bosh-backups/bosh-terminal" \
        BOSH_LANG=es \
        bash --noprofile --norc -eEuo pipefail -c "$case_script"; then

        TEST_PASS_COUNT=$((TEST_PASS_COUNT + 1))
        printf '[PASS] %s\n' "$case_name"
    else
        result=$?
        TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
        printf '[FAIL] %s (código %s)\n' "$case_name" "$result"
    fi

    test_cleanup_active_home
}

test_summary() {
    printf '\n====================================\n'
    printf ' Bosh Terminal - Test Summary\n'
    printf '====================================\n'
    printf 'Superadas: %s\n' "$TEST_PASS_COUNT"
    printf 'Fallidas:  %s\n' "$TEST_FAIL_COUNT"
    printf '====================================\n'

    [[ "$TEST_FAIL_COUNT" -eq 0 ]]
}
