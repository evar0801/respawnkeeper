# ============================================================
# rk-games.ps1 - the game template layer (dot-sourced; functions only)
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS. Everything respawnkeeper needs to know about a server is
# game-specific: how to start it, how to stop it WITHOUT losing the save, where
# the logs are, what a crash looks like. Those five answers were hardcoded for
# Minecraft. A template moves them into data, one file per game, under games\.
#
# THE ONE STRUCTURAL SURPRISE, found by looking at real installs (2026-08-27):
# Minecraft is the ODD ONE OUT. It writes logs\latest.log. Palworld, Valheim and
# Terraria print to the console and leave no log file at all - the "Logs" folder
# Palworld ships was empty, and Valheim's logs\ holds Steam's own logs, not the
# game's. So for those, respawnkeeper has to capture stdout ITSELF or it has
# nothing to read. That is the captureStdout flag.
#
# VERIFICATION HONESTY. A template makes two very different kinds of claim:
#   layout - "these files are in this folder". CHECKABLE, and Test-RkGameTemplate
#            checks it against the real folder before the template is used.
#   launch/stop - "starting it this way works, stopping it this way saves the
#            world". NOT checkable without running somebody's real server, which
#            respawnkeeper does not get to do on its own. Those stay marked
#            unverified until a human has watched it happen once.
# A template whose layout claims fail is REJECTED, not "used with a warning".
# ============================================================

