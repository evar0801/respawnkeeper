# ============================================================
# Invoke-LiveTest.ps1 - the three mechanisms Invoke-SelfTest cannot cover.
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# Invoke-SelfTest proves the crash -> diagnose -> repair -> restart loop. It
# deliberately does NOT cover these three, because each one needs something the
# routine suite must not do: spend tokens, wait for a wall-clock window, or
# tamper with the PATH.
#
#   L1  which account pays        - proven with a PATH shim, so it costs nothing
#   L2  the daily maintenance lap - warn -> stop -> read logs -> report -> restart
#   L3  escalation, for real      - a real claude session. OPT-IN: -RunEscalation
#   L4  the forced maintenance restart - the panel's button: MAINTENANCE_NOW
#   L5  a launcher that outlives the server - the shape Minecraft cannot show
#   L6  the game dies UNDER a living launcher - does it come back by itself?
#
# Everything runs in a throwaway sandbox. It never reads or writes fc8 or
# pokemoncraft, and it never starts a real server.
#
#   powershell -File tests\Invoke-LiveTest.ps1
#   powershell -File tests\Invoke-LiveTest.ps1 -RunEscalation   # spends tokens
# ============================================================

param(
  [string]$Sandbox = '',
  [switch]$KeepSandbox,
  [switch]$RunEscalation,        # L3 only runs when this is passed
  [int]$MaintenanceLeadSec = 50  # how far ahead to schedule the maintenance window
)

$ErrorActionPreference = 'Continue'
$HarnessDir = Split-Path -Parent $PSScriptRoot
$TestsDir   = $PSScriptRoot
. (Join-Path $HarnessDir 'lib\rk-common.ps1')

