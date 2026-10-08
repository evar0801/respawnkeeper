# ============================================================
# panel-model.ps1 - what the control panel KNOWS, with no window attached.
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI; one Japanese character in a
# script file breaks the parser - every Japanese string is in
# panel-strings.ja.json instead).
#
# Dot-sourced by rk-panel.ps1 (the window) and render-preview.ps1 (the offscreen
# renderer). They share this file rather than each holding a copy, because a
# preview that renders different data than the panel is worse than no preview.
#
# Everything here is READ-ONLY with one exception: the servers.json registry
# next to the harness. It never writes into a server folder.
# ============================================================

$script:PanelUiDir      = $PSScriptRoot
$script:PanelHarnessDir = Split-Path -Parent $script:PanelUiDir
$script:PanelRepoDir    = Split-Path -Parent $script:PanelHarnessDir

. (Join-Path $script:PanelHarnessDir 'lib\rk-common.ps1')

$script:PanelRegistryFile = Join-Path $script:PanelRepoDir 'servers.json'

function Write-RkTrace {
  # Startup phases, when RK_TRACE names a file: milliseconds since this PROCESS
  # started (so powershell.exe's own 400 ms is in the number), the phase, the
  # pid. Off unless asked for. This is how "opening it is quite slow" was
  # measured rather than argued about ([R-095]).
  param([string]$What)
  if (-not $env:RK_TRACE) { return }
  try {
    $ms = [int]((Get-Date) - (Get-Process -Id $PID).StartTime).TotalMilliseconds
    Add-Content -LiteralPath $env:RK_TRACE -Value ('{0,7} ms  pid {1}  {2}' -f $ms, $PID, $What) -Encoding ascii
  } catch { }
}

# The panel is ONE window for the whole machine, so unlike the console its
# registration cannot live in a server folder. It sits next to servers.json,
# which is the only other thing here that is about the fleet rather than about
# one server.
function Get-RkPanelLockFile {
  return (Join-Path $script:PanelRepoDir 'panel.lock')
}

function Get-RkPanelScriptPattern {
  # What a live panel's command line looks like. TWO shapes since [R-095]:
  # started by hand or from a .bat it is "powershell ... rk-panel.ps1"; started
  # from respawnkeeper.exe it runs INSIDE rk-entry.ps1's process, whose command
  # line names rk-entry.ps1 and never rk-panel.ps1. A pattern that only knew
  # the first shape made Get-RkUiWindow call the exe-started panel "not a
  # panel", so the console's "back to the list" button would have opened a
  # second one - the exact duplicate the registration exists to prevent.
  return 'rk-panel\.ps1|rk-entry\.ps1'
}

function Initialize-RkWindowApi {
  # Add-Type costs 208ms the first time (measured 2026-09-13), and the first
  # time used to be inside a click handler on the UI thread. Split out so a
  # window can pay it during startup instead.
  #
  # The guard tests the type Add-Type actually creates. -Namespace RkNative
  # -Name Win produces RkNative.Win; the older block further down this file
  # guards on 'RkShell' while creating RkNative.Shell, which never matches and
  # is only harmless because a separate one-shot flag stops it running twice.
  if ('RkNative.Win' -as [type]) { return }
  Add-Type -Namespace RkNative -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
'@ -ErrorAction Stop
}

function Show-RkWindowOf {
  # Bring another process's main window to the front. Returns $false if there
  # was nothing to bring - which is NOT the same as "there is no panel", so the
  # caller must not read a $false here as permission to start a second one.
  #
  # SetForegroundWindow is allowed to refuse: Windows only grants it to a
  # process that already owns the foreground. That is exactly the case here (the
  # operator just clicked a button in our window), which is why this works from
  # a click and would not work from a timer.
  param([Parameter(Mandatory)][int]$Id)
  try {
    Initialize-RkWindowApi
    $p = Get-Process -Id $Id -ErrorAction Stop
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) {
      # A window that exists but has not been shown yet reports 0. Give it one
      # short beat rather than declaring it absent.
      Start-Sleep -Milliseconds 400
      $p.Refresh()
      $h = $p.MainWindowHandle
    }
    if ($h -eq [IntPtr]::Zero) { return $false }
    if ([RkNative.Win]::IsIconic($h)) { [void][RkNative.Win]::ShowWindow($h, 9) }  # SW_RESTORE
    return [RkNative.Win]::SetForegroundWindow($h)
  } catch { return $false }
}

# ---- strings ----------------------------------------------------------------
$script:S = $null
try {
  $script:S = Get-Content -LiteralPath (Join-Path $script:PanelUiDir 'panel-strings.ja.json') -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  throw ('cannot read panel-strings.ja.json: ' + $_.Exception.Message)
}

function T([string]$path) {
  $node = $script:S
  foreach ($part in $path.Split('.')) {
    if ($null -eq $node) { return $path }
    $node = $node.$part
  }
  if ($null -eq $node) { return $path }
  return [string]$node
}

function TF {
  param([string]$path)
  $fmt = T $path
  $rest = @($args)
  for ($i = 0; $i -lt $rest.Count; $i++) { $fmt = $fmt.Replace('{' + $i + '}', [string]$rest[$i]) }
  return $fmt
}

# ---- palette (DESIGN.md dark theme + Forest accent) -------------------------
# Amber is not in DESIGN.md's named set. It is used for exactly one meaning -
# "this still works, but something needs you later" - which neither accent
# (fine) nor danger (broken now) can carry without lying about severity.
$script:Col = @{
  ink       = '#F2F1EE'
  inkMuted  = '#B7B5B0'
  logInk    = '#8FC2CE'
  inkSubtle = '#7D7B76'
  accent    = '#4F9C74'
  danger    = '#D97066'
  amber     = '#C9A227'
  # STANDBY, NOT ABSENCE. "Nothing is running" used to be painted in InkMuted,
  # and InkMuted is a TEXT colour - 19% saturation. On the rail that colour is
  # not read as a state, it is read as the picture having lost its colour: the
  # neon sign over the bed turned grey. Eva's word for it was "colour-drained",
  # and she is right that it is a different complaint from "too dark".
  #
  # So idle gets a hue of its own: the magenta the sign is actually painted in
  # (#BD23B5 in the art), lifted enough to read as lit. It says "the sign is
  # still on, she is just asleep under it" instead of "this panel is broken".
  # 46 degrees of hue from Danger (#FF3D7F), which is the one it must not be
  # confused with - and Danger blinks fast while this one is held. [R-092]
  idle      = '#C93FD6'
}

# ============================================================================
# Themes
#
# panel.xaml holds the LAYOUT. theme-<name>.xaml holds colours, fonts, corner
# radii and border weights, and is spliced in where the <!--THEME--> marker is.
# One layout, N skins (drop a theme-<name>.xaml in and it appears in the cycle):
# a theme that could move things would have to be re-debugged, and layout bugs
# are the ones that actually hurt (the first
# render of this window clipped its own right edge).
#
# Some things a resource dictionary cannot express are still the THEME's to
# decide, so the theme declares them as flags and the loader carries them out:
#
#   AliasedText   TextRenderingMode is a Window-level attached property. Shape
#                 alone does not read as pixels; glyph-edge smoothing is what
#                 gives it away.
#   KeeperOn      whether the keeper's rail is shown at all.
#
# The rule is the same one [R-043] arrived at for the state colours: if the
# loader decides it, then adding a theme means editing the loader, and the
# second theme of a kind quietly gets the first one's behaviour.
# ============================================================================
function Get-RkPanelThemes {
  return @(Get-ChildItem -LiteralPath $script:PanelUiDir -Filter 'theme-*.xaml' -ErrorAction SilentlyContinue |
           ForEach-Object { $_.BaseName -replace '^theme-', '' })
}

function Get-RkNextTheme([string]$Current) {
  # Cycles rather than toggles. With three themes a two-way switch can only ever
  # reach two of them, and the third would be a flag nobody finds.
  $all = @(Get-RkPanelThemes | Sort-Object)
  if ($all.Count -eq 0) { return 'modern' }
  $i = [array]::IndexOf($all, $Current)
  if ($i -lt 0) { return $all[0] }
  return $all[($i + 1) % $all.Count]
}

function Get-RkThemeLabel([string]$Name) {
  $disp = T ('theme.names.' + $Name)
  if ($disp -eq ('theme.names.' + $Name)) { $disp = $Name }   # unnamed theme: show its id
  return (TF 'theme.next' $disp)
}

