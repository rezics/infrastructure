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
- `nixosModules.retainedEdge` runs Outline and PostgreSQL backup services without
  importing the application release gateway, database runtime or autoscaler.
  Its reconciler purges the named retired application jobs and preserves the
  Databasus control backup and restore verification agent.
- `nixosModules.mail` exposes the opt-in `services.rezicsMail` contract:
  hostname, domain, forwarding addresses, ACME contact, runtime admin hash and
  initial provisioning files, and public interface. It runs Stalwart 0.16.25
  with a JSON RocksDB descriptor and applies its Git-managed JMAP policy before
  opening the mail listeners. Initial passwords are hashed by Stalwart using
  Argon2id; existing account passwords are preserved on subsequent starts.
  Submission requires authentication and TLS. HTTP on 8085 is loopback-only;
  the administrative WebUI remains available on public HTTPS with password login.
- `nixosModules.backupPause` exposes `services.rezicsBackupPause.enable`, which
  persistently pauses only the retired `rezics` database's backup and scheduled
  verification while retaining its history and the Outline schedules.
- `packages.x86_64-linux.release-gateway` builds the OIDC-authenticated release
  gateway.
- `packages.x86_64-linux.stalwart` and `stalwart-cli` package SHA-256-pinned
  upstream static releases, independent of the older Nixpkgs TOML module.

The consuming fleet repository owns `nixosConfigurations`, hardware configuration,
network identities, SOPS declarations, credential paths, and activation policy. It
pins this flake in its lock file and supplies the required module options.

The existing `edge` and `data` outputs retain their contracts. Fleet composition
selects which outputs to import; importing `retainedEdge` does not import `edge`.
Operator scripts receive private Cloudflare configuration and forwarding address
files as arguments. They never contain production origin addresses or passwords.

The Stalwart runtime provisioning JSON contains `mailbox` (username and initial
password) and `dkim` (initial JMAP signature records). Keep it outside Git and
load it through systemd credentials. `stalwart-operator.py stage --dkim-file`
stages this file and the admin hash; it preserves existing backup credentials.
DKIM key material is inserted once into the mail datastore. Host and routing
policy is reconciled on startup; user accounts and installed Applications remain
persistent Stalwart state. The 0.16 deployment uses a fresh `db-v016` store;
the module does not migrate old TOML stores.

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
