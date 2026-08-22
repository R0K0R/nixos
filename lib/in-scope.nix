/*
  "Does this feature's home half apply to the user it is currently being
  evaluated for?"

  home-manager's `sharedModules` are evaluated ONCE PER USER, so
  `config.home.username` differs between evaluations of the same file. That is
  what makes per-user scoping possible at all -- and also what made the bug this
  exists to prevent: a sharedModule may only carry things true of EVERY user, so
  setting `home.username` in one was a category error that collided with
  home-manager's own definition.

  WHY NOT FILTER `imports` CENTRALLY instead, in lib/home-manager.nix, and skip
  touching every feature: `imports` is resolved before the fixpoint exists, so
  it cannot depend on `config`. Computing which modules a user gets from
  `config.my.<feature>.users` is an infinite recursion, not a style choice. The
  condition has to live where it is a `config` value, i.e. inside the module.

  DEGRADES TO TRUE for a feature that declares no `users` option. Compositors
  are the real case -- features/hyprland and features/niri are selected by
  my.desktop.compositor, which is a property of the machine rather than of a
  person, so "applies to everyone with a home" is the right answer and no scope
  option is wanted. Returning true rather than erroring keeps those features
  from needing an option that would only ever have one value.
*/
{ osConfig, config, feature }:

let
  decl = osConfig.my.${feature} or { };
in
!(decl ? users) || builtins.elem config.home.username decl.users
