{ lib, osConfig, ... }:

let
  cfg = osConfig.my.opencode;
in
lib.mkIf cfg.enable {
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
