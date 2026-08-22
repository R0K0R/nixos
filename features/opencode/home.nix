{ config, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.opencode.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "opencode"; };
in
let
  cfg = osConfig.my.opencode;
in
lib.mkIf (cfg.enable && inScope) {
  xdg.configFile."opencode/config.json".text = builtins.toJSON {
    provider = {
      yulee = {
        name = "Yulee (Local)";
        npm = "@ai-sdk/openai-compatible";
        options = {
          apiKey = "dummy";
          baseURL = cfg.baseURL;
        };
        models = {
          diffusiongemma = {
            id = "diffusiongemma";
            name = "DiffusionGemma";
            tool_call = true;
            reasoning = true;
            limit = {
              context = 262144;
              output = 8192;
            };
          };
          "gemma4-31b" = {
            id = "gemma4-31b";
            name = "Gemma 4 31B";
            tool_call = true;
            reasoning = true;
            limit = {
              context = 204800;
              output = 8192;
            };
          };
        };
      };
    };
  };
}
