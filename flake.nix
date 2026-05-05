{
  description = "Developer workstation bootstrap";

  inputs = {
    # Repo tooling follows the main application repo so shared checks like
    # shellcheck resolve to the same derivations when possible.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    darwin-nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
    nix-darwin.inputs.nixpkgs.follows = "darwin-nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, nix-darwin, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkDarwin = hostPlatform:
        nix-darwin.lib.darwinSystem {
          modules = [
            self.darwinModules.default
            {
              nixpkgs.hostPlatform = hostPlatform;

              networking.hostName = "bootstrap";
              networking.localHostName = "bootstrap";

              system.primaryUser = "bootstrap";
              users.users."bootstrap".home = "/Users/bootstrap";
            }
          ];

          specialArgs = { inherit inputs; };
        };
    in
    {
      darwinModules.default = import ./nix/darwin;

      darwinConfigurations.bootstrap-aarch64 = mkDarwin "aarch64-darwin";
      darwinConfigurations.bootstrap-x86_64 = mkDarwin "x86_64-darwin";

      templates.nix-darwin = {
        path = ./templates/nix-darwin;
        description = "Minimal nix-darwin host config importing the shared workstation module";
      };

      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixpkgs-fmt;
      formatter.x86_64-darwin = nixpkgs.legacyPackages.x86_64-darwin.nixpkgs-fmt;
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt;
      formatter.aarch64-linux = nixpkgs.legacyPackages.aarch64-linux.nixpkgs-fmt;

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixpkgs-fmt
              shellcheck
            ];
          };
        });
    };
}
