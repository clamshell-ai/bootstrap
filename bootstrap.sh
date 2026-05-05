#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_BOOTSTRAP_FLAKE_INPUT="github:clamshell-ai/bootstrap"
DEFAULT_DARWIN_DIR="/etc/nix-darwin"
DEFAULT_NIXPKGS_INPUT="github:NixOS/nixpkgs/nixpkgs-25.11-darwin"
DEFAULT_NIX_DARWIN_INPUT="github:nix-darwin/nix-darwin/nix-darwin-25.11"
BOOTSTRAP_VERSION="2026-05-05.1"

BOOTSTRAP_ASSUME_YES="${BOOTSTRAP_ASSUME_YES:-0}"
BOOTSTRAP_INSTALL_HOMEBREW="${BOOTSTRAP_INSTALL_HOMEBREW:-1}"
BOOTSTRAP_INSTALL_NIX="${BOOTSTRAP_INSTALL_NIX:-1}"
BOOTSTRAP_INSTALL_ROSETTA="${BOOTSTRAP_INSTALL_ROSETTA:-0}"
BOOTSTRAP_RUN_GH_AUTH="${BOOTSTRAP_RUN_GH_AUTH:-0}"
BOOTSTRAP_SETUP_GH_GIT="${BOOTSTRAP_SETUP_GH_GIT:-0}"
BOOTSTRAP_SKIP_DARWIN="${BOOTSTRAP_SKIP_DARWIN:-0}"
BOOTSTRAP_DARWIN_DIR="${BOOTSTRAP_DARWIN_DIR:-$DEFAULT_DARWIN_DIR}"
BOOTSTRAP_NIXPKGS_INPUT="${BOOTSTRAP_NIXPKGS_INPUT:-$DEFAULT_NIXPKGS_INPUT}"
BOOTSTRAP_NIX_DARWIN_INPUT="${BOOTSTRAP_NIX_DARWIN_INPUT:-$DEFAULT_NIX_DARWIN_INPUT}"
BOOTSTRAP_XCODE_CLT_ALLOW_GUI="${BOOTSTRAP_XCODE_CLT_ALLOW_GUI:-0}"
BOOTSTRAP_XCODE_CLT_WAIT_SECONDS="${BOOTSTRAP_XCODE_CLT_WAIT_SECONDS:-1800}"

SUDO_KEEPALIVE_PID=""

log() {
  printf '\033[1;34m==>\033[0m %s\n' "$*" >&2
}

warn() {
  printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: bootstrap.sh

Environment overrides:
  BOOTSTRAP_DARWIN_FLAKE       Flake ref passed to darwin-rebuild.
  BOOTSTRAP_DARWIN_DIR         Local nix-darwin dir to scaffold. Default: /etc/nix-darwin.
  BOOTSTRAP_WORKSTATION_INPUT  Shared module flake input for generated configs.
  BOOTSTRAP_NIXPKGS_INPUT      nixpkgs input for generated configs.
  BOOTSTRAP_NIX_DARWIN_INPUT   nix-darwin input for generated configs and first switch.
  BOOTSTRAP_XCODE_CLT_ALLOW_GUI=1
                              Allow fallback to Apple's GUI CLT installer.
  BOOTSTRAP_XCODE_CLT_WAIT_SECONDS
                              Seconds to wait if GUI CLT fallback is enabled. Default: 1800.
  BOOTSTRAP_SKIP_DARWIN=1      Install prerequisites but do not run darwin-rebuild.
  BOOTSTRAP_INSTALL_ROSETTA=1  Install Rosetta on Apple Silicon.
  BOOTSTRAP_RUN_GH_AUTH=1      Run gh auth login if not already authenticated.
  BOOTSTRAP_SETUP_GH_GIT=1     Run gh auth setup-git after gh auth is available.
  BOOTSTRAP_ASSUME_YES=1       Accept script prompts where possible.
USAGE
}

cleanup() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_interactive() {
  [ -t 0 ] && [ -t 1 ]
}

is_ssh_session() {
  [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]
}

confirm() {
  local prompt="$1"

  if [ "$BOOTSTRAP_ASSUME_YES" = "1" ]; then
    return 0
  fi

  if ! is_interactive; then
    return 1
  fi

  local reply
  printf '%s [y/N] ' "$prompt"
  read -r reply
  case "$reply" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

require_macos() {
  case "$(uname -s)" in
    Darwin) ;;
    *) die "Only macOS is supported right now. Linux support can be added later." ;;
  esac
}

