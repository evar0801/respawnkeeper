# ============================================================
# respawnkeeper.ps1 - crash detect -> diagnose on the FIRST crash -> repair
#                     while stopped -> restart, or HALT.
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI; non-ASCII breaks the parser).
# Docs: README.md (Japanese). Decisions: ..\DECISIONS.md (R-nnn).
#
# Serves BOTH servers: fc8 (Forge 1.20.1 / Java 17) and pokemoncraft
# (NeoForge 1.21.1 / Java 21). Which one is decided entirely by -ServerDir;
# no path and no version is hardcoded in this file.
#
# THE SHAPE OF IT
#   start server -> it exits -> was it clean?
#     yes -> respect that. intent=STOPPED_BY_USER. Do not resurrect it.
#     no  -> the crash report is ALREADY written (the JVM flushes it before
#            exiting), so diagnose immediately - on crash #1, not #3 [D-030].
#            Tier1 is a table lookup, no model involved [R-006].
#            Repair only while stopped, only reversible moves, then restart.
#            Anything uncertain -> HALT and wait for a human.
#
# WHAT IS DELIBERATELY OFF BY DEFAULT
#   -AutoRestart  : starting and stopping servers is the operator's call.
#   -AutoRepair   : unattended repair has a measured success rate of 1/3.
#   escalation    : Tier2/Tier3 spend tokens; opt in via respawnkeeper.config.ps1.
#   The crash-loop breaker is NOT optional and cannot be switched off [R-007].
# ============================================================

param(
  # REQUIRED. The folder holding mods\, config\, logs\ and crash-reports\ - the
  # folder run.bat sits in. Never derived: one harness serves several servers,
  # and a wrong guess looks exactly like "this server never crashes" [R-003].
  [Parameter(Mandatory)][string]$ServerDir,

  [switch]$AutoRestart,      # restart after a crash (config default: off)
  [switch]$AutoRepair,       # let Tier1 apply a reversible repair (config default: off)
  [switch]$NoHangWatch,      # disable the log-staleness hang heuristic for this run
  [switch]$NoConsoleWindow,  # do not open the console window for this run

  [switch]$ClearStaleLock,   # before starting: drop an orphan world\<level>\session.lock
  [switch]$DiagnoseOnly,     # diagnose the newest crash report and exit. Touches nothing.
  [switch]$CheckOnly,        # resolve config/paths/java and exit. Safe any time.

  # WHERE THE GAME TEMPLATES COME FROM. Defaults to harness\games, which is the
  # only value any real run should ever use. It exists so the test suite can
  # drive a THROWAWAY game whose shape does not exist in games\ - specifically
  # a script launch whose wrapper outlives the server ([R-084]), the shape that
  # produced two defects in a row while both suites stayed green because they
  # only ever ran Minecraft, where the launched process IS the server.
  [string]$GamesDir = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\rk-common.ps1')

$HarnessDir = $PSScriptRoot
$ServerDir  = Resolve-RkServerDir -Path $ServerDir -GamesDir $GamesDir
$StateDir   = Get-RkStateDir -ServerDir $ServerDir

$StatusFile   = Join-Path $StateDir 'STATUS.txt'
$StateFile    = Join-Path $StateDir 'state.json'
$HarnessLock  = Join-Path $StateDir 'harness.lock'
$ServerPidFile= Join-Path $StateDir 'server.pid'
$DiagFile     = Join-Path $StateDir 'diagnosis.json'
$ResultFile   = Join-Path $StateDir 'repair-result.txt'
$HangLog      = Join-Path $StateDir 'hangwatch.log'
# NOTE: the crash-report folder and the log file used to be hardcoded here as
# 'crash-reports' and 'logs\latest.log'. Both are Minecraft answers, and being
# computed HERE meant they were computed before the game template was even
# loaded - so the template layer could not reach them at all. They are resolved
# from the template further down, right after $Game is decided.
$StopFlagFile = Join-Path $ServerDir 'STOP_SERVER'
# MAINTENANCE_NOW: "run the maintenance lap now" - warn, clean stop, read the
# logs, start again - from the panel's restart button, the console window, or
# rk-restart.bat. Same shape as STOP_SERVER. The file may hold a number: how
# many seconds of warning the players get. Empty means the profile's default
# (dailyMaintenance.forcedWarnSeconds, 60). Shared with the UI through
# Request-RkSignal in lib\rk-common.ps1, which is the only writer that also
# checks that a supervisor is there to read it.
$MaintFlagFile = Join-Path $ServerDir 'MAINTENANCE_NOW'
# Commands typed into the console window land here as one file each. A spool
# DIRECTORY rather than one appended file: two writers and one truncating
# reader on a single file is a race, while "create a file, read it, delete it"
# has no interleaving to get wrong, and sorting by name replays them in order.
# Same shape as STOP_SERVER - a file is how anything outside the supervisor asks
# it for something.
$ConsoleInDir = Join-Path $StateDir 'console-in'

# ---- Defaults, then respawnkeeper.config.ps1 overrides them -----------------
$AutoRestartEnabled  = $false
$AutoRepairEnabled   = $false
$CrashLoopCount      = 3
$CrashLoopWindowMin  = 30
$SoakMin             = 20
$MaxRepairAttempts   = 1
$RestartBackoffSec   = 10
$EnableHangWatch     = $true
$HangStaleMin        = 15
# Opens harness\ui\rk-console.ps1 in its own process, once per supervisor
# process lifetime (not once per server start/restart). Default is "open":
# an existing profile.json written before this key existed has no
# enableConsoleWindow property at all, and Get-Variable/PSObject checks below
# treat "property missing" as "leave the default alone" - so old profiles keep
# opening the window too. See Start-RkConsoleWindow for the safety contract.
$EnableConsoleWindow = $true
# A JVM that outlives its own server (2026-09-07). See Test-RkProvenDead:
# ending it is only allowed when four independent probes agree that the world
# is already saved and the port is closed. $false goes back to never ending it.
$KillProvenDeadServer = $true
$ProvenDeadStaleMin   = 5
# THE GAME DIES AND THE LAUNCHER DOES NOT (2026-09-23, found by live test L6).
# Test-RkProvenDead answers a different question - "this process is alive but
# the server inside it is dead" - and it answers it with the PORT, so it gives
# up the moment the port is unknown. For launch.kind = 'script' the game is not
# inside the watched process at all: it is a grandchild, and when it dies the
# cmd.exe sits there looking perfectly healthy. Measured on the L6 fixture: the
# game was killed and the supervisor noticed nothing for 3.4 minutes, then read
# the launcher's own exit as an intentional stop. On a real server with
# autoRestart on, that is a server that is down and reported as running.
#
# So ask a second, cheaper question on a shorter clock: is the process the
# TEMPLATE names still there? Two consecutive misses, because one Get-Process
# sweep that comes back empty is not worth ending a lap over.
#
# THE GRACE IS NOT A STYLE CHOICE (2026-09-23, second run of L6). The first
# version of this only armed once the game process had been SEEN, and it never
# fired: the test kills the game a second or two after the launcher starts it,
# so the first sweep already found nothing and the watch sat disarmed for ever.
# A server that never brings its game up at all is the same shape. So after the
# grace the question gets asked either way - and the answer is checked against
# Get-RkServerLiveness before it counts, which is what stops a template with
# the wrong process name from declaring a healthy server dead: that is exactly
# the case where the port probe is still saying yes.
$GameGoneCheckSec  = 5
$GameGoneMisses    = 2
$GameStartGraceSec = 90
# A LAUNCHER SCRIPT THAT OUTLIVES THE SERVER IT LAUNCHED (2026-09-13, [R-089]).
# For launch.kind = 'script' the process respawnkeeper holds is a cmd.exe
# running the game's own .bat, and the game is its CHILD. A Ctrl+C stop leaves
# that cmd sitting at "Terminate batch job (Y/N)?" forever, and every
# maintenance restart leaves another one. respawnkeeper used to log "close that
# window, or answer Y in it" and walk away, which made a person type Y after
# every single stop.
#
# Ending it is NOT the "never kill the server" rule being bent, for a reason
# that is a property of Windows rather than a judgement call: ending a parent
# does not end its children, so this cannot reach the game even if every probe
# above it were wrong. And it is only reached after Get-RkServerLiveness - the
# same probe the safety gate uses - has said the server is gone, and then
# re-says it at the moment of the act.
# $false restores the old behaviour: the cmd is left for a human to close.
$CloseOrphanLauncher  = $true
$PollIntervalSec     = 20
$EnableToast         = $true
$ToastLevel          = 'important'   # off | important | all
$StopTimeoutSec      = 120
$EscalationHook      = ''
$EscalationTimeoutMin= 45
$EscalateOnHalt      = $false
$RestartAfterUnknownExit = $false
$AllowModRemoval     = $true
$ServerLabel         = ''

# ---- Daily maintenance (off by default) -------------------------------------
# Once a day: warn, stop cleanly, read the day's logs, write a report a human
# can read later, start again. The point is NOT to fix anything - it is to turn
# "the server has been up for a week and something feels off" into a dated list
# of what the logs actually complained about.
$MaintenanceEnabled  = $false
$MaintenanceAt       = '10:00'
$MaintenanceAnalyze  = $true
$MaintenanceRestart  = $true
# A command to run WHILE THE SERVER IS DOWN, in the maintenance window.
# The window already exists and is already the only moment in the day when
# the world files are quiet and nothing is being written to. That makes it
# the one place a health check can read the save without racing the server.
# Empty = nothing runs, which is the behaviour every existing profile has.
$MaintenanceHook           = ''
$MaintenanceHookTimeoutMin = 15
# The warning a FORCED maintenance restart gives the players (MAINTENANCE_NOW).
# Short on purpose: somebody pressed a button and is waiting. Games that cannot
# be told anything (no broadcast channel) skip the wait - nobody to warn.
$MaintenanceForcedWarnSec  = 60

# ---- Which model, and whose bill --------------------------------------------
# 'subscription' runs the claude CLI on the account login (no metered charge).
# 'api' makes the same CLI bill an API key, taken from an environment variable
# named here. The KEY ITSELF is never stored in a profile or read by this
# harness - only the NAME of the variable is.
$ModelBackend  = 'subscription'
$ModelName     = 'claude-opus-5'
$ModelApiKeyEnv = 'ANTHROPIC_API_KEY'

$ConfigFile = Join-Path $HarnessDir 'respawnkeeper.config.ps1'
if (Test-Path $ConfigFile) {
  try { . $ConfigFile }
  catch { Write-Host ('[respawnkeeper] FATAL: respawnkeeper.config.ps1 failed to load: ' + $_.Exception.Message); exit 1 }
} else {
  Write-Host '[respawnkeeper] note: respawnkeeper.config.ps1 not found; using built-in defaults.'
}

# Per-server profile beats the harness-wide config. One harness serves fc8 (a
# live server friends play on) and pokemoncraft (nobody connected yet); "repair
# and restart while I sleep" is a reasonable answer for one and not the other.
# Written by rk-setup.ps1.
$SrvProfile = Get-RkProfile -ServerDir $ServerDir
$SrvProfileName = ''
if ($SrvProfile) {
  $SrvProfileName = [string]$SrvProfile.profile
  foreach ($kv in @(
      @{ n = 'autoRestart';           v = { $script:AutoRestartEnabled  = [bool]$SrvProfile.autoRestart } },
      @{ n = 'autoRepair';            v = { $script:AutoRepairEnabled   = [bool]$SrvProfile.autoRepair } },
      @{ n = 'escalationHook';        v = { $script:EscalationHook      = [string]$SrvProfile.escalationHook } },
      @{ n = 'escalateOnHalt';        v = { $script:EscalateOnHalt      = [bool]$SrvProfile.escalateOnHalt } },
      @{ n = 'escalationTimeoutMin';  v = { $script:EscalationTimeoutMin= [int]$SrvProfile.escalationTimeoutMin } },
      @{ n = 'crashLoopCount';        v = { $script:CrashLoopCount      = [int]$SrvProfile.crashLoopCount } },
      @{ n = 'crashLoopWindowMin';    v = { $script:CrashLoopWindowMin  = [int]$SrvProfile.crashLoopWindowMin } },
      @{ n = 'soakMin';               v = { $script:SoakMin             = [int]$SrvProfile.soakMin } },
      @{ n = 'maxRepairAttempts';     v = { $script:MaxRepairAttempts   = [int]$SrvProfile.maxRepairAttempts } },
      @{ n = 'restartBackoffSec';     v = { $script:RestartBackoffSec   = [int]$SrvProfile.restartBackoffSec } },
      @{ n = 'restartAfterUnknownExit'; v = { $script:RestartAfterUnknownExit = [bool]$SrvProfile.restartAfterUnknownExit } },
      @{ n = 'allowModRemoval';       v = { $script:AllowModRemoval     = [bool]$SrvProfile.allowModRemoval } },
      @{ n = 'enableHangWatch';       v = { $script:EnableHangWatch     = [bool]$SrvProfile.enableHangWatch } },
      @{ n = 'hangStaleMin';          v = { $script:HangStaleMin        = [int]$SrvProfile.hangStaleMin } },
      @{ n = 'enableConsoleWindow';   v = { $script:EnableConsoleWindow = [bool]$SrvProfile.enableConsoleWindow } },
      @{ n = 'closeOrphanLauncher';   v = { $script:CloseOrphanLauncher = [bool]$SrvProfile.closeOrphanLauncher } },
      @{ n = 'enableToast';           v = { $script:EnableToast         = [bool]$SrvProfile.enableToast } },
      @{ n = 'toastLevel';            v = { $script:ToastLevel          = [string]$SrvProfile.toastLevel } },
      @{ n = 'serverLabel';           v = { $script:ServerLabel         = [string]$SrvProfile.serverLabel } }
    )) {
    if ($null -ne $SrvProfile.PSObject.Properties[$kv.n]) { & $kv.v }
  }
  if ($SrvProfile.dailyMaintenance) {
    $dm = $SrvProfile.dailyMaintenance
    if ($null -ne $dm.PSObject.Properties['enabled'])     { $MaintenanceEnabled = [bool]$dm.enabled }
    if ($dm.at)                                           { $MaintenanceAt      = [string]$dm.at }
    if ($null -ne $dm.PSObject.Properties['analyzeLogs']) { $MaintenanceAnalyze = [bool]$dm.analyzeLogs }
    if ($null -ne $dm.PSObject.Properties['restartAfter']){ $MaintenanceRestart = [bool]$dm.restartAfter }
    if ($dm.warnSeconds)      { $MaintenanceWarnSecs       = @($dm.warnSeconds | ForEach-Object { [int]$_ } | Sort-Object -Descending) }
    if ($dm.warnMessage)      { $MaintenanceWarnMessage    = [string]$dm.warnMessage }
    if ($dm.warnMinuteUnit)   { $MaintenanceWarnMinuteUnit = [string]$dm.warnMinuteUnit }
    if ($dm.warnSecondUnit)   { $MaintenanceWarnSecondUnit = [string]$dm.warnSecondUnit }
    if ($dm.hook)            { $MaintenanceHook           = [string]$dm.hook }
    if ($dm.hookTimeoutMin)  { $MaintenanceHookTimeoutMin = [int]$dm.hookTimeoutMin }
    if ($null -ne $dm.PSObject.Properties['forcedWarnSeconds']) { $MaintenanceForcedWarnSec = [int]$dm.forcedWarnSeconds }
  }
  if ($SrvProfile.model) {
    if ($SrvProfile.model.backend)   { $ModelBackend   = [string]$SrvProfile.model.backend }
    if ($SrvProfile.model.name)      { $ModelName      = [string]$SrvProfile.model.name }
    if ($SrvProfile.model.apiKeyEnv) { $ModelApiKeyEnv = [string]$SrvProfile.model.apiKeyEnv }
  }
}

# Command-line switches beat everything: they are what a human just typed.
if ($AutoRestart)  { $AutoRestartEnabled = $true }
if ($AutoRepair)   { $AutoRepairEnabled  = $true }
if ($NoHangWatch)  { $EnableHangWatch    = $false }
# 2026-09-12: opening the console window is fire-and-forget by design - nothing
# keeps a handle and nothing closes it later. That is right for a real run and
# wrong for anything that starts the supervisor repeatedly, because every run
# leaves another window on the desktop and they pile up in front of whatever the
# operator was doing. The self-test starts it three times per pass.
if ($NoConsoleWindow) { $EnableConsoleWindow = $false }
if (-not $ServerLabel) { $ServerLabel = Split-Path -Leaf $ServerDir }

# Which game is this? A profile written by rk-setup pins the answer; without one,
# detect it. Pinning matters: if two templates could match a folder, the
# supervisor must keep using the one that was verified at setup time rather than
# quietly re-deciding later.
$Game = $null
if ($SrvProfile -and $SrvProfile.game) {
  $Game = @(Get-RkGameTemplates -GamesDir $GamesDir | Where-Object { $_.id -eq $SrvProfile.game })[0]
}
if (-not $Game) { $Game = Find-RkGame -ServerDir $ServerDir -Templates (Get-RkGameTemplates -GamesDir $GamesDir) }

$Loader = $null
if ($Game -and ($Game.launch.kind -eq 'builtin')) { $Loader = Get-RkLoader -ServerDir $ServerDir }
$Port   = Get-RkServerPort -ServerDir $ServerDir -Template $Game
$PortProtocol = Get-RkPortProtocol -Template $Game
$Level  = Get-RkLevelName  -ServerDir $ServerDir

# ---- Where this game's evidence lives ---------------------------------------
# PATTERNS, not resolved files. Several games name the log per launch, and the
# console respawnkeeper captures itself is named per run, so a path resolved
# once at startup would point at a file that does not exist yet and would never
# be looked at again. Resolution happens at the moment of reading.
#   $LogPatterns : absolute glob(s). EMPTY means this game has no readable
#                  stream at all - which is a fact features have to act on, not
#                  a path to keep testing.
#   $CrashDirs   : absolute, existing only. Zero is legitimate.
$LogPatterns = @(Get-RkLogFilePatterns -ServerDir $ServerDir -Template $Game)
$CrashDirs   = @(Get-RkCrashDirs -ServerDir $ServerDir -Template $Game)
function Get-RkCurrentLog { return (Get-RkLogFile -ServerDir $ServerDir -Template $Game) }

# Daily maintenance: stop, read the day's logs, write a report, start again.
# 予告のタイミング（秒）。profile.json の dailyMaintenance.warnSeconds で上書きできる。
# 既定は従来どおり60秒前の1回だけ。fc8 と共有する部品なので、既定は変えない。
if ($null -eq $MaintenanceWarnSecs) { $MaintenanceWarnSecs = @(60) }
# {0} に「5分」「30秒」等が入る。profile.json の dailyMaintenance.warnMessage で上書きできる。
if ($null -eq $MaintenanceWarnMessage) { $MaintenanceWarnMessage = 'Scheduled restart in {0}.' }


function Format-RkCountdown {
  # 600 -> "10分" ではなく、設定した言語に依存しない形にはできないので、
  # 数字と単位だけを組み立てて warnMessage 側に埋める。
  param([int]$Seconds)
  if ($Seconds -ge 60 -and ($Seconds % 60) -eq 0) { return ([int]($Seconds / 60)).ToString() + $MaintenanceWarnMinuteUnit }
  return $Seconds.ToString() + $MaintenanceWarnSecondUnit
}
if ($null -eq $MaintenanceWarnMinuteUnit) { $MaintenanceWarnMinuteUnit = ' minutes' }
if ($null -eq $MaintenanceWarnSecondUnit) { $MaintenanceWarnSecondUnit = ' seconds' }

function Get-RkNextMaintenance {
  # The next time today's maintenance is due, or $null when it is switched off
  # or already done today. Returning $null rather than a far-future date keeps
  # the run loop free of "did I already do this" bookkeeping.
  if (-not $MaintenanceEnabled) { return $null }
  $hh = 10; $mm = 0
  if ($MaintenanceAt -match '^(\d{1,2}):(\d{2})$') { $hh = [int]$Matches[1]; $mm = [int]$Matches[2] }
  $today = (Get-Date).Date.AddHours($hh).AddMinutes($mm)
  $doneToday = $false
  if ($script:State.lastMaintenance) {
    try { $doneToday = (([datetime]$script:State.lastMaintenance).Date -eq (Get-Date).Date) } catch {}
  }
  if ($doneToday) { return $null }
  # Missed the window by hours (the machine was asleep, or it started late):
  # wait for tomorrow rather than restarting the server at a random hour.
  if ((Get-Date) -gt $today.AddHours(2)) { return $null }
  return $today
}

# $script:RkConsoleLost is set by Restore-RkConsole when the supervisor could not
# get a console back after a Ctrl+C stop. Write-Host into a destroyed console
# throws; the log FILE is the record that matters, so the echo half is dropped
# instead of being allowed to take the supervisor down. Nothing is lost from
# watchdog.log - only from a window that is no longer there to read.
$script:RkConsoleLost = $false
function Log([string]$m) { Write-RkLog -StateDir $StateDir -Message $m -Quiet:$script:RkConsoleLost }

# A toast is one-way: nothing in this harness ever reads one back, and every
# state it announces is also written to STATUS.txt / state.json / watchdog.log.
# So the ONLY job a toast has is waking a human up, and the only state that
# needs a human is one where the server is DOWN and staying down.
#
# 2026-08-27: the operator turned respawnkeeper's notifications off at the Windows
# level because the routine ones (maintenance finished, crashed-but-handling-it)
# were noise. Killing all of them silently costs the HALT notice too, which is
# the one that matters, so the switch is per-severity rather than on/off.
#   important - the server is down and waiting for a person   (default)
#   routine   - progress reports; the logs already have them
$script:ToastRank = @{ off = 0; important = 1; all = 2 }

function Toast([string]$title, [string]$body, [string]$level = 'important') {
  if (-not $EnableToast) { return }
  $want = $script:ToastRank[[string]$ToastLevel]
  if ($null -eq $want) { $want = 1 }          # unknown value -> behave like 'important'
  if ($want -eq 0) { return }
  if ($level -ne 'important' -and $want -lt 2) { return }
  try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $nodes = $xml.GetElementsByTagName('text')
    $nodes.Item(0).AppendChild($xml.CreateTextNode($title)) | Out-Null
    $nodes.Item(1).AppendChild($xml.CreateTextNode($body))  | Out-Null
    $toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('respawnkeeper').Show($toast)
  } catch { Log ('toast failed: ' + $_.Exception.Message) }
}

