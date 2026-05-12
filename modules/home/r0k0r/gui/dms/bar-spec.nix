# From DMS `SettingsSpec.js` `barConfigs.def[0]` — setting `barConfigs` replaces the whole value, so include the full bar.
{
  id = "default";
  name = "Main Bar";
  enabled = true;
  position = 0;
  screenPreferences = [ "all" ];
  showOnLastDisplay = true;
  leftWidgets = [
    "launcherButton"
    "workspaceSwitcher"
    "focusedWindow"
  ];
  centerWidgets = [
    "music"
    "clock"
    "weather"
  ];
  rightWidgets = [
    "systemTray"
    "clipboard"
    "cpuUsage"
    "memUsage"
    "notificationButton"
    "battery"
    "controlCenterButton"
  ];
  spacing = 4;
  innerPadding = 4;
  bottomGap = 0;
  transparency = 1.0;
  widgetTransparency = 1.0;
  squareCorners = false;
  noBackground = false;
  maximizeWidgetIcons = false;
  maximizeWidgetText = false;
  removeWidgetPadding = false;
  widgetPadding = 8;
  gothCornersEnabled = false;
  gothCornerRadiusOverride = false;
  gothCornerRadiusValue = 12;
  borderEnabled = false;
  borderColor = "surfaceText";
  borderOpacity = 1.0;
  borderThickness = 1;
  widgetOutlineEnabled = false;
  widgetOutlineColor = "primary";
  widgetOutlineOpacity = 1.0;
  widgetOutlineThickness = 1;
  fontScale = 1.0;
  iconScale = 1.0;
  autoHide = false;
  autoHideStrict = false;
  autoHideDelay = 250;
  showOnWindowsOpen = false;
  openOnOverview = false;
  visible = true;
  popupGapsAuto = true;
  popupGapsManual = 4;
  maximizeDetection = true;
  fullscreenDetection = true;
  scrollEnabled = true;
  scrollXBehavior = "column";
  scrollYBehavior = "workspace";
  shadowIntensity = 0;
  shadowOpacity = 60;
  shadowColorMode = "default";
  shadowCustomColor = "#000000";
  clickThrough = false;
}
