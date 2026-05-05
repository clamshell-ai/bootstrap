{ lib, pkgs, ... }:

{
  nix.enable = lib.mkDefault true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.settings.trusted-users = [
    "root"
    "@admin"
  ];

  nix.gc = {
    automatic = lib.mkDefault true;
    interval = lib.mkDefault {
      Weekday = 0;
      Hour = 3;
      Minute = 15;
    };
    options = lib.mkDefault "--delete-older-than 14d";
  };
  nix.optimise.automatic = lib.mkDefault true;

  programs.zsh.enable = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    age
    curl
    direnv
    gh
    git
    gnupg
    jq
    just
    nix-direnv
    openssh
    sops
    vim
    wget
  ];

  homebrew = {
    enable = lib.mkDefault true;

    onActivation = {
      autoUpdate = lib.mkDefault true;
      cleanup = lib.mkDefault "none";
      upgrade = lib.mkDefault false;
    };

    casks = [
      "1password"
      "1password-cli"
      "brave-browser"
      "docker-desktop"
      "google-chrome"
      "google-drive"
      "tailscale-app"
    ];
  };

  system.stateVersion = lib.mkDefault 6;
}
