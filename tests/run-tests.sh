#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

printf '\n====================================\n'
printf ' Bosh Terminal - Test Suite\n'
printf '====================================\n'

shopt -s nullglob
suites=("$TEST_DIR"/test-*.sh)

if (( ${#suites[@]} == 0 )); then
    echo "ERROR: no se encontraron módulos de pruebas."
    exit 1
fi

passed=0
failed=0

for suite in "${suites[@]}"; do
    name="${suite##*/}"

    printf '\n------------------------------------\n'
    printf ' Ejecutando: %s\n' "$name"
    printf '%s\n' '------------------------------------'

    if bash "$suite"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

printf '\n====================================\n'
printf ' Resultado global\n'
printf '====================================\n'
printf 'Módulos superados: %s\n' "$passed"
printf 'Módulos fallidos:  %s\n' "$failed"
printf '====================================\n'

(( failed == 0 ))
