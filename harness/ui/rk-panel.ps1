# ============================================================
# rk-panel.ps1 - the control panel window. ASCII only (PS 5.1 decodes BOM-less
# .ps1 as ANSI). Japanese lives in panel-strings.ja.json, layout in panel.xaml,
# and everything it KNOWS is in panel-model.ps1.
#
# WHY THIS EXISTS. Everything shown here was already being written to disk -
# STATUS.txt, state.json, reports\daily-*.md, reports\comeback-*.md - and none
# of it reached the operator, because reaching it meant walking into a server folder
# and opening a text file. The daily report in particular was built to be read
# at leisure and was invisible. This is not a new feature; it is the existing
# state, put where a person actually looks.
#
# IT IS A VIEW, NOT A SECOND BRAIN. It reads files and launches the same .bat
# files a human would double-click. It never repairs and never decides.
#
# It writes into a server folder in exactly one place: the policy sheet, which
# changes four scalars in <ServerDir>\respawnkeeper\profile.json and keeps the
# previous file beside it as .bak. The other two maintenance sheets start the
# script a person would have typed and then check the result. Nothing here ever
# opens world\, mods\ or config\.
#
#   powershell -STA -File harness\ui\rk-panel.ps1
#   powershell -STA -File harness\ui\rk-panel.ps1 -Once   # print the model, no window
# ============================================================

param(
  [switch]$Once,           # resolve every server, dump what the cards would say, exit
  [string]$Theme = '',     # modern (default) | pixel. Remembered in panel-settings.json
  [switch]$NoAutoRefresh,
  [string]$RenderTo = '',  # rasterise THIS window (not a rebuilt copy) and exit
  [string]$RenderAdd = '', # with -RenderTo: open the add-a-server sheet on this folder
  [string]$RenderMaint = '', # with -RenderTo: quar | scan | policy | name
  [string]$RenderMaintDir = '', # which server the maintenance sheet is about
  [string]$RenderMaintPick = '', # with -RenderMaint policy: the policy to select
  [switch]$RenderMaintDo,  # PRESS the sheet's action button before rasterising
  [string]$RenderFleet = '', # with -RenderTo: games | model
  [string]$RenderFleetPick = ''  # with -RenderFleet model: subscription | api
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'panel-model.ps1')
. (Join-Path $PSScriptRoot 'rk-async.ps1')

$RepoDir  = $script:PanelRepoDir
Write-RkTrace 'panel: model loaded'
$XamlFile = Join-Path $PSScriptRoot 'panel.xaml'

# ---- -Once: the model, with no window in the way ----------------------------
if ($Once) {
  $dirs = @(Get-RkKnownServers)
  $onceRows = New-Object System.Collections.ArrayList
  Write-Host ('servers: ' + $dirs.Count)
  foreach ($d in $dirs) {
    $row = Get-RkPanelRow -ServerDir $d
    [void]$onceRows.Add($row)
    Write-Host ''
    Write-Host ('  ' + $row.Label + '  [' + $row.StateText + ']  ' + $row.Uptime)
    Write-Host ('    ' + $row.Meta)
    foreach ($n in $row.Notices) { Write-Host ('    * ' + $n.Text) }
    Write-Host ('    canStart=' + $row.CanStart + ' canStop=' + $row.CanStop + ' report=' + $row.HasReport)
    Write-Host ('    ' + $row.ServerDir)
  }
  Write-Host ''
  Write-Host ('signed out: ' + (Get-RkSignedOut))

  # The keeper, with no window to draw her in. Two things are checked here
  # because both fail SILENTLY in the window: Update-RkKeeper traps its own
  # errors (a panel must not die because a sprite did), so a renamed frame or a
  # broken .rkspr would just show an empty rail and no complaint at all.
  $keeper = Get-RkKeeperState -Rows $onceRows
  Write-Host ('keeper: ' + $keeper.Pose + '  ' + $keeper.Brush + '  ' + $keeper.Line)

  # Rasterising needs the imaging types, which -Once has not loaded because it
  # opens no window.
  Add-Type -AssemblyName PresentationCore, WindowsBase, PresentationFramework
  $bad = 0
  try {
    $rail = Get-RkRailStage
    Write-Host ('rail: ' + $rail.Width + 'x' + $rail.Height + ' @' + $rail.Scale + 'x, ' +
                $rail.Layers.Count + ' layers')
    # Rasterise every frame of every animation. Read-RkStage checks the NAMES
    # exist; only actually drawing them proves the pixels do.
    foreach ($L in $rail.Layers) {
      foreach ($a in @($L.Anims.Keys)) {
        foreach ($fr in $L.Anims[$a]) {
          try { [void](Get-RkStageFrameImage -Stage $rail -Layer $L -Frame $fr -Signal '#FFFFFFFF') }
          catch { $bad++; Write-Host ('  ! ' + $L.Id + '/' + $a + ' wants frame ' + $fr + ': ' + $_.Exception.Message) }
        }
      }
    }
  } catch { $bad++; Write-Host ('  ! rail did not load: ' + $_.Exception.Message) }
  Write-Host ('rail frames: ' + $(if ($bad -eq 0) { 'all present' } else { $bad.ToString() + ' missing' }))
  # The window swallows per-server failures so one odd folder cannot take the
  # whole panel down. Here they are printed, because a silently swallowed
  # exception is how this file shipped two invisible bugs.
  if ($script:PanelErrors.Count -gt 0) {
    Write-Host ''
    Write-Host ('swallowed errors: ' + $script:PanelErrors.Count)
    foreach ($e in $script:PanelErrors) { Write-Host ('  ! ' + $e) }
  }
  exit 0
}

# ---- the window -------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# The chosen theme is remembered next to the panel, not in a server folder:
# it is a preference about this window, not about any server.
$SettingsFile = Join-Path $PSScriptRoot 'panel-settings.json'
if (-not $Theme) {
  $st = Read-RkJson -Path $SettingsFile
  if ($st -and $st.theme) { $Theme = [string]$st.theme } else { $Theme = 'modern' }
}
try { Write-RkJson -Path $SettingsFile -Object ([ordered]@{ schema = 'respawnkeeper/panel/1'; theme = $Theme }) } catch {}

try { $win = New-RkPanelWindow -Theme $Theme }
catch { Write-Host ('FATAL: panel.xaml failed to load: ' + $_.Exception.Message); exit 2 }

Write-RkTrace 'panel: window built'
$win.Add_ContentRendered({ Write-RkTrace 'panel: window shown' })
$ListServers  = $win.FindName('ListServers')
$EmptyState   = $win.FindName('EmptyState')
$TxtFooter    = $win.FindName('TxtFooter')
$BannerGlobal = $win.FindName('BannerGlobal')
$TxtGlobal    = $win.FindName('TxtGlobal')
$BtnFixGlobal = $win.FindName('BtnFixGlobal')
$script:KeeperTick = 0
$script:PanelRows  = @()
$BtnAdd       = $win.FindName('BtnAdd')
$BtnEnv       = $win.FindName('BtnEnv')
$BtnGames     = $win.FindName('BtnGames')
$FleetLayer      = $win.FindName('FleetLayer')
$TxtFleetTitle   = $win.FindName('TxtFleetTitle')
$TxtFleetWho     = $win.FindName('TxtFleetWho')
$FleetDetails    = $win.FindName('FleetDetails')
$WalletRow       = $win.FindName('WalletRow')
$TxtWalletPick   = $win.FindName('TxtWalletPick')
$BtnWalletSub    = $win.FindName('BtnWalletSub')
$BtnWalletApi    = $win.FindName('BtnWalletApi')
$ApiEnvRow       = $win.FindName('ApiEnvRow')
$TxtApiEnvPick   = $win.FindName('TxtApiEnvPick')
$TxtApiEnvInput  = $win.FindName('TxtApiEnvInput')
$TxtApiEnvState  = $win.FindName('TxtApiEnvState')
$BtnFleetClose   = $win.FindName('BtnFleetClose')
$BtnFleetAction  = $win.FindName('BtnFleetAction')
$AddLayer         = $win.FindName('AddLayer')
$TxtAddTitle      = $win.FindName('TxtAddTitle')
$AddDetails       = $win.FindName('AddDetails')
$TxtAddPolicy     = $win.FindName('TxtAddPolicy')
$PolicyRow        = $win.FindName('PolicyRow')
$BtnPolUnattended = $win.FindName('BtnPolUnattended')
$BtnPolWatch      = $win.FindName('BtnPolWatch')
$BtnPolManual     = $win.FindName('BtnPolManual')
$BtnAddCancel     = $win.FindName('BtnAddCancel')
$BtnAddConfirm    = $win.FindName('BtnAddConfirm')
$MaintLayer        = $win.FindName('MaintLayer')
$TxtMaintTitle     = $win.FindName('TxtMaintTitle')
$TxtMaintWho       = $win.FindName('TxtMaintWho')
$MaintDetails      = $win.FindName('MaintDetails')
$TxtMaintPick      = $win.FindName('TxtMaintPick')
$MaintPolicyRow    = $win.FindName('MaintPolicyRow')
$TglRestart        = $win.FindName('TglRestart')
$TglRepair         = $win.FindName('TglRepair')
$TglEscalate       = $win.FindName('TglEscalate')
$TxtTglRestart     = $win.FindName('TxtTglRestart')
$TxtTglRepair      = $win.FindName('TxtTglRepair')
$TxtTglEscalate    = $win.FindName('TxtTglEscalate')
$TxtWhyRestart     = $win.FindName('TxtWhyRestart')
$TxtWhyRepair      = $win.FindName('TxtWhyRepair')
$TxtWhyEscalate    = $win.FindName('TxtWhyEscalate')
$TxtPolicyLock     = $win.FindName('TxtPolicyLock')
$BtnMaintClose     = $win.FindName('BtnMaintClose')
$BtnMaintAction    = $win.FindName('BtnMaintAction')
$NameRow           = $win.FindName('NameRow')
$TxtNamePick       = $win.FindName('TxtNamePick')
$TxtNameInput      = $win.FindName('TxtNameInput')

