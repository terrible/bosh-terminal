#!/usr/bin/env bash

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Dependencies: all packages already installed" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

PACKAGES=(alpha beta)
package_installed() { return 0; }

install_dependencies
CASE

test_case "Dependencies: confirmed installation and state registration" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

PACKAGES=(alpha beta)
SUDO_ARGS=()
STATE_WRITES=()
INSTALLED=()

package_installed() {
    local package
    for package in "${INSTALLED[@]}"; do
        [[ "$package" == "$1" ]] && return 0
    done
    return 1
}

confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }

sudo() {
    SUDO_ARGS=("$@")
    INSTALLED=(alpha beta)
    return 0
}

write_state() { STATE_WRITES+=("$1=$2"); }

install_dependencies

[[ "${SUDO_ARGS[*]}" == "pacman -Syu --needed alpha beta" ]]
[[ "${STATE_WRITES[*]}" == "package_alpha=1 package_beta=1" ]]
CASE

test_case "Dependencies: user rejection stops installation" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

PACKAGES=(alpha beta)
SUDO_CALLS=0
STATE_CALLS=0

package_installed() { return 1; }
confirm() { return 1; }
require_command() { SUDO_CALLS=$((SUDO_CALLS + 1)); }
sudo() { SUDO_CALLS=$((SUDO_CALLS + 1)); }
write_state() { STATE_CALLS=$((STATE_CALLS + 1)); }

if install_dependencies; then
    echo "ERROR: rejection was ignored."
    exit 1
else
    result=$?
fi

[[ "$result" -eq 1 ]]
[[ "$SUDO_CALLS" -eq 0 ]]
[[ "$STATE_CALLS" -eq 0 ]]
CASE

test_case "Dependencies: pacman failure prevents state registration" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

PACKAGES=(alpha beta)
STATE_CALLS=0

package_installed() { return 1; }
confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }
sudo() { return 42; }
write_state() { STATE_CALLS=$((STATE_CALLS + 1)); }

if install_dependencies; then
    echo "ERROR: pacman failure was ignored."
    exit 1
else
    result=$?
fi

[[ "$result" -eq 1 ]]
[[ "$STATE_CALLS" -eq 0 ]]
CASE

test_case "Dependencies: missing package after pacman prevents state registration" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

PACKAGES=(alpha beta)
STATE_CALLS=0
INSTALLED=()

package_installed() {
    [[ "$1" == "alpha" && " ${INSTALLED[*]} " == *" alpha "* ]]
}

confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }
sudo() {
    INSTALLED=(alpha)
    return 0
}
write_state() { STATE_CALLS=$((STATE_CALLS + 1)); }

if install_dependencies; then
    echo "ERROR: unverified installation was accepted."
    exit 1
else
    result=$?
fi

[[ "$result" -eq 1 ]]
[[ "$STATE_CALLS" -eq 0 ]]
CASE

test_case "Dependencies: state registration failure propagates" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

PACKAGES=(alpha beta)
STATE_WRITES=()
INSTALLED=()

package_installed() {
    local package
    for package in "${INSTALLED[@]}"; do
        [[ "$package" == "$1" ]] && return 0
    done
    return 1
}

confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }
sudo() {
    INSTALLED=(alpha beta)
    return 0
}
write_state() {
    STATE_WRITES+=("$1")
    return 1
}

if install_dependencies; then
    echo "ERROR: state registration failure was ignored."
    exit 1
else
    result=$?
fi

[[ "$result" -eq 1 ]]
[[ "${STATE_WRITES[*]}" == "package_alpha" ]]
CASE

test_case "Konsole: confirmed package installation and state registration" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

mkdir -p "$HOME/konsole-test"
printf 'profile\n' > "$HOME/konsole-test/profile"
printf 'scheme\n' > "$HOME/konsole-test/scheme"

KONSOLE_PROFILE="$HOME/konsole-test/profile"
KONSOLE_SCHEME="$HOME/konsole-test/scheme"
KONSOLE_DIR="$HOME/konsole-test/output"

INSTALLED=()
SUDO_ARGS=()
STATE_WRITES=()
MANAGED_CALLS=0

