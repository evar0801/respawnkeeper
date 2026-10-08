# ============================================================
# rk-diagnose.ps1 - Tier1 cause identification  (respawnkeeper stage 3, tier 1)
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# THE WHOLE POINT ([R-006]): most crashes are the SAME mod failing the SAME way,
# so the first tier must be a table lookup with NO language model in it. Paying
# a model to re-derive "Structory_Towers is not a valid mod file" every time is
# the failure mode this design exists to avoid. Tier2/Tier3 are for what this
# script cannot match - and it says so plainly instead of guessing.
#
# READ-ONLY. This script never writes to the server. It writes exactly one
# file, <ServerDir>\respawnkeeper\diagnosis.json, and prints a summary.
#
# Usage:
#   powershell -File rk-diagnose.ps1 -ServerDir <dir>
#   powershell -File rk-diagnose.ps1 -ServerDir <dir> -CrashReport <path>
#   powershell -File rk-diagnose.ps1 -ServerDir <dir> -Since '2026-08-26 20:00'
#
# Exit codes:  0 = a rule matched   4 = no rule matched (escalate)   2 = usage
# ============================================================

param(
  [Parameter(Mandatory)][string]$ServerDir,
  [string]$CrashReport = '',          # default: newest report in crash-reports\
  [string]$Since       = '',          # only consider reports newer than this
  [string]$RulesFile   = '',          # default: rules\crash-rules.psd1
  [int]$LogTailLines   = 400,
  [string]$OutFile     = '',          # default: <StateDir>\diagnosis.json
  # Where the game templates live. Empty = harness\games. Threaded in from
  # respawnkeeper.ps1 so a supervisor started on a fixture game hands its
  # children the SAME template set it is using itself; without it the child
  # re-resolves the folder against the shipped templates, finds nothing, and
  # throws - which used to take the supervisor down with it mid-crash-path.
  [string]$GamesDir    = '',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\rk-common.ps1')

$ServerDir = Resolve-RkServerDir -Path $ServerDir -GamesDir $GamesDir
$StateDir  = Get-RkStateDir -ServerDir $ServerDir
if (-not $OutFile)   { $OutFile   = Join-Path $StateDir 'diagnosis.json' }

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

# ---- Which rule table, if any ----------------------------------------------
# 2026-09-12 ([R-072]): this used to hardcode rules\crash-rules.psd1 for EVERY
# game. That table names jars, mixins, Forge and JVM crash reports - running it
# over a Unity server cannot produce a right answer, only a confident wrong one.
# The template's 'rules' field existed to say which table applies and was read
# by nothing, so it may as well not have existed.
#
# An EMPTY 'rules' is now a real, supported answer: this game has no crash rule
# table, so diagnosis reports that the server died and stops there. That is a
# smaller claim than the old behaviour made, and it is the true one.
$Game = $null
try { $Game = Find-RkGame -ServerDir $ServerDir -Templates (Get-RkGameTemplates -GamesDir $GamesDir) } catch {}

$rules       = @()
$rulesOrigin = ''
if ($RulesFile) {
  $rulesOrigin = 'explicit -RulesFile'
} elseif ($Game) {
  if ($Game.rules) {
    $RulesFile   = Join-Path $PSScriptRoot (Join-Path 'rules' ([string]$Game.rules))
    $rulesOrigin = ('template ' + $Game.id)
  } else {
    $rulesOrigin = ('template ' + $Game.id + ' declares no rule table')
  }
} else {
  # No template matched. Keep the historical default so nothing that worked
  # before stops working just because detection failed.
  $RulesFile   = Join-Path $PSScriptRoot 'rules\crash-rules.psd1'
  $rulesOrigin = 'no template matched - falling back to the Minecraft table'
}

if ($RulesFile) {
  if (-not (Test-Path -LiteralPath $RulesFile)) { throw "rules file not found: $RulesFile ($rulesOrigin)" }
  $rulesData = Import-PowerShellDataFile -LiteralPath $RulesFile
  $rules = @($rulesData.rules)
  if ($rules.Count -eq 0) { throw "rules file loaded but contains no rules: $RulesFile" }
}
Say ('rules    : ' + $rules.Count + ' (' + $rulesOrigin + ')')

# ---- Gather evidence --------------------------------------------------------
# Crash reports are already fully written when the JVM exits - the report is
# flushed before the process dies - so there is nothing to wait for here
# (respawnkeeper CLAUDE.md, technical note 1).
$crashDir = Join-Path $ServerDir 'crash-reports'
$report   = $null
if ($CrashReport) {
  if (-not (Test-Path -LiteralPath $CrashReport)) { throw "crash report not found: $CrashReport" }
  $report = Get-Item -LiteralPath $CrashReport
} elseif (Test-Path $crashDir) {
  $all = @(Get-ChildItem -LiteralPath $crashDir -Filter '*.txt' -ErrorAction SilentlyContinue)
  if ($Since) {
    $sinceDt = [datetime]::Parse($Since)
    $all = @($all | Where-Object { $_.LastWriteTime -gt $sinceDt })
  }
  $report = $all | Sort-Object LastWriteTime | Select-Object -Last 1
}

$reportText = ''
if ($report) {
  try { $reportText = Get-Content -LiteralPath $report.FullName -Raw -ErrorAction Stop } catch { $reportText = '' }
}

$latestLog = Join-Path $ServerDir 'logs\latest.log'
$logText = ''
if (Test-Path -LiteralPath $latestLog) {
  # Tail only. Never dump a whole log into anything - the KubeJS incident put
  # 71,803 identical ERROR lines into ONE log file.
  try { $logText = (Get-Content -LiteralPath $latestLog -Tail $LogTailLines -ErrorAction Stop) -join "`n" } catch { $logText = '' }
}

# ---- Mod / file resolution helpers -----------------------------------------

function Get-NormalizedName([string]$s) {
  if (-not $s) { return '' }
  return ($s.ToLower() -replace '[^a-z0-9]', '')
}

function Resolve-ModJarByModid {
  # modid -> exactly one jar under mods\, or a list of candidates.
  # Deliberately conservative: 0 or 2+ candidates is NOT a resolution. Removing
  # the wrong jar unattended is precisely the class of accident that made
  # "repair only while stopped, HALT when unsure" the rule.
  param([string]$Modid)
  $modsDir = Join-Path $ServerDir 'mods'
  if (-not (Test-Path $modsDir)) { return @{ resolved = $null; candidates = @() } }
  $needle = Get-NormalizedName $Modid
  if (-not $needle) { return @{ resolved = $null; candidates = @() } }
  $hits = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -ErrorAction SilentlyContinue |
    Where-Object { (Get-NormalizedName $_.Name).Contains($needle) })
  if ($hits.Count -eq 1) { return @{ resolved = $hits[0].FullName; candidates = @($hits[0].FullName) } }
  return @{ resolved = $null; candidates = @($hits | ForEach-Object { $_.FullName }) }
}