# ---- State ------------------------------------------------------------------
# intent is what SHOULD be true, and it is the thing that stops a well-meaning
# supervisor from resurrecting a server a human deliberately shut down. fc8's
# Layer2 heartbeat needed exactly this field; the 2026-08-02 port dropped it,
# which is why it is back.
$script:State = [ordered]@{
  schema         = 'respawnkeeper/state/1'
  intent         = 'SHOULD_RUN'      # SHOULD_RUN | STOPPED_BY_USER | HALTED
  state          = 'INIT'
  serverDir      = $ServerDir
  harnessPid     = $PID
  updated        = ''
  serverStartUtc = ''
  crashTimes     = @()
  repairAttempts = 0
  lastCrash      = ''
  lastMaintenance = ''
  lastVerdict    = ''
}

function Save-State { $script:State.updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Write-RkJson -Path $StateFile -Object $script:State }

function Commit([string]$stateName, [string]$detail, [string]$intent) {
  if ($intent) { $script:State.intent = $intent }
  $script:State.state = $stateName
  Save-State
  try { $host.UI.RawUI.WindowTitle = ("respawnkeeper [" + $stateName + "] " + $ServerLabel) } catch {}
  # STATUS.txt is the file a person actually opens. If escalation is armed but
  # cannot run, that belongs here and not only in the log - otherwise "Opus from
  # crash #1" reads as true on the one screen the operator looks at, while being false.
  $modelLine = ''
  if ((Get-Variable -Name ModelReady -Scope Script -ErrorAction SilentlyContinue) -and (-not $script:ModelReady)) {
    $modelLine = "MODEL: NOT READY - $($script:ModelNote)`r`n"
  }
  $txt = "STATE: $stateName`r`nINTENT: $($script:State.intent)`r`nSERVER: $ServerDir`r`nUPDATED: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`nAUTO_RESTART: $AutoRestartEnabled`r`nAUTO_REPAIR: $AutoRepairEnabled`r`n$modelLine$detail`r`n"
  try { [System.IO.File]::WriteAllText($StatusFile, $txt, (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

# ---- -CheckOnly -------------------------------------------------------------
if ($CheckOnly) {
  Write-Host ''
  Write-Host '=== respawnkeeper -CheckOnly (nothing is started, nothing is written to the server) ==='
  Write-Host ("ServerDir   = " + $ServerDir)
  Write-Host ("HarnessDir  = " + $HarnessDir)
  Write-Host ("StateDir    = " + $StateDir)
  if ($Loader) {
    Write-Host ("Loader      = " + $Loader.kind + ' ' + $Loader.version + '  (Minecraft ' + $Loader.mcVersion + ')')
    Write-Host ("WinArgs     = " + $Loader.winArgsRel + '  exists=' + (Test-Path (Join-Path $ServerDir $Loader.winArgsRel)))
    $j = Resolve-RkJava -Major $Loader.javaMajor
    Write-Host ("Java " + $Loader.javaMajor + "      = " + $(if ($j) { $j } else { 'NOT FOUND' }))
  } else {
    Write-Host 'Loader      = NOT FOUND (no win_args.txt under libraries\net\{neoforged\neoforge|minecraftforge\forge}\)'
  }
  Write-Host ("Port        = " + $Port + '/' + $PortProtocol + $(if ($Port -le 0) { '   <- unknown: the port is NOT used as evidence of life' } else { '' }))
  Write-Host ("LevelName   = " + $Level)
  # Printed because "which file is being read" was invisible while it was
  # hardcoded, and an unreadable stream looked exactly like a quiet one.
  $curLog = Get-RkCurrentLog
  Write-Host ("Log stream  = " + $(if ($LogPatterns.Count -eq 0) { 'NONE - this game exposes no readable log (hang watch, logscan and player roster cannot run)' } else { ($LogPatterns -join ' ; ') }))
  if ($LogPatterns.Count -gt 0) {
    Write-Host ("  current   = " + $(if ($curLog) { $curLog } else { '(no matching file exists yet)' }))
  }
  Write-Host ("Crash dirs  = " + $(if ($CrashDirs.Count -eq 0) { 'none exist - a crash can only be inferred from the log tail' } else { ($CrashDirs -join ' ; ') }))
  if ($Game) {
    $v = Get-RkGameVerificationLevel -Template $Game
    Write-Host ("Game        = " + $Game.id + '  (' + $Game.displayName + ')')
    Write-Host ("  verified  = layout=" + $v.layout + " launch=" + $v.launch + " stop=" + $v.stop + $(if (-not $v.stop) { '   <- no verified clean stop: restarts and daily maintenance stay OFF' } else { '' }))
    try { Write-Host ("  launch    = " + (Resolve-RkLaunch -ServerDir $ServerDir -Template $Game).describe) } catch { Write-Host ("  launch    = CANNOT RESOLVE: " + $_.Exception.Message) }
    Write-Host ("  stop      = " + (Get-RkStopPlan -ServerDir $ServerDir -Template $Game).describe)
  } else {
    Write-Host 'Game        = NO TEMPLATE MATCHES THIS FOLDER (rk-setup.ps1 can generate one)'
  }
  Write-Host ("Profile     = " + $(if ($SrvProfileName) { $SrvProfileName + '   (' + (Join-Path $StateDir 'profile.json') + ')' } else { '(none - run rk-setup.ps1 to create one)' }))
  Write-Host ("Daily check = " + $(if ($MaintenanceEnabled) { 'ON at ' + $MaintenanceAt + '  (stop -> read the logs -> report -> ' + $(if ($MaintenanceRestart) { 'restart' } else { 'stay down' }) + ')' } else { 'off' }))
  Write-Host ("Health hook = " + $(if ($MaintenanceHook) { $MaintenanceHook + '   (limit ' + $MaintenanceHookTimeoutMin + ' min, runs while the server is down)' } else { 'none' }))
  Write-Host ("Model       = " + $ModelBackend + ' / ' + $ModelName + $(if ($ModelBackend -eq 'api') { '   key from $env:' + $ModelApiKeyEnv + ' (set=' + [bool][System.Environment]::GetEnvironmentVariable($ModelApiKeyEnv) + ')' } else { '   (account login, no metered charge)' }))
  Write-Host ("AutoRestart = " + $AutoRestartEnabled + "   AutoRepair = " + $AutoRepairEnabled)
  Write-Host ("HangWatch   = " + $EnableHangWatch + " (stale after " + $HangStaleMin + " min)")
  if ($KillProvenDeadServer) {
    Write-Host ("Leftover JVM= ended when PROVEN DEAD (port closed + log stale " + $ProvenDeadStaleMin + " min + log ends in a completed save)")
  } else {
    Write-Host "Leftover JVM= never ended (killProvenDeadServer=false); a dead-but-running JVM waits for a human"
  }
  Write-Host ("Breaker     = HALT after " + $CrashLoopCount + " crashes in " + $CrashLoopWindowMin + " min; soak " + $SoakMin + " min resets it")
  Write-Host ("Escalation  = " + $(if ($EscalationHook) { $EscalationHook } else { '(none - unmatched crashes HALT)' }))
  Write-Host ("  on HALT   = " + $EscalateOnHalt + $(if ($EscalateOnHalt) { '  (Tier1 "human decides" cases also go to the model)' } else { '  (Tier1 "human decides" cases wait for you)' }))
  # "Escalation is armed" has to mean "escalation can actually run". Found the
  # hard way: the hook worked perfectly and the CLI was signed out, which only
  # showed up as a 4-second session and an empty verdict. Checking it costs
  # nothing (claude auth status is local) and it belongs in daylight.
  if ($EscalationHook) {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
      Write-Host '  model     = NOT READY: the claude CLI is not on PATH' -ForegroundColor Red
    } elseif ($ModelBackend -eq 'api') {
      $kv = [System.Environment]::GetEnvironmentVariable($ModelApiKeyEnv)
      if ($kv) { Write-Host ("  model     = ready (api, key from " + $ModelApiKeyEnv + ")") }
      else { Write-Host ("  model     = NOT READY: backend is api but " + $ModelApiKeyEnv + " is not set on this machine") -ForegroundColor Red }
    } else {
      $authRaw = ''
      try { $authRaw = (& claude auth status 2>&1 | Out-String) } catch { $authRaw = '' }
      if ($authRaw -match '"loggedIn"\s*:\s*true') { Write-Host '  model     = ready (subscription, signed in)' }
      elseif ($authRaw -match '"loggedIn"\s*:\s*false') { Write-Host '  model     = NOT READY: the claude CLI is signed out. Run "claude auth login" once. Tier1 and restarts still work without it.' -ForegroundColor Red }
      else { Write-Host '  model     = unknown (claude auth status gave no answer this CLI understands)' -ForegroundColor Yellow }
    }
  }
  Write-Host ("Manual stop = an exit with no crash evidence " + $(if ($RestartAfterUnknownExit) { 'IS restarted (restartAfterUnknownExit=true)' } else { 'is NOT restarted' }))
  Write-Host ("Mod removal = " + $(if ($AllowModRemoval) { 'allowed for LEAF mods only (nothing depends on them, players do not download them)' } else { 'NEVER unattended (allowModRemoval=false: this world has been played)' }))
  if ($Game -and $Game.paths.modsDir) {
    $mi = Get-RkModIndex -ServerDir $ServerDir -Template $Game
    if ($mi.available) {
      $lf = 0; $lb = 0
      foreach ($k in $mi.mods.Keys) { if ($mi.dependents.ContainsKey($k)) { $lb++ } else { $lf++ } }
      Write-Host ("  mod graph = " + $mi.scanned + " jars; " + $lf + " leaf, " + $lb + " load-bearing (only leaves are ever removable)")
    }
  }
  $live = Get-RkServerLiveness -ServerDir $ServerDir -Loader $Loader -Template $Game
  Write-Host ("Running now = " + $live.alive + '  ' + ($live.reasons -join ' | '))
  $legacy = Get-RkLegacyWatchdog -ServerDir $ServerDir
  if ($legacy.present) {
    Write-Host ("Legacy      = " + $legacy.script)
    Write-Host ("              scheduled task armed = " + $legacy.taskArmed + $(if ($legacy.taskArmed) { '  <- BLOCKS respawnkeeper' } else { '' }))
  }
  Write-Host '======================================================================================'
  exit 0
}

# ---- -DiagnoseOnly ----------------------------------------------------------
if ($DiagnoseOnly) {
  & (Join-Path $HarnessDir 'rk-diagnose.ps1') -ServerDir $ServerDir -GamesDir $GamesDir
  exit $LASTEXITCODE
}

# ---- Preflight --------------------------------------------------------------
# One supervisor per server. Two would fight over the same STATUS.txt and both
# try to start the server.
# THE SAME PROOF THE PANEL USES (Test-RkPidRunsScript), not "any live
# PowerShell": a harness.lock left by a killed supervisor names a pid that
# this machine hands to the next PowerShell it starts, and this line used to
# refuse to start for as long as THAT process lived. An unreadable command
# line still counts as the supervisor (fail towards not starting a second one).
$prev = Read-RkJson -Path $HarnessLock
if ($prev -and $prev.pid) {
  $proof = @{ ok = $false }
  try { $proof = Test-RkPidRunsScript -Id ([int]$prev.pid) -ScriptPattern 'respawnkeeper\.ps1' -What 'harness.lock' } catch { $proof = @{ ok = $true } }
  if ($proof.ok) {
    Write-Host ("[respawnkeeper] ABORT: another respawnkeeper is already watching this server (pid " + $prev.pid + ").")
    exit 1
  }
}
Write-RkJson -Path $HarnessLock -Object ([ordered]@{ pid = $PID; since = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); serverDir = $ServerDir })

# Carry the previous run's counters forward, so a supervisor that was killed
# mid-escalation does not hand a crash-looping server a fresh set of lives.
$prevState = Read-RkJson -Path $StateFile
if ($prevState) {
  if ($prevState.intent -eq 'HALTED') {
    Log 'Reconcile: previous run ended HALTED; a human relaunched us => counters reset.'
  } else {
    if ($prevState.crashTimes)     { $script:State.crashTimes     = @($prevState.crashTimes) }
    if ($prevState.repairAttempts) { $script:State.repairAttempts = [int]$prevState.repairAttempts }
    if (@($script:State.crashTimes).Count -gt 0) {
      Log ('Reconcile: carried over crashCount=' + @($script:State.crashTimes).Count + ' repairAttempts=' + $script:State.repairAttempts)
    }
  }
}

Log '=== respawnkeeper starting ==='
Log ("server=" + $ServerDir)
Log ("autoRestart=" + $AutoRestartEnabled + " autoRepair=" + $AutoRepairEnabled + " hangWatch=" + $EnableHangWatch + " clearStaleLock=" + [bool]$ClearStaleLock)

if (-not $Game) {
  Log 'FATAL: no game template recognises this folder.'
  Commit 'FATAL' 'No game template matches this folder. Run respawnkeeper.bat on it - setup can generate a template for an unknown game.' 'STOPPED_BY_USER'
  exit 1
}
Log ('game=' + $Game.id + ' (' + $Game.displayName + ')')

$Launch = $null
try { $Launch = Resolve-RkLaunch -ServerDir $ServerDir -Template $Game }
catch {
  Log ('FATAL: cannot work out how to start this server: ' + $_.Exception.Message)
  Commit 'FATAL' ('Cannot start this server: ' + $_.Exception.Message) 'STOPPED_BY_USER'
  exit 1
}
$StopPlan = Get-RkStopPlan -ServerDir $ServerDir -Template $Game
Log ('launch=' + $Launch.describe)
Log ('stop=' + $StopPlan.describe)

# A game whose stop path has never been watched by a human does not get to be
# stopped and restarted unattended. An untested shutdown that fails to save is
# not a recoverable mistake - it is somebody's world rolled back.
$Ver = Get-RkGameVerificationLevel -Template $Game
if (-not $Ver.stop) {
  if ($AutoRestartEnabled -or $MaintenanceEnabled) {
    Log ('NOTE: the stop path for ' + $Game.id + ' has never been verified by a human.')
    Log ('      Automatic restarts and daily maintenance are DISABLED for this run.')
    Log ('      Stop it once by hand with rk-stop.bat, confirm the world saved, then set')
    Log ('      verified.stop = $true in games\' + $Game.id + '.psd1.')
    Log ('      A restart YOU ask for (the panel''s restart button / rk-restart.bat) still runs: it is')
    Log ('      the same clean stop, watched by a person, and nothing is killed if it does not stop.')
    $AutoRestartEnabled = $false
    $MaintenanceEnabled = $false
  }
}

# "Escalation is armed" must mean "escalation can actually run". The first real
# run of the hook (2026-08-27) came back in 4 seconds because the claude CLI's
# OAuth session had expired - the harness was perfect and the promise was empty.
# An OAuth session can expire at any time, so checking it once at setup is not
# enough; it is re-checked on every start. `claude auth status` is local and
# spends nothing. This never blocks the launch: Tier1, repairs and restarts do
# not need a model.
$script:ModelReady = $true
$script:ModelNote  = ''
if ($EscalationHook) {
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    $script:ModelReady = $false
    $script:ModelNote  = 'the claude CLI is not on PATH'
  } elseif ($ModelBackend -eq 'api') {
    if (-not [System.Environment]::GetEnvironmentVariable($ModelApiKeyEnv)) {
      $script:ModelReady = $false
      $script:ModelNote  = ('backend is api but ' + $ModelApiKeyEnv + ' is not set on this machine')
    }
  } else {
    $authRaw = ''
    try { $authRaw = (& claude auth status 2>&1 | Out-String) } catch {}
    if ($authRaw -match '"loggedIn"\s*:\s*false') {
      $script:ModelReady = $false
      $script:ModelNote  = 'the claude CLI is signed out - run "claude auth login"'
    }
  }
  if (-not $script:ModelReady) {
    Log ('NOTE: escalation is armed but the model cannot run: ' + $script:ModelNote)
    Log ('      Tier1, repairs and restarts are unaffected. Crashes Tier1 cannot answer will HALT.')
  }
}

# Two supervisors on one server is not a style problem - the fc8 Layer2
# heartbeat would start the OLD watchdog, which would start the server,
# underneath this one. Checked mechanically rather than assumed.
$legacy = Get-RkLegacyWatchdog -ServerDir $ServerDir
if ($legacy.taskArmed) {
  Log ('ABORT: this server still has the legacy fc8 watchdog installed AND its scheduled task "' + $legacy.taskName + '" is armed.')
  Log ('  legacy supervisor : ' + $legacy.script)
  Log ('  disarm it first   : powershell -File "' + $legacy.uninstall + '"')
  Log ('  (or run: Disable-ScheduledTask -TaskName "' + $legacy.taskName + '")')
  Commit 'ABORTED' ("The legacy fc8 watchdog heartbeat task '" + $legacy.taskName + "' is still armed. Two supervisors would fight over this server. Disarm it, then start respawnkeeper.") 'STOPPED_BY_USER'
  exit 1
}
if ($legacy.present) {
  Log ('note: the legacy fc8 watchdog is still present at ' + $legacy.script + ' but its heartbeat task is not armed. Proceeding.')
}

$live = Get-RkServerLiveness -ServerDir $ServerDir -Loader $Loader -Template $Game
if ($live.alive) {
  Log ('ABORT: this server already appears to be running. ' + ($live.reasons -join ' | '))
  Commit 'ABORTED' ("Already running: " + ($live.reasons -join ' | ')) 'SHOULD_RUN'
  Toast 'respawnkeeper' 'ABORT: that server is already running.'
  exit 1
}

if ($ClearStaleLock) {
  # Reuses the ordinary repair path so that even this gets a quarantine entry
  # and an undo - it is the only action that writes under world\.
  $fake = [ordered]@{
    schema = 'respawnkeeper/diagnosis/1'; matched = $true; tier = 1
    action = 'CLEAR_WORLD_LOCK'; autoFixable = $true
    targets = @('(session.lock)'); summary = 'operator passed -ClearStaleLock'
    primary = [ordered]@{ ruleId = 'operator-clear-stale-lock' }
  }
  $tmpDiag = Join-Path $StateDir 'diagnosis.clearlock.json'
  Write-RkJson -Path $tmpDiag -Object $fake
  & (Join-Path $HarnessDir 'rk-repair.ps1') -ServerDir $ServerDir -GamesDir $GamesDir -DiagnosisFile $tmpDiag -Apply
}

# ---- Hang watch -------------------------------------------------------------
function Start-HangWatch {
  # A true hang does NOT reach the crash path: the process never exits, so
  # there is no exit code and no crash report. pokemoncraft also sets
  # max-tick-time=-1, which switches OFF the vanilla ServerHangWatchdog that
  # fc8 relied on. This heuristic fills that specific gap - and it only warns.
  # Staleness alone stays too weak to act on. Since 2026-09-07 there IS one
  # case the supervisor acts on, but it is decided elsewhere and needs three
  # further proofs on top of staleness - see Test-RkProvenDead.
  # Staleness alone is not evidence enough to kill a possibly-fine-but-quiet
  # server unattended.
  if (-not $EnableHangWatch) { return $null }

  # A hang watch with nothing to read is not a quiet hang watch - it is a
  # DISABLED one that looks identical to a healthy server, because the only
  # thing it ever produces is a warning and it can no longer produce one. The
  # old code hardcoded logs\latest.log and simply `continue`d when it was not
  # there, so on any game that writes no such file it span forever in silence.
  # If there is no stream, say so once, loudly, and do not start the job.
  if ($LogPatterns.Count -eq 0) {
    $why = ('hang watch is OFF for ' + $Game.id + ': this game exposes no readable log stream ' +
            '(paths.logFile is unset and capture.stdout is false), so "the server has gone quiet" ' +
            'cannot be observed. It is not being watched - absence of a hang warning means nothing here.')
    Log $why
    try { Add-Content -Path $HangLog -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $why) } catch {}
    return $null
  }

  $sb = {
    param($Patterns, $HangLogPath, $StaleMin, $PollSec)
    $warned = $false
    $noFileSince = Get-Date
    $saidNoFile = $false
    while ($true) {
      Start-Sleep -Seconds $PollSec
      # Resolved EVERY poll, newest match wins: games that name the log per
      # launch (and the captured console, which is named per run) would
      # otherwise pin whichever file happened to exist at startup.
      $newest = $null
      foreach ($pat in $Patterns) {
        if ($pat -match '[\*\?]') {
          foreach ($f in @(Get-ChildItem -Path $pat -File -ErrorAction SilentlyContinue)) {
            if ((-not $newest) -or ($f.LastWriteTime -gt $newest.LastWriteTime)) { $newest = $f }
          }
        } elseif (Test-Path -LiteralPath $pat -PathType Leaf) {
          $f = Get-Item -LiteralPath $pat -ErrorAction SilentlyContinue
          if ($f -and ((-not $newest) -or ($f.LastWriteTime -gt $newest.LastWriteTime))) { $newest = $f }
        }
      }
      if (-not $newest) {
        # Normal for the first minute of a run. Permanent means the template
        # points somewhere the game never writes - which is exactly the silent
        # spin this rewrite exists to end, so it gets said once.
        if ((-not $saidNoFile) -and (((Get-Date) - $noFileSince).TotalMinutes -ge $StaleMin)) {
          Add-Content -Path $HangLogPath -Value ('[{0}] hang watch has found NO log file for {1:N0} min. Patterns: {2}. Until one appears nothing is being watched, so the absence of a hang warning is not evidence of health.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ((Get-Date) - $noFileSince).TotalMinutes, ($Patterns -join ' ; '))
          $saidNoFile = $true
        }
        continue
      }
      $noFileSince = Get-Date
      $saidNoFile = $false
      $age = (Get-Date) - $newest.LastWriteTime
      if ($age.TotalMinutes -ge $StaleMin) {
        if (-not $warned) {
          Add-Content -Path $HangLogPath -Value ('[{0}] {1} has not moved for {2:N1} min - POSSIBLE HANG. This warning never kills or restarts anything by itself. A leftover process whose port is closed AND whose log ends in a completed save is ended separately (see Test-RkProvenDead); seeing this line WITHOUT that happening means the server may still be holding unsaved world state, so a human should look at the console.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $newest.Name, $age.TotalMinutes)
          $warned = $true
        }
      } else { $warned = $false }
    }
  }
  return Start-Job -ScriptBlock $sb -ArgumentList (,$LogPatterns), $HangLog, $HangStaleMin, $PollIntervalSec
}

# ---- Console window (opened once, at supervisor start) ----------------------
function Start-RkConsoleWindow {
  # Opens the per-server console window (harness\ui\rk-console.ps1) as an
  # independent process. Called exactly once, right before the main loop
  # below - NOT from inside it - so a crash-restart loop never multiplies
  # windows [contract requirement (c)]. ui\rk-console.ps1 itself is someone
  # else's file and is treated here as a black box: only the launch command
  # this contract was handed is used, nothing about its internals is assumed.
  #
  # Two safety properties, both unconditional:
  #   (a) every failure path here is caught and logged as one warning line -
  #       this function must never be able to stop the supervisor.
  #   (b) Start-Process is fire-and-forget: no handle is kept, nothing waits
  #       on the child, nothing kills it later, and nothing the child does
  #       (including the operator closing its window) is ever read back here.
  #
  # 2026-09-12 ([R-073]): (c) only ever promised not to multiply windows WITHIN
  # one supervisor run. Across runs the cleanup belonged to nobody, so every
  # start left another window on the desktop for good - the self-test, which
  # starts the supervisor three times a pass, made that obvious by piling up
  # four at a time. The fix does NOT weaken (b): this side still keeps no handle
  # and still kills nothing. The window is told which pid opened it and ends
  # itself once that pid is gone, so ownership of the cleanup sits with the only
  # party that can do it without breaking the contract.
  if (-not $EnableConsoleWindow) {
    Log 'console window: disabled (enableConsoleWindow=false in profile.json).'
    return
  }
  try {
    # (f) No interactive desktop (e.g. a Task Scheduler run set to "whether
    # user is logged on or not") has no window station for a console to open
    # on. UserInteractive is the standard .NET way to tell; when it says no,
    # skip deliberately rather than let Start-Process fail unpredictably.
    if (-not [System.Environment]::UserInteractive) {
      Log 'console window: skipped (no interactive desktop - e.g. a non-interactive scheduled task session).'
      return
    }
    # (g) THE WINDOW NOW OUTLIVES THE SUPERVISOR (2026-09-13, [R-088]), so one
    # may already be on the desktop from the previous run - opened by a
    # supervisor that has since exited, kept alive so that stopping the server
    # from it does not make the START button disappear with it.
    #
    # That moves the promise in (c) here. It used to be kept by the window
    # ending itself when its opener died; it is now kept by not opening a second
    # one while a live one is registered. The registration is proven the same
    # way harness.lock is, so a window that was killed leaves nothing behind
    # that can block the next one.
    #
    # Nothing about (b) changes: no handle is taken, nothing is waited on, and
    # the window that is already there is not touched in any way - it is only
    # counted.
    $openWin = Get-RkConsoleWindow -ServerDir $ServerDir
    if ($openWin.alive) {
      # $openWin.reason carries the lock file's full path, because the cure for
      # a wrong answer here is deleting that file and nothing in the UI names it.
      Log ('console window: one is already open for this server (' + $openWin.reason + ') - not opening a second.')
      return
    }
    $consoleScript = Join-Path $HarnessDir 'ui\rk-console.ps1'
    if (-not (Test-Path -LiteralPath $consoleScript)) {
      Log ('console window: skipped (not found: ' + $consoleScript + ').')
      return
    }
    $psCmd = Get-Command powershell -ErrorAction SilentlyContinue
    if (-not $psCmd) {
      Log 'console window: skipped (powershell.exe not found on PATH).'
      return
    }
    # NOT Start-Process -WindowStyle Hidden. That is a REQUEST: PowerShell sets
    # UseShellExecute and passes SW_HIDE as a hint, and the hint is only obeyed
    # by whoever ends up owning the window. On Windows 11 the default terminal
    # is Windows Terminal, which opens a window of its own and ignores the hint
    # entirely - so this line put an empty "Windows PowerShell" window on the
    # desktop for the whole life of every run, next to the two windows that are
    # supposed to be there. Measured 2026-09-13: launching
    # `powershell -WindowStyle Hidden` under this terminal makes a NEW visible
    # window appear ([R-077]).
    #
    # CreateNoWindow with UseShellExecute=$false is not a hint. It becomes
    # CREATE_NO_WINDOW on the CreateProcess call, so no console is allocated at
    # all and there is nothing for a terminal to decide about. It does not touch
    # GUI windows, which is why the WPF window still opens - the same shape
    # launcher\RespawnKeeper.cs already uses for the panel.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $psCmd.Source
    $psi.Arguments       = ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + $consoleScript +
                            '" -ServerDir "' + $ServerDir + '" -SupervisorPid ' + $PID)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.WorkingDirectory = $HarnessDir
    # Fire-and-forget, exactly as before: the returned object is dropped, so
    # nothing here waits on the child or can ever kill it - property (b) above.
    [void][System.Diagnostics.Process]::Start($psi)
    Log 'console window: opened (no console allocated - CREATE_NO_WINDOW).'
  } catch {
    # Whatever went wrong, the supervisor keeps going regardless - the window
    # is a convenience, the server watch loop below is the job.
    Log ('console window: failed to open (not fatal, supervisor continues): ' + $_.Exception.Message)
  }
}

# ---- Asking a server to stop, per game --------------------------------------

# The StandardInput writer that has already been given its BOM-guard newline.
# Kept at script scope so it survives across Send-RkStdin calls, and keyed on the
# writer object rather than a boolean so a restarted server (a new pipe) is
# primed again on its own.
$script:RkStdinPrimedWriter = $null

function Send-RkStdin {
  # Touching StandardInput.BaseStream emits a UTF-8 BOM into the pipe before
  # anything we write; Minecraft then reads BOM+"stop" as one mangled line and
  # rejects it. .NET Framework has no knob to suppress that, so a leading
  # newline goes first: the BOM lands on its own (rejected) line and the command
  # arrives clean. Verified at byte level, 2026-08-03, in
  # pokemoncraft\server\start_server.ps1.
  #
  # That guard belongs on the FIRST write to a pipe only. Sending it every time
  # puts an empty line in front of every command, and the server rejects each one:
  #   "Unknown or incomplete command" followed by an empty "<--[HERE]"
  # 1,428 of those in a single pokemoncraft session - exactly one per command
  # actually sent - before this was fixed ([P-042], 2026-09-08). Measured at byte
  # level by pokemoncraft\lab\pregen2\test_send_rkstdin.ps1, which runs THIS
  # function (pulled out of this file by AST) against a real redirected pipe.
  param($Proc, [string]$Line)
  try {
    # The preamble is a property of this writer, so that is what "already primed"
    # is keyed on. PID would be wrong: Windows reuses process ids.
    $writer = $Proc.StandardInput
    $prefix = ''
    if (-not [System.Object]::ReferenceEquals($script:RkStdinPrimedWriter, $writer)) {
      $prefix = "`n"
    }
    # UTF-8。ASCII だと日本語の say が全部 "?" に潰れる。
    # Java 18+ (JEP 400) は file.encoding の既定が UTF-8 なので、
    # Java 21 のこのサーバーはそのまま読める。ASCII より狭くなることはない。
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($prefix + $Line + "`n")
    $writer.BaseStream.Write($bytes, 0, $bytes.Length)
    $writer.BaseStream.Flush()
    # Marked only after the bytes are actually out: if the write threw, the pipe
    # has not been primed and the next attempt still needs the guard.
    $script:RkStdinPrimedWriter = $writer
    return $true
  } catch {
    Log ('could not write to the server console: ' + $_.Exception.Message)
    return $false
  }
}

function Initialize-RkConsoleApi {
  # The four kernel32 calls the Ctrl+C channel needs. Loaded on first use.
  #
  # The guard tests the type that Add-Type actually creates. It used to test
  # 'RkConsole', which is not the name of anything: -Namespace Rk -Name Console
  # produces Rk.Console, so the guard was never satisfied and Add-Type ran again
  # on every call. The second call throws "the type name already exists", which
  # the old caller's single try/catch turned into "Ctrl+C attempt failed" - i.e.
  # the FIRST stop request of a supervisor run worked and every later one
  # reported a failure that had nothing to do with the server.
  if ('Rk.Console' -as [type]) { return }
  Add-Type -Namespace 'Rk' -Name 'Console' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint dwProcessId);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
'@ -ErrorAction Stop | Out-Null
}

function Restore-RkConsole {
  # Put this process back on a console after Send-RkCtrlC detached it.
  #
  # FreeConsole() is unavoidable in the Ctrl+C path: a process can be attached to
  # exactly one console, so the supervisor has to leave its own before it can
  # attach to the child's. What was missing until 2026-09-12 is the way back. The
  # old code called FreeConsole and simply never re-attached, so from the first
  # stop request onwards the supervisor had no console at all - the live tee of
  # the server's output in Invoke-ServerRun and the echo half of every log line
  # went nowhere. The window fell silent and stayed silent, which reads exactly
  # like a hung supervisor. watchdog.log was fine the whole time, so nothing in
  # the evidence said what had happened.
  #
  # ATTACH_PARENT_PROCESS (0xFFFFFFFF) is the only way back, and it works only
  # when the supervisor was started FROM a console that something else still
  # owns - a cmd window, rk-start.bat. If the supervisor owned its console alone,
  # FreeConsole destroyed it and Windows has no call that brings one back.
  # There is no third option, so the failure is RECORDED instead of hidden.
  # Returns $true if a console is attached again.
  $ok = $false
  try { $ok = [Rk.Console]::AttachConsole([uint32]::MaxValue) } catch { $ok = $false }
  if ($ok) {
    $script:RkConsoleLost = $false
    Log 'console: re-attached to the parent console after the Ctrl+C; live output continues.'
    return $true
  }
  # Deliberately file-only (-Quiet): Write-Host into a console that no longer
  # exists is what would throw here, and this is the line explaining why.
  $script:RkConsoleLost = $true
  Write-RkLog -StateDir $StateDir -Quiet -Message ('console: could NOT re-attach after the Ctrl+C (AttachConsole(ATTACH_PARENT_PROCESS) failed). ' +
    'This supervisor has no console for the rest of its life, so nothing more will appear in the window - every line still goes to watchdog.log. ' +
    'This is a known limit of the Ctrl+C mechanism on Windows, NOT a hang and NOT a sign the server is in trouble.')
  return $false
}

function Send-RkCtrlC {
  # stop.kind = 'ctrlc' - Ctrl+C as a first-class stop channel. Returns $true if
  # the signal was actually generated.
  #
  # WHY THIS IS ITS OWN FUNCTION (2026-09-12)
  #   It used to be the hidden second half of Request-RkClose. A child launched
  #   with redirected handles has no main window (MainWindowHandle = 0 and
  #   CloseMainWindow() = False - measured 2026-09-12), so for every game that
  #   declared stop.kind = 'close' AND capture.stdout = $true, CloseMainWindow
  #   could not succeed even once: "close the window" was the declaration and
  #   "send Ctrl+C" was the behaviour, every single time, with nothing in the log
  #   saying so. The mismatch between the declared plan and the executed one is
  #   the defect - not the mechanism - so the two kinds are now separate and a
  #   template can say which one it means.
  #
  # !! Ctrl+C REACHES EVERY PROCESS SHARING THE CONSOLE.
  #   GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) addresses process group 0, which
  #   means "everything attached to the console this thread is attached to" - not
  #   just the child. After AttachConsole(child) that is the child's console, but
  #   a child that INHERITED the supervisor's console shares it with the
  #   supervisor and with the cmd window the operator launched from, and those get
  #   the Ctrl+C too. Windows has no per-process console signal, so this is a
  #   property of the mechanism and cannot be coded around. A game that must not
  #   take the operator's shell down with it needs its own console or a different
  #   stop channel. SetConsoleCtrlHandler(NULL, TRUE) below is what keeps the
  #   supervisor itself from acting on the signal it just sent.
  #
  # !! NOT VERIFIED AS A SAVE-SAFE STOP for any game that currently declares it.
  #   respawnkeeper has never stopped a real Valheim or Core Keeper server. If
  #   this does not work the supervisor does NOT escalate to a forced kill:
  #   killing one of these loses everything since the last autosave, which is
  #   worse than a server that is still running.
  param($Proc)
  try {
    Initialize-RkConsoleApi
  } catch {
    Log ('Ctrl+C stop is unavailable: could not load the console API: ' + $_.Exception.Message)
    return $false
  }
  $sent       = $false
  $deafened   = $false   # did SetConsoleCtrlHandler(NULL, TRUE) take effect?
  try {
    [void][Rk.Console]::FreeConsole()
    if (-not [Rk.Console]::AttachConsole([uint32]$Proc.Id)) {
      Log ('Ctrl+C stop: could not attach to the console of pid ' + $Proc.Id + ' - no signal was sent. (A process with no console of its own cannot be signalled this way.)')
      return $false
    }
    [void][Rk.Console]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
    $deafened = $true
    $sent = [Rk.Console]::GenerateConsoleCtrlEvent(0, 0)   # 0 = CTRL_C_EVENT
    Start-Sleep -Milliseconds 500
    [void][Rk.Console]::FreeConsole()
  } catch {
    Log ('Ctrl+C attempt failed: ' + $_.Exception.Message)
    $sent = $false
  } finally {
    # Both of these run on the success path, the early-return path and the throw
    # path alike, because both undo something that has ALREADY happened.
    #   - the ignore flag is process-wide and permanent until cleared; leaving it
    #     set would make this supervisor deaf to the operator's own Ctrl+C for
    #     the rest of its life.
    #   - FreeConsole has already detached us whether or not the rest worked, so
    #     skipping the re-attach is exactly what leaves the window dead.
    if ($deafened) { try { [void][Rk.Console]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) } catch {} }
    [void](Restore-RkConsole)
  }
  return [bool]$sent
}