if (-not $Sandbox) { $Sandbox = Join-Path $env:TEMP ('rk-livetest-' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Group([string]$n) { Write-Host ''; Write-Host ('== ' + $n + ' ' + ('=' * [Math]::Max(0, 62 - $n.Length))) }
function Ok([string]$w)    { $script:pass++; Write-Host ('  PASS  ' + $w) }
function No([string]$w, [string]$d) { $script:fail++; Write-Host ('  FAIL  ' + $w); if ($d) { Write-Host ('        ' + $d) } }
function Skip([string]$w, [string]$y) { $script:skip++; Write-Host ('  SKIP  ' + $w + '  (' + $y + ')') }
function Check([string]$w, [bool]$c, [string]$d) { if ($c) { Ok $w } else { No $w $d } }

function To-BashPath([string]$p) {
  $q = $p -replace '\\', '/'
  if ($q -match '^([A-Za-z]):(.*)$') { return ('/' + $Matches[1].ToLower() + $Matches[2]) }
  return $q
}

# ---- sandbox ----------------------------------------------------------------
Group 'sandbox'
foreach ($sub in @('libraries', 'mods', 'config', 'crash-reports', 'logs')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Sandbox $sub) | Out-Null
}
[System.IO.File]::WriteAllText((Join-Path $Sandbox 'server.properties'),
  "server-port=25598`r`nlevel-name=world_livetest`r`n", (New-Object System.Text.UTF8Encoding($false)))
New-Item -ItemType Directory -Force -Path (Join-Path $Sandbox 'world_livetest') | Out-Null
$StateDir = Join-Path $Sandbox 'respawnkeeper'
Write-Host ('  sandbox: ' + $Sandbox)

$java = Resolve-RkJava -Major 21
$javac = $null
if ($java) { $javac = Join-Path (Split-Path -Parent $java) 'javac.exe' }
$classes = Join-Path $Sandbox 'crashsim'
$haveSim = $false
if ($javac -and (Test-Path $javac)) {
  New-Item -ItemType Directory -Force -Path $classes | Out-Null
  & $javac -d $classes (Join-Path $TestsDir 'crashsim\CrashSim.java') 2>&1 | Out-Null
  $haveSim = Test-Path (Join-Path $classes 'CrashSim.class')
}
# Suffixed, and for the same reason Invoke-SelfTest suffixes its loader
# ([R-078]): a sandbox that names the loader version pokemoncraft really runs
# is indistinguishable from pokemoncraft to the loader-signature probe. With
# the plain number this suite could only pass while nobody was playing.
$ldr = Join-Path $Sandbox 'libraries\net\neoforged\neoforge\21.1.247-rklivetest'
New-Item -ItemType Directory -Force -Path $ldr | Out-Null
if ($haveSim) {
  $cp = ($classes -replace '\\', '/')
  [System.IO.File]::WriteAllText((Join-Path $ldr 'win_args.txt'), ("-cp`r`n" + $cp + "`r`nCrashSim`r`n"), (New-Object System.Text.UTF8Encoding($false)))
} else {
  Set-Content -LiteralPath (Join-Path $ldr 'win_args.txt') -Value '-version' -Encoding ascii
}
[System.IO.File]::WriteAllText((Join-Path $Sandbox 'user_jvm_args.txt'), "-Xmx256M`r`n", (New-Object System.Text.UTF8Encoding($false)))
Check 'the crash simulator built' $haveSim 'javac missing or CrashSim.java failed to compile'

& (Join-Path $HarnessDir 'rk-setup.ps1') -ServerDir $Sandbox -Policy 'unattended' -NonInteractive -NoLaunch -NoRegister *>&1 | Out-Null
$ProfileFile = Join-Path $StateDir 'profile.json'
Check 'a profile exists to drive the tests' (Test-Path $ProfileFile) ''

function Set-Profile([scriptblock]$edit) {
  $p = Get-Content -LiteralPath $ProfileFile -Raw -Encoding UTF8 | ConvertFrom-Json
  & $edit $p
  Write-RkJson -Path $ProfileFile -Object $p
}

# ============================================================================
# L1. Which account pays.
#
# The setting only means anything if it decides the CHILD's environment: the
# claude CLI bills an API key when ANTHROPIC_API_KEY is set and uses the account
# login when it is not. So the thing to prove is what the child actually sees,
# and the only honest way to see that is to BE the child.
#
# A shim named 'claude' (no extension) is put first on PATH. Git Bash resolves
# it; PowerShell's Get-Command still finds the real claude.cmd further down, so
# the hook's own preflight check is unaffected. The shim spends nothing.
# ============================================================================
Group 'L1. which account pays (no tokens spent)'

$ShimDir  = Join-Path $Sandbox 'shim'
$ShimSeen = Join-Path $Sandbox 'shim-saw-env.txt'
New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
$seenBash = To-BashPath $ShimSeen
$shimLines = @(
  '#!/bin/sh',
  'cat > /dev/null',
  (': > "' + $seenBash + '"'),
  ('echo "KEY=[${ANTHROPIC_API_KEY-UNSET}]" >> "' + $seenBash + '"'),
  ('echo "TOKEN=[${ANTHROPIC_AUTH_TOKEN-UNSET}]" >> "' + $seenBash + '"'),
  'echo shim ran'
)
[System.IO.File]::WriteAllText((Join-Path $ShimDir 'claude'), (($shimLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$Hook       = Join-Path $HarnessDir 'hooks\escalate-claude.ps1'
$DiagStub   = Join-Path $StateDir 'diagnosis.json'
$ResultFile = Join-Path $StateDir 'livetest-result.txt'
Write-RkJson -Path $DiagStub -Object ([ordered]@{ schema = 'respawnkeeper/diagnosis/1'; crashReport = 'NONE'; matches = @() })

function Invoke-Hook([string]$backend, [string]$keyEnvName, [string]$keyValue) {
  Remove-Item -LiteralPath $ResultFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ShimSeen -Force -ErrorAction SilentlyContinue
  Set-Profile { param($p) $p.model.backend = $backend; $p.model.apiKeyEnv = $keyEnvName }
  $oldPath = $env:PATH
  $oldKey  = [System.Environment]::GetEnvironmentVariable($keyEnvName)
  $env:PATH = $ShimDir + ';' + $env:PATH
  if ($null -ne $keyValue) { Set-Item -Path ('env:' + $keyEnvName) -Value $keyValue }
  try {
    & $Hook -ServerDir $Sandbox -DiagnosisFile $DiagStub -ResultFile $ResultFile *>&1 | Out-Null
  } finally {
    $env:PATH = $oldPath
    if ($null -eq $oldKey) { Remove-Item -Path ('env:' + $keyEnvName) -ErrorAction SilentlyContinue }
    else { Set-Item -Path ('env:' + $keyEnvName) -Value $oldKey }
  }
  $verdict = ''
  if (Test-Path $ResultFile) { $verdict = (Get-Content -LiteralPath $ResultFile -TotalCount 1) }
  $seen = ''
  if (Test-Path $ShimSeen) { $seen = (Get-Content -LiteralPath $ShimSeen -Raw) }
  return @{ verdict = $verdict; ranClaude = (Test-Path $ShimSeen); childEnv = $seen }
}

# (a) api chosen, the named variable is not set anywhere -> refuse, and say which
#     variable. It must NOT quietly fall back to the subscription: that would
#     charge a different wallet than the one that was picked.
$r = Invoke-Hook 'api' 'RK_LIVETEST_KEY' $null
Check 'api + missing env var -> HALT' ($r.verdict -like 'HALT:*') ('verdict: ' + $r.verdict)
Check 'the HALT names the variable to set' ($r.verdict -match 'RK_LIVETEST_KEY') ('verdict: ' + $r.verdict)
Check 'no model session was launched' (-not $r.ranClaude) ''

# (b) api chosen and the variable IS set -> the child gets exactly that value.
$r = Invoke-Hook 'api' 'RK_LIVETEST_KEY' 'rk-livetest-sentinel-value'
Check 'api + env var set -> the session is launched' ($r.ranClaude) ('verdict: ' + $r.verdict)
Check 'the child is billed with the named variable' ($r.childEnv -match 'KEY=\[rk-livetest-sentinel-value\]') ('child env: ' + ($r.childEnv -replace "`r`n", ' | '))

# (c) THE ONE THAT MATTERS. subscription chosen while a key happens to be set in
#     the parent environment. If the harness merely "does not set" the key, the
#     child inherits it and the account silently moves onto metered billing.
#     'subscription' has to actively REMOVE it.
$r = Invoke-Hook 'subscription' 'ANTHROPIC_API_KEY' 'rk-should-not-reach-the-child'
Check 'subscription -> the session is launched' ($r.ranClaude) ('verdict: ' + $r.verdict)
Check 'subscription STRIPS an inherited API key from the child' ($r.childEnv -match 'KEY=\[UNSET\]') ('child env: ' + ($r.childEnv -replace "`r`n", ' | '))
Check 'subscription strips ANTHROPIC_AUTH_TOKEN too' ($r.childEnv -match 'TOKEN=\[UNSET\]') ('child env: ' + ($r.childEnv -replace "`r`n", ' | '))

# The profile must never hold the secret itself - only the name of a variable.
$profRaw = Get-Content -LiteralPath $ProfileFile -Raw -Encoding UTF8
Check 'the profile stores the variable NAME, never a key value' ($profRaw -notmatch 'rk-livetest-sentinel-value') ''

# ============================================================================
# L2. The daily maintenance lap.
#
# warn -> clean stop -> read the day's logs -> write the report -> start again.
# This needs a server that is still RUNNING when the window arrives, which is
# what CrashSim's "serve" mode is for.
# ============================================================================
Group 'L2. the daily maintenance lap'

if (-not $haveSim) {
  Skip 'daily maintenance lap' 'no crash simulator'
} else {
  Set-Content -LiteralPath (Join-Path $Sandbox 'crashsim.mode') -Value 'serve' -Encoding ascii -NoNewline
  Remove-Item -LiteralPath (Join-Path $Sandbox 'STOP_SERVER') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $StateDir 'watchdog.log') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $StateDir 'state.json') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $StateDir 'reports') -Recurse -Force -ErrorAction SilentlyContinue

  # Give the scan something to find. It must report a real count, not zero.
  $today = Get-Date -Format 'yyyy-MM-dd'
  $seed = New-Object System.Collections.Generic.List[string]
  foreach ($i in 1..12) {
    $seed.Add('[' + $today + ' 09:1' + ($i % 10) + ':00] [Server thread/WARN]: Can''t keep up! Is the server overloaded? Running 2451ms behind')
  }
  $seed.Add('[' + $today + ' 09:20:00] [Server thread/ERROR]: Failed to load datapack file example.json')
  [System.IO.File]::WriteAllLines((Join-Path $Sandbox 'logs\latest.log'), $seed.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

  # The window is stored as HH:mm, so it can only land on a minute boundary.
  # Adding N seconds to "now" therefore usually resolves to a time ALREADY PAST
  # (20:33:07 + 50s -> "20:33" -> due 6 seconds ago), which fires the stop
  # instantly and skips the 60-second warning. Aim at the next boundary that is
  # far enough out for the warning to have somewhere to happen.
  $now = Get-Date
  $due = $now.Date.AddHours($now.Hour).AddMinutes($now.Minute + 1)
  while (($due - $now).TotalSeconds -lt $MaintenanceLeadSec) { $due = $due.AddMinutes(1) }
  Set-Profile {
    param($p)
    $p.dailyMaintenance.enabled = $true
    $p.dailyMaintenance.at = $due.ToString('HH:mm')
    $p.dailyMaintenance.analyzeLogs = $true
    $p.dailyMaintenance.restartAfter = $true
    $p.autoRestart = $true
    $p.soakMin = 0
  }
  Write-Host ('  maintenance window set for ' + $due.ToString('HH:mm') + ' (about ' + $MaintenanceLeadSec + 's out)')

  $rk = Join-Path $HarnessDir 'respawnkeeper.ps1'
  $supLog = Join-Path $Sandbox 'livetest-supervisor.log'
  # -NoConsoleWindow: the console window no longer ends itself when the
  # supervisor does ([R-088]), so a lap that opened one would leave it on the
  # desktop pointing at a sandbox this script deletes on the way out.
  $job = Start-Job -ScriptBlock {
    param($rk, $dir, $out)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $rk -ServerDir $dir -NoConsoleWindow *>&1 | Out-File -FilePath $out -Encoding utf8
  } -ArgumentList $rk, $Sandbox, $supLog

  # Wait for the lap: the log says maintenance happened, then the server is up again.
  $wd = Join-Path $StateDir 'watchdog.log'
  $sawMaint = $false; $sawRestart = $false
  $deadline = (Get-Date).AddSeconds($MaintenanceLeadSec + 180)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (Test-Path $wd) {
      $txt = Get-Content -LiteralPath $wd -Raw
      if ($txt -match 'daily maintenance stop completed') { $sawMaint = $true }
      if ($sawMaint -and (([regex]::Matches($txt, 'started: ')).Count -ge 2)) { $sawRestart = $true; break }
    }
    if ($job.State -eq 'Completed') { break }
  }
  # It is serving again; end the run the way a person would.
  if ($sawRestart) { Start-Sleep -Seconds 5 }
  Set-Content -LiteralPath (Join-Path $Sandbox 'STOP_SERVER') -Value '' -Encoding ascii -NoNewline
  $null = Wait-Job -Job $job -Timeout 120
  Stop-Job -Job $job -ErrorAction SilentlyContinue
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

  $wdTxt = ''
  if (Test-Path $wd) { $wdTxt = Get-Content -LiteralPath $wd -Raw }
  $status = ''
  if (Test-Path (Join-Path $StateDir 'STATUS.txt')) { $status = Get-Content -LiteralPath (Join-Path $StateDir 'STATUS.txt') -Raw }
  $reports = @(Get-ChildItem -LiteralPath (Join-Path $StateDir 'reports') -Filter 'daily-*.md' -ErrorAction SilentlyContinue)

  Check 'the window fired and warned the server first' ($wdTxt -match 'daily maintenance in ~\d+s - warned') ($wdTxt -replace "`r`n", ' | ')
  Check 'it took the server down cleanly (not killed)' ($sawMaint) ($wdTxt -replace "`r`n", ' | ')
  Check 'it read the days logs while the server was down' ($wdTxt -match 'daily report written') ''
  Check 'it wrote a report a human can read later' ($reports.Count -ge 1) ('reports: ' + $reports.Count)
  if ($reports.Count -ge 1) {
    $rep = Get-Content -LiteralPath $reports[0].FullName -Raw
    Check 'the report counted the seeded problem' ($rep -match 'keep up') ''
    Check 'the report is not empty boilerplate' ($rep.Length -gt 200) ('length: ' + $rep.Length)
  }
  Check 'it started the server again by itself' ((([regex]::Matches($wdTxt, 'started: ')).Count -ge 2)) ($wdTxt -replace "`r`n", ' | ')
  Check 'the manual stop after it was honoured' ($status -match 'STATE: STOPPED') ($status -replace "`r`n", ' | ')
  Check 'no harness lock was left behind' (-not (Test-Path (Join-Path $StateDir 'harness.lock'))) ''
}

# ============================================================================
# L4. The forced maintenance restart - what the panel's restart button does.
#
# MAINTENANCE_NOW is written through Request-RkSignal (the exact call the panel
# and the console window make), against a supervisor that has NO daily window
# scheduled and autoRestart OFF - so the lap that follows can only be the
# forced one, and the restart at the end can only be its doing. The profile's
# restartAfter is off as well: that setting is about the morning lap, and a
# restart somebody asked for must not be cancelled by it.
# ============================================================================
Group 'L4. the forced maintenance restart (MAINTENANCE_NOW)'

if (-not $haveSim) {
  Skip 'forced maintenance restart' 'no crash simulator'
} else {
  Set-Content -LiteralPath (Join-Path $Sandbox 'crashsim.mode') -Value 'serve' -Encoding ascii -NoNewline
  foreach ($f in @('STOP_SERVER', 'MAINTENANCE_NOW')) { Remove-Item -LiteralPath (Join-Path $Sandbox $f) -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath (Join-Path $StateDir 'watchdog.log') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $StateDir 'state.json') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $StateDir 'reports') -Recurse -Force -ErrorAction SilentlyContinue
  $today = Get-Date -Format 'yyyy-MM-dd'
  [System.IO.File]::WriteAllLines((Join-Path $Sandbox 'logs\latest.log'),
    @('[' + $today + ' 09:10:00] [Server thread/WARN]: Can''t keep up! Is the server overloaded? Running 2451ms behind'),
    (New-Object System.Text.UTF8Encoding($false)))

  Set-Profile {
    param($p)
    $p.dailyMaintenance.enabled = $false
    $p.dailyMaintenance.restartAfter = $false
    $p.dailyMaintenance.analyzeLogs = $true
    $p.dailyMaintenance | Add-Member -NotePropertyName forcedWarnSeconds -NotePropertyValue 5 -Force
    $p.autoRestart = $false
    $p.soakMin = 0
  }

  $rk = Join-Path $HarnessDir 'respawnkeeper.ps1'
  $supLog = Join-Path $Sandbox 'livetest-supervisor-l4.log'
  $job = Start-Job -ScriptBlock {
    param($rk, $dir, $out)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $rk -ServerDir $dir -NoConsoleWindow *>&1 | Out-File -FilePath $out -Encoding utf8
  } -ArgumentList $rk, $Sandbox, $supLog

  # Up, and announced: harness.lock names a live respawnkeeper.
  $wd = Join-Path $StateDir 'watchdog.log'
  $sup = @{ alive = $false; reason = 'never checked' }
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if ((Test-Path $wd) -and ((Get-Content -LiteralPath $wd -Raw) -match 'started: ')) {
      $sup = Get-RkSupervisor -ServerDir $Sandbox
      if ($sup.alive) { break }
    }
    if ($job.State -eq 'Completed') { break }
  }
  Check 'the supervisor announces itself while it runs (harness.lock -> live pid)' ($sup.alive) $sup.reason
  # Give the simulator a moment to reach its serve loop before asking for a stop.
  Start-Sleep -Seconds 2

  # The button.
  $req = Request-RkSignal -ServerDir $Sandbox -Signal 'maintenance'
  Check 'the restart request is accepted (a supervisor is listening)' ($req.ok -eq $true) ('reason=' + $req.reason + ' ' + $req.detail)

  # Watch the lap, and record every state the supervisor passes through.
  $statusFile = Join-Path $StateDir 'STATUS.txt'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $sawStop = $false; $sawRestart = $false
  $deadline = (Get-Date).AddSeconds(150)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if (Test-Path $statusFile) {
      $st = ''
      try { $st = Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop } catch {}
      if ($st -match 'STATE:\s*([A-Z_]+)') { [void]$seen.Add($Matches[1]) }
    }
    if (Test-Path $wd) {
      $txt = Get-Content -LiteralPath $wd -Raw
      if ($txt -match 'forced maintenance stop completed') { $sawStop = $true }
      if ($sawStop -and (([regex]::Matches($txt, 'started: ')).Count -ge 2)) { $sawRestart = $true; break }
    }
    if ($job.State -eq 'Completed') { break }
  }
  Write-Host ('  states seen: ' + (($seen | Sort-Object) -join ', '))
  if ($sawRestart) { Start-Sleep -Seconds 3 }

  # THE MAINTENANCE FLAG IS ASKED ABOUT HERE, BEFORE ANOTHER ONE IS WRITTEN.
  #
  # It used to be checked after the stop below, which made it a question about
  # whichever flag happened to be on disk at the end. That is not what it means
  # to ask, and it went red as soon as the timing shifted.
  Check 'the flag was picked up (nothing left pending)' (@(Get-RkPendingSignals -ServerDir $Sandbox).Count -eq 0) (@(Get-RkPendingSignals -ServerDir $Sandbox) -join ',')

  # End the run the way the stop button does.
  #
  # CrashSim watches STOP_SERVER ITSELF (serve mode), which no real game does -
  # so the simulator can exit on the flag before the supervisor's own loop gets
  # to it, and then nobody deletes the file. That race is the simulator's, not
  # the product's, and the assertions below must not depend on which side won.
  $stopReq = Request-RkSignal -ServerDir $Sandbox -Signal 'stop'
  $null = Wait-Job -Job $job -Timeout 120
  Stop-Job -Job $job -ErrorAction SilentlyContinue
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

  $wdTxt = ''
  if (Test-Path $wd) { $wdTxt = Get-Content -LiteralPath $wd -Raw }
  $status = ''
  if (Test-Path $statusFile) { $status = Get-Content -LiteralPath $statusFile -Raw }
  $reports = @(Get-ChildItem -LiteralPath (Join-Path $StateDir 'reports') -Filter 'daily-*.md' -ErrorAction SilentlyContinue)
  $one = ($wdTxt -replace "`r`n", ' | ')

  Check 'the request was logged with its warning time' ($wdTxt -match 'forced maintenance restart requested \(MAINTENANCE_NOW\): warn 5s') $one
  Check 'it warned the players first, with the SHORT time (not the 10-minute threshold)' ($wdTxt -match 'forced maintenance restart in ~[1-5]s - warned') $one
  Check 'the card could say so: state MAINT_PENDING was committed' ($seen.Contains('MAINT_PENDING')) (($seen | Sort-Object) -join ',')
  Check 'it took the server down cleanly (not killed)' ($sawStop) $one
  Check 'it read the logs while the server was down' ($wdTxt -match 'daily report written') ''
  Check 'it wrote the report' ($reports.Count -ge 1) ('reports: ' + $reports.Count)
  Check 'it started the server again - with autoRestart OFF and restartAfter OFF' ($sawRestart) $one
  Check 'state RESTARTING was committed on the way back up' ($seen.Contains('RESTARTING')) (($seen | Sort-Object) -join ',')
  $lastM = ''
  try { $lastM = [string](Read-RkJson -Path (Join-Path $StateDir 'state.json')).lastMaintenance } catch {}
  Check 'the forced lap counted as today''s maintenance (lastMaintenance set)' (-not [string]::IsNullOrEmpty($lastM)) ('lastMaintenance=' + $lastM)
  Check 'the stop button after it was accepted' ($stopReq.ok -eq $true) ('reason=' + $stopReq.reason)
  Check 'and honoured: STATE STOPPED, and it stays down' ($status -match 'STATE: STOPPED') ($status -replace "`r`n", ' | ')
  $supAfter = Get-RkSupervisor -ServerDir $Sandbox
  Check 'after the run the supervisor is gone (harness.lock removed)' ((-not $supAfter.alive) -and (-not (Test-Path (Join-Path $StateDir 'harness.lock')))) $supAfter.reason
  # Clear the floor first. What this asserts is that a REFUSED request writes
  # nothing - and a leftover STOP_SERVER from the earlier ACCEPTED one (see the
  # CrashSim note above) would answer a different question.
  foreach ($stale in @('STOP_SERVER', 'MAINTENANCE_NOW')) {
    Remove-Item -LiteralPath (Join-Path $Sandbox $stale) -Force -ErrorAction SilentlyContinue
  }
  $late = Request-RkSignal -ServerDir $Sandbox -Signal 'stop'
  Check 'and a stop pressed now is refused instead of left on disk' (($late.ok -eq $false) -and ($late.reason -eq 'unsupervised') -and (-not (Test-Path (Join-Path $Sandbox 'STOP_SERVER')))) ('reason=' + $late.reason)
}

