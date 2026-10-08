# ============================================================
# rk-lock.ps1 - the repair lock  (respawnkeeper stage 1)
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS ([R-008]). The harness and an interactive Claude session do
# NOT collide in conversation - the harness starts `claude -p` as a separate
# process. What they collide over is:
#   (1) files   - both writing config\ / mods\ (this has already happened, in fc8)
#   (2) the server - one restarts it while the other is working on it
#   (3) the token budget
# One lock file plus a "look before you write" convention closes (1) and (2).
#
# THE CONVENTION, in one line:
#   Before writing anything under a server directory, run
#     powershell -File harness\rk-lock.ps1 -ServerDir <dir> -Check
#   and if it says HELD, read and investigate but do not write.
#
# Usage:
#   -Check    exit 0 = free, 3 = held (prints the holder)
#   -Acquire  take the lock (-Reason "..." -Owner "..."). exit 3 if already held
#   -Release  release a lock this process/owner holds
#   -Force    with -Release: break someone else's lock (prints what it broke)
#   -Wait <s> with -Acquire: retry for up to N seconds before giving up
#
# The lock is advisory. It cannot stop a process that ignores it; what it does
# is make "somebody else is mid-repair" a fact you can check in one command
# instead of a thing you have to remember.
# ============================================================

param(
  [Parameter(Mandatory)][string]$ServerDir,
  [switch]$Check,
  [switch]$Acquire,
  [switch]$Release,
  [switch]$Force,
  [string]$Reason = '',
  [string]$Owner  = '',
  [int]$Wait      = 0,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\rk-common.ps1')

$ServerDir = Resolve-RkServerDir -Path $ServerDir
$StateDir  = Get-RkStateDir -ServerDir $ServerDir
$LockFile  = Join-Path $StateDir 'repair.lock'

if (-not $Owner) {
  $Owner = $env:RESPAWNKEEPER_OWNER
  if (-not $Owner) { $Owner = ($env:USERNAME + '@' + $env:COMPUTERNAME) }
}

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

function Get-LockState {
  # Returns @{ held; stale; data }. A lock whose owning PID is gone is STALE:
  # a crashed repair must not wedge the server forever.
  if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) {
    return @{ held = $false; stale = $false; data = $null }
  }
  $d = Read-RkJson -Path $LockFile
  if (-not $d) {
    return @{ held = $true; stale = $true; data = $null }   # unreadable = treat as stale
  }
  $alive = $false
  if ($d.pid -and ([int]$d.pid) -gt 0) {
    if (Get-Process -Id ([int]$d.pid) -ErrorAction SilentlyContinue) { $alive = $true }
  }
  return @{ held = $true; stale = (-not $alive); data = $d }
}

function Show-Lock($st) {
  if (-not $st.data) { Say "  (lock file is present but unreadable)"; return }
  Say ("  owner   : " + $st.data.owner)
  Say ("  pid     : " + $st.data.pid + $(if ($st.stale) { '  <- process is GONE (stale)' } else { '  (alive)' }))
  Say ("  since   : " + $st.data.acquiredUtc + " UTC")
  Say ("  reason  : " + $st.data.reason)
}

# ---- -Check -----------------------------------------------------------------
if ($Check) {
  $st = Get-LockState
  if (-not $st.held) { Say "FREE   $LockFile"; exit 0 }
  if ($st.stale) {
    Say "STALE  $LockFile"
    Show-Lock $st
    Say "  -> the holder is dead. Release it with: -Release -Force"
    exit 3
  }
  Say "HELD   $LockFile"
  Show-Lock $st
  Say "  -> a repair is in progress. Read and investigate, but do not write under this server."
  exit 3
}

# ---- -Acquire ---------------------------------------------------------------
if ($Acquire) {
  if (-not $Reason) { $Reason = 'unspecified' }
  $deadline = (Get-Date).AddSeconds([Math]::Max(0, $Wait))
  while ($true) {
    $st = Get-LockState
    if ((-not $st.held) -or $st.stale) {
      if ($st.stale) { Say "note: breaking a stale lock (holder pid is gone)." }
      $data = [ordered]@{
        owner       = $Owner
        pid         = $PID
        acquiredUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        reason      = $Reason
        serverDir   = $ServerDir
        host        = $env:COMPUTERNAME
      }
      Write-RkJson -Path $LockFile -Object $data
      # Re-read: on a race, whoever wrote last owns it, and both sides can see so.
      Start-Sleep -Milliseconds 120
      $back = Read-RkJson -Path $LockFile
      if ($back -and ([int]$back.pid -eq $PID)) {
        Say ("ACQUIRED $LockFile (pid $PID)")
        Write-RkLog -StateDir $StateDir -Message ("repair lock ACQUIRED by " + $Owner + " pid " + $PID + " : " + $Reason) -Quiet:$Quiet
        exit 0
      }
      Say "lost a race for the lock; retrying."
    }
    if ((Get-Date) -ge $deadline) {
      Say "BUSY   $LockFile"
      Show-Lock $st
      exit 3
    }
    Start-Sleep -Seconds 2
  }
}

# ---- -Release ---------------------------------------------------------------
if ($Release) {
  $st = Get-LockState
  if (-not $st.held) { Say "already FREE"; exit 0 }
  $mine = $false
  if ($st.data) {
    if (([int]$st.data.pid -eq $PID) -or ($st.data.owner -eq $Owner)) { $mine = $true }
  }
  if ((-not $mine) -and (-not $st.stale) -and (-not $Force)) {
    Say "REFUSED: this lock belongs to someone else and is not stale."
    Show-Lock $st
    Say "  -> pass -Force only if you are certain the holder is finished."
    exit 3
  }
  if ($Force -and (-not $mine)) {
    Say "FORCING release of a lock held by:"
    Show-Lock $st
  }
  Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
  Say "RELEASED $LockFile"
  Write-RkLog -StateDir $StateDir -Message ("repair lock RELEASED by " + $Owner + " pid " + $PID + $(if ($Force) { ' (forced)' } else { '' })) -Quiet:$Quiet
  exit 0
}

Write-Host "rk-lock.ps1: pass one of -Check / -Acquire / -Release."
exit 2
