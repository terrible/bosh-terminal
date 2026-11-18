#!/usr/bin/env bash
# Bosh Terminal online installer — review candidate.
# Downloads a fixed, reviewed Git commit before running the local installer.
set -Eeuo pipefail

readonly REPOSITORY_URL="https://github.com/terrible/bosh-terminal.git"
readonly PINNED_COMMIT="3fc14e53813bab8d31e16c57c716695549ab9d72"

die() { printf 'Bosh Terminal: %s\n' "$*" >&2; exit 1; }
info() { printf 'Bosh Terminal: %s\n' "$*" >&2; }

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  printf 'Usage: curl -fsSL https://raw.githubusercontent.com/terrible/bosh-terminal/main/install-online.sh | bash\n'
  printf 'Installs the pinned Bosh Terminal revision on supported Arch-based Linux.\n'
  exit 0
fi
(( $# == 0 )) || die "Unknown arguments. Only --help is supported."
(( EUID != 0 )) || die "Do not run this installer as root."
for command in git mktemp rm bash; do
  command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command"
done
if ! ( : </dev/tty ) 2>/dev/null; then
  die "An interactive terminal is required to review installation prompts."
fi

# Git's HTTPS certificate verification must remain enabled.
export GIT_TERMINAL_PROMPT=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/bosh-terminal-online.XXXXXXXX")" || die "Cannot create temporary directory"
cleanup() { rm -rf -- "$workdir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

info "Fetching reviewed revision $PINNED_COMMIT"
git -C "$workdir" init -q
git -C "$workdir" remote add origin "$REPOSITORY_URL"
git -C "$workdir" -c protocol.version=2 fetch --quiet --depth 1 origin "$PINNED_COMMIT" ||
  die "Cannot fetch pinned revision."
actual_commit="$(git -C "$workdir" rev-parse --verify 'FETCH_HEAD^{commit}')" ||
  die "Cannot verify downloaded revision."
[[ "$actual_commit" == "$PINNED_COMMIT" ]] || die "Revision mismatch; refusing to run."
git -C "$workdir" -c advice.detachedHead=false checkout --quiet --detach "$PINNED_COMMIT" ||
  die "Cannot check out verified revision."
[[ -f "$workdir/install.sh" && -f "$workdir/scripts/lib/common.sh" ]] ||
  die "Required installer files are missing."

info "Revision verified. Starting interactive installer."
# Do not let 'curl | bash' consume the installer's interactive answers.
( cd "$workdir" && bash ./install.sh </dev/tty )