# ============================================================================
# L3. Escalation, for real.
#
# OPT-IN, because it spends tokens on a real model session. The crash handed to
# it is deliberately one Tier1's table cannot match, which is exactly the case
# escalation exists for.
#
# What is asserted is the CONTRACT, not the answer: a verdict line in the agreed
# shape, and no server started. Whether the model's fix is right is a question
# only real crashes can answer.
# ============================================================================
Group 'L3. escalation, for real (a real model session)'

if (-not $RunEscalation) {
  Skip 'live escalation' 'pass -RunEscalation to spend tokens on this'
} elseif (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Skip 'live escalation' 'the claude CLI is not on PATH'
} else {
  Set-Profile { param($p) $p.model.backend = 'subscription'; $p.model.apiKeyEnv = 'ANTHROPIC_API_KEY'; $p.dailyMaintenance.enabled = $false }

  # A crash with no Tier1 rule: an unknown registry fault, named jar, no entry.
  $crashDir = Join-Path $Sandbox 'crash-reports'
  Get-ChildItem -LiteralPath $crashDir -Filter '*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  $crashFile = Join-Path $crashDir ('crash-livetest-' + (Get-Date -Format 'yyyy-MM-dd_HH.mm.ss') + '-server.txt')
  $lines = @(
    '---- Minecraft Crash Report ----',
    '// respawnkeeper live test: synthetic, deliberately UNMATCHED by the Tier1 table.',
    '',
    'Description: Exception in server tick loop',
    '',
    'java.lang.IllegalStateException: Duplicate registration for key rk_livetest:widget',
    '  at com.example.rklivetest.RegistryBootstrap.register(RegistryBootstrap.java:88)',
    '  at rk_livetest.Mod.onCommonSetup(Mod.java:41)',
    '',
    '-- System Details --',
    '  Mod File: rk_livetest-1.0.jar'
  )
  [System.IO.File]::WriteAllLines($crashFile, $lines, (New-Object System.Text.UTF8Encoding($false)))

  $diagFile = Join-Path $StateDir 'diagnosis.json'
  & (Join-Path $HarnessDir 'rk-diagnose.ps1') -ServerDir $Sandbox *>&1 | Out-Null
  $diag = Read-RkJson -Path $diagFile
  $primaryDesc = 'none'
  if ($diag -and $diag.primary) { $primaryDesc = ([string]$diag.primary.ruleId + '/' + [string]$diag.primary.action) }
  $tier1Blank = $true
  if ($diag -and $diag.primary -and $diag.primary.ruleId) { $tier1Blank = $false }
  Check 'Tier1 genuinely has no answer for this crash' $tier1Blank ('primary: ' + $primaryDesc)

  $esc = Join-Path $StateDir 'livetest-escalation.txt'
  Remove-Item -LiteralPath $esc -Force -ErrorAction SilentlyContinue
  $t0 = Get-Date
  & (Join-Path $HarnessDir 'hooks\escalate-claude.ps1') -ServerDir $Sandbox -DiagnosisFile $diagFile -ResultFile $esc *>&1 | Out-Null
  $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

  $verdict = ''
  if (Test-Path $esc) { $verdict = (Get-Content -LiteralPath $esc -TotalCount 1) }
  Write-Host ('  session took ' + $elapsed + 's; verdict: ' + $verdict)

  Check 'the session produced a verdict at all' ($verdict -ne '') ''
  # A failed session must say WHY. "no verdict" alone sends the 3am reader to
  # the wrong place; this is the check that caught the signed-out CLI.
  $outLog = Join-Path $StateDir 'escalate-out.log'
  $transcript = ''
  if (Test-Path $outLog) { $transcript = (Get-Content -LiteralPath $outLog -Raw) }
  if ($verdict -like 'HALT:*') {
    Check 'a HALT verdict explains itself, not just "no verdict"' ($verdict -notmatch 'finished without writing a verdict$') ('verdict: ' + $verdict)
    if ($transcript -match 'OAuth session expired|Failed to authenticate') {
      Check 'a signed-out CLI is named as the cause' ($verdict -match 'authenticate|signed in|auth login') ('verdict: ' + $verdict)
      Check 'and it says Tier1 still works' ($verdict -match 'Tier1') ('verdict: ' + $verdict)
    }
  }
  Check 'the verdict is in the agreed shape' (($verdict -like 'FIXED:*') -or ($verdict -like 'HALT:*') -or ($verdict -like 'SECURITY-HALT:*')) ('verdict: ' + $verdict)
  Check 'the escalation prompt was actually rendered' (Test-Path (Join-Path $StateDir 'escalate-prompt.current.md')) ''
  Check 'the session transcript was kept' (Test-Path (Join-Path $StateDir 'escalate-out.log')) ''
  Check 'it did NOT start the server' (-not (Get-RkServerLiveness -ServerDir $Sandbox -StateDir $StateDir).running) ''
  if (Test-Path (Join-Path $StateDir 'escalate-prompt.current.md')) {
    $tpl = Get-Content -LiteralPath (Join-Path $StateDir 'escalate-prompt.current.md') -Raw
    Check 'no placeholder was left unrendered in the prompt' ($tpl -notmatch '\{\{') ''
  }
}