package_installed() {
    local package
    for package in "${INSTALLED[@]}"; do
        [[ "$package" == "$1" ]] && return 0
    done
    return 1
}

confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }
sudo() {
    SUDO_ARGS=("$@")
    INSTALLED=(konsole ttf-hack)
    return 0
}
write_state() { STATE_WRITES+=("$1=$2"); }
install_managed_file_or_skip() {
    MANAGED_CALLS=$((MANAGED_CALLS + 1))
    return 0
}

install_konsole_component

[[ "${SUDO_ARGS[*]}" == "pacman -Syu --needed konsole ttf-hack" ]]
[[ "${STATE_WRITES[*]}" == "package_konsole=1 package_ttf-hack=1" ]]
[[ "$MANAGED_CALLS" -eq 2 ]]
CASE

test_case "Konsole: optional installation cancellation skips component" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

mkdir -p "$HOME/konsole-test"
printf 'profile\n' > "$HOME/konsole-test/profile"
printf 'scheme\n' > "$HOME/konsole-test/scheme"

KONSOLE_PROFILE="$HOME/konsole-test/profile"
KONSOLE_SCHEME="$HOME/konsole-test/scheme"
KONSOLE_DIR="$HOME/konsole-test/output"

SUDO_CALLS=0
MANAGED_CALLS=0

package_installed() { return 1; }
confirm() { return 1; }
require_command() { :; }
sudo() { SUDO_CALLS=$((SUDO_CALLS + 1)); }
write_state() { return 1; }
install_managed_file_or_skip() {
    MANAGED_CALLS=$((MANAGED_CALLS + 1))
}

output="$(install_konsole_component 2>&1)" || {
    printf '%s\n' "$output"
    exit 1
}

grep -Fq 'Konsole component skipped.' <<< "$output"
[[ "$SUDO_CALLS" -eq 0 ]]
[[ "$MANAGED_CALLS" -eq 0 ]]
CASE

test_case "Konsole: unverified package prevents state registration" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

mkdir -p "$HOME/konsole-test"
printf 'profile\n' > "$HOME/konsole-test/profile"
printf 'scheme\n' > "$HOME/konsole-test/scheme"

KONSOLE_PROFILE="$HOME/konsole-test/profile"
KONSOLE_SCHEME="$HOME/konsole-test/scheme"
KONSOLE_DIR="$HOME/konsole-test/output"

STATE_CALLS=0
MANAGED_CALLS=0

package_installed() {
    [[ "$1" == konsole ]]
}
confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }
sudo() { return 0; }
write_state() { STATE_CALLS=$((STATE_CALLS + 1)); }
install_managed_file_or_skip() {
    MANAGED_CALLS=$((MANAGED_CALLS + 1))
}

if install_konsole_component; then
    echo "ERROR: unverified package was accepted."
    exit 1
else
    result=$?
fi

[[ "$result" -eq 1 ]]
[[ "$STATE_CALLS" -eq 0 ]]
[[ "$MANAGED_CALLS" -eq 0 ]]
CASE



test_case "Konsole dependencies: confirmed installation and verification" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/konsole-dependencies-success"
mkdir -p "$root"
printf 'profile\n' > "$root/profile"
printf 'scheme\n' > "$root/scheme"

KONSOLE_PROFILE="$root/profile"
KONSOLE_SCHEME="$root/scheme"
KONSOLE_DIR="$root/output"
mkdir -p "$KONSOLE_DIR"

INSTALLED=()
SUDO_ARGS=()
STATE_WRITES=()
MANAGED_CALLS=()

package_installed() {
    local package
    for package in "${INSTALLED[@]}"; do
        [[ "$package" == "$1" ]] && return 0
    done
    return 1
}

confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }
sudo() {
    SUDO_ARGS=("$@")
    INSTALLED=(konsole ttf-hack)
    return 0
}
write_state() { STATE_WRITES+=("$1=$2"); }
install_managed_file_or_skip() {
    MANAGED_CALLS+=("$1")
    return 0
}

install_konsole_component

