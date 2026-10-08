# ============================================================
# rk-finish-setup.ps1 - the two steps an agent is not allowed to take.
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# Entry point: ..\finish-setup.bat (double-click).
#
#   1. sign the claude CLI in     - a credential; only a person enters one
#   2. disarm the fc8 heartbeat   - needs one UAC approval
#
# Starts no server. Changes nothing else. Safe to run twice: each step checks
# whether it is already done and skips itself.
#
# WHY THIS IS A .ps1 AND NOT THE .bat. The detection needs `claude auth status`
# and Get-ScheduledTask, and quoting those through cmd's for/f loop silently
# produced an EMPTY answer - which reads as "not signed in" and would have run
# the login every time. PowerShell has no such quoting trap.
# ============================================================

param(
  [switch]$CheckOnly     # report what is left, act on nothing
)

$ErrorActionPreference = 'Continue'
$HarnessDir = $PSScriptRoot
$RepoDir    = Split-Path -Parent $HarnessDir

function Head([string]$t) {
  Write-Host ''
  Write-Host ('  ' + $t) -ForegroundColor Cyan
  Write-Host ('  ' + ('-' * $t.Length)) -ForegroundColor DarkCyan
}
function Good([string]$m) { Write-Host ('    o ' + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ('    ! ' + $m) -ForegroundColor Yellow }
function Info([string]$m) { Write-Host ('      ' + $m) -ForegroundColor Gray }

function Get-SignInState {
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return 'NO_CLI' }
  $raw = ''
  try { $raw = (& claude auth status 2>&1 | Out-String) } catch { return 'UNKNOWN' }
  if ($raw -match '"loggedIn"\s*:\s*true')  { return 'YES' }
  if ($raw -match '"loggedIn"\s*:\s*false') { return 'NO' }
  return 'UNKNOWN'
}

function Get-HeartbeatState {
  $t = Get-ScheduledTask -TaskName 'FC8WatchdogHeartbeat' -ErrorAction SilentlyContinue
  if (-not $t) { return 'GONE' }
  if ($t.State -eq 'Disabled') { return 'DISABLED' }
  return 'ARMED'
}

try { $host.UI.RawUI.WindowTitle = 'respawnkeeper - finish setup' } catch {}
Write-Host ''
Write-Host '  ===========================================================' -ForegroundColor Cyan
Write-Host '   respawnkeeper - finish setup' -ForegroundColor Cyan
Write-Host '   Nothing to decide. No server is started.' -ForegroundColor DarkGray
Write-Host '  ===========================================================' -ForegroundColor Cyan

# ---- 1. sign in -------------------------------------------------------------
Head '1 of 2   claude CLI sign-in'
$sign = Get-SignInState
switch ($sign) {
  'YES'    { Good 'already signed in - skipping.' }
  'NO_CLI' { Warn 'the claude CLI is not on PATH. Skipping; only the model pass is affected.' }
  default  {
    if ($CheckOnly) {
      Warn 'not signed in.'
      Info 'run this script without -CheckOnly to sign in.'
    } else {
      Write-Host '    Not signed in. A browser window will open - approve it there.'
      Write-Host '    Using the Claude subscription (no metered charge).'
      Write-Host ''
      & claude auth login --claudeai
      Write-Host ''
      if ((Get-SignInState) -eq 'YES') { Good 'signed in.' }
      else {
        Warn 'still not signed in.'
        Info 'Tier1 diagnosis, repairs, restarts and the daily check all still work.'
        Info 'Only the model pass (Opus on crash #1) is unavailable.'
      }
    }
  }
}

# ---- 2. the fc8 legacy heartbeat -------------------------------------------
Head '2 of 2   fc8 legacy heartbeat'
$hb = Get-HeartbeatState
switch ($hb) {
  'GONE'     { Good 'not installed - nothing to do.' }
  'DISABLED' { Good 'already disabled - nothing to do.' }
  default    {
    if ($CheckOnly) {
      Warn 'still armed - respawnkeeper refuses to run on fc8 while it is.'
    } else {
      Write-Host '    Still armed. respawnkeeper refuses to run on fc8 while it is.'
      Write-Host '    Windows will ask for administrator approval: the task sits in the'
      Write-Host '    protected root of the Task Scheduler library.'
      Write-Host '    It is DISABLED, not deleted - Enable-ScheduledTask puts it back.'
      Write-Host ''
      $bat = Join-Path $RepoDir 'disarm-fc8-heartbeat.bat'
      if (-not (Test-Path -LiteralPath $bat)) { Warn ('missing: ' + $bat) }
      else {
        try { Start-Process -FilePath $bat -Verb RunAs -Wait -ErrorAction Stop }
        catch { Warn ('elevation was declined or failed: ' + $_.Exception.Message) }
        if ((Get-HeartbeatState) -eq 'DISABLED') { Good 'disabled.' }
        else {
          Warn 'still armed.'
          Info 'fc8 is unaffected otherwise, and pokemoncraft does not care at all.'
        }
      }
    }
  }
}

# ---- where that leaves things ----------------------------------------------
Head 'where that leaves things'
$pkc = Join-Path (Split-Path -Parent $RepoDir) 'pokemoncraft\server'
if (Test-Path -LiteralPath $pkc) {
  # -CheckOnly reports with Write-Host, which does NOT travel down the pipeline:
  # without 6>&1 the filter below matches nothing and the whole report prints.
  # (Same trap as fc8's log capture; noted in the project notes (powershell51-gotchas).)
  $report = & (Join-Path $HarnessDir 'respawnkeeper.ps1') -ServerDir $pkc -CheckOnly 6>&1 2>$null
  $wanted = 'Profile     =|Daily check =|AutoRestart =|  model     =|Running now ='
  foreach ($line in $report) {
    $t = [string]$line
    if ($t -match $wanted) { Write-Host ('    ' + $t.Trim()) }
  }
} else {
  Warn ('pokemoncraft server folder not found at ' + $pkc)
}

Write-Host ''
if ((Get-SignInState) -eq 'YES' -and (Get-HeartbeatState) -ne 'ARMED') {
  Write-Host '    Everything an agent cannot do is done.' -ForegroundColor Green
} else {
  Write-Host '    Some steps are still open - re-run this file any time.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '    Whenever you want it, the last step is to START THE SERVER:'
Write-Host ('      ' + (Join-Path $pkc 'rk-start.bat')) -ForegroundColor Cyan
Write-Host ''
