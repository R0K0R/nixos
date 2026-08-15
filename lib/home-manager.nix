/*
  home-manager wiring, in one place because TWO callers need it and they used to
  disagree.

  mkHost sets this up for real hosts. tuning/runtime-cache/tier2-eval.nix builds
  its own throwaway "pass1" config to compute Tier 2 anchors, and that config
  must see the same home-manager users -- home.packages is one of its anchor
  sources.

  It broke exactly once: the wiring used to live in a module the host file
  imported, so pass1 got it for free. Moving it into mkHost left pass1 with no
  home-manager users at all, so imagemagick, eza and every other home package
  silently stopped being anchors and got classified as not-host-runtime, i.e.
  built untuned. Nothing failed; the packages were still installed. Only the
  tuning quietly went away.
*/
{ homeModules, inputs, hostName }:

{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs hostName; };
    backupFileExtension = "hm-backup";
    # Allow replacing an existing *.hm-backup when backing up again (avoids an
    # activation crash on the second run).
    overwriteBackup = true;

    /*
      Feature home halves, plus Unstraightened's own module. In sharedModules
      rather than a per-user config so one `my.<feature>.enable = true` in the
      host file drives both halves; the home side gates on osConfig.my.*.
    */
    sharedModules = homeModules ++ [ inputs.feat-emacs.homeModule ];

    # Nothing to import: every home module is a feature half arriving above.
    users.r0k0r = { };
  };
}
