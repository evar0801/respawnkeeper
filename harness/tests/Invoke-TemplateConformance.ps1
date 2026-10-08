# ============================================================
# Invoke-TemplateConformance.ps1
# Static conformance check for harness\games\*.psd1 against
# harness\lib\rk-capabilities.psd1.  ASCII only.
#
# STARTS NOTHING, STOPS NOTHING, TOUCHES NO SERVER FOLDER. It reads the
# templates, reads the capabilities contract, and parses the harness source.
# Run it on a machine with none of these games installed and you get the same
# answer.
#
# It answers five questions per template:
#   1. does it declare a combination rk-capabilities.psd1 says cannot hold?
#   2. does it set a field that NO harness code reads? (a dead field is worse
#      than a missing one - it looks configured)
#   3. do the files it points at (rules, logscan) exist?
#   4. which features can actually run, and for the ones that cannot, WHY - in
#      the words rk-capabilities.psd1 uses, so the answer is actionable
#   5. what is each claim's provenance? measured / human / inferred, with a
#      missing entry read as inferred. A feature resting on inferred claims is
#      reported as blocked, not on.
#
# This is NOT Test-RkGameTemplate (lib\rk-games.ps1). That one checks a template
# against a real folder. This one checks a template against itself and against
# the code. Keep them apart.
#
# EXIT CODES (same convention as the repo hooks)
#   0  clean
#   1  warnings only
#   2  at least one FAIL
#
# USAGE
#   powershell -File harness\tests\Invoke-TemplateConformance.ps1
#   powershell -File harness\tests\Invoke-TemplateConformance.ps1 -Template valheim
#   powershell -File harness\tests\Invoke-TemplateConformance.ps1 -GamesDir <dir>
#   powershell -File harness\tests\Invoke-TemplateConformance.ps1 -Explain
# ============================================================
[CmdletBinding()]
param(
  [string]$GamesDir = '',
  [string]$HarnessRoot = '',
  [string]$CapabilitiesFile = '',
  [string]$RulesDir = '',
  [string]$Template = '',
  [switch]$Explain,
  [switch]$Quiet,
  [string]$JsonOut = ''
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HarnessRoot)      { $HarnessRoot = Split-Path -Parent $here }
if (-not $GamesDir)         { $GamesDir = Join-Path $HarnessRoot 'games' }
if (-not $RulesDir)         { $RulesDir = Join-Path $HarnessRoot 'rules' }
if (-not $CapabilitiesFile) { $CapabilitiesFile = Join-Path $HarnessRoot 'lib\rk-capabilities.psd1' }

. (Join-Path $HarnessRoot 'lib\rk-conformance.ps1')

function Say { param([string]$m = '') if (-not $Quiet) { Write-Host $m } }
function Wrap {
  # Reason text is written to be read by a person, so it is long. Fold it under
  # an indent instead of truncating it - a truncated reason is not actionable.
  param([string]$Text, [int]$Indent = 4, [int]$Width = 96)
  $pad = ' ' * $Indent
  $out = @()
  $line = ''
  foreach ($w in ($Text -split '\s+')) {
    if (-not $w) { continue }
    if (($line.Length + $w.Length + 1) -gt $Width) { $out += ($pad + $line); $line = $w }
    else { if ($line) { $line = $line + ' ' + $w } else { $line = $w } }
  }
  if ($line) { $out += ($pad + $line) }
  return $out
}

# ---- load ------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $CapabilitiesFile)) {
  Write-Host ('[conformance] capabilities file not found: ' + $CapabilitiesFile)
  exit 2
}
$caps = Import-PowerShellDataFile -LiteralPath $CapabilitiesFile

$templates = @()
if (-not (Test-Path -LiteralPath $GamesDir)) {
  Write-Host ('[conformance] games dir not found: ' + $GamesDir)
  exit 2
}
foreach ($f in (Get-ChildItem -LiteralPath $GamesDir -Filter '*.psd1' -File | Sort-Object Name)) {
  try {
    $t = Import-PowerShellDataFile -LiteralPath $f.FullName
    $t['templateFile'] = $f.FullName
    if (-not $t.Contains('id')) { $t['id'] = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
    $templates += $t
  } catch {
    Write-Host ('[conformance] CANNOT PARSE ' + $f.Name + ': ' + $_.Exception.Message)
    $templates += @{ id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name); templateFile = $f.FullName; __parseError = $_.Exception.Message }
  }
}
if ($Template) { $templates = @($templates | Where-Object { $_.id -eq $Template }) }
if (@($templates).Count -eq 0) {
  Write-Host '[conformance] no templates to check'
  exit 2
}

