{
  description = "Reusable infrastructure modules and tooling for the REZICS platform";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = package: nixpkgs.lib.getName package == "nomad";
      };
    in
    {
      nixosModules = rec {
        fleet = ./modules/fleet.nix;
        common = ./modules/common.nix;
        nomad = ./modules/nomad.nix;
        nomadAutoscaler = ./modules/nomad-autoscaler.nix;
        rezicsPlatform = ./modules/rezics-platform.nix;
        cloudflaredTunnel = ./modules/cloudflared.nix;

        base = {
          imports = [
            fleet
            common
            nomad
          ];
        };

        edge = {
          imports = [
            base
            nomadAutoscaler
            rezicsPlatform
            cloudflaredTunnel
          ];
        };

        data = base;
      };

      packages.${system} = rec {
        release-gateway = pkgs.callPackage ./packages/release-gateway.nix { };
        default = release-gateway;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.go
          pkgs.go-task
          pkgs.nomad
          pkgs.ripgrep
          pkgs.shellcheck
        ];
      };

      checks.${system}.release-gateway = self.packages.${system}.release-gateway;
      formatter.${system} = pkgs.nixfmt;
    };
}
