# Workstation Bootstrap

Bootstrap a developer workstation, starting with macOS.

This repo handles the first-run work that needs to happen before Nix-managed
configuration can take over. After that, `nix-darwin`, home-manager, and
per-project flakes should own the steady-state developer environment.

## Install

From a new macOS machine:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/clamshell-ai/bootstrap/main/bootstrap.sh)"
```

For local testing from a checkout:

```sh
./bootstrap.sh
```

Useful overrides:

```sh
BOOTSTRAP_DARWIN_FLAKE=github:your-org/dotfiles#Your-Mac ./bootstrap.sh
BOOTSTRAP_SKIP_DARWIN=1 ./bootstrap.sh
BOOTSTRAP_INSTALL_ROSETTA=1 ./bootstrap.sh
BOOTSTRAP_RUN_GH_AUTH=1 ./bootstrap.sh
```

Generated nix-darwin configs default to `nixpkgs-25.11-darwin` and
`nix-darwin-25.11`. Override `BOOTSTRAP_NIXPKGS_INPUT` or
`BOOTSTRAP_NIX_DARWIN_INPUT` if your team wants different inputs.

## What It Does

`bootstrap.sh` is idempotent and safe to rerun. On macOS it:

- verifies or starts installation of Xcode Command Line Tools
- installs Homebrew when missing
- installs Nix when missing
- ensures `nix-command` and `flakes` are enabled for the current user
- creates a minimal `/etc/nix-darwin` flake when one does not already exist
- runs `darwin-rebuild switch --flake ...`
- verifies `git` and `gh`, and can optionally start GitHub CLI auth

Existing `/etc/nix-darwin/flake.nix` and `/etc/nix-darwin/configuration.nix`
files are left untouched. To use a different nix-darwin configuration, set
`BOOTSTRAP_DARWIN_FLAKE`.

If Xcode Command Line Tools are missing, bootstrap installs them with
`softwareupdate`. It does not launch Apple's GUI installer unless explicitly run
with `BOOTSTRAP_XCODE_CLT_ALLOW_GUI=1`.

Bootstrap loads Homebrew into the current shell while it runs. Persistent shell
configuration should be managed by the user's dotfiles or home-manager config;
bootstrap does not append to user-managed shell files.

Some Homebrew casks run privileged macOS package installers and may prompt for
your password during `darwin-rebuild` with a bare `Password:` prompt. Tailscale
is intentionally not managed by this bootstrap because its macOS installer owns
VPN/system extension state and does not behave like a simple idempotent cask.

## Layers

`bootstrap.sh` owns first-run prerequisites only. It should stay small,
defensive, and non-destructive.

`nix-darwin` owns system-level macOS configuration, global developer tools, and
Homebrew casks. This repo exposes `darwinModules.default` for that shared layer.
Machine-specific values such as username, hostname, host platform, and personal
preferences should live in the user's own nix-darwin flake.

`home-manager` owns user-level dotfiles, shell setup, editor config, and Git
config. Users should keep their home-manager flakes in their own dotfiles repo.
The bootstrap installs `direnv` with Homebrew so it is available immediately;
users should configure shell hooks and any `nix-direnv` preference in their own
home-manager setup.

Per-project flakes continue to own project-specific developer tools.

## GitHub And 1Password

This repo installs tooling and prompts for authentication; it does not store
secrets.

If Git remotes use SSH keys from 1Password, `git config --global
credential.helper osxkeychain` and `gh auth setup-git` are usually not required
for Git operations. Those are mainly useful for HTTPS Git credentials.

Recommended flow for SSH-based Git:

1. Sign in to 1Password.
2. Enable the 1Password SSH agent.
3. Configure SSH to use the agent for GitHub, commonly through an
   `IdentityAgent` entry.
4. Test with `ssh -T git@github.com`.
5. Run `gh auth login` only if you want GitHub CLI API access.

If your team uses HTTPS Git instead of SSH, run:

```sh
gh auth login
gh auth setup-git
```

## Nix-Darwin Template

This repo also ships a flake template:

```sh
nix flake init -t github:clamshell-ai/bootstrap#nix-darwin
```

Edit the generated `configuration.nix` before applying it.

## Development

This repo's `flake.nix` also defines the local development shell used to manage
the repo itself.

```sh
direnv allow
./scripts/check.sh
```

The dev shell currently provides `shellcheck` and `nixpkgs-fmt`.

## References

- [nix-darwin getting started](https://github.com/nix-darwin/nix-darwin)
- [nix-darwin options](https://nix-darwin.github.io/nix-darwin/manual/)
- [1Password SSH agent](https://developer.1password.com/docs/ssh/agent/)
