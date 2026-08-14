{ inputs, hostName, ... }:

{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs hostName; };
    backupFileExtension = "hm-backup";
    /* Allow replacing an existing *.hm-backup when backing up again (avoids activation crash). */
    overwriteBackup = true;
    sharedModules = [ inputs.nix-doom-emacs-unstraightened.homeModule ];

    /*
      Headless hosts get an Emacs-only home config; the full one imports the
      GUI stack, which has nothing to attach to on a machine with no display
      manager or compositor. See home-r0k0r-headless.nix.
    */
    users.r0k0r = import (
      if hostName == "victus-15" then ../../../home-r0k0r-headless.nix else ../../../home-r0k0r.nix
    );
  };
}