require_non_root_user() {
  if [ "$(id -u)" -eq 0 ]; then
    die "Run this as your normal macOS user, not with sudo. The script will ask for sudo when needed."
  fi
}

require_sudo() {
  log "Requesting sudo access for system-level setup."
  sudo -v

  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" >/dev/null 2>&1 || exit
  done 2>/dev/null &

  SUDO_KEEPALIVE_PID="$!"
}

host_name() {
  local name
  name="$(scutil --get LocalHostName 2>/dev/null || true)"
  if [ -z "$name" ]; then
    name="$(hostname -s)"
  fi
  printf '%s' "$name"
}

darwin_platform() {
  case "$(uname -m)" in
    arm64) printf 'aarch64-darwin' ;;
    x86_64) printf 'x86_64-darwin' ;;
    *) die "Unsupported macOS architecture: $(uname -m)" ;;
  esac
}

detect_workstation_input() {
  if [ -n "${BOOTSTRAP_WORKSTATION_INPUT:-}" ]; then
    printf '%s' "$BOOTSTRAP_WORKSTATION_INPUT"
    return
  fi

  local source_path script_dir
  source_path="${BASH_SOURCE[0]:-}"

  if [ -n "$source_path" ] && [ -f "$source_path" ]; then
    script_dir="$(cd "$(dirname "$source_path")" && pwd)"
    if [ -f "$script_dir/flake.nix" ] && [ -f "$script_dir/nix/darwin/default.nix" ]; then
      printf 'path:%s' "$script_dir"
      return
    fi
  fi

  printf '%s' "$DEFAULT_BOOTSTRAP_FLAKE_INPUT"
}

