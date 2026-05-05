#!/usr/bin/env bash
set -Eeuo pipefail

bash -n bootstrap.sh

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck bootstrap.sh scripts/check.sh
fi

if command -v nix >/dev/null 2>&1; then
  nix --extra-experimental-features 'nix-command flakes' flake check --all-systems "path:$PWD"
fi
