{ lib, ... }:

{
  xdg.configFile."opencode/config.json".text = builtins.toJSON {
    provider = {
      yulee = {
        name = "Yulee (Local)";
        api = "openai";
        options = {
          apiKey = "dummy";
          baseURL = "http://yulee:8000/v1/";
        };
        models = {
          diffusiongemma = {
            id = "diffusiongemma";
            name = "DiffusionGemma";
            tool_call = false;
            limit = {
              context = 32768;
              output = 8192;
            };
          };
          "gemma4-31b" = {
            id = "gemma4-31b";
            name = "Gemma 4 31B";
            tool_call = true;
            limit = {
              context = 131072;
              output = 8192;
            };
          };
        };
      };
    };
  };
}
