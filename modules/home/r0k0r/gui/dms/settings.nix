/*
  Full DMS settings, one-to-one from the runtime config (schema v11) -- every
  knob is a visible placeholder, edit here and rebuild. To adopt changes made
  in DMS's own settings UI, translate them into this file.

  Glassmorphism knobs: barConfigs[*].transparency/widgetTransparency,
  popupTransparency, dockTransparency (v11 has no global transparency key);
  the frosted backdrop itself comes from Hyprland's blur layerrules
  (wayland/hyprland.nix, namespace ^(dms.*)$).
*/
{
  currentThemeName = "monochrome";
  currentThemeCategory = "generic";
  customThemeFile = "";
  registryThemeVariants = { };
  matugenScheme = "scheme-tonal-spot";
  matugenContrast = 0;
  runUserMatugenTemplates = true;
  matugenTargetMonitor = "";
  popupTransparency = 0.65;
  dockTransparency = 0.6;
  widgetBackgroundColor = "sch";
  widgetColorMode = "default";
  controlCenterTileColorMode = "primary";
  buttonColorMode = "primary";
  cornerRadius = 16;
  niriLayoutGapsOverride = -1;
  niriLayoutRadiusOverride = 16;
  niriLayoutBorderSize = -1;
  hyprlandLayoutGapsOverride = -1;
  hyprlandLayoutRadiusOverride = -1;
  hyprlandLayoutBorderSize = -1;
  mangoLayoutGapsOverride = -1;
  mangoLayoutRadiusOverride = -1;
  mangoLayoutBorderSize = -1;
  firstDayOfWeek = -1;
  showWeekNumber = false;
  use24HourClock = true;
  showSeconds = false;
  padHours12Hour = false;
  useFahrenheit = false;
  windSpeedUnit = "kmh";
  nightModeEnabled = false;
  animationSpeed = 1;
  customAnimationDuration = 500;
  syncComponentAnimationSpeeds = true;
  popoutAnimationSpeed = 1;
  popoutCustomAnimationDuration = 150;
  modalAnimationSpeed = 1;
  modalCustomAnimationDuration = 150;
  enableRippleEffects = true;
  animationVariant = 0;
  motionEffect = 0;
  m3ElevationEnabled = true;
  m3ElevationIntensity = 12;
  m3ElevationOpacity = 30;
  m3ElevationColorMode = "default";
  m3ElevationLightDirection = "top";
  m3ElevationCustomColor = "#000000";
  modalElevationEnabled = true;
  popoutElevationEnabled = true;
  barElevationEnabled = false;
  blurEnabled = true;
  # false: this is DMS's own fake blur -- it blurs the BACKGROUND when
  # overlays open (observed as "spotlight blurs background, not itself")
  # and fights Hyprland's real per-surface blur (the layerrules in
  # wayland/hyprland.nix). Real blur frosts the panel itself.
  blurForegroundLayers = false;
  blurLayerOutlineOpacity = 0.12;
  blurBorderColor = "outline";
  blurBorderCustomColor = "#ffffff";
  blurBorderOpacity = 0.35;
  wallpaperFillMode = "Fill";
  blurredWallpaperLayer = false;
  blurWallpaperOnOverview = false;
  showLauncherButton = true;
  showWorkspaceSwitcher = true;
  showFocusedWindow = true;
  showWeather = true;
  showMusic = true;
  showClipboard = true;
  showCpuUsage = true;
  showMemUsage = true;
  showCpuTemp = true;
  showGpuTemp = true;
  selectedGpuIndex = 0;
  enabledGpuPciIds = [ ];
  showSystemTray = true;
  systemTrayIconTintMode = "none";
  systemTrayIconTintSaturation = 50;
  systemTrayIconTintStrength = 135;
  showClock = true;
  showNotificationButton = true;
  showBattery = true;
  showControlCenterButton = true;
  showCapsLockIndicator = true;
  controlCenterShowNetworkIcon = true;
  controlCenterShowBluetoothIcon = true;
  controlCenterShowAudioIcon = true;
  controlCenterShowAudioPercent = false;
  controlCenterShowVpnIcon = true;
  controlCenterShowBrightnessIcon = false;
  controlCenterShowBrightnessPercent = false;
  controlCenterShowMicIcon = false;
  controlCenterShowMicPercent = false;
  controlCenterShowBatteryIcon = false;
  controlCenterShowPrinterIcon = false;
  controlCenterShowScreenSharingIcon = true;
  showPrivacyButton = true;
  privacyShowMicIcon = false;
  privacyShowCameraIcon = false;
  privacyShowScreenShareIcon = false;
  controlCenterWidgets = [
    {
      id = "volumeSlider";
      enabled = true;
      width = 50;
    }
    {
      id = "brightnessSlider";
      enabled = true;
      width = 50;
    }
    {
      id = "wifi";
      enabled = true;
      width = 50;
    }
    {
      id = "bluetooth";
      enabled = true;
      width = 50;
    }
    {
      id = "audioOutput";
      enabled = true;
      width = 50;
    }
    {
      id = "audioInput";
      enabled = true;
      width = 50;
    }
    {
      id = "nightMode";
      enabled = true;
      width = 50;
    }
    {
      id = "darkMode";
      enabled = true;
      width = 50;
    }
  ];
  showWorkspaceIndex = true;
  showWorkspaceName = false;
  showWorkspacePadding = true;
  workspaceScrolling = false;
  showWorkspaceApps = true;
  workspaceDragReorder = true;
  maxWorkspaceIcons = 1;
  workspaceAppIconSizeOffset = 0;
  groupWorkspaceApps = true;
  workspaceFollowFocus = false;
  showOccupiedWorkspacesOnly = false;
  reverseScrolling = false;
  dwlShowAllTags = false;
  workspaceActiveAppHighlightEnabled = false;
  workspaceColorMode = "default";
  workspaceOccupiedColorMode = "none";
  workspaceUnfocusedColorMode = "default";
  workspaceUrgentColorMode = "default";
  workspaceFocusedBorderEnabled = false;
  workspaceFocusedBorderColor = "primary";
  workspaceFocusedBorderThickness = 2;
  workspaceNameIcons = { };
  waveProgressEnabled = true;
  scrollTitleEnabled = true;
  mediaAdaptiveWidthEnabled = true;
  audioVisualizerEnabled = true;
  audioScrollMode = "volume";
  audioWheelScrollAmount = 5;
  clockCompactMode = false;
  focusedWindowCompactMode = false;
  runningAppsCompactMode = true;
  barMaxVisibleApps = 0;
  barMaxVisibleRunningApps = 0;
  barShowOverflowBadge = true;
  appsDockHideIndicators = false;
  appsDockColorizeActive = false;
  appsDockActiveColorMode = "primary";
  appsDockEnlargeOnHover = false;
  appsDockEnlargePercentage = 125;
  appsDockIconSizePercentage = 100;
  keyboardLayoutNameCompactMode = false;
  runningAppsCurrentWorkspace = true;
  runningAppsGroupByApp = false;
  runningAppsCurrentMonitor = false;
  appIdSubstitutions = [
    {
      pattern = "Spotify";
      replacement = "spotify";
      type = "exact";
    }
    {
      pattern = "beepertexts";
      replacement = "beeper";
      type = "exact";
    }
    {
      pattern = "home assistant desktop";
      replacement = "homeassistant-desktop";
      type = "exact";
    }
    {
      pattern = "com.transmissionbt.transmission";
      replacement = "transmission-gtk";
      type = "contains";
    }
    {
      pattern = "^steam_app_(\\d+)$";
      replacement = "steam_icon_$1";
      type = "regex";
    }
  ];
  centeringMode = "index";
  clockDateFormat = "";
  lockDateFormat = "";
  greeterRememberLastSession = true;
  greeterRememberLastUser = true;
  greeterEnableFprint = true;
  greeterEnableU2f = false;
  greeterWallpaperPath = "";
  greeterUse24HourClock = true;
  greeterShowSeconds = false;
  greeterPadHours12Hour = false;
  greeterLockDateFormat = "";
  greeterFontFamily = "";
  greeterWallpaperFillMode = "";
  mediaSize = 1;
  appLauncherViewMode = "list";
  spotlightModalViewMode = "list";
  browserPickerViewMode = "grid";
  browserUsageHistory = { };
  appPickerViewMode = "grid";
  filePickerUsageHistory = { };
  sortAppsAlphabetically = false;
  appLauncherGridColumns = 4;
  spotlightCloseNiriOverview = true;
  rememberLastQuery = false;
  spotlightSectionViewModes = { };
  appDrawerSectionViewModes = { };
  niriOverviewOverlayEnabled = true;
  dankLauncherV2Size = "compact";
  dankLauncherV2BorderEnabled = false;
  dankLauncherV2BorderThickness = 2;
  dankLauncherV2BorderColor = "primary";
  dankLauncherV2ShowFooter = true;
  dankLauncherV2UnloadOnClose = false;
  dankLauncherV2IncludeFilesInAll = false;
  dankLauncherV2IncludeFoldersInAll = false;
  launcherUseOverlayLayer = false;
  launcherStyle = "full";
  useAutoLocation = true;
  weatherEnabled = true;
  networkPreference = "auto";
  iconTheme = "System Default";
  cursorSettings = {
    niri = {
      hideWhenTyping = false;
    };
    size = 12;
    theme = "Adwaita";
  };
  launcherLogoMode = "apps";
  launcherLogoCustomPath = "";
  launcherLogoColorOverride = "";
  launcherLogoColorInvertOnMode = false;
  launcherLogoBrightness = 0.5;
  launcherLogoContrast = 1;
  launcherLogoSizeOffset = 0;
  fontFamily = "Inter Variable";
  monoFontFamily = "JetBrainsMono Nerd Font Mono";
  fontWeight = 400;
  fontScale = 1;
  textRenderType = 0;
  textRenderQuality = 0;
  notepadUseMonospace = true;
  notepadFontFamily = "";
  notepadFontSize = 14;
  notepadShowLineNumbers = false;
  notepadTransparencyOverride = -1;
  notepadLastCustomTransparency = 0.7;
  soundsEnabled = true;
  useSystemSoundTheme = false;
  soundLogin = false;
  soundNewNotification = true;
  soundVolumeChanged = true;
  soundPluggedIn = true;
  acMonitorTimeout = 0;
  acLockTimeout = 0;
  acSuspendTimeout = 0;
  acSuspendBehavior = 0;
  acProfileName = "";
  acPostLockMonitorTimeout = 0;
  batteryMonitorTimeout = 0;
  batteryLockTimeout = 0;
  batterySuspendTimeout = 0;
  batterySuspendBehavior = 0;
  batteryProfileName = "";
  batteryPostLockMonitorTimeout = 0;
  batteryChargeLimit = 100;
  lockBeforeSuspend = false;
  loginctlLockIntegration = true;
  fadeToLockEnabled = true;
  fadeToLockGracePeriod = 5;
  fadeToDpmsEnabled = true;
  fadeToDpmsGracePeriod = 5;
  launchPrefix = "";
  brightnessDevicePins = { };
  wifiNetworkPins = { };
  bluetoothDevicePins = { };
  audioInputDevicePins = { };
  audioOutputDevicePins = { };
  gtkThemingEnabled = false;
  qtThemingEnabled = false;
  syncModeWithPortal = true;
  terminalsAlwaysDark = false;
  muxType = "tmux";
  muxUseCustomCommand = false;
  muxCustomCommand = "";
  muxSessionFilter = "";
  runDmsMatugenTemplates = true;
  matugenTemplateGtk = true;
  matugenTemplateNiri = true;
  matugenTemplateHyprland = true;
  matugenTemplateMangowc = true;
  matugenTemplateQt5ct = true;
  matugenTemplateQt6ct = true;
  matugenTemplateFirefox = true;
  matugenTemplatePywalfox = true;
  matugenTemplateZenBrowser = true;
  matugenTemplateVesktop = true;
  matugenTemplateVencord = true;
  matugenTemplateEquibop = true;
  matugenTemplateGhostty = true;
  matugenTemplateKitty = true;
  matugenTemplateFoot = true;
  matugenTemplateAlacritty = true;
  matugenTemplateNeovim = false;
  matugenTemplateWezterm = true;
  matugenTemplateDgop = true;
  matugenTemplateKcolorscheme = true;
  matugenTemplateVscode = true;
  matugenTemplateEmacs = true;
  matugenTemplateZed = true;
  matugenTemplateNeovimSettings = {
    dark = {
      baseTheme = "github_dark";
      harmony = 0.5;
    };
    light = {
      baseTheme = "github_light";
      harmony = 0.5;
    };
  };
  matugenTemplateNeovimSetBackground = true;
  showDock = false;
  dockAutoHide = false;
  dockSmartAutoHide = false;
  dockUseOverlayLayer = false;
  dockGroupByApp = false;
  dockRestoreSpecialWorkspaceOnClick = false;
  dockOpenOnOverview = false;
  dockPosition = 1;
  dockSpacing = 4;
  dockBottomGap = 0;
  dockMargin = 0;
  dockIconSize = 40;
  dockIndicatorStyle = "circle";
  dockBorderEnabled = false;
  dockBorderColor = "surfaceText";
  dockBorderOpacity = 1;
  dockBorderThickness = 1;
  dockIsolateDisplays = false;
  dockLauncherEnabled = false;
  dockLauncherLogoMode = "apps";
  dockLauncherLogoCustomPath = "";
  dockLauncherLogoColorOverride = "";
  dockLauncherLogoSizeOffset = 0;
  dockLauncherLogoBrightness = 0.5;
  dockLauncherLogoContrast = 1;
  dockMaxVisibleApps = 0;
  dockMaxVisibleRunningApps = 0;
  dockShowOverflowBadge = true;
  dockShowTrash = false;
  dockTrashFileManager = "default";
  dockTrashCustomCommand = "";
  notificationOverlayEnabled = false;
  notificationPopupShadowEnabled = true;
  notificationPopupPrivacyMode = false;
  modalDarkenBackground = true;
  lockScreenShowPowerActions = true;
  lockScreenShowSystemIcons = true;
  lockScreenShowTime = true;
  lockScreenShowDate = true;
  lockScreenShowProfileImage = true;
  lockScreenShowPasswordField = true;
  lockScreenShowMediaPlayer = true;
  lockScreenPowerOffMonitorsOnLock = false;
  lockAtStartup = false;
  enableFprint = false;
  maxFprintTries = 15;
  enableU2f = false;
  u2fMode = "or";
  lockScreenActiveMonitor = "all";
  lockScreenInactiveColor = "#000000";
  lockScreenNotificationMode = 0;
  lockScreenVideoEnabled = false;
  lockScreenVideoPath = "";
  lockScreenVideoCycling = false;
  hideBrightnessSlider = false;
  notificationTimeoutLow = 5000;
  notificationTimeoutNormal = 5000;
  notificationTimeoutCritical = 0;
  notificationCompactMode = false;
  notificationPopupPosition = 0;
  notificationAnimationSpeed = 1;
  notificationCustomAnimationDuration = 400;
  notificationHistoryEnabled = true;
  notificationHistoryMaxCount = 50;
  notificationHistoryMaxAgeDays = 7;
  notificationHistorySaveLow = true;
  notificationHistorySaveNormal = true;
  notificationHistorySaveCritical = true;
  notificationRules = [ ];
  notificationFocusedMonitor = false;
  osdAlwaysShowValue = false;
  osdPosition = 5;
  osdVolumeEnabled = true;
  osdMediaVolumeEnabled = true;
  osdMediaPlaybackEnabled = false;
  osdBrightnessEnabled = true;
  osdIdleInhibitorEnabled = true;
  osdMicMuteEnabled = true;
  osdCapsLockEnabled = true;
  osdPowerProfileEnabled = false;
  osdAudioOutputEnabled = true;
  powerActionConfirm = true;
  powerActionHoldDuration = 0.5;
  powerMenuActions = [
    "reboot"
    "logout"
    "poweroff"
    "lock"
    "suspend"
    "restart"
  ];
  powerMenuDefaultAction = "logout";
  powerMenuGridLayout = false;
  customPowerActionLock = "";
  customPowerActionLogout = "";
  customPowerActionSuspend = "";
  customPowerActionHibernate = "";
  customPowerActionReboot = "";
  customPowerActionPowerOff = "";
  updaterHideWidget = false;
  updaterCheckOnStart = false;
  updaterUseCustomCommand = false;
  updaterCustomCommand = "";
  updaterTerminalAdditionalParams = "";
  updaterIntervalSeconds = 1800;
  updaterIncludeFlatpak = true;
  updaterAllowAUR = true;
  displayNameMode = "system";
  screenPreferences = { };
  showOnLastDisplay = { };
  niriOutputSettings = { };
  hyprlandOutputSettings = { };
  displayProfiles = { };
  activeDisplayProfile = { };
  displayProfileAutoSelect = false;
  displayShowDisconnected = false;
  displaySnapToEdge = true;
  connectedFrameBarStyleBackups = { };
  barConfigs = [
    {
      autoHide = false;
      autoHideDelay = 250;
      autoHideStrict = false;
      borderColor = "surfaceText";
      borderEnabled = false;
      borderOpacity = 1;
      borderThickness = 1;
      bottomGap = 0;
      centerWidgets = [
        "music"
        "clock"
        "weather"
      ];
      clickThrough = false;
      enabled = true;
      fontScale = 1;
      fullscreenDetection = true;
      gothCornerRadiusOverride = false;
      gothCornerRadiusValue = 12;
      gothCornersEnabled = false;
      iconScale = 1;
      id = "default";
      innerPadding = 4;
      leftWidgets = [
        "launcherButton"
        "workspaceSwitcher"
        "focusedWindow"
      ];
      maximizeDetection = true;
      maximizeWidgetIcons = false;
      maximizeWidgetText = false;
      name = "Main Bar";
      noBackground = false;
      openOnOverview = false;
      popupGapsAuto = true;
      popupGapsManual = 4;
      position = 0;
      removeWidgetPadding = false;
      rightWidgets = [
        "systemTray"
        "clipboard"
        "cpuUsage"
        "memUsage"
        "notificationButton"
        "battery"
        "controlCenterButton"
        {
          enabled = true;
          id = "dankKDEConnect";
        }
      ];
      screenPreferences = [
        "all"
      ];
      scrollEnabled = true;
      scrollXBehavior = "column";
      scrollYBehavior = "workspace";
      shadowColorMode = "default";
      shadowCustomColor = "#000000";
      shadowIntensity = 0;
      shadowOpacity = 60;
      showOnLastDisplay = true;
      showOnWindowsOpen = false;
      spacing = 4;
      squareCorners = false;
      transparency = 0.6;
      visible = true;
      widgetOutlineColor = "primary";
      widgetOutlineEnabled = false;
      widgetOutlineOpacity = 1;
      widgetOutlineThickness = 1;
      widgetPadding = 8;
      widgetTransparency = 0.65;
    }
  ];
  desktopClockEnabled = false;
  desktopClockStyle = "analog";
  desktopClockTransparency = 0.8;
  desktopClockColorMode = "primary";
  desktopClockCustomColor = {
    r = 1;
    g = 1;
    b = 1;
    a = 1;
    hsvHue = -1;
    hsvSaturation = 0;
    hsvValue = 1;
    hslHue = -1;
    hslSaturation = 0;
    hslLightness = 1;
    valid = true;
  };
  desktopClockShowDate = true;
  desktopClockShowAnalogNumbers = false;
  desktopClockShowAnalogSeconds = true;
  desktopClockX = -1;
  desktopClockY = -1;
  desktopClockWidth = 280;
  desktopClockHeight = 180;
  desktopClockDisplayPreferences = [
    "all"
  ];
  systemMonitorEnabled = false;
  systemMonitorShowHeader = true;
  systemMonitorTransparency = 0.8;
  systemMonitorColorMode = "primary";
  systemMonitorCustomColor = {
    r = 1;
    g = 1;
    b = 1;
    a = 1;
    hsvHue = -1;
    hsvSaturation = 0;
    hsvValue = 1;
    hslHue = -1;
    hslSaturation = 0;
    hslLightness = 1;
    valid = true;
  };
  systemMonitorShowCpu = true;
  systemMonitorShowCpuGraph = true;
  systemMonitorShowCpuTemp = true;
  systemMonitorShowGpuTemp = false;
  systemMonitorGpuPciId = "";
  systemMonitorShowMemory = true;
  systemMonitorShowMemoryGraph = true;
  systemMonitorShowNetwork = true;
  systemMonitorShowNetworkGraph = true;
  systemMonitorShowDisk = true;
  systemMonitorShowTopProcesses = false;
  systemMonitorTopProcessCount = 3;
  systemMonitorTopProcessSortBy = "cpu";
  systemMonitorGraphInterval = 60;
  systemMonitorLayoutMode = "auto";
  systemMonitorX = -1;
  systemMonitorY = -1;
  systemMonitorWidth = 320;
  systemMonitorHeight = 480;
  systemMonitorDisplayPreferences = [
    "all"
  ];
  systemMonitorVariants = [ ];
  desktopWidgetPositions = { };
  desktopWidgetGridSettings = { };
  desktopWidgetInstances = [ ];
  desktopWidgetGroups = [ ];
  builtInPluginSettings = { };
  clipboardEnterToPaste = false;
  launcherPluginVisibility = { };
  launcherPluginOrder = [ ];
  frameEnabled = false;
  frameThickness = 16;
  frameRounding = 23;
  frameColor = "";
  frameOpacity = 1;
  frameScreenPreferences = [
    "all"
  ];
  frameBarSize = 40;
  frameShowOnOverview = false;
  frameBlurEnabled = true;
  frameCloseGaps = true;
  frameLauncherEmergeSide = "bottom";
  frameLauncherArcExtender = false;
  frameUseSpotlightLauncher = false;
  frameMode = "connected";
  configVersion = 11;
  theme = "dark";
  dynamicTheming = true;
}
