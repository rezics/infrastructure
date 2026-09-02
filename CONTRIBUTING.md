# Contributing

Run `nix develop --command task check` before submitting a change. A contribution must
keep the public flake independently evaluable and must not include public origin
addresses, machine identities, credentials, encrypted secret files, or private
deployment procedures.

Changes to exported NixOS module options should include the downstream migration
required by the contract change. Security-sensitive findings should follow
[SECURITY.md](SECURITY.md) instead of being reported in a public issue.