# Facts about the harness itself that a requirement needs to know. Read from the
# code rather than assumed, so that ripping the pid file out breaks this check
# instead of silently making pidFileProbe a lie.
$supervisor = Join-Path $HarnessRoot 'respawnkeeper.ps1'
$pidFileName = 'respawnkeeper\server.pid'
$writesPid = $false
if (Test-Path -LiteralPath $supervisor) {
  $src = Get-Content -LiteralPath $supervisor -Raw
  $writesPid = ($src -match 'ServerPidFile' -and $src -match "Set-Content[^\r\n]*ServerPidFile")
}
$ctx = @{
  rulesDir               = $RulesDir
  harnessRoot            = $HarnessRoot
  supervisorWritesPidFile = $writesPid
  pidFileName            = $pidFileName
}

$fieldNames = @($caps.mustBeConsumed | ForEach-Object { [string]$_ })
$consumption = Get-RkConfConsumption -HarnessRoot $HarnessRoot -Fields $fieldNames

# ---- header ----------------------------------------------------------------

Say ''
Say '================================================================================'
Say ' respawnkeeper - template conformance (static; no server is started or touched)'
Say '================================================================================'
Say ('  capabilities : ' + $CapabilitiesFile)
Say ('  schema       : ' + [string]$caps.schema)
Say ('  games dir    : ' + $GamesDir)
Say ('  rules dir    : ' + $RulesDir)
Say ('  source scan  : ' + $consumption.files + ' .ps1 files under ' + $HarnessRoot + ' (tests\ and *.bak* excluded)')
Say ('  parse errors : ' + @($consumption.parseErrors).Count)
foreach ($pe in @($consumption.parseErrors)) { Say ('      ' + $pe) }
Say ('  pid file     : ' + $(if ($writesPid) { 'the supervisor writes ' + $pidFileName } else { 'NOT written by the supervisor' }))
Say ''

# Field consumption is a property of the CODE, not of any one template, so it is
# reported once, up front, with the evidence behind each verdict.
Say '--- fields the contract says must be consumed by code ---------------------------'
foreach ($n in $fieldNames) {
  $e = $consumption.fields[$n]
  $mark = '  ok  '
  if ($e.state -eq 'dead') { $mark = ' DEAD ' }
  if ($e.state -eq 'ambiguous') { $mark = ' ???  ' }
  $counts = ('bound=' + $e.bound.Count + ' unbound=' + $e.ambiguous.Count + ' literal=' + $e.literal.Count)
  Say ('  [' + $mark + '] ' + $n.PadRight(11) + ' ' + $counts)
  if ($e.state -eq 'consumed') {
    foreach ($h in (@($e.bound) | Select-Object -First 2)) { Say ('            read at ' + $h) }
  } else {
    foreach ($h in (@($e.ambiguous) | Select-Object -First 4)) { Say ('            rejected (receiver is not a template): ' + $h) }
    foreach ($h in (@($e.literal) | Select-Object -First 3)) { Say ('            bare string only: ' + $h) }
    if ($e.state -eq 'dead') { Say '            three probes came back empty: $x.name, $x[''name''], and the bare quoted name' }
  }
}
Say ''

if ($Explain) {
  Say '--- checker-side defaults (argue with these, do not guess at them) --------------'
  Say ('  launch kinds implemented : ' + ($script:RkConfLaunchKinds -join ', '))
  Say ('  stop kinds implemented   : ' + ($script:RkConfStopKinds -join ', '))
  Say ('  port protocols probed    : ' + ($script:RkConfPortProto -join ', '))
  Say '  facts about the harness itself (no template can change these):'
  foreach ($k in ($script:RkConfHarnessMeasured.Keys | Sort-Object)) {
    Say ('      ' + $k.PadRight(23) + ' measured - ' + $script:RkConfHarnessMeasured[$k])
  }
  Say '  provenance fallback (used only when the template has no provenance entry):'
  foreach ($k in ($script:RkConfVerifiedFallback.Keys | Sort-Object)) {
    Say ('      ' + $k.PadRight(23) + ' <- verified.' + $script:RkConfVerifiedFallback[$k])
  }
  Say ''
}

# ---- per template ----------------------------------------------------------

$totalFail = 0
$totalWarn = 0
$results = @()

