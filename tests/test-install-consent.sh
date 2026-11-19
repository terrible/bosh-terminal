#!/usr/bin/env bash
set -uo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Consent: negative answer prevents lock" <<'CASE'
inner='
source "$BOSH_TEST_PROJECT/install.sh"
preflight() { :; }
acquire_install_lock() {
  mkdir -p "$BOSH_STATE"
  return 77
}
main
'
cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"

if output="$(printf 'n\n' | script -q -e -c "$cmd" /dev/null 2>&1)"; then
  echo "ERROR: negative answer accepted"
  exit 1
fi

grep -Fq '¿Autorizas la instalación' <<< "$output"
[[ ! -e "$BOSH_STATE" ]]
CASE

test_case "Consent: empty answer prevents lock" <<'CASE'
inner='
source "$BOSH_TEST_PROJECT/install.sh"
preflight() { :; }
acquire_install_lock() {
  mkdir -p "$BOSH_STATE"
  return 77
}
main
'
cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"

if printf '\n' | script -q -e -c "$cmd" /dev/null >/dev/null 2>&1; then
  echo "ERROR: empty answer accepted"
  exit 1
fi

[[ ! -e "$BOSH_STATE" ]]
CASE

test_case "Consent: missing TTY prevents lock" <<'CASE'
inner='
source "$BOSH_TEST_PROJECT/install.sh"
preflight() { :; }
acquire_install_lock() {
  mkdir -p "$BOSH_STATE"
  return 77
}
main
'

if setsid -w bash --noprofile --norc -c "$inner" \
    </dev/null >/dev/null 2>&1; then
  echo "ERROR: consent accepted without TTY"
  exit 1
fi

[[ ! -e "$BOSH_STATE" ]]
CASE

test_case "Consent: affirmative reaches lock" <<'CASE'
inner='
source "$BOSH_TEST_PROJECT/install.sh"
preflight() { :; }
acquire_install_lock() {
  printf "called\n" > "$HOME/lock-called"
  return 77
}
main
'
cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"

printf 's\n' | script -q -e -c "$cmd" /dev/null \
    >"$HOME/consent-output" 2>&1 || result=$?

[[ "${result:-0}" -eq 1 ]]
[[ "$(cat "$HOME/lock-called")" == "called" ]]
grep -Fq '¿Autorizas la instalación' "$HOME/consent-output"
CASE

test_case "Consent: pending recovery remains untouched" <<'CASE'
mkdir -p "$BOSH_STATE"
printf 'pending-journal\n' > "$BOSH_STATE/pending-sentinel"

before="$(sha256sum "$BOSH_STATE/pending-sentinel")"

inner='
source "$BOSH_TEST_PROJECT/install.sh"
preflight() { :; }

acquire_install_lock() {
  printf "lock-called\n" > "$HOME/lock-called"
  return 77
}

bosh_managed_txn_recover() {
  printf "recovery-called\n" > "$HOME/recovery-called"
  return 77
}

main
'

if setsid -w bash --noprofile --norc -c "$inner" \
    </dev/null >"$HOME/recovery-output" 2>&1; then
  echo "ERROR: installation accepted without TTY"
  exit 1
else
  result=$?
fi

[[ "$result" -eq 1 ]]
grep -Fq 'Interactive confirmation required.' \
  "$HOME/recovery-output"

after="$(sha256sum "$BOSH_STATE/pending-sentinel")"

[[ "$before" == "$after" ]]
[[ ! -e "$HOME/lock-called" ]]
[[ ! -e "$HOME/recovery-called" ]]
[[ ! -e "$BOSH_STATE/install.lock" ]]
CASE

test_case "Consent: terminal EOF prevents lock" <<'CASE'
inner='
source "$BOSH_TEST_PROJECT/install.sh"
preflight() { :; }
acquire_install_lock() {
  printf "called\n" > "$HOME/lock-called"
  return 77
}
main
'

cmd="$(printf '%q ' bash --noprofile --norc -c "$inner")"

# EOF en la entrada de una pseudoterminal.
if timeout 10s script -q -e -c "$cmd" /dev/null \
    </dev/null >"$HOME/eof-output" 2>&1; then
  echo "ERROR: EOF accepted"
  exit 1
fi

[[ ! -e "$HOME/lock-called" ]]
[[ ! -e "$BOSH_STATE" ]]
CASE

test_summary