# ============================================================================
# L5. A LAUNCHER THAT OUTLIVES THE SERVER  (launch.kind = 'script')
#
# The shape neither suite could reach until now. For Minecraft the process
# respawnkeeper starts IS the server, so "it exited" and "the server is gone"
# are the same sentence. For a script launch they are two different sentences,
# and every defect in the stop path has come from that gap:
#
#   [R-082]  the wait watched the wrapper -> a clean stop reported as a
#            180-second failure.
#   [R-084]  the report was fixed and the unbounded WaitForExit right after it
#            was not -> the supervisor hung with the game already dead.
#
# Both were found on Eva's real Valheim server, three days apart, while these
# suites stayed green. So the fixture reproduces the shape with nothing real:
# fakegame.exe is a copy of cmd.exe (its own process name, its image inside the
# server folder), start-fake.bat launches it as a GRANDCHILD and then holds the
# way cmd.exe holds at "Terminate batch job (Y/N)?", and stop-fake.ps1 ends the
# game without touching the wrapper.
#
# What is asserted is the whole lap, but the one that matters is TIME: a
# supervisor that hangs here fails by never finishing, so every wait below is
# bounded and a timeout is a failure, not a skip.
# ============================================================================
Group 'L5. a launcher that outlives the server (launch.kind=script)'

