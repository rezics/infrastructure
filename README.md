# REZICS infrastructure

Reusable infrastructure components for operating the REZICS platform on NixOS and
Nomad. This repository contains no production host identities, public origin addresses,
encrypted secret payloads, or deployment credentials.

## Flake outputs

- `nixosModules.base` configures the shared hardened NixOS, WireGuard, Docker, and
  Nomad foundation.
- `nixosModules.edge` adds the REZICS control-plane services, release gateway,
  reconciliation jobs, Cloudflare Tunnel unit, and Nomad Autoscaler.
- `nixosModules.data` provides the data-host foundation.
- `packages.x86_64-linux.release-gateway` builds the OIDC-authenticated release
  gateway.

The consuming fleet repository owns `nixosConfigurations`, hardware configuration,
network identities, SOPS declarations, credential paths, and activation policy. It
pins this flake in its lock file and supplies the required module options.

```nix
{
  inputs.infrastructure = {
    url = "github:rezics/infrastructure";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { infrastructure, nixpkgs, ... }: {
    nixosConfigurations.edge = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        infrastructure.nixosModules.edge
        ./hosts/edge
      ];
    };
  };
}
```

## Validation

With Nix installed, enter the pinned development shell and run the complete check:

```sh
nix develop --command task check
```

This formats and evaluates the flake, builds the release gateway, validates every
Nomad jobspec, checks shell scripts, runs Go tests, and enforces the repository's
public-content policy.

## License

Licensed under the GNU Affero General Public License v3.0; see [LICENSE](LICENSE).
