{ ... }:

{
  services.greetd = {
    enable = true;
    settings.default_session.user = "greeter";
  };
}
