# ============================================================
# rk-console.ps1 - the server console window. ASCII only (PS 5.1 decodes a
# BOM-less .ps1 as ANSI; Japanese lives in panel-strings.ja.json).
#
# WHY THIS EXISTS. respawnkeeper launches Minecraft with `nogui`, so the server's
# own Swing window never opens and the only face it has is a console. This is
# the replacement for that face.
#
# IT DOES NOT OWN THE SERVER, and that is the whole design:
#
#   read   tail logs\latest.log, which the server writes anyway.
#   write  drop one file per command into respawnkeeper\console-in\; the
#          supervisor, which already holds the stdin pipe (it needs it to send
#          "stop"), picks them up within half a second.
#
# So closing this window does nothing to the server, opening it against an
# already-running server works, and two of them can be open at once. The
# alternative - launching java from here with redirected pipes - would make
# "closed the window" and "killed the server" the same gesture.
#
#   powershell -STA -File harness\ui\rk-console.ps1 -ServerDir "<dir>"
#   powershell -File harness\ui\rk-console.ps1 -ServerDir "<dir>" -Once
# ============================================================

param(
  [Parameter(Mandatory)][string]$ServerDir,
  # The supervisor that opened this window, if one did. RECORDED, NOT OBEYED.
  #
  # 2026-09-12 ([R-073]): nothing used to close this window, so every supervisor
  # run left another one on the desktop forever. The fix was for the window to
  # end itself once this pid was gone - the supervisor keeps no handle to it, so
  # the window was the only party that could clean up.
  #
  # 2026-09-13 ([R-088]): that made STOPPING THE SERVER FROM THIS WINDOW close
  # the window, and the start button went with it - press stop, and the thing
  # you would press to start it again is gone. The window now outlives its
  # supervisor. The duplicate it was preventing is prevented on the other side
  # instead: this window registers itself in console.lock and the supervisor
  # does not open a second one while that registration is alive.
  #
  # So this pid is kept only for the log line below. Nothing acts on it, and the
  # window does not care whether the supervisor it belongs to is the one that
  # opened it - every screen here is derived from disk, so a supervisor that
  # started ten minutes after this window drives it just as well.
  [int]$SupervisorPid = 0,
  [string]$Theme = '',
  [int]$Backlog = 300,        # lines of history to show on open
  [switch]$Once,              # print what the window would show, and exit
  [string]$RenderTo = '',     # rasterise the real window to a PNG and exit
  [ValidateSet('', 'players', 'vitals', 'report', 'diag', 'command', 'attend', 'remove')]
  [string]$RenderTablet = '', # with -RenderTo: open this tablet screen first
  [switch]$RenderMin,         # with -RenderTo: render at the smallest size the
                              # window can be dragged to, not the default one
  [double]$RenderScroll = 0   # with -RenderTablet: scroll the tablet down this
                              # many pixels first, so a still picture can show
                              # what the middle of a long screen looks like
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'panel-model.ps1')
. (Join-Path $PSScriptRoot 'rk-stage.ps1')
. (Join-Path $PSScriptRoot 'rk-async.ps1')
. (Join-Path $PSScriptRoot 'rk-players.ps1')
. (Join-Path $PSScriptRoot 'rk-vitals.ps1')

$ServerDir = (Resolve-Path -LiteralPath $ServerDir).Path
Write-RkTrace 'console: model loaded'
$StateDir  = Join-Path $ServerDir 'respawnkeeper'

# CLAIM THE WINDOW BEFORE DOING SEVEN SECONDS OF WORK, not after.
#
# The claim used to be taken on the last line before ShowDialog. Measured
# 2026-09-13: everything above that line costs 4.4s (-Once) to 6.9s (full XAML
# and layout), and for all of it this window was invisible to the registry - so
# two launches inside that window both opened. The folder is known here, which
# is all the claim needs.
#
# -Once and -RenderTo are excluded by hand rather than by position: neither is a
# window anybody is looking at, and claiming to be one would stop a real
# supervisor from opening a real one.
#
# It is released twice over on the way out: Add_Closed for the ordinary case and
# a finally for ShowDialog throwing. Both are safe to run because Unregister
# deletes only a registration that positively names this process.
if ((-not $Once) -and (-not $RenderTo)) {
  [void](Register-RkUiWindow -LockFile (Get-RkConsoleLockFile -ServerDir $ServerDir) -ScriptPattern 'rk-console\.ps1')
}
$QueueDir  = Join-Path $StateDir 'console-in'

# ---- which log, and whose answer is that ------------------------------------
# This used to be Join-Path $ServerDir 'logs\latest.log', a path only Minecraft
# writes. On every other game the window opened onto a file that does not exist
# and showed an empty log - which is what a quiet server looks like. [R-071].
#
# Get-RkLogFile (lib\rk-common.ps1) is the one place that knows where a given
# game's log is: per-template paths, newest-match globs, and the console
# respawnkeeper captured itself when the game writes no file at all. When it is
# not loaded, Get-RkUiLogSource falls back to the old hardcoded path and says
# so - $script:LogMode is 'legacy' and the window prints a line about it.
$script:Game      = Get-RkUiTemplate -ServerDir $ServerDir
$script:LogFile   = $null
$script:LogMode   = ''
$script:LogLookup = [datetime]::MinValue

function Update-RkLogSource {
  # Re-asks where the log is. Called on open, and again while the window is up
  # whenever there is no log yet: a server that starts AFTER the console does
  # creates its log (or its capture file) minutes later, and a window that
  # resolved once would stay blank for the rest of the evening.
  param([switch]$Force)
  if (-not $Force) {
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) { return }
    if (([datetime]::Now - $script:LogLookup).TotalSeconds -lt 5) { return }
  }
  $script:LogLookup = [datetime]::Now
  $src = Get-RkUiLogSource -ServerDir $ServerDir -Template $script:Game
  if ([string]$src.Path -ne [string]$script:LogFile) {
    # A different file means the old byte offset points into the wrong stream.
    $script:LogPos = 0
    $script:LogLen = 0
  }
  $script:LogFile = $src.Path
  $script:LogMode = $src.Mode
}
Update-RkLogSource -Force
$LogFile = $script:LogFile   # for messages that just want to name it
$Label     = Split-Path -Leaf $ServerDir
$prof = Read-RkJson -Path (Join-Path $StateDir 'profile.json')
if ($prof -and $prof.serverLabel) { $Label = [string]$prof.serverLabel }

# ---- reading the log --------------------------------------------------------
# Opened FileShare ReadWrite|Delete every time, and never held between polls.
# [R-041] is the record of what happens otherwise: something reading a log kept
# the writer from appending, and the lost lines looked exactly like code that
# never ran. A console that breaks the log it is showing is worse than no
# console.
$script:LogPos = 0
$script:LogLen = 0

function Read-RkLogChunk {
  param([switch]$FromStart)

  Update-RkLogSource
  if (-not $script:LogFile) { return @() }
  if (-not (Test-Path -LiteralPath $script:LogFile)) { return @() }
  $bytes = $null
  try {
    $fs = New-Object System.IO.FileStream($script:LogFile, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
      $len = $fs.Length
      # Shrunk means the server rotated latest.log (it does that on every boot).
      # Reading from the old offset would show the middle of a sentence.
      if ($len -lt $script:LogPos) { $script:LogPos = 0 }
      $from = $(if ($FromStart) { 0 } else { $script:LogPos })
      if ($len -le $from) { $script:LogLen = $len; return @() }
      [void]$fs.Seek($from, [System.IO.SeekOrigin]::Begin)
      $count = [int]($len - $from)
      $bytes = New-Object 'byte[]' $count
      [void]$fs.Read($bytes, 0, $count)
      $script:LogPos = $len
      $script:LogLen = $len
    } finally { $fs.Close() }
  } catch { return @() }

  # Same decision as rk-logscan: decode UTF-8, and if the replacement character
  # appears, this is not UTF-8 - fc8's Forge log is Shift-JIS. Valid UTF-8 never
  # decodes to U+FFFD.
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($text.IndexOf([char]0xFFFD) -ge 0) { $text = [System.Text.Encoding]::Default.GetString($bytes) }
  return @($text -split "`r?`n" | Where-Object { $_ -ne '' })
}

function Get-RkLineLevel([string]$line) {
  # Deliberately crude. This colours a log, it does not parse one: three levels
  # a person can scan for, and everything else stays quiet so the two that
  # matter stand out.
  if ($line -cmatch '/(ERROR|FATAL)\]|\bException\b|^\s+at [\w\.$]+\(') { return 'error' }
  if ($line -cmatch '/WARN\]|\bWARN\b') { return 'warn' }
  return 'info'
}

# ---- sending a command ------------------------------------------------------
function Test-RkStdinOwner {
  # Can anything actually deliver what gets typed? Only the supervisor holds the
  # server's stdin, and it only holds it while it is running - so the question
  # is whether the pid in server.pid is alive. A server started by hand from
  # run.bat has nobody holding a pipe, and the honest answer there is "read
  # only", not a text box that swallows commands.
  $pf = Join-Path $StateDir 'server.pid'
  if (-not (Test-Path -LiteralPath $pf)) { return $false }
  $id = 0
  try { $id = [int]((Get-Content -LiteralPath $pf -Raw).Trim()) } catch { return $false }
  if ($id -le 0) { return $false }
  try { $p = Get-Process -Id $id -ErrorAction Stop } catch { return $false }
  return ($null -ne $p)
}

