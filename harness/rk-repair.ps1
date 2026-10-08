# ============================================================
# rk-repair.ps1 - applies ONE safe, reversible repair  (respawnkeeper stage 3)
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# THREE RULES, and they are not negotiable:
#   1. NEVER touch a running server. Proved from the machine every time via
#      Assert-RkServerStopped, not assumed from a flag or a human's word
#      ([R-007] item 1; the fc8 hot-swap incident; the upper CLAUDE.md line
#      "do not take 'I stopped it' at face value").
#   2. MOVE, never delete. Everything goes to <StateDir>\quarantine\<stamp>\
#      with a MANIFEST.json, and -Undo puts it all back.
#   3. DRY RUN BY DEFAULT. Nothing changes unless -Apply is passed.
#
# Success rate of unattended repair, measured: 1 of 3 ([R-007] item 2). That is
# why the default when a repair does not stick is HALT, not another attempt.
#
# Usage:
#   powershell -File rk-repair.ps1 -ServerDir <dir>                  # dry run from diagnosis.json
#   powershell -File rk-repair.ps1 -ServerDir <dir> -Apply
#   powershell -File rk-repair.ps1 -ServerDir <dir> -Undo last
#   powershell -File rk-repair.ps1 -ServerDir <dir> -ListQuarantine
#
# Exit codes: 0 = repair applied (or dry run OK) | 3 = HALT (nothing done)
#             2 = usage/precondition failure
# ============================================================

param(
  [Parameter(Mandatory)][string]$ServerDir,
  [string]$DiagnosisFile = '',   # default <StateDir>\diagnosis.json
  [switch]$Apply,
  [string]$Undo          = '',   # a quarantine stamp, or 'last'
  [switch]$ListQuarantine,
  [switch]$NoLock,               # caller already holds the repair lock
  [string]$Owner         = '',
  [switch]$AllowModRemoval,      # override the profile for this run
  [string]$GamesDir      = '',   # see rk-diagnose.ps1; same reason
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\rk-common.ps1')

$ServerDir     = Resolve-RkServerDir -Path $ServerDir -GamesDir $GamesDir
$StateDir      = Get-RkStateDir -ServerDir $ServerDir
$QuarantineDir = Join-Path $StateDir 'quarantine'
$ResultFile    = Join-Path $StateDir 'repair-result.txt'
if (-not $DiagnosisFile) { $DiagnosisFile = Join-Path $StateDir 'diagnosis.json' }
if (-not $Owner) {
  $Owner = $env:RESPAWNKEEPER_OWNER
  if (-not $Owner) { $Owner = 'rk-repair' }
}

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }
function RLog([string]$m) { Write-RkLog -StateDir $StateDir -Message $m -LogName 'repair.log' -Quiet:$Quiet }

$Game = $null
try { $Game = Find-RkGame -ServerDir $ServerDir -Templates (Get-RkGameTemplates -GamesDir $GamesDir) } catch {}

# ---- Which crash rule table, if any ----------------------------------------
# 2026-09-12 ([R-072] item 3): Write-ComebackNote used to load
# rules\crash-rules.psd1 by name, for every game. That table names jars, Mixins,
# Forge and JVM crash reports; run over a Unity server it cannot produce a right
# answer, only a confident wrong one. rk-diagnose.ps1 and rk-logscan.ps1 were
# wired to the template's own 'rules' field; this was the last place that was
# not, so the same shape is used here.
#
# An EMPTY 'rules' is a real, supported answer: this game has no crash rule
# table. The note then simply carries no soft-fork hint, which is the true
# statement. Nothing here throws - this lookup only decorates a report, and a
# report writer must never be the thing that fails a repair path.
$RulesFile   = ''
$RulesOrigin = ''
if ($Game) {
  if ($Game.rules) {
    $RulesFile   = Join-Path $PSScriptRoot (Join-Path 'rules' ([string]$Game.rules))
    $RulesOrigin = ('template ' + $Game.id)
  } else {
    $RulesOrigin = ('template ' + $Game.id + ' declares no rule table')
  }
} else {
  # No template matched. Same back-compat fallback rk-diagnose.ps1 uses, so the
  # two agree about what a diagnosis was produced from.
  $RulesFile   = Join-Path $PSScriptRoot 'rules\crash-rules.psd1'
  $RulesOrigin = 'no template matched - falling back to the Minecraft table'
}
$CrashRules = @()
if ($RulesFile) {
  if (Test-Path -LiteralPath $RulesFile) {
    try { $CrashRules = @((Import-PowerShellDataFile -LiteralPath $RulesFile).rules) }
    catch { $CrashRules = @(); $RulesOrigin = ($RulesOrigin + ' - could not be read: ' + $_.Exception.Message) }
  } else {
    $RulesOrigin = ($RulesOrigin + ' - file not found: ' + $RulesFile)
  }
}

