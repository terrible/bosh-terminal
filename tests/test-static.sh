#!/usr/bin/env bash

set -uo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Auditoría estática del instalador" <<'CASE'
cd "$BOSH_TEST_PROJECT"

echo "=== Sintaxis Bash ==="
bash -n install.sh
bash -n scripts/lib/common.sh
echo "Sintaxis correcta."

echo ""
echo "=== Integridad Zsh C-1 ==="
grep -Fq 'block_sha256' install.sh
if grep -Eq 'needs_migration|expected_block_hash="\$expected_block_hash"' install.sh; then
    echo "ERROR: se encontraron referencias obsoletas."
    exit 1
fi
echo "Integridad basada en block_sha256."

echo ""
echo "=== Archivos administrados C-2 ==="
grep -Fq 'return 2' install.sh
grep -Fq 'if (( status == 2 )); then' install.sh

call_count="$(grep -Fc 'install_managed_file_or_skip \' install.sh || true)"

[[ "$call_count" -eq 5 ]] || {
    echo "ERROR: se esperaban cinco llamadas protegidas; encontradas: $call_count"
    exit 1
}

echo "Las cinco llamadas utilizan la función intermediaria."

echo ""
echo "=== ShellCheck opcional ==="
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x install.sh scripts/lib/common.sh
    echo "ShellCheck superado."
else
    echo "SKIP: ShellCheck no está instalado."
fi

echo ""
echo "Auditoría estática superada."
CASE

test_summary
