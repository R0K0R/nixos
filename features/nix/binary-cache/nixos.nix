/*
  This store as an HTTP binary cache (harmonia), for the other machines'
  `substituters` in place of `ssh-ng://`.

  Why HTTP: a no-op home build on galaxybook (everything already built),
  measured 2026-11-17 with yulee as the one peer substituter:
    ssh-ng://r0k0r@yulee     422.4 s, then 26.5 s
    http://yulee:5000          15.0 s cold, then 3.3 s, 3.4 s
    no peer substituter         3.4 s (the floor)
  Under content addressing every unresolved derivation asks each substituter
  for its realisation. An ssh-ng store answers one query at a time over one
  session and caches no negative answer, so a single stall (a Wi-Fi roam)
  holds every query behind it; an HTTP cache is queried in parallel and its
  answers, misses included, land in the client's narinfo cache
  (narinfo-cache-negative-ttl). harmonia serves realisations too
  (harmonia-cache/src/realisations.rs), which a CA substituter needs.

  Signed with this host's existing store key (my.nix-settings), so clients
  that already trust "<host>-1" need no new key. Listening on the tailnet
  only: the port is opened on tailscale0, nowhere else.
*/
{ config, lib, ... }:
let
  cfg = config.my.binary-cache;
in
{
  options.my.binary-cache = {
    enable = lib.mkEnableOption "an HTTP binary cache of this store (harmonia), on the tailnet";
    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "TCP port harmonia listens on, opened on tailscale0 only.";
    };
    signKeyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/nix-signing-key";
      description = ''
        Secret key the cache signs with: by default the store key
        my.nix-settings.signingKeySecret decrypts, whose public half the
        clients already trust.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [ cfg.signKeyPath ];
      settings = {
        bind = "[::]:${toString cfg.port}";
        # Clients set their own order with ?priority= (my.remote-builder);
        # this is only the default for one that does not.
        priority = 30;
      };
    };
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}
