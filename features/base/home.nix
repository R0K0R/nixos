{
  config,
  lib,
  osConfig,
  ...
}:

let
  # sharedModules are evaluated once per user; this is what makes the feature
  # apply only to the accounts my.base.users names.
  inScope = import ../../lib/in-scope.nix {
    inherit osConfig config;
    feature = "base";
  };
in
let
  cfg = osConfig.my.base;
in
lib.mkIf (cfg.enable && inScope) {
  /*
    gh, and the git credential helper it writes.

    WHY THIS IS DECLARED RATHER THAN LEFT TO `gh auth setup-git`: that command
    writes ~/.gitconfig by hand, baking in the ABSOLUTE STORE PATH of whatever
    gh existed the day it ran --

      helper = !/nix/store/<hash>-gh-2.95.0/bin/.gh-wrapped auth git-credential

    -- and ~/.gitconfig is an ordinary file, so nothing makes that path a GC
    root. The next `nix-collect-garbage` removes the gh it names, and git then
    fails to exec the helper, silently falls back to no helper at all, and
    prompts for a username. Confirmed on victus-15 (gh 2.95.0, collected) and
    latent on galaxybook, whose file still points at gh 2.92.0. The credentials
    are never the problem -- `gh auth status` stays happily logged in -- only
    the path to the binary.

    home-manager's programs.gh writes the same two entries into the config it
    manages, where the store path IS referenced by the generation and therefore
    survives GC. gitCredentialHelper.enable defaults to true, and its `hosts`
    default is exactly https://github.com plus https://gist.github.com, i.e.
    what `gh auth setup-git` produced anyway -- so this is spelled with no
    arguments on purpose.

    programs.git.enable is NOT incidental: programs.gh contributes through
    `programs.git.settings.credential`, which home-manager only writes when the
    git module itself is enabled. Without it this whole block is inert.

    THE HAND-WRITTEN FILE STILL WINS UNTIL IT IS REMOVED. home-manager writes
    ~/.config/git/config; git reads that BEFORE ~/.gitconfig and accumulates
    credential.helper across both. gh's entries start with an empty `helper =`,
    which resets the accumulated chain -- so a leftover ~/.gitconfig section
    wipes this one and re-adds its own. Verified:

      $ git config --get-all credential."https://github.com".helper
                                              <- reset from ~/.config/git/config
      !/nix/store/.../gh auth git-credential   <- ours
                                              <- reset from ~/.gitconfig
      !gh auth git-credential                  <- theirs, and the one used

    So the credential sections have to come out of ~/.gitconfig on each host
    for this to take effect. Everything else in that file (user.name/email,
    sendemail.*, safe.directory) is untouched and keeps working: it is read
    after this one, so it still takes precedence.
  */
  programs.gh.enable = true;
  programs.git.enable = true;
}