xcode_clt_installed() {
  if xcode-select -p >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

wait_for_xcode_clt() {
  local deadline next_notice
  deadline=$((SECONDS + BOOTSTRAP_XCODE_CLT_WAIT_SECONDS))
  next_notice=$SECONDS

  while ! xcode_clt_installed; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      die "Xcode Command Line Tools did not become available within ${BOOTSTRAP_XCODE_CLT_WAIT_SECONDS}s. If a macOS installer window is open, finish it there, then rerun bootstrap."
    fi

    if [ "$SECONDS" -ge "$next_notice" ]; then
      log "Waiting for Xcode Command Line Tools. If a macOS installer window is open, complete it there; this terminal will continue automatically."
      next_notice=$((SECONDS + 30))
    fi

    sleep 5
  done
}

install_xcode_clt_via_softwareupdate() {
  local marker output product status
  marker="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

  log "Looking for Xcode Command Line Tools package via softwareupdate."
  sudo touch "$marker"
  output="$(softwareupdate --list 2>&1 || true)"
  product="$(printf '%s\n' "$output" | awk -F': ' '/Label: Command Line Tools/ { product = $2 } END { print product }')"

  if [ -z "$product" ]; then
    sudo rm -f "$marker"
    warn "No Xcode Command Line Tools package was found by softwareupdate."
    return 1
  fi

  log "Installing $product."
  if sudo softwareupdate --install "$product" --verbose; then
    sudo rm -f "$marker"
    xcode_clt_installed
    return
  fi

  status=$?
  sudo rm -f "$marker"
  return "$status"
}

install_xcode_clt() {
  local install_output

  if xcode_clt_installed; then
    log "Xcode Command Line Tools are installed."
    return
  fi

  if is_ssh_session; then
    log "SSH session detected."
  fi

  if install_xcode_clt_via_softwareupdate; then
    log "Xcode Command Line Tools are installed."
    return
  fi

  if [ "$BOOTSTRAP_XCODE_CLT_ALLOW_GUI" != "1" ]; then
    die "Could not install Xcode Command Line Tools with softwareupdate. To use Apple's GUI installer explicitly, rerun with BOOTSTRAP_XCODE_CLT_ALLOW_GUI=1, or install Command Line Tools manually and rerun bootstrap."
  fi

  log "Starting Xcode Command Line Tools GUI installer because BOOTSTRAP_XCODE_CLT_ALLOW_GUI=1."
  install_output="$(xcode-select --install 2>&1 || true)"

  if [ -n "$install_output" ]; then
    warn "$install_output"
  fi

  if is_interactive; then
    log "Use the macOS installer window to complete installation. Do not press anything in this terminal; it is waiting automatically."
    wait_for_xcode_clt
  else
    die "Xcode Command Line Tools are missing. If a macOS installer window opened, finish it there, then rerun bootstrap."
  fi

  log "Xcode Command Line Tools are installed."
}

install_rosetta_if_requested() {
  if [ "$BOOTSTRAP_INSTALL_ROSETTA" != "1" ]; then
    return
  fi

  if [ "$(uname -m)" != "arm64" ]; then
    log "Rosetta is only relevant on Apple Silicon; skipping."
    return
  fi

  if /usr/bin/pgrep oahd >/dev/null 2>&1; then
    log "Rosetta appears to be installed."
    return
  fi

  log "Installing Rosetta."
  /usr/sbin/softwareupdate --install-rosetta --agree-to-license
}

load_homebrew_env() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

install_homebrew() {
  if [ "$BOOTSTRAP_INSTALL_HOMEBREW" != "1" ]; then
    log "Skipping Homebrew installation."
    return
  fi

  load_homebrew_env

  if command_exists brew; then
    log "Homebrew is installed."
    return
  fi

  log "Installing Homebrew."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  load_homebrew_env
  command_exists brew || die "Homebrew installation completed, but brew is not on PATH."
}

load_nix_env() {
  if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
}

install_nix() {
  if [ "$BOOTSTRAP_INSTALL_NIX" != "1" ]; then
    log "Skipping Nix installation."
    load_nix_env
    return
  fi

  load_nix_env

  if command_exists nix; then
    log "Nix is installed."
    return
  fi

  log "Installing Nix."
  curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install
  load_nix_env
  command_exists nix || die "Nix installation completed, but nix is not on PATH."
}

ensure_nix_flakes_for_user() {
  local nix_dir nix_conf tmp
  nix_dir="$HOME/.config/nix"
  nix_conf="$nix_dir/nix.conf"

  mkdir -p "$nix_dir"

  if [ ! -f "$nix_conf" ]; then
    log "Creating $nix_conf with flakes enabled."
    printf 'experimental-features = nix-command flakes\n' >"$nix_conf"
    return
  fi

  if grep -Eq '^[[:space:]]*experimental-features[[:space:]]*=.*\bnix-command\b.*\bflakes\b|^[[:space:]]*experimental-features[[:space:]]*=.*\bflakes\b.*\bnix-command\b' "$nix_conf"; then
    log "Nix flakes are enabled for the current user."
    return
  fi

  if grep -Eq '^[[:space:]]*experimental-features[[:space:]]*=' "$nix_conf"; then
    log "Updating $nix_conf to include nix-command and flakes."
    tmp="$(mktemp)"
    awk '
      BEGIN { updated = 0 }
      /^[[:space:]]*experimental-features[[:space:]]*=/ && updated == 0 {
        line = $0
        if (line !~ /(^|[[:space:]])nix-command($|[[:space:]])/) {
          line = line " nix-command"
        }
        if (line !~ /(^|[[:space:]])flakes($|[[:space:]])/) {
          line = line " flakes"
        }
        print line
        updated = 1
        next
      }
      { print }
    ' "$nix_conf" >"$tmp"
    mv "$tmp" "$nix_conf"
  else
    log "Appending flakes settings to $nix_conf."
    printf '\nexperimental-features = nix-command flakes\n' >>"$nix_conf"
  fi
}

repair_generated_darwin_flake_if_needed() {
  local flake_file workstation_input tmp
  flake_file="$1"
  workstation_input="$2"

  if grep -Eq '^[[:space:]]*workstation\.url[[:space:]]*=[[:space:]]*"(path:[^"]*)?"[[:space:]]*;' "$flake_file"; then
    log "Repairing invalid workstation input in $flake_file."
    tmp="$(mktemp)"
    awk -v workstation_input="$workstation_input" '
      /^[[:space:]]*workstation\.url[[:space:]]*=[[:space:]]*"(path:[^"]*)?"[[:space:]]*;/ {
        print "    workstation.url = \"" workstation_input "\";"
        next
      }
      { print }
    ' "$flake_file" >"$tmp"
    mv "$tmp" "$flake_file"
  fi
}

