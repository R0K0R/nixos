{ config, lib, pkgs, osConfig, ... }:

let
  # No `users` option on this feature -- the app is a system package and its
  # config is per-user, so "everyone with a home" is the right answer and
  # in-scope degrades to true, as it does for the compositors.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "claude-desktop"; };

  cfg = osConfig.my.claude-desktop;

  # Desktop speaks MCP over stdio only -- see the option's own note -- so an
  # HTTP server is given to it as a command that speaks stdio and posts.
  bridge = pkgs.writeScriptBin "mcp-http-stdio" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./mcp-http-stdio.py}
  '';

  overStdio =
    _name: def:
    if (def.type or "stdio") == "http" || (def.type or "stdio") == "sse" then
      {
        command = "${bridge}/bin/mcp-http-stdio";
        args = [ def.url ];
      }
    else
      def;

  mcpJson = (pkgs.formats.json { }).generate "claude-desktop-mcp.json" {
    mcpServers = lib.mapAttrs overStdio cfg.mcp.servers;
  };
in
lib.mkIf ((cfg.enable && cfg.mcp.servers != { }) && inScope) {
  # Merged, not symlinked: Claude Desktop rewrites this file whenever a
  # preference changes, so it cannot be a read-only store path.  Idempotent,
  # so a switch that changes nothing leaves the file alone.
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
}
