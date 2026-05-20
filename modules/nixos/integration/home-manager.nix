{ inputs, hostName, ... }:

{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs hostName; };
    backupFileExtension = "hm-backup";
    /* Allow replacing an existing *.hm-backup when backing up again (avoids activation crash). */
    overwriteBackup = true;
    users.r0k0r = import ../../../home-r0k0r.nix;
  };
}
