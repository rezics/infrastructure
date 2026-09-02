# REZICS infrastructure instructions

This public repository owns reusable NixOS modules, Nomad jobs, release tooling,
and the release gateway. Environment-specific host assembly and all secret material
belong in the private `rezics/nixos-private` repository.

Before proposing or committing a change, run the complete validation task from the
repository root:

```sh
task check
```

The task requires `nix`, `nixfmt`, `nomad`, `shellcheck`, `go`, and `rg`. On Windows,
run it inside WSL 2. Do not silently skip a missing prerequisite.

Do not add public origin addresses, hardware identifiers, SSH or WireGuard identities,
SOPS ciphertext or recipient configuration, credentials, private deployment entrypoints,
or other private environment values. Public product hostnames may appear where they are
part of the reusable routing contract. Model downstream requirements as typed NixOS
module options and keep credential paths as runtime strings so secret contents never
enter the Nix store.

Keep the public flake independently evaluable. `nixosModules.edge` and
`nixosModules.data` are the supported composition outputs; changes to their option
contracts must be deliberate and documented.
