# ============================================================
# rk-vitals.ps1 - how the server FEELS, read from the log and the process.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY NOT TPS. A real tick rate comes from asking the server (`forge tps`), and
# this window has a standing rule that it never talks to the server to draw
# itself. What the log gives instead is better evidence anyway: "Can't keep up!
# ... Running 3318ms or 66 ticks behind" is the server admitting it missed a
# deadline, with the size of the miss attached. Counting those is a measurement.
# Printing a "20.0 TPS" nobody measured would be a decoration.
#
# WHY A BYTE WINDOW AND NOT A TIME WINDOW. The timestamps are locale-formatted -
# pokemoncraft's read "[07<JP month>2026 01:31:06.017]", which is day, Japanese
# month, year. Parsing that would put the health readout at the mercy of the
# machine's locale settings. Bytes from the end of the file have no such
# dependency.
#
# ---- WHAT CHANGED 2026-09-12 ([R-071] / [R-072]) ---------------------------
# This file used to read Join-Path $ServerDir 'logs\latest.log' - a path only
# Minecraft writes - and when that file did not exist, Get-RkLogTail returned an
# empty array. Zero lines then produced zero lag hits, and the window printed
# "no lag recorded in the last 256KB of log" after reading ZERO BYTES.
#
# That is not a display bug. "I measured and it was fine" and "I could not
# measure" were rendered identically, so the reading a person trusts most - the
# green one - was also the one produced by a total failure to observe. On
# Valheim every single vitals row would have said the server was healthy.
#
# So the result now carries LagMeasured, and a caller that prints the clean line
# without checking it is the bug coming back. The contract is written down in
# lib\rk-capabilities.psd1: feature 'vitals', onUnmet = 'degraded', and the note
# says degraded means process-level facts only, with the missing measurements
# NAMED rather than implied to have been taken.
# ============================================================

# Minecraft's own words for a missed tick deadline. Measured against real
# pokemoncraft and fc8 logs. It is BUILT IN rather than guessed at for every
# game: on a server that never prints this sentence, counting zero matches of it
# is not a clean bill of health, it is a pattern that cannot fire. Another game
# gets its own pattern from the template (evidence.lag) or gets told that this
# particular measurement is not available here.
$script:RkLagRe = [regex]'Running (\d+)ms or (\d+) ticks behind'

function Get-RkLagPattern {
  # The regex that means "this server missed a deadline" for this game, or
  # $null when nobody has established what that looks like.
  param($Template)
  if ($Template -and $Template.evidence -and $Template.evidence.lag) {
    try { return [regex]([string]$Template.evidence.lag) } catch { return $null }
  }
  # No template resolved: the caller is on the pre-template Minecraft path
  # (Get-RkLogFile falls back to logs\latest.log for exactly the same reason).
  if (-not $Template) { return $script:RkLagRe }
  if ([string]$Template.id -eq 'minecraft') { return $script:RkLagRe }
  return $null
}

# ============================================================================
# SHARED UI EVIDENCE PLUMBING
# Also used by rk-players.ps1, which dot-sources this file when these functions
# are not already defined. They live here rather than in two copies because the
# question they answer - "where is the log, and what do I say when there is not
# one" - must have ONE answer across the window; two drifting copies is how the
# roster and the vitals row came to disagree about what they were reading.
# ============================================================================

# ---- the capability contract ------------------------------------------------
# lib\rk-capabilities.psd1 holds one sentence per requirement saying, in words a
# person can act on, what is lost when that requirement is unmet. The UI quotes
# that sentence verbatim instead of inventing its own wording, so there is
# exactly one place where the reason a measurement is missing is written down.
$script:RkCapReq = $null
function Get-RkCapabilityWhy {
  param([Parameter(Mandatory)][string]$Requirement)
  if ($null -eq $script:RkCapReq) {
    $script:RkCapReq = @{}
    try {
      $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\rk-capabilities.psd1'
      if (Test-Path -LiteralPath $p) {
        $c = Import-PowerShellDataFile -LiteralPath $p
        if ($c -and $c.requirements) { $script:RkCapReq = $c.requirements }
      }
    } catch { $script:RkCapReq = @{} }
  }
  try {
    $r = $script:RkCapReq[$Requirement]
    if ($r -and $r.why) { return [string]$r.why }
  } catch { }
  return ''
}

