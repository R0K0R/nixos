/*
  The `my.<feature>.users` option, declared once and imported by every feature
  that has a user-facing side.

  WHY A SHARED FACTORY rather than 25 copies: the option is identical in every
  feature, and the one thing that must never drift is its TYPE -- see below.
  The cost is that a feature now imports from lib/, which is a small dent in the
  "hand a feature directory to a stranger" property. Four lines, inlineable by
  whoever takes the feature.

  WHY types.enum AND NOT types.str: a feature scoped to a user that does not
  exist applies to NOBODY, silently. That is the single failure mode of a
  stringly-typed user list, and it looks exactly like a deliberately empty
  scope. Computing the enum from `config.my.users` turns a typo into an eval
  error that names the valid set:

    error: A definition for option `my.fish.users."[definition 1-entry 1]"' is
    not of type `one of "benjamin", "r0k0r"'. Definition values:
    - In `/…/hosts/victus-15/default.nix': "r0k0rr"

  which is strictly better than the assertion it replaces -- it fires at
  evaluation, names the file, and lists what was allowed.

  NO RECURSION, despite the type reading `config`. Forcing it needs only the
  KEY SET of my.users, which comes from the shape of the definitions rather
  than their values; nothing that defines my.users reads a feature's `users`
  option back. Verified against the real fan-out shape (feature scope ->
  my.packages.perUser -> users.users.<n>.packages), including the default-to-
  primary path, which resolves through the same attrset.
*/
{ lib, config }:

lib.mkOption {
  type = lib.types.listOf (lib.types.enum (lib.attrNames config.my.users));

  default = lib.attrNames (lib.filterAttrs (_: u: u.primary) config.my.users);
  defaultText = lib.literalExpression "[ <the account with my.users.<name>.primary = true> ]";

  example = lib.literalExpression ''[ "r0k0r" "benjamin" ]'';

  description = ''
    Accounts this feature applies to, defaulting to the primary user.

    Drives BOTH halves: the feature's `user` packages are fanned out to exactly
    these accounts via my.packages.perUser, and the feature's home-manager half
    only activates for a user in this list. One option, so the two can never
    disagree -- a machine where someone has the fish config but not the fish
    binary is not reachable from here.

    An empty list is legal and means "enabled on this host, applied to nobody",
    which is occasionally what you want for a feature whose NixOS side is the
    point. It is spelled `[ ]` rather than reached by accident, because the enum
    type rejects a name that is not a declared account.
  '';
}
