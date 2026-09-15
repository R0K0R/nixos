{ config, lib, pkgs, inputs, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.claude-code.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "claude-code"; };
in
let
  cfg = osConfig.my.claude-code;

  # Same pinned claude-code the NixOS half installs (vendored package; binary
  # hash-pinned via the claude-code-bin flake input).
  claude-code = pkgs.callPackage ./package.nix { src = inputs.feat-claude-code.src; };

  # Pinned to a commit in watermarks-remover.nix, so the version is the flake's
  # rather than whatever upstream's install_skill.py copied in at the time.
  wmr = pkgs.callPackage ./watermarks-remover.nix { };
  wmrShare = "${wmr}/share/watermarks-remover";

  # One store file, symlinked into every project that asked for it, so the
  # servers cannot drift apart between projects and a generation switch moves
  # them together.
  mcpJson = (pkgs.formats.json { }).generate "claude-mcp.json" {
    mcpServers = cfg.mcp.servers;
  };

  gemma-claude = pkgs.writeScriptBin "gemma-claude" ''
    #! /bin/sh
    exec env \
      ANTHROPIC_BASE_URL=${cfg.gemma.baseURL} \
      ANTHROPIC_API_KEY=dummy \
      ANTHROPIC_DEFAULT_SONNET_MODEL=${cfg.gemma.sonnetModel} \
      ANTHROPIC_DEFAULT_HAIKU_MODEL=${cfg.gemma.sonnetModel} \
      ANTHROPIC_DEFAULT_OPUS_MODEL=${cfg.gemma.opusModel} \
      CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000 \
      ${claude-code}/bin/claude "$@"
  '';
in
lib.mkMerge [
  (lib.mkIf ((cfg.enable && cfg.gemma.enable) && inScope) {
    home.packages = [ gemma-claude ];
  })

  /*
    Claude Desktop is not covered: upstream ships a Claude Code plugin, two
    skills and a Cursor integration, and no MCP server -- Desktop loads only
    MCP servers, so there is nothing there to install.

    The plugin's PostToolUse hook (Write|Edit|MultiEdit|NotebookEdit -> node
    run_hook.js) is deliberately NOT wired up: it would run after every file
    write in every session and needs node. Add it consciously if wanted.
  */
  (lib.mkIf ((cfg.enable && cfg.mcp.servers != { } && cfg.mcp.projects != [ ]) && inScope) {
    home.file = lib.listToAttrs (
      map (dir: {
        name = "${dir}/.mcp.json";
        value.source = mcpJson;
      }) cfg.mcp.projects
    );
  })

  (lib.mkIf ((cfg.enable && cfg.mcp.servers != { } && cfg.mcp.desktop.enable) && inScope) {
    # Merged, not symlinked: the file is Claude Desktop's own state, and it
    # rewrites it whenever a preference changes.  Idempotent, so a switch that
    # changes nothing leaves the file untouched.
    home.activation.claudeDesktopMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      desktopConfig="$HOME/.config/Claude/claude_desktop_config.json"
      run mkdir -p "$(dirname "$desktopConfig")"
      [ -f "$desktopConfig" ] || run echo '{}' > "$desktopConfig"
      merged="$(${pkgs.jq}/bin/jq --slurpfile add ${mcpJson} \
        '.mcpServers = ((.mcpServers // {}) + $add[0].mcpServers)' "$desktopConfig")"
      if [ "$merged" != "$(cat "$desktopConfig")" ]; then
        run printf '%s\n' "$merged" > "$desktopConfig"
      fi
    '';
  })

  (lib.mkIf ((cfg.enable && cfg.watermarksRemover.enable) && inScope) {
    home.packages = [ wmr ];

    # Symlinks into the store, so switching generations moves both skills
    # together and a GC cannot leave a dangling skill directory behind.
    home.file.".claude/skills/remove-ai-marks".source = "${wmrShare}/skills/remove-ai-marks";
    home.file.".claude/skills/clean-user-facing-text".source = "${wmrShare}/skills/clean-user-facing-text";

    systemd.user.services.watermarks-remover = lib.mkIf cfg.watermarksRemover.service.enable {
      Unit.Description = "watermarks-remover local HTTP service";
      Service = {
        # Loopback only: it takes file paths and rewrites them in place, so it
        # must never be reachable off-host.
        ExecStart = "${pkgs.python3}/bin/python3 ${wmrShare}/service/scripts/server.py"
          + " --host 127.0.0.1 --port ${toString cfg.watermarksRemover.service.port}";
        Environment = [
          "PYTHONPATH=${wmrShare}"
          # The service shells out to these when present and silently drops the
          # corresponding capability when not -- /capabilities reports which it
          # found. A user unit inherits almost no PATH, so name them explicitly.
          "PATH=${
            lib.makeBinPath [
              pkgs.exiftool
              pkgs.ffmpeg
              pkgs.ghostscript
              pkgs.qpdf
              pkgs.c2patool
            ]
          }"
        ];
        Restart = "on-failure";
      };
      Install.WantedBy = [ "default.target" ];
    };
  })
]