[[ "${SUDO_ARGS[*]}" == "pacman -Syu --needed konsole ttf-hack" ]]
[[ "${STATE_WRITES[*]}" == "package_konsole=1 package_ttf-hack=1" ]]
[[ "${#MANAGED_CALLS[@]}" -eq 2 ]]
CASE

test_case "Konsole dependencies: rejection skips package installation" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/konsole-dependencies-cancel"
mkdir -p "$root"
printf 'profile\n' > "$root/profile"
printf 'scheme\n' > "$root/scheme"

KONSOLE_PROFILE="$root/profile"
KONSOLE_SCHEME="$root/scheme"
KONSOLE_DIR="$root/output"
mkdir -p "$KONSOLE_DIR"

SUDO_CALLS=0
STATE_CALLS=0
MANAGED_CALLS=()

package_installed() { return 1; }
confirm() { return 1; }
require_command() { SUDO_CALLS=$((SUDO_CALLS + 1)); }
sudo() { SUDO_CALLS=$((SUDO_CALLS + 1)); }
write_state() { STATE_CALLS=$((STATE_CALLS + 1)); }
install_managed_file_or_skip() {
    MANAGED_CALLS+=("$1")
    return 0
}

output="$(install_konsole_component 2>&1)" || {
    printf '%s\n' "$output"
    exit 1
}

grep -Fq 'Konsole component skipped.' <<< "$output"
[[ "$SUDO_CALLS" -eq 0 ]]
[[ "$STATE_CALLS" -eq 0 ]]
[[ "${#MANAGED_CALLS[@]}" -eq 0 ]]
CASE

test_case "Konsole dependencies: failed verification prevents state registration" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/konsole-dependencies-verification"
mkdir -p "$root"
printf 'profile\n' > "$root/profile"
printf 'scheme\n' > "$root/scheme"

KONSOLE_PROFILE="$root/profile"
KONSOLE_SCHEME="$root/scheme"
KONSOLE_DIR="$root/output"
mkdir -p "$KONSOLE_DIR"

STATE_CALLS=0
MANAGED_CALLS=()

package_installed() { return 1; }
confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }
sudo() { return 0; }
write_state() { STATE_CALLS=$((STATE_CALLS + 1)); }
install_managed_file_or_skip() {
    MANAGED_CALLS+=("$1")
    return 0
}

if install_konsole_component; then
    echo "ERROR: se aceptó una instalación no verificada."
    exit 1
else
    result=$?
fi

[[ "$result" -eq 1 ]]
[[ "$STATE_CALLS" -eq 0 ]]
[[ "${#MANAGED_CALLS[@]}" -eq 0 ]]
CASE

test_case "Dependencies and Konsole: only one full system upgrade" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/combined-dependencies"
mkdir -p "$root"
printf 'profile\n' > "$root/profile"
printf 'scheme\n' > "$root/scheme"

KONSOLE_PROFILE="$root/profile"
KONSOLE_SCHEME="$root/scheme"
KONSOLE_DIR="$root/output"

PACKAGES=(alpha beta)
INSTALLED=()
SUDO_CALLS=()
STATE_WRITES=()

package_installed() {
    local package
    for package in "${INSTALLED[@]}"; do
        [[ "$package" == "$1" ]] && return 0
    done
    return 1
}

confirm() { return 0; }
require_command() { [[ "$1" == sudo ]]; }

sudo() {
    SUDO_CALLS+=("$*")
    if [[ " $* " == *" alpha beta "* ]]; then
        INSTALLED+=(alpha beta)
    elif [[ " $* " == *" konsole ttf-hack "* ]]; then
        INSTALLED+=(konsole ttf-hack)
    fi
    return 0
}

write_state() { STATE_WRITES+=("$1=$2"); }
install_managed_file_or_skip() { return 0; }

install_dependencies
[[ "$BOSH_SYSTEM_UPGRADED" -eq 1 ]]

install_konsole_component

[[ "${#SUDO_CALLS[@]}" -eq 2 ]]
[[ "${SUDO_CALLS[0]}" == "pacman -Syu --needed alpha beta" ]]
[[ "${SUDO_CALLS[1]}" == "pacman -S --needed konsole ttf-hack" ]]
[[ "${#STATE_WRITES[@]}" -eq 4 ]]
CASE


test_summary