function Resolve-ModJarByPath {
  # A path straight out of the report ("Mod File:" / "File ... is not a valid
  # mod file"). The path may be from another machine or another checkout
  # (fc8's reports still carry C:\OldServerLocation\...), so match on the
  # FILE NAME against this ServerDir's mods\ rather than trusting the path.
  param([string]$PathOrName)
  $modsDir = Join-Path $ServerDir 'mods'
  if (-not $PathOrName) { return @{ resolved = $null; candidates = @() } }
  $leaf = Split-Path -Leaf ($PathOrName -replace '/', '\')
  $direct = Join-Path $modsDir $leaf
  if (Test-Path -LiteralPath $direct) { return @{ resolved = (Get-Item -LiteralPath $direct).FullName; candidates = @($direct) } }
  return @{ resolved = $null; candidates = @() }
}

function Get-NearestModFile {
  # For rules whose evidence is an exception line, the owning jar is named on a
  # nearby "Mod File:" line in the same block of the FML report. Search backwards
  # from the match, then forwards, within a bounded window.
  param([string]$Text, [int]$Offset)
  $window = 4000
  $start = [Math]::Max(0, $Offset - $window)
  $before = $Text.Substring($start, $Offset - $start)
  $m = [regex]::Matches($before, 'Mod File:\s*(?<p>\S+)')
  if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups['p'].Value }
  $end = [Math]::Min($Text.Length, $Offset + $window)
  $after = $Text.Substring($Offset, $end - $Offset)
  $m2 = [regex]::Match($after, 'Mod File:\s*(?<p>\S+)')
  if ($m2.Success) { return $m2.Groups['p'].Value }
  return ''
}