function Request-RkClose {
  # stop.kind = 'close' - ask the server's MAIN WINDOW to close (WM_CLOSE) and
  # let it save. Correct only for a server that really owns a window.
  #
  # The Ctrl+C fallback is KEPT rather than removed: valheim.psd1 declares
  # 'close' and its launcher documents Ctrl+C as the way to stop it, so deleting
  # the fallback would take away that game's only stop path. What changed is that
  # the substitution is now ANNOUNCED. Falling through in silence is what let a
  # template claim one stop channel while a different one did all the work.
  param($Proc)
  $hwnd = 'unknown'
  try { $hwnd = [string]$Proc.MainWindowHandle } catch {}
  try { if ($Proc.CloseMainWindow()) { Log 'stop: asked the server window to close (WM_CLOSE).'; return $true } } catch {}
  Log ('stop: WM_CLOSE could not be delivered - this process has no main window (MainWindowHandle=' + $hwnd +
       '), which is what a child started with redirected handles always looks like. Falling back to Ctrl+C. ' +
       'If Ctrl+C is the real stop channel for this game, declare stop.kind = ''ctrlc'' in its template so the plan and the action match.')
  return (Send-RkCtrlC -Proc $Proc)
}

function Invoke-RkProvenDeadCheck {
  # The single place allowed to end a server process. It ends one ONLY when
  # Test-RkProvenDead can show all four of its proofs, which together mean the
  # world is already on disk and nobody is being served. Anything less and this
  # returns $false and the supervisor keeps standing down, as it always has.
  #
  # Returns $true if the process was ended (the caller should treat that as
  # "the server is gone now").
  param($Proc, [string]$Why)
  if (-not $KillProvenDeadServer) { return $false }
  if (-not $Proc) { return $false }
  if ($Proc.HasExited) { return $false }
  $pd = Test-RkProvenDead -ServerDir $ServerDir -ProcessId $Proc.Id -Template $Game -StaleMin $ProvenDeadStaleMin
  if (-not $pd.dead) { return $false }
  Log ("the server inside pid " + $Proc.Id + " is PROVEN DEAD (" + $Why + "):")
  foreach ($e in $pd.evidence) { Log ("  proof: " + $e) }
  Log "  the world is saved and the port is closed, so this JVM is a leftover, not a running server."
  Toast "respawnkeeper" "The server had already died but its process would not exit. Ending it." "important"
  try {
    Stop-Process -Id $Proc.Id -Force -ErrorAction Stop
  } catch {
    Log ("could not end pid " + $Proc.Id + ": " + $_.Exception.Message)
    return $false
  }
  [void]$Proc.WaitForExit(30000)
  if ($Proc.HasExited) { Log "the leftover process is gone."; return $true }
  Log "asked the leftover process to end but it is still there. Standing down."
  return $false
}

