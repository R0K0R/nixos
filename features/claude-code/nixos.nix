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
      default = config.my.internal.primaryUser;
        defaultText = lib.literalExpression "the primary user";
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

    watermarksRemover = {
      enable = lib.mkEnableOption ''
        watermarks-remover: wm-* CLI tools plus its two Claude Code skills,
        pinned to a commit in watermarks-remover.nix rather than installed
        with upstream's install_skill.py
      '';

      service = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Run the local HTTP service as a user unit. Only the
            remove-ai-marks skill needs it; clean-user-facing-text is
            self-contained and the wm-* tools call the scripts directly.
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8765;
          description = "Loopback port for the service. Upstream's default.";
        };
      };
    };

    mcp = {
      servers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
        example = lib.literalExpression ''
          {
            noteworthy = {
              type = "http";
              url = "http://yulee:8010/mcp";
            };
          }
        '';
        description = ''
          MCP servers to declare, by name, in the shape Claude Code reads
          (`type` and `url` for HTTP; `command`, `args`, `env` for stdio).

          Written as a `.mcp.json` in each directory `mcp.projects` names,
          that being the only config file Claude Code reads without being
          told to on the command line: `--mcp-config` is a global variadic
          flag, so baking it into a wrapper swallows the subcommand after it,
          and `~/.claude.json` is state the program rewrites itself.

          Claude Code still asks once, per project, before it will talk to a
          server declared this way. That prompt is its trust gate and this
          option does not try to answer it.
        '';
      };

      projects = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "noteworthy" ];
        description = ''
          Directories, relative to the user's home, to write `.mcp.json`
          into. A project gets the servers only if it is named here: which
          sessions may act through a server is a decision, not a default.
        '';
      };
    };
  };

  options.my.claude-code.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ claude-code ];

    systemd.tmpfiles.rules = lib.mkIf cfg.shareWithRoot [
      "L /root/.claude - - - - ${config.users.users.${cfg.primaryUser}.home}/.claude"
    ];
  };
}