function Get-RkUiTemplate {
  # The game template for a folder, or $null. Never throws: a window must open
  # even when the template layer is unavailable, it just has less to say.
  param([Parameter(Mandatory)][string]$ServerDir)
  if (-not (Get-Command Find-RkGame -ErrorAction SilentlyContinue)) { return $null }
  try { return (Find-RkGame -ServerDir $ServerDir) } catch { return $null }
}

function Get-RkUiLogSource {
  # Where this game's log actually is. Returns @{ Path; Mode }, Path $null when
  # there is no readable log - which is a real answer, not an error.
  #
  # Mode:
  #   resolver - lib\rk-common.ps1 Get-RkLogFile answered (globs, captured
  #              stdout, per-game paths).
  #   legacy   - Get-RkLogFile is not loaded, so this fell back to the
  #              pre-[R-071] hardcoded logs\latest.log. Callers MUST show this.
  #              Quietly reverting to the old behaviour is the disease, not the
  #              cure: a fallback nobody can see is indistinguishable from the
  #              bug this file was rewritten to remove.
  param([Parameter(Mandatory)][string]$ServerDir, $Template)

  if (Get-Command Get-RkLogFile -ErrorAction SilentlyContinue) {
    $p = $null
    try { $p = Get-RkLogFile -ServerDir $ServerDir -Template $Template } catch { $p = $null }
    if ($p) { return [pscustomobject]@{ Path = [string]$p; Mode = 'resolver' } }
    return [pscustomobject]@{ Path = $null; Mode = 'resolver' }
  }

  $legacy = Join-Path $ServerDir 'logs\latest.log'
  if (Test-Path -LiteralPath $legacy) { return [pscustomobject]@{ Path = $legacy; Mode = 'legacy' } }
  return [pscustomobject]@{ Path = $null; Mode = 'legacy' }
}

# ---- reading the tail -------------------------------------------------------

function Get-RkLogTailInfo {
  # Returns @{ Lines; Bytes; Ok }. Bytes is what was ACTUALLY read, not the size
  # of the window that was asked for - the whole point of this rewrite is that
  # nobody downstream may assume a read happened.
  param([string]$Path, [int]$Bytes = 262144)
  $empty = [pscustomobject]@{ Lines = @(); Bytes = 0; Ok = $false }
  if (-not $Path) { return $empty }
  if (-not (Test-Path -LiteralPath $Path)) { return $empty }
  $from = 0
  try {
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
      $len  = $fs.Length
      $from = [Math]::Max(0, $len - $Bytes)
      [void]$fs.Seek($from, [System.IO.SeekOrigin]::Begin)
      $count = [int]($len - $from)
      if ($count -le 0) { return [pscustomobject]@{ Lines = @(); Bytes = 0; Ok = $true } }
      $buf = New-Object 'byte[]' $count
      [void]$fs.Read($buf, 0, $count)
    } finally { $fs.Close() }
  } catch { return $empty }
  $text = [System.Text.Encoding]::UTF8.GetString($buf)
  if ($text.IndexOf([char]0xFFFD) -ge 0) { $text = [System.Text.Encoding]::Default.GetString($buf) }
  $lines = @($text -split "`r?`n")
  # The first line was cut mid-sentence by seeking to a byte offset. Drop it
  # rather than let half a line be matched against.
  if ($lines.Count -gt 1 -and $from -gt 0) { $lines = $lines[1..($lines.Count - 1)] }
  return [pscustomobject]@{ Lines = $lines; Bytes = $buf.Length; Ok = $true }
}

function Get-RkLogTail {
  # Kept for callers that only want the lines. It cannot tell "nothing to read"
  # from "nothing was read", so nothing inside this file uses it any more.
  param([string]$Path, [int]$Bytes = 262144)
  return @((Get-RkLogTailInfo -Path $Path -Bytes $Bytes).Lines)
}

