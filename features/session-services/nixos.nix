{ config, lib, pkgs, ... }:

let
  /*
    DMS writes theme state via `gsettings set org.gnome.desktop.interface
    color-scheme ...` (core/internal/utils/gsettings.go), falling back to raw
    `dconf write` only if that fails -- which is why the dconf VALUE always
    looked correct (`dconf read` bypasses schema validation entirely) while
    nothing that reads via the real GSettings API (what GTK/Electron apps
    actually use, not raw dconf) ever saw it.

    programs.dconf.enable (below) only adds the dconf package/D-Bus service
    itself -- verified directly against nixos/modules/programs/dconf.nix, it
    never touches gsettings-desktop-schemas at all. That package was already
    present in this system's closure (three times over) but only ever
    transitively, and NixOS's system-path schema aggregation
    (nixos/modules/config/system-path.nix) only compiles schemas placed
    directly under share/glib-2.0/schemas/ -- gsettings-desktop-schemas
    ships its schemas nested under share/gsettings-schemas/<pname>-<version>/
    specifically to avoid collisions between coexisting versions, which
    structurally opts it out of that aggregation path. Confirmed on both
    apps directly from their own wrapper scripts: Firefox's wrapper never
    references gsettings-desktop-schemas at all; Claude Desktop's wrapper
    does add its path to XDG_DATA_DIRS, but that path contains only the raw,
    UNCOMPILED .xml schema sources -- GSettings' runtime API only ever reads
    a compiled glib-2.0/schemas/gschemas.compiled blob, so pointing at raw
    XML is inert. Compiling it once here and exporting it session-wide fixes
    both, and any other app with the same gap, in one place instead of
    patching each app's wrapper individually.
  */
  compiledGsettingsSchemas = pkgs.runCommand "compiled-gsettings-schemas" {
    nativeBuildInputs = [ pkgs.glib ];
  } ''
    mkdir -p $out/share/glib-2.0/schemas
    cp ${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/*/glib-2.0/schemas/*.xml \
      $out/share/glib-2.0/schemas/
    glib-compile-schemas $out/share/glib-2.0/schemas
  '';
in
{
  options.my.session-services.enable = lib.mkEnableOption ''
    graphical-session plumbing: dconf, compiled GSettings schemas exported
    session-wide, geoclue2, and the portal/polkit services a bare compositor
    needs because no desktopManager provides them
  '';

  config = lib.mkMerge [
    # Depended upon by locale-automatic (geoclue2); see features/_meta.
    { my.internal.features.session-services.enabledBy = config.my.session-services.enable; }

    (lib.mkIf config.my.session-services.enable {
  /* DMS’s NixOS module turns these on with mkDefault only when HM sets
     programs.dank-material-shell on the *system* module — HM-only setups miss them.
     They are referenced by KDE Connect, GNOME-ish power UI tooling, portals, etc. */
  security.polkit.enable = true;

  # dconf package/CLI/D-Bus service itself -- see compiledGsettingsSchemas
  # above for why this alone doesn't fix schema discovery.
  programs.dconf.enable = true;

  environment.sessionVariables.XDG_DATA_DIRS = [ "${compiledGsettingsSchemas}/share" ];

  /*
    compiledGsettingsSchemas alone was not enough -- confirmed by elimination,
    directly against the actual running session, not a test shell: dconf's
    color-scheme value is correct ('prefer-dark'), the schema compiles and
    resolves correctly, and DMS's own live process (checked its real
    /proc/<pid>/environ) has the correct XDG_DATA_DIRS -- yet Firefox and
    Claude Desktop still showed light. That only makes sense if neither reads
    color-scheme via raw GSettings at all: they check the XDG desktop portal's
    org.freedesktop.appearance interface instead, confirmed absent entirely
    (busctl call to org.freedesktop.portal.Settings returned "No such
    interface"). Neither hyprland's nor niri's own portal wiring implements
    it. DMS can't provide this itself either -- checked its source directly,
    both old and new versions: it's a portal CLIENT (reads Settings to react
    to external changes) and a raw dconf/gsettings WRITER, never a Settings
    portal SERVER. xdg-desktop-portal-gtk is the standard backend that does.

    extraPortals alone still wasn't enough -- confirmed after adding it and
    rebuilding/rebooting twice, the Settings interface was STILL absent.
    Root cause, found by reading the installed .portal files directly
    (/run/current-system/sw/share/xdg-desktop-portal/portals/*.portal):
    gtk.portal correctly lists org.freedesktop.impl.portal.Settings under
    Interfaces=, but also declares `UseIn=gnome`. xdg-desktop-portal honors
    that restriction and refuses to route to gtk's Settings implementation
    on any desktop that doesn't self-identify as gnome -- confirmed live,
    xdg-desktop-portal-gtk.service stayed "inactive (dead)" and never got
    D-Bus-activated even after a fresh restart of the main portal daemon.
    hyprland.portal doesn't implement Settings at all, so with no explicit
    override neither backend is ever selected for it, regardless of both
    being installed and correctly registered. config.common.default forces
    the routing explicitly, overriding each backend's own UseIn= guess.
  */
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "gtk" ];
  };

  services.accounts-daemon.enable = true;
  services.power-profiles-daemon.enable = true;
  services.geoclue2.enable = true;

  /*
    Cups-pk-helper is pulled in via the printing stack (dbus activation + polkit)
    once polkit-enabled printing is on.
  */
  services.printing.enable = true;

  /* systemd / logind lid policy (upstream defaults vary; laptop users expect suspend). */
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
    HandleLidSwitchDocked = "ignore";
  };

  /*
    Bridges system suspend → user sleep.target so per-user units can react.
    Needed so we can invoke DMS lock before sleep below.
  */
  services.systemd-lock-handler.enable = true;
    })
  ];
}