write_generated_darwin_flake() {
  local dir host platform user group workstation_input
  dir="$1"
  host="$2"
  platform="$3"
  user="$4"
  group="$5"
  workstation_input="$6"

  sudo mkdir -p "$dir"
  sudo chown "$user:$group" "$dir"

  if [ ! -f "$dir/flake.nix" ]; then
    log "Creating $dir/flake.nix."
    cat >"$dir/flake.nix" <<EOF
{
  description = "Local nix-darwin workstation configuration";

  inputs = {
    nixpkgs.url = "$BOOTSTRAP_NIXPKGS_INPUT";
    nix-darwin.url = "$BOOTSTRAP_NIX_DARWIN_INPUT";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    workstation.url = "$workstation_input";
  };

  outputs = inputs@{ nix-darwin, workstation, ... }: {
    darwinConfigurations."$host" = nix-darwin.lib.darwinSystem {
      modules = [
        workstation.darwinModules.default
        ./configuration.nix
      ];

      specialArgs = { inherit inputs; };
    };
  };
}
EOF
  else
    log "$dir/flake.nix already exists; leaving it unchanged."
    repair_generated_darwin_flake_if_needed "$dir/flake.nix" "$workstation_input"
  fi

  if [ ! -f "$dir/configuration.nix" ]; then
    log "Creating $dir/configuration.nix."
    cat >"$dir/configuration.nix" <<EOF
{ ... }:

{
  nixpkgs.hostPlatform = "$platform";

  networking.hostName = "$host";
  networking.localHostName = "$host";

  system.primaryUser = "$user";
  users.users."$user".home = "/Users/$user";

  # Keep personal preferences, dotfiles, and home-manager imports in your own
  # repo. This file only contains the minimum host-specific values needed for
  # nix-darwin to evaluate.
}
EOF
  else
    log "$dir/configuration.nix already exists; leaving it unchanged."
  fi
}

darwin_flake_ref() {
  if [ -n "${BOOTSTRAP_DARWIN_FLAKE:-}" ]; then
    printf '%s' "$BOOTSTRAP_DARWIN_FLAKE"
    return
  fi

  local host platform user group workstation_input
  host="${BOOTSTRAP_DARWIN_CONFIGURATION:-$(host_name)}"
  platform="$(darwin_platform)"
  user="${SUDO_USER:-$USER}"
  group="$(id -gn "$user")"
  workstation_input="$(detect_workstation_input)"

  write_generated_darwin_flake "$BOOTSTRAP_DARWIN_DIR" "$host" "$platform" "$user" "$group" "$workstation_input"
  printf '%s#%s' "$BOOTSTRAP_DARWIN_DIR" "$host"
}

run_darwin_rebuild() {
  if [ "$BOOTSTRAP_SKIP_DARWIN" = "1" ]; then
    log "Skipping nix-darwin activation."
    return
  fi

  local flake_ref darwin_rebuild nix_bin
  flake_ref="$(darwin_flake_ref)"

  log "Activating nix-darwin with $flake_ref."

  if darwin_rebuild="$(command -v darwin-rebuild 2>/dev/null)"; then
    sudo -H "$darwin_rebuild" switch --flake "$flake_ref"
  else
    nix_bin="$(command -v nix)"
    sudo -H "$nix_bin" --extra-experimental-features 'nix-command flakes' \
      run "$BOOTSTRAP_NIX_DARWIN_INPUT#darwin-rebuild" -- \
      switch --flake "$flake_ref"
  fi
}

verify_git_tooling() {
  if command_exists git; then
    log "Git is available: $(git --version)"
  else
    warn "Git is not available after bootstrap."
  fi

  if ! command_exists gh; then
    warn "GitHub CLI is not available yet. It should be installed by nix-darwin on the next successful switch."
    return
  fi

  log "GitHub CLI is available: $(gh --version | head -n 1)"

  if gh auth status >/dev/null 2>&1; then
    log "GitHub CLI is authenticated."
  elif [ "$BOOTSTRAP_RUN_GH_AUTH" = "1" ] || confirm "GitHub CLI is not authenticated. Run 'gh auth login' now?"; then
    gh auth login
  else
    warn "Skipping GitHub CLI authentication."
  fi

  if [ "$BOOTSTRAP_SETUP_GH_GIT" = "1" ]; then
    log "Configuring Git to use GitHub CLI credentials for HTTPS Git operations."
    gh auth setup-git
  fi
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      usage
      die "Unknown argument: $1"
      ;;
  esac

  require_macos
  require_non_root_user
  log "Running workstation bootstrap $BOOTSTRAP_VERSION."
  require_sudo
  install_xcode_clt
  install_rosetta_if_requested
  install_homebrew
  install_nix
  ensure_nix_flakes_for_user
  run_darwin_rebuild
  verify_git_tooling

  log "Bootstrap complete."
}

main "$@"