function New-RkPanelWindow {
  # -XamlFile so the console window gets the same themes as the panel without a
  # second copy of the splice-and-load logic. Every trap below was paid for once
  # already; a second loader would pay for them again.
  param([string]$Theme = 'modern', [string]$XamlFile = 'panel.xaml')

  # THE TASKBAR BUTTON DOES NOT TAKE THE WINDOW'S ICON. It takes the icon of
  # the AppUserModelID the window belongs to, and a process that never sets one
  # inherits an ID derived from its executable - powershell.exe. So the window
  # icon set further down was landing correctly (measured: WM_GETICON on the
  # live window returns a real handle, and the 32x32 bitmap behind it IS
  # respawnkeeper's) while the taskbar went on showing the PowerShell logo.
  #
  # Setting an explicit ID puts these windows in their own group, and the group
  # then draws with the window's own icon. It must happen BEFORE the first
  # window exists, which is why it is the first thing in this function.
  #
  # Wrapped because the API is Windows 7+ and absent on some hosts; an icon is
  # not worth failing to open a window over.
  if (-not $script:RkAppIdSet) {
    $script:RkAppIdSet = $true
    try {
      if (-not ('RkShell' -as [type])) {
        Add-Type -Namespace RkNative -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
public static extern void SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction Stop
      }
      [RkNative.Shell]::SetCurrentProcessExplicitAppUserModelID('Evar.respawnkeeper')
    } catch { }
  }

  $themeFile = Join-Path $script:PanelUiDir ('theme-' + $Theme + '.xaml')
  if (-not (Test-Path -LiteralPath $themeFile)) {
    Write-Host ('[panel] no such theme: ' + $Theme + ' - falling back to modern')
    $Theme = 'modern'
    $themeFile = Join-Path $script:PanelUiDir 'theme-modern.xaml'
  }

  $xaml  = [System.IO.File]::ReadAllText((Join-Path $script:PanelUiDir $XamlFile), [System.Text.Encoding]::UTF8)
  $theme = [System.IO.File]::ReadAllText($themeFile, [System.Text.Encoding]::UTF8)

  # The theme file opens with an explanatory comment; drop exactly THAT one and
  # keep everything after it.
  #
  # LastIndexOf('-->') is wrong and was the first thing tried: a theme with
  # inline comments further down (theme-pixel has two) gets cut at the last one,
  # silently discarding every resource above it. The failure surfaced as
  # "Cannot find resource named 'Body'" - a message that points nowhere near
  # the actual mistake.
  if ($theme.TrimStart().StartsWith('<!--')) {
    $cut = $theme.IndexOf('-->')
    if ($cut -ge 0) { $theme = $theme.Substring($cut + 3) }
  }

  if ($xaml.IndexOf('<!--THEME-->') -lt 0) { throw ($XamlFile + ' has no <!--THEME--> marker') }
  $xaml = $xaml.Replace('<!--THEME-->', $theme)

  $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
  $win = [Windows.Markup.XamlReader]::Load($reader)

  # Aliased + Display: glyph edges land on whole pixels instead of being
  # smoothed across them. This is the single change that makes a skin read as
  # pixels rather than as "square corners".
  #
  # It used to be `if ($Theme -eq 'pixel')`. That is the same structural hole
  # [R-043] found in the state colours: the loader, not the theme, was deciding
  # something about how the theme looks, so the SECOND pixel-grid theme silently
  # rendered with smoothed text and nobody could see why it looked wrong. The
  # theme declares it now; the loader only obeys.
  if (Get-RkThemeFlag $win 'AliasedText') {
    [System.Windows.Media.TextOptions]::SetTextRenderingMode($win, [System.Windows.Media.TextRenderingMode]::Aliased)
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($win, [System.Windows.Media.TextFormattingMode]::Display)
  }

  # The keeper's rail is part of the shared layout - a theme may not move it -
  # but a theme may decline it. modern/pixel/cyber are readouts; eve is the one
  # that has someone standing in it.
  $rail = $win.FindName('KeeperRail')
  if ($rail) {
    if (Get-RkThemeFlag $win 'KeeperOn') {
      $rail.Visibility = 'Visible'
      # She needs her own room. Without this the rail takes 224px out of the
      # cards, and the cost lands on the notices - the longest lines in the
      # window and the ones a person opened it to read. The window is the thing
      # that grew a column, so the window is what widens.
      $win.Width    = $win.Width + 344
      $win.MinWidth = $win.MinWidth + 344
    } else {
      $rail.Visibility = 'Collapsed'
    }
  }

  # The city needs sky to stand in. Without this the skyline is drawn into the
  # 20px gap between the banner and the first card, which is not a city, it is a
  # texture - and the whole argument for putting one there was that the towers
  # are readable. The window grew a band, so the window is what grows, exactly
  # as it does for the keeper's column.
  $header = $win.FindName('HeaderBand')
  if ($header -and (Get-RkThemeFlag $win 'CityOn')) {
    $header.MinHeight = 208
    $win.Height    = $win.Height + 170
    $win.MinHeight = $win.MinHeight + 170

    # Her bay is opaque in every other theme because it is a panel. With a city
    # behind it, an opaque bay cuts a rectangular hole in the skyline and she
    # ends up standing in a box next to a city rather than in one. Dropping the
    # fill to about 80% keeps her line legible - the thing the bay is FOR -
    # while the towers carry on behind her.
    if ($rail -and $rail.Visibility -eq 'Visible') {
      $c = [System.Windows.Media.ColorConverter]::ConvertFromString('#0C1524')
      $c.A = 208
      $rail.Background = New-Object System.Windows.Media.SolidColorBrush $c
    }
  }

  # The ground comes from the theme, not from a hardcoded attribute on Window.
  # A theme may hand back a DrawingBrush here rather than a colour - which is how
  # the cyber theme gets its scanlines without a single image file.
  $ground = $win.TryFindResource('Canvas')
  if ($ground) { $win.Background = $ground }

  # State and notice colours were hardcoded in $script:Col, so a theme could
  # restyle the whole window and the one thing that carries MEANING - green for
  # up, red for down, amber for "later" - stayed the old palette. They are read
  # back out of the loaded theme instead.
  Set-RkPanelPalette -Window $win
  # The taskbar button, the title bar and Alt-Tab all take their picture from
  # the Window. With none set WPF draws the generic PowerShell host icon, so the
  # panel and the console looked like two stray scripts sitting next to the exe
  # rather than three faces of one program. Same .ico the launcher is built
  # with, by design - one mark for all of them.
  $ico = Join-Path (Split-Path -Parent $script:PanelUiDir) 'launcher\respawnkeeper.ico'
  if (Test-Path -LiteralPath $ico) {
    # Never fatal: a window with the wrong icon is a cosmetic fault, and a
    # window that refused to open over one would be a real one.
    # BitmapFrame::Create on a multi-size .ico returns the FIRST frame, which is
    # the 16x16 - and the taskbar draws at 32 or more, so that ships a blurry
    # upscale. This .ico carries 16/32/48/256; the largest is picked and WPF
    # scales DOWN, which is the direction that stays sharp.
    try {
      $dec = New-Object System.Windows.Media.Imaging.IconBitmapDecoder(
               [uri]$ico,
               [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
               [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
      $win.Icon = ($dec.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1)
    } catch {
      try { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([uri]$ico) } catch { }
    }
  }

  return $win
}

function Get-RkThemeColors {
  # The state colours of a theme WITHOUT building a window: the theme file is a
  # fragment of resources spliced into panel.xaml at <!--THEME-->, so wrap it in
  # a ResourceDictionary with the same three namespaces and let the XAML reader
  # resolve it. For tools that draw the stage on their own (render-stage.ps1),
  # which used to carry a hand-copied table of eve's values and therefore
  # previewed every other theme in the wrong colours ([R-091] U20).
  # Returns @{ accent; amber; danger; idle; inkSubtle } as '#AARRGGBB' strings,
  # or $null if the theme cannot be read.
  param([Parameter(Mandatory)][string]$Theme)
  $themeFile = Join-Path $script:PanelUiDir ('theme-' + $Theme + '.xaml')
  if (-not (Test-Path -LiteralPath $themeFile)) { return $null }
  try {
    $theme = [System.IO.File]::ReadAllText($themeFile, [System.Text.Encoding]::UTF8)
    if ($theme.TrimStart().StartsWith('<!--')) {
      $cut = $theme.IndexOf('-->')
      if ($cut -ge 0) { $theme = $theme.Substring($cut + 3) }
    }
    $xaml = '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" ' +
            'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" ' +
            'xmlns:sys="clr-namespace:System;assembly=mscorlib">' + $theme + '</ResourceDictionary>'
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $dict = [Windows.Markup.XamlReader]::Load($reader)
    $out = @{}
    foreach ($pair in @(
        @{ key = 'Accent';     field = 'accent' },
        @{ key = 'Amber';      field = 'amber' },
        @{ key = 'Danger';     field = 'danger' },
        @{ key = 'KeeperIdle'; field = 'idle' },
        @{ key = 'InkSubtle';  field = 'inkSubtle' })) {
      $b = $null
      if ($dict.Contains($pair.key)) { $b = $dict[$pair.key] }
      if ($b -and $b.Color) { $out[$pair.field] = $b.Color.ToString() }
    }
    return $out
  } catch { return $null }
}

function Get-RkThemeFlag {
  # A theme that says nothing means no. Missing is not the same as false to a
  # reader, but it has to be the same to the loader, or dropping in a new
  # theme-<name>.xaml would fail with a null reference instead of just looking
  # plain - and "drop a file in" is the whole contract of the theme mechanism.
  param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)][string]$Key)
  $v = $Window.TryFindResource($Key)
  if ($null -eq $v) { return $false }
  return [bool]$v
}

function Set-RkPanelPalette {
  param([Parameter(Mandatory)]$Window)
  foreach ($pair in @(
      @{ key = 'Accent';    field = 'accent' },
      @{ key = 'Danger';    field = 'danger' },
      @{ key = 'Amber';     field = 'amber' },
      @{ key = 'Ink';       field = 'ink' },
      @{ key = 'InkMuted';  field = 'inkMuted' },
      @{ key = 'InkSubtle'; field = 'inkSubtle' },
      # A theme that says nothing keeps the default magenta. Declaring
      # KeeperIdle is how a theme whose own palette fights magenta (modern's
      # accent is a green) says so, instead of every theme inheriting one hue
      # chosen for eve.
      #
      # Only eve DRAWS it today: cyber, modern and pixel all declare
      # KeeperOn=False, so their rail - and this colour with it - is collapsed
      # (measured: rail ActualWidth 0 for those three, 320 for eve). They are
      # declared anyway, and checked for contrast anyway, because the day
      # somebody flips KeeperOn is not the day to discover the value was never
      # looked at.
      @{ key = 'KeeperIdle'; field = 'idle' },
      @{ key = 'LogInk';    field = 'logInk' })) {
    $b = $Window.TryFindResource($pair.key)
    if ($b -and $b.Color) { $script:Col[$pair.field] = $b.Color.ToString() }
  }
}