function Start-Detached([string]$file) {
  # Everything this panel "does" is launching the file a human would
  # double-click. UseShellExecute gives the server its own console window that
  # the operator owns - not a child that dies when the panel closes.
  if (-not (Test-Path -LiteralPath $file)) {
    [void][System.Windows.MessageBox]::Show(($file + "`n`nnot found"), 'respawnkeeper')
    return
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $file
  $psi.UseShellExecute = $true
  $psi.WorkingDirectory = (Split-Path -Parent $file)
  try { [void][System.Diagnostics.Process]::Start($psi) }
  catch { [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'respawnkeeper') }
}

function Send-PanelSignal($row, [string]$signal) {
  # Stop and restart do NOT go through a .bat any more. rk-stop.bat only ever
  # created STOP_SERVER and then sat in a cmd window saying so; the panel can
  # create the same file itself and say so on the card. The one thing the .bat
  # could not do - and the reason the button used to look broken - is notice
  # that nobody is reading the file. Request-RkSignal checks for a supervisor
  # first and refuses out loud when there is none.
  $r = Request-RkSignal -ServerDir $row.ServerDir -Signal $signal
  if ($r.ok) { return }
  $msg = $(if ($r.reason -eq 'unsupervised') { TF 'signal.nobody' $r.detail } else { TF 'signal.failed' $r.detail })
  [void][System.Windows.MessageBox]::Show($msg, 'respawnkeeper')
}

function Start-RkConsole([string]$dir) {
  # ASK FIRST. The supervisor checks console.lock before opening a window; this
  # button did not, so clicking a server whose window is already up made a
  # second one - and now that windows outlive their supervisor, "already up" is
  # the normal case rather than a rare one. Raising the existing window is what
  # the click means anyway.
  $open = Get-RkConsoleWindow -ServerDir $dir
  if ($open.alive) {
    if (Show-RkWindowOf -Id $open.pid) { return }
    [void][System.Windows.MessageBox]::Show((TF 'console.windowOpen' $open.pid), 'respawnkeeper')
    return
  }
  # The console is a .ps1 with an argument, so it cannot go through
  # Start-Detached (which shell-executes a file a human could double-click).
  # -STA because it opens a window; hidden host window because the console IS
  # the window - a cmd box behind it would be the thing this replaces.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                    (Join-Path $PSScriptRoot 'rk-console.ps1') + '" -ServerDir "' + $dir + '"')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  try { [void][System.Diagnostics.Process]::Start($psi) }
  catch { [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'respawnkeeper') }
}

# ============================================================================
# WHY THE REFRESH IS NOT ON THIS THREAD ANY MORE  ([R-091])
#
# Eva: "this screen periodically stops responding". It was not periodic in the
# sense of rare. Measured 2026-09-13 against her three servers:
#
#   Get-RkKnownServers (the five-pattern disk sweep)          779 ms
#   Get-RkLegacyWatchdog (Get-ScheduledTask, fc8)       996 - 1369 ms
#   Get-RkServerLiveness x3                             457 -  640 ms each
#   -------------------------------------------------------------------
#   one refresh                                        3009 - 3075 ms
#
# on a FOUR SECOND DispatcherTimer, whose Tick handler runs on the dispatcher
# thread - the thread that draws and handles input. So the window was frozen
# about three seconds in every four, and every card button called Update-Panel
# again on the way out, which is why a click felt like it hung the app. The
# 400ms keeper animation could not tick either, which is the visible tell.
#
# The two worst offenders are now fixed at the source (rk-common.ps1 asks the
# task scheduler by name instead of enumerating it; the sweep is cached for 20
# seconds), which took a refresh to about 1.3 s. That is better and still not
# acceptable: 1.3 s of dead window every 4 s is a stutter, not a fix.
#
# So the READING happens in a background runspace and the UI thread only ever
# APPLIES the result. What is left on this thread is an IsCompleted check every
# 700 ms and one property-setting pass.
#
# WHAT MAKES THIS SAFE HERE, and would not make it safe everywhere:
#   - the gather is READ-ONLY except for servers.json, which nothing else
#     writes, and which now only gets written when the list actually changed
#   - it touches no WPF object. Rows are pscustomobject and ArrayList, which
#     are not DispatcherObjects, so the UI thread may read them afterwards
#   - only ONE gather is ever in flight, so two of them cannot interleave
#   - the runspace is REUSED, so panel-model's caches (the sweep, the mod
#     index) survive between refreshes instead of being paid every time
# ============================================================================
# THE MECHANICS LIVE IN rk-async.ps1 NOW, shared with the console window,
# which had the same freeze for the same reason ([R-095]). What stays here is
# what is specific to this window: the cadence, the fallback and the apply.
#
# A gather is about a second of disk reading (was 3.5-4.8 s before the probe
# caches of [R-095]). Sixty seconds is not a performance threshold, it is
# "this one is never coming back": a disconnected path under the live-server folder or a
# wedged child process can block it forever, and without this the window keeps
# drawing pre-hang data, perfectly responsive, with the mascot still blinking -
# which is a worse lie than the freeze this change removed.
$script:Gather         = New-RkGather -Name 'panel' -DeadlineSec 60
$script:GatherForce    = $false
$script:GatherDue      = $false
$script:GatherFirst    = $true      # the first read draws from the registry and skips the disk walk
$script:AsyncRefresh   = $false
$script:FallbackAt     = [datetime]::MinValue   # when the sync fallback was entered
$script:GatherLastErr  = ''
$script:DataAt         = [datetime]::MinValue
$script:LastStart      = @{}   # ServerDir -> when its start button last fired
$script:RowsPrint      = ''    # what the cards currently show, as one string
# The frame cache warm-up: every rail frame in every state colour, rasterised
# to stage\.cache in the background so the UI thread only ever decodes a PNG
# (35 ms) instead of rasterising a text map (440 ms, measured on this thread).
$script:Prerender      = New-RkGather -Name 'prerender' -DeadlineSec 300

# THE FLEET SHEET READS IN THE BACKGROUND TOO, and it has to: Get-RkSupportedGames
# runs the conformance checker over every template (2,091 ms measured
# 2026-09-14, nearly all of it the one-time parse of the harness source) and
# Get-RkModelWallet shells out to `claude auth status` (321 ms). Either one on
# the dispatcher thread is the [R-091] freeze again, this time triggered by
# clicking a button rather than by a timer - which is worse, because the person
# is watching when it happens.
$script:FleetGather = New-RkGather -Name 'fleet' -DeadlineSec 90
$script:FleetScreen = ''        # '' | games | model
$script:FleetPick   = ''        # the wallet the operator has clicked
# A screen asked for while another read was still in flight. Without it,
# opening the games sheet, closing it and opening the model sheet inside the two
# seconds the first read takes left the second sheet on "counting..." FOR EVER:
# Start-FleetGather saw the handle busy and returned having queued nothing, the
# games result landed and was discarded for naming the wrong screen, and the
# only caller of Start-FleetGather is the button that had already been pressed.
$script:FleetWant   = ''
$script:FleetWallet = $null     # the last wallet actually read
# Drawn from the last background read. False until one lands, so the footer
# button opens finish-setup rather than a wallet sheet during the first second
# - the safe direction: finish-setup is idempotent and reports what is already
# done, whereas offering the wallet on a machine with no CLI is a dead end.
$script:ClaudeReady = $false

function Apply-PanelData {
  param($Data)
  $rows = $Data.Rows
  if ($null -eq $rows) { $rows = @() }
  # ONLY WHEN A CARD WOULD LOOK DIFFERENT. Setting ItemsSource throws every
  # card away and re-templates it (42 ms measured, on this thread, every four
  # seconds) - and while a maintenance sheet is open over the list, that swap
  # is what reordered the cards underneath it ([R-091] T8). The rows are
  # fingerprinted on every field a card binds to; an identical fingerprint is
  # an identical picture, so the list is left alone. The row objects behind the
  # buttons (Tag) then stay the previous refresh's, which is fine: the
  # fingerprint says they would render the same, and ServerDir - the only
  # field a click actually uses - is part of it.
  $print = New-Object System.Text.StringBuilder
  foreach ($r in @($rows)) {
    [void]$print.Append([string]$r.Label).Append('|').Append([string]$r.ServerDir).Append('|')
    [void]$print.Append([string]$r.StateText).Append('|').Append([string]$r.StateBrush).Append('|').Append([string]$r.DotBrush).Append('|')
    [void]$print.Append([string]$r.Uptime).Append('|').Append([string]$r.Meta).Append('|').Append([string]$r.Busy).Append('|')
    [void]$print.Append([string]$r.CanStart).Append([string]$r.CanStop).Append([string]$r.CanRestart).Append([string]$r.HasReport).Append('|')
    [void]$print.Append([string]$r.ReportLabel).Append('|').Append([string]$r.ReportPath).Append('|')
    # Not bound by the card, but read off the row a click hands over (the
    # quarantine sheet gates its restore button on Running): review of [R-095].
    [void]$print.Append([string]$r.Running).Append([string]$r.Supervised).Append('|').Append((@($r.Pending) -join ',')).Append('|')
    foreach ($n in @($r.Notices)) { [void]$print.Append([string]$n.Text).Append('#').Append([string]$n.Brush).Append('#').Append([string]$n.Level).Append(';') }
    [void]$print.Append("`n")
  }
  $printS = $print.ToString()
  if ($printS -ne $script:RowsPrint) {
    if (-not $script:RowsPrint) { Write-RkTrace ('panel: first cards (' + @($rows).Count + ')') }
    $ListServers.ItemsSource = $rows
    $script:RowsPrint = $printS
  }
  # Held so the sprite timer can re-pose her between refreshes without going
  # back to disk. Her pose is derived from these rows and nothing else - there
  # is no second source for "is anything wrong", which is how a mascot ends up
  # smiling at a dead server.
  $script:PanelRows = $rows
  [void](Update-RkKeeper -Window $win -Rows $rows -Tick $script:KeeperTick)
  if (@($rows).Count -eq 0) { $EmptyState.Visibility = 'Visible' } else { $EmptyState.Visibility = 'Collapsed' }

  if ($Data.SignedOut) {
    $TxtGlobal.Text = T 'global.signedOut'
    $BannerGlobal.Visibility = 'Visible'
  } else {
    $BannerGlobal.Visibility = 'Collapsed'
  }

  # THE FOOTER BUTTON NAMES WHAT IS MISSING, not a phase of setup. ClaudeReady
  # is "there is a claude command AND it is logged in", read by the same
  # background pass that draws the cards, so this costs nothing extra. Both
  # halves matter: SignedOut alone is $false when the CLI is not installed at
  # all, which would have offered to register an API key on a machine that
  # cannot reach the model either way.
  $script:ClaudeReady = [bool]$Data.ClaudeReady
  $BtnEnv.Content = $(if ($script:ClaudeReady) { T 'footer.model' } else { T 'footer.link' })

  # The time the READING STARTED, handed over by the gather - not the time this
  # line runs. Those differ by the whole gather plus the pickup delay (1.3 s
  # normally, up to ~4.5 s on a cycle that also re-walks the disk), and the
  # footer's whole job is to say how old what you are looking at is.
  $script:DataAt = $Data.At
  $stamp = ([datetime]$Data.At).ToString('HH:mm:ss')
  $TxtFooter.Text = TF 'footer.counted' @($rows).Count $stamp
}

function Show-GatherTrouble([string]$why) {
  # A refresh that keeps failing must not look like a refresh that keeps
  # agreeing with itself. Three layers were dropping the reason - EndInvoke's
  # catch, the runspace error stream, and Data.Errors - so the only symptom was
  # a footer clock that stopped, on a window that still blinks.
  $script:GatherLastErr = $why
  try {
    # MinValue FIRST: (now - MinValue).TotalSeconds does not fit an int, and
    # the cast threw INTO the empty catch below - so a window whose very
    # first read failed kept saying "loading" forever, in silence (review of
    # [R-095]).
    $age = -1
    if ($script:DataAt -ne [datetime]::MinValue) { $age = [int]((Get-Date) - $script:DataAt).TotalSeconds }
    $TxtFooter.Text = TF 'footer.stale' $why $age
  } catch { }
}

function Update-Panel {
  # The synchronous path. Still used for the FIRST paint (a window that opens
  # empty and fills in a second later looks broken in a way the freeze never
  # did), for -NoAutoRefresh, and for -RenderTo.
  param([switch]$ForceSweep)
  Apply-PanelData (Get-RkPanelData -ForceSweep:$ForceSweep)
}

function Start-PanelGather {
  if (Test-RkGatherBusy -Gather $script:Gather) { return }   # one in flight is enough
  $force   = [bool]$script:GatherForce
  # The very first read draws the cards from servers.json alone (25 ms) and
  # leaves the one-second disk walk to the second read, four seconds later -
  # so the window is showing servers, not an empty list, while the walk runs.
  $noSweep = ([bool]$script:GatherFirst) -and (-not $force)
  $script:GatherForce = $false
  $script:GatherFirst = $false
  # AddScript re-parses the text in the other runspace, so NOTHING is captured
  # from here by closure - every input is an explicit argument. The palette in
  # particular: it lives on the Window, which the other thread cannot touch,
  # and without it every card comes back in the built-in colours with no
  # exception raised.
  $ok = Start-RkGather -Gather $script:Gather -Script {
      param($ModelPath, $Colors, $ForceSweep, $NoSweep)
      if (-not (Get-Command Get-RkPanelData -ErrorAction SilentlyContinue)) { . $ModelPath }
      Set-RkPanelColorTable -Colors $Colors
      Get-RkPanelData -ForceSweep:([bool]$ForceSweep) -NoSweep:([bool]$NoSweep)
    } -Arguments @((Join-Path $PSScriptRoot 'panel-model.ps1'), (Get-RkPanelColorTable), $force, $noSweep)
  if ($ok) { return }
  # The request outlives a start that could not begin (review of [R-095]).
  if ($force) { $script:GatherForce = $true }
  if ($noSweep) { $script:GatherFirst = $true }
  # A runspace that will not open is not a reason to stop showing servers -
  # but it must not become a reason to stop being a responsive window either
  # (the first version latched the sync fallback forever, and ran the sync
  # read on every 700 ms tick while doing so). Start-RkGather has already
  # dropped the runspace and counted the failure; three in a row is not a
  # blip, so only then fall back, out loud.
  $script:GatherLastErr = $script:Gather.LastErr
  if ($script:Gather.Fails -ge 3) {
    $script:AsyncRefresh = $false
    Show-GatherTrouble $script:GatherLastErr
    Update-Panel
  } else {
    Show-GatherTrouble $script:GatherLastErr
  }
}

function Complete-PanelGather {
  $r = Complete-RkGather -Gather $script:Gather -Pick {
    param($out)
    # Only the object shaped like a refresh. Dot-sourcing the model emits
    # nothing today, but "the last thing that came out" is not a contract.
    @($out | Where-Object { $_ -and (@($_.PSObject.Properties.Name) -contains 'Rows') })[-1]
  }
  switch ($r.state) {
    'idle'    { return }
    'running' { return }
    'timeout' {
      # NOT COMING BACK. Without this the window shows pre-hang data for as
      # long as it is open, fully responsive, and the only tell is a footer
      # clock that stopped advancing. rk-async has already thrown the wedged
      # runspace away.
      Show-GatherTrouble (T 'footer.timedOut')
      if ($script:Gather.Fails -ge 3) { $script:AsyncRefresh = $false }
      return
    }
    'done' {
      $script:GatherLastErr = ''
      Apply-PanelData $r.data
      # The gather's own swallowed errors. -Once prints these; the window used
      # to throw them away, which is how "every server renders as unknown"
      # shipped once before ([R-039]).
      if (@($r.data.Errors).Count -gt 0) { Show-GatherTrouble ([string]@($r.data.Errors)[0]) }
      return
    }
    default {
      $why = [string]$r.why
      if (-not $why) { $why = (T 'footer.noResult') }
      Show-GatherTrouble $why
      if ($script:Gather.Fails -ge 3) {
        # Three failed gathers in a row: stop pretending the background path
        # works and go back to reading on this thread, where a throw is at
        # least visible in the console the panel was started from.
        $script:AsyncRefresh = $false
        Reset-RkGather -Gather $script:Gather
      }
      return
    }
  }
}

function Start-PanelPrerender {
  # Once, after the window is up. Rasterises what is missing from
  # stage\.cache in a background runspace; a second run is a directory listing.
  if (Test-RkGatherBusy -Gather $script:Prerender) { return }
  # Only for a rail that is drawn: three of the four themes collapse it.
  $railEl = $win.FindName('KeeperRail')
  if ($railEl -and $railEl.Visibility -ne 'Visible') { return }
  $sigs = @($script:Col.accent, $script:Col.amber, $script:Col.danger, $script:Col.idle, $script:Col.inkSubtle)
  [void](Start-RkGather -Gather $script:Prerender -Script {
      param($UiDir, $StagePath, $Signals)
      Add-Type -AssemblyName PresentationCore, WindowsBase
      . (Join-Path $UiDir 'rk-stage.ps1')
      $st = Read-RkStage -Path $StagePath
      $n = Initialize-RkStageCache -Stage $st -Signals $Signals
      $st = $null
      $n
    } -Arguments @($PSScriptRoot, $script:RailPath, $sigs))
}

function Request-PanelRefresh {
  # "Something just happened, show me the result." Never blocks.
  param([switch]$ForceSweep)
  if ($ForceSweep) { $script:GatherForce = $true }
  if (-not $script:AsyncRefresh) { Update-Panel -ForceSweep:$ForceSweep; return }
  $script:GatherDue = $true
}

# Card buttons live inside a DataTemplate, so FindName cannot reach them. One
# class handler on the list routes every click by name, with the row on Tag.
$ListServers.AddHandler(
  [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
  [System.Windows.RoutedEventHandler]{
    param($panelSender, $e)
    $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
    if (-not $btn) { return }
    $row = $btn.Tag
    if (-not $row) { return }
    # ONE LAUNCH PER PRESS, EVEN IF PRESSED TWICE. CanStart / CanStop are row
    # properties and only a gather recomputes them, so they stay True for the
    # whole 2.7-4 s it takes the card to catch up - and BtnStart runs a .bat
    # with no flag file behind it, so two presses really are two servers
    # starting. Stop and restart write a flag and are idempotent; this guard is
    # for the one that is not. The console's power button already does this
    # ([R-088]); same shape, same reason.
    if ($btn.Name -eq 'BtnStart') {
      $key = [string]$row.ServerDir
      $last = [datetime]::MinValue
      if ($script:LastStart.ContainsKey($key)) { $last = $script:LastStart[$key] }
      if (((Get-Date) - $last).TotalSeconds -lt 8) { return }
      $script:LastStart[$key] = Get-Date
    }
    switch ($btn.Name) {
      'BtnStart'    { Start-Detached (Join-Path $row.ServerDir 'rk-start.bat') }
      'BtnStop'     { Send-PanelSignal $row 'stop' }
      'BtnRestart'  { Send-PanelSignal $row 'maintenance' }
      'BtnConsole'  { Start-RkConsole $row.ServerDir }
      'BtnDiagnose' { Start-Detached (Join-Path $row.ServerDir 'rk-diagnose.bat') }
      'BtnReport'   { if ($row.ReportPath) { Start-Process -FilePath $row.ReportPath } }
      'BtnFolder'   { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $row.ServerDir + '"') }
      'BtnQuar'     { Show-MaintSheet 'quar'   $row; return }
      'BtnScan'     { Show-MaintSheet 'scan'   $row; return }
      'BtnPolicy'   { Show-MaintSheet 'policy' $row; return }
      'BtnName'     { Show-MaintSheet 'name'   $row; return }
    }
    # NOT a synchronous refresh. This line is why pressing a card button used
    # to feel like the app hung: it ran the whole three second read on the way
    # out of the click handler.
    #
    # But losing the freeze also lost the FEEDBACK. Measured from the tick
    # arithmetic: a card now takes 2.7 s to change after a click, or about 4 s
    # when a gather was already in flight - and in that case the first thing
    # that happens is the in-flight result landing, which was read BEFORE the
    # click and therefore redraws the card saying nothing happened. So say so
    # in the footer immediately, on this thread, where a person is looking.
    $TxtFooter.Text = T 'footer.scanning'
    Request-PanelRefresh
  })

# THE THEME BUTTON IS GONE, and it is not coming back in this shape.
#
# It relaunched the panel to pick up a new resource dictionary, which is a fair
# thing to want. What it did wrong is how: UseShellExecute = $false with
# CreateNoWindow = $true, and then $win.Close() on the next line. Started that
# way the new process is a CHILD sharing this one's console, and this one is
# about to exit. Start-Detached, four hundred lines up, exists precisely to not
# do that - read its comment: shell-execute "gives the server its own console
# window that the operator owns - not a child that dies when the panel closes."
#
# Eva pressed it and a server went down. Whatever the exact path, a button that
# only changes COLOURS has no business anywhere near process lifetimes, and the
# rule it broke was already written down in this file.
#
# The theme still works: panel-settings.json is read at startup and -Theme is
# still a parameter. It is chosen once, not toggled live. [R-070]

# ============================================================================
# ADDING A SERVER, INSIDE THE PANEL
#
# What the old button did: launch respawnkeeper.bat, which opened a console and
# asked the same questions there. Nothing was wrong with the answers - the
# problem was that the operator had to leave the window that knows about their
# servers in order to add one to it.
#
# Order matters here. The folder is READ before anything is written, the reading
# is shown, and only then is there a button that writes. Pointing this at the
# wrong folder is the one mistake worth designing against, and the only thing
# that can catch it is a person looking at what was found.
# ============================================================================
$script:AddDir    = ''
$script:AddPolicy = 'watch'
$script:AddProc   = $null

$script:SheetFontBody = 'Segoe UI'
$script:SheetFontMono = 'Consolas'
$f = $win.TryFindResource('Body'); if ($f) { $script:SheetFontBody = $f.Source }
$f = $win.TryFindResource('Mono'); if ($f) { $script:SheetFontMono = $f.Source }

function New-SheetRow {
  # Strings, not objects - a Brush built here does not survive the trip through
  # a PowerShell object into a WPF binding (see console.xaml's ItemTemplate).
  param([string]$Text, [string]$Colour = '', [switch]$Mono, [double]$Size = 13)
  if (-not $Colour) { $Colour = $script:Col.ink }
  return [pscustomobject]@{
    Text     = $Text
    Colour   = $Colour
    FontName = $(if ($Mono) { $script:SheetFontMono } else { $script:SheetFontBody })
    Size     = $Size
  }
}

function Set-AddPolicy([string]$p) {
  $script:AddPolicy = $p
  # The chosen one wears the primary style. Three buttons where one is filled in
  # is a radio group without the 1990s control.
  $BtnPolUnattended.Style = $win.TryFindResource($(if ($p -eq 'unattended') { 'BtnPrimary' } else { 'BtnSecondary' }))
  $BtnPolWatch.Style      = $win.TryFindResource($(if ($p -eq 'watch')      { 'BtnPrimary' } else { 'BtnSecondary' }))
  $BtnPolManual.Style     = $win.TryFindResource($(if ($p -eq 'manual')     { 'BtnPrimary' } else { 'BtnSecondary' }))
}

function Read-AddFolder([string]$dir) {
  # Everything shown comes from the folder. Nothing is written by this function.
  $rows = @()
  $rows += (New-SheetRow $dir $script:Col.ink -Mono -Size 12)
  $rows += (New-SheetRow '')

  $already = $false
  try {
    $reg = Read-RkJson -Path $script:PanelRegistryFile
    if ($reg -and $reg.servers) {
      foreach ($srv in @($reg.servers)) {
        if (([string]$srv).TrimEnd('\') -eq $dir.TrimEnd('\')) { $already = $true }
      }
    }
  } catch { }
  if ($already) { $rows += (New-SheetRow (T 'add.already') $script:Col.amber -Size 14) }

  $game = $null
  try { $game = Find-RkGame -ServerDir $dir } catch { }
  if (-not $game) {
    $rows += (New-SheetRow (T 'add.unknown') $script:Col.danger -Size 14)
    $rows += (New-SheetRow (T 'add.unknownHow') $script:Col.inkMuted -Size 12)
    return [pscustomobject]@{ Rows = $rows; CanAdd = $false; Game = $null }
  }

  $rows += (New-SheetRow (TF 'add.found' $game.displayName) $script:Col.accent -Size 15)

  # A template that MATCHES is not the same as a template whose every claim
  # holds. Checking now is what keeps a wrong guess from quietly driving a real
  # server later.
  $check = $null
  try { $check = Test-RkGameTemplate -ServerDir $dir -Template $game } catch { }
  $canAdd = $true
  if ($check) {
    foreach ($prob in @($check.problems)) {
      $rows += (New-SheetRow ('  x ' + $prob) $script:Col.danger -Size 12)
      $canAdd = $false
    }
    foreach ($warn in @($check.warnings)) {
      $rows += (New-SheetRow ('  ! ' + $warn) $script:Col.amber -Size 12)
    }
  }

  # Whether a clean stop has ever been WATCHED decides whether respawnkeeper is
  # allowed to restart this server on its own, so it is said out loud here
  # rather than discovered later.
  if ($game.verified -and -not $game.verified.stop) {
    $rows += (New-SheetRow (T 'add.stopUnverified') $script:Col.amber -Size 12)
  }

  $modDir = Join-Path $dir 'mods'
  if (Test-Path -LiteralPath $modDir) {
    $n = @(Get-ChildItem -LiteralPath $modDir -Filter '*.jar' -File -ErrorAction SilentlyContinue).Count
    $rows += (New-SheetRow (TF 'add.mods' $n) $script:Col.inkMuted -Size 13)
  }

  if ($canAdd) {
    $rows += (New-SheetRow '')
    $rows += (New-SheetRow (T 'add.writes') $script:Col.inkMuted -Size 12)
    foreach ($w in @('rk-start.bat', 'rk-stop.bat', 'rk-restart.bat', 'rk-diagnose.bat', 'respawnkeeper')) {
      $rows += (New-SheetRow ('  ' + $w) $script:Col.inkMuted -Mono -Size 11)
    }
    $rows += (New-SheetRow (T 'add.writesNot') $script:Col.accent -Size 12)
  }

  return [pscustomobject]@{ Rows = $rows; CanAdd = $canAdd; Game = $game }
}

function Show-AddDialog {
  Add-Type -AssemblyName System.Windows.Forms
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = T 'add.pick'
  $dlg.ShowNewFolderButton = $false
  if ($dlg.SelectedPath) { }
  if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
  $dir = $dlg.SelectedPath
  if (-not $dir) { return }

  $script:AddDir = $dir
  $TxtAddTitle.Text = T 'add.title'
  $TxtAddPolicy.Text = T 'add.policy'
  $res = Read-AddFolder $dir
  $AddDetails.ItemsSource = @($res.Rows)
  $BtnAddConfirm.IsEnabled = $res.CanAdd
  $PolicyRow.IsEnabled = $res.CanAdd
  Set-AddPolicy 'watch'
  $AddLayer.Visibility = 'Visible'
}

function Hide-AddDialog {
  $AddLayer.Visibility = 'Collapsed'
  $script:AddDir = ''
}

function Start-AddServer {
  if (-not $script:AddDir) { return }

  # rk-setup does the writing. It is the same script respawnkeeper.bat runs, in
  # its non-interactive form - deliberately NOT a second implementation of
  # "create the files", which would be one more thing to keep in step.
  #
  # -NoLaunch: adding a server must never start one. Starting is a decision a
  # person makes in front of the panel, with the button that says so.
  $setup = Join-Path $script:PanelHarnessDir 'rk-setup.ps1'
  if (-not (Test-Path -LiteralPath $setup)) {
    $AddDetails.ItemsSource = @((New-SheetRow (TF 'add.noSetup' $setup) $script:Col.danger -Size 13))
    return
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = 'powershell.exe'
  $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + $setup +
                    '" -ServerDir "' + $script:AddDir + '" -Policy ' + $script:AddPolicy +
                    ' -NonInteractive -NoLaunch')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow  = $true
  try { $script:AddProc = [System.Diagnostics.Process]::Start($psi) }
  catch {
    $AddDetails.ItemsSource = @((New-SheetRow $_.Exception.Message $script:Col.danger -Size 13))
    return
  }

  $BtnAddConfirm.IsEnabled = $false
  $PolicyRow.IsEnabled = $false
  $AddDetails.ItemsSource = @((New-SheetRow (T 'add.working') $script:Col.accent -Size 14))

  # Watched rather than waited on: a modal wait would freeze the panel, and the
  # panel is the thing that shows whether it worked.
  # $script:AddWatch, not a function local. A scriptblock made inside a function
  # is NOT a closure: when the tick fires later the function's scope is gone, so
  # the local timer variable resolved to $null and calling .Stop() on it was a
  # method call on nothing, written to a stream nobody reads (Continue).
  # Measured 2026-09-13: ticks=7, sawWatch=NULL, stillEnabled=True - the timer
  # kept running on the UI thread for the life of the window, one orphan per
  # use. Script scope is what the refresh timer below already relies on.
  if ($script:AddWatch) { try { $script:AddWatch.Stop() } catch {} }
  $script:AddWatch = New-Object System.Windows.Threading.DispatcherTimer
  $script:AddWatch.Interval = [TimeSpan]::FromMilliseconds(500)
  $script:AddWatch.Add_Tick({
      if (-not $script:AddProc -or -not $script:AddProc.HasExited) { return }
      $script:AddWatch.Stop()
      $code = $script:AddProc.ExitCode
      $script:AddProc = $null
      if ($code -eq 0) {
        # Proof, not the exit code: the files it promised are either there or
        # they are not.
        $made = @()
        foreach ($w in @('rk-start.bat', 'rk-stop.bat', 'rk-restart.bat', 'rk-diagnose.bat')) {
          if (Test-Path -LiteralPath (Join-Path $script:AddDir $w)) { $made += $w }
        }
        $AddDetails.ItemsSource = @(
          (New-SheetRow (TF 'add.done' $made.Count) $script:Col.accent -Size 15),
          (New-SheetRow ''),
          (New-SheetRow (T 'add.doneNext') $script:Col.inkMuted -Size 12)
        )
        $BtnAddCancel.Content = T 'add.close'
        # -ForceSweep: a folder that did not exist a moment ago is exactly the
        # case the 20 second sweep cache would hide.
        Request-PanelRefresh -ForceSweep
      } else {
        $AddDetails.ItemsSource = @(
          (New-SheetRow (TF 'add.failed' $code) $script:Col.danger -Size 14),
          (New-SheetRow (T 'add.failedHow') $script:Col.inkMuted -Size 12)
        )
        $BtnAddConfirm.IsEnabled = $true
        $PolicyRow.IsEnabled = $true
      }
    })
  $script:AddWatch.Start()
}

# ============================================================================
# MAINTENANCE, INSIDE THE PANEL  ([R-058])
#
# Three operations that had no button anywhere. They were reachable, but only
# by someone who remembered a command line:
#
#   quarantine  rk-repair.ps1 -ListQuarantine  /  -Undo last -Apply
#   inspect     rk-logscan.ps1
#   policy      hand-editing respawnkeeper\profile.json
#
# WHY THEY ARE HERE AND NOT IN THE CONSOLE WINDOW. The operator drew the line: the
# console window watches ONE server run. These are done TO a server, and the
# server is usually standing still while they happen.
#
# THIS IS THE FIRST PART OF THE PANEL THAT WRITES INTO A SERVER FOLDER.
# The header of this file used to say it never does. It now says "except these
# three", and the exception is kept as narrow as it can be:
#   - quarantine and inspect do not write anything themselves. They start the
#     same script a person would have typed, and then check the result.
#   - policy writes four scalars inside <ServerDir>\respawnkeeper\profile.json
#     and keeps the previous file next to it. World, mods and config are never
#     opened by any path here.
# ============================================================================
$script:MaintDir    = ''
$script:MaintScreen = ''      # quar | scan | policy
# The three switches, and what the game allows. Replaces $script:MaintPick:
# a single preset name could not express "restart yes, repair no, model yes",
# which is the combination Eva asked for.
$script:PolRestart  = $false
$script:PolRepair   = $false
$script:PolEscalate = $false
$script:PolStopOk   = $false   # has a human watched this game stop cleanly
$script:PolHookOk   = $false   # is the escalation hook on disk
$script:MaintProc   = $null
$script:MaintTarget = $null   # the quarantine entry the action is about to undo
$script:MaintMark   = [datetime]::MinValue
$script:MaintLog    = ''     # where the child script's output was captured

# The policy table used to be copied here from rk-setup.ps1, with a comment
# explaining that duplicating four values was "the smaller wrong than a button
# that lies". The copy then drifted anyway: rk-setup learned to register the
# escalation hook and this one did not, so the button DID lie - it offered
# unattended and wrote escalate=false. The table now lives once, in
# Get-RkRepolicedProfileText (panel-model.ps1), which both the sheet and any
# script can call. Removed rather than left unused: a field nobody reads is
# worse than a missing one, because it looks configured.
#
# (The original reason for the copy still stands and is why calling rk-setup
# from here is not the answer either: -NonInteractive used to keep an existing
# profile untouched and report success. That is fixed in [R-096], but rk-setup
# also rewrites rk-start.bat, which cannot be done while a server is running.)

function Get-MaintStateDir([string]$dir) { return (Join-Path $dir 'respawnkeeper') }

function Get-MaintQuarEntries([string]$dir) {
  # Read-only. The manifests ARE the preview - what a restore would put back is
  # written in them, so there is no dry run to shell out for.
  $qdir = Join-Path (Get-MaintStateDir $dir) 'quarantine'
  if (-not (Test-Path -LiteralPath $qdir)) { return @() }
  $out = @()
  foreach ($d in @(Get-ChildItem -LiteralPath $qdir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $man = Read-RkJson -Path (Join-Path $d.FullName 'MANIFEST.json')
    if (-not $man) { continue }
    $out += [pscustomobject]@{
      Stamp  = $d.Name
      Man    = $man
      Undone = ($man.undone -eq $true)
    }
  }
  return $out
}

function Build-MaintQuarRows($row) {
  $rows = @()
  $entries = @(Get-MaintQuarEntries $row.ServerDir)
  if ($entries.Count -eq 0) {
    return [pscustomobject]@{ Rows = @((New-SheetRow (T 'maint.quar.empty') $script:Col.inkMuted -Size 14)); CanAct = $false; Target = $null }
  }

  $rows += (New-SheetRow (TF 'maint.quar.count' $entries.Count) $script:Col.ink -Size 15)
  $rows += (New-SheetRow '')

  # Newest first: the one the button acts on is the one at the top.
  foreach ($e in @($entries | Sort-Object Stamp -Descending)) {
    $col = $(if ($e.Undone) { $script:Col.inkSubtle } else { $script:Col.accent })
    $rows += (New-SheetRow (TF 'maint.quar.head' $e.Stamp) $col -Mono -Size 12)
    if ($e.Man.action) { $rows += (New-SheetRow (TF 'maint.quar.action' $e.Man.action) $script:Col.inkMuted -Size 12) }
    if ($e.Man.reason) { $rows += (New-SheetRow (TF 'maint.quar.reason' $e.Man.reason) $script:Col.inkMuted -Size 12) }
    foreach ($it in @($e.Man.items)) {
      $rows += (New-SheetRow (TF 'maint.quar.file' $it.originalPath) $script:Col.inkSubtle -Mono -Size 11)
    }
    if ($e.Undone) { $rows += (New-SheetRow (T 'maint.quar.undone') $script:Col.inkSubtle -Size 11) }
    $rows += (New-SheetRow '')
  }
  $rows += (New-SheetRow (T 'maint.quar.where') $script:Col.inkMuted -Size 12)

  $target = @($entries | Where-Object { -not $_.Undone } | Sort-Object Stamp | Select-Object -Last 1)
  $target = $(if ($target.Count -gt 0) { $target[0] } else { $null })

  $canAct = $true
  if (-not $target) {
    $rows += (New-SheetRow (T 'maint.quar.nothing') $script:Col.inkMuted -Size 13)
    $canAct = $false
  } elseif ($row.Running) {
    # .Running, not .CanStop - the comment below used to say "CanStop is true
    # exactly when the server is up", and that was simply false: CanStop also
    # requires a live supervisor, so this gate opened on a running server the
    # moment the supervisor left. Restoring a jar under a
    # running server is the hot-swap this whole project exists to refuse;
    # rk-repair refuses it too, but a disabled button says WHY without making
    # someone press it to find out.
    $rows += (New-SheetRow (T 'maint.quar.running') $script:Col.amber -Size 13)
    $canAct = $false
  }
  return [pscustomobject]@{ Rows = $rows; CanAct = $canAct; Target = $target }
}

function Build-MaintScanRows($row) {
  $rows = @()
  $rows += (New-SheetRow (T 'maint.scan.what') $script:Col.ink -Size 14)
  $rows += (New-SheetRow (T 'maint.scan.safe') $script:Col.accent -Size 12)
  $rows += (New-SheetRow '')

  $repDir = Join-Path (Get-MaintStateDir $row.ServerDir) 'reports'
  $daily = @()
  $comebacks = @()
  if (Test-Path -LiteralPath $repDir) {
    $daily = @(Get-ChildItem -LiteralPath $repDir -Filter 'daily-*.md' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime)
    $comebacks = @(Get-ChildItem -LiteralPath $repDir -Filter 'comeback-*.md' -File -ErrorAction SilentlyContinue)
  }
  if ($daily.Count -gt 0) {
    $last = $daily[$daily.Count - 1]
    $rows += (New-SheetRow (TF 'maint.scan.lastDaily' ($last.Name + '  (' + $last.LastWriteTime.ToString('MM-dd HH:mm') + ')')) $script:Col.inkMuted -Size 13)
  } else {
    $rows += (New-SheetRow (T 'maint.scan.none') $script:Col.inkMuted -Size 13)
  }
  if ($comebacks.Count -gt 0) {
    $rows += (New-SheetRow (TF 'maint.scan.lastComeback' $comebacks.Count) $script:Col.amber -Size 13)
  }
  return [pscustomobject]@{ Rows = $rows; CanAct = $true; Target = $null }
}

function Build-MaintPolicyRows($row) {
  $prof = Read-RkJson -Path (Join-Path (Get-MaintStateDir $row.ServerDir) 'profile.json')
  if (-not $prof) {
    return [pscustomobject]@{ Rows = @((New-SheetRow (T 'maint.policy.noProfile') $script:Col.danger -Size 14)); CanAct = $false; Target = $null }
  }
  $yes = T 'maint.policy.yes'
  $no  = T 'maint.policy.no'
  function _yn($v) { if ($v -eq $true) { return $yes } else { return $no } }

  $name = switch ([string]$prof.profile) {
    'unattended' { T 'meta.policyUnattended' }
    'watch'      { T 'meta.policyWatch' }
    'manual'     { T 'meta.policyManual' }
    'custom'     { T 'meta.policyCustom' }
    default      { [string]$prof.profile }
  }
  $rows = @()
  $rows += (New-SheetRow (TF 'maint.policy.now' $name) $script:Col.accent -Size 15)
  $rows += (New-SheetRow '')
  $rows += (New-SheetRow (TF 'maint.policy.autoRestart' (_yn $prof.autoRestart)) $script:Col.inkMuted -Size 13)
  $rows += (New-SheetRow (TF 'maint.policy.autoRepair'  (_yn $prof.autoRepair))  $script:Col.inkMuted -Size 13)
  $rows += (New-SheetRow (TF 'maint.policy.escalate'    (_yn $prof.escalateOnHalt)) $script:Col.inkMuted -Size 13)
  $daily = $false
  if ($prof.dailyMaintenance) { $daily = ($prof.dailyMaintenance.enabled -eq $true) }
  $rows += (New-SheetRow (TF 'maint.policy.daily' (_yn $daily)) $script:Col.inkMuted -Size 13)

  # From the TEMPLATE, by the id this profile pinned - not from the copy
  # rk-setup froze into profile.json at registration time, which is how this
  # sheet came to say "no clean stop has been seen" about a game that had been
  # stopped cleanly, watched by Eva, the previous afternoon.
  $gv = Get-RkVerifiedForProfile -Profile $prof
  # Read here so the switches know what they are allowed to be before they are
  # drawn - the sheet and the file must not disagree even for one frame.
  $script:PolRestart  = ($prof.autoRestart -eq $true)
  $script:PolRepair   = ($prof.autoRepair -eq $true)
  $script:PolEscalate = ($prof.escalateOnHalt -eq $true)
  $script:PolStopOk   = [bool]$gv.stop
  $script:PolHookOk   = [bool](Test-Path -LiteralPath (Get-RkEscalationHookPath))
  $rows += (New-SheetRow '')
  $rows += (New-SheetRow (T 'maint.policy.writes') $script:Col.inkMuted -Size 12)

  return [pscustomobject]@{ Rows = $rows; CanAct = $true; Target = $prof }
}

function Set-PolicySwitches {
  # Push the three script-scope values onto the controls, and lock the ones the
  # game does not allow.
  #
  # LOCKED, NOT SILENTLY IGNORED. The old sheet let a person choose the unattended preset on
  # a game with no watched clean stop, wrote autoRestart=false anyway, and put
  # one amber line at the bottom that did not name a control. A switch that
  # cannot move now looks like it cannot move, and the reason is under it.
  $TglRestart.IsChecked  = [bool]$script:PolRestart
  $TglRepair.IsChecked   = [bool]$script:PolRepair
  $TglEscalate.IsChecked = [bool]$script:PolEscalate

  $TglRestart.IsEnabled  = [bool]$script:PolStopOk
  $TglRepair.IsEnabled   = [bool]$script:PolStopOk
  $TglEscalate.IsEnabled = [bool]$script:PolHookOk

  $locks = @()
  if (-not $script:PolStopOk) { $locks += (T 'maint.policy.lockStop') }
  if (-not $script:PolHookOk) { $locks += (T 'maint.policy.lockHook') }
  if (@($locks).Count -gt 0) {
    $TxtPolicyLock.Text = ($locks -join '  ')
    $TxtPolicyLock.Visibility = 'Visible'
  } else {
    $TxtPolicyLock.Visibility = 'Collapsed'
  }
}

function Set-PolicyFromPreset([string]$p) {
  # For -RenderMaintPick, and for anything that still thinks in preset names.
  $v = Get-RkPolicyPreset -Name $p
  $script:PolRestart  = [bool]$v.autoRestart
  $script:PolRepair   = [bool]$v.autoRepair
  $script:PolEscalate = [bool]$v.escalate
  Set-PolicySwitches
}

function Build-MaintNameRows($row) {
  # RENAMING IS NOT MOVING. What this sheet changes is serverLabel in
  # profile.json - the string the card, the console window title and the
  # supervisor's toast notifications already prefer over the folder name
  # (rk-setup writes it as the folder name at setup time, and nothing has ever
  # been able to change it since). Those three and nothing else: the watchdog
  # log and STATUS.txt name the DIRECTORY, deliberately, because they are read
  # while working out which folder to go and look in.
  # The folder on disk is untouched, which is the whole reason this is
  # safe to put behind one button: servers.json, rk-start.bat, the scheduled
  # tasks and anything outside respawnkeeper that points at that path all keep
  # working, because none of them are involved. [R-093]
  $prof = Read-RkJson -Path (Join-Path (Get-MaintStateDir $row.ServerDir) 'profile.json')
  if (-not $prof) {
    return [pscustomobject]@{ Rows = @((New-SheetRow (T 'maint.name.noProfile') $script:Col.danger -Size 14)); CanAct = $false; Target = $null }
  }
  $cur = [string]$prof.serverLabel
  if (-not $cur) { $cur = Split-Path -Leaf $row.ServerDir }
  $rows = @()
  $rows += (New-SheetRow (TF 'maint.name.now' $cur) $script:Col.accent -Size 15)
  $rows += (New-SheetRow '')
  $rows += (New-SheetRow (TF 'maint.name.folder' (Split-Path -Leaf $row.ServerDir)) $script:Col.inkMuted -Size 13)
  $rows += (New-SheetRow '')
  $rows += (New-SheetRow (T 'maint.name.writes') $script:Col.inkMuted -Size 12)
  $rows += (New-SheetRow (T 'maint.name.reopen') $script:Col.inkMuted -Size 12)
  $script:MaintNameWas = $cur
  return [pscustomobject]@{ Rows = $rows; CanAct = $true; Target = $prof }
}

# ============================================================================
# THE FLEET SHEET - what this harness supports, and who pays for the model
#
# Both screens are about the machine rather than about one server, which is why
# they are not part of Show-MaintSheet: that function is keyed to a ServerDir
# and every one of its four screens needs one. Threading a null through it to
# reach two screens that never use it would make the per-server path carry a
# case it does not have.
# ============================================================================

function Set-WalletButtons([string]$pick) {
  # The chosen one wears the primary style - same radio-without-a-radio as
  # Set-AddPolicy and the policy switches. Three places now; still worth
  # keeping separate, because each set of buttons has different labels and
  # the shared part is two lines.
  $BtnWalletSub.Style = $win.TryFindResource($(if ($pick -eq 'subscription') { 'BtnPrimary' } else { 'BtnSecondary' }))
  $BtnWalletApi.Style = $win.TryFindResource($(if ($pick -eq 'api')          { 'BtnPrimary' } else { 'BtnSecondary' }))
  # The name box only means something for the metered account. Shown rather
  # than disabled: a greyed field still invites a click.
  $ApiEnvRow.Visibility = $(if ($pick -eq 'api') { 'Visible' } else { 'Collapsed' })
}

function Build-FleetGamesRows($games) {
  $knowServers = (@($script:PanelRows).Count -gt 0)
  $rows = @()
  $list = @($games)
  if ($list.Count -eq 0) {
    return [pscustomobject]@{ Rows = @((New-SheetRow (T 'fleet.games.none') $script:Col.amber -Size 14)); CanAct = $false }
  }
  foreach ($g in $list) {
    $lvlKey = switch ([string]$g.Level) {
      'full'    { 'fleet.games.levelFull' }
      'partial' { 'fleet.games.levelPartial' }
      'broken'  { 'fleet.games.levelBroken' }
      default   { 'fleet.games.levelNone' }
    }
    # The colour IS the level. Same rule the cards follow: say it twice, once in
    # words and once in colour, because colour alone is not readable by everyone.
    $lvlCol = switch ([string]$g.Level) {
      'full'    { $script:Col.accent }
      'partial' { $script:Col.amber }
      'broken'  { $script:Col.danger }
      default   { $script:Col.inkSubtle }
    }
    $rows += (New-SheetRow ([string]$g.Name) $script:Col.ink -Size 15)
    $rows += (New-SheetRow ('  ' + (T $lvlKey)) $lvlCol -Size 12)
    if ([int]$g.On -lt 0) {
      $rows += (New-SheetRow ('  ' + (T 'fleet.games.countsUnknown')) $script:Col.amber -Size 12)
    } else {
      $rows += (New-SheetRow ('  ' + (TF 'fleet.games.counts' $g.On $g.Blocked $g.Off)) $script:Col.inkMuted -Size 12)
    }
    $used = @($g.Servers | Where-Object { $_ })
    if ($used.Count -gt 0) {
      $rows += (New-SheetRow ('  ' + (TF 'fleet.games.inUse' ($used -join ', '))) $script:Col.accent -Size 12)
    } elseif ($knowServers) {
      $rows += (New-SheetRow ('  ' + (T 'fleet.games.notInUse')) $script:Col.inkSubtle -Size 12)
    } else {
      # "not used here" and "the list of servers has not arrived yet" are
      # different answers. The window opens before the first read lands, and
      # this sheet is clickable immediately.
      $rows += (New-SheetRow ('  ' + (T 'fleet.games.usersUnknown')) $script:Col.amber -Size 12)
    }
    $rows += (New-SheetRow '')
  }
  $rows += (New-SheetRow (T 'fleet.games.legend') $script:Col.inkMuted -Size 12)
  return [pscustomobject]@{ Rows = $rows; CanAct = $false }
}

function Build-FleetModelRows($wallet) {
  $rows = @()
  if (-not $wallet) {
    return [pscustomobject]@{ Rows = @((New-SheetRow (T 'footer.noResult') $script:Col.danger -Size 14)); CanAct = $false }
  }
  if (-not $wallet.CliPresent) {
    $rows += (New-SheetRow (T 'fleet.model.cliMissing') $script:Col.danger -Size 14)
  } elseif ($wallet.SignedIn) {
    $rows += (New-SheetRow (T 'fleet.model.cliIn') $script:Col.accent -Size 14)
  } else {
    $rows += (New-SheetRow (T 'fleet.model.cliOut') $script:Col.amber -Size 14)
  }
  $rows += (New-SheetRow '')
  if ([string]$wallet.Backend -eq 'api') {
    $rows += (New-SheetRow (TF 'fleet.model.nowApi' ([string]$wallet.ApiKeyEnv)) $script:Col.ink -Size 13)
  } else {
    $rows += (New-SheetRow (T 'fleet.model.nowSub') $script:Col.ink -Size 13)
  }
  if ($wallet.Mixed) { $rows += (New-SheetRow (T 'fleet.model.mixed') $script:Col.amber -Size 12) }
  if ([int]$wallet.Count -le 0) {
    $rows += (New-SheetRow (T 'fleet.model.nothing') $script:Col.amber -Size 12)
  }
  # The subtitle is already under the title (TxtFleetWho). It was here too, so
  # the sheet said the same sentence twice, four lines apart - caught by
  # rendering it rather than by reading the code.
  # CanAct is false with nothing registered: an apply button that would write to
  # zero files is a button that reports success for doing nothing.
  return [pscustomobject]@{ Rows = $rows; CanAct = ([int]$wallet.Count -gt 0) }
}

function Update-ApiEnvState {
  # Whether the NAME currently in the box resolves to a value on this machine.
  # It never reads the value itself, and there is nowhere for it to go if it
  # did: this line says "set" or "not set" and nothing else.
  $n = ''
  try { $n = ([string]$TxtApiEnvInput.Text).Trim() } catch { }
  if (-not $n) { $TxtApiEnvState.Text = ''; return }
  $has = $false
  try {
    $v = [System.Environment]::GetEnvironmentVariable($n)
    if (-not $v) { $v = [System.Environment]::GetEnvironmentVariable($n, 'User') }
    if (-not $v) { $v = [System.Environment]::GetEnvironmentVariable($n, 'Machine') }
    $has = [bool]$v
  } catch { }
  # !! DO NOT REPEAT THE BOX BACK UNLESS IT IS A VARIABLE NAME. It used to be
  # echoed twice, once inside a ready-to-run `setx {0} "(key)"` - so pasting a
  # key printed 64 characters of it on screen and offered it back as a command.
  # A valid variable name cannot be a key (a key has hyphens), so validating
  # first makes the echo safe; anything else is described, never quoted.
  if ($n -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') {
    $TxtApiEnvState.Text = T 'fleet.model.envBadName'
    return
  }
  if ($has) {
    $TxtApiEnvState.Text = (TF 'fleet.model.envSet' $n)
  } else {
    $TxtApiEnvState.Text = (TF 'fleet.model.envUnset' $n) + '  ' + (TF 'fleet.model.keyWarn' $n)
  }
}

function Show-FleetSheet([string]$screen) {
  $script:FleetScreen = $screen
  $TxtFleetTitle.Text = T ('fleet.' + $screen + '.title')
  $TxtFleetWho.Text   = T ('fleet.' + $screen + '.sub')
  $BtnFleetClose.Content = T 'fleet.close'
  # Everything below is filled in when the background read lands. The sheet
  # opens IMMEDIATELY saying it is counting, rather than after two seconds of
  # nothing - the same choice the window itself makes on first paint.
  $FleetDetails.ItemsSource = @((New-SheetRow (T 'fleet.games.loading') $script:Col.inkMuted -Size 13))
  $WalletRow.Visibility     = 'Collapsed'
  $BtnFleetAction.Visibility = $(if ($screen -eq 'model') { 'Visible' } else { 'Collapsed' })
  $BtnFleetAction.Content    = T 'fleet.model.apply'
  $BtnFleetAction.IsEnabled  = $false
  $FleetLayer.Visibility = 'Visible'
  Start-FleetGather $screen
}

function Hide-FleetSheet {
  $FleetLayer.Visibility = 'Collapsed'
  $WalletRow.Visibility  = 'Collapsed'
  $script:FleetScreen = ''
}

function Start-FleetGather([string]$screen) {
  if (Test-RkGatherBusy -Gather $script:FleetGather) { $script:FleetWant = $screen; return }
  $script:FleetWant = ''
  # The directories come from the rows already in hand, so opening this sheet
  # never pays for a disk walk of its own.
  $dirs = @()
  foreach ($r in @($script:PanelRows)) { if ($r.ServerDir) { $dirs += [string]$r.ServerDir } }
  $ok = Start-RkGather -Gather $script:FleetGather -Script {
      param($ModelPath, $Screen, $Dirs)
      if (-not (Get-Command Get-RkSupportedGames -ErrorAction SilentlyContinue)) { . $ModelPath }
      if ($Screen -eq 'games') {
        @{ screen = 'games'; games = @(Get-RkSupportedGames -ServerDirs $Dirs) }
      } else {
        @{ screen = 'model'; wallet = (Get-RkModelWallet -ServerDirs $Dirs) }
      }
    } -Arguments @((Join-Path $PSScriptRoot 'panel-model.ps1'), $screen, $dirs)
  if (-not $ok) {
    $FleetDetails.ItemsSource = @((New-SheetRow (TF 'footer.stale' $script:FleetGather.LastErr 0) $script:Col.danger -Size 13))
  }
}

function Complete-FleetGather {
  $r = Complete-RkGather -Gather $script:FleetGather -Pick {
      param($out)
      foreach ($o in @($out)) { if ($o -is [hashtable] -and $o.ContainsKey('screen')) { return $o } }
      return $null
    }
  if ($r.state -eq 'idle' -or $r.state -eq 'running') { return }
  # The handle is free now, so a screen that asked while it was busy gets its
  # turn. Before the visibility check, or closing the first sheet cancels the
  # second one's read as well.
  if ($script:FleetWant) {
    $want = $script:FleetWant
    $script:FleetWant = ''
    if (($FleetLayer.Visibility -eq 'Visible') -and ($want -eq $script:FleetScreen)) { Start-FleetGather $want }
  }
  # A sheet closed while its read was in flight must not repaint itself open.
  if ($FleetLayer.Visibility -ne 'Visible') { return }
  if ($r.state -ne 'done' -or (-not $r.data)) {
    $why = $r.why; if (-not $why) { $why = T 'footer.noResult' }
    $FleetDetails.ItemsSource = @((New-SheetRow $why $script:Col.danger -Size 13))
    return
  }
  $d = $r.data
  # The answer to a question that is no longer on screen is not an answer.
  if ([string]$d.screen -ne $script:FleetScreen) { return }

  if ([string]$d.screen -eq 'games') {
    $res = Build-FleetGamesRows $d.games
    $FleetDetails.ItemsSource = @($res.Rows)
    return
  }

  $w = $d.wallet
  $script:FleetWallet = $w
  $res = Build-FleetModelRows $w
  $FleetDetails.ItemsSource = @($res.Rows)
  $TxtWalletPick.Text  = T 'fleet.model.pick'
  $BtnWalletSub.Content = T 'fleet.model.optSub'
  $BtnWalletApi.Content = T 'fleet.model.optApi'
  $TxtApiEnvPick.Text  = T 'fleet.model.envPick'
  $TxtApiEnvInput.Text = [string]$w.ApiKeyEnv
  $script:FleetPick    = [string]$w.Backend
  Set-WalletButtons $script:FleetPick
  Update-ApiEnvState
  $WalletRow.Visibility     = $(if ($w.CliPresent -or ([string]$w.Backend -eq 'api')) { 'Visible' } else { 'Collapsed' })
  $BtnFleetAction.IsEnabled = [bool]$res.CanAct
}

function Invoke-WalletApply {
  # Writes the model block into every registered profile. This is the one place
  # the panel writes into a server folder for an ACCOUNT-wide reason. The file
  # work is Set-RkProfileWallet (panel-model.ps1), which the self-test drives
  # directly; what is left here is "for each row, call it and count", so one
  # unreadable profile is reported and the rest still get written.
  $pick = $script:FleetPick
  # Only two values exist. Anything else came from a profile nobody validated,
  # and passing it on hits a [ValidateSet] that throws out of the Click handler.
  if (($pick -ne 'subscription') -and ($pick -ne 'api')) { return }
  $envName = ''
  try { $envName = ([string]$TxtApiEnvInput.Text).Trim() } catch { }
  if (-not $envName) { $envName = 'ANTHROPIC_API_KEY' }

  $done = 0
  $bad  = @()
  $rows = @($script:PanelRows)
  if (@($rows).Count -eq 0) {
    # The window now opens before the first read lands, so this list can be
    # empty while servers.json holds three. Writing to nothing and reporting
    # success is worse than saying the list is not in yet.
    $FleetDetails.ItemsSource = @((New-SheetRow (T 'footer.loading') $script:Col.amber -Size 14))
    return
  }
  foreach ($row in $rows) {
    if (-not $row.ServerDir) { continue }
    $pf = Join-Path (Get-MaintStateDir $row.ServerDir) 'profile.json'
    # A SKIPPED SERVER IS NOT A WRITTEN ONE. This used to `continue` in silence,
    # so a folder that had been moved left the fleet inconsistent while the
    # sheet said "2 written" and the "these disagree" warning had just been
    # replaced by the result.
    if (-not (Test-Path -LiteralPath $pf)) { $bad += ($row.Label + ': ' + (T 'fleet.model.noProfile')); continue }
    $res = $null
    try { $res = Set-RkProfileWallet -ProfileFile $pf -Backend $pick -ApiKeyEnv $envName }
    catch { $bad += ($row.Label + ': ' + $_.Exception.Message); continue }
    if ($res.ok) { $done++ } else { $bad += ($row.Label + ': ' + $res.reason) }
  }

  $rows = @()
  if ($done -gt 0) { $rows += (New-SheetRow (TF 'fleet.model.applied' $done) $script:Col.accent -Size 14) }
  foreach ($b in $bad) { $rows += (New-SheetRow (TF 'fleet.model.failed' $b) $script:Col.danger -Size 13) }
  if ($rows.Count -eq 0) { $rows += (New-SheetRow (T 'fleet.model.nothing') $script:Col.amber -Size 13) }
  $rows += (New-SheetRow '')
  if ($pick -eq 'api') {
    $rows += (New-SheetRow (TF 'fleet.model.keyWarn' $envName) $script:Col.amber -Size 12)
  }
  $FleetDetails.ItemsSource = @($rows)
  $BtnFleetAction.IsEnabled = $false
  # The cards carry no wallet, so nothing else on screen is stale - but the
  # footer button might be, if this run also signed in.
  $script:GatherForce = $true
  $script:GatherDue   = $true
}

function Show-MaintSheet([string]$screen, $row) {
  $script:MaintScreen = $screen
  $script:MaintDir    = $row.ServerDir
  $TxtMaintTitle.Text = T ('maint.title.' + $screen)
  $TxtMaintWho.Text   = $row.Label + '  -  ' + $row.ServerDir

  $res = switch ($screen) {
    'quar'   { Build-MaintQuarRows   $row }
    'scan'   { Build-MaintScanRows   $row }
    'policy' { Build-MaintPolicyRows $row }
    'name'   { Build-MaintNameRows   $row }
  }
  $script:MaintTarget = $res.Target

  # @() twice on purpose: PowerShell unwraps a one-element array on assignment,
  # and ItemsSource then gets a bare PSCustomObject and throws.
  $rows = @($res.Rows)
  $MaintDetails.ItemsSource = @($rows)

  $actionKey = switch ($screen) {
    'quar'   { 'maint.quar.restore' }
    'scan'   { 'maint.scan.run' }
    'name'   { 'maint.name.apply' }
    default  { 'maint.policy.apply' }
  }
  $BtnMaintAction.Content   = T $actionKey
  $BtnMaintAction.IsEnabled = $res.CanAct
  $BtnMaintClose.Content    = T 'maint.close'

  if ($screen -eq 'name' -and $res.CanAct) {
    $TxtNamePick.Text     = T 'maint.name.pick'
    $TxtNameInput.Text    = $script:MaintNameWas
    $NameRow.Visibility   = 'Visible'
    # Re-enabled on every open: a successful rename disables the row, and a
    # sheet that stays disabled the next time it is opened is a dead button.
    $NameRow.IsEnabled    = $true
    # Selected, not just focused: the first thing anyone does here is replace
    # the whole word "server", and making them clear it by hand first is the
    # difference between a rename box and a chore.
    [void]$TxtNameInput.Focus()
    $TxtNameInput.SelectAll()
  } else {
    $NameRow.Visibility = 'Collapsed'
  }

  if ($screen -eq 'policy' -and $res.CanAct) {
    $TxtMaintPick.Text       = T 'maint.policy.pick'
    $TxtMaintPick.Visibility = 'Visible'
    $MaintPolicyRow.Visibility = 'Visible'
    $TxtTglRestart.Text  = T 'maint.policy.tglRestart'
    $TxtTglRepair.Text   = T 'maint.policy.tglRepair'
    $TxtTglEscalate.Text = T 'maint.policy.tglEscalate'
    $TxtWhyRestart.Text  = T 'maint.policy.whyRestart'
    $TxtWhyRepair.Text   = T 'maint.policy.whyRepair'
    $TxtWhyEscalate.Text = T 'maint.policy.whyEscalate'
    Set-PolicySwitches
  } else {
    $TxtMaintPick.Visibility   = 'Collapsed'
    $MaintPolicyRow.Visibility = 'Collapsed'
  }
  $MaintLayer.Visibility = 'Visible'
}

function Hide-MaintSheet {
  $MaintLayer.Visibility = 'Collapsed'
  $NameRow.Visibility    = 'Collapsed'
  $script:MaintScreen = ''
  $script:MaintDir    = ''
  $script:MaintTarget = $null
}

function Start-MaintProcess([string]$argline) {
  # Same shape as the add sheet: launched and WATCHED, never waited on. A modal
  # wait freezes the window that is supposed to show whether it worked.
  #
  # WHY THE OUTPUT IS KEPT. rk-repair is THE gate in front of every write to a
  # server, and it can refuse for reasons this panel does not know about. It
  # refused a restore during this sheet's own first run, and the only thing the
  # sheet could say was "exit code 1" - while the script had printed the actual
  # answer: "REFUSING to touch a running server. port 25565 is LISTENING". The
  # panel must not re-decide a safety question; it must repeat what the
  # authority said.
  #
  # Redirected through cmd rather than RedirectStandardOutput, for the same
  # reason the maintenance hook does it: reading a redirected stream while the
  # child is still writing is a deadlock waiting to be scheduled.
  $script:MaintLog = [System.IO.Path]::GetTempFileName()
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = 'cmd.exe'
  $psi.Arguments = ('/c powershell.exe -NoProfile -ExecutionPolicy Bypass ' + $argline +
                    ' > "' + $script:MaintLog + '" 2>&1')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow  = $true
  try { $script:MaintProc = [System.Diagnostics.Process]::Start($psi) }
  catch {
    $MaintDetails.ItemsSource = @((New-SheetRow $_.Exception.Message $script:Col.danger -Size 13))
    return $false
  }
  $BtnMaintAction.IsEnabled  = $false
  $MaintPolicyRow.IsEnabled  = $false
  return $true
}

function Get-MaintSaid {
  # The last few things the script said, for a failure line to stand next to.
  # Capped because a stack trace is not an explanation and fills the sheet.
  $rows = @()
  if (-not $script:MaintLog) { return $rows }
  if (-not (Test-Path -LiteralPath $script:MaintLog)) { return $rows }
  $said = @()
  try {
    # PowerShell prints a throw as five lines, four of which are furniture:
    # the source location, the offending source text, a row of tildes under it,
    # CategoryInfo and FullyQualifiedErrorId. The message is the first line.
    # Showing the rest buries it - which is the failure this capture exists to
    # fix, repeated one level down.
    $said = @(Get-Content -LiteralPath $script:MaintLog -ErrorAction SilentlyContinue |
              Where-Object { $_ -and $_.Trim() -ne '' } |
              Where-Object { $_ -notmatch '^\s*\+' } |
              Where-Object { $_ -notmatch 'CategoryInfo|FullyQualifiedErrorId' } |
              Where-Object { $_ -notmatch '\.ps1:\d+' } |
              Select-Object -First 6)
  } catch { }
  foreach ($line in $said) {
    $rows += (New-SheetRow ('  ' + $line.Trim()) $script:Col.inkMuted -Mono -Size 11)
  }
  try { Remove-Item -LiteralPath $script:MaintLog -Force -ErrorAction SilentlyContinue } catch { }
  $script:MaintLog = ''
  return $rows
}

function Complete-MaintQuar([int]$code) {
  # The exit code is what the script THINKS happened. What actually happened is
  # whether the files are back where the manifest said they belonged.
  $back = 0
  if ($script:MaintTarget) {
    foreach ($it in @($script:MaintTarget.Man.items)) {
      if ($it.originalPath -and (Test-Path -LiteralPath $it.originalPath)) { $back++ }
    }
  }
  if ($back -gt 0) {
    $MaintDetails.ItemsSource = @(
      (New-SheetRow (TF 'maint.quar.done' $back) $script:Col.accent -Size 15),
      (New-SheetRow ''),
      (New-SheetRow (T 'maint.quar.doneNext') $script:Col.inkMuted -Size 12)
    )
  } else {
    $rows = @((New-SheetRow (TF 'maint.quar.failed' $code) $script:Col.danger -Size 14))
    $rows += @(Get-MaintSaid)
    $MaintDetails.ItemsSource = @($rows)
  }
}

function Complete-MaintScan([int]$code) {
  $repDir = Join-Path (Get-MaintStateDir $script:MaintDir) 'reports'
  $fresh = $null
  if (Test-Path -LiteralPath $repDir) {
    $fresh = @(Get-ChildItem -LiteralPath $repDir -Filter 'daily-*.md' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -gt $script:MaintMark } |
               Sort-Object LastWriteTime | Select-Object -Last 1)
    $fresh = $(if ($fresh.Count -gt 0) { $fresh[0] } else { $null })
  }
  if ($fresh) {
    $MaintDetails.ItemsSource = @(
      (New-SheetRow (TF 'maint.scan.done' $fresh.Name) $script:Col.accent -Size 15),
      (New-SheetRow ''),
      (New-SheetRow (T 'maint.scan.doneNext') $script:Col.inkMuted -Size 12)
    )
  } else {
    $rows = @((New-SheetRow (TF 'maint.scan.failed' $code) $script:Col.danger -Size 14))
    $rows += @(Get-MaintSaid)
    $MaintDetails.ItemsSource = @($rows)
  }
}

function Set-MaintProfile {
  # A SURGICAL edit, not a round trip. Reading profile.json into an object and
  # writing it back would re-encode every Japanese string in it - warnMessage
  # among them - into \uXXXX escapes. Still valid JSON, still read correctly by
  # the harness, and still a file the operator can no longer read. Four lines change;
  # every other byte is left exactly where it was.
  $pf = Join-Path (Get-MaintStateDir $script:MaintDir) 'profile.json'
  $prof = Read-RkJson -Path $pf
  if (-not $prof) {
    $MaintDetails.ItemsSource = @((New-SheetRow (T 'maint.policy.noProfile') $script:Col.danger -Size 14))
    return
  }
  # The switches ARE the answer now; the name is derived from them. "Already
  # this policy" is therefore a comparison of three booleans, not of a label -
  # two different combinations used to share the name 'custom' and one of them
  # would have been refused as "no change".
  $want = Get-RkPolicyName -AutoRestart $script:PolRestart -AutoRepair $script:PolRepair -Escalate $script:PolEscalate
  if ((($prof.autoRestart -eq $true) -eq $script:PolRestart) -and
      (($prof.autoRepair -eq $true) -eq $script:PolRepair) -and
      (($prof.escalateOnHalt -eq $true) -eq $script:PolEscalate) -and
      ([string]$prof.profile -eq $want)) {
    $MaintDetails.ItemsSource = @((New-SheetRow (T 'maint.policy.same') $script:Col.inkMuted -Size 14))
    return
  }

  # ONE IMPLEMENTATION OF "WHAT DOES THIS POLICY MEAN", shared with anything
  # else that has to write it. It used to live here as an inline edit list, and
  # the copy in rk-setup.ps1 knew one thing this one did not: how to REGISTER
  # the escalation hook. So the sheet offered "unattended" - whose whole point
  # is that an unmatched crash goes to the model - and then silently turned that
  # half off, because escalationHook was empty and only rk-setup ever wrote it.
  # The sheet said unattended, the file said escalate=false, and nothing
  # explained the gap.
  $raw = [System.IO.File]::ReadAllText($pf, [System.Text.Encoding]::UTF8)
  $gv  = Get-RkVerifiedForProfile -Profile $prof
  $res = Get-RkRepolicedProfileText -Raw $raw `
           -AutoRestart $script:PolRestart -AutoRepair $script:PolRepair -Escalate $script:PolEscalate `
           -StopVerified ([bool]$gv.stop) -HookPath (Get-RkEscalationHookPath)
  if (-not $res.ok) {
    $MaintDetails.ItemsSource = @((New-SheetRow (TF 'maint.policy.failed' $res.reason) $script:Col.danger -Size 14))
    return
  }

  try {
    Copy-Item -LiteralPath $pf -Destination ($pf + '.bak') -Force -ErrorAction Stop
    # -ErrorAction Stop is not enough on its own: with a DIRECTORY at the .bak
    # path Copy-Item copies INTO it and reports success. Check the result.
    if (-not (Test-Path -LiteralPath ($pf + '.bak') -PathType Leaf)) { throw ('the backup did not end up at ' + $pf + '.bak') }
    [System.IO.File]::WriteAllText($pf, $res.text, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    $MaintDetails.ItemsSource = @((New-SheetRow (TF 'maint.policy.failed' $_.Exception.Message) $script:Col.danger -Size 14))
    return
  }

  # Read it back off the disk. The value we set is not evidence; the file is.
  $after = Read-RkJson -Path $pf
  if ((-not $after) -or ([string]$after.profile -ne $want)) {
    $MaintDetails.ItemsSource = @((New-SheetRow (TF 'maint.policy.failed' 'readback') $script:Col.danger -Size 14))
    return
  }
  $name = switch ($want) {
    'unattended' { T 'meta.policyUnattended' }
    'watch'      { T 'meta.policyWatch' }
    'manual'     { T 'meta.policyManual' }
    default      { $want }
  }
  $MaintDetails.ItemsSource = @((New-SheetRow (TF 'maint.policy.applied' $name) $script:Col.accent -Size 15))
  $BtnMaintAction.IsEnabled = $false
  Request-PanelRefresh
}

function Set-MaintName {
  # The same surgical edit Set-MaintProfile makes, and for the same reason: a
  # read-modify-write round trip through ConvertTo-Json would re-encode every
  # Japanese string already in this file into \uXXXX escapes. One line changes.
  $pf = Join-Path (Get-MaintStateDir $script:MaintDir) 'profile.json'
  $prof = Read-RkJson -Path $pf
  if (-not $prof) {
    $MaintDetails.ItemsSource = @((New-SheetRow (T 'maint.name.noProfile') $script:Col.danger -Size 14))
    return
  }

  $want = [string]$TxtNameInput.Text
  if ($want) { $want = $want.Trim() }
  if (-not $want) {
    $MaintDetails.ItemsSource = @((New-SheetRow (T 'maint.name.empty') $script:Col.danger -Size 14))
    return
  }
  # A newline inside a JSON string is not legal JSON, and a tab in a card title
  # is a layout bug nobody would connect back to this box. Rejected rather than
  # silently stripped: the operator should see what they typed be refused.
  if ($want -match '[\x00-\x1F\x7F]') {
    $MaintDetails.ItemsSource = @((New-SheetRow (T 'maint.name.bad') $script:Col.danger -Size 14))
    return
  }
  if ($want -eq [string]$prof.serverLabel) {
    $MaintDetails.ItemsSource = @((New-SheetRow (T 'maint.name.same') $script:Col.inkMuted -Size 14))
    return
  }

  # The edit itself is in panel-model.ps1 as a pure string -> string function,
  # so the self-test can hammer it (including the twelve label shapes that used
  # to come back as "failed: parse") without opening a window.
  $raw = [System.IO.File]::ReadAllText($pf, [System.Text.Encoding]::UTF8)
  $made = Get-RkRelabeledProfileText -Raw $raw -Label $want
  if (-not $made.ok) {
    $MaintDetails.ItemsSource = @((New-SheetRow (TF 'maint.name.failed' $made.reason) $script:Col.danger -Size 14))
    return
  }

  $bak = $pf + '.bak'
  try {
    Copy-Item -LiteralPath $pf -Destination $bak -Force
    [System.IO.File]::WriteAllText($pf, $made.text, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    $MaintDetails.ItemsSource = @((New-SheetRow (TF 'maint.name.failed' $_.Exception.Message) $script:Col.danger -Size 14))
    return
  }

  # Read it back off the disk. The value we set is not evidence; the file is.
  #
  # AND PUT IT BACK IF THE READBACK FAILS. Everything above this point fails
  # BEFORE the file is touched; this is the one branch that can be reached with
  # the file already rewritten, and the previous version simply said "failed:
  # readback" and left it that way - with a perfectly good copy sitting in .bak
  # that it had made itself and never mentioned.
  $after = Read-RkJson -Path $pf
  if ((-not $after) -or ([string]$after.serverLabel -ne $want)) {
    $restored = $false
    try { Copy-Item -LiteralPath $bak -Destination $pf -Force; $restored = $true } catch { $restored = $false }
    $why = 'readback'
    if ($restored) { $why = 'readback' + (T 'maint.name.rolledBack') }
    $MaintDetails.ItemsSource = @((New-SheetRow (TF 'maint.name.failed' $why) $script:Col.danger -Size 14))
    return
  }

  # The sheet's own header still carries the label the card was showing when it
  # was opened. Left alone, the screen says "renamed to X" directly under the
  # old name, and the success line has already replaced every other row.
  $TxtMaintWho.Text = $want + '  -  ' + $script:MaintDir
  $MaintDetails.ItemsSource = @((New-SheetRow (TF 'maint.name.applied' $want) $script:Col.accent -Size 15))
  $script:MaintNameWas = $want
  $BtnMaintAction.IsEnabled = $false
  $NameRow.IsEnabled = $false
  Request-PanelRefresh
}

function Invoke-MaintAction {
  switch ($script:MaintScreen) {
    'name'   { Set-MaintName;    return }
    'policy' { Set-MaintProfile; return }
    'quar' {
      if (-not $script:MaintTarget) { return }
      $rep = Join-Path $script:PanelHarnessDir 'rk-repair.ps1'
      $ok = Start-MaintProcess ('-File "' + $rep + '" -ServerDir "' + $script:MaintDir + '" -Undo last -Apply')
      if (-not $ok) { return }
      $MaintDetails.ItemsSource = @((New-SheetRow (T 'maint.quar.working') $script:Col.accent -Size 14))
    }
    'scan' {
      $scan = Join-Path $script:PanelHarnessDir 'rk-logscan.ps1'
      $script:MaintMark = [datetime]::Now.AddSeconds(-2)
      $ok = Start-MaintProcess ('-File "' + $scan + '" -ServerDir "' + $script:MaintDir + '"')
      if (-not $ok) { return }
      $MaintDetails.ItemsSource = @((New-SheetRow (T 'maint.scan.working') $script:Col.accent -Size 14))
    }
    default { return }
  }

  # Same orphan as Start-AddServer's watcher, same reason - see the note there.
  if ($script:MaintWatch) { try { $script:MaintWatch.Stop() } catch {} }
  $script:MaintWatch = New-Object System.Windows.Threading.DispatcherTimer
  $script:MaintWatch.Interval = [TimeSpan]::FromMilliseconds(500)
  $script:MaintWatch.Add_Tick({
      if (-not $script:MaintProc -or -not $script:MaintProc.HasExited) { return }
      $script:MaintWatch.Stop()
      $code = $script:MaintProc.ExitCode
      $script:MaintProc = $null
      if ($script:MaintScreen -eq 'quar') { Complete-MaintQuar $code } else { Complete-MaintScan $code }
      $MaintPolicyRow.IsEnabled = $true
      Request-PanelRefresh
    })
  $script:MaintWatch.Start()
}

# THE ONLY TEXT BOX IN THE PROGRAM, and until this was added, Enter did nothing
# in it - which is the second thing a person does after typing a name, and the
# classic "the app ignored me". Escape closes, matching every other sheet's
# close button. Handled here rather than with IsDefault/IsCancel on the buttons,
# because those two buttons are shared with the quarantine and inspect sheets,
# where Enter would fire a restore.
$TxtNameInput.Add_PreviewKeyDown({
    param($keySender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return -or $e.Key -eq [System.Windows.Input.Key]::Enter) {
      $e.Handled = $true
      if ($BtnMaintAction.IsEnabled) { Invoke-MaintAction }
    } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
      $e.Handled = $true
      Hide-MaintSheet
    }
  })

$BtnMaintClose.Add_Click({      Hide-MaintSheet })
$BtnMaintAction.Add_Click({     Invoke-MaintAction })
# The switches are the control now. Each click only records the intent - the
# vetoes are applied once, in Get-RkRepolicedProfileText, where the file is
# written. Doing them here as well would be two implementations of one rule.
$TglRestart.Add_Click({  $script:PolRestart  = [bool]$TglRestart.IsChecked })
$TglRepair.Add_Click({   $script:PolRepair   = [bool]$TglRepair.IsChecked })
$TglEscalate.Add_Click({ $script:PolEscalate = [bool]$TglEscalate.IsChecked })

$BtnAdd.Add_Click({           Show-AddDialog })
$BtnAddCancel.Add_Click({     Hide-AddDialog })
$BtnAddConfirm.Add_Click({    Start-AddServer })
$BtnPolUnattended.Add_Click({ Set-AddPolicy 'unattended' })
$BtnPolWatch.Add_Click({      Set-AddPolicy 'watch' })
$BtnPolManual.Add_Click({     Set-AddPolicy 'manual' })
# ONE BUTTON, TWO JOBS, decided by what is actually missing (Apply-EnvState).
# Not signed in -> open finish-setup, which is where a person types a
# credential; signed in -> open the wallet sheet. The click reads the same
# state the label was drawn from, so a stale label cannot dispatch to the
# wrong action.
$BtnEnv.Add_Click({
    if ($script:ClaudeReady) { Show-FleetSheet 'model' }
    else { Start-Detached (Join-Path $RepoDir 'finish-setup.bat') }
  })
$BtnGames.Add_Click({ Show-FleetSheet 'games' })
$BtnFleetClose.Add_Click({ Hide-FleetSheet })
$BtnFleetAction.Add_Click({ Invoke-WalletApply })
# The action button is re-armed by a change of mind. It is disabled after an
# apply, and the choice buttons stayed live - so changing the pick afterwards
# highlighted a selection with no way to commit it, and $script:FleetPick then
# disagreed with both the disk and the result rows on screen.
$BtnWalletSub.Add_Click({ $script:FleetPick = 'subscription'; Set-WalletButtons 'subscription'; $BtnFleetAction.IsEnabled = $true })
$BtnWalletApi.Add_Click({ $script:FleetPick = 'api'; Set-WalletButtons 'api'; Update-ApiEnvState; $BtnFleetAction.IsEnabled = $true })
$TxtApiEnvInput.Add_TextChanged({ Update-ApiEnvState })
$BtnFixGlobal.Add_Click({ Start-Detached (Join-Path $RepoDir 'finish-setup.bat') })
# There is no refresh button. Update-Panel is on a four second timer just
# below, so the button only ever bought impatience. [R-070]
#
# THE FIRST PAINT IS NOT SYNCHRONOUS ANY MORE when the timer will run. It was
# kept synchronous in [R-091] ("a window that opens empty and fills in a
# second later looks broken") - and cost 4.8 s of blank, unresponsive window
# before the first frame, measured 2026-09-13, which is what Eva meant by
# "opening it is quite slow". The window now opens at once with the footer
# saying it is reading, the keeper already on the rail, and the cards arrive
# from the first background read - about a second later, drawn from the
# registry without the disk walk. -NoAutoRefresh and -RenderTo still read
# synchronously: there, nothing else will ever fill the window in.
if ($NoAutoRefresh -or $RenderTo) {
  Update-Panel
} else {
  $TxtFooter.Text = T 'footer.loading'
  $EmptyState.Visibility = 'Collapsed'
  [void](Update-RkKeeper -Window $win -Rows @() -Tick 0)
  # Update-RkKeeper's caption for zero rows is "nobody to watch", which is not
  # what an unread list means; say what is actually happening.
  $kl = $win.FindName('KeeperLine'); if ($kl) { $kl.Text = T 'footer.loading' }
}

# -RenderTo is excluded now that a tick can start a background gather: the
# rasteriser pumps the dispatcher (PushFrame, below) to let item containers
# generate, and a refresh landing inside that pump would swap ItemsSource
# halfway through measuring it. Before this the two timers were started and
# then abandoned, which made every offscreen render a race it happened to win.
if ((-not $NoAutoRefresh) -and (-not $RenderTo)) {
  # 4s of DATA age: fast enough that "did it come back up?" is answered by
  # looking, slow enough that the liveness probe is not a load of its own.
  #
  # The TIMER is 700ms and is not the refresh - it is the pickup. Each tick
  # asks a finished gather for its result (IsCompleted, one bool) and starts
  # the next one when the last one is 4 seconds old or somebody pressed
  # something. Polling at the data interval instead would age every result by
  # a whole extra period before it was ever shown.
  $script:AsyncRefresh = $true
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(700)
  $timer.Add_Tick({
      # The warm-up's result is not used; it only has to be collected so the
      # handle is released and a failure is not left dangling.
      if (Test-RkGatherBusy -Gather $script:Prerender) {
        $pr = Complete-RkGather -Gather $script:Prerender -Pick { param($out) $true }
        # Done or dead: the runspace is dropped, or it would keep every bitmap
        # it decoded alive for the life of the window (136 MB measured for the
        # console's room; review of [R-095]).
        if ($pr.state -ne 'running') { Close-RkGather -Gather $script:Prerender }
      }
      if (Test-RkGatherBusy -Gather $script:FleetGather) { Complete-FleetGather }
      if (-not $script:AsyncRefresh) {
        # THE SYNC FALLBACK IS A MODE, NOT A LATCH. Three failures in a row
        # put the window here; it reads on this thread on the old four second
        # cadence (the [R-091] freeze, knowingly, with the reason in the
        # footer) and tries the background path again a minute later. The
        # first version set AsyncRefresh false and nothing ever set it back,
        # so one bad minute became a frozen window for the rest of its life
        # (review of [R-095]).
        if ($script:FallbackAt -eq [datetime]::MinValue) { $script:FallbackAt = Get-Date }
        if (((Get-Date) - $script:Gather.Started).TotalSeconds -ge 4) {
          $script:Gather.Started = Get-Date
          try { Update-Panel } catch { Show-GatherTrouble $_.Exception.Message }
        }
        if (((Get-Date) - $script:FallbackAt).TotalSeconds -ge 60) {
          $script:FallbackAt = [datetime]::MinValue
          $script:Gather.Fails = 0
          $script:AsyncRefresh = $true
        }
        return
      }
      Complete-PanelGather
      if (Test-RkGatherBusy -Gather $script:Gather) { return }
      if ($script:GatherDue -or (((Get-Date) - $script:Gather.Started).TotalSeconds -ge 4)) {
        $script:GatherDue = $false
        Start-PanelGather
      }
    })
  $timer.Start()
  # The first read starts NOW, not on the first tick 700 ms from now - and the
  # frame warm-up right behind it, so by the time the sign first pulses its
  # dimmed frame is already a PNG on disk.
  Start-PanelGather
  Start-PanelPrerender
  $win.Add_Closed({
      $timer.Stop()
      # NOTHING HERE MAY BLOCK. This handler runs on the dispatcher thread and
      # everything after it - $anim.Stop(), and the Unregister that releases
      # panel.lock - is downstream of it.
      #
      # The first version called $script:GatherPs.Dispose() with the comment
      # "the runspace holds a thread, leaving it behind is how a panel becomes
      # something you hunt in Task Manager". Measured 2026-09-13: Dispose stops
      # the pipeline and WAITS for it, and if the pipeline is inside a native
      # child process it waits for the child - 28,468 ms against a `ping -n 30`
      # stand-in, on the dispatcher thread, with no exception. The gather runs
      # `claude auth status` (340-486 ms measured) on every pass, so the line
      # written to avoid a stuck process was the one creating a frozen window
      # AND holding panel.lock, which makes the console's "back to the list"
      # button chase a window that is already gone. Close-RkGather is
      # CloseAsync only, for that reason.
      Close-RkGather -Gather $script:Gather
      Close-RkGather -Gather $script:Prerender
      Close-RkGather -Gather $script:FleetGather
    })

  # The keeper's own clock. Separate from the refresh because they answer
  # different questions: the 4s timer asks the disk what changed, this one only
  # advances a frame index against rows already in hand and swaps in a cached
  # bitmap. 400ms is the coarsest tick at which a blink still reads as a blink;
  # anything faster is a costume, which is the line [R-043] drew.
  $anim = New-Object System.Windows.Threading.DispatcherTimer
  $anim.Interval = [TimeSpan]::FromMilliseconds(400)
  $anim.Add_Tick({
      $script:KeeperTick++
      [void](Update-RkKeeper -Window $win -Rows $script:PanelRows -Tick $script:KeeperTick)
    })
  $anim.Start()
  $win.Add_Closed({ $anim.Stop() })
}

# -RenderTo: the same window, the same data, rasterised instead of shown. The
# add-a-server sheet is only reachable through a folder picker, so -RenderAdd
# takes the folder directly - otherwise the one screen that writes files would
# be the one screen that could never be looked at before shipping ([R-040]).
if ($RenderTo) {
  $timer = $null
  if ($RenderAdd) {
    $script:AddDir = $RenderAdd
    $TxtAddTitle.Text  = T 'add.title'
    $TxtAddPolicy.Text = T 'add.policy'
    $res = Read-AddFolder $RenderAdd
    $AddDetails.ItemsSource = @($res.Rows)
    $BtnAddConfirm.IsEnabled = $res.CanAdd
    $PolicyRow.IsEnabled = $res.CanAdd
    Set-AddPolicy 'watch'
    $AddLayer.Visibility = 'Visible'
  }

  if ($RenderFleet) {
    # Same door as -RenderMaint, for the same reason: a sheet only reachable by
    # clicking is a sheet nobody looks at before shipping it. This one needs one
    # extra thing - it fills itself from a BACKGROUND read, and a window that is
    # never shown gets no timer ticks, so the gather is pumped here rather than
    # waited on by a clock that will not run.
    Show-FleetSheet $RenderFleet
    $deadline = (Get-Date).AddSeconds(120)
    while ((Test-RkGatherBusy -Gather $script:FleetGather) -and ((Get-Date) -lt $deadline)) {
      Start-Sleep -Milliseconds 150
      Complete-FleetGather
    }
    if ($RenderFleetPick) {
      $script:FleetPick = $RenderFleetPick
      Set-WalletButtons $RenderFleetPick
      if ($RenderFleetPick -eq 'api') { Update-ApiEnvState }
    }
  }

  if ($RenderMaint) {
    # Same reason -RenderAdd exists: these sheets are reachable only by clicking
    # a card, so without a door from the command line the three screens that
    # actually change something would be the three nobody could look at before
    # shipping them ([R-040]).
    $mdir = $RenderMaintDir
    if (-not $mdir) { $mdir = @(Get-RkKnownServers)[0] }
    if ($mdir) {
      Show-MaintSheet $RenderMaint (Get-RkPanelRow -ServerDir $mdir)
      if ($RenderMaintPick) { Set-PolicyFromPreset $RenderMaintPick }

      # -RenderMaintDo actually presses it. Two of these three sheets write, and
      # a write path nobody has run is not a write path anybody has checked -
      # the picture only proves the sheet DRAWS. It is a separate switch from
      # -RenderMaint on purpose, and it is used against a throwaway server dir.
      if ($RenderMaintDo) {
        Invoke-MaintAction
        # The action for quarantine is a child process; give it its own pump
        # rather than the 500ms timer, which never ticks in a window that is
        # never shown.
        if ($script:MaintProc) {
          [void]$script:MaintProc.WaitForExit(120000)
          $rc = $script:MaintProc.ExitCode
          $script:MaintProc = $null
          if ($script:MaintScreen -eq 'quar') { Complete-MaintQuar $rc } else { Complete-MaintScan $rc }
        }
      }
    }
  }

  $w = [int]$win.Width; $h = [int]$win.Height
  if ($w -le 0) { $w = 1084 }
  if ($h -le 0) { $h = 830 }
  $root = $win.Content
  $win.Content = $null
  $root.Measure((New-Object System.Windows.Size($w, $h)))
  $root.Arrange((New-Object System.Windows.Rect(0, 0, $w, $h)))
  $root.UpdateLayout()

  # Item containers are generated on the dispatcher, and UpdateLayout does not
  # drain a queue - without this the sheet renders empty. Measured, not guessed.
  $frame = New-Object System.Windows.Threading.DispatcherFrame
  [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle,
        [action]{ $frame.Continue = $false })
  [System.Windows.Threading.Dispatcher]::PushFrame($frame)
  $root.Measure((New-Object System.Windows.Size($w, $h)))
  $root.Arrange((New-Object System.Windows.Rect(0, 0, $w, $h)))
  $root.UpdateLayout()

  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $dv = New-Object System.Windows.Media.DrawingVisual
  $dc = $dv.RenderOpen()
  $bg = $win.TryFindResource('Canvas')
  if (-not $bg) { $bg = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#121212')) }
  $dc.DrawRectangle($bg, $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
  $dc.Close()
  $rtb.Render($dv)
  $rtb.Render($root)

  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $fs = [System.IO.File]::Open($RenderTo, 'Create')
  try { $enc.Save($fs) } finally { $fs.Close() }
  Write-Host ('rendered ' + $w + 'x' + $h + ' -> ' + $RenderTo)
  exit 0
}

# The panel says it is open, so the console's "back to the list" button can
# raise this window instead of starting a second panel next to it.
[void](Register-RkUiWindow -LockFile (Get-RkPanelLockFile) -ScriptPattern (Get-RkPanelScriptPattern))
$win.Add_Closed({ Unregister-RkUiWindow -LockFile (Get-RkPanelLockFile) })
try { [void]$win.ShowDialog() } finally { Unregister-RkUiWindow -LockFile (Get-RkPanelLockFile) }
