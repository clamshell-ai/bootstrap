{
  description = "Local nix-darwin workstation configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    workstation.url = "github:clamshell-ai/bootstrap";
  };

  outputs = inputs@{ nix-darwin, workstation, ... }: {
    darwinConfigurations."Your-Mac" = nix-darwin.lib.darwinSystem {
      modules = [
        workstation.darwinModules.default
        ./configuration.nix
      ];

      specialArgs = { inherit inputs; };
    };
  };
}
