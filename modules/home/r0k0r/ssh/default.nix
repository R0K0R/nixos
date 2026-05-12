{ ... }:

{
  programs.ssh = {
    enable = true;

    matchBlocks = {
      yulee = {
        hostname = "10.8.0.22";
        user = "r0k0r";
      };
    };
  };

  home.file.".ssh/known_hosts".text = ''
    yulee,10.8.0.22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2O6gqRdfKcKJQU/KLBGSnsf1VKj67IfHqzAEyWn014
  '';
}
