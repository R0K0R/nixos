{ ... }:

{
  /* Used by systemd --user graphical session (incl. dms/quickshell) for QIcon/fromTheme lookups. */
  environment.sessionVariables = {
    ICON_THEME = "breeze-dark";
    GTK_ICON_THEME = "breeze-dark";
  };
}