# ============================================================================
# Which servers are there?
#
# Two sources, unioned: a registry this panel maintains, and a wildcard sweep of
# the two places servers actually live in this project. Fixed wildcard depths,
# not -Recurse: recursing the mod workspace walks 167 mod folders and a world, and a
# control panel that takes six seconds to open is one nobody opens.
# ============================================================================
function Get-RkPanelSearchPatterns {
  # WHERE TO SWEEP IS DATA, NOT GEOMETRY ([R-103]). Until 2026-09-22 the two
  # roots were derived as "my parent" and "my grandparent" - true only while
  # this harness sat in the mod workspace. Moving it one level up aimed
  # the sweep at C:\ and dropped fc8 off the panel, silently: a sweep that
  # finds nothing looks exactly like a machine with no new servers. A harness
  # that cannot be moved has a game baked into it, which [R-019] says it must
  # not. The roots now live in servers.json beside the server list, because
  # "which servers are there" is one question, not two.
  #
  # NO FALLBACK TO THE OLD DERIVATION ON PURPOSE. With no scanRoots the sweep
  # returns nothing and the registry alone draws the cards - every server that
  # was set up is in there ([R-091] keeps it that way). Losing auto-discovery
  # of a NEW folder is a card that shows up late; guessing a root is a walk of
  # someone else's disk.
  $reg = Read-RkJson -Path $script:PanelRegistryFile
  if (-not ($reg -and $reg.scanRoots)) { return @() }

  $patterns = New-Object System.Collections.Generic.List[string]
  foreach ($r in @($reg.scanRoots)) {
    if (-not $r) { continue }
    $root = [string]$r.path
    if (-not $root) { continue }
    # depth = how many folder levels below the root a server may sit, and it is
    # PER ROOT because each level is another wildcard walk: the mod workspace at depth 4
    # walks 167 mod folders and a world on every sweep, while the live-server folder
    # genuinely needs 4 (loader\version\pack\instance).
    $depth = 1
    if ($null -ne $r.depth) { try { $depth = [int]$r.depth } catch { $depth = 1 } }
    if ($depth -lt 0) { $depth = 0 }
    if ($depth -gt 6) { $depth = 6 }   # a typo in the file must not become a walk of the whole drive
    for ($i = 0; $i -le $depth; $i++) {
      $mid = ''
      for ($j = 0; $j -lt $i; $j++) { $mid += '*\' }
      [void]$patterns.Add((Join-Path $root ($mid + 'respawnkeeper\profile.json')))
    }
  }
  return $patterns.ToArray()
}

function Get-RkKnownServers {
  param([switch]$Force, [switch]$NoSweep)

  # THE SWEEP IS NOT FREE AND IT IS NOT URGENT. Measured 2026-09-13: 779 ms for
  # the five wildcard patterns below, paid on every four second refresh - to
  # answer a question ("has a new server folder appeared?") whose answer changes
  # about once a month. [R-091]
  #
  # ONLY THE WILDCARD WALK IS CACHED. The registry file is read on EVERY call,
  # because it is the one thing another process edits while the panel is open:
  # rk-console's uninstall rewrites servers.json to drop a server it has just
  # moved out ([R-057]). The first version of this cache returned before that
  # read, which left a card offering a start button for a server whose
  # rk-start.bat had been moved away, for up to twenty-five seconds - while the
  # comment directly above it claimed the registry read was the fresh part.
  #
  # $script:SweepDone rather than testing $script:SweepFound: an empty array is
  # falsy in PowerShell, so a machine with no servers yet - the first-run
  # screen - would have paid the 779 ms walk on every single refresh.
  $found = New-Object System.Collections.Generic.List[string]
  # -NoSweep only means something when the registry has servers to draw from.
  # A fresh install (no servers.json, or an empty one) would otherwise open on
  # "no servers yet - add one" for four seconds while servers sat on disk
  # (review of [R-095]); there the walk is the first read.
  if ($NoSweep -and (-not $Force) -and (-not $script:SweepDone)) {
    $regPeek = Read-RkJson -Path $script:PanelRegistryFile
    if (-not ($regPeek -and (@($regPeek.servers | Where-Object { $_ }).Count -gt 0))) { $NoSweep = $false }
  }
  if ($NoSweep -and (-not $Force) -and (-not $script:SweepDone)) {
    # THE FIRST READ AFTER THE WINDOW OPENS. The walk costs about a second and
    # the registry already names every server that was here last time (25 ms),
    # so the first cards are drawn from the registry and the walk is paid on
    # the second refresh, four seconds later - when a person is already
    # looking at their servers instead of at an empty window. SweepDone stays
    # false, so nothing below mistakes this for a walk that happened.
  } elseif ((-not $Force) -and $script:SweepDone -and $script:SweepAt -and
      (((Get-Date) - $script:SweepAt).TotalSeconds -lt 20)) {
    # Re-checked, not trusted: the walk is what costs 779 ms, but confirming
    # that a handful of already-known folders are still set up is three
    # Test-Path calls. Without this, a server torn down by the console (or by
    # hand in Explorer) keeps its card - and its start button - for the rest of
    # the cache window.
    foreach ($d in @($script:SweepFound)) {
      if ((Test-Path -LiteralPath (Join-Path $d 'respawnkeeper\profile.json')) -and (-not $found.Contains($d))) {
        [void]$found.Add($d)
      }
    }
  } else {
    foreach ($pattern in (Get-RkPanelSearchPatterns)) {
      foreach ($f in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) {
        $dir = Split-Path -Parent (Split-Path -Parent $f.FullName)
        if (-not $found.Contains($dir)) { [void]$found.Add($dir) }
      }
    }
    $script:SweepAt    = Get-Date
    $script:SweepDone  = $true
    $script:SweepFound = @($found)
  }

  # Anything registered by hand that the sweep cannot reach (a server kept
  # somewhere else entirely).
  #
  # !! A REGISTERED SERVER IS NEVER FORGOTTEN BY THIS FUNCTION. It used to be:
  # an entry whose profile.json failed ONE Test-Path - a disconnected drive, a
  # folder mid-rename, a transient share error - was left out of $found, and
  # $found was then written back as the whole registry. So one bad read
  # deleted a hand-registered server from the only place that knew about it,
  # with no .bak ([R-091] W8). Now an entry that cannot be confirmed is
  # SKIPPED for this refresh (no card) but KEPT in the file. The registry only
  # ever grows here; the one thing that shrinks it is the console's uninstall,
  # which is a person pressing a button that says so.
  $reg = Read-RkJson -Path $script:PanelRegistryFile
  $registered = New-Object System.Collections.Generic.List[string]
  if ($reg -and $reg.servers) {
    foreach ($p in @($reg.servers)) {
      $d = [string]$p
      if (-not $d) { continue }
      if (-not $registered.Contains($d)) { [void]$registered.Add($d) }
      if ((Test-Path -LiteralPath (Join-Path $d 'respawnkeeper\profile.json')) -and (-not $found.Contains($d))) {
        [void]$found.Add($d)
      }
    }
  }
  # What goes back to disk: everything that was there, plus what the walk
  # found that was not. Order is the registry's own, new finds appended.
  $toWrite = New-Object System.Collections.Generic.List[string]
  foreach ($d in $registered) { [void]$toWrite.Add($d) }
  foreach ($d in $found) { if (-not $toWrite.Contains($d)) { [void]$toWrite.Add($d) } }

  # WRITE ONLY WHEN THE LIST ACTUALLY CHANGED. This ran every four seconds and
  # rewrote servers.json every time with the same three paths and a new
  # timestamp - a truncate-then-write (Write-RkJson has no retry) against the
  # one file every panel and every console reads to find its servers. Nothing
  # was observed to break, but paying that lottery ticket 900 times an hour to
  # record "still the same three" is not a trade worth making.
  $prevList = @()
  if ($reg -and $reg.servers) { $prevList = @($reg.servers | ForEach-Object { [string]$_ }) }
  # Ordinal, to match List[string].Contains above. PowerShell's -ne on strings
  # ignores case, so a registry entry differing from the swept path only in case
  # would be added as a SECOND entry by Contains and then judged "unchanged"
  # here - two cards for one server, frozen that way because the file is never
  # rewritten to correct it.
  $changed = ($prevList.Count -ne $toWrite.Count)
  if (-not $changed) {
    for ($i = 0; $i -lt $toWrite.Count; $i++) {
      if (-not [string]::Equals($prevList[$i], $toWrite[$i], [System.StringComparison]::Ordinal)) { $changed = $true; break }
    }
  }
  if ($changed) {
    try {
      # A copy of the last version beside it, and an atomic swap (Write-RkJson):
      # the file every window reads to find its servers is never seen empty.
      if (Test-Path -LiteralPath $script:PanelRegistryFile) {
        Copy-Item -LiteralPath $script:PanelRegistryFile -Destination ($script:PanelRegistryFile + '.bak') -Force -ErrorAction SilentlyContinue
      }
      # scanRoots is CARRIED OVER, not rebuilt. This rewrite is triggered by a
      # change to the server list, and the object below is built from scratch -
      # so every field this function does not name is dropped. Leaving it out
      # turned the panel's own sweep off the first time a server was added.
      $out = [ordered]@{
        schema  = 'respawnkeeper/servers/1'
        updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        servers = @($toWrite)
      }
      if ($reg -and $reg.scanRoots) { $out['scanRoots'] = @($reg.scanRoots) }
      Write-RkJson -Path $script:PanelRegistryFile -Object $out
    } catch {}
  }

  return @($found)
}

# ---- why the catches are not empty -------------------------------------------
# Two bugs shipped in the first version of this file and BOTH were invisible:
# Get-RkServerLiveness was called with a parameter it does not have, and
# Get-RkGameMatch was called instead of Find-RkGame. Each threw, each was
# swallowed by an empty catch, and the panel calmly rendered "unknown" and no
# mod count as though that were the truth.
#
# The window must never crash because one server folder is odd, so the catches
# stay - but they now record. -Once turns that into output, which is how both
# bugs were finally seen.
$script:PanelErrors = New-Object System.Collections.ArrayList
function Trap-PanelError($err) {
  [void]$script:PanelErrors.Add([string]$err)
}

# ============================================================================
# One server -> one card's worth of facts. Pure reading.
# ============================================================================
# Level, not colour, is what severity MEANS. The brush is how it looks; two
# themes are free to paint two levels the same and neither is wrong. The keeper
# reads Level, so "broken" and "needed later" cannot collapse into one pose
# because a palette happened to reuse a hex.
#   danger = down now   care = works, but you are needed later   info = FYI
function New-RkNotice([string]$text, [string]$brush, [string]$level = 'info') {
  return [pscustomobject]@{ Text = $text; Brush = $brush; Level = $level }
}

function Get-RkPanelRow {
  param([Parameter(Mandatory)][string]$ServerDir)

  $stateDir = Join-Path $ServerDir 'respawnkeeper'
  $prof = Read-RkJson -Path (Join-Path $stateDir 'profile.json')
  $st   = Read-RkJson -Path (Join-Path $stateDir 'state.json')

  $label = Split-Path -Leaf $ServerDir
  if ($prof -and $prof.serverLabel) { $label = [string]$prof.serverLabel }

  # Get-RkServerLiveness takes -Loader/-Template (NOT -StateDir) and reports
  # .alive (NOT .running). Calling it wrong is silent: the try/catch swallows
  # the parameter error and every server renders as "unknown", which is exactly
  # what the first version of this panel did against both real servers.
  # Resolved ONCE. The mod-count block further down used to call Find-RkGame a
  # second time for the same folder (measured 22-139 ms each), which is a
  # different kind of wrong from being slow: two calls are two chances to
  # disagree about what game this is.
  $game = $null
  try { $game = Find-RkGame -ServerDir $ServerDir } catch { Trap-PanelError $_ }

  $running = $false
  try {
    $live = Get-RkServerLiveness -ServerDir $ServerDir -Template $game
    if ($live -and $live.alive) { $running = $true }
  } catch { Trap-PanelError $_ }

  $intent = ''
  if ($st -and $st.intent) { $intent = [string]$st.intent }
  $stName = ''
  if ($st -and $st.state) { $stName = [string]$st.state }

  # Is anybody WATCHING this folder? A running server with no supervisor is a
  # server the panel cannot stop: the stop and restart buttons write a flag that
  # only a supervisor reads. Saying so beats a button that does nothing.
  $sup = @{ alive = $false; pid = 0; reason = '' }
  try { $sup = Get-RkSupervisor -ServerDir $ServerDir } catch { Trap-PanelError $_ }
  $pending = @()
  try { $pending = @(Get-RkPendingSignals -ServerDir $ServerDir) } catch { Trap-PanelError $_ }

  # What the supervisor is in the middle of, if anything. Read off state.json
  # (the supervisor commits STOPPING / MAINT_PENDING / ANALYZING / RESTARTING
  # as it goes) and off the flag files (a request it has not picked up yet).
  # Only trusted while the supervisor is alive: a stale RESTARTING from a
  # supervisor that was killed mid-lap is history, not a promise.
  $busy = ''
  if ($sup.alive) {
    if ($pending -contains 'stop')             { $busy = T 'busy.stopRequested' }
    elseif ($pending -contains 'maintenance')  { $busy = T 'busy.restartRequested' }
    elseif ($running) {
      switch ($stName) {
        'STOPPING'      { $busy = T 'busy.stopping' }
        'MAINT_PENDING' { $busy = T 'busy.maintPending' }
      }
    } else {
      switch ($stName) {
        'ANALYZING'  { $busy = T 'busy.analyzing' }
        'RESTARTING' { $busy = T 'busy.restarting' }
        'DIAGNOSING' { $busy = T 'busy.diagnosing' }
        'ESCALATING' { $busy = T 'busy.diagnosing' }
      }
    }
  }

  # What is true NOW, not what the last run wrote. A stale HALTED sitting next
  # to a live java process would be a lie on the one screen whose whole job is
  # answering "is it up".
  #
  # No state.json at all means respawnkeeper has never supervised this server -
  # a real, distinct answer. Showing "unknown" there implies something went
  # wrong when nothing has happened yet.
  $stateText = T 'state.never'
  $stateCol  = $script:Col.inkSubtle
  $dotCol    = $script:Col.inkSubtle
  if ($busy) {
    $stateText = $busy;             $stateCol = $script:Col.amber;    $dotCol = $script:Col.amber
  } elseif ($running) {
    $stateText = T 'state.running'; $stateCol = $script:Col.accent;   $dotCol = $script:Col.accent
  } elseif ($intent -eq 'HALTED') {
    $stateText = T 'state.halted';  $stateCol = $script:Col.danger;   $dotCol = $script:Col.danger
  } elseif ($st) {
    $stateText = T 'state.stopped'; $stateCol = $script:Col.inkMuted; $dotCol = $script:Col.inkSubtle
  }

  # The city draws towers from the NUMBERS, not from the formatted strings. A
  # skyline parsed back out of "2h14m" and the localised mod line would be one
  # locale change away from a city that silently flattens - so the row carries
  # both: text for the card, values for the drawing.
  $uptime = ''
  $uptimeMin = 0
  $modCount = 0
  $dailyOn = $false
  if ($running -and $st -and $st.serverStartUtc) {
    try {
      $mins = ((Get-Date).ToUniversalTime() - [datetime]$st.serverStartUtc).TotalMinutes
      if ($mins -ge 0) {
        $uptimeMin = [int]$mins
        if ($mins -lt 60) { $uptime = ('{0}m' -f [int]$mins) }
        else { $uptime = ('{0}h{1:00}m' -f [int]($mins / 60), [int]($mins % 60)) }
      }
    } catch {}
  }

  # ---- the policy line ----
  $bits = New-Object System.Collections.Generic.List[string]
  if ($prof) {
    switch ([string]$prof.profile) {
      'unattended' { [void]$bits.Add((T 'meta.policyUnattended')) }
      'watch'      { [void]$bits.Add((T 'meta.policyWatch')) }
      'manual'     { [void]$bits.Add((T 'meta.policyManual')) }
      default      { if ($prof.profile) { [void]$bits.Add([string]$prof.profile) } }
    }
    if ($prof.dailyMaintenance -and $prof.dailyMaintenance.enabled) {
      $dailyOn = $true
      [void]$bits.Add((TF 'meta.dailyOn' $prof.dailyMaintenance.at))
    } else {
      [void]$bits.Add((T 'meta.dailyOff'))
    }
    if ($prof.loader) { [void]$bits.Add((TF 'meta.loader' $prof.loader $prof.javaMajor)) }
  } else {
    [void]$bits.Add((T 'meta.noProfile'))
  }
  # Ask Get-RkModIndex rather than reading modgraph.json directly: the cache has
  # no leaf count in it, and inventing a second way to derive one is how the
  # panel ends up disagreeing with -CheckOnly about the same mods folder. (The
  # first version read .total and .leafCount, neither of which exists, so the
  # mod line silently vanished.) It is cached, so this is a file read.
  try {
    if ($game -and $game.paths.modsDir) {
      $mi = Get-RkModIndex -ServerDir $ServerDir -Template $game
      if ($mi -and $mi.available) {
        $leafCount = 0
        foreach ($k in $mi.mods.Keys) { if (-not $mi.dependents.ContainsKey($k)) { $leafCount++ } }
        $modCount = [int]$mi.scanned
        [void]$bits.Add((TF 'meta.modsGraph' $mi.scanned $leafCount))
      }
    }
  } catch { Trap-PanelError $_ }

  # ---- notices: the things worth interrupting a person for ----
  $notices = New-Object System.Collections.ArrayList

  if ((-not $running) -and ($intent -eq 'HALTED')) {
    [void]$notices.Add((New-RkNotice (T 'notice.halted') $script:Col.danger 'danger'))
  }
  if ($running -and (-not $sup.alive)) {
    [void]$notices.Add((New-RkNotice (T 'notice.unsupervised') $script:Col.amber 'care'))
  }

  try {
    $legacy = Get-RkLegacyWatchdog -ServerDir $ServerDir
    if ($legacy -and $legacy.taskArmed) {
      [void]$notices.Add((New-RkNotice (T 'notice.legacyWatchdog') $script:Col.danger 'danger'))
    }
  } catch { Trap-PanelError $_ }

  # MODEL: is written by the supervisor at every start. Shown only where a
  # profile actually arms escalation, so this never nags about a model that
  # server was never going to use.
  if ($prof -and $prof.escalationHook -and $prof.escalateOnHalt) {
    $statusTxt = ''
    try { $statusTxt = Get-Content -LiteralPath (Join-Path $stateDir 'STATUS.txt') -Raw -ErrorAction Stop } catch {}
    if ($statusTxt -match 'MODEL:\s*NOT READY\s*-\s*(.+)') {
      [void]$notices.Add((New-RkNotice (TF 'notice.modelNotReady' $Matches[1].Trim()) $script:Col.amber 'care'))
    }
  }

  # Today's report and the comeback homework. Both were written to be read, and
  # both were invisible until this window existed.
  $reportDir = Join-Path $stateDir 'reports'
  $todayRep = $null
  $reports = @(Get-ChildItem -LiteralPath $reportDir -Filter 'daily-*.md' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
  if ($reports.Count -gt 0) {
    $todayRep = $reports[0]
    if ($todayRep.LastWriteTime.Date -eq (Get-Date).Date) {
      [void]$notices.Add((New-RkNotice (T 'notice.newReport') $script:Col.accent 'info'))
    }
  }
  $comebacks = @(Get-ChildItem -LiteralPath $reportDir -Filter 'comeback-*.md' -ErrorAction SilentlyContinue)
  if ($comebacks.Count -gt 0) {
    [void]$notices.Add((New-RkNotice (TF 'notice.comeback' $comebacks.Count) $script:Col.amber 'care'))
  }

  return [pscustomobject]@{
    Label       = $label
    ServerDir   = $ServerDir
    StateText   = $stateText
    StateBrush  = $stateCol
    DotBrush    = $dotCol
    Uptime      = $uptime
    UptimeMinutes = $uptimeMin
    ModCount    = $modCount
    DailyOn     = $dailyOn
    Meta        = ($bits -join (T 'meta.separator'))
    Notices     = $notices
    # Start is a double-click on rk-start.bat; stop and restart are flags that
    # need a supervisor to read them. While it is mid-lap (busy) both are held
    # back: a second stop on top of a stop in progress is not a stronger stop.
    # THE PLAIN FACT, published separately from what can be DONE about it.
    #
    # Four places were asking CanStop when what they meant was "is the server
    # up": the console's uninstall screen (its warning row, its confirm button
    # and the uninstall itself), the panel's quarantine-restore gate, and the
    # keeper's pose. CanStop is ($running -and $sup.alive -and -not $busy), so
    # all four read a RUNNING server as stopped as soon as the supervisor was
    # gone - and a supervisor can leave with the server still up (it stands
    # down rather than kill: see respawnkeeper.ps1 'Sent "stop" but the server
    # has not exited'). The uninstall one is the sharp end: it would move
    # respawnkeeper out of a live server folder with its "the server is
    # running" warning hidden.
    Running     = [bool]$running
    Supervised  = [bool]$sup.alive
    SupervisorPid = [int]$sup.pid
    Busy        = $busy
    Pending     = @($pending)
    CanStart    = ((-not $running) -and (-not $sup.alive))
    CanStop     = ($running -and $sup.alive -and (-not $busy))
    CanRestart  = ($running -and $sup.alive -and (-not $busy))
    HasReport   = ($null -ne $todayRep)
    ReportPath  = $(if ($todayRep) { $todayRep.FullName } else { '' })
    ReportLabel = $(if ($todayRep) { T 'button.report' } else { T 'button.noReport' })
  }
}

# ============================================================================
# ONE REFRESH, WITH NO WINDOW ATTACHED  ([R-091])
#
# Everything the panel reads off the disk, and nothing it draws. It exists so
# the same reading can happen on a background thread as happens on the UI
# thread - if the window had its own copy of this loop, the threaded one would
# be the one that quietly drifted.
# ============================================================================
function Get-RkPanelColorTable {
  $c = @{}
  foreach ($k in @($script:Col.Keys)) { $c[$k] = [string]$script:Col[$k] }
  return $c
}

function Set-RkPanelColorTable {
  # THE THEME LIVES ON THE WINDOW, AND A WINDOW CANNOT CROSS A THREAD.
  # Set-RkPanelPalette reads brushes off the Window object, so a gather running
  # in another runspace has no way to reach them and would build every card out
  # of the built-in defaults - cards in one palette inside a window wearing
  # another. The colours are therefore handed over explicitly.
  param([Parameter(Mandatory)][hashtable]$Colors)
  foreach ($k in @($Colors.Keys)) { $script:Col[$k] = [string]$Colors[$k] }
}

function Get-RkPanelData {
  param([switch]$ForceSweep, [switch]$NoSweep)

  # STAMPED AT THE START, NOT THE END. This is what the footer shows as "last
  # updated", and the honest answer to that is the age of the OLDEST fact on
  # screen - which is read first. Stamping at the end (or, worse, at the moment
  # the window applies the result) claims the data is a whole gather fresher
  # than it is: 1.3 s normally, 3.8 s on a cycle that also re-walks the disk.
  $startedAt = Get-Date

  # Per refresh, not cumulative: these are "what went wrong reading the disk
  # just now", and a list that only ever grows cannot answer that.
  $script:PanelErrors.Clear()

  $rows = New-Object System.Collections.ArrayList
  foreach ($d in @(Get-RkKnownServers -Force:$ForceSweep -NoSweep:$NoSweep)) {
    try { [void]$rows.Add((Get-RkPanelRow -ServerDir $d)) } catch { Trap-PanelError $_ }
  }
  $signedOut = $false
  $claudeReady = $false
  try {
    $cs = Get-RkClaudeState
    $signedOut   = ($cs.present -and (-not $cs.signedIn))
    $claudeReady = ($cs.present -and $cs.signedIn)
  } catch { Trap-PanelError $_ }

  return [pscustomobject]@{
    Rows      = $rows
    SignedOut = $signedOut
    # NOT the negation of SignedOut. SignedOut is "the CLI is here and logged
    # out" - it stays false when there is no CLI at all, because a banner
    # telling somebody to sign in a program they do not have is noise. The
    # footer button needs the other question ("can the model be reached?"),
    # and answering it with -not SignedOut would have offered to register an
    # API key on a machine with no claude command.
    ClaudeReady = $claudeReady
    Errors    = @($script:PanelErrors)
    At        = $startedAt
  }
}

function Get-RkRelabeledProfileText {
  # The whole of the rename, as a string -> string function, so it can be tested
  # without a window. @{ ok; text; reason }
  #
  # A SURGICAL EDIT, NOT A ROUND TRIP. Reading profile.json into an object and
  # writing it back re-encodes every Japanese string in it - warnMessage among
  # them - into \uXXXX escapes: still valid JSON, still read correctly by the
  # harness, and no longer a file the operator can read. One line changes.
  param(
    [Parameter(Mandatory)][string]$Raw,
    [Parameter(Mandatory)][string]$Label
  )
  $out = @{ ok = $false; text = ''; reason = '' }

  # JSON string escaping by hand, so the value stays readable UTF-8 in the file
  # instead of \uXXXX. Backslash FIRST - escaping the quotes first would then
  # have its own backslashes escaped again.
  $esc = $Label.Replace('\', '\\').Replace('"', '\"')
  # !! AND THEN AGAIN FOR THE REGEX ENGINE. $esc is handed to [regex]::Replace
  # as the REPLACEMENT string, where $1 $& $0 $+ $_ ${1} are substitution
  # tokens, not text. Measured 2026-09-13: a label of "a$_b" pulled the ENTIRE
  # FILE into the value, "a$&b" re-inserted the matched line, "a$1b" inserted
  # the captured indentation. Every one of those was caught by the parse and
  # value checks below and never reached disk - so this is not a corruption
  # bug, it is twelve perfectly ordinary names that could not be used and
  # reported "failed: parse", which points the reader at the file instead of at
  # what they typed.
  $repl = $esc.Replace('$', '$$')

  # (?:[^"\\]|\\.)* rather than [^"]*: a label that already contains an escaped
  # quote would end the match early and the replacement would cut the file.
  $pat = '(?m)^(\s*"serverLabel"\s*:\s*)"(?:[^"\\]|\\.)*"'
  $n = ([regex]$pat).Matches($Raw).Count
  if ($n -eq 1) {
    $out.text = ([regex]$pat).Replace($Raw, ('${1}"' + $repl + '"'), 1)
  } elseif ($n -eq 0) {
    # A profile written before serverLabel existed. Add it next to "profile",
    # copying that line's own indentation so the file still reads as one file.
    $anchor = '(?m)^(\s*)"profile"(\s*:\s*)"[^"]*",'
    if (([regex]$anchor).Matches($Raw).Count -ne 1) {
      # Name the anchor that failed, not the key we were looking for: "no
      # serverLabel" sends the reader hunting for a line that is legitimately
      # absent, when what actually went wrong is the "profile" line.
      $out.reason = 'no "profile", line to insert after'
      return $out
    }
    $out.text = ([regex]$anchor).Replace($Raw, ('$0' + "`r`n" + '${1}"serverLabel"${2}"' + $repl + '",'), 1)
  } else {
    $out.reason = 'serverLabel x' + $n
    return $out
  }

  # Prove it is still JSON, and still says what we meant, BEFORE it goes to disk.
  $check = $null
  try { $check = ($out.text | ConvertFrom-Json) } catch { $check = $null }
  if (-not $check) { $out.reason = 'the result is not JSON'; $out.text = ''; return $out }
  if ([string]$check.serverLabel -ne $Label) {
    $out.reason = 'the result does not say what was typed'
    $out.text = ''
    return $out
  }
  $out.ok = $true
  return $out
}

# ============================================================================
# WHICH GAMES THIS THING CAN LOOK AFTER
#
# Eva asked for a button that lists them ("the minecraft we made it handle, the
# valheim we are about to"). The temptation is a typed list, and a typed list
# is exactly what must not be here: it would be right on the day it was typed
# and would then quietly disagree with harness\games\*.psd1 forever, which is
# the failure this project keeps writing knowledge files about.
#
# So every row is derived. The name and the three verification flags come from
# the template file; the "what it can do" numbers come from the SAME conformance
# checker the test suite runs, so a template that loses a capability loses it in
# this window on the next open, without anybody remembering to edit anything.
#
# COST: 2.6 s for six templates, measured 2026-09-14 - nearly all of it the
# one-time parse of the harness source that Get-RkConfConsumption does. That is
# thirty times the budget of a timer tick, so this MUST be called from a
# background gather. It is never called on the dispatcher thread.
# ============================================================================
function Get-RkPeekStateDir {
  # <ServerDir>\respawnkeeper WITHOUT creating it.
  #
  # Get-RkStateDir does New-Item -Force, which is right for the supervisor and
  # wrong for a question. Both read paths on the fleet sheet used it, so merely
  # OPENING the sheet created respawnkeeper\ in every registered folder, from a
  # background runspace, with nothing said about it. A read that writes is not
  # a read.
  param([Parameter(Mandatory)][string]$ServerDir)
  return (Join-Path $ServerDir 'respawnkeeper')
}

function Get-RkSupportedGames {
  param([string[]]$ServerDirs = @())

  $gamesDir = Join-Path $script:PanelHarnessDir 'games'
  if (-not (Test-Path -LiteralPath $gamesDir)) { return @() }

  # Which registered folder uses which template. Taken from each profile.json
  # rather than by re-detecting: the profile is what the supervisor actually
  # obeys, and re-detection could name a template this server is not run under.
  $useBy = @{}
  foreach ($d in @($ServerDirs)) {
    if (-not $d) { continue }
    $label = Split-Path -Leaf $d
    $gid = ''
    try {
      $pf = Read-RkJson -Path (Join-Path (Get-RkPeekStateDir -ServerDir $d) 'profile.json')
      if ($pf) {
        if ($pf.serverLabel) { $label = [string]$pf.serverLabel }
        if ($pf.game)        { $gid   = [string]$pf.game }
      }
    } catch { Trap-PanelError $_ }
    if (-not $gid) { continue }
    if (-not $useBy.ContainsKey($gid)) { $useBy[$gid] = @() }
    $useBy[$gid] = @($useBy[$gid]) + $label
  }

  # The scorer is optional on purpose. If the capabilities contract or the
  # checker is missing, the window still lists the games and says the counts are
  # unknown (-1), because "we could not work it out" and "it can do nothing" are
  # different answers and only one of them is true.
  $caps = $null; $consumption = $null; $ctx = $null; $canScore = $false
  try {
    $capsFile = Join-Path $script:PanelHarnessDir 'lib\rk-capabilities.psd1'
    $confLib  = Join-Path $script:PanelHarnessDir 'lib\rk-conformance.ps1'
    if ((Test-Path -LiteralPath $capsFile) -and (Test-Path -LiteralPath $confLib)) {
      . $confLib
      $caps = Import-PowerShellDataFile -LiteralPath $capsFile
      # Read from the source, not assumed - the same way the test does it, so
      # that removing the pid file breaks this instead of making the probe a lie.
      $writesPid = $false
      $sup = Join-Path $script:PanelHarnessDir 'respawnkeeper.ps1'
      if (Test-Path -LiteralPath $sup) {
        $src = Get-Content -LiteralPath $sup -Raw
        $writesPid = ($src -match 'ServerPidFile' -and $src -match "Set-Content[^\r\n]*ServerPidFile")
      }
      $ctx = @{ rulesDir                = (Join-Path $script:PanelHarnessDir 'rules')
                harnessRoot             = $script:PanelHarnessDir
                supervisorWritesPidFile = $writesPid
                pidFileName             = 'respawnkeeper\server.pid' }
      $consumption = Get-RkConfConsumption -HarnessRoot $script:PanelHarnessDir -Fields @($caps.mustBeConsumed | ForEach-Object { [string]$_ })
      $canScore = $true
    }
  } catch { Trap-PanelError $_ }

  $out = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $gamesDir -Filter '*.psd1' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $t = $null
    try { $t = Import-PowerShellDataFile -LiteralPath $f.FullName } catch { Trap-PanelError $_ }
    $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    if (-not $t) {
      # A template that will not parse is still a game somebody added. Saying
      # nothing about it would hide the only interesting fact about it.
      $out += [pscustomobject]@{ Id = $id; Name = $id; Layout = $false; Launch = $false; Stop = $false
                                 Level = 'broken'; On = -1; Blocked = -1; Off = -1; Servers = @() }
      continue
    }
    if ($t.id) { $id = [string]$t.id }
    $t['templateFile'] = $f.FullName
    if (-not $t.Contains('id')) { $t['id'] = $id }

    $v = $t.verified
    $vLayout = [bool]($v -and $v.layout)
    $vLaunch = [bool]($v -and $v.launch)
    $vStop   = [bool]($v -and $v.stop)
    # 'full' is deliberately (launch AND stop), not (all three). layout on its
    # own says where the files are; what makes a game USABLE unattended is that
    # somebody watched it start and watched it stop without losing the world.
    $level = 'none'
    if ($vLaunch -and $vStop) { $level = 'full' }
    elseif ($vLayout -or $vLaunch -or $vStop) { $level = 'partial' }

    $on = -1; $blocked = -1; $off = -1
    if ($canScore) {
      try {
        $r = Invoke-RkTemplateConformance -Template $t -Caps $caps -Consumption $consumption -Ctx $ctx
        $on      = @($r.features | Where-Object { $_.status -eq 'on' }).Count
        $blocked = @($r.features | Where-Object { ([string]$_.status).StartsWith('blocked') }).Count
        $off     = @($r.features | Where-Object { $_.status -eq 'off' -or $_.status -eq 'degraded' }).Count
      } catch { Trap-PanelError $_ }
    }

    $nm = [string]$t.displayName
    if (-not $nm) { $nm = $id }
    $out += [pscustomobject]@{
      Id = $id; Name = $nm
      Layout = $vLayout; Launch = $vLaunch; Stop = $vStop
      Level = $level; On = $on; Blocked = $blocked; Off = $off
      Servers = @($useBy[$id])
    }
  }

  # Furthest along first, then the ones actually in use here, then by name - so
  # the row a person is looking for is near the top rather than alphabetical.
  $rank = @{ full = 0; partial = 1; none = 2; broken = 3 }
  return @($out | Sort-Object `
    @{ Expression = { $rank[$_.Level] } }, `
    @{ Expression = { -(@($_.Servers).Count) } }, `
    @{ Expression = { $_.Name } })
}

# ============================================================================
# WHO PAYS FOR THE MODEL, AND IS THE ACCOUNT ACTUALLY CONNECTED
#
# [R-020] gave this two answers - the subscription (the claude CLI signed in on
# Eva's own account) or an API key billed per use - and rk-setup asked the
# question once, per server, buried in step 3b of a console script. That is the
# wrong place for it twice over: it is an ACCOUNT-wide fact, and it is the first
# thing that has to be true before any of this works, so it belongs on the first
# screen rather than at the end of a setup nobody re-runs.
#
# THE KEY ITSELF IS NEVER HANDLED HERE. Only the NAME of the environment
# variable that holds it. Entering a credential is Eva's own action, in her own
# shell - see the global rules. This code reads whether that variable is set and
# nothing else; it never reads, prints, stores or transmits the value.
# ============================================================================
function Get-RkModelWallet {
  param([string[]]$ServerDirs = @())

  $res = [pscustomobject]@{
    CliPresent = $false      # is there a claude command on PATH at all
    SignedIn   = $false      # ...and is it logged in
    Backend    = 'subscription'
    ApiKeyEnv  = 'ANTHROPIC_API_KEY'
    ApiKeySet  = $false      # the NAME resolves to something. Never the value.
    Mixed      = $false      # registered servers disagree with each other
    Count      = 0           # how many profiles were readable
  }

  $res.CliPresent = [bool](Get-Command claude -ErrorAction SilentlyContinue)
  if ($res.CliPresent) {
    # 340-486 ms, measured. One of the reasons this whole function is only ever
    # called from a background gather.
    try {
      $raw = (& claude auth status 2>&1 | Out-String)
      if ($raw -match '"loggedIn"\s*:\s*true') { $res.SignedIn = $true }
    } catch { Trap-PanelError $_ }
  }

  $backends = @(); $envs = @()
  foreach ($d in @($ServerDirs)) {
    if (-not $d) { continue }
    try {
      $pf = Read-RkJson -Path (Join-Path (Get-RkPeekStateDir -ServerDir $d) 'profile.json')
      if (-not $pf) { continue }
      $res.Count++
      $b = 'subscription'; $e = 'ANTHROPIC_API_KEY'
      if ($pf.model) {
        if ($pf.model.backend)   { $b = [string]$pf.model.backend }
        if ($pf.model.apiKeyEnv) { $e = [string]$pf.model.apiKeyEnv }
      }
      $backends += $b; $envs += $e
    } catch { Trap-PanelError $_ }
  }
  if ($backends.Count -gt 0) {
    # WHATEVER IS IN THE FILE IS NOT NECESSARILY A BACKEND. This was copied out
    # verbatim, handed to the sheet, and then handed to Set-RkProfileWallet,
    # whose [ValidateSet] threw a TERMINATING error inside the Click handler -
    # so one profile containing backend="openai" (hand-edited, half-written,
    # from a future version) meant zero servers were written and the sheet did
    # not change at all. Anything unrecognised reads as the default, which is
    # also what the supervisor does with it.
    $b0 = [string]$backends[0]
    $res.Backend = $(if ($b0 -eq 'api') { 'api' } else { 'subscription' })
    $res.Mixed   = (@($backends | Sort-Object -Unique).Count -gt 1)
  }
  if ($envs.Count -gt 0) { $res.ApiKeyEnv = $envs[0] }

  # Machine scope as well as process scope: setx in another window has not
  # reached this process, and reporting "not set" then would send Eva looking
  # for a problem she has already fixed.
  try {
    $val = [System.Environment]::GetEnvironmentVariable($res.ApiKeyEnv)
    if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($res.ApiKeyEnv, 'User') }
    if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($res.ApiKeyEnv, 'Machine') }
    $res.ApiKeySet = [bool]$val
  } catch { Trap-PanelError $_ }

  return $res
}

function Get-RkRemodelledProfileText {
  # The wallet change, as a string -> string function, testable without a
  # window. @{ ok; text; reason }
  #
  # SURGICAL, for the same reason as Get-RkRelabeledProfileText: a round trip
  # through ConvertFrom-Json / ConvertTo-Json re-encodes every Japanese string
  # in the file into \uXXXX escapes. Still valid JSON, no longer a file Eva can
  # read. Two lines change.
  param(
    [Parameter(Mandatory)][string]$Raw,
    [Parameter(Mandatory)][ValidateSet('subscription','api')][string]$Backend,
    [string]$ApiKeyEnv = 'ANTHROPIC_API_KEY'
  )
  $out = @{ ok = $false; text = ''; reason = '' }

  $envName = $ApiKeyEnv.Trim()
  if (-not $envName) { $envName = 'ANTHROPIC_API_KEY' }

  # THE NAME IS ONLY PART OF THE ANSWER WHEN THE ANSWER IS 'api'. It used to be
  # validated and rewritten either way, so: choose metered, type something into
  # the name box, change your mind, choose subscription - and every server
  # failed with "that is not an environment variable name", about a box the
  # sheet had just hidden. Picking the subscription now touches only 'backend'.
  $pairs = @(, @('backend', $Backend))
  if ($Backend -eq 'api') {
    # An environment variable name, not a value. Anything outside this set is
    # either a typo or somebody pasting the KEY into the name box, and the
    # second one must never reach disk.
    if ($envName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') {
      $out.reason = 'that is not an environment variable name'
      return $out
    }
    $pairs += , @('apiKeyEnv', $envName)
  }

  $text = $Raw
  foreach ($pair in $pairs) {
    $key = $pair[0]; $val = $pair[1]
    # Same double escape as the rename: once for JSON, once for the regex
    # replacement string, where $1 $& $_ are substitution tokens.
    $repl = $val.Replace('\', '\\').Replace('"', '\"').Replace('$', '$$')
    $pat = '(?m)^(\s*"' + $key + '"\s*:\s*)"(?:[^"\\]|\\.)*"'
    $n = ([regex]$pat).Matches($text).Count
    if ($n -eq 1) {
      $text = ([regex]$pat).Replace($text, ('${1}"' + $repl + '"'), 1)
    } else {
      # Not "add it anyway": a profile with no model block, or with two
      # "backend" lines, is not a file this function understands, and guessing
      # where the key belongs is how a config silently ends up with the setting
      # in a section nothing reads.
      $out.reason = '"' + $key + '" x' + $n
      return $out
    }
  }

  # Prove it is still JSON and still says what was asked, BEFORE it goes to disk.
  $check = $null
  try { $check = ($text | ConvertFrom-Json) } catch { $check = $null }
  if (-not $check)         { $out.reason = 'the result is not JSON'; return $out }
  if (-not $check.model)   { $out.reason = 'the result has no model block'; return $out }
  if ([string]$check.model.backend -ne $Backend) { $out.reason = 'the result does not say what was chosen'; return $out }
  if (($Backend -eq 'api') -and ([string]$check.model.apiKeyEnv -ne $envName)) { $out.reason = 'the result does not say what was chosen'; return $out }

  $out.ok = $true
  $out.text = $text
  return $out
}

function Get-RkVerifiedForProfile {
  # What has actually been WATCHED for this server's game. @{ layout; launch;
  # stop; source }
  #
  # THE PROFILE'S COPY IS A SNAPSHOT, NOT THE TRUTH. rk-setup writes
  # gameVerified into profile.json at registration time and nothing ever
  # refreshes it, so a promotion made later never reaches the window. Measured
  # 2026-09-14 on the Everheim instance: harness\games\valheim.psd1 had said
  # layout/launch/stop = $true since [R-086] on 09-13, and the panel's policy
  # sheet was still printing "this game has not been seen stopping cleanly, so
  # nothing will start itself" from a copy taken at 10:21:38 that morning - and
  # vetoing autoRestart on the strength of it.
  #
  # The template is therefore read first, by the id the profile PINNED. That
  # keeps the reason the pin exists (if two templates could match a folder, the
  # supervisor must keep using the one that was verified here) while dropping
  # the part that was never meant to be frozen. The supervisor already works
  # this way - it reads the template - so this also stops the window and the
  # thing it is watching from disagreeing.
  #
  # A DOWNGRADE PROPAGATES TOO, which is the safe direction: taking stop back
  # down to $false in the template makes the window refuse auto-restart at once,
  # rather than at whatever future date somebody re-runs setup.
  param($Profile)
  $out = @{ layout = $false; launch = $false; stop = $false; source = 'nothing' }
  $gid = ''
  try { if ($Profile) { $gid = [string]$Profile.game } } catch { }
  if ($gid) {
    $f = Join-Path (Join-Path $script:PanelHarnessDir 'games') ($gid + '.psd1')
    if (Test-Path -LiteralPath $f) {
      try {
        $tpl = Import-PowerShellDataFile -LiteralPath $f
        if ($tpl -and $tpl.verified) {
          $out.layout = [bool]$tpl.verified.layout
          $out.launch = [bool]$tpl.verified.launch
          $out.stop   = [bool]$tpl.verified.stop
          $out.source = 'template'
          return $out
        }
      } catch { Trap-PanelError $_ }
    }
  }
  # The template is gone or unreadable. The frozen copy is all there is, and it
  # is still better than assuming the best.
  try {
    if ($Profile -and $Profile.gameVerified) {
      $out.layout = ($Profile.gameVerified.layout -eq $true)
      $out.launch = ($Profile.gameVerified.launch -eq $true)
      $out.stop   = ($Profile.gameVerified.stop   -eq $true)
      $out.source = 'profile'
    }
  } catch { Trap-PanelError $_ }
  return $out
}

function Get-RkEscalationHookPath {
  # The hook rk-setup would have named. '' when it is not there.
  return (Join-Path $script:PanelHarnessDir 'hooks\escalate-claude.ps1')
}

function Get-RkPolicyPreset {
  # The three switches a named policy stands for. rk-setup.ps1 step 3 has the
  # same table; this is the one the WINDOW uses, and both write the same file.
  param([Parameter(Mandatory)][ValidateSet('manual','watch','unattended')][string]$Name)
  switch ($Name) {
    'watch'      { return @{ autoRestart = $true;  autoRepair = $false; escalate = $false } }
    'unattended' { return @{ autoRestart = $true;  autoRepair = $true;  escalate = $true  } }
    default      { return @{ autoRestart = $false; autoRepair = $false; escalate = $false } }
  }
}

function Get-RkPolicyName {
  # The name for a combination of switches, or 'custom' when it is not one of
  # the three. Both places that DISPLAY a policy name already fall through to
  # the raw string (panel-model.ps1 Get-RkPanelRow, rk-panel.ps1
  # Build-MaintPolicyRows), so a fourth value costs nothing there - and the
  # supervisor reads the three flags individually and never branches on this
  # name at all (it only prints it).
  param([bool]$AutoRestart, [bool]$AutoRepair, [bool]$Escalate)
  if ((-not $AutoRestart) -and (-not $AutoRepair) -and (-not $Escalate)) { return 'manual' }
  if ($AutoRestart -and (-not $AutoRepair) -and (-not $Escalate))        { return 'watch' }
  if ($AutoRestart -and $AutoRepair -and $Escalate)                      { return 'unattended' }
  return 'custom'
}

function Get-RkRepolicedProfileText {
  # The policy change, as a string -> string function, testable without a
  # window. @{ ok; text; reason; applied }
  #
  # THREE SWITCHES, NOT A PRESET. It used to take a policy NAME, which is how
  # rk-setup asks the question and is wrong for the window: Eva wants to turn
  # ONE of them off (the rule-table repair off, the model stage on) and a preset
  # cannot express that. The name is now DERIVED from the switches, so the file
  # keeps a readable profile field and the sheet keeps its shortcuts.
  #
  # SURGICAL, for the third time and the same reason (Get-RkRelabeledProfileText,
  # Get-RkRemodelledProfileText): a round trip through ConvertTo-Json re-encodes
  # every Japanese string in the file into \uXXXX.
  #
  # THE TWO VETOES ARE PART OF THE ANSWER, not a caller's job. rk-setup applies
  # them at registration and the window has to apply the same ones, or the two
  # doors into the same file disagree about what a switch means.
  param(
    [Parameter(Mandatory)][string]$Raw,
    [bool]$AutoRestart = $false,
    [bool]$AutoRepair  = $false,
    [bool]$Escalate    = $false,
    # Whether a HUMAN has watched this game stop cleanly. From the template, not
    # from the copy frozen in the profile - see Get-RkVerifiedForProfile.
    [bool]$StopVerified = $false,
    [string]$HookPath = ''
  )
  $out = @{ ok = $false; text = ''; reason = ''; applied = $null }

  $wantRestart = $AutoRestart
  $wantRepair  = $AutoRepair
  $wantEscalate = $Escalate

  # VETO 1: a game whose clean stop nobody has watched does not get to be
  # started or written to on its own. Both flags, not just autoRestart -
  # repair is the one that WRITES ([R-071] addendum).
  if (-not $StopVerified) { $AutoRestart = $false; $AutoRepair = $false }

  # VETO 2: escalation needs a hook that exists.
  $writeHook = ''
  if ($Escalate) {
    if ($HookPath -and (Test-Path -LiteralPath $HookPath)) { $writeHook = $HookPath }
    else { $Escalate = $false }
  }

  $name = Get-RkPolicyName -AutoRestart $AutoRestart -AutoRepair $AutoRepair -Escalate $Escalate

  $text = $Raw
  $edits = @(
    @{ k = 'profile';        pat = '(?m)^(\s*"profile"\s*:\s*)"[^"]*"';             val = ('"' + $name + '"') },
    @{ k = 'autoRestart';    pat = '(?m)^(\s*"autoRestart"\s*:\s*)(true|false)';    val = $(if ($AutoRestart) { 'true' } else { 'false' }) },
    @{ k = 'autoRepair';     pat = '(?m)^(\s*"autoRepair"\s*:\s*)(true|false)';     val = $(if ($AutoRepair)  { 'true' } else { 'false' }) },
    @{ k = 'escalateOnHalt'; pat = '(?m)^(\s*"escalateOnHalt"\s*:\s*)(true|false)'; val = $(if ($Escalate)    { 'true' } else { 'false' }) }
  )
  if ($writeHook) {
    # Escaped for JSON, then for the .NET replacement string, where $1 $& $_ are
    # substitution tokens - a Windows path is full of backslashes and this is
    # the third place in this file that has had to say so.
    $esc = $writeHook.Replace('\', '\\').Replace('"', '\"').Replace('$', '$$')
    $edits += @{ k = 'escalationHook'; pat = '(?m)^(\s*"escalationHook"\s*:\s*)"(?:[^"\\]|\\.)*"'; val = ('"' + $esc + '"') }
  }

  foreach ($e in $edits) {
    $n = ([regex]$e.pat).Matches($text).Count
    if ($n -ne 1) { $out.reason = $e.k + ' x' + $n; return $out }
    $text = ([regex]$e.pat).Replace($text, ('${1}' + $e.val), 1)
  }

  # Prove it is still JSON and still says what was meant, BEFORE it goes to disk.
  $check = $null
  try { $check = ($text | ConvertFrom-Json) } catch { $check = $null }
  if (-not $check) { $out.reason = 'the result is not JSON'; return $out }
  if ([string]$check.profile -ne $name)                  { $out.reason = 'the result does not say what was chosen'; return $out }
  if (([bool]$check.autoRestart)    -ne $AutoRestart)    { $out.reason = 'autoRestart did not take'; return $out }
  if (([bool]$check.autoRepair)     -ne $AutoRepair)     { $out.reason = 'autoRepair did not take'; return $out }
  if (([bool]$check.escalateOnHalt) -ne $Escalate)       { $out.reason = 'escalateOnHalt did not take'; return $out }

  $out.ok = $true
  $out.text = $text
  $out.applied = [pscustomobject]@{
    Policy = $name; AutoRestart = $AutoRestart; AutoRepair = $AutoRepair
    Escalate = $Escalate; Hook = $writeHook
    # What the operator asked for but did not get, and why. The sheet needs
    # this: a switch that flips itself back with no explanation is the defect
    # this whole function was rewritten to stop repeating.
    VetoedByStop = ((-not $StopVerified) -and ($wantRestart -or $wantRepair))
    VetoedByHook = ($wantEscalate -and (-not $Escalate))
  }
  return $out
}

function Set-RkProfileWallet {
  # One profile file, on disk. @{ ok; reason }
  #
  # Split out of the panel's apply loop so the part that actually TOUCHES A FILE
  # can be run by the self-test without a window. The loop above it is then only
  # "for each row, call this and count", which is the part a picture can check.
  param(
    [Parameter(Mandatory)][string]$ProfileFile,
    [Parameter(Mandatory)][ValidateSet('subscription','api')][string]$Backend,
    [string]$ApiKeyEnv = 'ANTHROPIC_API_KEY'
  )
  $out = @{ ok = $false; reason = '' }
  if (-not (Test-Path -LiteralPath $ProfileFile)) { $out.reason = 'no profile.json'; return $out }
  try {
    $raw = Get-Content -LiteralPath $ProfileFile -Raw -Encoding UTF8
  } catch { $out.reason = $_.Exception.Message; return $out }

  $res = Get-RkRemodelledProfileText -Raw $raw -Backend $Backend -ApiKeyEnv $ApiKeyEnv
  if (-not $res.ok) { $out.reason = $res.reason; return $out }

  try {
    # A COPY BESIDE IT FIRST, AND IT HAS TO SUCCEED. This was
    # -ErrorAction SilentlyContinue on the only safety net there is: with the
    # .bak path unwritable the profile was rewritten anyway and the call
    # returned ok=$true. rk-setup.ps1 does the same copy with -ErrorAction Stop
    # and warns; this did neither.
    #
    # One generation of history, because .bak is shared: the rename sheet, the
    # policy sheet, rk-setup and this all write it, so two applies in a row used
    # to leave the original nowhere. The previous .bak is moved aside first.
    $bak = $ProfileFile + '.bak'
    if (Test-Path -LiteralPath $bak) {
      Copy-Item -LiteralPath $bak -Destination ($ProfileFile + '.bak2') -Force -ErrorAction SilentlyContinue
    }
    Copy-Item -LiteralPath $ProfileFile -Destination $bak -Force -ErrorAction Stop
    # CHECK THE RESULT, NOT THE CALL. -ErrorAction Stop is not enough on its
    # own: if something has left a DIRECTORY at profile.json.bak, Copy-Item
    # cheerfully copies INTO it (profile.json.bak\profile.json) and reports
    # success, so there is no backup at the path anything would look for and
    # nothing threw. Caught by the test written for the -ErrorAction fix.
    if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) {
      throw ('the backup did not end up at ' + $bak)
    }
    # UTF-8 WITH NO BOM, written as bytes. Set-Content -Encoding UTF8 on PS 5.1
    # emits a BOM, and a BOM in a config file is a rule this project has already
    # paid for once (a TOML crash). Read-RkJson copes either way; the person
    # opening the file in an editor is the one who would not.
    [System.IO.File]::WriteAllText($ProfileFile, $res.text, (New-Object System.Text.UTF8Encoding($false)))
  } catch { $out.reason = $_.Exception.Message; return $out }
  $out.ok = $true
  return $out
}

function Get-RkClaudeState {
  # @{ present; signedIn }. Two facts, one 340-486 ms call, because every caller
  # that wanted one of them wanted to know about the other in the same breath
  # and was getting it by negating the wrong thing.
  $res = @{ present = $false; signedIn = $false }
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return $res }
  $res.present = $true
  $raw = ''
  try { $raw = (& claude auth status 2>&1 | Out-String) } catch { return $res }
  $res.signedIn = ($raw -match '"loggedIn"\s*:\s*true')
  return $res
}

function Get-RkSignedOut {
  # Account-wide, so it belongs above the list rather than repeated on cards.
  # "The CLI is here and logged out" - deliberately NOT true when there is no
  # CLI, which is why it is not the complement of Get-RkClaudeState().signedIn.
  $cs = Get-RkClaudeState
  return ($cs.present -and (-not $cs.signedIn))
}

# ============================================================================
# The keeper
#
# WHY A CHARACTER IS ALLOWED IN HERE AT ALL. [R-043] set the rule that nothing
# in this window may move, because a readout that fights its reader is a
# costume. The keeper does not break that rule, she is an instance of it: her
# eyes, her collar and the light under her feet are drawn in the STATE colour,
# so what animates is the status itself. She blinks; she does not dance.
#
# She is also the only part of the window that answers the question at the
# altitude a person actually asks it. The cards answer "what is pokemoncraft
# doing"; she answers "is anything wrong", which is the question that made
# someone open the window.
# ============================================================================
. (Join-Path $script:PanelUiDir 'rk-sprite.ps1')
. (Join-Path $script:PanelUiDir 'rk-stage.ps1')
. (Join-Path $script:PanelUiDir 'rk-city.ps1')

# The rail is a STAGE, described by stage\rail.json: the bed underneath, her on
# top of it. It used to be one .rkspr drawn into an <Image>, which made her her
# own background - so she could not be moved or replaced without a hole
# appearing where she had been [R-064].
#
# The pose timings that used to be $script:KeeperLoops here are now 'hold' in
# that manifest, on the layer that actually carries the state (the neon sign
# over the bed - her iris is three pixels at this size and the colour reduction
# does not even keep a green for it). Timing belongs next to the art it times.
$script:RailStage = $null
$script:RailPath  = Join-Path $script:PanelUiDir 'stage\rail.json'

function Get-RkKeeperState {
  param($Rows)

  $rows = @($Rows)
  if ($rows.Count -eq 0) {
    # No servers is not "every server is stopped": the sign has nothing to
    # report, so it wears the quiet ink, not the stopped colour ([R-091] U18).
    return [pscustomobject]@{ Pose = 'sleep'; Brush = $script:Col.inkSubtle; Line = (T 'keeper.none') }
  }

  # Severity is read off the notices' LEVEL, not their colour. Deriving it from
  # the brush would work today and break the first time a theme picked the same
  # hex for two meanings - and this is the one place in the panel where a wrong
  # answer is silent, because a calm character is what "nothing is wrong" looks
  # like.
  $running = 0; $care = 0; $halted = 0
  foreach ($r in $rows) {
    if ($r.Running) { $running++ }
    foreach ($n in @($r.Notices)) {
      if ($n.Level -eq 'danger') { $halted++ }
      elseif ($n.Level -eq 'care') { $care++ }
    }
  }

  if ($halted -gt 0) { return [pscustomobject]@{ Pose = 'halt';  Brush = $script:Col.danger;    Line = (T 'keeper.halt') } }
  if ($care -gt 0)   { return [pscustomobject]@{ Pose = 'care';  Brush = $script:Col.amber;     Line = (TF 'keeper.care' $care) } }
  # T, not TF: THE COUNT IS GONE FROM THIS LINE ON PURPOSE (Eva, 2026-09-14).
  # It used to open with the number of running servers, which read as "both of
  # the 1 are running" at one server and said nothing worth reading at any other
  # number - the cards directly above already carry the count. What this line is
  # for is whether anything is WRONG. 'care' keeps its number, because "look at
  # 3 things later" is the entire content of that one.
  if ($running -gt 0){ return [pscustomobject]@{ Pose = 'run';   Brush = $script:Col.accent;    Line = (T 'keeper.run') } }
  return               [pscustomobject]@{ Pose = 'sleep'; Brush = $script:Col.idle;      Line = (T 'keeper.sleep') }
}

function Get-RkRailStage {
  # Read once. Read-RkStage validates every frame name against the art that is
  # actually there, so a typo in the manifest throws here rather than showing an
  # empty rail and saying nothing.
  if (-not $script:RailStage) { $script:RailStage = Read-RkStage -Path $script:RailPath }
  return $script:RailStage
}

function Update-RkKeeper {
  param([Parameter(Mandatory)]$Window, $Rows, [int]$Tick = 0)

  $canvas = $Window.FindName('KeeperStage')
  if (-not $canvas) { return $null }

  $st = Get-RkKeeperState -Rows $Rows
  try {
    # Build the visual tree the first time this canvas is seen. Keyed on the
    # canvas being empty rather than on a flag, so a second window in the same
    # process (the offscreen preview) builds its own instead of silently
    # sharing one set of Image elements with the first.
    if ($canvas.Children.Count -eq 0) {
      [void](New-RkStageVisual -Stage (Get-RkRailStage) -Canvas $canvas)
    }
    Update-RkStage -Stage (Get-RkRailStage) -Tick $Tick -State $st.Pose -Signal $st.Brush
  } catch { Trap-PanelError $_ }

  $line = $Window.FindName('KeeperLine')
  if ($line) {
    $line.Text = $st.Line
    try { $line.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($st.Brush)) } catch {}
  }
  return $st
}
