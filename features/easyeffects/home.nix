{ config, lib, pkgs, inputs, osConfig, ... }:

let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.easyeffects.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "easyeffects"; };

  /*
    The upstream repo is a FLAT collection: every preset is a *.json at the repo
    root, with impulse responses under irs/. It has no `output/` directory, and
    linking one produced a dangling symlink and zero visible presets -- the bug
    this derivation exists to fix. EasyEffects' own layout, per upstream's
    install.sh, is

      ~/.config/easyeffects/output/*.json     the presets
      ~/.config/easyeffects/irs/*.irs         impulse responses they reference

    so the shapes have to be translated rather than symlinked across. Doing it
    in a derivation rather than with per-file xdg.configFile entries keeps the
    file list out of the evaluator: it is 9 presets and 25 IRS files today, and
    a `readDir` over the flake input would re-evaluate on every preset the
    upstream repo ever adds.

    install.sh also sed-replaces a <PRESETS_DIRECTORY> placeholder in some
    presets, for convolver paths. The current revision has none -- checked, not
    assumed -- so that step is deliberately not reproduced here. If upstream
    reintroduces it, the convolver would silently load nothing, and the fix is a
    substituteInPlace against config.xdg.configHome.
  */
  presetTree = pkgs.runCommandLocal "easyeffects-presets" { } ''
    mkdir -p "$out/output" "$out/irs"
    cp ${inputs.feat-easyeffects.presets}/*.json "$out/output/"
    cp ${inputs.feat-easyeffects.presets}/irs/*.irs "$out/irs/"
  '';
in
lib.mkIf (osConfig.my.easyeffects.enable && inScope) {
  /*
    recursive = true so each preset is its OWN symlink inside a real directory,
    rather than the directory itself being a store symlink. EasyEffects writes
    into this directory when you save a preset, which a read-only store symlink
    would make impossible.
  */
  xdg.configFile."easyeffects/output" = {
    source = "${presetTree}/output";
    recursive = true;
  };

  xdg.configFile."easyeffects/irs" = {
    source = "${presetTree}/irs";
    recursive = true;
  };

  /*
    Background/tray autostart, same shape as the Galaxy Buds client in
    features/samsung-ecosystem -- bound to graphical-session.target so it is
    compositor-agnostic (uwsm activates the target under both hyprland and
    niri), rather than an exec-once in one compositor's config.

    Declared HERE rather than as a NixOS systemd.user.service, unlike the buds
    client: a NixOS user service is generated for every account on the machine,
    which would start EasyEffects for people this feature was never scoped to.
    home-manager's units are per-user by construction, so the service exists
    exactly where my.easyeffects.users says it should.

    -w/--hide-window is the app's own flag for starting without the main window;
    it has a matching --quit "useful when running in service mode", i.e. this is
    the supported way to run it detached rather than a workaround.
  */
  systemd.user.services.easyeffects = lib.mkIf osConfig.my.easyeffects.startUp {
    Unit = {
      Description = "EasyEffects audio effects (hidden)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" "pipewire.service" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      Type = "simple";
      ExecStart = "${lib.getExe pkgs.easyeffects} --hide-window";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
