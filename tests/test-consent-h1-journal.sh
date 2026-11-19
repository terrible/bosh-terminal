#!/usr/bin/env bash
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Consent H1: rejected and missing TTY preserve a real pending journal" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

# Produce an authentic interrupted managed-file transaction, not a mock journal.
mkdir -p "$BOSH_HOME"
printf 'PERSONAL-H1\n' > "$BOSH_HOME/starship.toml"
chmod 644 "$BOSH_HOME/starship.toml"
printf 'NEW-H1\n' > "$HOME/replacement"

status=0
bash --noprofile --norc -euo pipefail -c '
  source "$BOSH_TEST_PROJECT/install.sh"
  write_manifest() { exit 86; }
  install_managed_file "$HOME/replacement" "$BOSH_HOME/starship.toml" starship
' >"$HOME/interruption-output" 2>&1 || status=$?

[[ "$status" -eq 86 ]]
pending="$BOSH_STATE/.starship.managed-pending"
[[ -d "$pending" ]]
[[ -f "$pending/record" ]]
[[ -f "$pending/next" ]]
[[ -f "$pending/previous_destination" ]]
[[ "$(cat "$pending/previous_destination")" == "PERSONAL-H1" ]]
[[ "$(cat "$BOSH_HOME/starship.toml")" == "NEW-H1" ]]
[[ ! -e "$BOSH_STATE/starship_manifest" ]]
[[ ! -e "$BOSH_STATE/install.lock" ]]
find "$BOSH_BACKUP" -type f -name starship.toml -print -quit |
  grep -q .

# Snapshot content and metadata for the journal, managed destination,
# backup, and state. Rejection must leave all of them unchanged.
snapshot() {
  local prefix="$1"
  find "$BOSH_STATE" "$BOSH_BACKUP" "$BOSH_HOME" \
    -printf '%p|%y|%m|%n|%s|%T@|%l\n' |
    LC_ALL=C sort > "$HOME/${prefix}-metadata"
  find "$BOSH_STATE" "$BOSH_BACKUP" "$BOSH_HOME" -type f \
    -exec sha256sum -- {} + |
    LC_ALL=C sort > "$HOME/${prefix}-hashes"
}

assert_unchanged() {
  snapshot after
  cmp "$HOME/before-metadata" "$HOME/after-metadata"
  cmp "$HOME/before-hashes" "$HOME/after-hashes"
  [[ ! -e "$BOSH_STATE/install.lock" ]]
  [[ ! -e "$BOSH_STATE/starship_manifest" ]]
  [[ -d "$pending" ]]
  [[ "$(cat "$BOSH_HOME/starship.toml")" == "NEW-H1" ]]
}

snapshot before

# Only preflight and dependency installation are stubbed: the actual
# consent, lock acquisition and H1 recovery implementations are retained.
# The dependency stub prevents package installation even if consent regresses.
inner='
source "$BOSH_TEST_PROJECT/install.sh"
preflight() { :; }
install_dependencies() {
  printf "unexpected-dependencies\n" > "$HOME/dependencies-called"
  return 88
}
main
'
cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"

status=0
printf 'n\n' | script -q -e -c "$cmd" /dev/null \
  >"$HOME/denied-output" 2>&1 || status=$?

[[ "$status" -eq 1 ]]
grep -Fq '¿Autorizas la instalación' "$HOME/denied-output"
[[ ! -e "$HOME/dependencies-called" ]]
assert_unchanged

status=0
setsid -w bash --noprofile --norc -c "$inner" \
  </dev/null >"$HOME/no-tty-output" 2>&1 || status=$?

[[ "$status" -eq 1 ]]
grep -Fq 'Interactive confirmation required.' "$HOME/no-tty-output"
[[ ! -e "$HOME/dependencies-called" ]]
assert_unchanged

echo "Real H1 journal, destination, backup and metadata preserved after denial and no TTY."
CASE

test_summary
