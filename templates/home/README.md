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
- Tuning is a home option, in any of your modules: `my.tuning = { march; lto;
  o3; }` (each `"system"` by default = the host's own package set; `true` /
  `false`; march may name an arch) plus `my.tuning.packages.{o3,lto}` and
  `my.tuning.exclude.{o3,lto}` for single packages in your set. Values must be
  literals that do not read `pkgs`. A choice whose set cannot safely load the
  system's in-process code fails to evaluate, with an explanation.
- `tuning-refresh` (once the admin enabled it) records which packages your
  home runs, so the host's tuning counts them.
- `persist.nix` is reserved for the paths to keep when your home is
  impermanent. Nothing reads it yet; no host has impermanent homes today.

While the system still activates your home (registry `homeActivation =
"system"`, the default), mkHome's activation package is identical to the
system's. Once your file says `"standalone"`, mkHome installs `home.packages`
into your own profile and you switch with `home-manager switch --flake .`.