$W        = Join-Path $Sandbox 'wrapper'
$WState   = Join-Path $W 'respawnkeeper'
$FixGames = Join-Path $TestsDir 'fixtures\games'

if (-not (Test-Path -LiteralPath (Join-Path $FixGames 'wrappergame.psd1'))) {
  Skip 'wrapper-outlives-server lap' 'fixtures\games\wrappergame.psd1 is missing'
} else {
  New-Item -ItemType Directory -Force -Path (Join-Path $W 'logs') | Out-Null

  # A copy, not a shim: the process needs a NAME of its own (so process.names
  # can find it) and an image path inside the server folder (so the attribution
  # layer resolves it by exe-path instead of guessing). cmd.exe is the one
  # binary on Windows guaranteed to run from anywhere with no dependencies.
  Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
            -Destination (Join-Path $W 'fakegame.exe') -Force

  # ASCII + CRLF, like every other .bat this harness writes: cmd.exe reads a
  # .bat in the CONSOLE codepage, and a stray byte breaks line parsing rather
  # than erroring ([R-081]).
  $startBat = @"
@echo off
rem Test fixture. Starts the "game" as a GRANDCHILD, then holds - which is what
rem cmd.exe does at "Terminate batch job (Y/N)?" after a Ctrl+C.
setlocal
set HERE=%~dp0
del "%HERE%GAME_STOP" 2>nul
start "" /b "%HERE%fakegame.exe" /c "%HERE%game-loop.bat"
rem Bounded so a broken test cannot leave a process behind for ever. The test
rem releases it by creating WRAPPER_RELEASE when it tears the sandbox down.
for /l %%i in (1,1,600) do (
  if exist "%HERE%WRAPPER_RELEASE" goto :done
  ping -n 2 127.0.0.1 >nul
)
:done
exit /b 0
"@

  $loopBat = @"
@echo off
rem Test fixture: the "server". Writes its own log, like Valheim does.
setlocal
set HERE=%~dp0
set LOG=%HERE%logs\fake-%RANDOM%%RANDOM%.log
echo fake server: started >> "%LOG%"
for /l %%i in (1,1,600) do (
  if exist "%HERE%GAME_STOP" goto :bye
  ping -n 2 127.0.0.1 >nul
)
:bye
echo fake server: clean shutdown >> "%LOG%"
exit /b 0
"@

  # .ps1 because Request-RkStop runs every stop script with `powershell -File`.
  $stopPs1 = @"
# Test fixture stop script. Ends the GAME and leaves the wrapper alone - which
# is the entire point of this fixture.
New-Item -ItemType File -Path (Join-Path `$PSScriptRoot 'GAME_STOP') -Force | Out-Null
"@

  foreach ($f in @(
      @{ p = (Join-Path $W 'start-fake.bat'); c = $startBat },
      @{ p = (Join-Path $W 'game-loop.bat');  c = $loopBat },
      @{ p = (Join-Path $W 'stop-fake.ps1');  c = $stopPs1 })) {
    [System.IO.File]::WriteAllText($f.p, ($f.c -replace "`r?`n", "`r`n"), (New-Object System.Text.ASCIIEncoding))
  }

  $rk = Join-Path $HarnessDir 'respawnkeeper.ps1'
  $supLog = Join-Path $Sandbox 'livetest-supervisor-l5.log'

  # THIS LAP LEAVES THE CONSOLE WINDOW SWITCHED ON, ON PURPOSE - it is the only
  # place the "never two windows for one server" guard is exercised for real.
  #
  # A live registration is planted first, standing in for a window that outlived
  # the previous run. A supervisor that honours it opens nothing and says so; a
  # supervisor that does not opens a real window on Eva's desktop, which is both
  # the failure and its own alarm. The dummy is a sleeping PowerShell whose
  # command line names rk-console.ps1 - the same shape Get-RkConsoleWindow is
  # asked to recognise, without opening a window to make one.
  # The state directory does not exist yet - the supervisor makes it - and
  # Write-RkJson does NOT create parents (Register-RkUiWindow does, which is why
  # the product path never hit this). The first run of this check failed exactly
  # here, and failed LOUDLY rather than planting nothing and calling the guard
  # proven, which is the whole point of asserting $plantedOk before starting.
  New-Item -ItemType Directory -Force -Path (Join-Path $W 'respawnkeeper') | Out-Null
  # -ServerDir is on the command line because a real console window's always
  # is, and because the guard now checks WHICH server: a window belonging to
  # another one must not satisfy this server's lock. The first run after that
  # check existed failed right here - correctly - because this dummy did not
  # name the folder it was pretending to watch.
  $fakeConsole = Start-Process -FilePath (Get-Command powershell).Source `
                   -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 300', '#', 'ui\rk-console.ps1', '-ServerDir', ('"' + $W + '"')) `
                   -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 800
  Write-RkJson -Path (Get-RkConsoleLockFile -ServerDir $W) `
               -Object ([ordered]@{ pid = $fakeConsole.Id; since = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') })
  $plantedOk = (Get-RkConsoleWindow -ServerDir $W).alive
  Check 'the planted console registration reads as a live window' $plantedOk ('pid ' + $fakeConsole.Id)

  $job = Start-Job -ScriptBlock {
    param($rk, $dir, $games, $out)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $rk -ServerDir $dir -GamesDir $games *>&1 | Out-File -FilePath $out -Encoding utf8
  } -ArgumentList $rk, $W, $FixGames, $supLog

  $wd = Join-Path $WState 'watchdog.log'
  function Get-WdText { if (Test-Path -LiteralPath $wd) { return (Get-Content -LiteralPath $wd -Raw) } return '' }

  # Up: the template matched, the wrapper started, and the GAME is running.
  $gameUp = $false
  $deadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if (@(Get-Process -Name 'fakegame' -ErrorAction SilentlyContinue).Count -gt 0) { $gameUp = $true; break }
    if ($job.State -eq 'Completed') { break }
  }
  $wdTxt = Get-WdText
  Check 'the script-launch template was picked up' ($wdTxt -match 'game=wrappergame') ($wdTxt -replace "`r`n", ' | ')
  Check 'the launcher started and the GAME came up as its grandchild' ($gameUp) ($wdTxt -replace "`r`n", ' | ')
}

# NOTHING BELOW MEANS ANYTHING IF THE FIXTURE NEVER STARTED.
#
# The first run of L5 proved that the hard way: the supervisor exited in a
# second (it could not resolve the template), and FIVE checks below went green
# anyway - every one of them by looking for a string in a log file that did not
# exist, or for a process that was never launched. A suite that reports PASS
# when its subject never ran is not testing the subject.
#
# So the lap is gated on the fixture actually being up, and a fixture that is
# not up is ONE loud failure naming the reason - not a row of quiet greens.
if ($haveSim -and (Test-Path -LiteralPath (Join-Path $FixGames 'wrappergame.psd1')) -and (-not $gameUp)) {
  $why = ''
  if (Test-Path -LiteralPath $supLog) { $why = ((Get-Content -LiteralPath $supLog -Tail 4) -join ' | ') }
  No 'the wrapper lap could not start - everything it would have proven is UNPROVEN' $why
  Stop-Job -Job $job -ErrorAction SilentlyContinue
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}

if ($gameUp) {
  # The wrapper respawnkeeper is holding must NOT be the game. If these are the
  # same process the fixture is not reproducing anything.
  #
  # $srvPid must be proven read, not defaulted: Get-Process -Id 0 returns the
  # System Idle Process, whose name is 'Idle' - truthy, and not 'fakegame'. On
  # the first run that turned "there is no server.pid at all" into a PASS.
  $srvPid = 0
  try { $srvPid = [int]((Get-Content -LiteralPath (Join-Path $WState 'server.pid') -Raw).Trim()) } catch { }
  $wrapperName = ''
  if ($srvPid -gt 0) { try { $wrapperName = (Get-Process -Id $srvPid -ErrorAction Stop).ProcessName } catch { } }
  Check 'the process respawnkeeper holds is the WRAPPER, not the game' (($srvPid -gt 0) -and $wrapperName -and ($wrapperName -ne 'fakegame')) ("server.pid -> '" + $wrapperName + "' (pid " + $srvPid + ")")

  # The button.
  $req = Request-RkSignal -ServerDir $W -Signal 'maintenance'
  Check 'the restart request is accepted' ($req.ok -eq $true) ('reason=' + $req.reason + ' ' + $req.detail)

  # THE ONE THAT MATTERS. Before [R-084] the supervisor stopped here for ever:
  # the game was gone, the wrapper was not, and the wait had no bound. A
  # timeout on this loop IS the regression.
  $sawGone = $false; $sawStoodDown = $false; $sawRestart = $false
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $wdTxt = Get-WdText
    if ($wdTxt -match 'the server itself is gone')            { $sawGone = $true }
    if ($wdTxt -match 'not waiting on it any longer')         { $sawStoodDown = $true }
    if ($sawGone -and (([regex]::Matches($wdTxt, 'started: ')).Count -ge 2)) { $sawRestart = $true; break }
    if ($job.State -eq 'Completed') { break }
  }
  $wdTxt = Get-WdText
  $one = ($wdTxt -replace "`r`n", ' | ')

  Check 'it saw the SERVER go, while the wrapper was still alive ([R-082])' ($sawGone) $one
  Check 'it stopped waiting on the wrapper instead of hanging ([R-084])' ($sawStoodDown) $one
  Check 'the lap finished: the server was started again' ($sawRestart) $one
  # Both of these ask a log NOT to contain something, which an empty log
  # satisfies for free. The log has to exist and have the lap in it first.
  $lapLogged = ($wdTxt -match 'stop requested')
  Check 'the empty "proof:" line is gone - it says what it looked at' ($lapLogged -and ($wdTxt -notmatch '(?m)^\[[^\]]+\]\s+proof:\s*$')) $one
  # THIS EXPECTATION IS THE OPPOSITE OF WHAT IT WAS THIS MORNING ([R-089]).
  #
  # It used to assert that the launcher was never killed. That was the right
  # rule for the SERVER and the wrong one for the launcher: a cmd.exe holding at
  # "Terminate batch job (Y/N)?" is not a server, it is a prompt, and leaving
  # one behind after every stop is what made Eva type Y after every stop.
  #
  # What has to stay true is the ORDER: the game is proven gone first, the
  # launcher is ended second, and the log says which. And the game must not be
  # what got ended - the fixture's game is 'fakegame', so if that name appears
  # in a kill line this check has to go red.
  # ORDER IS THE WHOLE ASSERTION, so it is asked as an order.
  #
  # The first version of this check counted live 'fakegame' processes and called
  # zero a pass under the label "no fakegame was taken down with it" - which
  # asserts the exact opposite of its own label, and went red because a second
  # wrapper's game was legitimately still up. A check whose label and predicate
  # disagree is worse than no check: it fails for the wrong reason and would
  # have passed for the wrong reason too.
  #
  # What has to be true is that respawnkeeper saw the SERVER go, and only then
  # ended the launcher. Positions in the log say that; a process count cannot.
  $iGone   = $wdTxt.IndexOf('the server itself is gone')
  $iKilled = $wdTxt.IndexOf('ended the launcher script')
  Check 'the launcher was ended' ($lapLogged -and ($iKilled -ge 0)) $one
  Check '  and the server was proven gone BEFORE that, not after' `
        (($iGone -ge 0) -and ($iKilled -gt $iGone)) ('gone@' + $iGone + ' killed@' + $iKilled)
  Check '  and the line names the launcher, not the game' `
        (($iKilled -lt 0) -or ($wdTxt -notmatch '(?m)^.*ended the launcher script.*fakegame')) $one

  # And the ordinary stop still works on this shape.
  #
  # THE JOB OBJECT IS NOT THE SUPERVISOR. `start /b` hands the wrapper's
  # children the job's inherited stdout handle, and the job stays Running until
  # every one of them lets go - which here is teardown, minutes later. Waiting
  # on the job would therefore report a hang that is not happening: the first
  # version of this check said 'job state: Failed' while the supervisor's own
  # log said "respawnkeeper finished" thirteen seconds after the stop.
  #
  # So the question is asked of the supervisor: is its lock gone, does its log
  # say it finished, and is the process no longer there.
  $stopReq = Request-RkSignal -ServerDir $W -Signal 'stop'
  $supEnded = $false
  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $s = Get-RkSupervisor -ServerDir $W
    if ((-not $s.alive) -and ((Get-WdText) -match 'respawnkeeper finished')) { $supEnded = $true; break }
  }
  $wdTxt = Get-WdText

  $status = ''
  if (Test-Path -LiteralPath (Join-Path $WState 'STATUS.txt')) { $status = Get-Content -LiteralPath (Join-Path $WState 'STATUS.txt') -Raw }
  Check 'the stop button was accepted on this shape too' ($stopReq.ok -eq $true) ('reason=' + $stopReq.reason)
  Check 'the supervisor EXITED rather than hanging on the wrapper' ($supEnded) (($wdTxt -replace "`r`n", ' | '))
  Check '  and it exited saying STOPPED' ($status -match 'STATE: STOPPED') ($status -replace "`r`n", ' | ')

  Stop-Job -Job $job -ErrorAction SilentlyContinue
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

  # ---- never two windows for one server ([R-088]) ---------------------------
  #
  # A live console registration was planted before this supervisor started. The
  # question is whether it honoured it. The evidence has to be BOTH halves:
  #
  #   the log line, which says it made the decision on purpose, and
  #   the process count, which says no window actually appeared.
  #
  # The line alone would pass if the guard logged and then opened one anyway;
  # the count alone would pass if the supervisor had simply failed to get that
  # far. Neither is worth anything without the other, and neither is worth
  # anything at all unless the planted registration was alive - which is why
  # $plantedOk is checked above, before the supervisor is started.
  $supText = ''
  if (Test-Path -LiteralPath $supLog) { $supText = (Get-Content -LiteralPath $supLog -Raw) }
  $realWindows = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and ($_.CommandLine -match 'rk-console\.ps1') -and
                                  ($_.CommandLine -match [regex]::Escape($W)) -and
                                  ($_.ProcessId -ne $fakeConsole.Id) })
  # THE PLANT IS NOT A FINDING. Once the dummy started carrying -ServerDir (it
  # has to: the guard checks which server), it began matching this very filter
  # and reported itself as the window the guard had just refused to open - and
  # the cleanup below then killed the plant and called it an escape. A detector
  # that counts its own scaffolding measures the scaffolding.
  Check 'the supervisor refused to open a second console window' `
        ($plantedOk -and ($supText -match 'already open for this server')) `
        (($supText -split "`r?`n" | Where-Object { $_ -match 'console window' }) -join ' | ')
  Check '  and no console window process was actually started for this server' `
        ($realWindows.Count -eq 0) `
        ('found ' + $realWindows.Count + ': ' + (($realWindows | ForEach-Object { $_.ProcessId }) -join ','))

  # If the guard DID regress, the check above has already failed - but a real
  # console window is now on the desktop pointing at a folder this script is
  # about to delete, and it no longer closes itself. Clean it up: an alarm that
  # has to be dismissed by hand is a worse alarm than one that reports itself.
  foreach ($rw in $realWindows) {
    Stop-Process -Id $rw.ProcessId -Force -ErrorAction SilentlyContinue
    No ('had to clean up a real console window (pid ' + $rw.ProcessId + ') the guard should have prevented') ''
  }
  Stop-Process -Id $fakeConsole.Id -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Get-RkConsoleLockFile -ServerDir $W) -Force -ErrorAction SilentlyContinue

  # Teardown: let both wrappers out of their loops, then make sure nothing of
  # this fixture is left running on the machine.
  [System.IO.File]::WriteAllText((Join-Path $W 'WRAPPER_RELEASE'), '', (New-Object System.Text.ASCIIEncoding))
  $gone = $false
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (@(Get-Process -Name 'fakegame' -ErrorAction SilentlyContinue).Count -eq 0) { $gone = $true; break }
  }
  if (-not $gone) {
    @(Get-Process -Name 'fakegame' -ErrorAction SilentlyContinue) | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
  }
  Check 'the fixture left nothing of its own running' ($gone) 'fakegame.exe was still up after 30s; killed it'
}

# ============================================================================
# L6. THE GAME DIES AND THE LAUNCHER DOES NOT. Does it come back by itself?
#
# THE GAP THIS FILLS (2026-09-15). L5 proves a REQUESTED restart on the wrapper
# shape. It does not prove the one respawnkeeper exists for: nobody asked, the
# server just died.
#
# For Minecraft those are nearly the same test, because the process the
# supervisor holds IS the server - it exits, and the loop ends. For a script
# launch they are not the same test at all: the game can die while cmd.exe sits
# there perfectly healthy, and a supervisor that only watches its own child
# would wait for ever with the server long gone. Nothing would be logged. It
# would look exactly like a server that is running fine.
#
# The mechanism that is supposed to catch it is the 60-second
# Invoke-RkProvenDeadCheck inside the watch loop ("the server may have died
# without its process exiting"). It has never been exercised on this shape.
#
# The kill is deliberately NOT the stop script: no GAME_STOP file, no
# 'fake server: clean shutdown' line in the log. That is what makes it a crash
# rather than a stop, and telling those two apart is the judgement being tested
# - a supervisor that reads this as a user stop must NOT restart, and one that
# reads it as a crash must.
#
# Slow on purpose: the dead check runs once a minute, so the lap cannot be
# faster than that. A timeout here is a FAILURE, not a skip - "it never noticed"
# is exactly the defect.
# ============================================================================
Group 'L6. the game crashes under a living launcher - does it restart itself?'

$W6 = Join-Path $Sandbox 'wrapper-crash'
if (-not (Test-Path -LiteralPath (Join-Path $FixGames 'wrappergame.psd1'))) {
  Skip 'crash -> auto-restart on the wrapper shape' 'fixtures\games\wrappergame.psd1 is missing'
} elseif (-not $haveSim) {
  Skip 'crash -> auto-restart on the wrapper shape' 'the crash simulator is not available'
} else {
  New-Item -ItemType Directory -Force -Path (Join-Path $W6 'logs') | Out-Null
  Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
            -Destination (Join-Path $W6 'fakegame.exe') -Force
  # Same three fixture files as L5, in a directory of their own so the two laps
  # cannot see each other's processes or state.
  foreach ($f in @(
      @{ p = (Join-Path $W6 'start-fake.bat'); c = $startBat },
      @{ p = (Join-Path $W6 'game-loop.bat');  c = $loopBat },
      @{ p = (Join-Path $W6 'stop-fake.ps1');  c = $stopPs1 })) {
    [System.IO.File]::WriteAllText($f.p, ($f.c -replace "`r?`n", "`r`n"), (New-Object System.Text.ASCIIEncoding))
  }

  $W6State = Join-Path $W6 'respawnkeeper'
  # THE ONE SETTING THIS LAP IS ABOUT (2026-09-23, Eva chose A - [R-106]).
  #
  # A game that dies leaving no crash report, no hs_err and no clean-shutdown
  # line is, for Minecraft, most likely somebody ending java from Task Manager -
  # so [R-018] does not restart it. Valheim writes NO crash report of its own,
  # which makes that same silence the ORDINARY shape of a real crash: leaving
  # the default in place means auto-restart never fires for it, not once.
  #
  # So the lap runs with the knob the operator is expected to turn for such a
  # game, and asserts what happens THEN. The default stays false, and
  # Invoke-SelfTest still asserts that a fresh profile has it off.
  New-Item -ItemType Directory -Force -Path $W6State | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $W6State 'profile.json'),
    "{`r`n  `"schema`": `"respawnkeeper/profile/2`",`r`n  `"profile`": `"livetest-L6`",`r`n  `"restartAfterUnknownExit`": true`r`n}`r`n",
    (New-Object System.Text.UTF8Encoding($false)))
  $supLog6 = Join-Path $Sandbox 'livetest-supervisor-l6.log'
  $job6 = Start-Job -ScriptBlock {
    param($rk, $dir, $games, $out)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $rk -ServerDir $dir -GamesDir $games -AutoRestart *>&1 |
      Out-File -FilePath $out -Encoding utf8
  } -ArgumentList $rk, $W6, $FixGames, $supLog6

  $wd6 = Join-Path $W6State 'watchdog.log'
  function Get-Wd6 { if (Test-Path -LiteralPath $wd6) { return (Get-Content -LiteralPath $wd6 -Raw) } return '' }
  # ONLY our own processes. Another lap's fakegame.exe, or a leftover, would
  # make this test pass or fail for the wrong reason - so match on the image
  # path, which is inside this lap's sandbox.
  function Get-Ours { @(Get-Process -Name 'fakegame' -ErrorAction SilentlyContinue |
                        Where-Object { $_.Path -and $_.Path.StartsWith($W6, [StringComparison]::OrdinalIgnoreCase) }) }

  $pid1 = 0
  $deadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    $ours = Get-Ours
    if ($ours.Count -gt 0) { $pid1 = $ours[0].Id; break }
    if ($job6.State -eq 'Completed') { break }
  }
  Check 'the crash fixture came up' ($pid1 -gt 0) (
    'watchdog: ' + ((Get-Wd6) -replace "`r`n", ' | '))

  if ($pid1 -le 0) {
    # Same rule as L5: nothing below means anything if the subject never ran.
    $why = ''
    if (Test-Path -LiteralPath $supLog6) { $why = ((Get-Content -LiteralPath $supLog6 -Tail 4) -join ' | ') }
    No 'the crash lap could not start - everything it would have proven is UNPROVEN' $why
  } else {
    $startsBefore = ([regex]::Matches((Get-Wd6), '(?m)^\[[^\]]+\]\s+started:')).Count

    # THE CRASH. Force-kill the GAME and nothing else: the launcher keeps
    # running, no stop file is written, and no clean-shutdown line reaches the
    # log. From the outside this is a server that fell over.
    Stop-Process -Id $pid1 -Force -ErrorAction SilentlyContinue
    $killedAt = Get-Date

    $sawGone = $false; $restarted = $false; $pid2 = 0
    $deadline = (Get-Date).AddSeconds(200)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 3
      $txt = Get-Wd6
      if (-not $sawGone -and ($txt -match 'gone|dead|exited|no longer')) { $sawGone = $true }
      if (([regex]::Matches($txt, '(?m)^\[[^\]]+\]\s+started:')).Count -gt $startsBefore) { $restarted = $true }
      $ours = @(Get-Ours | Where-Object { $_.Id -ne $pid1 })
      if ($ours.Count -gt 0) { $pid2 = $ours[0].Id }
      if ($restarted -and $pid2 -gt 0) { break }
      if ($job6.State -eq 'Completed') { break }
    }
    $took = [int]((Get-Date) - $killedAt).TotalSeconds
    $wd6Txt = (Get-Wd6) -replace "`r`n", ' | '

    Check 'it noticed the server was gone while the launcher was still alive' $sawGone $wd6Txt
    Check '  and it started the server again without being asked' $restarted (
      'after ' + $took + 's  |  ' + $wd6Txt)
    Check '  and a NEW game process is running (not the corpse of the old one)' (
      ($pid2 -gt 0) -and ($pid2 -ne $pid1)) ('was pid ' + $pid1 + ', now pid ' + $pid2)
    # The judgement, not just the action: a crash must never be filed as a stop
    # somebody asked for, because that is the one reading that suppresses the
    # restart for good.
    $st6 = ''
    $stFile = Join-Path $W6State 'STATUS.txt'
    if (Test-Path -LiteralPath $stFile) { $st6 = (Get-Content -LiteralPath $stFile -Raw) }
    Check '  and it was NOT filed as a stop somebody asked for' (
      $st6 -notmatch 'STOPPED_BY_USER') ($st6 -replace "`r`n", ' | ')
  }

  # Teardown: release every wrapper this lap started, then make sure nothing of
  # it survives. Two wrappers exist by design here - the orphan from before the
  # crash and the one the restart opened - and both watch the same file.
  [System.IO.File]::WriteAllText((Join-Path $W6 'WRAPPER_RELEASE'), '', (New-Object System.Text.ASCIIEncoding))
  [System.IO.File]::WriteAllText((Join-Path $W6 'GAME_STOP'), '', (New-Object System.Text.ASCIIEncoding))
  Stop-Job -Job $job6 -ErrorAction SilentlyContinue
  Remove-Job -Job $job6 -Force -ErrorAction SilentlyContinue
  $gone6 = $false
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if ((Get-Ours).Count -eq 0) { $gone6 = $true; break }
  }
  if (-not $gone6) { (Get-Ours) | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } }
  Check 'the crash lap left nothing of its own running' $gone6 'fakegame.exe was still up after 30s; killed it'
}

# ---- summary ----------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 66)
Write-Host ('  PASS ' + $script:pass + '   FAIL ' + $script:fail + '   SKIP ' + $script:skip)
Write-Host ('=' * 66)
if ($KeepSandbox) { Write-Host ('  sandbox kept: ' + $Sandbox) }
else { Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:fail -gt 0) { exit 1 }
exit 0