function Get-RkGameTemplates {
  # Loads every games\*.psd1. A malformed template is skipped loudly rather than
  # taking the whole harness down with it.
  param([string]$GamesDir = '')
  if (-not $GamesDir) { $GamesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'games' }
  $out = New-Object System.Collections.ArrayList
  if (-not (Test-Path $GamesDir)) { return @() }
  foreach ($f in (Get-ChildItem -LiteralPath $GamesDir -Filter '*.psd1' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    try {
      $t = Import-PowerShellDataFile -LiteralPath $f.FullName
      if (-not $t.id) { Write-Host ('[rk-games] skipping ' + $f.Name + ': no id'); continue }
      $t['templateFile'] = $f.FullName
      [void]$out.Add($t)
    } catch {
      Write-Host ('[rk-games] skipping ' + $f.Name + ': ' + $_.Exception.Message)
    }
  }
  return @($out)
}

function Test-RkPathClaim {
  # A claim is a path relative to the server folder. Wildcards allowed.
  param([string]$ServerDir, [string]$Claim)
  if (-not $Claim) { return $false }
  $p = Join-Path $ServerDir $Claim
  if ($Claim -match '[\*\?]') { return (@(Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue)).Count -gt 0 }
  return (Test-Path -LiteralPath $p)
}

function Get-RkGameMatch {
  # Scores one template against one folder. Returns @{ matched; score; missing }.
  #   allOf - every one of these must exist, or it is not this game
  #   anyOf - at least one must exist (empty = no constraint)
  param([Parameter(Mandatory)][string]$ServerDir, [Parameter(Mandatory)]$Template)
  $missing = @()
  $score = 0
  foreach ($c in @($Template.detect.allOf)) {
    if (-not $c) { continue }
    if (Test-RkPathClaim -ServerDir $ServerDir -Claim $c) { $score += 10 } else { $missing += $c }
  }
  $anyOf = @($Template.detect.anyOf | Where-Object { $_ })
  $anyHit = $false
  foreach ($c in $anyOf) {
    if (Test-RkPathClaim -ServerDir $ServerDir -Claim $c) { $anyHit = $true; $score += 5 }
  }
  if ($anyOf.Count -gt 0 -and (-not $anyHit)) { $missing += ('(one of) ' + ($anyOf -join ' | ')) }
  return @{
    matched = ($missing.Count -eq 0)
    score   = $score
    missing = $missing
  }
}

function Find-RkGame {
  # Best-matching template for a folder, or $null. Highest score wins; a tie is
  # broken by the template that makes MORE claims (the more specific one).
  param([Parameter(Mandatory)][string]$ServerDir, $Templates)
  if (-not $Templates) { $Templates = Get-RkGameTemplates }
  $hits = New-Object System.Collections.ArrayList
  foreach ($t in $Templates) {
    $m = Get-RkGameMatch -ServerDir $ServerDir -Template $t
    if ($m.matched) { [void]$hits.Add(@{ template = $t; score = $m.score; claims = (@($t.detect.allOf).Count + @($t.detect.anyOf).Count) }) }
  }
  if ($hits.Count -eq 0) { return $null }
  $best = $hits | Sort-Object @{Expression={$_.score};Descending=$true}, @{Expression={$_.claims};Descending=$true} | Select-Object -First 1
  return $best.template
}

function Test-RkGameTemplate {
  # Re-checks EVERY layout claim a template makes against the real folder, not
  # just the detection markers. Called before a template is written into a
  # profile, so a wrong guess can never quietly drive a real server.
  # Returns @{ ok; problems; warnings }.
  param([Parameter(Mandatory)][string]$ServerDir, [Parameter(Mandatory)]$Template)
  $problems = @()
  $warnings = @()

  $m = Get-RkGameMatch -ServerDir $ServerDir -Template $Template
  foreach ($x in $m.missing) { $problems += ('detection marker not found: ' + $x) }

  switch ($Template.launch.kind) {
    'script' {
      if (-not (Test-RkPathClaim -ServerDir $ServerDir -Claim $Template.launch.script)) {
        $problems += ('launch script not found: ' + $Template.launch.script)
      }
    }
    'exe' {
      if (-not (Test-RkPathClaim -ServerDir $ServerDir -Claim $Template.launch.exe)) {
        $problems += ('launch executable not found: ' + $Template.launch.exe)
      }
    }
    'builtin' {
      if ($Template.launch.builtin -ne 'minecraft') { $problems += ('unknown builtin launcher: ' + $Template.launch.builtin) }
    }
    default { $problems += ('launch.kind is missing or unknown: ' + $Template.launch.kind) }
  }

  if ($Template.stop.kind -eq 'script') {
    if (-not (Test-RkPathClaim -ServerDir $ServerDir -Claim $Template.stop.script)) {
      $problems += ('stop script not found: ' + $Template.stop.script)
    }
  }

  # Log location: a warning, not an error. Many servers only create the file
  # once they have run, and several never create one at all (captureStdout).
  if ($Template.paths.logFile -and (-not $Template.capture.stdout)) {
    if (-not (Test-RkPathClaim -ServerDir $ServerDir -Claim $Template.paths.logFile)) {
      $warnings += ('log file not there yet (normal before the first run): ' + $Template.paths.logFile)
    }
  }

  foreach ($k in @('modsDir', 'configDir')) {
    $v = $Template.paths.$k
    if ($v -and (-not (Test-RkPathClaim -ServerDir $ServerDir -Claim $v))) {
      $warnings += ($k + ' not found: ' + $v + ' (repairs that touch it will be unavailable)')
    }
  }

  return @{ ok = ($problems.Count -eq 0); problems = $problems; warnings = $warnings }
}

function Get-RkGameVerificationLevel {
  # What a human has actually watched happen, per template. Drives how cautious
  # rk-setup is allowed to be on the first run of a new game.
  param([Parameter(Mandatory)]$Template)
  $v = $Template.verified
  return @{
    layout = [bool]$v.layout
    launch = [bool]$v.launch
    stop   = [bool]$v.stop
    note   = [string]$Template.verifiedNote
    full   = ([bool]$v.layout -and [bool]$v.launch -and [bool]$v.stop)
  }
}

# ---- Turning a template into an actual command -----------------------------

function Resolve-RkLaunch {
  # Returns @{ exe; arguments; workingDir; captureStdout; describe } or throws.
  # No secret ever passes through here: for games whose start command carries a
  # password (Valheim writes one straight into start_headless_server.bat), the
  # template launches THAT SCRIPT instead of reconstructing its arguments, so
  # respawnkeeper never reads, stores or logs the password.
  param([Parameter(Mandatory)][string]$ServerDir, [Parameter(Mandatory)]$Template)

  switch ($Template.launch.kind) {

    'builtin' {
      if ($Template.launch.builtin -ne 'minecraft') { throw ('unknown builtin launcher: ' + $Template.launch.builtin) }
      $loader = Get-RkLoader -ServerDir $ServerDir
      if (-not $loader) { throw 'no Forge/NeoForge win_args.txt found under libraries\' }
      $java = Resolve-RkJava -Major $loader.javaMajor
      if (-not $java) { throw ('no Java ' + $loader.javaMajor + ' found (checked JAVA_HOME, vendor folders, PATH)') }
      return @{
        exe           = $java
        arguments     = ('"@user_jvm_args.txt" "@' + $loader.winArgsRel + '" nogui')
        workingDir    = $ServerDir
        captureStdout = $false
        describe      = ($loader.kind + ' ' + $loader.version + ' on Java ' + $loader.javaMajor)
      }
    }

    'script' {
      # cmd.exe for .bat, powershell for .ps1. Either way the real game process
      # is a GRANDCHILD, so liveness is decided by process.names, not by us.
      $script = Join-Path $ServerDir $Template.launch.script
      $ext = [System.IO.Path]::GetExtension($script).ToLower()
      $extra = ''
      if ($Template.launch.args) { $extra = ' ' + ($Template.launch.args -join ' ') }
      if ($ext -eq '.ps1') {
        return @{
          exe = (Get-Command powershell).Source
          arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '"' + $extra)
          workingDir = $ServerDir
          captureStdout = [bool]$Template.capture.stdout
          describe = ('script: ' + $Template.launch.script)
        }
      }
      return @{
        exe = (Join-Path $env:SystemRoot 'System32\cmd.exe')
        arguments = ('/c "' + $script + '"' + $extra)
        workingDir = $ServerDir
        captureStdout = [bool]$Template.capture.stdout
        describe = ('script: ' + $Template.launch.script)
      }
    }

    'exe' {
      $exe = Join-Path $ServerDir $Template.launch.exe
      $args = ''
      if ($Template.launch.args) { $args = ($Template.launch.args -join ' ') }
      return @{
        exe = $exe
        arguments = $args
        workingDir = $ServerDir
        captureStdout = [bool]$Template.capture.stdout
        describe = ('exe: ' + $Template.launch.exe)
      }
    }

    default { throw ('launch.kind is missing or unknown: ' + $Template.launch.kind) }
  }
}

function Get-RkGameProcesses {
  # Processes belonging to THIS server, by the template's exact process names.
  #
  # EXACT NAMES, NEVER WILDCARDS. Straight from the operator's own Palworld stop script:
  # the server is PalServer-Win64-Shipping-Cmd and the Steam CLIENT is
  # Palworld-Win64-Shipping. A wildcard search kills the game somebody is
  # playing. That warning is written in C:\Servers\palworld\scripts\stop-server.ps1 and
  # it is the reason this function takes a list of names and compares them with -eq.
  param([Parameter(Mandatory)]$Template)
  $names = @($Template.process.names | Where-Object { $_ })
  if ($names.Count -eq 0) { return @() }
  $wanted = @($names | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_).ToLower() })
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $wanted -contains $_.ProcessName.ToLower() })
}

