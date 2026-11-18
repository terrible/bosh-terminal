# Bosh Terminal

**Version:** 0.1.0

Bosh Terminal sets up a Zsh-based terminal environment on Arch Linux and
Arch-based distributions. It manages the project's shell configuration,
Starship prompt, Fastfetch display, anime artwork, and an optional Konsole
profile and color scheme.

## Features

- **Zsh:** shell configuration, completion support, and syntax highlighting.
- **Oh My Zsh:** integrates the official Oh My Zsh framework and selected
  plugins. An existing valid Oh My Zsh installation is preserved.
- **Starship:** installs and configures the Starship prompt.
- **Fastfetch:** displays system information using the project's configuration.
- **Anime artwork:** installs the five images included in `assets/anime/`.
  Fastfetch selects an image from the managed collection.
- **Chafa:** enables terminal image rendering in Fastfetch when available.
- **Konsole (optional):** installs a Bosh Terminal profile, color scheme, and
  Hack font.

## Compatibility and requirements

Bosh Terminal currently supports **Arch Linux and Arch-based distributions**
recognized through `/etc/os-release` (`ID=arch` or an `ID_LIKE` value
containing `arch`).

Run the installer from a regular user account. **Do not run it as root.**

The installer requires Bash, `pacman`, `flock`, `git`, `tar`, `base64`, `awk`,
`cmp`, and `sha256sum`. Administrative privileges through `sudo` are needed
when system packages must be installed.

## Installation

Run the installer from the project directory:

    bash install.sh

The installer checks the system, requests confirmation before installing
missing dependencies, and configures the managed files and Zsh integration.

The main package set includes:

- `zsh`
- `starship`
- `fastfetch`
- `chafa`
- `zsh-autosuggestions`
- `zsh-syntax-highlighting`
- `zsh-completions`
- `git`

### Important: package upgrades

When required packages are missing, the installer uses:

    sudo pacman -Syu --needed ...

This operation synchronizes package databases, upgrades installed packages,
and installs the requested packages. Review the package manager's proposed
changes before confirming.

The optional Konsole component may also use `pacman -Syu` when it needs to
install Konsole or the Hack font and a system upgrade has not already been
performed during the installation.

### Konsole component

The Konsole component is optional. If its configuration files are missing
or invalid, the installer skips this component. Otherwise, it installs
Konsole and the `ttf-hack` package if needed, then deploys the Bosh Terminal
profile and color scheme.

After installation, open a new Zsh session. When the optional component is
installed, select the Bosh Terminal profile in Konsole.


## Configuration and data locations

Bosh Terminal follows the XDG base directory variables. The default locations
are:

| Purpose | Default location |
| --- | --- |
| Managed configuration | `~/.config/bosh-terminal/` |
| State and manifests | `~/.local/state/bosh-terminal/` |
| Installation backups | `~/.config/bosh-backups/bosh-terminal/` |
| Fastfetch anime images | `~/.local/share/fastfetch/anime/` |
| Zsh integration | `~/.zshrc` |

When set, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, and `XDG_DATA_HOME` replace
the corresponding default base directories.

The managed configuration directory contains the installed Zsh, Starship,
and Fastfetch configuration files. Bosh Terminal adds a managed loader block
to `~/.zshrc` to load its Zsh configuration.

## Local configuration changes

Bosh Terminal tracks managed configuration files using state manifests and
SHA-256 hashes.

If a managed file differs from the version previously recorded by the
installer:

- The existing file is preserved; the installer does not overwrite it.
- The update for that file is skipped, while installation may continue with
  other components.
- The installer reports the conflict so you can review and reconcile your
  local changes before running it again.

This conflict check does not create a new backup of the locally modified
file. The modified file remains at its destination. Make your own copy before
manually merging or replacing it.

Compare the modified file with its corresponding candidate in `config/`, for
example:

- `config/zsh/zshrc.candidate`
- `config/starship/starship.toml.candidate`
- `config/fastfetch/config.jsonc.candidate`

Retain any customizations you need. Do not assume that the original
pre-install backup contains later local edits.

Bosh Terminal deliberately does not provide a force-overwrite option for
these conflicts. Resolve the difference manually and rerun the installer
when you are ready.


## Uninstallation

Run the uninstaller from the project directory:

    bash uninstall.sh

The uninstaller uses the recorded state and file hashes to identify resources
managed by Bosh Terminal. It removes managed files when they can be safely
verified and restores saved originals when their backups pass validation.

Files that have been modified, cannot be verified, or are otherwise unsafe to
replace are preserved. Review the uninstaller's report for details.

**Uninstallation does not remove Oh My Zsh or system packages.** These are
deliberately left in place.

## Tests

Run the project's test suite from the project directory:

    bash tests/run-tests.sh

## Licenses

Bosh Terminal uses separate licenses for its software and artwork.

- **Source code, scripts, tests, and configuration files:** MIT License
  (see [LICENSE](LICENSE)).
- **Anime images in `assets/anime/`:** Creative Commons Attribution 4.0
  International (CC BY 4.0; see [LICENSE-IMAGES](LICENSE-IMAGES)).

The CC BY 4.0 license permits sharing and adapting the images, including
commercial use, provided the creator is credited, the license is linked,
and changes are indicated. This license applies only to rights held by
the creator; third-party materials and rights are not included.