function Get-RkOwnedGameProcess {
  # The processes this game is made of, by the template's EXACT names, minus
  # any that another server on this machine has been proved to own.
  #
  # Deliberately not Get-RkServerLiveness: that merges three probes and answers
  # "is anything of this shape alive", and two of them answer yes for a launcher
  # that has outlived its game - the pid file holds the LAUNCHER's pid, and an
  # unknown port is skipped rather than counted as closed. The question here is
  # narrower and has to stay narrow: is the GAME still running.
  $names = @($Game.process.names | Where-Object { $_ })
  if ($names.Count -eq 0) { return @() }
  $out = @()
  foreach ($pr in (Get-RkGameProcesses -Template $Game)) {
    $own = Get-RkProcessOwnership -ServerDir $ServerDir -ProcessId $pr.Id -Loader $Loader -Template $Game
    # Only a POSITIVE foreign verdict removes a process. 'unknown' still counts
    # as ours, which keeps this from reporting a running server gone.
    if ($own.verdict -eq 'foreign') { continue }
    $out += $pr
  }
  return @($out)
}

function Request-RkStop {
  # Dispatches on the game's stop plan. Returns $true if a stop was REQUESTED
  # (not that it succeeded - the caller waits and decides).
  param($Proc, [string]$Why)
  Log ('stop requested (' + $Why + '): ' + $StopPlan.describe)
  switch ($StopPlan.kind) {
    'stdin'  { return (Send-RkStdin -Proc $Proc -Line $StopPlan.command) }
    'close'  { return (Request-RkClose -Proc $Proc) }
    # A console server whose output respawnkeeper captures. Separate from
    # 'close' on purpose - see Send-RkCtrlC for why sharing one kind between
    # them hid which of the two was actually running.
    'ctrlc'  { return (Send-RkCtrlC -Proc $Proc) }
    'script' {
      # The game's own stop script. For Palworld that script does REST
      # announce -> save -> shutdown and reads the admin password itself, so
      # respawnkeeper never sees the credential at all.
      try {
        $p = Start-Process -FilePath (Get-Command powershell).Source `
             -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $StopPlan.script + '"')) `
             -WorkingDirectory $ServerDir -PassThru -WindowStyle Hidden
        [void]$p.WaitForExit($StopPlan.timeoutSec * 1000)
        return $true
      } catch { Log ('stop script failed: ' + $_.Exception.Message); return $false }
    }
    default {
      Log 'this game has no known clean stop - a human has to stop it. Standing down.'
      return $false
    }
  }
}

