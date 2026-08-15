{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.claude-code;

  /*
    Vendored package; the binary itself is hash-pinned via the claude-code-bin
    flake input. Anthropic's release channel carries every published version
    immediately, so this avoids nixpkgs packaging lag while still rolling back
    with generations and needing no network at activation time.

    Bump: features/claude-code/update.sh [version], then rebuild.
  */
  claude-code = pkgs.callPackage ./package.nix { src = inputs.feat-claude-code.src; };
in
{
  options.my.claude-code = {
    enable = lib.mkEnableOption "claude-code, pinned to an exact release via flake.lock";

    shareWithRoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Symlink /root/.claude to the primary user's ~/.claude, so `sudo claude`
        shares one set of credentials, history and settings rather than starting
        cold as root.
      '';
    };

    primaryUser = lib.mkOption {
      type = lib.types.str;
      default = "r0k0r";
      description = "Whose ~/.claude the root symlink points at.";
    };

    gemma = {
      enable = lib.mkEnableOption ''
        the `gemma-claude` wrapper: claude-code pointed at a local
        OpenAI-compatible endpoint instead of Anthropic's API
      '';

      baseURL = lib.mkOption {
        type = lib.types.str;
        default = "http://yulee:8002";
        description = ''
          Endpoint the wrapper talks to. Deliberately not shared with the
          opencode feature or DMS's AI panel: those name the same host today
          but are independent consumers, not one value duplicated.
        '';
      };

      sonnetModel = lib.mkOption {
        type = lib.types.str;
        default = "diffusiongemma";
        description = "Model substituted for Sonnet (and Haiku).";
      };

      opusModel = lib.mkOption {
        type = lib.types.str;
        default = "gemma4-31b";
        description = "Model substituted for Opus.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ claude-code ];

    systemd.tmpfiles.rules = lib.mkIf cfg.shareWithRoot [
      "L /root/.claude - - - - ${config.users.users.${cfg.primaryUser}.home}/.claude"
    ];
  };
}