function Get-RkStopPlan {
  # Describes how to stop this game without losing the save. Returned as data so
  # the supervisor can log exactly what it is about to do before doing it.
  param([Parameter(Mandatory)][string]$ServerDir, [Parameter(Mandatory)]$Template)
  $kind = $Template.stop.kind
  if (-not $kind) { $kind = 'none' }
  $plan = @{
    kind       = $kind
    command    = [string]$Template.stop.command
    script     = ''
    timeoutSec = 120
    describe   = ''
  }
  if ($Template.stop.timeoutSec) { $plan.timeoutSec = [int]$Template.stop.timeoutSec }
  switch ($kind) {
    'stdin'  { $plan.describe = ('write "' + $plan.command + '" to the server console') }
    'script' {
      $plan.script = (Join-Path $ServerDir $Template.stop.script)
      $plan.describe = ('run ' + $Template.stop.script)
    }
    'close'  { $plan.describe = 'ask the process to close (WM_CLOSE, never /F) and let it save' }
    # A console server whose stdout respawnkeeper captures has no window to
    # close, so Ctrl+C is its own stop kind rather than a fallback hidden inside
    # 'close' (2026-09-12; see Send-RkCtrlC in respawnkeeper.ps1). Without this
    # arm the supervisor logs "no clean stop is known for this game" immediately
    # before carrying out a stop it does know how to make.
    'ctrlc'  { $plan.describe = 'send Ctrl+C to the console the server runs in (everything sharing that console gets it)' }
    default  { $plan.describe = 'no clean stop is known for this game - a human has to stop it' }
  }
  return $plan
}