foreach ($t in $templates) {
  Say '================================================================================'
  Say (' ' + [string]$t.id + '  -  ' + [string]$t.displayName)
  Say ('   ' + [string]$t.templateFile)
  Say '================================================================================'

  if ($t.Contains('__parseError')) {
    Say ('  FAIL  the file does not parse: ' + $t.__parseError)
    $totalFail++
    continue
  }

  $r = Invoke-RkTemplateConformance -Template $t -Caps $caps -Consumption $consumption -Ctx $ctx
  $results += $r
  $totalFail += @($r.fails).Count
  $totalWarn += @($r.warns).Count

  # 1. conflicts
  Say ''
  Say '  [1] declared combinations that cannot hold'
  $cfHits = @($r.conflicts.hits)
  if ($cfHits.Count -eq 0) {
    Say ('        none of the ' + @($caps.conflicts).Count + ' declared conflicts fire')
  } else {
    foreach ($h in $cfHits) {
      Say ('        FAIL  ' + $h.id)
      Say ('              ' + $h.detail)
      foreach ($l in (Wrap $h.why 14)) { Say $l }
    }
  }
  foreach ($u in @($r.conflicts.unimplemented)) {
    Say ('        WARN  ' + $u + ' - declared in the contract but the checker has no rule for it')
  }

  # 2/3. fields
  Say ''
  Say '  [2] fields this template sets, and whether code reads them'
  $any = $false
  foreach ($f in @($r.fields)) {
    if ($f.severity -eq 'ok') { continue }
    $any = $true
    Say ('        ' + $f.severity + '  ' + $f.id + ' - ' + $f.detail)
  }
  if (-not $any) { Say '        every field this template sets is read by code' }

  Say ''
  Say '  [3] files this template points at'
  if (@($r.refs).Count -eq 0) { Say '        it points at no rule tables' }
  foreach ($f in @($r.refs)) {
    if ($f.severity -eq 'ok') { Say ('        ok    ' + $f.detail) }
    else { Say ('        ' + $f.severity + '  ' + $f.detail) }
  }

  # 4. requirements + features
  Say ''
  Say '  [4] requirements'
  foreach ($k in (@($r.reqs.Keys) | Sort-Object)) {
    $q = $r.reqs[$k]
    $mark = 'unmet'
    if ($q.met -eq $true) { $mark = ' MET ' }
    if ($null -eq $q.met) { $mark = ' ??? ' }
    # Provenance on an UNMET requirement would be noise at best and misleading
    # at worst ("human" next to a field that is not set reads as reassurance).
    $prov = 'n/a'
    if ($q.met -eq $true) { $prov = $q.provLevel }
    Say ('        [' + $mark + '] ' + $k.PadRight(23) + ' prov=' + $prov.PadRight(10) + $q.detail)
  }

  Say ''
  Say '  [5] features - what this game can and cannot have'
  Say '        FEATURE             STATUS              WHY'
  Say '        ------------------- ------------------- ----------------------------------------'
  foreach ($ft in @($r.features)) {
    Say ('        ' + $ft.name.PadRight(19) + ' ' + $ft.status.PadRight(19) + ' ' + $ft.label)
    if ($ft.status -eq 'on') { continue }
    if ($ft.status -eq 'blocked:provenance') {
      Say ('            cannot be switched on yet: ' + (@($ft.inferred) -join ', ') + ' rest on inferred claims')
      foreach ($n in @($ft.inferred)) {
        if ($r.reqs.ContainsKey($n)) {
          Say ('            - ' + $n + ': ' + $r.reqs[$n].provWhere)
        }
      }
      continue
    }
    foreach ($n in @($ft.unmet)) {
      $key = ($n -replace ' \(feature\)$', '') -replace ' \(unknown requirement\)$', ''
      if ($r.reqs.ContainsKey($key)) {
        Say ('            - ' + $key + ': ' + $r.reqs[$key].detail)
        foreach ($l in (Wrap ('=> ' + $r.reqs[$key].why) 14)) { Say $l }
      } else {
        Say ('            - ' + $n)
      }
    }
  }
  foreach ($ft in @($r.features)) {
    if (@($ft.wantsUnmet).Count -gt 0 -and $ft.status -ne 'off') {
      Say ('        note: ' + $ft.name + ' runs with less than it wants (missing: ' + (@($ft.wantsUnmet) -join ', ') + ')')
    }
  }

  $f = @($r.fails).Count
  $w = @($r.warns).Count
  Say ''
  Say ('  == ' + [string]$t.id + ': FAIL ' + $f + ' / WARN ' + $w + ' ==')
  Say ''
}

# ---- summary ---------------------------------------------------------------

Say '================================================================================'
Say ' SUMMARY'
Say '================================================================================'
Say ('  ' + 'template'.PadRight(14) + 'FAIL  WARN   features on / blocked / off')
foreach ($r in $results) {
  $on = @($r.features | Where-Object { $_.status -eq 'on' }).Count
  $bl = @($r.features | Where-Object { $_.status -eq 'blocked:provenance' }).Count
  $of = @($r.features | Where-Object { $_.status -ne 'on' -and $_.status -ne 'blocked:provenance' }).Count
  Say ('  ' + $r.id.PadRight(14) + (@($r.fails).Count.ToString()).PadRight(6) + (@($r.warns).Count.ToString()).PadRight(7) + $on + ' / ' + $bl + ' / ' + $of)
}
Say ''
Say ('  TOTAL  FAIL ' + $totalFail + '  WARN ' + $totalWarn)
Say ''
Say '  A feature row is a capability report, not a defect: "off" can be the correct'
Say '  answer for a game. The exit code scores defects only - conflicts, dead fields,'
Say '  files that are pointed at but absent, and safetyGate being structurally off.'
Say ''

if ($JsonOut) {
  $results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonOut -Encoding ascii
  Say ('  json -> ' + $JsonOut)
}

if ($totalFail -gt 0) { exit 2 }
if ($totalWarn -gt 0) { exit 1 }
exit 0
