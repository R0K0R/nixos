/*
  Full DMS settings, one-to-one from the runtime config (schema v11) -- every
  knob is a visible placeholder, edit here and rebuild. To adopt changes made
  in DMS's own settings UI, translate them into this file.

  Glassmorphism knobs: barConfigs[*].transparency/widgetTransparency,
  popupTransparency, dockTransparency (v11 has no global transparency key);
  the frosted backdrop itself comes from Hyprland's blur layerrules
  (features/hyprland/home.nix, namespace ^(dms.*)$).
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
  popupTransparency = 0.35;
  dockTransparency = 0.3;
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
  # features/hyprland/home.nix). Real blur frosts the panel itself.
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
    {
      # "plugin_" prefix (not the bare plugin id) is what routes this to
      # PluginService.pluginWidgetComponents in DMS's DragDropGrid.qml --
      # otherwise it falls through to the builtin-only switch and renders
      # as an "Unknown" placeholder tile.
      id = "plugin_noSleep";
      enabled = true;
      width = 50;
    }
    {
      id = "plugin_rotationLock";
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
  # Shrinks the app glyph, and with it each pill: baseWidth is
  # max(widgetHeight * 0.7, appIconSize * 1.2) horizontally, so this helps
  # until it hits that floor -- past roughly -2 nothing more is gained.
  workspaceAppIconSizeOffset = -2;
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
  /*
    Bar widgets OVERLAP on a narrow screen -- rotate this panel to portrait and
    the title runs under the centre clock. That is structural in DMS, not a
    misconfiguration, and no setting turns it off:

      hLeftSection    anchors.left:            parent.left
      hCenterSection  anchors.horizontalCenter: parent.horizontalCenter
      hRightSection   anchors.right:           parent.right

    Three independently anchored items with clip: false and no width
    negotiation between them -- see Modules/DankBar/DankBarContent.qml. Nothing
    measures the total, so past a certain width they simply draw on top of each
    other. The only lever is making the content narrower than the screen.

    The budget is tighter than it looks: 2880x1800 at scale 1.5 is 1920x1200
    logical, so rotated the bar has 1200px, and focusedWindow alone was
    entitled to 456 of them.

    focusedWindowSize is the biggest single win, and its mapping is
    counter-intuitive -- 0 is the SMALLEST (288px), not "off"; the unset
    default of 1 is 456px. (mediaSize uses 0 for hidden, so the two do not
    agree.) compactMode additionally caps the title text at 80px instead of
    180px. Together that reclaims ~250px of the 1200.

    Still not a guarantee. If it overlaps again, the next lever is the centre
    section: oskToggle + music + clock + weather + screenshot is the widest
    group, and weather/clock are the discretionary two.
  */
  focusedWindowSize = 0;
  focusedWindowCompactMode = true;
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
  # greeterEnableFprint / enableFprint are DERIVED in home.nix from the host's
  # own services.fprintd.enable -- they were duplicating a fact, not expressing
  # a preference. Values here are inert; kept so the file still mirrors the
  # runtime schema one-to-one.
  greeterEnableFprint = true;
  greeterEnableU2f = false;
  greeterWallpaperPath = "~/Pictures/Wallpaper.jpg";
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
  notepadLastCustomTransparency = 0.35;
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
  showDock = true;
  dockAutoHide = true;
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
  enableFprint = true;
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
  /*
    TWO BARS, one per screen orientation, swapped at runtime.

    Rotating this panel takes the bar from 1920px to 1200 -- a 37.5% loss --
    and DMS anchors its three sections independently with no width negotiation
    (hLeftSection to the left edge, hCenterSection to horizontalCenter,
    hRightSection to the right, clip: false). Past a certain total the sections
    simply draw on top of each other; nothing elides or reflows.

    720px cannot be recovered by shaving padding, and there is no
    orientation-conditional config: settings.json is a read-only store symlink,
    so nothing can rewrite it live. Two other runtime routes were tried and
    rejected, both measured rather than assumed:

      dms ipc call widget hide <id>   -> WIDGET_HIDE_NOT_SUPPORTED for built-in
                                        widgets; only plugins can be toggled
      dms ipc call settings set barConfigs <json>
                                     -> SETTINGS_SET_FAILURE; only scalar
                                        settings are settable at runtime

    What does work is per-bar visibility: `dms ipc call bar hide id <barId>`
    returns BAR_HIDE_SUCCESS and `bar status id <barId>` reports it. So both
    bars are declared here, in full, and the orientation hook in
    features/hyprland (hyprland-bar-orientation) reveals exactly one.

    compactBar is the main bar with three fields replaced, so every visual
    setting -- transparency, spacing, colours -- stays in one place and cannot
    drift between orientations.
  */
  barConfigs =
    let
      mainBar =
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
          {
            enabled = true;
            id = "oskToggle";
          }
          "music"
          "clock"
          "weather"
          {
            enabled = true;
            id = "screenshot";
          }
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
          {
            enabled = true;
            id = "dankKDEConnect";
          }
          # Stock switcher replaced by features/dms/plugins/workspaces: it draws
          # the index and app icons together (no setting separates them) and
          # floors its pill width at widgetHeight * 0.7, so neither the
          # hold-to-peek numbers nor a genuinely compact strip is reachable here.
          {
            enabled = true;
            id = "pagedWorkspaces";
          }
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
          "cpuUsage"
          "memUsage"
          "notificationButton"
          "controlCenterButton"
          "battery"
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
        spacing = 2;
        squareCorners = false;
        transparency = 0.3;
        visible = true;
        widgetOutlineColor = "primary";
        widgetOutlineEnabled = false;
        widgetOutlineOpacity = 1;
        widgetOutlineThickness = 1;
        /*
          Inner padding, i.e. the gap between a widget's content and its own
          pill edge. Was cut 8 -> 4 while the single bar was fighting for room
          in portrait; the clock came out reading "12:00 · Sat 29" with the
          text hard against both ends.

          The compact bar makes that trim unnecessary: portrait now drops
          widgets instead of squeezing the ones it keeps, so this can go back
          to breathing room. 6 rather than the original 8 -- the strip and the
          paged workspaces are new since then, and 8 costs about 40px across a
          full bar.

          NOTE this is inherited by compactBar through the // , so portrait
          gets the same padding on a shorter widget list. If portrait ever
          overflows again, drop a widget from keepOnly rather than shaving
          this: cramped text was the complaint that got us here.
        */
        widgetPadding = 6;
        widgetTransparency = 0.45;
      };

      /*
        DERIVED FROM mainBar BY FILTERING, never retyped.

        Hand-writing the lists silently reordered them: the main bar ends
        ... notificationButton, controlCenterButton, battery, and the rewrite
        put battery before controlCenterButton. Same widgets, different bar --
        visible immediately on rotation, and exactly the kind of drift a second
        copy of a list invites.

        Filtering keeps each widget's position AND its entry form (plain string
        vs { enabled; id; } attrset), and any future reorder of the main bar
        carries over for free.
      */
      idOf = w: if builtins.isString w then w else w.id;
      keepOnly = ids: builtins.filter (w: builtins.elem (idOf w) ids);

      compactBar = mainBar // {
        id = "compact";
        name = "Compact Bar (portrait)";

        /*
          HIDDEN BY DEFAULT, so landscape is correct with no help.

          Inheriting mainBar's visible = true meant both bars rendered at once
          from session start until dms-bar-orientation got to hide one -- a
          guaranteed race, and the reason two bars showed at startup rather
          than only across a switch.

          Landscape is the resting state, so the bar that needs revealing is
          this one. `dms ipc call bar reveal id compact` overrides this at
          runtime; the setting only decides where things start.
        */
        visible = false;

        /*
          What survives 1200px.

          Portrait on this machine means tablet mode, so the on-screen keyboard
          toggle earns its place. Dropped: focusedWindow on the left, weather in the centre, cpuUsage and memUsage on the right --
          all either duplicated elsewhere or not worth a tap in tablet mode.

          Nothing is lost in landscape: the full bar still exists, it is simply
          not the one being shown.
        */
        leftWidgets = keepOnly [
          "launcherButton"
          "dankKDEConnect"
          "pagedWorkspaces"
        ] mainBar.leftWidgets;
        centerWidgets = keepOnly [ "oskToggle" "music" "clock" "screenshot" ] mainBar.centerWidgets;
        rightWidgets = keepOnly [
          "systemTray"
          "notificationButton"
          "controlCenterButton"
          "battery"
        ] mainBar.rightWidgets;
      };

    in
    [
      mainBar
      compactBar
    ];
  desktopClockEnabled = false;
  desktopClockStyle = "analog";
  desktopClockTransparency = 0.35;
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
  systemMonitorTransparency = 0.4;
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
