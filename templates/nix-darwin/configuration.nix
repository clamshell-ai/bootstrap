{ ... }:

{
  nixpkgs.hostPlatform = "aarch64-darwin";

  networking.hostName = "Your-Mac";
  networking.localHostName = "Your-Mac";

  system.primaryUser = "your-user";
  users.users."your-user".home = "/Users/your-user";

  # Keep personal preferences, dotfiles, and home-manager imports in your own
  # repo. This file only contains the minimum host-specific values needed for
  # nix-darwin to evaluate.
}