function Wait-RkStopped {
  # Wait for the server to exit after a stop was requested - and RE-SEND the
  # stop while waiting.
  #
  # WHY THIS EXISTS (2026-08-31, observed on pokemoncraft):
  #   A "stop" written to stdin BEFORE the server has finished loading is
  #   silently swallowed. NeoForge does not register the console command
  #   handler until after "Done (", which on this pack takes ~60-120s. The
  #   evidence: rk-stop.bat at 07:14:26, "Done (" at 07:14:49 - the stop landed
  #   23s early, the server came up anyway, and respawnkeeper sat in
  #   WaitForExit() for a shutdown that was never going to happen. From the
  #   operator's side that reads as "rk-stop.bat does not work".
  #
  #   Waiting for "Done (" before sending would fix that one case. Re-sending
  #   fixes it AND every other reason a single line can be lost (a mod eating
  #   stdin, a full pipe, a command handler swapped out at runtime), without
  #   needing to know which one happened. So: re-send, do not predict.
  #
  # Never escalates to a kill. If the server will not stop, that stays a human
  # decision - killing Minecraft mid-save is worse than a server that is still up.
  param($Proc, [int]$TimeoutSec, [int]$ResendSec = 20)
  if ($StopPlan.kind -ne 'stdin') {
    # THE DIRECT CHILD IS NOT ALWAYS THE SERVER (2026-09-13, [R-082]).
    #
    # This used to be a single $Proc.WaitForExit(). For launch.kind = 'builtin'
    # that is right - $Proc IS the game. For launch.kind = 'script' it is not:
    # $Proc is a cmd.exe running the launcher, and the game is its child.
    #
    # Measured on Valheim, 2026-09-13, the first real stop of a real instance:
    #   11:30:26  Ctrl+C sent
    #   11:30:26  Game - OnApplicationQuit ... World save (5/5) done ...
    #   11:30:29  Net scene destroyed          <- THE SERVER WAS DOWN AND SAVED
    #   11:33:26  "did not exit within 180s"   <- what respawnkeeper reported
    # The game had stopped perfectly. The cmd.exe had not, because a Ctrl+C
    # leaves cmd sitting at "Terminate batch job (Y/N)?" with nobody to answer.
    # Waiting on the wrapper turned a clean shutdown into a reported failure -
    # and a reported failure is what would have stopped verified.stop from ever
    # being earned.
    #
    # So both are watched. The wrapper exiting is still the clean answer; the
    # game being provably gone is accepted too, and SAYS SO, because a stuck
    # wrapper is a launcher problem and must not be reported as "the server
    # would not stop". Get-RkServerLiveness is the same attribution-aware probe
    # the safety gate uses, so this cannot call a server dead that the gate
    # would call alive.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
      if ($Proc.WaitForExit(2000)) { return $true }
      $live = Get-RkServerLiveness -ServerDir $ServerDir -Loader $Loader -Template $Game
      if (-not $live.alive) {
        Log ('the server itself is gone, but the launcher process (pid ' + $Proc.Id + ') has not exited.')
        # Get-RkServerLiveness answers with .reasons (why it called something
        # alive) and .excluded (what it saw and ruled out). There is no
        # .evidence, and asking for one printed a single blank "proof:" line on
        # the first real run - a record that proves nothing, which is worse than
        # no record. What matters here is the absence, so say what was looked at.
        foreach ($e in @($live.excluded)) { Log ('  looked at, not this server: ' + $e) }
        Log ('  no probe reported it alive (port, pid file, process name' + $(if ($Loader) { ', loader signature' } else { '' }) + ').')
        Log '  that is the wrapper, not the server: a Ctrl+C leaves cmd.exe waiting at "Terminate batch job (Y/N)?".'
        Log '  counting the stop as successful. Nothing is killed - close that window, or answer Y in it.'
        return $true
      }
    }
    return $false
  }

  $startedWaiting = Get-Date
  $deadline = $startedWaiting.AddSeconds($TimeoutSec)
  # The timeout is meant to measure "how long since the server COULD have acted
  # on the stop", not wall clock. This pack takes 60-120s to load and the stop
  # timeout is 120s, so counting the boot against it would let the deadline
  # expire before the server was ever able to read the command. While the server
  # is still starting the deadline is pushed forward; $hardDeadline is what stops
  # that from becoming an unbounded wait.
  $hardDeadline = $startedWaiting.AddSeconds([Math]::Max($TimeoutSec, 900))
  $nextSend = (Get-Date).AddSeconds($ResendSec)
  $resends  = 0
  while ((Get-Date) -lt $deadline) {
    if ($Proc.WaitForExit(1000)) { return $true }
    if ((Get-Date) -ge $nextSend) {
      # Only worth re-sending once the server can actually read a command.
      # Can the server read a console command yet?
      #
      # This used to be decided by searching latest.log for "Done (". That is
      # wrong for any server that has been up across midnight: log4j rolls
      # latest.log at 00:00, so "Done (" moves into the dated archive and the
      # live file no longer contains it. From then on this answered "still
      # starting" forever, the stop was never actually sent, and the 900s hard
      # deadline expired. Observed 2026-09-07 on pokemoncraft: a server started
      # 09-06 10:00 could not be stopped at all the next morning - and the
      # 10:00 daily maintenance takes this same path every single day.
      #
      # A listening port is the direct evidence and it does not roll over.
      $ready = $false
      if ($Port -gt 0) {
        # Protocol comes from the template. A UDP game asked the TCP question
        # answers "nothing there" for as long as it runs, which would read as
        # "not started yet" and hold the stop request forever.
        $ready = (Get-RkPortHolders -Port $Port -Protocol $PortProtocol).bound
      } else {
        # No port to watch (a game whose port lives in a launch script). Fall
        # back to the log, and on any doubt re-send rather than hold.
        try {
          $curLog = Get-RkCurrentLog
          if ($curLog) {
            $fs = [System.IO.File]::Open($curLog, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs)
            $ready = ($sr.ReadToEnd() -match 'Done \(')
            $sr.Close(); $fs.Close()
          }
        } catch { $ready = $true }   # cannot tell -> assume ready and re-send anyway
      }
      if ($ready) {
        $resends++
        $waitedSec = [int]((Get-Date) - $startedWaiting).TotalSeconds
        Log ('still running ' + $waitedSec + 's after the stop request - re-sending "' + $StopPlan.command + '" (attempt ' + ($resends + 1) + ').')
        [void](Send-RkStdin -Proc $Proc -Line $StopPlan.command)
      } else {
        # "has not started yet" and "already died" look identical from here:
        # in both cases the port is closed. Ask the four proofs which one it is
        # before settling in to wait another 900 seconds.
        if (Invoke-RkProvenDeadCheck -Proc $Proc -Why 'while holding a stop request') { return $true }
        Log 'the server has not finished starting yet, so it cannot read a console command. Holding the stop and will re-send once it is up.'
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        if ((Get-Date) -ge $hardDeadline) {
          Log ('gave up waiting for the server to finish starting after ' + [int](($hardDeadline - $startedWaiting).TotalSeconds) + 's. Standing down - not killing it.')
          return $Proc.HasExited
        }
      }
      $nextSend = (Get-Date).AddSeconds($ResendSec)
    }
  }
  return $Proc.HasExited
}

function Send-RkConsoleQueue {
  # Drain the console spool into the server's stdin.
  #
  # This is a command channel into a LIVE server, so two things are not
  # negotiable. Every line is written to watchdog.log before it is sent - a
  # channel with no record is a channel nobody can audit after an incident. And
  # nothing here filters or rewrites what was typed: this is the operator's own
  # console, and a supervisor that silently edits commands is worse than one
  # that refuses them.
  #
  # "stop" typed here needs no special case. It produces a logged clean
  # shutdown, which the existing evidence check already reads as "a human
  # stopped it" - so it does not come back up on its own ([R-018]).
  param($Proc)
  if ($StopPlan.kind -ne 'stdin') { return }        # no pipe to write into
  if (-not (Test-Path -LiteralPath $ConsoleInDir)) { return }

  foreach ($f in @(Get-ChildItem -LiteralPath $ConsoleInDir -Filter '*.cmd' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $line = ''
    try { $line = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) } catch { continue }
    # Deleted BEFORE sending: if this crashes mid-send, the worst case is one
    # lost command. Deleting after would replay it on the next pass, and a
    # replayed command is not a lost one - it is a second one nobody typed.
    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    $line = $line.Trim()
    if (-not $line) { continue }
    Log ('console: ' + $line)
    [void](Send-RkStdin -Proc $Proc -Line $line)
  }
}

function Test-RkBridgeLoaded {
  # Is the server mod that carries the broadcast actually there, RIGHT NOW?
  #
  # Nothing in the template can answer this: a plugin can be uninstalled, fail
  # to patch, or simply be missing from a second copy of the same game, and the
  # file would still say 'bridge'. The mod announces itself once per boot, so
  # the log is the only honest answer - and the log for THIS run, not any log
  # ever written ([R-071]: a capability lit from something nobody watched).
  $rl = [string]$Game.broadcast.readyLine
  if (-not $rl) { return $false }
  $log = Get-RkCurrentLog
  if (-not $log) { return $false }
  try {
    foreach ($line in [System.IO.File]::ReadLines($log)) {
      if ($line -match $rl) { return $true }
    }
  } catch { return $false }
  return $false
}

