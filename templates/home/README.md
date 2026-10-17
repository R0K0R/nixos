# Home configuration

A standalone home-manager repo built on the system flake's `homeLib`.

    nix flake init -t github:R0K0R/nixos#home
    $EDITOR flake.nix          # set `username`
    home-manager switch --flake .

- `flake.nix` makes `homeConfigurations."<user>@<host>"` for every host the
  system's `registry/hosts.nix` puts you on, via `homeLib.<host>.mkHome`.
  It pins no nixpkgs or home-manager of its own: the host's package set comes
  from the system, so nothing the system already built is rebuilt.
- `modules/` is yours. It is added on top of the system's feature home halves.
- `tuning.json` is reserved for per-user tuning levers (empty = upstream
  defaults). Nothing reads it yet.
- `persist.nix` is reserved for the paths to keep when your home is
  impermanent. Nothing reads it yet; no host has impermanent homes today.

While the system still activates your home (registry `homeActivation =
"system"`, the default), mkHome's activation package is identical to the
system's. Once your file says `"standalone"`, mkHome installs `home.packages`
into your own profile and you switch with `home-manager switch --flake .`.
