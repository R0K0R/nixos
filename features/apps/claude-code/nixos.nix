/*
  The SYSTEM half of claude-code: the pinned package, wrapped with
  extraBinPackages, on every account's PATH -- the fallback session and root's
  `sudo claude` run it too -- the /root/.claude link, and ~/.claude's
  persistence. The per-user setup (gemma-claude, skills, MCP servers,
  watermarks-remover) is the home half, my.claude-code in a home repo, since
  2026-10-27.
*/
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
  claude-code = pkgs.callPackage ./package.nix {
    src = inputs.feat-claude-code.src;
    inherit (cfg) extraBinPackages;
  };
in
{
  options.my.claude-code = {
    enable = lib.mkEnableOption "claude-code, pinned to an exact release via flake.lock";

    extraBinPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.pandoc ]";
      description = ''
        Packages whose programs claude-code finds on its PATH, whatever
        PATH it was started with -- put there by its wrapper, not installed
        system-wide.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = claude-code;
      defaultText = lib.literalMD "the vendored package, wrapped with `extraBinPackages`";
      description = ''
        The claude-code this feature installs, for other features that start
        it themselves (features/session/fallback-session). Read-only: the
        knobs are the pin (flake.lock) and extraBinPackages.
      '';
    };

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
      default = config.my.internal.primaryUser;
        defaultText = lib.literalExpression "the primary user";
      description = "Whose ~/.claude the root symlink points at.";
    };
  };

  config = lib.mkIf cfg.enable {
    my.state.user.state.directories = [
      ".claude" # history, sessions, plans, memory; also holds .credentials.json
    ];
    my.state.user.secret.files = [
      ".claude.json" # account/oauth state; activation edits it, so it must persist as a file
    ];
    environment.systemPackages = [ claude-code ];

    systemd.tmpfiles.rules = lib.mkIf cfg.shareWithRoot [
      "L /root/.claude - - - - ${config.users.users.${cfg.primaryUser}.home}/.claude"
    ];
  };
}