function Resolve-ConfigFile {
  param([string]$Name)
  if (-not $Name) { return @{ resolved = $null; candidates = @() } }
  $leaf = Split-Path -Leaf ($Name -replace '/', '\')
  $hits = @()
  foreach ($sub in @('config', 'defaultconfigs')) {
    $d = Join-Path $ServerDir $sub
    if (-not (Test-Path $d)) { continue }
    $hits += @(Get-ChildItem -LiteralPath $d -Recurse -Filter $leaf -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.FullName })
  }
  # Only config\ is a repair target; defaultconfigs\ is a template.
  $inConfig = @($hits | Where-Object { $_ -like (Join-Path $ServerDir 'config') + '*' })
  if ($inConfig.Count -eq 1) { return @{ resolved = $inConfig[0]; candidates = $hits } }
  return @{ resolved = $null; candidates = $hits }
}

# ---- Match ------------------------------------------------------------------

$matchesFound = New-Object System.Collections.ArrayList
$seq = 0   # Sort-Object is NOT stable on PS 5.1, so ties need an explicit tie-breaker.

foreach ($rule in ($rules | Sort-Object { [int]$_.priority })) {
  $haystacks = @()
  if ($rule.scope -eq 'report') { $haystacks = @(@{ src = 'crash-report'; text = $reportText }) }
  elseif ($rule.scope -eq 'log') { $haystacks = @(@{ src = 'latest.log'; text = $logText }) }
  else { $haystacks = @(@{ src = 'crash-report'; text = $reportText }, @{ src = 'latest.log'; text = $logText }) }

  foreach ($h in $haystacks) {
    if (-not $h.text) { continue }
    $re = [regex]::new($rule.pattern)
    $ms = $re.Matches($h.text)
    if ($ms.Count -eq 0) { continue }

    # Report EVERY distinct capture, not just the first. A single FML report
    # routinely carries eight different missing dependencies; showing one of
    # them and calling it done is exactly the "filter your findings" mistake.
    $seen = @{}
    foreach ($m in $ms) {
      $caps = [ordered]@{}
      foreach ($gname in $re.GetGroupNames()) {
        if ($gname -match '^\d+$') { continue }
        if ($m.Groups[$gname].Success) { $caps[$gname] = $m.Groups[$gname].Value }
      }
      $key = ($caps.Values -join '|')
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true

      # Resolve the repair target, if this rule has one.
      $target = $null; $candidates = @(); $unresolvedWhy = ''
      switch ($rule.target) {
        'jar' {
          $r = Resolve-ModJarByPath -PathOrName $caps['jar']
          $target = $r.resolved; $candidates = $r.candidates
          if (-not $target) { $unresolvedWhy = "no file named '" + (Split-Path -Leaf ($caps['jar'] -replace '/', '\')) + "' under mods\ (already removed?)" }
        }
        'modid' {
          $r = Resolve-ModJarByModid -Modid $caps['modid']
          $target = $r.resolved; $candidates = $r.candidates
          if (-not $target) { $unresolvedWhy = "modid '" + $caps['modid'] + "' matched " + $r.candidates.Count + " jars under mods\ (need exactly 1)" }
        }
        'modfile' {
          $p = Get-NearestModFile -Text $h.text -Offset $m.Index
          $r = Resolve-ModJarByPath -PathOrName $p
          $target = $r.resolved; $candidates = $r.candidates
          if (-not $target) { $unresolvedWhy = "could not tie the exception to a jar in mods\ (nearest 'Mod File:' = '" + $p + "')" }
        }
        'file' {
          $r = Resolve-ConfigFile -Name $caps['file']
          $target = $r.resolved; $candidates = $r.candidates
          if (-not $target) { $unresolvedWhy = "config file '" + $caps['file'] + "' not found uniquely under config\" }
        }
        default { }
      }

      # A rule that CAN be auto-fixed but whose target could not be pinned down
      # is downgraded to HALT here rather than in the repair step, so that the
      # verdict the human reads already says what it is going to do.
      $action = $rule.action
      $autoFixable = [bool]$rule.autoFixable
      if ($rule.target -and (-not $target)) {
        $action = 'HALT'
        $autoFixable = $false
      }

      $seq++
      [void]$matchesFound.Add([ordered]@{
        ruleId      = $rule.id
        priority    = [int]$rule.priority
        seq         = $seq
        title       = $rule.title
        source      = $h.src
        action      = $action
        ruleAction  = $rule.action
        autoFixable = $autoFixable
        severity    = $rule.severity
        captures    = $caps
        target      = $target
        candidates  = $candidates
        unresolved  = $unresolvedWhy
        evidenceLine = ($m.Value -replace '\s+', ' ').Trim()
        note        = $rule.note
      })
    }
  }
}

# ---- Verdict ----------------------------------------------------------------
# Primary = lowest priority number. server-hang-watchdog sits at 90 on purpose:
# in fc8 it was nearly always a follow-on to a real crash in the same second,
# so anything else that matched should win.
#
# Tie-breakers, in order:
#   1. priority
#   2. a match whose repair target RESOLVED beats one that did not. An actionable
#      identification is worth more than an unactionable one of the same kind -
#      and without this, a report naming three dist-crashing mods would pick
#      whichever one Sort-Object happened to emit first (it is not stable here).
#   3. order of appearance in the report.
$primary = $null
$primaryTargets = @()
if ($matchesFound.Count -gt 0) {
  $primary = ($matchesFound |
    Sort-Object @{ Expression = { $_.priority } },
                @{ Expression = { if ($_.target) { 0 } else { 1 } } },
                @{ Expression = { $_.seq } } |
    Select-Object -First 1)

  # One crash report can name SEVERAL instances of the same fault - fc8's
  # 2026-06-25 report dist-crashed on ToadLib AND enhanced_boss_bars in one go.
  # Quarantining only the first would just crash again on the second, so the
  # verdict carries every resolved target of the winning rule and rk-repair.ps1
  # acts on all of them in one stopped window.
  $primaryTargets = @($matchesFound |
    Where-Object { ($_.ruleId -eq $primary.ruleId) -and $_.target } |
    ForEach-Object { $_.target } |
    Select-Object -Unique)
}

# ---- The removal veto, applied HERE and not only in the repair -------------
# "Quarantine the mod that crashed" sounds like removing one thing. On the real
# pokemoncraft install, removing `create` would remove 34 (33 mods declare it
# required). rk-repair enforces this too, but the verdict has to say it as well:
# STATUS.txt, the escalation prompt and the human all read the DIAGNOSIS, and a
# verdict that promises a removal that will then be refused is a lie in the one
# file everybody looks at first.
#
# There is a second reason to do it here. A mod that cannot be pulled is exactly
# the mod most worth fixing with a Mixin or a shim - so downgrading to HALT is
# what routes it to escalation (escalateOnHalt), which is where that work starts.
$removalVeto = @()
if ($primary -and ($primary.action -eq 'QUARANTINE_MOD') -and ($primaryTargets.Count -gt 0)) {
  $game = $null
  try { $game = Find-RkGame -ServerDir $ServerDir -Templates (Get-RkGameTemplates -GamesDir $GamesDir) } catch {}
  $allowRemoval = $true
  $prof = Get-RkProfile -ServerDir $ServerDir
  if ($prof -and ($null -ne $prof.PSObject.Properties['allowModRemoval'])) { $allowRemoval = [bool]$prof.allowModRemoval }
  $idx = Get-RkModIndex -ServerDir $ServerDir -Template $game
  foreach ($t in $primaryTargets) {
    if (-not (Test-Path -LiteralPath $t)) { continue }
    $chk = Test-RkModRemovable -ServerDir $ServerDir -JarPath $t -Template $game -AllowModRemoval $allowRemoval -Index $idx
    if (-not $chk.removable) {
      $removalVeto += [ordered]@{
        jar        = (Split-Path -Leaf $t)
        modid      = $chk.modid
        reasons    = @($chk.reasons)
        dependents = @($chk.dependents)
        distributed = $chk.distributed
      }
    }
  }
  if ($removalVeto.Count -gt 0) {
    $primary.action = 'HALT'
    $primary.autoFixable = $false
    $primary.unresolved = ('removal vetoed: ' + (@($removalVeto[0].reasons) -join '; '))
  }
}

$verdict = [ordered]@{
  schema        = 'respawnkeeper/diagnosis/1'
  generatedAt   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  serverDir     = $ServerDir
  crashReport   = $(if ($report) { $report.FullName } else { '' })
  crashReportAt = $(if ($report) { $report.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
  rulesFile     = $RulesFile
  ruleCount     = $rules.Count
  matched       = ($matchesFound.Count -gt 0)
  tier          = $(if ($matchesFound.Count -gt 0) { 1 } else { 0 })
  action        = $(if ($primary) { $primary.action } else { 'ESCALATE' })
  autoFixable   = $(if ($primary) { $primary.autoFixable } else { $false })
  primary       = $primary
  targets       = $primaryTargets
  removalVeto   = @($removalVeto)
  allMatches    = @($matchesFound)
  summary       = ''
}

if ($primary) {
  $s = '[' + $primary.ruleId + '] ' + $primary.title
  if ($removalVeto.Count -gt 0) {
    $s += ' -> HALT (removing ' + (($removalVeto | ForEach-Object { $_.jar }) -join ', ') + ' was vetoed: ' + (@($removalVeto[0].reasons) -join '; ') + ')'
  } elseif ($primaryTargets.Count -gt 0) {
    $s += ' -> ' + $primary.action + ' ' + (($primaryTargets | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')
  } else {
    $s += ' -> ' + $primary.action
  }
  $verdict.summary = $s
} else {
  $verdict.summary = 'No Tier1 rule matched. This is the Tier2/Tier3 case (or there is no crash report at all).'
}

Write-RkJson -Path $OutFile -Object $verdict -Depth 10

# ---- Human summary ----------------------------------------------------------
Say ''
Say '=== respawnkeeper Tier1 diagnosis ==============================='
Say ('server      : ' + $ServerDir)
Say ('crash report: ' + $(if ($report) { $report.Name + '  (' + $report.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + ')' } else { '(none found)' }))
# Split-Path -Leaf '' THROWS ("Cannot bind argument to parameter 'Path'"), and
# an empty $RulesFile is the CORRECT state for a game whose template declares
# rules = '' - which [R-072] made the honest answer for valheim, corekeeper and
# terraria. So the one line that was meant to tell a person which table was used
# aborted the whole summary for exactly the games that most need explaining.
# Measured 2026-09-14: the diagnose button on everheim printed two lines and a
# red PowerShell binding error.
if ($RulesFile) {
  Say ('rules       : ' + $rules.Count + ' from ' + (Split-Path -Leaf $RulesFile))
} else {
  Say ('rules       : this game has no rule table, so nothing can be matched by pattern.')
  Say ('              A crash here is described, not classified - see the log tail below.')
}
Say ('matches     : ' + $matchesFound.Count)
Say ''
if ($primary) {
  Say ('VERDICT     : ' + $verdict.summary)
  Say ('auto-fixable: ' + $primary.autoFixable)
  if ($primary.unresolved) { Say ('unresolved  : ' + $primary.unresolved) }
  foreach ($v in $removalVeto) {
    Say ('REMOVAL VETO: ' + $v.jar + $(if ($v.modid) { ' (' + $v.modid + ')' } else { '' }))
    foreach ($r in @($v.reasons)) { Say ('              - ' + $r) }
    if (@($v.dependents).Count -gt 0) {
      Say ('              would also break: ' + ((@($v.dependents) | Select-Object -First 8) -join ', ') +
           $(if (@($v.dependents).Count -gt 8) { ' ... (' + @($v.dependents).Count + ' total)' } else { '' }))
    }
  }
  Say ('evidence    : ' + $primary.evidenceLine)
  Say ('why         : ' + $primary.note)
  if ($matchesFound.Count -gt 1) {
    Say ''
    Say 'all matches (nothing filtered out):'
    foreach ($mm in $matchesFound) {
      $line = '  {0,3} {1,-30} {2,-16} {3}' -f $mm.priority, $mm.ruleId, $mm.action, $mm.evidenceLine
      if ($line.Length -gt 200) { $line = $line.Substring(0, 200) + '...' }
      Say $line
    }
  }
} else {
  Say 'VERDICT     : ESCALATE - no Tier1 rule matched.'
  Say '              Tier1 is a lookup table; not matching is a normal outcome, not an error.'
}
Say ''
Say ('written     : ' + $OutFile)
Say '================================================================'

if ($matchesFound.Count -gt 0) { exit 0 }
exit 4