function Test-RkCanBroadcast {
  # The conditions Send-RkBroadcast silently returns on. Asked out loud here so
  # a forced restart can skip a countdown nobody would hear - and so the DAILY
  # lap can refuse to stop a server it cannot warn.
  if (-not $Game.broadcast.format) { return $false }
  if ($Game.broadcast.kind -eq 'bridge') { return (Test-RkBridgeLoaded) }
  if ($Game.broadcast.kind -ne 'stdin') { return $false }
  if ($StopPlan.kind -ne 'stdin') { return $false }
  return $true
}

function Send-RkBroadcast {
  param($Proc, [string]$Message)
  if (-not $Game.broadcast.format) { return }
  $line = [string]::Format([string]$Game.broadcast.format, $Message)

  # A FILE DROP, for a game that reads no console (2026-09-15, [R-101]). The
  # server mod watches this exact folder - respawnkeeper's own console-in - and
  # moves what it has handled into done\, so the drop is auditable from both
  # ends. UTF8 WITHOUT a BOM: the mod strips one defensively, but writing one
  # would put the burden on every other reader of this folder.
  if ($Game.broadcast.kind -eq 'bridge') {
    if (-not (Test-RkBridgeLoaded)) {
      Log 'broadcast skipped: the server mod that carries it has not announced itself in this run''s log.'
      return
    }
    try {
      if (-not (Test-Path -LiteralPath $ConsoleInDir)) { New-Item -ItemType Directory -Force -Path $ConsoleInDir | Out-Null }
      $f = Join-Path $ConsoleInDir ('rk-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.txt')
      [System.IO.File]::WriteAllText($f, $line, (New-Object System.Text.UTF8Encoding($false)))
      Log ('broadcast: ' + $line)
    } catch {
      Log ('broadcast failed: ' + $_.Exception.Message)
    }
    return
  }

  if ($Game.broadcast.kind -ne 'stdin') { return }
  if ($StopPlan.kind -ne 'stdin') { return }   # no stdin pipe to write to
  [void](Send-RkStdin -Proc $Proc -Line $line)
}

# ---- Start the server one time and wait for it to exit ----------------------
function Invoke-ServerRun {
  # stdin is a real pipe, never a file: redirecting stdin from a file sends EOF
  # immediately and Minecraft reads EOF as "stop" (recorded in pokemoncraft).
  #
  # stdout is only captured for games that write no log of their own - which is
  # MOST of them. Minecraft writes logs\latest.log and keeps its own console
  # window, so nothing is redirected there and the window behaves as before.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName              = $Launch.exe
  $psi.WorkingDirectory      = $Launch.workingDir
  $psi.Arguments             = $Launch.arguments
  $psi.UseShellExecute       = $false
  $psi.RedirectStandardInput = ($StopPlan.kind -eq 'stdin')
  $psi.CreateNoWindow        = $false

  $consoleLog = ''
  if ($Launch.captureStdout) {
    $consoleDir = Join-Path $StateDir 'console'
    if (-not (Test-Path $consoleDir)) { New-Item -ItemType Directory -Force -Path $consoleDir | Out-Null }
    $consoleLog = Join-Path $consoleDir ('console-' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
  }

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $proc.EnableRaisingEvents = $true

  $subs = @()
  if ($Launch.captureStdout) {
    # Tee: the operator still sees the server output live in THIS window, and
    # respawnkeeper still gets a file to diagnose from afterwards.
    $sink = {
      param($s, $e)
      if ($null -eq $e.Data) { return }
      # The echo is the half that can fail: after a Ctrl+C stop the supervisor
      # may have no console left to write to (see Restore-RkConsole), and an
      # unguarded Write-Host then throws inside an event handler, where the error
      # surfaces nowhere useful. The FILE write is the record and it is attempted
      # regardless of whether anybody is watching the window.
      try { Write-Host $e.Data } catch {}
      try { Add-Content -LiteralPath $Event.MessageData -Value $e.Data -Encoding UTF8 } catch {}
    }
    $subs += Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $sink -MessageData $consoleLog
    $subs += Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $sink -MessageData $consoleLog
  }

  [void]$proc.Start()
  if ($Launch.captureStdout) { $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine() }

  Set-Content -LiteralPath $ServerPidFile -Value $proc.Id -NoNewline -Encoding ascii
  Log ('started: ' + $Launch.describe + ' (pid ' + $proc.Id + ')')
  Log ('clean stop: double-click rk-stop.bat, or create ' + $StopFlagFile)
  if ($consoleLog) { Log ('console captured to ' + $consoleLog) }

  if (Test-Path -LiteralPath $StopFlagFile) { Remove-Item -LiteralPath $StopFlagFile -Force -ErrorAction SilentlyContinue }
  # A MAINTENANCE_NOW written while nothing was running is a request to restart
  # a server that has just been started. Discarded, and said so.
  if (Test-Path -LiteralPath $MaintFlagFile) {
    Remove-Item -LiteralPath $MaintFlagFile -Force -ErrorAction SilentlyContinue
    Log 'a stale MAINTENANCE_NOW was lying in the server folder; discarded (the server has only just started).'
  }

  # Anything typed into the console while the server was DOWN is discarded at
  # boot rather than replayed into it. A queued command is a statement about the
  # server that was running when it was typed; firing it minutes later, into a
  # freshly repaired server, is a command nobody meant to give.
  if (Test-Path -LiteralPath $ConsoleInDir) {
    Get-ChildItem -LiteralPath $ConsoleInDir -Filter '*.cmd' -File -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
    # The same rule for the bridge's own drops (rk-*.txt, 2026-09-23). A "10
    # minutes until maintenance" left over from the run that just died is a
    # sentence about a world that no longer exists. Only respawnkeeper's own
    # prefix - anything a person put here by hand is theirs.
    Get-ChildItem -LiteralPath $ConsoleInDir -Filter 'rk-*.txt' -File -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } else {
    New-Item -ItemType Directory -Force -Path $ConsoleInDir | Out-Null
  }

  $userStopped    = $false
  $maintenance    = $false
  $forced         = $false   # the maintenance lap was asked for NOW (MAINTENANCE_NOW)
  $warned         = @{}   # 予告済みのしきい値。bool ではなく集合（複数回予告するため）
  $nextMaint      = Get-RkNextMaintenance
  # Get-RkNextMaintenance only ever answers about TODAY, and returns $null once
  # today's window has closed. Asking it once meant a long-lived process kept
  # that $null forever: a server started in the evening never saw maintenance
  # again. (2026-08-30: pokemoncraft was started 08-29 20:33 and silently
  # skipped the 08-30 10:00 window - and every window after it.) So remember
  # which day the answer is about, and ask again when the date rolls over.
  $maintDay       = (Get-Date).Date
  # Not checked every pass: the proofs read the port table and the log file,
  # and a dead server stays dead for a minute without anybody suffering.
  $nextDeadCheck  = (Get-Date).AddSeconds(60)

  # --- is the GAME still there, not just the launcher? (2026-09-23, L6) ----
  # Only armed for a launcher shape, and only once the game has actually been
  # SEEN. Seeing it first is what proves the template's process names are right
  # for this server; without that proof a wrong name would read as "the server
  # died" one second after every start.
  $watchGameProc  = (($Game.launch.kind -eq 'script') -and
                     (@($Game.process.names | Where-Object { $_ }).Count -gt 0) -and
                     (-not $Game.process.matchCommandLine))
  $gameSeen       = $false
  $goneMisses     = 0
  $gameGone       = $false
  $nextGoneCheck  = (Get-Date).AddSeconds($GameGoneCheckSec)
  # Per game, because the wait is a fact about the LAUNCHER, not about
  # respawnkeeper: a .bat that runs a SteamCMD update before it starts anything
  # has no game process for minutes, and that is not a dead server.
  $graceSec       = $GameStartGraceSec
  if ($Game.launch.startGraceSec) { $graceSec = [int]$Game.launch.startGraceSec }
  $graceEndsAt    = (Get-Date).AddSeconds($graceSec)
  if ($watchGameProc) {
    Log ('watching for the game itself: ' + (@($Game.process.names) -join '/') +
         ' (every ' + $GameGoneCheckSec + 's, after a ' + $graceSec + 's start grace; the launcher exiting is not the only way this server can end).')
  }

  # --- DID IT ACTUALLY COME UP? (Eva, 2026-09-14) --------------------------
  # "started" above means a process was created. It does not mean anybody can
  # join. Measured on the real Everheim instance the same day: the process
  # existed and UDP 2456 was bound at 13:28:06, and the game did not say
  # 'Opened Steam server' until 13:28:25 - nineteen seconds during which every
  # liveness probe read alive and the server was still loading. On a first
  # world generation that gap is 113 seconds.
  #
  # So the log gets asked, once the game has had a moment to write it. This is
  # REPORT ONLY on purpose: it changes no decision yet, because the ready
  # markers have been measured for two games and inferred for none of the rest,
  # and a gate whose evidence is not in for every game is a gate that fails in
  # the dark. What it does is put the answer in the log where the next question
  # ("it says it started, so why can nobody join?") is asked.
  $startedAt      = Get-Date
  $readySettled   = ''
  $nextReadyCheck = (Get-Date).AddSeconds(5)

  try {
    while (-not $proc.HasExited) {

      # --- a new day: yesterday's answer is stale, ask again ---
      if ((Get-Date).Date -ne $maintDay) {
        $maintDay = (Get-Date).Date
        if (-not $maintenance) {
          $warned    = @{}
          $nextMaint = Get-RkNextMaintenance
          if ($nextMaint) { Log ('new day: next daily maintenance at ' + $nextMaint.ToString('yyyy-MM-dd HH:mm')) }
        }
      }

      # --- did the start actually finish? (read from the log, once) ---
      if ((-not $readySettled) -and ((Get-Date) -ge $nextReadyCheck)) {
        $nextReadyCheck = (Get-Date).AddSeconds(5)
        $rd = $null
        try { $rd = Get-RkServerReadiness -ServerDir $ServerDir -Template $Game -Since $startedAt } catch { }
        if ($rd) {
          $secs = [int](((Get-Date) - $startedAt).TotalSeconds)
          switch ([string]$rd.verdict) {
            'ready' {
              $readySettled = 'ready'
              Log ('the server finished starting after ' + $secs + 's: ' + $rd.readyLine)
            }
            'trouble' {
              $readySettled = 'trouble'
              Log ('the log is complaining ' + $secs + 's after start: ' + $rd.detail)
              foreach ($p in @($rd.problems | Select-Object -First 3)) { Log ('  ' + $p) }
              Log '  nothing is being done about it here - this is a reading, not a decision.'
            }
            'nomarker' {
              $readySettled = 'nomarker'
              # Not a failure of this server. A gap in what has been established
              # about this GAME, and the first thing to fix when adding one.
              Log ('cannot confirm the start from the log: ' + $rd.detail)
              Log '  the port and the process only prove something of the right shape exists.'
            }
            'nolog' {
              $readySettled = 'nolog'
              Log ('cannot confirm the start from the log: ' + $rd.detail)
            }
            'unknown' {
              $readySettled = 'unknown'
              Log ('cannot confirm the start from the log: ' + $rd.detail)
            }
            default { }   # starting / stale: still within the window, ask again
          }
        }
      }

      # --- an operator asked for the maintenance lap NOW (MAINTENANCE_NOW) ---
      # Not a separate stop path: it moves the daily window to "a moment from
      # now" and lets the block below run exactly as it does every morning -
      # warn, clean stop, read the logs, start again. One code path that is
      # exercised daily is worth more than a second one that is exercised when
      # somebody is already annoyed.
      if (Test-Path -LiteralPath $MaintFlagFile) {
        $body = ''
        try { $body = ([System.IO.File]::ReadAllText($MaintFlagFile)).Trim() } catch {}
        Remove-Item -LiteralPath $MaintFlagFile -Force -ErrorAction SilentlyContinue
        if ($maintenance) {
          Log 'MAINTENANCE_NOW ignored: a maintenance stop is already in progress.'
        } else {
          $secs = $MaintenanceForcedWarnSec
          if ($body -match '^\d+$') { $secs = [int]$body }
          if (-not (Test-RkCanBroadcast)) {
            if ($secs -gt 0) { Log ('forced maintenance restart: this game cannot be told anything (no broadcast channel), so the ' + $secs + 's warning is skipped.') }
            $secs = 0
          }
          $forced    = $true
          $warned    = @{}
          $nextMaint = (Get-Date).AddSeconds($secs)
          Log ('forced maintenance restart requested (MAINTENANCE_NOW): warn ' + $secs + 's, then clean stop, then start again.')
          if (-not $Ver.stop) { Log ('  note: the stop path for ' + $Game.id + ' is unverified. Nothing is killed if it does not stop - respawnkeeper stands down instead.') }
          Commit 'MAINT_PENDING' ('Maintenance restart requested. Stopping cleanly in ~' + $secs + 's, then reading the logs, then starting again.') 'SHOULD_RUN'
        }
      }

      # --- the daily maintenance window (or the forced one, moved to now) ---
      if ($nextMaint -and (-not $maintenance)) {
        $maintWord = $(if ($forced) { 'forced maintenance restart' } else { 'daily maintenance' })
        $secsLeft = ($nextMaint - (Get-Date)).TotalSeconds

        # A DAILY STOP NOBODY CAN BE WARNED ABOUT DOES NOT HAPPEN (2026-09-23).
        #
        # This is the one automatic action whose cost lands on somebody else -
        # the people in the world when it fires - which is why the capability
        # contract makes dailyMaintenance NEED a broadcast channel. That check
        # is static: it reads the template. The channel can still be absent at
        # RUN time (valheim's is a server mod, and a mod can be missing), and
        # the static answer would happily let this fire anyway.
        #
        # Only games that CLAIM a channel are gated. A game that never claimed
        # one behaves exactly as it did before - this cannot switch off fc8's
        # or pokemoncraft's morning lap, whose stdin channel is always there.
        # The FORCED lap is not gated either: a person pressed that button and
        # is waiting, and it already announces that it is skipping the warning.
        if ((-not $forced) -and $Game.broadcast.kind -and (-not (Test-RkCanBroadcast)) -and ($secsLeft -le 0)) {
          Log ('daily maintenance SKIPPED: this game declares a broadcast channel (' + $Game.broadcast.kind +
               ') but it is not answering in this run, so nobody online could be warned before the stop.')
          Log '  the server is left running. Fix the channel, or turn the daily lap off in profile.json.'
          Toast ('respawnkeeper: ' + $ServerLabel) 'Daily maintenance skipped: the server cannot be warned. Left running.' 'important'
          $warned    = @{}
          $nextMaint = $nextMaint.AddDays(1)
          $secsLeft  = ($nextMaint - (Get-Date)).TotalSeconds
        }
        # Every threshold that has been crossed is marked, but only ONE line is
        # said, and it names the NEAREST crossed threshold - or the real time
        # left when even that is more than a few seconds off. Before this, a
        # supervisor started two minutes before the window announced "10
        # minutes" (the farthest threshold, the first in the list), and a
        # 60-second forced restart would have announced the same.
        $crossed = @($MaintenanceWarnSecs | Where-Object { (-not $warned.ContainsKey($_)) -and ($secsLeft -le $_) -and ($secsLeft -gt 0) })
        if ($crossed.Count -gt 0) {
          foreach ($th in $crossed) { $warned[$th] = $true }
          $say = [int](($crossed | Measure-Object -Minimum).Minimum)
          if (($say - $secsLeft) -gt 5) { $say = [int][Math]::Ceiling($secsLeft) }
          Send-RkBroadcast -Proc $proc -Message ([string]::Format($MaintenanceWarnMessage, (Format-RkCountdown -Seconds $say)))
          Log ($maintWord + ' in ~' + $say + 's - warned the players.')
          Commit 'MAINT_PENDING' ('Maintenance in ~' + $say + 's: players warned. Then a clean stop, the log scan, and a restart.') 'SHOULD_RUN'
        }
        if ($secsLeft -le 0) {
          $maintenance = $true
          if (-not (Request-RkStop -Proc $proc -Why $maintWord)) {
            Log ('could not request a stop for ' + $maintWord + '; skipping this window.')
            $maintenance = $false
            if ($forced) { $forced = $false; $nextMaint = Get-RkNextMaintenance } else { $nextMaint = $nextMaint.AddDays(1) }
          } else {
            Commit 'STOPPING' ('Stopping cleanly for ' + $maintWord + '. It will be started again once the logs have been read.') 'SHOULD_RUN'
            if (-not (Wait-RkStopped -Proc $proc -TimeoutSec $StopPlan.timeoutSec)) {
              Log ('WARNING: did not exit within ' + $StopPlan.timeoutSec + 's of the maintenance stop. NOT killing it - standing down.')
              return @{ exitCode = -1; userStopped = $false; maintenance = $true; forced = $forced; stillAlive = $true; pid = $proc.Id; consoleLog = $consoleLog }
            }
            break
          }
        }
      }

      # --- an operator asked it to stop ---
      if (Test-Path -LiteralPath $StopFlagFile) {
        Remove-Item -LiteralPath $StopFlagFile -Force -ErrorAction SilentlyContinue
        if (Request-RkStop -Proc $proc -Why 'STOP_SERVER flag') { $userStopped = $true }
        else {
          Log 'no clean stop available for this game; leaving the server running.'
          return @{ exitCode = -1; userStopped = $true; maintenance = $false; forced = $false; stillAlive = $true; pid = $proc.Id; consoleLog = $consoleLog }
        }
        Commit 'STOPPING' 'Stop requested by you. Waiting for the server to save and exit; it will NOT be restarted.' 'STOPPED_BY_USER'
        if (-not (Wait-RkStopped -Proc $proc -TimeoutSec $StopPlan.timeoutSec)) {
          Log ('WARNING: did not exit within ' + $StopPlan.timeoutSec + 's of the stop request. NOT killing it - standing down.')
          return @{ exitCode = -1; userStopped = $true; maintenance = $false; forced = $false; stillAlive = $true; pid = $proc.Id; consoleLog = $consoleLog }
        }
        break
      }

      # --- the server may have died without its process exiting ---
      # Get-RkServerLiveness answers "alive" here, and is right to: any one probe
      # saying alive means alive, and the process probe still matches. That is
      # exactly how a dead server went unnoticed for 76 minutes on 2026-09-07.
      if ((Get-Date) -ge $nextDeadCheck) {
        $nextDeadCheck = (Get-Date).AddSeconds(60)
        if (Invoke-RkProvenDeadCheck -Proc $proc -Why 'periodic check') { break }
      }

      # --- the GAME is gone and the LAUNCHER is still standing ---
      # Nothing is killed here and nothing is decided here beyond "stop
      # watching": whether this was a crash or a person pulling the game out
      # from under the launcher is read from the log afterwards, by the same
      # evidence that judges every other exit.
      if ($watchGameProc -and ((Get-Date) -ge $nextGoneCheck)) {
        $nextGoneCheck = (Get-Date).AddSeconds($GameGoneCheckSec)
        $gp = @(Get-RkOwnedGameProcess)
        if ($gp.Count -gt 0) {
          if (-not $gameSeen) {
            $gameSeen = $true
            Log ('the game process is up: ' + $gp[0].ProcessName + ' (pid ' + $gp[0].Id + ').')
          }
          $goneMisses = 0
        } elseif ($gameSeen -or ((Get-Date) -ge $graceEndsAt)) {
          $goneMisses++
          if ($goneMisses -ge $GameGoneMisses) {
            # ASK THE OTHER PROBES BEFORE BELIEVING IT. A template that names
            # the wrong process is indistinguishable from a dead game by this
            # sweep alone - and it is the one mistake that would take a healthy
            # server off watch. The port answers that, and a port that is still
            # bound outranks a name that never matched.
            $live = Get-RkServerLiveness -ServerDir $ServerDir -Loader $Loader -Template $Game
            if ($live.alive) {
              $goneMisses = 0
              if (-not $gameSeen) {
                Log ('no ' + (@($Game.process.names) -join '/') + ' process has ever been seen, but the server reads alive (' +
                     (@($live.reasons) -join '; ') + '). Not treating it as gone - check process.names in this game template.')
                $graceEndsAt = (Get-Date).AddSeconds(3600)   # say it once an hour, not every 10s
              }
            } else {
              $gameGone = $true
              $what = $(if ($gameSeen) { 'the server is GONE' } else { 'the server is GONE and was never seen at all in the first ' + $graceSec + 's' })
              Log ($what + ': no ' + (@($Game.process.names) -join '/') +
                   ' process for ' + ($GameGoneCheckSec * $GameGoneMisses) + 's and no probe says otherwise, while the launcher (pid ' +
                   $proc.Id + ') is still running.')
              Log '  the launcher exiting is what this loop normally waits for, and it is not going to.'
              break
            }
          }
        }
      }

      # --- an operator typed something in the console window ---
      Send-RkConsoleQueue -Proc $proc

      Start-Sleep -Milliseconds 500
    }
    # THE LOOP CAN BREAK WITH THE SERVER GONE AND $proc STILL ALIVE (2026-09-13, [R-084]).
    #
    # Wait-RkStopped returns $true in two different situations: $proc exited, or
    # the SERVER was proven gone while $proc - a launcher script, not the game -
    # sits at "Terminate batch job (Y/N)?" after the Ctrl+C. This line used to
    # be an unbounded WaitForExit, which in the second case waits for a cmd.exe
    # that will never exit on its own.
    #
    # Measured on Everheim, the first real press of the maintenance-restart
    # button: 13:20:43 stop requested -> 13:20:48 "the server itself is gone"
    # -> and then nothing. STATUS.txt sat at STOPPING, the game was long dead,
    # and the restart never came, because the supervisor was blocked here on
    # cmd.exe pid 39564. [R-082] fixed the REPORT and left the WAIT behind it.
    #
    # The bound is short because by this point the question is already answered.
    # Nothing is killed: the wrapper is left for a person to close.
    $orphanWrapper = $false
    if (-not $proc.HasExited) {
      if (-not $proc.WaitForExit(10000)) {
        $orphanWrapper = $true
        Log ('the launcher process (pid ' + $proc.Id + ') is still running 10s after the server exited; not waiting on it any longer.')
        Log '  that is a cmd.exe holding at "Terminate batch job (Y/N)?".'
        Log '  respawnkeeper is carrying on: the SERVER is what it was waiting for, and the server is gone.'
        if (-not $CloseOrphanLauncher) {
          Log '  closeOrphanLauncher=false, so it is left alone - close that window, or answer Y in it.'
        } else {
          # ASK AGAIN, HERE, RATHER THAN TRUSTING THE ANSWER FROM TEN SECONDS AGO.
          # This is the only place respawnkeeper ends a process it did not prove
          # dead in the same breath, so the proof is taken at the moment of the
          # act and not inherited from the caller.
          $stillLive = Get-RkServerLiveness -ServerDir $ServerDir -Loader $Loader -Template $Game
          if ($stillLive.alive) {
            Log ('  NOT ending it: a probe now says the server is alive again (' + (@($stillLive.reasons) -join '; ') + '). Standing down.')
          } else {
            try {
              Stop-Process -Id $proc.Id -Force -ErrorAction Stop
              [void]$proc.WaitForExit(5000)
              Log ('  ended the launcher script (pid ' + $proc.Id + ') so nobody has to answer Y to it. This cannot reach the game: on Windows ending a parent does not end its children, and the game is already gone.')
            } catch {
              Log ('  could not end the launcher script: ' + $_.Exception.Message + ' - close that window, or answer Y in it.')
            }
          }
        }
      }
    }
  } finally {
    foreach ($s in $subs) { Unregister-Event -SubscriptionId $s.Id -ErrorAction SilentlyContinue }
    if ($proc.HasExited -or $orphanWrapper) { Remove-Item -LiteralPath $ServerPidFile -Force -ErrorAction SilentlyContinue }
  }
  # Reading .ExitCode on a process that has not exited THROWS. With the wrapper
  # orphaned there is no exit code to read, and -1 is the value every other
  # "we stopped it on purpose" path already returns.
  $exitCode = -1
  if ($proc.HasExited) { try { $exitCode = $proc.ExitCode } catch { $exitCode = -1 } }
  return @{ exitCode = $exitCode; userStopped = $userStopped; maintenance = $maintenance; forced = $forced; stillAlive = $false; pid = $proc.Id; consoleLog = $consoleLog; gameGone = $gameGone }
}

# ---- Escalation (Tier2 / Tier3) ---------------------------------------------
function Invoke-Escalation {
  # Tier1 said "I do not know this one". The hook is whatever the operator
  # configured - typically a headless model session. Its contract is exactly
  # Tier1's: write the first line of repair-result.txt as FIXED:/HALT:/
  # SECURITY-HALT:. It must never start the server; that is this file's job.
  param([string]$CrashName)
  if (-not $EscalationHook) { return 'HALT: no escalation hook configured (Tier1 had no match)' }
  if (-not (Test-Path -LiteralPath $EscalationHook)) { return ('HALT: escalation hook not found: ' + $EscalationHook) }

  Commit 'ESCALATING' ("Tier1 had no match for " + $CrashName + "; running the escalation hook. Server is DOWN meanwhile.") 'SHOULD_RUN'
  Remove-Item -LiteralPath $ResultFile -Force -ErrorAction SilentlyContinue

  & (Join-Path $HarnessDir 'rk-lock.ps1') -ServerDir $ServerDir -Acquire -Reason 'escalation hook' -Owner 'respawnkeeper' -Quiet | Out-Null
  $gotLock = ($LASTEXITCODE -eq 0)
  if (-not $gotLock) { return 'HALT: repair lock is held by someone else; not escalating' }

  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell).Source
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + $EscalationHook + '"' +
                      ' -ServerDir "' + $ServerDir + '"' +
                      ' -DiagnosisFile "' + $DiagFile + '"' +
                      ' -ResultFile "' + $ResultFile + '"')
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($EscalationTimeoutMin * 60 * 1000)) {
      try { $p.Kill() } catch {}
      return 'HALT: escalation hook timed out'
    }
  } catch {
    return ('HALT: escalation hook failed to run: ' + $_.Exception.Message)
  } finally {
    & (Join-Path $HarnessDir 'rk-lock.ps1') -ServerDir $ServerDir -Release -Owner 'respawnkeeper' -Quiet | Out-Null
  }

  if (Test-Path -LiteralPath $ResultFile) {
    $first = (Get-Content -LiteralPath $ResultFile -TotalCount 1)
    if ($first) { return $first.Trim() }
  }
  return 'HALT: escalation hook produced no verdict'
}

