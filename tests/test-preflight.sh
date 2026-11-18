#!/usr/bin/env bash

set -uo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

test_case "Preflight: successful validation and check order" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/project"
mkdir -p "$root/anime"
for name in zsh starship fastfetch; do
    printf 'config\n' > "$root/$name"
done
printf 'png\n' > "$root/anime/image.png"

ZSH_CONFIG="$root/zsh"
STARSHIP_CONFIG="$root/starship"
FASTFETCH_CONFIG="$root/fastfetch"
ANIME_SOURCE="$root/anime"
KONSOLE_PROFILE="$root/missing.profile"
KONSOLE_SCHEME="$root/missing.scheme"

PREFLIGHT_CALLS=()
require_non_root() { PREFLIGHT_CALLS+=(nonroot); }
require_command() {
    PREFLIGHT_CALLS+=("$1")
}
detect_arch_system() { PREFLIGHT_CALLS+=(arch); }

shopt -u nullglob
preflight
[[ "${PREFLIGHT_CALLS[*]}" == "nonroot pacman flock git tar base64 awk cmp sha256sum arch" ]]
! shopt -q nullglob

shopt -s nullglob
preflight
shopt -q nullglob
CASE

test_case "Preflight: reject missing and symlinked required files" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/project"
mkdir -p "$root/anime"
printf 'png\n' > "$root/anime/image.png"
for name in zsh starship fastfetch; do
    printf 'config\n' > "$root/$name"
done

ZSH_CONFIG="$root/zsh"
STARSHIP_CONFIG="$root/starship"
FASTFETCH_CONFIG="$root/fastfetch"
ANIME_SOURCE="$root/anime"
KONSOLE_PROFILE="$root/profile"
KONSOLE_SCHEME="$root/scheme"

require_non_root() { :; }
require_command() { :; }
detect_arch_system() { :; }

for variable in ZSH_CONFIG STARSHIP_CONFIG FASTFETCH_CONFIG; do
    path="${!variable}"
    saved="$path.saved"
    mv -- "$path" "$saved"

    if preflight >/dev/null 2>&1; then
        echo "ERROR: se aceptó un archivo obligatorio ausente: $variable"
        exit 1
    fi

    mv -- "$saved" "$path"
    ln -s -- "$path" "$saved"

    printf -v "$variable" '%s' "$saved"
    if preflight >/dev/null 2>&1; then
        echo "ERROR: se aceptó un enlace simbólico: $variable"
        exit 1
    fi

    rm -- "$saved"
    printf -v "$variable" '%s' "$path"
done
CASE

test_case "Preflight: reject invalid anime directory and assets" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/project"
mkdir -p "$root/real-anime"
printf 'config\n' > "$root/zsh"
printf 'config\n' > "$root/starship"
printf 'config\n' > "$root/fastfetch"

ZSH_CONFIG="$root/zsh"
STARSHIP_CONFIG="$root/starship"
FASTFETCH_CONFIG="$root/fastfetch"
ANIME_SOURCE="$root/real-anime"
KONSOLE_PROFILE="$root/profile"
KONSOLE_SCHEME="$root/scheme"

require_non_root() { :; }
require_command() { :; }
detect_arch_system() { :; }

if preflight >/dev/null 2>&1; then
    echo "ERROR: se aceptó un directorio anime sin PNG."
    exit 1
fi

ln -s "$root/real-anime" "$root/anime-link"
ANIME_SOURCE="$root/anime-link"
if preflight >/dev/null 2>&1; then
    echo "ERROR: se aceptó un directorio anime simbólico."
    exit 1
fi

ANIME_SOURCE="$root/real-anime"
printf 'png\n' > "$root/real-anime/valid.png"
ln -s "$root/real-anime/valid.png" "$root/real-anime/linked.png"

if preflight >/dev/null 2>&1; then
    echo "ERROR: se aceptó una imagen PNG simbólica."
    exit 1
fi
CASE

test_case "Preflight: Konsole incomplete or symlinked remains optional" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/project"
mkdir -p "$root/anime"
for name in zsh starship fastfetch; do
    printf 'config\n' > "$root/$name"
done
printf 'png\n' > "$root/anime/image.png"
printf 'profile\n' > "$root/profile"
ln -s "$root/profile" "$root/profile-link"

ZSH_CONFIG="$root/zsh"
STARSHIP_CONFIG="$root/starship"
FASTFETCH_CONFIG="$root/fastfetch"
ANIME_SOURCE="$root/anime"
KONSOLE_PROFILE="$root/profile-link"
KONSOLE_SCHEME="$root/missing-scheme"

require_non_root() { :; }
require_command() { :; }
detect_arch_system() { :; }

output="$(preflight 2>&1)"
grep -Fq 'Konsole configuration files are incomplete' <<< "$output"
grep -Fq 'Preflight checks passed' <<< "$output"
CASE

test_case "Preflight: initial checks stop immediately on failure" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

for failed_check in nonroot pacman flock git tar base64 awk cmp sha256sum arch; do
    PREFLIGHT_CALLS=()

    require_non_root() {
        PREFLIGHT_CALLS+=(nonroot)
        [[ "$failed_check" != nonroot ]]
    }
    require_command() {
        PREFLIGHT_CALLS+=("$1")
        [[ "$failed_check" != "$1" ]]
    }
    detect_arch_system() {
        PREFLIGHT_CALLS+=(arch)
        [[ "$failed_check" != arch ]]
    }

    if preflight >/dev/null 2>&1; then
        echo "ERROR: preflight no se detuvo al fallar $failed_check."
        exit 1
    fi

    expected="nonroot"
    if [[ "$failed_check" != nonroot ]]; then
        for command_name in pacman flock git tar base64 awk cmp sha256sum; do
            expected+=" $command_name"
            [[ "$failed_check" == "$command_name" ]] && break
        done
    fi
    [[ "$failed_check" != arch ]] || expected+=" arch"

    [[ "${PREFLIGHT_CALLS[*]}" == "$expected" ]]
done
CASE

test_case "Preflight: validate ~/.zshrc destination early" <<'CASE'
source "$BOSH_TEST_PROJECT/install.sh"

root="$HOME/project"
mkdir -p "$root/anime"
for name in zsh starship fastfetch; do
    printf 'config\n' > "$root/$name"
done
printf 'png\n' > "$root/anime/image.png"

ZSH_CONFIG="$root/zsh"
STARSHIP_CONFIG="$root/starship"
FASTFETCH_CONFIG="$root/fastfetch"
ANIME_SOURCE="$root/anime"
KONSOLE_PROFILE="$root/missing.profile"
KONSOLE_SCHEME="$root/missing.scheme"

require_non_root() { :; }
require_command() { :; }
detect_arch_system() { :; }

preflight >/dev/null 2>&1

printf 'user config\n' > "$HOME/.zshrc"
preflight >/dev/null 2>&1

rm "$HOME/.zshrc"
printf 'target\n' > "$HOME/zshrc-target"
ln -s "$HOME/zshrc-target" "$HOME/.zshrc"
if preflight >/dev/null 2>&1; then
    echo "ERROR: se aceptó ~/.zshrc como enlace simbólico."
    exit 1
fi

rm "$HOME/.zshrc"
mkdir "$HOME/.zshrc"
if preflight >/dev/null 2>&1; then
    echo "ERROR: se aceptó ~/.zshrc como directorio."
    exit 1
fi
CASE

test_summary
