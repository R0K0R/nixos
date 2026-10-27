{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.dms;
in
{
  # The greeter moved out of dms itself into its own repo/module. Imported
  # unconditionally: `imports` cannot be gated, and an unenabled module costs
  # only its option declarations.
  imports = [ inputs.feat-dms.greeterModule ];

  options.my.dms = {
    enable = lib.mkEnableOption ''
      DankMaterialShell's system half: the shell's role, the rotation hook
      for its bar. The shell itself (settings, plugins, compositor glue) is
      the home half, my.dms in a home repo
    '';

    greeter = {
      enable = lib.mkEnableOption "the DMS login greeter (dank-greeter, a separate upstream repo)";

      primaryLogin = lib.mkOption {
        type = lib.types.str;
        default = config.my.internal.primaryUser;
        defaultText = lib.literalExpression "the primary user";
        description = ''
          Whose home directory the greeter reads theme state from, so the login
          screen matches the desktop.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      my.internal.features.dms = {
        # The shell reads my.desktop.compositor for its workspace and bar
        # integration; with no compositor selected it has nothing to attach to.
        requires = [ "compositor" ];
        # Two shells would both configure the compositor, both start a bar, and
        # produce a session with two of everything and no error. See the role
        # note in features/_meta.
        provides = [ "shell" ];
        enabledBy = cfg.enable;
      };

      my.internal.features."dms.greeter" = {
        # The greeter IS a greetd session. Without greetd it is built, installed,
        # and never launched -- no error anywhere.
        requires = [ "greetd" ];
        enabledBy = cfg.greeter.enable;
      };
    }

    /*
      Swap the bar when the screen rotates.

      Through the compositor's hook list rather than by features/hyprland
      calling this script directly, which is what it used to do. Rotation is
      not a keypress -- it arrives as a batch of legacy `hyprctl keyword`
      commands that the shim in features/hyprland rewrites -- so it is the one
      piece of compositor integration home-manager's option merging cannot
      express, and needs a declared extension point instead.
    */
    (lib.mkIf (cfg.enable && config.my.desktop.compositor == "hyprland") {
      my.hyprland.rotationHooks = [ (import ./bar-orientation.nix { inherit pkgs; }) ];
    })

    (lib.mkIf cfg.greeter.enable {
    # state, not optional: the remembered SESSION is what it holds, and when
    # it was wiped the greeter fell back to the first entry, "Hyprland
    # (uwsm-managed)", which this config does not start under (2026-10-24).
    my.state.system.state.directories = [
      "/var/lib/dms-greeter" # greeter's remembered user/session
    ];
    programs.dms-greeter = {
      enable = true;
      # The greeter has to launch the same compositor the session uses, so it
      # reads the single host-level choice rather than duplicating it.
      compositor.name = config.my.desktop.compositor;

      configHome = config.users.users.${cfg.greeter.primaryLogin}.home;

      logs = {
        save = true;
        path = "/tmp/dms-greeter.log";
      };

      quickshell.package = pkgs.quickshell;
    };

    /*
      Never remember a passwordless account. The greeter preselects the
      remembered user and, with fingerprint auth available, starts PAM at
      once; for an account with an empty hash pam_unix's nullok then succeeds
      without a prompt, so after one guest login every boot went straight
      back into guest with no way to pick r0k0r (2026-10-26). Dropping the
      key before the greeter reads it leaves the user picker up instead.
    */
    systemd.services.greetd.preStart =
      let
        passwordless = lib.attrNames (lib.filterAttrs (_: u: u.passwordless) config.my.users);
      in
      lib.mkIf (passwordless != [ ]) (lib.mkAfter ''
        mem=/var/lib/dms-greeter/.local/state/memory.json
        if [ -f "$mem" ] && ${pkgs.jq}/bin/jq -e --argjson pl '${builtins.toJSON passwordless}' \
             '.lastSuccessfulUser as $u | $pl | index($u)' "$mem" >/dev/null 2>&1; then
          ${pkgs.jq}/bin/jq 'del(.lastSuccessfulUser)' "$mem" > "$mem.tmp" && mv "$mem.tmp" "$mem"
          chown greeter: "$mem" || :
        fi
      '');
    })

  ];
}