# Whether this server's world has already been played. A dependency graph can
# tell you that removing a mod breaks other MODS; nothing in a jar can tell you
# that removing it empties chests in a world people have been playing for
# months. That fact is not measurable, so it is DECLARED once per server by a
# human (rk-setup asks) rather than guessed at 3am.
$ProfileAllowsRemoval = $true
$SrvProfile = Get-RkProfile -ServerDir $ServerDir
if ($SrvProfile -and ($null -ne $SrvProfile.PSObject.Properties['allowModRemoval'])) {
  $ProfileAllowsRemoval = [bool]$SrvProfile.allowModRemoval
}
if ($AllowModRemoval) { $ProfileAllowsRemoval = $true }

function Write-ComebackNote {
  # The point of this file: a removal that nobody writes down becomes a mod that
  # is simply gone. This turns the quarantine into a WORK QUEUE - what broke,
  # what the gates said, and what could be done tomorrow instead of removal.
  # It is written whether the removal happened OR was blocked; the blocked case
  # is the more valuable one, because a mod that cannot be pulled is precisely
  # the one worth fixing with a Mixin or a shim.
  param(
    [Parameter(Mandatory)][string]$JarPath,
    [Parameter(Mandatory)]$Check,          # Test-RkModRemovable result
    $Diag,
    [string]$Stamp = ''
  )
  $strFile = Join-Path $PSScriptRoot 'rules\comeback-report.ja.json'
  $S = $null
  try { $S = Get-Content -LiteralPath $strFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  if (-not $S) { return '' }

  $reportDir = Join-Path $StateDir 'reports'
  if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
  $who = $Check.modid
  if (-not $who) { $who = [System.IO.Path]::GetFileNameWithoutExtension($JarPath) }
  $safe = ($who -replace '[^A-Za-z0-9_.-]', '_')
  if (-not $Stamp) { $Stamp = Get-RkStamp }
  $out = Join-Path $reportDir ('comeback-' + $safe + '-' + $Stamp + '.md')

  $removed = [bool]$Check.removable
  $sb = New-Object System.Text.StringBuilder
  function W2([string]$s) { [void]$sb.AppendLine($s) }
  function WL2($lines) { foreach ($l in @($lines)) { [void]$sb.AppendLine([string]$l) } }
  $now = (Get-Date -Format 'yyyy-MM-dd HH:mm')

  if ($removed) { W2 ([string]::Format($S.title_removed, $who, $now)) } else { W2 ([string]::Format($S.title_blocked, $who, $now)) }
  W2 ''
  if ($removed) { WL2 $S.lead_removed } else { WL2 $S.lead_blocked }
  W2 ''

  $ruleId = ''; $summary = ''; $crash = ''; $evid = ''
  if ($Diag) {
    $summary = [string]$Diag.summary
    $crash   = [string]$Diag.crashReport
    if ($Diag.primary) { $ruleId = [string]$Diag.primary.ruleId; $evid = [string]$Diag.primary.evidenceLine }
  }
  W2 $S.h_what
  W2 ''
  W2 '| | |'
  W2 '|---|---|'
  W2 ([string]::Format($S.w_rule, $ruleId))
  W2 ([string]::Format($S.w_summary, ($summary -replace '\|', '\|')))
  W2 ([string]::Format($S.w_jar, (Split-Path -Leaf $JarPath)))
  W2 ([string]::Format($S.w_modid, $Check.modid))
  W2 ([string]::Format($S.w_crash, $crash))
  if ($evid) { W2 ([string]::Format($S.w_evidence, ($evid -replace '\|', '\|'))) }
  W2 ''

  W2 $S.h_gates
  W2 ''
  W2 $S.g_header
  W2 '|---|---|---|'
  $gWorld = $(if ($ProfileAllowsRemoval) { $S.g_ok } else { $S.g_ng })
  $gDeps  = $(if (@($Check.dependents).Count -eq 0) { $S.g_ok } else { $S.g_ng + ' (' + @($Check.dependents).Count + ')' })
  $gDist  = $(if (-not $Check.distributed) { $S.g_ok } else { $S.g_ng })
  W2 ([string]::Format($S.g_world, $gWorld))
  W2 ([string]::Format($S.g_deps,  $gDeps))
  W2 ([string]::Format($S.g_dist,  $gDist))
  W2 ''

  if (-not $removed) {
    W2 $S.h_blocked
    W2 ''
    foreach ($r in @($Check.reasons)) { W2 ('- ' + $r) }
    W2 ''
  }

  if (@($Check.dependents).Count -gt 0) {
    W2 ([string]::Format($S.h_dependents, @($Check.dependents).Count))
    W2 ''
    W2 ([string]::Format($S.d_note, (@($Check.dependents).Count + 1)))
    W2 ''
    foreach ($d in @($Check.dependents)) { W2 ('- `' + $d + '`') }
    W2 ''
  }

  W2 $S.h_next
  W2 ''
  # Whether a Mixin can help is a property of the CRASH KIND, and the rule table
  # records it per rule (softFork / softForkNote), from the same real crashes the
  # rules came from.
  if ($ruleId -and (@($CrashRules).Count -gt 0)) {
    try {
      $r = @($CrashRules | Where-Object { $_.id -eq $ruleId })[0]
      if ($r) {
        if ($r.softFork -eq 'none') { W2 ([string]::Format($S.next_hint_nomixin, $r.softForkNote)) }
        else { W2 ([string]::Format($S.next_hint_mixin, ('[' + $r.softFork + '] ' + $r.softForkNote))) }
        W2 ''
      }
    } catch {}
  }
  WL2 $S.next
  W2 ''
  W2 $S.h_limits
  W2 ''
  WL2 $S.limits
  W2 ''

  [System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
  return $out
}

function Set-Result([string]$verdict) {
  # First line is the verdict, in exactly the shape fc8's Tier2 contract used
  # (FIXED: / HALT: / SECURITY-HALT:). The supervisor reads only the first line,
  # so a Tier1 repair and a Tier2/Tier3 hook are indistinguishable to it.
  [System.IO.File]::WriteAllText($ResultFile, ($verdict + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# ---- -ListQuarantine --------------------------------------------------------
if ($ListQuarantine) {
  if (-not (Test-Path $QuarantineDir)) { Say 'quarantine is empty.'; exit 0 }
  foreach ($d in (Get-ChildItem -LiteralPath $QuarantineDir -Directory | Sort-Object Name)) {
    $man = Read-RkJson -Path (Join-Path $d.FullName 'MANIFEST.json')
    Say ('--- ' + $d.Name)
    if ($man) {
      Say ('    action : ' + $man.action)
      Say ('    reason : ' + $man.reason)
      Say ('    undone : ' + $man.undone)
      foreach ($it in $man.items) { Say ('    file   : ' + $it.originalPath) }
    } else { Say '    (no MANIFEST.json)' }
  }
  exit 0
}

# ---- -Undo ------------------------------------------------------------------
if ($Undo) {
  if (-not (Test-Path $QuarantineDir)) { Say 'nothing to undo (no quarantine folder).'; exit 2 }
  $stamp = $Undo
  if ($Undo -eq 'last') {
    $last = Get-ChildItem -LiteralPath $QuarantineDir -Directory |
      Where-Object { (Read-RkJson -Path (Join-Path $_.FullName 'MANIFEST.json')).undone -ne $true } |
      Sort-Object Name | Select-Object -Last 1
    if (-not $last) { Say 'nothing to undo (every quarantine entry is already undone).'; exit 2 }
    $stamp = $last.Name
  }
  $dir = Join-Path $QuarantineDir $stamp
  $manPath = Join-Path $dir 'MANIFEST.json'
  if (-not (Test-Path $manPath)) { Say ("no such quarantine entry: " + $stamp); exit 2 }

  # Undo is a write to the server, so it is gated exactly like a repair.
  Assert-RkServerStopped -ServerDir $ServerDir -Template $Game | Out-Null
  $man = Read-RkJson -Path $manPath
  $restored = 0
  foreach ($it in $man.items) {
    $src = Join-Path $dir $it.storedAs
    if (-not (Test-Path -LiteralPath $src)) { Say ('  MISSING in quarantine: ' + $it.storedAs); continue }
    if (Test-Path -LiteralPath $it.originalPath) { Say ('  already present, skipping: ' + $it.originalPath); continue }
    if ($Apply) {
      $parent = Split-Path -Parent $it.originalPath
      if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
      Move-Item -LiteralPath $src -Destination $it.originalPath -Force
      $restored++
    }
    Say (($(if ($Apply) { '  restored: ' } else { '  WOULD restore: ' })) + $it.originalPath)
  }
  if ($Apply) {
    $man.undone = $true
    $man | Add-Member -NotePropertyName undoneAt -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Force
    Write-RkJson -Path $manPath -Object $man
    RLog ("UNDO " + $stamp + " restored " + $restored + " file(s)")
  } else {
    Say '(dry run - pass -Apply to actually restore)'
  }
  exit 0
}

# ---- Load the diagnosis -----------------------------------------------------
$diag = Read-RkJson -Path $DiagnosisFile
if (-not $diag) { Say ("no diagnosis to act on: " + $DiagnosisFile); Set-Result 'HALT: no diagnosis file'; exit 2 }

$action  = $diag.action
$targets = @($diag.targets)
$ruleId  = ''
if ($diag.primary) { $ruleId = $diag.primary.ruleId }

Say ''
Say '=== respawnkeeper repair ======================================='
Say ('server   : ' + $ServerDir)
Say ('rule     : ' + $ruleId)
Say ('rules    : ' + @($CrashRules).Count + ' (' + $RulesOrigin + ')')
Say ('action   : ' + $action)
Say ('targets  : ' + $(if ($targets.Count) { ($targets -join '; ') } else { '(none)' }))
Say ('mode     : ' + $(if ($Apply) { 'APPLY' } else { 'DRY RUN' }))

# ---- Actions that are not repairs -------------------------------------------
if ($action -eq 'RESTART') {
  Say 'nothing to repair - the verdict is "just start it again".'
  Set-Result 'FIXED: no repair needed (transient); restart only'
  exit 0
}
if (($action -eq 'HALT') -or ($action -eq 'ESCALATE')) {
  $why = $diag.summary
  Say ('HALT - ' + $why)
  # A HALT that came from the removal veto is the case most worth writing down:
  # a mod that cannot be pulled is precisely the one worth fixing with a Mixin
  # or a shim. The veto fires during diagnosis, so this branch - not the
  # QUARANTINE_MOD branch - is where those notes get written.
  foreach ($v in @($diag.removalVeto)) {
    $path = ''
    foreach ($t in @($diag.targets)) { if ((Split-Path -Leaf $t) -eq $v.jar) { $path = $t } }
    if (-not $path) { continue }
    $chk = @{
      removable = $false; modid = $v.modid; jar = $v.jar
      reasons = @($v.reasons); dependents = @($v.dependents); distributed = [bool]$v.distributed
    }
    $note = Write-ComebackNote -JarPath $path -Check $chk -Diag $diag
    if ($note) { Say ('  what to do instead: ' + $note) }
  }
  Set-Result ('HALT: ' + $why)
  exit 3
}
if (-not $diag.autoFixable) {
  Say 'the matched rule is marked NOT auto-fixable; a human decides this one.'
  Set-Result ('HALT: rule ' + $ruleId + ' is not auto-fixable - ' + $diag.summary)
  exit 3
}

# ---- Preconditions ----------------------------------------------------------
# (a) the server must be provably stopped
try {
  Assert-RkServerStopped -ServerDir $ServerDir -Template $Game | Out-Null
  Say 'precheck : server is stopped (port free, no live pid, no matching java)'
} catch {
  Say ('REFUSED  : ' + $_.Exception.Message)
  Set-Result ('HALT: refused to repair a running server - ' + $_.Exception.Message)
  exit 2
}

# (b) the repair lock
$lockTaken = $false
if (-not $NoLock) {
  & (Join-Path $PSScriptRoot 'rk-lock.ps1') -ServerDir $ServerDir -Acquire -Reason ("rk-repair " + $ruleId) -Owner $Owner -Quiet:$Quiet | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Say 'REFUSED  : could not take the repair lock (someone else is working on this server).'
    Set-Result 'HALT: repair lock is held by another process'
    exit 2
  }
  $lockTaken = $true
  Say 'precheck : repair lock acquired'
}

$stamp = Get-RkStamp
$dest  = Join-Path $QuarantineDir $stamp
$items = New-Object System.Collections.ArrayList
$exitCode = 0

try {
  if (-not $targets -or $targets.Count -eq 0) {
    Say 'no resolved target - refusing to guess.'
    Set-Result ('HALT: ' + $ruleId + ' matched but no target could be resolved')
    $exitCode = 3
  }
  else {
    switch ($action) {

      # ---- Move the offending jar(s) out of mods\ ---------------------------
      'QUARANTINE_MOD' {
        # THE VETO, before anything moves. "Quarantine the mod that crashed"
        # sounds like removing one thing; on the real pokemoncraft install,
        # removing `create` would remove 34 (33 mods declare it required).
        # Every gate here is mechanical - see Test-RkModRemovable.
        $blocked = New-Object System.Collections.ArrayList
        $allowed = New-Object System.Collections.ArrayList
        $modIndex = Get-RkModIndex -ServerDir $ServerDir -Template $Game
        foreach ($t in $targets) {
          if (-not (Test-Path -LiteralPath $t)) { Say ('  gone already: ' + $t); continue }
          $chk = Test-RkModRemovable -ServerDir $ServerDir -JarPath $t -Template $Game `
                   -AllowModRemoval $ProfileAllowsRemoval -Index $modIndex
          if ($chk.removable) { [void]$allowed.Add(@{ path = $t; check = $chk }) }
          else { [void]$blocked.Add(@{ path = $t; check = $chk }) }
        }

        if ($blocked.Count -gt 0) {
          # One blocked target blocks the whole action. Removing "the ones we are
          # allowed to" would leave a half-applied repair, which is worse than
          # none: the server still crashes AND the mod list has changed.
          Say ''
          foreach ($b in $blocked) {
            Say ('  REFUSING to remove ' + (Split-Path -Leaf $b.path))
            foreach ($r in @($b.check.reasons)) { Say ('    - ' + $r) }
            if (@($b.check.dependents).Count -gt 0) {
              Say ('    would also break: ' + ((@($b.check.dependents) | Select-Object -First 8) -join ', ') +
                   $(if (@($b.check.dependents).Count -gt 8) { ' ... (' + @($b.check.dependents).Count + ' total)' } else { '' }))
            }
            $note = Write-ComebackNote -JarPath $b.path -Check $b.check -Diag $diag -Stamp $stamp
            if ($note) { Say ('    what to do instead: ' + $note) }
          }
          Say ''
          $first = $blocked[0].check
          Set-Result ('HALT: refused to remove ' + (Split-Path -Leaf $blocked[0].path) + ' - ' + (@($first.reasons) -join '; '))
          $exitCode = 3
          break
        }

        foreach ($a in $allowed) {
          $t = $a.path
          $leaf = Split-Path -Leaf $t
          Say (($(if ($Apply) { '  quarantine: ' } else { '  WOULD quarantine: ' })) + $t)
          Say ('    gates: no dependents, not distributed to players, world removable')
          if ($Apply) {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
            Move-Item -LiteralPath $t -Destination (Join-Path $dest $leaf) -Force
            $note = Write-ComebackNote -JarPath $t -Check $a.check -Diag $diag -Stamp $stamp
            if ($note) { Say ('    comeback note: ' + $note) }
          }
          [void]$items.Add([ordered]@{ originalPath = $t; storedAs = $leaf })
        }
      }

      # ---- Copy the unparseable config aside, then remove it ---------------
      'RESET_CONFIG' {
        foreach ($t in $targets) {
          if (-not (Test-Path -LiteralPath $t)) { Say ('  gone already: ' + $t); continue }
          $leaf = Split-Path -Leaf $t
          Say (($(if ($Apply) { '  reset: ' } else { '  WOULD reset: ' })) + $t)
          Say '         (the mod regenerates defaults on next boot; the old file is kept in quarantine to diff)'
          if ($Apply) {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
            Move-Item -LiteralPath $t -Destination (Join-Path $dest $leaf) -Force
          }
          [void]$items.Add([ordered]@{ originalPath = $t; storedAs = $leaf })
        }
      }

      # ---- The one action that writes under world\ -------------------------
      'CLEAR_WORLD_LOCK' {
        # Re-prove liveness a second time, immediately before touching world\.
        Assert-RkServerStopped -ServerDir $ServerDir -Template $Game | Out-Null
        $level = Get-RkLevelName -ServerDir $ServerDir
        $lock  = Join-Path $ServerDir (Join-Path $level 'session.lock')
        if (-not (Test-Path -LiteralPath $lock)) {
          Say ('  no session.lock at ' + $lock + ' - nothing to do')
        } else {
          Say (($(if ($Apply) { '  clearing: ' } else { '  WOULD clear: ' })) + $lock)
          if ($Apply) {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
            Move-Item -LiteralPath $lock -Destination (Join-Path $dest 'session.lock') -Force
          }
          [void]$items.Add([ordered]@{ originalPath = $lock; storedAs = 'session.lock' })
        }
      }

      default {
        Say ('unknown action in diagnosis: ' + $action)
        Set-Result ('HALT: unknown action ' + $action)
        $exitCode = 3
      }
    }

    if ($exitCode -eq 0) {
      if ($items.Count -eq 0) {
        Say 'nothing was actually changed (targets had already been dealt with).'
        Set-Result ('HALT: ' + $ruleId + ' target(s) were already gone; the cause may be elsewhere')
        $exitCode = 3
      }
      elseif ($Apply) {
        Write-RkJson -Path (Join-Path $dest 'MANIFEST.json') -Object ([ordered]@{
          schema     = 'respawnkeeper/quarantine/1'
          stamp      = $stamp
          appliedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
          serverDir  = $ServerDir
          action     = $action
          ruleId     = $ruleId
          reason     = $diag.summary
          owner      = $Owner
          undone     = $false
          items      = @($items)
        })
        $what = (($items | ForEach-Object { Split-Path -Leaf $_.originalPath }) -join ', ')
        RLog ($action + ' [' + $ruleId + '] -> ' + $what + '  (undo: rk-repair.ps1 -Undo ' + $stamp + ' -Apply)')
        Set-Result ('FIXED: ' + $action + ' ' + $what + ' (rule ' + $ruleId + '; undo stamp ' + $stamp + ')')
        Say ''
        Say ('APPLIED. undo with:  powershell -File rk-repair.ps1 -ServerDir "' + $ServerDir + '" -Undo ' + $stamp + ' -Apply')
      }
      else {
        Say ''
        Say '(dry run - nothing was changed. pass -Apply to do it.)'
        Set-Result ('HALT: dry run only, no repair applied')
      }
    }
  }
}
finally {
  if ($lockTaken) {
    & (Join-Path $PSScriptRoot 'rk-lock.ps1') -ServerDir $ServerDir -Release -Owner $Owner -Quiet:$Quiet | Out-Null
  }
}

Say '================================================================'
exit $exitCode