# Opened exactly once here, after every abort/preflight check above has
# already passed and before the loop that can restart the server many times
# over the supervisor's lifetime - see Start-RkConsoleWindow for why.
Start-RkConsoleWindow

# ---- Main loop --------------------------------------------------------------
$halted = $false
while ($true) {

  $startTime = Get-Date
  $script:State.serverStartUtc = $startTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
  Commit 'RUNNING' ("Started " + $startTime.ToString('yyyy-MM-dd HH:mm:ss') + ". Clean stop: double-click rk-stop.bat, or create " + $StopFlagFile) 'SHOULD_RUN'

  $hangJob = Start-HangWatch
  $run = Invoke-ServerRun
  if ($hangJob) { Stop-Job $hangJob -ErrorAction SilentlyContinue; Remove-Job $hangJob -Force -ErrorAction SilentlyContinue }

  $uptimeMin = ((Get-Date) - $startTime).TotalMinutes
  Log ('server exited. code=' + $run.exitCode + ' uptime=' + [math]::Round($uptimeMin, 1) + 'min')

  if ($run.stillAlive) {
    Commit 'UNKNOWN' 'Sent "stop" but the server has not exited. respawnkeeper is standing down rather than killing it.' 'SHOULD_RUN'
    break
  }

  # A run that lasted long enough is evidence the last repair actually worked.
  if ($uptimeMin -ge $SoakMin) {
    if ((@($script:State.crashTimes).Count -gt 0) -or ($script:State.repairAttempts -gt 0)) {
      Log ('soak passed (' + [math]::Round($uptimeMin, 1) + ' >= ' + $SoakMin + ' min): crash counters reset.')
    }
    $script:State.crashTimes = @()
    $script:State.repairAttempts = 0
  }

  # ---- Why did it stop? ---------------------------------------------------
  # The exit code alone cannot answer this. Killing java from Task Manager
  # gives a NON-ZERO exit and leaves no crash report - from the outside that is
  # identical to a crash whose report never got written. So the log tail and
  # any hs_err_pid file are read too. See Get-RkShutdownEvidence.
  $ev = Get-RkShutdownEvidence -ServerDir $ServerDir -Since $startTime -Template $Game -ConsoleLog $run.consoleLog
  $newCrash = $null
  if ($ev.crashReport) { $newCrash = Get-Item -LiteralPath $ev.crashReport }
  Log ('shutdown evidence: verdict=' + $ev.verdict +
       ' cleanShutdownLogged=' + $ev.cleanShutdownLogged +
       ' hs_err=' + $(if ($ev.jvmCrashLog) { Split-Path -Leaf $ev.jvmCrashLog } else { 'none' }) +
       ' exceptionInTail=' + $ev.exceptionInTail)

  # ---- Daily maintenance: WE stopped it, so we start it again -------------
  # This is deliberately checked before the clean-stop branch. A maintenance
  # stop looks exactly like an operator stop (that is the point - it uses the
  # same clean shutdown), so without this it would set intent=STOPPED_BY_USER
  # and the server would stay down until morning.
  if ($run.maintenance) {
    # A forced lap counts as today's maintenance too: it did everything the
    # morning one does, and running the morning one on top of it would take
    # the server down twice for one day's report.
    $script:State.lastMaintenance = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Save-State
    $lapWord = $(if ($run.forced) { 'forced maintenance' } else { 'daily maintenance' })
    Log ($lapWord + ' stop completed (uptime ' + [math]::Round($uptimeMin, 1) + ' min).')

    if ($MaintenanceAnalyze) {
      Commit 'ANALYZING' 'Daily maintenance: reading the day''s logs. The server is down for a moment.' 'SHOULD_RUN'
      try {
        & (Join-Path $HarnessDir 'rk-logscan.ps1') -ServerDir $ServerDir -GamesDir $GamesDir -Quiet
        Log ('daily report written to ' + (Join-Path $StateDir 'reports'))
      } catch { Log ('log scan failed (not fatal): ' + $_.Exception.Message) }
    }

    # The health gate runs here, in the quiet: the server is down, the world
    # files are closed, and nothing is being written. Reading the save at any
    # other time races the autosave.
    if ($MaintenanceHook) {
      Commit 'ANALYZING' 'Daily maintenance: running the health check. The server is down for a moment.' 'SHOULD_RUN'
      Log ('health check: running (limit ' + $MaintenanceHookTimeoutMin + ' min) -> ' + $MaintenanceHook)
      try {
        $hk = Invoke-RkMaintenanceHook -Command $MaintenanceHook `
                -TimeoutMin $MaintenanceHookTimeoutMin `
                -WorkingDir $ServerDir -ReportDir (Join-Path $StateDir 'reports')
        switch ($hk.verdict) {
          'TIMEOUT'      { Log ('health check: TIMED OUT after ' + $MaintenanceHookTimeoutMin + ' min - killed the check, restarting the server anyway.') }
          'START_FAILED' { Log ('health check: could not start (not fatal): ' + $hk.error) }
          default {
            Log ('health check: exit=' + $hk.exitCode + ' (' + $hk.verdict + ') in ' + $hk.seconds + 's -> ' + $hk.log)
            foreach ($h in $hk.highlights) { Log ('health check: ' + $h) }
          }
        }
        if ($hk.verdict -ne 'PASS' -and $hk.verdict -ne 'SKIPPED') {
          Toast ('respawnkeeper: ' + $ServerLabel) ('Daily health check came back ' + $hk.verdict + '.') $(if ($hk.verdict -eq 'WARN') { 'routine' } else { 'important' })
        }
      } catch { Log ('health check failed (not fatal): ' + $_.Exception.Message) }
    }

    # restartAfter=false is a setting about the MORNING lap ("take it down and
    # leave it for me"). A forced lap was asked for as a RESTART, so it comes
    # back up regardless.
    if ((-not $MaintenanceRestart) -and (-not $run.forced)) {
      Commit 'STOPPED' 'Daily maintenance done; restartAfter is off, so the server is left down.' 'STOPPED_BY_USER'
      break
    }
    Toast ('respawnkeeper: ' + $ServerLabel) ($lapWord + ' done - restarting.') 'routine'
    Commit 'RESTARTING' ($lapWord + ' done; restarting.') 'SHOULD_RUN'
    Start-Sleep -Seconds 5
    continue
  }

  # ---- Clean stop: respect it. Never resurrect what a human stopped. -------
  if ($run.userStopped -or (($run.exitCode -eq 0) -and ($ev.verdict -ne 'crash')) -or ($ev.verdict -eq 'clean')) {
    Log 'clean stop (the shutdown was intentional).'
    Commit 'STOPPED' 'Clean stop. respawnkeeper is exiting on purpose; nothing will restart this server.' 'STOPPED_BY_USER'
    break
  }

  # ---- Stopped, but nothing says why --------------------------------------
  # No crash report, no hs_err, no exception, and no clean-shutdown sequence:
  # the classic "killed from Task Manager". Treating that as a crash would mean
  # restarting a server somebody was in the middle of taking down by hand, which
  # is exactly what requirement 3 asks us not to do. Refusing to restart costs
  # one manual start; restarting into somebody's maintenance costs an afternoon.
  if ($ev.verdict -eq 'unknown') {
    if (-not $RestartAfterUnknownExit) {
      if ([bool]$run.gameGone) {
        # Worth separating in the log, because the two look nothing alike from
        # the outside: this one was NOTICED - the game vanished under a living
        # launcher and the watch loop ended on purpose - and then judged, by the
        # same rule as every other evidence-free exit. Somebody reading
        # STOPPED_EXTERNALLY needs to be able to tell "we saw it go and stood
        # down" from "we never saw anything".
        Log 'the game vanished while its launcher kept running, and the log says nothing about why (no report, no hs_err, no exception, no clean-shutdown line). That is also what a person ending the game process by hand looks like, so it is NOT restarted.'
      } else {
        Log ('server exited with code ' + $run.exitCode + ' but nothing indicates a crash (no report, no hs_err, no exception in the log tail). Treating this as an external stop and NOT restarting.')
      }
      Commit 'STOPPED_EXTERNALLY' ("Exit code " + $run.exitCode + " with no evidence of a crash - looks like the process was stopped from outside (Task Manager, window closed, machine sleep). Not restarting. Set restartAfterUnknownExit=true in profile.json if you want the opposite.") 'STOPPED_BY_USER'
      Toast 'respawnkeeper' 'Server stopped from outside. Not restarting (no crash evidence).' 'routine'
      break
    }
    Log 'no crash evidence, but restartAfterUnknownExit is on - continuing down the crash path.'
  }

  # ---- Crash path ---------------------------------------------------------
  $crashName = 'no-report'
  if ($newCrash) { $crashName = $newCrash.Name }
  Log ('CRASH: exit=' + $run.exitCode + ' report=' + $crashName)
  $script:State.lastCrash = $crashName

  $times = New-Object System.Collections.ArrayList
  foreach ($t in @($script:State.crashTimes)) { [void]$times.Add([datetime]$t) }
  [void]$times.Add((Get-Date))
  while (($times.Count -gt 0) -and ($times[0] -lt (Get-Date).AddMinutes(-$CrashLoopWindowMin))) { $times.RemoveAt(0) }
  $script:State.crashTimes = @($times | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm:ss') })
  Save-State
  Toast ('crash: ' + $ServerLabel) ('exit=' + $run.exitCode + ' report=' + $crashName) 'routine'

  # The breaker comes FIRST and is not optional [R-007]. "Diagnose on crash #1"
  # made the harness react sooner; it did not buy the right to loop forever.
  if ($times.Count -ge $CrashLoopCount) {
    Log ('HALT: crash-loop breaker (' + $times.Count + '/' + $CrashLoopCount + ' crashes within ' + $CrashLoopWindowMin + ' min).')
    Commit 'HALTED' ("Crash loop: " + $times.Count + " crashes in " + $CrashLoopWindowMin + " min. SERVER IS DOWN and stays down until a human looks. Last: " + $crashName) 'HALTED'
    Toast 'respawnkeeper HALTED' 'Crash-loop breaker tripped. The server is DOWN.'
    $halted = $true
    break
  }

  # ---- Tier1, on crash #1 -------------------------------------------------
  Commit 'DIAGNOSING' ("Crash " + $crashName + ". Running Tier1 (table lookup, no model). Server DOWN meanwhile.") 'SHOULD_RUN'
  # THE SUPERVISOR MUST SURVIVE ITS OWN TOOLS (2026-09-23, found by L6).
  # rk-diagnose is a separate script and it can throw - on a folder no template
  # recognises, on an unreadable rules file, on a locked state dir. Uncaught,
  # that ended the supervisor HERE: the server was already down, the restart
  # never came, and STATUS.txt kept whatever it said last. A tool that fails is
  # supposed to land on HALT, which is a state somebody can see and act on, not
  # on silence.
  # And the previous crash's answer goes first, because the catch below reads
  # the file whatever happened: a stale diagnosis would be acted on as if it
  # described THIS crash.
  Remove-Item -LiteralPath $DiagFile -Force -ErrorAction SilentlyContinue
  try {
    & (Join-Path $HarnessDir 'rk-diagnose.ps1') -ServerDir $ServerDir -GamesDir $GamesDir -Since $startTime.ToString('yyyy-MM-dd HH:mm:ss')
  } catch {
    Log ('Tier1 could not run: ' + $_.Exception.Message)
    Log '  treating this as "no match" - the crash path continues, and an unmatched crash HALTs unless escalation is on.'
  }
  $diag = Read-RkJson -Path $DiagFile
  $verdictLine = ''

  # Tier1 is kept in front of the model even in fully unattended mode, and the
  # reason is cost, not caution: it answers in about a second and costs nothing.
  # Paying a model to re-derive "that jar is not a valid mod file" every night
  # is the exact waste the three-tier split exists to avoid [R-006]. What
  # CHANGED (2026-08-27) is what happens when Tier1 says "I know what this is
  # but a human has to decide": with escalateOnHalt, that no longer parks the
  # server until morning - it hands the case to the model, which can look for a
  # fix Tier1's table has no way to express.
  if ($diag -and $diag.matched) {
    Log ('Tier1: ' + $diag.summary)
    $script:State.lastVerdict = $diag.summary

    if ($diag.action -eq 'RESTART') {
      $verdictLine = 'FIXED: transient (' + $diag.primary.ruleId + '); restart only'
    }
    elseif ($diag.autoFixable -and $AutoRepairEnabled) {
      if ($script:State.repairAttempts -ge $MaxRepairAttempts) {
        # "A repair that did not stick" is the 2-in-3 case. Trying again is how
        # a harness turns one broken mod into a night of broken mods [R-007].
        $verdictLine = 'HALT: a repair was already applied and the server crashed again; not trying a second time'
      } else {
        $script:State.repairAttempts++
        Save-State
        & (Join-Path $HarnessDir 'rk-repair.ps1') -ServerDir $ServerDir -GamesDir $GamesDir -Apply -Owner 'respawnkeeper'
        if (Test-Path -LiteralPath $ResultFile) {
          $first = (Get-Content -LiteralPath $ResultFile -TotalCount 1)
          if ($first) { $verdictLine = $first.Trim() }
        }
        if (-not $verdictLine) { $verdictLine = 'HALT: repair produced no verdict' }
      }
    }
    elseif ($diag.autoFixable -and (-not $AutoRepairEnabled)) {
      $verdictLine = 'HALT: Tier1 knows a reversible fix but -AutoRepair is off - ' + $diag.summary
    }
    else {
      # Tier1 identified the cause but its table has no safe mechanical answer
      # (a missing dependency, two mods declaring each other incompatible, an
      # entity that crashes on every tick). Parking here until morning is the
      # right call when nobody asked for more; when escalateOnHalt is on, the
      # model gets the case instead - it is not limited to the five actions
      # rk-repair implements.
      if ($EscalateOnHalt -and $EscalationHook) {
        Log ('Tier1 identified it but cannot fix it mechanically; escalating (escalateOnHalt). ' + $diag.summary)
        $verdictLine = Invoke-Escalation -CrashName $crashName
      } else {
        $verdictLine = 'HALT: ' + $diag.summary
      }
    }
  }
  else {
    Log 'Tier1: no rule matched.'
    $script:State.lastVerdict = 'no Tier1 match'
    $verdictLine = Invoke-Escalation -CrashName $crashName

    # WHAT restartAfterUnknownExit MEANS ONE LAYER DOWN (2026-09-23, Eva chose
    # A in [R-106]).
    #
    # Turning the knob on only got as far as "this was a crash". The crash path
    # then HALTed, because an unmatched crash HALTs - so for a game that writes
    # no crash report the answer was still "down until a human looks", and the
    # knob bought nothing. Measured on L6: STOPPED_EXTERNALLY became
    # "HALT: no escalation hook configured", and the server stayed down either
    # way.
    #
    # NARROW ON PURPOSE - only when there is NO crash report at all. A report
    # that exists and matches nothing is a real unknown: something to read, and
    # a reason to stop and fetch a person. Nothing at all is the ordinary shape
    # of a Valheim crash, and there is nothing there to repair or to learn from.
    # SECURITY-HALT is never overridden, and the crash-loop breaker upstream
    # (3 in 30 min) is untouched: this restarts, it does not loop for ever.
    if ($RestartAfterUnknownExit -and ($crashName -eq 'no-report') -and
        ($verdictLine -notlike 'FIXED*') -and ($verdictLine -notlike 'SECURITY-HALT*')) {
      Log ('nothing to repair: no crash report was written and no rule matched. restartAfterUnknownExit is on, so this restarts rather than HALTing (was: ' + $verdictLine + ').')
      $verdictLine = 'FIXED: nothing to repair - no crash report, no Tier1 match; restart only (restartAfterUnknownExit)'
    }
  }

  Log ('verdict: ' + $verdictLine)
  $script:State.lastVerdict = $verdictLine
  Save-State

  if ($verdictLine -notlike 'FIXED*') {
    Commit 'HALTED' ($verdictLine + " | crash report: " + $crashName + " | details: respawnkeeper\diagnosis.json") 'HALTED'
    Toast 'respawnkeeper HALTED' $verdictLine
    $halted = $true
    break
  }

  if (-not $AutoRestartEnabled) {
    Commit 'FIXED_NOT_RESTARTED' ($verdictLine + " -- auto-restart is OFF, so the server is left DOWN for you to start. Pass -AutoRestart to change that.") 'STOPPED_BY_USER'
    Toast 'respawnkeeper' 'Repair applied. Auto-restart is off; start it when ready.'
    break
  }

  Log ('restarting in ' + $RestartBackoffSec + 's (crash ' + $times.Count + '/' + $CrashLoopCount + ' in window, repairAttempts=' + $script:State.repairAttempts + ').')
  Commit 'RESTARTING' ($verdictLine + " -- restarting; it needs " + $SoakMin + " min of uptime to count as recovered.") 'SHOULD_RUN'
  Start-Sleep -Seconds $RestartBackoffSec
}

Remove-Item -LiteralPath $HarnessLock -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ServerPidFile -Force -ErrorAction SilentlyContinue
Log '=== respawnkeeper finished ==='
if ($halted) { exit 3 }
exit 0