$script:CmdSeq = 0
function Send-RkConsoleCommand([string]$line) {
  $line = $line.Trim()
  if (-not $line) { return $false }
  if (-not (Test-Path -LiteralPath $QueueDir)) { New-Item -ItemType Directory -Force -Path $QueueDir | Out-Null }
  # Name carries the order: the supervisor replays them sorted by name, and a
  # counter breaks ties inside the same millisecond.
  $script:CmdSeq++
  $name = ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff') + '-' + $script:CmdSeq.ToString('000') + '.cmd')
  try {
    [System.IO.File]::WriteAllText((Join-Path $QueueDir $name), $line, (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch { return $false }
}

function Get-RkPendingCommands {
  # Files still sitting in the spool mean nothing is draining it. Shown rather
  # than hidden: a command that went nowhere must not look like one that was
  # obeyed.
  if (-not (Test-Path -LiteralPath $QueueDir)) { return 0 }
  return @(Get-ChildItem -LiteralPath $QueueDir -Filter '*.cmd' -File -ErrorAction SilentlyContinue).Count
}

# ---- what the stage should be showing --------------------------------------
# THE ROW IS READ IN THE BACKGROUND ([R-095]). Get-RkPanelRow for one server
# cost 1.4-3.5 s on this machine (measured 2026-09-13, port probe + CIM), and
# this window called it ON THE DISPATCHER THREAD every two seconds - so the
# console was frozen most of the time it was open, which is what Eva was
# looking at when she said the app "still freezes a little" after the panel
# had been fixed. Same shape as the panel now: a runspace reads, a timer
# picks the result up, the dispatcher thread only applies.
$script:LastRow    = $null
$script:RowGather  = New-RkGather -Name 'row' -DeadlineSec 60
$script:RowDue     = $false
$script:RowAt      = [datetime]::MinValue
$script:RowFailSaid = [datetime]::MinValue

function Start-RowGather {
  if (Test-RkGatherBusy -Gather $script:RowGather) { return }
  [void](Start-RkGather -Gather $script:RowGather -Script {
      param($ModelPath, $Colors, $Dir)
      if (-not (Get-Command Get-RkPanelRow -ErrorAction SilentlyContinue)) { . $ModelPath }
      Set-RkPanelColorTable -Colors $Colors
      Get-RkPanelRow -ServerDir $Dir
    } -Arguments @((Join-Path $PSScriptRoot 'panel-model.ps1'), (Get-RkPanelColorTable), $ServerDir))
}

function Complete-RowGather {
  # $true when a fresh row landed.
  $r = Complete-RkGather -Gather $script:RowGather -Pick {
    param($out)
    @($out | Where-Object { $_ -and (@($_.PSObject.Properties.Name) -contains 'ServerDir') })[-1]
  }
  if ($r.state -eq 'done') {
    if ($null -eq $script:LastRow) { Write-RkTrace 'console: first row' }
    $script:LastRow = $r.data; $script:RowAt = Get-Date; return $true
  }
  if ($r.state -eq 'failed' -or $r.state -eq 'timeout') {
    # Said once, then at most once a minute: a server that is down and a
    # read that keeps failing would otherwise add a line every two seconds,
    # forever, into a pane whose cap only trims when the LOG grows.
    if (((Get-Date) - $script:RowFailSaid).TotalSeconds -ge 60) {
      $script:RowFailSaid = Get-Date
      Add-ConsoleNotice ('[respawnkeeper] ' + (TF 'console.readFailed' $r.why)) $script:Col.amber
    }
    if ($script:RowGather.Fails -ge 3) { Reset-RkGather -Gather $script:RowGather }
  }
  return $false
}

function Get-RkConsoleState {
  # One server, so this is simpler than the panel's fleet-wide question, and it
  # is derived from the same row so the two windows can never disagree. The row
  # is whatever the last background read brought back; $null before the first
  # one lands, which the window shows as "reading", not as "stopped".
  $row = $script:LastRow
  if (-not $row) { return [pscustomobject]@{ Pose = 'sleep'; Brush = $script:Col.inkSubtle; Line = (T 'console.loading'); Row = $null } }
  $st = Get-RkKeeperState -Rows @($row)
  return [pscustomobject]@{ Pose = $st.Pose; Brush = $st.Brush; Line = $st.Line; Row = $row }
}

# ---- -Once: everything the window would show, with no window ----------------
# English on purpose: this is the developer's view, it is ASCII-safe, and it is
# the only place the three states can be READ OFF rather than inferred from a
# rendered picture. Anything that says "not available" here must say so in the
# window too - that pairing is what the completion check for [R-071] tests.
if ($Once) {
  $lines = @(Read-RkLogChunk -FromStart)
  $tail = @($lines | Select-Object -Last 12)
  Write-Host ('server   : ' + $Label + '  (' + $ServerDir + ')')
  Write-Host ('game     : ' + $(if ($script:Game -and $script:Game.id) { [string]$script:Game.id } else { '(no template matched this folder)' }))
  if ($script:LogFile) {
    Write-Host ('log      : ' + $script:LogFile + '  ' + $lines.Count + ' lines, ' + [int]($script:LogLen / 1KB) + ' KB')
  } else {
    Write-Host ('log      : NOT AVAILABLE - no readable log for this game. The window shows this as a reason, not as an empty console.')
    $w = Get-RkCapabilityWhy -Requirement 'logStream'
    if ($w) { Write-Host ('           why: ' + $w) }
  }
  # The probe's own reasons, not just its verdict. A liveness answer that is
  # wrong for one refresh (seen once on 2026-09-13 against the Valheim folder,
  # not reproduced) can only be understood from what the probe SAID it saw.
  $lv = $null
  try { $lv = Get-RkServerLiveness -ServerDir $ServerDir -Template $script:Game } catch { }
  if ($lv) {
    Write-Host ('alive    : ' + $lv.alive + $(if (@($lv.reasons).Count -gt 0) { '  (' + (@($lv.reasons) -join ' | ') + ')' } else { '  (no probe matched)' }))
    foreach ($x in @($lv.excluded)) { Write-Host ('           excluded: ' + $x) }
  }
  $sup = $null
  try { $sup = Get-RkSupervisor -ServerDir $ServerDir } catch { }
  if ($sup -and $sup.alive) { Write-Host ('watcher  : supervisor alive (' + $sup.reason + ')') }
  else { Write-Host ('watcher  : NO supervisor - stop/restart buttons are disabled (' + $(if ($sup) { $sup.reason } else { 'could not check' }) + ')') }
  $pend = @()
  try { $pend = @(Get-RkPendingSignals -ServerDir $ServerDir) } catch { }
  if ($pend.Count -gt 0) { Write-Host ('pending  : ' + ($pend -join ', ') + ' (flag written, not yet picked up)') }
  Write-Host ('log src  : ' + $script:LogMode + $(if ($script:LogMode -eq 'legacy') { '  (Get-RkLogFile not loaded - using the pre-[R-071] hardcoded logs\latest.log)' } else { '' }))

  # The roster and the vitals row are the two readouts that used to render
  # "could not measure" as good news, so -Once prints their measured/unmeasured
  # flags rather than only their numbers.
  $r = New-RkRoster
  try { $r = Initialize-RkRoster -Roster $r -ServerDir $ServerDir -Template $script:Game } catch { }
  $rs = Get-RkRosterStatus -Roster $r
  if ($rs.Available) {
    Write-Host ('players  : ' + $rs.Count + ' online   (evidence: ' + $rs.Evidence + '; read: ' + $rs.Source + ')')
  } else {
    Write-Host ('players  : NOT AVAILABLE [' + $rs.Reason + '] - this is NOT zero players')
    if ($rs.Why)    { Write-Host ('           why: ' + $rs.Why) }
    if ($rs.Detail) { Write-Host ('           detail: ' + $rs.Detail) }
  }

  $v = $null
  try { $v = Get-RkVitals -ServerDir $ServerDir -Template $script:Game } catch { }
  if ($v) {
    Write-Host ('vitals   : uptime ' + $v.UptimeMin + ' min, mem ' + $v.MemMB + ' MB' + $(if (-not $v.ProcMeasured) { '  (process not measured - no live pid)' } else { '' }))
    if ($v.LagMeasured) {
      Write-Host ('           lag ' + $v.LagCount + ' hit(s) in the last ' + $v.ScannedKB + ' KB, worst ' + $v.WorstMs + ' ms')
    } else {
      Write-Host ('           lag NOT MEASURED [' + $v.UnmetReason + '] - this is NOT "no lag recorded"')
      if ($v.UnmetWhy) { Write-Host ('           why: ' + $v.UnmetWhy) }
    }
  }

  Write-Host ('stdin    : ' + $(if (Test-RkStdinOwner) { 'the supervisor is holding it - commands can be sent' } else { 'nobody is holding it - read only' }))
  Write-Host ('queued   : ' + (Get-RkPendingCommands))
  try { $script:LastRow = Get-RkPanelRow -ServerDir $ServerDir } catch { }
  $cs = Get-RkConsoleState
  Write-Host ('stage    : ' + $cs.Pose + '  ' + $cs.Brush + '  ' + $cs.Line)
  Write-Host ''
  foreach ($l in $tail) { Write-Host ('  ' + (Get-RkLineLevel $l).PadRight(5) + ' ' + $l) }
  exit 0
}

# ---- the window -------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# The console follows whatever skin the panel is wearing, so the two windows are
# recognisably one program.
$SettingsFile = Join-Path $PSScriptRoot 'panel-settings.json'
if (-not $Theme) {
  $stg = Read-RkJson -Path $SettingsFile
  if ($stg -and $stg.theme) { $Theme = [string]$stg.theme } else { $Theme = 'eve' }
}

# The supervisor starts this script with CREATE_NO_WINDOW (see
# Start-RkConsoleWindow), so from 2026-09-13 there is no console for Write-Host
# to reach: a failure here would be a window that silently never appears, and
# the supervisor cannot tell the difference because it deliberately keeps no
# handle on this process. So the reason goes to a file the operator can find
# next to the rest of this server's respawnkeeper state.
function Write-RkConsoleFatal {
  param([string]$Message)
  Write-Host ('FATAL: ' + $Message)   # still useful under -Once, from a real console
  try {
    $stateDir = Join-Path $ServerDir 'respawnkeeper'
    if (Test-Path -LiteralPath $stateDir -PathType Container) {
      Add-Content -LiteralPath (Join-Path $stateDir 'console-window.err.log') `
                  -Value ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] pid ' + $PID + ' ' + $Message)
    }
  } catch { }
}

try { $win = New-RkPanelWindow -Theme $Theme -XamlFile 'console.xaml' }
catch { Write-RkConsoleFatal ('console.xaml failed to load: ' + $_.Exception.Message); exit 2 }

Write-RkTrace 'console: window built'
$win.Add_ContentRendered({ Write-RkTrace 'console: window shown' })
$TxtTitle     = $win.FindName('TxtTitle')
$TxtSub       = $win.FindName('TxtSub')
$LogList      = $win.FindName('LogList')
$LogScroll    = $win.FindName('LogScroll')
$StageHost    = $win.FindName('StageHost')
$StageFrame   = $win.FindName('StageFrame')
$StageCard    = $win.FindName('StageCard')
$BtnBlock     = $win.FindName('BtnBlock')
$BtnGrid      = $win.FindName('BtnGrid')
$RootGrid     = $win.FindName('RootGrid')
$ColLeft      = $win.FindName('ColLeft')
$ColRight     = $win.FindName('ColRight')
$TxtStageLine = $win.FindName('TxtStageLine')
$TxtCommand   = $win.FindName('TxtCommand')
$BtnSend      = $win.FindName('BtnSend')
$TxtCmdNote   = $win.FindName('TxtCmdNote')
$BtnPower     = $win.FindName('BtnPower')
$PowerRow     = $win.FindName('PowerRow')
$BtnMaint     = $win.FindName('BtnMaint')
$BtnPanel     = $win.FindName('BtnPanel')
$BtnDiagnose  = $win.FindName('BtnDiagnose')
$BtnReport    = $win.FindName('BtnReport')
$BtnFolder    = $win.FindName('BtnFolder')

$TabletLayer     = $win.FindName('TabletLayer')
$TxtTabletTitle  = $win.FindName('TxtTabletTitle')
$TabletList      = $win.FindName('TabletList')
$TabletScroll    = $win.FindName('TabletScroll')
$BtnTabletClose  = $win.FindName('BtnTabletClose')
$TabletActions   = $win.FindName('TabletActions')
$BtnTabletConfirm = $win.FindName('BtnTabletConfirm')
$TabletInput     = $win.FindName('TabletInput')
$BtnTabPlayers   = $win.FindName('BtnTabPlayers')
$BtnTabVitals    = $win.FindName('BtnTabVitals')
$BtnTabCommand   = $win.FindName('BtnTabCommand')
$BtnTabAttend    = $win.FindName('BtnTabAttend')
$BtnTabRemove    = $win.FindName('BtnTabRemove')

$TxtTitle.Text = $Label
$win.Title = ($Label + ' - respawnkeeper console')

# Read the theme's own colours into the shared table. Without this the console
# used panel-model.ps1's built-in defaults no matter which theme was loaded.
Set-RkPanelPalette -Window $win

# STRINGS, not Brush objects. See the note on the LogLine template.
$lineColour = @{
  info  = $script:Col.logInk
  warn  = $script:Col.amber
  error = $script:Col.danger
}

# Bounded on purpose. A Minecraft server writes tens of thousands of lines in an
# evening, and an ItemsControl that keeps all of them turns the window into a
# memory leak with a scrollbar.
$MaxLines = 2000
$Lines = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$LogList.ItemsSource = $Lines

# ---- who is on the server ---------------------------------------------------
# Folded from history ONCE (see rk-players.ps1 for why latest.log alone is not
# enough), then kept current by the very lines this window is already reading.
# Watching the roster therefore costs one extra regex per log line and nothing
# else - no second file handle, no timer, and nothing sent to the server.
#
# The fold also decides whether this game HAS a readable roster at all. When it
# does not, the roster refuses to collect names and says why, instead of sitting
# at zero and being read as "nobody is playing" ([R-071], playerRoster.note in
# lib\rk-capabilities.psd1).
# THE HISTORY FOLD RUNS IN THE BACKGROUND. Initialize-RkRoster reads the
# whole current log and every archived .log.gz since the server started -
# 2.2 s for pokemoncraft, measured 2026-09-13 - and it ran here, before the
# window existed. Now the window opens first; the fold lands on a timer, and
# every line the live tail saw in the meantime is folded in after it, in
# order. Until then the players tablet says it is still reading, which is
# true, rather than "nobody is online", which would not be.
$script:Roster        = New-RkRoster
$script:RosterReady   = $false
$script:RosterPending = New-Object System.Collections.ArrayList
$script:RosterGather  = New-RkGather -Name 'roster' -DeadlineSec 180
[void](Start-RkGather -Gather $script:RosterGather -Script {
    param($ModelPath, $PlayersPath, $Dir)
    if (-not (Get-Command Get-RkUiTemplate -ErrorAction SilentlyContinue)) { . $ModelPath }
    if (-not (Get-Command Initialize-RkRoster -ErrorAction SilentlyContinue)) { . $PlayersPath }
    $r = New-RkRoster
    Initialize-RkRoster -Roster $r -ServerDir $Dir -Template (Get-RkUiTemplate -ServerDir $Dir)
  } -Arguments @((Join-Path $PSScriptRoot 'panel-model.ps1'), (Join-Path $PSScriptRoot 'rk-players.ps1'), $ServerDir))

function Complete-RosterGather {
  if ($script:RosterReady) { return }
  $r = Complete-RkGather -Gather $script:RosterGather -Pick {
    param($out)
    @($out | Where-Object { $_ -and (@($_.PSObject.Properties.Name) -contains 'Names') })[-1]
  }
  if ($r.state -eq 'running' -or $r.state -eq 'idle') { return }
  if ($r.state -eq 'done') { $script:Roster = $r.data; Write-RkTrace 'console: roster folded' }
  else {
    # NOT an empty roster. An empty roster reads as "nobody is playing"; a
    # fold that failed knows nothing, and the tablet must say that instead
    # (rk-players.ps1's own rule; review of [R-095]).
    Add-ConsoleNotice ('[respawnkeeper] roster: ' + $r.why) $script:Col.amber
    $script:Roster = Set-RkRosterUnavailable -Roster $script:Roster -Reason 'playerRoster' -Detail ('the history could not be read: ' + $r.why)
  }
  $script:RosterReady = $true
  # Whatever the tail saw while the history was being read, in the order it
  # was seen. A line that is in both (the fold read past where the tail
  # started) is folded twice, which the roster's join/leave rules make
  # harmless: the same sequence, replayed, ends in the same state.
  foreach ($l in @($script:RosterPending)) { Add-RkRosterLine -Roster $script:Roster -Line $l -When ([datetime]::Now) }
  $script:RosterPending.Clear()
  if ($script:TabletScreen -eq 'players') { Show-Tablet 'players' }
}

function Add-LogLines($incoming) {
  # NOT named $lines. PowerShell variables are case-insensitive, so a parameter
  # called $lines shadows the $Lines collection this function is supposed to be
  # appending to - and every Add lands on the parameter array instead, which is
  # fixed-size, so the whole log silently stayed empty.
  if (-not $incoming -or @($incoming).Count -eq 0) { return }
  foreach ($l in @($incoming)) {
    [void]$Lines.Add([pscustomobject]@{ Text = $l; Colour = $lineColour[(Get-RkLineLevel $l)] })
    # Locally echoed commands start with "> " and are not server output; feeding
    # them to the roster would let anyone type a join line into existence.
    if (-not $l.StartsWith('> ')) {
      if ($script:RosterReady) { Add-RkRosterLine -Roster $script:Roster -Line $l -When ([datetime]::Now) }
      else {
        [void]$script:RosterPending.Add($l)
        # A fold that is stuck must not turn the queue into the whole log.
        while ($script:RosterPending.Count -gt 5000) { $script:RosterPending.RemoveAt(0) }
      }
    }
  }
  while ($Lines.Count -gt $MaxLines) { $Lines.RemoveAt(0) }
  $LogScroll.ScrollToEnd()
}

# The backlog: read the whole file, keep the tail. Reading only the last N bytes
# would be cheaper and would also cut a line in half and mis-decode a multi-byte
# character sitting on the boundary.
$all = @(Read-RkLogChunk -FromStart)
Add-LogLines @($all | Select-Object -Last $Backlog)
Write-RkTrace 'console: backlog shown'

# An empty log pane has two causes that look identical: a quiet server, and a
# console pointed at a file this game never writes. Only one of them is worth
# acting on, so the second one says so in the pane itself. Added straight to
# $Lines rather than through Add-LogLines because this is the window talking,
# not the server, and the roster must never be fed it.
$script:NoticeLines = 0
function Add-ConsoleNotice([string]$text, [string]$colour) {
  if (-not $text) { return }
  [void]$Lines.Add([pscustomobject]@{ Text = $text; Colour = $colour })
  # Counted so the subtitle keeps saying how many lines the SERVER wrote. A
  # window that has read nothing must not be able to report "2 lines of log".
  $script:NoticeLines++
  while ($Lines.Count -gt $MaxLines) { $Lines.RemoveAt(0) }
}
if (-not $script:LogFile) {
  Add-ConsoleNotice (T 'console.logUnavailable') $script:Col.amber
  $w = Get-RkCapabilityWhy -Requirement 'logStream'
  if ($w) { Add-ConsoleNotice (TF 'tablet.unavail.why' $w) $script:Col.inkSubtle }
}
if ($script:LogMode -eq 'legacy') {
  Add-ConsoleNotice (T 'console.logLegacy') $script:Col.amber
}

# ---- the stage --------------------------------------------------------------
$stage = $null
try {
  $stage = Read-RkStage -Path (Join-Path $PSScriptRoot 'stage\stage.json')
  [void](New-RkStageVisual -Stage $stage -Canvas $StageHost)
} catch {
  # A broken manifest must not cost the operator their console. It costs the
  # decoration, loudly, and the log keeps working.
  Write-Host ('[console] stage disabled: ' + $_.Exception.Message)
  $TxtStageLine.Text = 'stage: ' + $_.Exception.Message
}
Write-RkTrace 'console: stage built'

# ---- fitting the window around the stage, which never gives way --------------
#
# THE BUG THIS EXISTS TO KILL. The stage sits in an Auto row of an Auto column,
# and WPF measures such a cell with infinite width and infinite height. Every
# child inherits that infinity, and three separate symptoms fall out of it:
#
#   * the tablet's ScrollViewer never finds a bottom edge, so it GROWS to fit
#     its content instead of scrolling it;
#   * TextWrapping="Wrap" never finds a right edge, so nothing wraps, the
#     tablet's inner grid ends up thousands of pixels wide, and the close
#     button - which is in its right-hand column - is arranged off the side of
#     the screen, leaving no way back;
#   * the swollen column makes the root grid taller and wider than the window,
#     which pushes the eight buttons and the command box out of sight.
#
# Giving the frame a real size before the first layout pass ends all three at
# once: everything inside it then measures against a number.
#
# The number is deliberately not written down anywhere. It is the canvas size
# rk-stage.ps1 took from stage.json (size x scale), and as of 2026-09-10 it is
# taken WHOLE: the stage is drawn at exactly the zoom the manifest asks for and
# is never scaled to make something else fit.
#
# WHY THE STAGE STOPPED GIVING WAY. This used to shrink the stage until the
# left column fitted the window, and with today's 560x376@2 art in a 1880x1010
# window the answer it came to was 0.75. Snapped to a quarter, so the arithmetic
# was tidy - but 0.75 is not a size nearest-neighbour pixel art has. A 2px
# outline drawn at 0.75 is one screen pixel here and two there, depending on
# where the row happens to land, and the whole picture goes soft in patches. The
# eyes are about to become a high-detail layer with an animation running inside
# them, and a layer like that is bought in whole screen pixels; 0.75 was
# spending three of every four.
#
# So the height comes out of the CHROME instead. The nine buttons, the header
# and the gaps between them are re-sized from one scale that follows the
# window, from 1.0 down to a floor of 0.80 - below that 13px Japanese labels
# stop being readable, and a button you cannot read is not a button. When even
# the floor does not fit, the window's own minimum is raised until it does, so
# the operator runs out of window before they run out of buttons. Nothing is
# ever pushed off the edge.
#
# Change stage.json and every one of those numbers follows it - including the
# window minimum, which is now essentially the stage's own width plus the log's.

function Get-RkWindowChrome {
  # A Window's Width and Height include the title bar and the resize frame; the
  # layout only ever gets what is left. Fitting against the outer numbers would
  # hand the layout ~40px of height it does not have - which is precisely the
  # band the bottom row of buttons lives in.
  $bw = [double][System.Windows.SystemParameters]::ResizeFrameVerticalBorderWidth
  $bh = [double][System.Windows.SystemParameters]::ResizeFrameHorizontalBorderHeight
  $cap = [double][System.Windows.SystemParameters]::CaptionHeight
  return (New-Object System.Windows.Size(($bw * 2), ($bh * 2 + $cap)))
}

function Set-RkStageFrameScale([double]$s) {
  $StageFrame.Width  = [Math]::Floor($script:StageArtW * $s)
  $StageFrame.Height = [Math]::Floor($script:StageArtH * $s)
  # The three sentences in this column are of unknown length and would widen an
  # Auto column all on their own. They may use the stage's width and no more.
  foreach ($t in @($TxtTitle, $TxtSub, $TxtStageLine)) {
    if ($t -and $StageFrame.Width -gt 0) { $t.MaxWidth = $StageFrame.Width }
  }
}

# ---- the chrome scale -------------------------------------------------------
# One number drives every part of the left column that is allowed to give way.
# The natural sizes live HERE rather than being read back out of the loaded
# XAML, because a value read back is a value that has already been scaled once:
# reading and re-scaling would ratchet the layout a little smaller on every
# resize and never come back. console.xaml carries the same numbers so the file
# still reads correctly on its own, and this table is what actually runs.
$script:UiScaleMin = 0.80
$script:UiScale    = 0.0
$script:UiBase = @{
  TitleFont = 22.0    # the server's name
  SubTop    = 2.0
  StageTop  = 8.0     # header -> stage card
  LineTop   = 6.0     # the sentence under the stage
  LineBottom = 8.0
  LineSide  = 12.0
  BlockTop  = 8.0     # stage card -> the buttons
  PowerGap  = 6.0     # power button -> the grid of eight
  Gap       = 6.0     # between the eight
  BtnFont   = 13.0
  BtnPadX   = 14.0
  BtnPadY   = 7.0
}

function Set-RkUiScale([double]$c) {
  if ($c -gt 1.0) { $c = 1.0 }
  if ($c -lt $script:UiScaleMin) { $c = $script:UiScaleMin }
  $script:UiScale = $c
  $b = $script:UiBase

  $TxtTitle.FontSize   = [Math]::Round($b.TitleFont * $c, 1)
  $TxtSub.Margin       = New-Object System.Windows.Thickness(0.0, [Math]::Round($b.SubTop * $c), 0.0, 0.0)
  $StageCard.Margin    = New-Object System.Windows.Thickness(0.0, [Math]::Round($b.StageTop * $c), 0.0, 0.0)
  $TxtStageLine.Margin = New-Object System.Windows.Thickness($b.LineSide, [Math]::Round($b.LineTop * $c),
                                                            $b.LineSide, [Math]::Round($b.LineBottom * $c))
  $BtnBlock.Margin     = New-Object System.Windows.Thickness(0.0, [Math]::Round($b.BlockTop * $c), 0.0, 0.0)

  # The buttons keep their full width - they span the stage, and a row of eight
  # that stopped short of it would look like a mistake rather than a decision.
  # What shrinks is the type and the padding around it, which is where the
  # height is.
  $font = [Math]::Round($b.BtnFont * $c, 1)
  $padX = [Math]::Round($b.BtnPadX * $c)
  $padY = [Math]::Round($b.BtnPadY * $c)
  $gap  = [Math]::Round($b.Gap * $c)
  $pad  = New-Object System.Windows.Thickness($padX, $padY, $padX, $padY)

  $BtnPower.FontSize = $font
  $BtnPower.Padding  = $pad
  $BtnPower.Margin   = New-Object System.Windows.Thickness(0.0, 0.0, 0.0, 0.0)
  $BtnMaint.FontSize = $font
  $BtnMaint.Padding  = $pad
  $BtnMaint.Margin   = New-Object System.Windows.Thickness([double]$gap, 0.0, 0.0, 0.0)
  $BtnPanel.FontSize = $font
  $BtnPanel.Padding  = $pad
  $BtnPanel.Margin   = New-Object System.Windows.Thickness([double]$gap, 0.0, 0.0, 0.0)
  $PowerRow.Margin   = New-Object System.Windows.Thickness(0.0, 0.0, 0.0, [Math]::Round($b.PowerGap * $c))

  # Taken from the grid's own children rather than from a list written here, so
  # that adding a ninth lookup button to console.xaml does not silently leave it
  # at full size while the other eight shrink around it.
  $i = 0
  foreach ($btn in @($BtnGrid.Children)) {
    $btn.FontSize = $font
    $btn.Padding  = $pad
    $right  = $(if (($i % 4) -lt 3) { [double]$gap } else { 0.0 })
    $bottom = $(if ($i -lt 4)       { [double]$gap } else { 0.0 })
    $btn.Margin = New-Object System.Windows.Thickness(0.0, 0.0, $right, $bottom)
    $i++
  }
}

function Measure-RkLeftColumn([double]$w) {
  # Invalidate, then UpdateLayout, THEN Measure. Calling Measure alone with the
  # constraint it was last given returns the cached answer: the flag set by
  # changing the frame's Width lives on the frame, and the elements between it
  # and this Grid are clean, so a top-down Measure never reaches it. Without
  # these two lines the column measured 552x201 - the size it has with NO stage
  # in it - no matter how large the frame had just been set to, and the window
  # minimum computed from it would have been a size nothing fits in. Verified by
  # printing both: 552x201 before, 844x765 after. UpdateLayout is what a live
  # window does when a Width changes at runtime; it walks the dirty path.
  #
  # The button block is invalidated for the same reason the frame is: it is
  # asked the same question at five different chrome scales in a row, and an
  # answer that came back cached would be the previous scale's height wearing
  # this scale's name - which is exactly the shape of the 552x201 bug.
  $StageFrame.InvalidateMeasure()
  $BtnBlock.InvalidateMeasure()
  $ColLeft.InvalidateMeasure()
  $ColLeft.UpdateLayout()
  $ColLeft.Measure((New-Object System.Windows.Size($w, [double]::PositiveInfinity)))
  return $ColLeft.DesiredSize
}

$script:StageArtW = 0.0
$script:StageArtH = 0.0
if ($StageHost.Width  -gt 0) { $script:StageArtW = [double]$StageHost.Width }
if ($StageHost.Height -gt 0) { $script:StageArtH = [double]$StageHost.Height }

# 1.0, and it stays 1.0. The variable is kept because the render report and the
# fallback below both want to say out loud what the stage is being drawn at, and
# a number that is printed is a number that can be checked.
$script:StageFit = 1.0

# Below this the log stops being a log - a Minecraft line is long and a column
# narrower than this is a column of fragments. It is the one number here that is
# a judgement rather than a measurement.
$script:LogMinWidth = 560.0

$chrome = Get-RkWindowChrome
$script:RootPad = $RootGrid.Margin   # the root grid's own inset
$gap    = $ColRight.Margin.Left      # the space between the two columns

$availW = [double]$win.Width  - $chrome.Width  - $script:RootPad.Left - $script:RootPad.Right - $gap - $script:LogMinWidth
$availH = [double]$win.Height - $chrome.Height - $script:RootPad.Top  - $script:RootPad.Bottom

# The sentence under the stage is still EMPTY here - Update-Console fills it in
# a moment - and it wraps, so measuring now under-counts it by however many
# lines it turns out to be. Reserve two: one for the line that is coming, one
# for the day it is a long one (a stage error puts the exception in there).
$script:UiReserve = 2 * [Math]::Ceiling([double]$TxtStageLine.FontSize * 1.4)
$availH -= $script:UiReserve

# What the column costs with no stage in it at all: the header, her line, and
# the nine buttons. Measured rather than assumed - it moves when a font, a
# padding or a string changes.
Set-RkUiScale 1.0
Set-RkStageFrameScale 0
$bare = Measure-RkLeftColumn $availW

if ($script:StageArtW -le 0 -or $script:StageArtH -le 0) {
  # No stage: a broken manifest, or art that failed to load. The frame still
  # needs a size, because the TABLET lives inside it and would otherwise be
  # measured at infinity all over again - a broken picture must not also cost
  # the operator the buttons. It gets the room the stage would have had.
  $script:StageArtW = $availW
  $script:StageArtH = [Math]::Max(120.0, ($availH - $bare.Height))
  Write-Host ('[console] no stage size - the tablet frame falls back to ' +
              [int]$script:StageArtW + 'x' + [int]$script:StageArtH)
}

# THE STAGE, ONCE, WHOLE. Nothing below this line ever touches it again.
Set-RkStageFrameScale $script:StageFit

# What the finished column costs at every chrome scale there is. Measured now,
# in five passes, rather than during a resize: the answers cannot change later
# (the column's width is the stage's width, so the sentence under it wraps the
# same way at every window size), and a drag that re-measured a layout five
# times per mouse move would stutter.
$script:FitTable = @()
for ($c = 1.0; $c -ge ($script:UiScaleMin - 0.001); $c -= 0.05) {
  $cc = [Math]::Round($c, 2)
  Set-RkUiScale $cc
  $m = Measure-RkLeftColumn $availW
  $script:FitTable += [pscustomobject]@{ Scale = $cc; W = [double]$m.Width; H = [double]$m.Height }
}
$floor = $script:FitTable[$script:FitTable.Count - 1]
Write-Host ('[console] chrome costs (scale=column height): ' +
            (($script:FitTable | ForEach-Object { $_.Scale.ToString('0.00') + '=' + [int]$_.H }) -join '  '))

function Set-RkUiFitForClientHeight([double]$clientH) {
  # The largest chrome that fits the height on offer; the floor when none does,
  # which is the case the window minimum below exists to make impossible.
  if (-not $script:FitTable -or $script:FitTable.Count -eq 0) { return $null }
  $room = $clientH - $script:RootPad.Top - $script:RootPad.Bottom - $script:UiReserve
  $pick = $script:FitTable[$script:FitTable.Count - 1]
  foreach ($e in $script:FitTable) { if ($e.H -le $room) { $pick = $e; break } }
  if ([Math]::Abs($pick.Scale - $script:UiScale) -gt 0.001) { Set-RkUiScale $pick.Scale }
  return $pick
}

# The window's floor: what the layout needs with the chrome as small as it is
# allowed to get, never less than what console.xaml asked for. An operator who
# drags the window smaller must run out of window before they run out of
# buttons - and since the stage no longer gives way, this is where the promise
# is kept.
$minW = [Math]::Ceiling($floor.W + $script:RootPad.Left + $script:RootPad.Right + $gap + $script:LogMinWidth + $chrome.Width)
$minH = [Math]::Ceiling($floor.H + $script:UiReserve + $script:RootPad.Top + $script:RootPad.Bottom + $chrome.Height)
if ($win.MinWidth  -lt $minW) { $win.MinWidth  = $minW }
if ($win.MinHeight -lt $minH) { $win.MinHeight = $minH }

# A minimum larger than the desktop is not a layout bug, it is a stage that has
# outgrown the screen - and the honest thing to do is say so rather than quietly
# shrink the art the manifest asked for. The window still works; it is simply
# larger than the work area, and the operator will find out by dragging it.
$work = [System.Windows.SystemParameters]::WorkArea
if ($win.MinWidth -gt $work.Width -or $win.MinHeight -gt $work.Height) {
  Write-Host ('[console] WARNING: this stage needs a window of at least ' +
              [int]$win.MinWidth + 'x' + [int]$win.MinHeight +
              ', and the work area is only ' + [int]$work.Width + 'x' + [int]$work.Height +
              ' - shrink stage.json, not the stage.')
}

# And the scale this window actually opens at.
$pick = Set-RkUiFitForClientHeight ([Math]::Max([double]$win.Height, [double]$win.MinHeight) - $chrome.Height)

# A live window follows the drag. Nothing here re-measures - it picks a row out
# of the table built above - so this is cheap enough to run on every SizeChanged
# a resize produces.
$win.Add_SizeChanged({
    param($s, $e)
    # NewSize rather than ActualHeight, and a guard on both: the first
    # SizeChanged of a window's life is the one where it goes from nothing to
    # its opening size, and a zero read there would pick the floor and open the
    # window with its smallest buttons at its largest size.
    $hh = 0.0
    if ($e -and [double]$e.NewSize.Height -gt 0) { $hh = [double]$e.NewSize.Height }
    else { $hh = [double]$win.ActualHeight }
    if ($hh -le 0) { return }
    # Wrapped for the same reason every stage call in this file is: this runs on
    # every frame of a window drag, and a console that dies while being resized
    # is a console that dies exactly when somebody is trying to look at it. The
    # worst case without it is buttons that stop following the window; the worst
    # case with an unguarded throw is no window.
    try {
      $ch = Get-RkWindowChrome
      [void](Set-RkUiFitForClientHeight ($hh - $ch.Height))
    } catch { Write-Host ('[console] resize: ' + $_.Exception.Message) }
  })

Write-Host ('[console] stage ' + [int]$script:StageArtW + 'x' + [int]$script:StageArtH +
            ' at fit ' + $script:StageFit + ' (never scaled) -> ' +
            [int]$StageFrame.Width + 'x' + [int]$StageFrame.Height +
            '; chrome scale ' + $script:UiScale + ' of ' + $script:UiScaleMin + '..1' +
            '; left column needs ' + [int]$pick.W + 'x' + [int]$pick.H +
            ' (' + [int]$floor.W + 'x' + [int]$floor.H + ' at the floor)' +
            '; window ' + [int]$win.Width + 'x' + [int]$win.Height +
            ', min ' + [int]$win.MinWidth + 'x' + [int]$win.MinHeight)

Write-RkTrace 'console: chrome fitted'
$script:Tick = 0
$script:LastState = [pscustomobject]@{ Pose = 'sleep'; Brush = $script:Col.inkSubtle; Line = ''; Row = $null }

# ============================================================================
# THE TABLET
#
# Every one of the eight buttons asks her for something and she hands it over.
# The animation is the wrapper; these functions are what is written on it.
#
# NOTHING HERE TALKS TO THE SERVER except the command screen, which uses the
# same spool the text box does. Looking something up must never cost a tick.
# ============================================================================
$script:TabletScreen  = ''
$script:HandoffScreen = ''
# Kept as the font NAMES, not FontFamily objects - see the ItemTemplate comment
# in console.xaml for why anything richer than a string does not survive the
# trip through a PowerShell object.
$script:FontBody = 'Segoe UI'
$script:FontMono = 'Consolas'
$f = $win.TryFindResource('Body'); if ($f) { $script:FontBody = $f.Source }
$f = $win.TryFindResource('Mono'); if ($f) { $script:FontMono = $f.Source }

function New-TabRow {
  param([string]$Text, [string]$Colour = '', [switch]$Mono, [double]$Size = 13)
  if (-not $Colour) { $Colour = $script:Col.ink }
  return [pscustomobject]@{
    Text     = $Text
    Colour   = $Colour
    FontName = $(if ($Mono) { $script:FontMono } else { $script:FontBody })
    Size     = $Size
  }
}

function Build-TabRosterUnavailable {
  # THE THIRD STATE. "Nobody is on" and "I cannot tell who is on" are different
  # sentences, and before [R-071] they were the same one. The reason line comes
  # from lib\rk-capabilities.psd1 verbatim so the window cannot soften it.
  param([pscustomobject]$Status)
  $rows = @((New-TabRow (T 'tablet.unavail.head') $script:Col.amber -Size 15))
  $rows += (New-TabRow '')
  switch ($Status.Reason) {
    'connectEvidence' { $rows += (New-TabRow (T 'tablet.unavail.players') $script:Col.ink -Size 13) }
    'gameUnknown'     { $rows += (New-TabRow (T 'tablet.unavail.unknownGame') $script:Col.ink -Size 13) }
    'logStream'       { $rows += (New-TabRow (T 'tablet.unavail.noLog') $script:Col.ink -Size 13) }
    default           { $rows += (New-TabRow (T 'tablet.unavail.noLog') $script:Col.ink -Size 13) }
  }
  if ($Status.Why) { $rows += (New-TabRow (TF 'tablet.unavail.why' $Status.Why) $script:Col.inkSubtle -Size 11) }
  if ($Status.LogMode -eq 'legacy') { $rows += (New-TabRow (T 'tablet.unavail.legacy') $script:Col.inkSubtle -Size 11) }
  return $rows
}

function Build-TabPlayers {
  if (-not $script:RosterReady) { return @((New-TabRow (T 'tablet.players.loading') $script:Col.inkMuted)) }
  $status = Get-RkRosterStatus -Roster $script:Roster
  if (-not $status.Available) { return (Build-TabRosterUnavailable -Status $status) }
  $names = @(Get-RkRosterNames -Roster $script:Roster)
  if ($names.Count -eq 0) { return @((New-TabRow (T 'tablet.players.none') $script:Col.inkMuted)) }
  $rows = @((New-TabRow (TF 'tablet.players.count' $names.Count) $script:Col.accent -Size 16))
  foreach ($n in $names) { $rows += (New-TabRow ('  ' + $n) $script:Col.ink -Mono -Size 14) }
  $rows += (New-TabRow '')
  $rows += (New-TabRow (T 'tablet.players.how') $script:Col.inkSubtle -Size 11)
  if ($status.LogMode -eq 'legacy') { $rows += (New-TabRow (T 'tablet.unavail.legacy') $script:Col.inkSubtle -Size 11) }
  return $rows
}

function Build-TabVitals {
  $v = $null
  try { $v = Get-RkVitals -ServerDir $ServerDir -Template $script:Game } catch { }
  if (-not $v) { return @((New-TabRow (T 'tablet.vitals.none') $script:Col.inkMuted)) }

  # Uptime and memory come from the process, so they survive a missing log -
  # that is exactly what 'degraded' is allowed to show (vitals.note in
  # lib\rk-capabilities.psd1). What it is NOT allowed to do is print the lag
  # line: with no log read, LagCount is zero because nothing was counted, and
  # "no lag recorded" would be a measurement nobody took. [R-071].
  $rows = @()
  $rows += (New-TabRow (TF 'tablet.vitals.uptime' ([int]($v.UptimeMin / 60)) ($v.UptimeMin % 60)) $script:Col.ink -Size 14)
  $rows += (New-TabRow (TF 'tablet.vitals.mem' $v.MemMB) $script:Col.ink -Size 14)
  $rows += (New-TabRow '')
  if (-not $v.LagMeasured) {
    $rows += (New-TabRow (T 'tablet.unavail.head') $script:Col.amber -Size 14)
    switch ($v.UnmetReason) {
      'logEmpty'      { $rows += (New-TabRow (T 'tablet.unavail.lagEmpty') $script:Col.ink -Size 13) }
      'logUnreadable' { $rows += (New-TabRow (T 'tablet.unavail.lagUnreadable') $script:Col.ink -Size 13) }
      'lagEvidence'   { $rows += (New-TabRow (T 'tablet.unavail.lagEvidence') $script:Col.ink -Size 13) }
      default         { $rows += (New-TabRow (T 'tablet.unavail.lag') $script:Col.ink -Size 13) }
    }
    if ($v.UnmetWhy) { $rows += (New-TabRow (TF 'tablet.unavail.why' $v.UnmetWhy) $script:Col.inkSubtle -Size 11) }
  } elseif ($v.LagCount -eq 0) {
    $rows += (New-TabRow (TF 'tablet.vitals.lagNone' $v.ScannedKB) $script:Col.accent -Size 14)
  } else {
    # Colour by the WORST miss, not by how many: 60 small stutters is a
    # different problem from one 26-second freeze, and the number that decides
    # whether a person should act is the big one.
    $col = $script:Col.amber
    if ($v.WorstMs -ge 5000) { $col = $script:Col.danger }
    $rows += (New-TabRow (TF 'tablet.vitals.lag' $v.LagCount $v.ScannedKB) $col -Size 14)
    $rows += (New-TabRow (TF 'tablet.vitals.worst' ([Math]::Round($v.WorstMs / 1000.0, 1)) $v.WorstTicks) $col -Size 14)
  }
  $rows += (New-TabRow '')
  $rows += (New-TabRow (TF 'tablet.vitals.crash' $v.Crashes $v.Repairs) $script:Col.inkMuted -Size 13)
  return $rows
}

function Build-TabReport {
  if (-not $script:ReportPath) { return @((New-TabRow (T 'tablet.report.none') $script:Col.inkMuted)) }
  $text = ''
  try { $text = Get-Content -LiteralPath $script:ReportPath -Raw -Encoding UTF8 } catch { }
  if (-not $text) { return @((New-TabRow (T 'tablet.report.none') $script:Col.inkMuted)) }
  $rows = @()
  foreach ($ln in @($text -split "`r?`n")) {
    if ($ln -match '^#{1,6}\s*(.*)$') { $rows += (New-TabRow $Matches[1] $script:Col.accent -Size 15) }
    elseif ($ln.Trim() -eq '')        { $rows += (New-TabRow '') }
    else                              { $rows += (New-TabRow $ln $script:Col.ink -Size 13) }
  }
  return $rows
}

function Build-TabDiag {
  $stateDir = Join-Path $ServerDir 'respawnkeeper'
  $rows = @()

  $st = $null
  try { $st = Get-Content -LiteralPath (Join-Path $stateDir 'state.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
  if ($st) {
    $verdict = ''
    if ($st.lastVerdict) { $verdict = [string]$st.lastVerdict }
    $lastCrash = ''
    if ($st.lastCrash) { $lastCrash = [string]$st.lastCrash }
    if (-not $lastCrash) {
      $rows += (New-TabRow (T 'tablet.diag.noCrash') $script:Col.accent -Size 14)
    } else {
      $rows += (New-TabRow (TF 'tablet.diag.lastCrash' $lastCrash) $script:Col.danger -Size 14)
      if ($verdict) { $rows += (New-TabRow (TF 'tablet.diag.verdict' $verdict) $script:Col.ink -Size 13) }
    }
  } else {
    $rows += (New-TabRow (T 'tablet.diag.noState') $script:Col.inkMuted)
  }

  $rows += (New-TabRow '')
  $comebacks = @(Get-ChildItem -LiteralPath (Join-Path $stateDir 'reports') -Filter 'comeback-*.md' -File -ErrorAction SilentlyContinue)
  if ($comebacks.Count -eq 0) {
    $rows += (New-TabRow (T 'tablet.diag.noComeback') $script:Col.inkMuted -Size 13)
  } else {
    $rows += (New-TabRow (TF 'tablet.diag.comeback' $comebacks.Count) $script:Col.amber -Size 14)
    foreach ($c in $comebacks) { $rows += (New-TabRow ('  ' + $c.Name) $script:Col.ink -Mono -Size 12) }
  }
  return $rows
}

function Build-TabCommand {
  $rows = @()
  if (-not (Test-RkStdinOwner)) {
    $rows += (New-TabRow (T 'console.noStdin') $script:Col.amber -Size 13)
    return $rows
  }
  $rows += (New-TabRow (T 'tablet.command.hint') $script:Col.ink -Size 13)
  $rows += (New-TabRow '')
  $rows += (New-TabRow (T 'tablet.command.chatHint') $script:Col.inkMuted -Size 12)
  $rows += (New-TabRow '')
  foreach ($ex in @('list', 'say hello', 'save-all', 'time set day', 'weather clear')) {
    $rows += (New-TabRow ('  ' + $ex) $script:Col.inkMuted -Mono -Size 12)
  }
  return $rows
}

function Build-TabAttend {
  $rows = @()
  $rows += (New-TabRow (T 'tablet.attend.hint') $script:Col.ink -Size 14)
  $rows += (New-TabRow '')
  $rows += (New-TabRow (T 'tablet.attend.note') $script:Col.inkSubtle -Size 11)
  return $rows
}

function Build-TabRemove {
  # The destructive screen. It lists what will MOVE and what will not be
  # touched, because "uninstall" next to a Minecraft world has to be read as a
  # promise about the world before it is read as anything else.
  $rows = @()
  # .Running, NOT .CanStop. CanStop also requires a live supervisor, so asking
  # it here hid this warning exactly when the window has outlived its
  # supervisor with the server still up - the state this window now stays open
  # for. See panel-model.ps1 where Running is published.
  # FAIL CLOSED. No row yet (the first background read has not landed, or
  # every read is failing) is not "not running": until the row says so, the
  # server is treated as up and the button stays off. This was the one
  # destructive control that read a missing row as permission (review of
  # [R-095]).
  $running = $true
  if ($script:LastState.Row) { $running = [bool]$script:LastState.Row.Running }

  if ($running) {
    $rows += (New-TabRow (T 'tablet.remove.running') $script:Col.danger -Size 14)
    $rows += (New-TabRow '')
  }
  $rows += (New-TabRow (T 'tablet.remove.what') $script:Col.ink -Size 14)
  foreach ($item in @('respawnkeeper', 'rk-start.bat', 'rk-stop.bat', 'rk-restart.bat', 'rk-diagnose.bat')) {
    $rows += (New-TabRow ('  ' + $item) $script:Col.ink -Mono -Size 12)
  }
  $rows += (New-TabRow '')
  $rows += (New-TabRow (T 'tablet.remove.safe') $script:Col.accent -Size 13)
  $rows += (New-TabRow '')
  $rows += (New-TabRow (T 'tablet.remove.where') $script:Col.inkMuted -Size 12)
  return $rows
}

function Show-Tablet([string]$screen) {
  $script:TabletScreen = $screen
  $TabletActions.Visibility = 'Collapsed'
  $TabletInput.Visibility   = 'Collapsed'
  $BtnTabletConfirm.Visibility = 'Collapsed'
  $BtnTabletConfirm.IsEnabled  = $true

  $rows = @()
  switch ($screen) {
    'players' { $TxtTabletTitle.Text = T 'tablet.title.players'; $rows = @(Build-TabPlayers) }
    'vitals'  { $TxtTabletTitle.Text = T 'tablet.title.vitals';  $rows = @(Build-TabVitals) }
    'report'  { $TxtTabletTitle.Text = T 'tablet.title.report';  $rows = @(Build-TabReport) }
    'diag'    { $TxtTabletTitle.Text = T 'tablet.title.diag';    $rows = @(Build-TabDiag) }
    'attend'  {
      $TxtTabletTitle.Text = T 'tablet.title.attend'; $rows = @(Build-TabAttend)
      $BtnTabletConfirm.Content = T 'tablet.attend.coffee'
      $BtnTabletConfirm.Visibility = 'Visible'
      $TabletActions.Visibility = 'Visible'
    }
    'command' {
      $TxtTabletTitle.Text = T 'tablet.title.command'; $rows = @(Build-TabCommand)
      if (Test-RkStdinOwner) {
        $BtnTabletConfirm.Content = T 'tablet.command.send'
        $BtnTabletConfirm.Visibility = 'Visible'
        $TabletInput.Visibility = 'Visible'
        $TabletActions.Visibility = 'Visible'
      }
    }
    'remove'  {
      $TxtTabletTitle.Text = T 'tablet.title.remove'; $rows = @(Build-TabRemove)
      $BtnTabletConfirm.Content = T 'tablet.remove.confirm'
      $BtnTabletConfirm.Visibility = 'Visible'
      $TabletActions.Visibility = 'Visible'
      # Never while it is up. Pulling the supervisor out from under a running
      # server is the one thing this window must refuse on its own - and
      # "nobody has told me yet" counts as up (review of [R-095]).
      $r = $true
      if ($script:LastState.Row) { $r = [bool]$script:LastState.Row.Running }
      $BtnTabletConfirm.IsEnabled = (-not $r)
    }
    default   { $TxtTabletTitle.Text = ''; $rows = @() }
  }
  $TabletList.ItemsSource = @($rows)
  $TabletLayer.Visibility = 'Visible'
}

function Hide-Tablet {
  $script:TabletScreen = ''
  $TabletLayer.Visibility = 'Collapsed'
}

# ---- the hand-off -----------------------------------------------------------
# She takes the tablet out, holds it forward and turns it to face you: four
# frames named hand.0..hand.3, reached through a 'hand' state in stage.json.
#
# THE ART IS NOT DRAWN YET and the window must not wait for a thing that does
# not exist, so the animation plays only if stage.json actually declares that
# state. Adding it later is four frames plus four lines of manifest - no code
# changes here.
function Test-HandoffArt {
  if (-not $stage) { return $false }
  foreach ($L in $stage.Layers) {
    if ($L.ByState -and $L.ByState.ContainsKey('hand')) { return $true }
  }
  return $false
}

$script:HandFrame = 0
$script:HandTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HandTimer.Interval = [TimeSpan]::FromMilliseconds(110)
$script:HandTimer.Add_Tick({
    $script:HandFrame++
    if ($stage) {
      try { Update-RkStage -Stage $stage -Tick $script:HandFrame -State 'hand' -Signal $script:LastState.Brush } catch { }
    }
    if ($script:HandFrame -ge 8) {
      $script:HandTimer.Stop()
      Show-Tablet $script:HandoffScreen
    }
  })

function Start-Handoff([string]$screen) {
  # Asking for the screen you are already looking at closes it. The button is
  # the same gesture both ways, which is how a person expects a drawer to work.
  if ($script:TabletScreen -eq $screen) { Hide-Tablet; return }
  $script:HandoffScreen = $screen
  if (-not (Test-HandoffArt)) { Show-Tablet $screen; return }
  $script:HandFrame = 0
  $script:HandTimer.Start()
}

function Invoke-RkUninstall {
  # QUARANTINE, NOT DELETE - the house rule, and the right one here: an
  # uninstall that turns out to have been a misclick is otherwise unrecoverable,
  # and what is being moved includes the state file that knows this server's
  # whole crash history.
  #
  # The world, the mods and the configs are never touched. Nothing under
  # $ServerDir moves except respawnkeeper's own footprint.
  $running = $true     # no row = not proven stopped = refuse (review of [R-095])
  if ($script:LastState.Row) { $running = [bool]$script:LastState.Row.Running }
  if ($running) { return }

  $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
  $label = (Split-Path -Leaf $ServerDir)
  $quarantine = Join-Path (Split-Path -Parent $script:PanelRepoDir) ('support\delate_files\' + $label + '-respawnkeeper-' + $stamp)
  try {
    New-Item -ItemType Directory -Force -Path $quarantine | Out-Null
  } catch {
    [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'respawnkeeper')
    return
  }

  $moved = @()
  foreach ($rel in @('respawnkeeper', 'rk-start.bat', 'rk-stop.bat', 'rk-restart.bat', 'rk-diagnose.bat')) {
    $src = Join-Path $ServerDir $rel
    if (-not (Test-Path -LiteralPath $src)) { continue }
    try { Move-Item -LiteralPath $src -Destination (Join-Path $quarantine $rel) -Force; $moved += $rel }
    catch { }
  }

  # And out of the registry, so the panel stops listing a server it no longer
  # supervises.
  try {
    $reg = Read-RkJson -Path $script:PanelRegistryFile
    if ($reg -and $reg.servers) {
      $keep = @($reg.servers | Where-Object { $_ -and (([string]$_).TrimEnd('\')) -ne $ServerDir.TrimEnd('\') })
      $out = [pscustomobject]@{
        schema  = 'respawnkeeper/servers/1'
        updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        servers = $keep
      }
      [System.IO.File]::WriteAllText($script:PanelRegistryFile, ($out | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch { }

  $TabletList.ItemsSource = @(
    (New-TabRow (TF 'tablet.remove.done' $moved.Count) $script:Col.accent -Size 14),
    (New-TabRow ''),
    (New-TabRow $quarantine $script:Col.ink -Mono -Size 12)
  )
  $TabletActions.Visibility = 'Collapsed'
}

function Invoke-TabletConfirm {
  switch ($script:TabletScreen) {
    'command' {
      $text = $TabletInput.Text
      if (-not $text -or -not $text.Trim()) { return }
      if (Send-RkConsoleCommand $text) {
        Add-LogLines @('> ' + $text.Trim())
        $TabletInput.Text = ''
      } else {
        Add-LogLines @('> ' + $text.Trim() + '   [could not be queued]')
      }
    }
    'attend' {
      # The interaction hook. With no art for it yet this is the line she says;
      # when a 'coffee' state exists in stage.json it will play here too.
      $TxtStageLine.Text = T 'tablet.attend.thanks'
      Hide-Tablet
    }
    'remove' { Invoke-RkUninstall }
  }
}

function Send-ConsoleSignal([string]$signal) {
  # Same file, same check as the panel's buttons (Send-PanelSignal). The reply
  # goes into the log column and onto the stage line, where the operator is
  # already looking - not into a message box, unless it is a refusal.
  $r = Request-RkSignal -ServerDir $ServerDir -Signal $signal
  if ($r.ok) {
    Add-LogLines @('> [respawnkeeper] ' + $signal + ' requested (' + (Split-Path -Leaf $r.file) + ')')
    $TxtStageLine.Text = $(if ($signal -eq 'stop') { T 'signal.sentStop' } else { T 'signal.sentRestart' })
    $script:RowDue = $true      # the label changes when the next read lands
    return
  }
  Add-LogLines @('> [respawnkeeper] ' + $signal + ' NOT sent: ' + $r.reason + ' - ' + $r.detail)
  $msg = $(if ($r.reason -eq 'unsupervised') { TF 'signal.nobody' $r.detail } else { TF 'signal.failed' $r.detail })
  [void][System.Windows.MessageBox]::Show($msg, 'respawnkeeper')
}

function Update-Console {
  $cs = Get-RkConsoleState
  $script:LastState = $cs
  if ($stage) {
    try { Update-RkStage -Stage $stage -Tick $script:Tick -State $cs.Pose -Signal $cs.Brush } catch { }
  }
  $TxtStageLine.Text = $cs.Line
  try { $TxtStageLine.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($cs.Brush)) } catch { }

  $canSend = Test-RkStdinOwner
  $BtnSend.IsEnabled = $canSend
  $TxtCommand.IsEnabled = $canSend
  $pending = Get-RkPendingCommands
  if (-not $canSend) {
    $TxtCmdNote.Text = T 'console.noStdin'
    $TxtCmdNote.Visibility = 'Visible'
  } elseif ($pending -gt 0) {
    $TxtCmdNote.Text = TF 'console.pending' $pending
    $TxtCmdNote.Visibility = 'Visible'
  } else {
    $TxtCmdNote.Visibility = 'Collapsed'
  }

  # Start and stop are one button because the server is either up or it is not.
  # The action is stored rather than decided in the click handler: the handler
  # runs on whatever the last slow pass established, which is the same value the
  # label the operator just read was drawn from.
  #
  # Start is still rk-start.bat (a supervisor needs a console of its own). Stop
  # and the maintenance restart are flag files, written here through the same
  # Request-RkSignal the panel uses; the row already knows whether a supervisor
  # is there to read them (CanStop / CanRestart), and while one is mid-lap
  # (Busy) the label says what it is doing instead of offering a second stop.
  $busy = ''
  if ($cs.Row) { $busy = [string]$cs.Row.Busy }
  if ($busy) {
    $BtnPower.Content = $busy
    $script:PowerAction = ''
    $BtnPower.IsEnabled = $false
  } elseif ($cs.Row -and $cs.Row.CanStop) {
    $BtnPower.Content = T 'button.stop'
    $script:PowerAction = 'stop'
    $BtnPower.IsEnabled = $true
  } elseif (-not $cs.Row) {
    # No row yet: say so, rather than "start" on a server that may be up.
    $BtnPower.Content = T 'console.loading'
    $script:PowerAction = ''
    $BtnPower.IsEnabled = $false
  } else {
    $BtnPower.Content = T 'button.start'
    $script:PowerAction = 'start'
    $script:PowerTarget = Join-Path $ServerDir 'rk-start.bat'
    $BtnPower.IsEnabled = ((Test-Path -LiteralPath $script:PowerTarget) -and ($cs.Row -and $cs.Row.CanStart))
  }
  $BtnMaint.IsEnabled = [bool]($cs.Row -and $cs.Row.CanRestart)

  # A report button that opens nothing is worse than a disabled one: it reads as
  # a broken window rather than as "there is no report yet".
  $script:ReportPath = ''
  if ($cs.Row -and $cs.Row.ReportPath) { $script:ReportPath = [string]$cs.Row.ReportPath }
  $BtnReport.Content = $(if ($cs.Row) { $cs.Row.ReportLabel } else { T 'button.noReport' })
  $BtnReport.IsEnabled = [bool]$script:ReportPath

  # A tablet left open must keep saying what is true. Only the live screens are
  # rebuilt - re-rendering 'remove' would wipe the result of an uninstall that
  # just ran, and re-rendering 'command' would take a half-typed line away.
  if ($script:TabletScreen -eq 'players' -or $script:TabletScreen -eq 'vitals') {
    Show-Tablet $script:TabletScreen
  }

  $state = T 'console.loading'
  if ($cs.Row) { $state = $cs.Row.StateText }
  $TxtSub.Text = TF 'console.subtitle' $state ([Math]::Max(0, $Lines.Count - $script:NoticeLines))
}

# The same three lines as the panel's Start-Detached, and deliberately not
# shared with it: panel-model.ps1 is the part that KNOWS things and has no window
# and no side effects, and a process launcher does not belong in it.
#
# UseShellExecute is the point. The server gets its own console owned by the
# operator rather than a child handle owned by this window - which is the same
# promise the command queue makes. Closing this window must never be able to
# take a server with it.
function Start-Detached([string]$file) {
  if (-not (Test-Path -LiteralPath $file)) {
    [void][System.Windows.MessageBox]::Show(($file + "`n`n" + (T 'console.noBat')), 'respawnkeeper')
    return
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $file
  $psi.UseShellExecute = $true
  $psi.WorkingDirectory = (Split-Path -Parent $file)
  try { [void][System.Diagnostics.Process]::Start($psi) }
  catch { [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'respawnkeeper') }
}

function Submit-Command {
  $text = $TxtCommand.Text
  if (-not $text.Trim()) { return }
  if (Send-RkConsoleCommand $text) {
    # Echoed locally so the operator sees that it left. It is NOT dressed up as
    # a server line - the server has not answered yet, and might not.
    Add-LogLines @('> ' + $text.Trim())
    $TxtCommand.Text = ''
  } else {
    Add-LogLines @('> ' + $text.Trim() + '   [could not be queued]')
  }
  Update-Console
}

$BtnSend.Add_Click({ Submit-Command })
# A SECOND PRESS INSIDE THE BLIND WINDOW IS NOT A SECOND INTENT.
#
# The label and the enabled state come from the slow tick, which is 2s apart
# plus the 0.6-1.7s Get-RkPanelRow costs - so for up to ~3.7s after a start the
# button still says START and is still enabled. Nothing about the click changes
# that, and a second press launches rk-start.bat again. The second supervisor
# almost always aborts on harness.lock, but "almost always" is not the standard
# for a path whose bad end is two servers on one world.
$script:LastPowerClick = [datetime]::MinValue
$BtnPower.Add_Click({
    if (((Get-Date) - $script:LastPowerClick).TotalSeconds -lt 6) { return }
    $script:LastPowerClick = Get-Date
    switch ($script:PowerAction) {
      'start' { if ($script:PowerTarget) { Start-Detached $script:PowerTarget } }
      'stop'  { Send-ConsoleSignal 'stop' }
    }
  })
$BtnMaint.Add_Click({ Send-ConsoleSignal 'maintenance' })
# The six lookup buttons all go through the tablet. rk-diagnose.bat still exists and
# still runs from the panel - what changed is that ASKING what the diagnosis
# said no longer means launching a process and reading a black window.
$BtnDiagnose.Add_Click({    Start-Handoff 'diag' })
$BtnReport.Add_Click({      Start-Handoff 'report' })
$BtnTabPlayers.Add_Click({  Start-Handoff 'players' })
$BtnTabVitals.Add_Click({   Start-Handoff 'vitals' })
$BtnTabCommand.Add_Click({  Start-Handoff 'command' })
$BtnTabAttend.Add_Click({   Start-Handoff 'attend' })
$BtnTabRemove.Add_Click({   Start-Handoff 'remove' })
$BtnTabletClose.Add_Click({ Hide-Tablet })
$BtnTabletConfirm.Add_Click({ Invoke-TabletConfirm })
$TabletInput.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) { Invoke-TabletConfirm; $e.Handled = $true }
  })
$BtnFolder.Add_Click({   Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $ServerDir + '"') })

function Show-RkPanel {
  # "Back to the list" - the screen where you pick which rk server to start or
  # edit. This window is normally opened FROM that screen, so the panel is
  # usually still behind it: raise the one that is there rather than starting a
  # second one. Opening a duplicate here would be the very bug this session
  # fixed one level down.
  $lock = Get-RkPanelLockFile
  $open = Get-RkUiWindow -LockFile $lock -ScriptPattern (Get-RkPanelScriptPattern)
  if ($open.alive) {
    if (Show-RkWindowOf -Id $open.pid) { return }
    # It is registered and its process is provably a live rk-panel.ps1, so the
    # answer is NOT "start another one" - it is "that window would not come
    # forward", which is a different problem and is said out loud.
    [void][System.Windows.MessageBox]::Show((TF 'console.panelOpen' $open.pid), 'respawnkeeper')
    return
  }
  # No panel. Start one the only way anything starts one - through rk-entry.ps1,
  # which is the single place that decides what a door means ([R-080]).
  $entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'rk-entry.ps1'
  if (-not (Test-Path -LiteralPath $entry)) {
    [void][System.Windows.MessageBox]::Show((TF 'console.panelMissing' $entry), 'respawnkeeper')
    return
  }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName         = (Get-Command powershell).Source
    $psi.Arguments        = ('-NoProfile -ExecutionPolicy Bypass -File "' + $entry + '" -Task panel')
    $psi.UseShellExecute  = $false
    $psi.CreateNoWindow   = $true
    $psi.WorkingDirectory = (Split-Path -Parent $PSScriptRoot)
    [void][System.Diagnostics.Process]::Start($psi)
  } catch { [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'respawnkeeper') }
}

# Same blind window as the power button, and worse: a panel takes ~6s to reach
# the line where it registers itself, so a second press inside that gap sees no
# registration and starts a second panel.
$script:LastPanelClick = [datetime]::MinValue
$BtnPanel.Add_Click({
    if (((Get-Date) - $script:LastPanelClick).TotalSeconds -lt 8) { return }
    $script:LastPanelClick = Get-Date
    Show-RkPanel
  })
$TxtCommand.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) { Submit-Command; $e.Handled = $true }
  })

# The first paint says "reading" and the first background read replaces it
# about half a second later; -RenderTo reads synchronously below, because a
# picture of the window with no row in it is not a picture of the window.
if ($RenderTo) { try { $script:LastRow = Get-RkPanelRow -ServerDir $ServerDir } catch { } }
Update-Console
$TxtCommand.Focus() | Out-Null

# Two clocks, for the same reason the panel has two: this one only advances a
# frame index and appends whatever the log grew by, which is cheap enough to do
# often. Anything that touches the disk harder stays on the slower pass inside
# Update-Console.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:SlowEvery = 5
$script:SlowCount = 0
# NOTHING HERE CLOSES THE WINDOW ANY MORE ([R-088]).
#
# This tick used to watch $SupervisorPid and close the window two misses after
# that process disappeared. Which meant: press stop -> the server goes down ->
# the supervisor exits -> the window vanishes, taking the start button with it.
# The one moment you most want a window that says "stopped, press here to start"
# was the one moment there was no window.
#
# Update-Console reads everything from disk, so a window with no supervisor is
# not a broken window: the row says STOPPED, the power button turns into START
# (CanStart is exactly "not running AND no supervisor"), and the log keeps the
# last run's lines on screen to read. The only thing that ends this window now
# is the operator closing it.
$timer.Add_Tick({
    Add-LogLines (Read-RkLogChunk)
    Complete-RosterGather
    if (Test-RkGatherBusy -Gather $script:Prerender) {
      $pr = Complete-RkGather -Gather $script:Prerender -Pick { param($out) $true }
      if ($pr.state -ne 'running') { Close-RkGather -Gather $script:Prerender }   # drop the runspace and what it decoded
    }
    # A finished read is applied the moment it is seen, not on the slow beat;
    # the slow beat only decides when the NEXT read starts. So a result is
    # never more than 400 ms older than it has to be.
    if (Complete-RowGather) { Update-Console }
    $script:SlowCount++
    # Busy is tested BEFORE RowDue is cleared: a request that lands while a
    # read is in flight waits for the next tick instead of being thrown away
    # (the panel's GatherDue had this right; this one did not - review of
    # [R-095]).
    if (Test-RkGatherBusy -Gather $script:RowGather) { return }
    if ($script:RowDue -or ($script:SlowCount -ge $script:SlowEvery)) {
      $script:SlowCount = 0
      $script:RowDue = $false
      Start-RowGather            # asks the disk what is true, off this thread
    }
  })

# ---- the stage's own clock --------------------------------------------------
# Drawing is separated from reading on purpose. This timer advances frames and
# touches nothing else - no disk, no log - so it can run four times as often
# without costing four times as much. The eye layer needs it: a gradient
# travelling down an iris in eight frames is nine tenths of a second here and
# three and a half seconds on the 400ms tick, which is the difference between
# light moving and a slideshow.
#
# Nothing else speeds up. Every animation that existed before had its hold
# values multiplied by four in stage.json, so it lands on the same wall clock it
# always had. The hand-off keeps its own 110ms timer and is untouched.
$script:StageTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:StageTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:StageTimer.Add_Tick({
    if (-not $stage) { return }
    if ($script:HandTimer -and $script:HandTimer.IsEnabled) { return }  # the hand-off is driving
    $script:Tick++
    try { Update-RkStage -Stage $stage -Tick $script:Tick -State $script:LastState.Pose -Signal $script:LastState.Brush } catch { }
  })

# -RenderTo: the same window, with the same data, rasterised instead of shown.
# It is placed AFTER everything is wired rather than in a separate preview
# script on purpose - a preview that builds its own copy of the window is a
# preview of a window that does not exist ([R-040]).
if ($RenderTo) {
  $timer.Stop()
  # The roster fold runs in the background and is normally picked up by the
  # timer, which never ticks here - so collect it now, or -RenderTablet
  # players would rasterise the "still reading" row, a screen the real window
  # shows for a second and the picture would show forever.
  $waited = 0
  while ((-not $script:RosterReady) -and ($waited -lt 120000)) { Complete-RosterGather; if (-not $script:RosterReady) { Start-Sleep -Milliseconds 100; $waited += 100 } }
  if ($RenderTablet) { Show-Tablet $RenderTablet }

  # THE CLIENT AREA, not the window box. $win.Width and $win.Height include the
  # title bar and the resize frame, so rendering at those numbers gives the
  # layout about 40px of height it will never actually have on screen - and the
  # bottom row of buttons sits in exactly that band. A preview that is kinder
  # than the real window is not a preview.
  $chrome = Get-RkWindowChrome
  $outerW = [double]$win.Width; $outerH = [double]$win.Height
  if ($RenderMin) { $outerW = [double]$win.MinWidth; $outerH = [double]$win.MinHeight }
  $w = [int]($outerW - $chrome.Width); $h = [int]($outerH - $chrome.Height)

  # The chrome scale follows the window's height, and in a shown window the
  # SizeChanged handler is what does that following. Nothing raises SizeChanged
  # here - this window is never shown - so the render has to ask for the same
  # thing by hand. Without it, -RenderMin would rasterise the DEFAULT layout
  # into the MINIMUM window and report an overflow that the real window does not
  # have, which is the same class of lie as a preview that is kinder than the
  # window.
  [void](Set-RkUiFitForClientHeight ([double]$h))

  $root = $win.Content
  $win.Content = $null                  # a Window cannot be rendered as a visual
  $root.Measure((New-Object System.Windows.Size($w, $h)))
  $root.Arrange((New-Object System.Windows.Rect(0, 0, $w, $h)))
  $root.UpdateLayout()
  $LogScroll.ScrollToEnd()
  $root.UpdateLayout()

  # An ItemsControl whose ItemsSource was set moments ago has not built its
  # item containers yet: generation is queued on the dispatcher, and
  # UpdateLayout does not drain a queue. Rendering here produced a tablet with
  # a title, a border and NOTHING INSIDE IT - which looked close enough to
  # right that it was only caught by measuring the pixels (the whole body area
  # came back as the background colour, alpha 255). Pump the queue, then lay
  # out again.
  $frame = New-Object System.Windows.Threading.DispatcherFrame
  [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle,
        [action]{ $frame.Continue = $false })
  [System.Windows.Threading.Dispatcher]::PushFrame($frame)
  $root.Measure((New-Object System.Windows.Size($w, $h)))
  $root.Arrange((New-Object System.Windows.Rect(0, 0, $w, $h)))
  $root.UpdateLayout()

  if ($RenderScroll -gt 0 -and $TabletScroll) {
    $TabletScroll.ScrollToVerticalOffset($RenderScroll)
    $root.UpdateLayout()
  }

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
  # EVERY COORDINATE BELOW IS IN CLIENT PIXELS, which is what the PNG is.
  # TransformToAncestor($root) stops at the root grid's INNER origin - the
  # grid's own Margin is applied by whatever arranges it, so it is not in the
  # transform - and the numbers came out 20 short across and 12 short down. On
  # the "is it inside" test that error points the wrong way: it makes the report
  # kinder than the window by exactly the bottom margin, which is the one thing
  # this report exists not to be.
  $ox = [double]$script:RootPad.Left
  $oy = [double]$script:RootPad.Top

  if ($RenderTablet) {
    Write-Host ('tablet: screen=' + $script:TabletScreen +
                ' source=' + @($TabletList.ItemsSource).Count +
                ' items=' + $TabletList.Items.Count +
                ' vis=' + $TabletLayer.Visibility +
                ' fontBody=' + $script:FontBody)
    # The numbers that say the tablet is a viewport and not a balloon: extent
    # larger than viewport means there is something to scroll TO, and a close
    # button with a position inside the window means there is a way back.
    $cp = $BtnTabletClose.TransformToAncestor($root).Transform((New-Object System.Windows.Point(0, 0)))
    $cIn = $(if (($cp.Y + $oy + $BtnTabletClose.ActualHeight) -le $h -and
                 ($cp.X + $ox + $BtnTabletClose.ActualWidth) -le $w) { 'inside' } else { 'OFF-SCREEN' })
    Write-Host ('tablet: scroll offset=' + [int]$TabletScroll.VerticalOffset +
                ' viewport=' + [int]$TabletScroll.ViewportHeight +
                ' extent=' + [int]$TabletScroll.ExtentHeight +
                ' scrollable=' + [int]$TabletScroll.ScrollableHeight +
                '; close button at ' + [int]($cp.X + $ox) + ',' + [int]($cp.Y + $oy) +
                ' size ' + [int]$BtnTabletClose.ActualWidth + 'x' + [int]$BtnTabletClose.ActualHeight +
                ' ' + $cIn)
  }
  # What the stage was drawn at, and what the chrome paid for it. The canvas's
  # offset is part of the report because 1:1 pixel art is only 1:1 if it lands
  # on whole device pixels: a frame at scale 1.0 sitting at x=20.5 is resampled
  # just as thoroughly as one at 0.75.
  $sp = $StageHost.TransformToAncestor($root).Transform((New-Object System.Windows.Point(0, 0)))
  Write-Host ('stage: canvas ' + $StageHost.Width + 'x' + $StageHost.Height +
              ' at ' + ($sp.X + $ox) + ',' + ($sp.Y + $oy) +
              '; frame ' + $StageFrame.ActualWidth + 'x' + $StageFrame.ActualHeight +
              '; fit ' + $script:StageFit)
  Write-Host ('chrome: scale ' + $script:UiScale + ' (floor ' + $script:UiScaleMin + ')' +
              '; power ' + [int]$BtnPower.ActualWidth + 'x' + [int]$BtnPower.ActualHeight +
              ' font ' + $BtnPower.FontSize +
              '; grid button ' + [int]$BtnTabPlayers.ActualWidth + 'x' + [int]$BtnTabPlayers.ActualHeight +
              ' font ' + $BtnTabPlayers.FontSize +
              '; title font ' + $TxtTitle.FontSize)

  # The two things the operator lost when the layout overflowed, reported as
  # coordinates rather than as an opinion about a picture: the bottom edge of
  # the last button, and the box they type into. Both must be inside $h.
  foreach ($pair in @(@('last button', $BtnTabRemove), @('command box', $TxtCommand))) {
    $el = $pair[1]
    $pt = $el.TransformToAncestor($root).Transform((New-Object System.Windows.Point(0, 0)))
    $px = $pt.X + $ox
    $py = $pt.Y + $oy
    $inside = $(if (($py + $el.ActualHeight) -le $h -and ($px + $el.ActualWidth) -le $w) { 'inside' } else { 'OFF-SCREEN' })
    Write-Host ('layout: ' + $pair[0] + ' at ' + [int]$px + ',' + [int]$py +
                ' size ' + [int]$el.ActualWidth + 'x' + [int]$el.ActualHeight +
                ' -> bottom ' + [int]($py + $el.ActualHeight) + ' of ' + $h +
                ', right ' + [int]($px + $el.ActualWidth) + ' of ' + $w + '  ' + $inside)
  }

  Write-Host ('rendered ' + $w + 'x' + $h + ' client (window ' + [int]$outerW + 'x' + [int]$outerH +
              ', chrome ' + [int]$chrome.Width + 'x' + [int]$chrome.Height + ') -> ' + $RenderTo)
  exit 0
}

# Warm the two slow calls that the "back to the list" button would otherwise
# pay for on its first click, ON THE UI THREAD. Measured: Add-Type 208ms and a
# Win32_Process query 380ms, which is the same quarter-to-a-full second stall
# [R-085] was about. Paid AFTER the window is on screen, at Background
# priority, where nothing is waiting - not before it, where 200 ms is 200 ms
# more of no window ([R-095]). The CIM query is now a cache lookup after the
# first read (Get-RkProcessFacts), so the second line is cheap either way.
[void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
  try {
    Initialize-RkWindowApi
    [void](Get-RkUiWindow -LockFile (Get-RkPanelLockFile) -ScriptPattern (Get-RkPanelScriptPattern))
  } catch { }
})

# Every frame of the room in every state colour, rasterised to stage\.cache in
# the background. First ever run on a machine: about 17 s of background work
# (61 files, measured 2026-09-14); every run after that: a directory listing.
# The UI thread then decodes a PNG (1-35 ms) instead of rasterising a text map
# (up to 1051 ms for the 1120x752 room - on this thread, the first time each
# frame was shown in each colour).
$script:Prerender = New-RkGather -Name 'prerender' -DeadlineSec 300
if ($stage) {
  [void](Start-RkGather -Gather $script:Prerender -Script {
      param($UiDir, $StagePath, $Signals)
      Add-Type -AssemblyName PresentationCore, WindowsBase
      . (Join-Path $UiDir 'rk-stage.ps1')
      $st = Read-RkStage -Path $StagePath
      $n = Initialize-RkStageCache -Stage $st -Signals $Signals
      $st = $null
      $n
    } -Arguments @($PSScriptRoot, (Join-Path $PSScriptRoot 'stage\stage.json'),
                   @($script:Col.accent, $script:Col.amber, $script:Col.danger, $script:Col.idle, $script:Col.inkSubtle)))
}

$win.Add_Closed({
    # NOTHING HERE MAY BLOCK - see the panel's Closed handler. CloseAsync only.
    Close-RkGather -Gather $script:RowGather
    Close-RkGather -Gather $script:RosterGather
    Close-RkGather -Gather $script:Prerender
    Unregister-RkUiWindow -LockFile (Get-RkConsoleLockFile -ServerDir $ServerDir)
  })

$timer.Start()
$script:StageTimer.Start()
Start-RowGather      # the first read starts now, not on the first tick
Write-RkTrace 'console: about to show'
try { [void]$win.ShowDialog() }
finally { Unregister-RkUiWindow -LockFile (Get-RkConsoleLockFile -ServerDir $ServerDir) }
