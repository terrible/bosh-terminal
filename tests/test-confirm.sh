#!/usr/bin/env bash
set -uo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Confirmation: Spanish affirmative s" <<'CASE'
inner='source "$BOSH_TEST_PROJECT/scripts/lib/common.sh"; confirm "¿Continuar?" "Continue?"'
run_cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"
output="$(printf 's\n' | script -q -e -c "$run_cmd" /dev/null)"
grep -Fq '¿Continuar? [s/N]:' <<< "$output"
CASE

test_case "Confirmation: Spanish affirmative si" <<'CASE'
inner='source "$BOSH_TEST_PROJECT/scripts/lib/common.sh"; confirm "¿Continuar?" "Continue?"'
run_cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"
output="$(printf 'si\n' | script -q -e -c "$run_cmd" /dev/null)"
grep -Fq '¿Continuar? [s/N]:' <<< "$output"
CASE

test_case "Confirmation: English affirmative yes" <<'CASE'
inner='source "$BOSH_TEST_PROJECT/scripts/lib/common.sh"; BOSH_LANG=en; confirm "¿Continuar?" "Continue?"'
run_cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"
output="$(printf 'yes\n' | script -q -e -c "$run_cmd" /dev/null)"
grep -Fq 'Continue? [y/N]:' <<< "$output"
CASE

test_case "Confirmation: negative response is rejected" <<'CASE'
inner='source "$BOSH_TEST_PROJECT/scripts/lib/common.sh"; confirm "¿Continuar?" "Continue?"'
run_cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"

if output="$(printf 'n\n' | script -q -e -c "$run_cmd" /dev/null 2>&1)"; then
    echo "ERROR: se aceptó una respuesta negativa."
    exit 1
else
    result=$?
fi

[[ "$result" -eq 1 ]]
grep -Fq '¿Continuar? [s/N]:' <<< "$output"
CASE

test_case "Confirmation: redirected stdin still uses controlling terminal" <<'CASE'
inner='source "$BOSH_TEST_PROJECT/scripts/lib/common.sh"; confirm "¿Continuar?" "Continue?"'
run_cmd="$(printf '%q ' bash --noprofile --norc -c "$inner") </dev/null"

output="$(printf 's\n' | script -q -e -c "$run_cmd" /dev/null)"
grep -Fq '¿Continuar? [s/N]:' <<< "$output"
CASE

test_case "Confirmation: missing controlling terminal fails safely" <<'CASE'
inner='source "$BOSH_TEST_PROJECT/scripts/lib/common.sh"; confirm "¿Continuar?" "Continue?"'

if output="$(setsid -w bash --noprofile --norc -c "$inner" </dev/null 2>&1)"; then
    echo "ERROR: se permitió confirmar sin terminal."
    exit 1
else
    result=$?
fi

[[ "$result" -eq 1 ]]
grep -Fq 'Interactive confirmation required.' <<< "$output"
CASE

test_summary
