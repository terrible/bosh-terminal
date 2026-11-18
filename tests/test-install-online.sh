#!/usr/bin/env bash
# Tests for the one-command launcher: all network and installer actions mocked.
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Online: help is safe and does not fetch code" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
output="$(bash "$BOSH_TEST_PROJECT/install-online.sh" --help)"
[[ "$output" == *'Usage: curl -fsSL'* ]]
[[ ! -s "$ONLINE_LOG" ]]
online_assert_clean
CASE

test_case "Online: unknown options fail before fetching" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
if bash "$BOSH_TEST_PROJECT/install-online.sh" --unexpected > "$HOME/output" 2>&1; then
    echo 'ERROR: unknown option accepted'; exit 1
fi
grep -q 'Unknown arguments' "$HOME/output"
[[ ! -s "$ONLINE_LOG" ]]
online_assert_clean
CASE

test_case "Online: no controlling TTY fails before fetching" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
if bash "$BOSH_TEST_PROJECT/install-online.sh" </dev/null > "$HOME/output" 2>&1; then
    echo 'ERROR: no-TTY invocation accepted'; exit 1
fi
grep -q 'interactive terminal is required' "$HOME/output"
[[ ! -s "$ONLINE_LOG" ]]
online_assert_clean
CASE

test_case "Online: missing git is rejected before writing files" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
mkdir -p "$HOME/limited-bin"
ln -s "$(command -v bash)" "$HOME/limited-bin/bash"
if PATH="$HOME/limited-bin" "$HOME/limited-bin/bash" "$BOSH_TEST_PROJECT/install-online.sh" > "$HOME/output" 2>&1; then
    echo 'ERROR: missing git was accepted'; exit 1
fi
grep -q 'Missing required command: git' "$HOME/output"
[[ ! -s "$ONLINE_LOG" ]]
online_assert_clean
CASE

test_case "Online: piped launcher uses /dev/tty and runs verified child" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_ASK_PROMPT=1
online_run_tty "cat '$BOSH_TEST_PROJECT/install-online.sh' | bash" $'yes\n'
grep -Fxq 'child-tty-ok' "$ONLINE_LOG"
grep -Fxq 'child-started' "$ONLINE_LOG"
grep -Fq 'remote add origin https://github.com/terrible/bosh-terminal.git' "$ONLINE_LOG"
grep -Fq "fetch --quiet --depth 1 origin $ONLINE_PINNED" "$ONLINE_LOG"
grep -Fq "checkout --quiet --detach $ONLINE_PINNED" "$ONLINE_LOG"
online_assert_clean
CASE

test_case "Online: user rejects child confirmation" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_ASK_PROMPT=1
if online_run_tty "cat '$BOSH_TEST_PROJECT/install-online.sh' | bash" $'no\n'; then
    echo 'ERROR: user refusal ignored'; exit 1
fi
! grep -Fxq 'child-started' "$ONLINE_LOG"
grep -Fxq 'child-tty-ok' "$ONLINE_LOG"
online_assert_clean
CASE

test_case "Online: fetch failure never starts installer" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_FAIL_STEP=fetch
if online_run_tty "bash '$BOSH_TEST_PROJECT/install-online.sh'"; then
    echo 'ERROR: failed fetch accepted'; exit 1
fi
grep -q 'Cannot fetch pinned revision' "$HOME/online-output.log"
online_assert_not_run
online_assert_clean
CASE

test_case "Online: mismatch SHA blocks execution" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_ACTUAL_SHA=1111111111111111111111111111111111111111
if online_run_tty "bash '$BOSH_TEST_PROJECT/install-online.sh'"; then
    echo 'ERROR: wrong SHA accepted'; exit 1
fi
grep -q 'Revision mismatch' "$HOME/online-output.log"
! grep -q 'checkout' "$ONLINE_LOG"
online_assert_not_run
online_assert_clean
CASE

test_case "Online: rev-parse failure blocks execution" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_FAIL_STEP=verify
if online_run_tty "bash '$BOSH_TEST_PROJECT/install-online.sh'"; then
    echo 'ERROR: missing revision verification accepted'; exit 1
fi
grep -q 'Cannot verify downloaded revision' "$HOME/online-output.log"
online_assert_not_run
online_assert_clean
CASE

test_case "Online: checkout failure blocks execution" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_FAIL_STEP=checkout
if online_run_tty "bash '$BOSH_TEST_PROJECT/install-online.sh'"; then
    echo 'ERROR: failed checkout accepted'; exit 1
fi
grep -q 'Cannot check out verified revision' "$HOME/online-output.log"
online_assert_not_run
online_assert_clean
CASE

test_case "Online: missing install.sh is rejected" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_MISSING_FILE=install
if online_run_tty "bash '$BOSH_TEST_PROJECT/install-online.sh'"; then
    echo 'ERROR: missing installer accepted'; exit 1
fi
grep -q 'Required installer files are missing' "$HOME/online-output.log"
online_assert_not_run
online_assert_clean
CASE

test_case "Online: missing common library is rejected" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_MISSING_FILE=common
if online_run_tty "bash '$BOSH_TEST_PROJECT/install-online.sh'"; then
    echo 'ERROR: missing common library accepted'; exit 1
fi
grep -q 'Required installer files are missing' "$HOME/online-output.log"
online_assert_not_run
online_assert_clean
CASE

test_case "Online: child installer failure propagates and cleans up" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_CHILD_RC=47
result=0
online_run_tty "bash '$BOSH_TEST_PROJECT/install-online.sh'" || result=$?
[[ "$result" -eq 47 ]]
grep -Fxq 'child-started' "$ONLINE_LOG"
online_assert_clean
CASE

test_case "Online: git init error blocks fetch and preserves sentinel" <<'CASE'
source "$BOSH_TEST_PROJECT/tests/online-fixture.sh"
online_fixture_setup
export ONLINE_FAIL_STEP=init
if online_run_tty "bash '$BOSH_TEST_PROJECT/install-online.sh'"; then
    echo 'ERROR: git init failure accepted'; exit 1
fi
! grep -q 'fetch' "$ONLINE_LOG"
online_assert_not_run
online_assert_clean
CASE

test_summary