function Get-RkVitals {
  param([Parameter(Mandatory)][string]$ServerDir, [int]$Bytes = 262144, $Template)

  $stateDir = Join-Path $ServerDir 'respawnkeeper'
  if (-not $Template) { $Template = Get-RkUiTemplate -ServerDir $ServerDir }
  $src = Get-RkUiLogSource -ServerDir $ServerDir -Template $Template

  $lagCount = 0; $worstMs = 0; $worstTicks = 0; $lastMs = 0
  $scanned = 0
  $lagMeasured = $false
  $reason = ''

  $lagRe = Get-RkLagPattern -Template $Template

  if (-not $src.Path) {
    # No readable stream. NOT "no lag" - see the header.
    $reason = 'logStream'
  } elseif (-not $lagRe) {
    # There is a log, and it is being read for everything else, but nobody has
    # established what a missed tick looks like in THIS game. Counting zero
    # matches of Minecraft's sentence in a Valheim log would be the same lie in
    # a smaller font.
    $reason = 'lagEvidence'
  } else {
    $tail = Get-RkLogTailInfo -Path $src.Path -Bytes $Bytes
    $scanned = $tail.Bytes
    if (-not $tail.Ok) {
      $reason = 'logUnreadable'
    } elseif ($tail.Bytes -le 0) {
      # The file is there and empty. Saying "no lag in the last 0KB" is true and
      # useless, and reads as good news, so it is not said.
      $reason = 'logEmpty'
    } else {
      $lagMeasured = $true
      foreach ($ln in $tail.Lines) {
        $m = $lagRe.Match($ln)
        if (-not $m.Success) { continue }
        $lagCount++
        # Groups 1 and 2 are how big the miss was. A template pattern that only
        # marks the line without capturing them still counts - the count is the
        # measurement, the size is the detail.
        $ms = 0; $tk = 0
        if ($m.Groups.Count -ge 2) { try { $ms = [int]$m.Groups[1].Value } catch { $ms = 0 } }
        if ($m.Groups.Count -ge 3) { try { $tk = [int]$m.Groups[2].Value } catch { $tk = 0 } }
        $lastMs = $ms
        if ($ms -gt $worstMs) { $worstMs = $ms; $worstTicks = $tk }
      }
    }
  }

  # Memory comes from the process, not the log - and only if the pid the
  # supervisor wrote is still the process that is alive. These are the facts
  # that survive a missing log, and they are what 'degraded' is allowed to show.
  $memMB = 0; $uptimeMin = 0; $procMeasured = $false
  $pf = Join-Path $stateDir 'server.pid'
  if (Test-Path -LiteralPath $pf) {
    try {
      $id = [int]((Get-Content -LiteralPath $pf -Raw).Trim())
      $p  = Get-Process -Id $id -ErrorAction Stop
      # PrivateMemorySize64, NOT WorkingSet64. Windows trims the working set of
      # a process nobody is touching, so an idle server reported 161 MB
      # moments after the same process measured 7,845 MB - a number that would
      # have sent someone hunting for a memory leak that had not happened.
      # Private bytes is what the JVM has actually taken from the OS.
      $memMB     = [int]($p.PrivateMemorySize64 / 1MB)
      $uptimeMin = [int](([datetime]::Now - $p.StartTime).TotalMinutes)
      $procMeasured = $true
    } catch { }
  }

  $crashes = 0; $repairs = 0
  try {
    $st = Get-Content -LiteralPath (Join-Path $stateDir 'state.json') -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($st.crashTimes)     { $crashes = @($st.crashTimes).Count }
    if ($st.repairAttempts) { $repairs = [int]$st.repairAttempts }
  } catch { }

  # Round UP a partial kilobyte: a 400-byte read is "1KB", never "0KB". Zero is
  # reserved for "nothing was read", and that case never reaches a caller with
  # LagMeasured true anyway.
  $scannedKB = 0
  if ($scanned -gt 0) { $scannedKB = [int][Math]::Max(1, [Math]::Round($scanned / 1KB)) }

  return [pscustomobject]@{
    LagCount     = $lagCount
    WorstMs      = $worstMs
    WorstTicks   = $worstTicks
    LastMs       = $lastMs
    ScannedKB    = $scannedKB
    ScannedBytes = $scanned
    MemMB        = $memMB
    UptimeMin    = $uptimeMin
    Crashes      = $crashes
    Repairs      = $repairs

    # ---- what was, and was not, actually observed --------------------------
    # LagMeasured false means LagCount/WorstMs are NOT measurements. They are
    # zeros because nothing was read. A caller that prints the reassuring line
    # without looking at this flag has reintroduced [R-071].
    LagMeasured  = $lagMeasured
    ProcMeasured = $procMeasured
    Degraded     = (-not $lagMeasured)
    UnmetReason  = $reason
    UnmetWhy     = $(if ($reason) { Get-RkCapabilityWhy -Requirement $reason } else { '' })
    LogPath      = $src.Path
    LogMode      = $src.Mode
    GameId       = $(if ($Template -and $Template.id) { [string]$Template.id } else { '' })
  }
}
