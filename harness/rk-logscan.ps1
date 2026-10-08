# ============================================================
# rk-logscan.ps1 - the daily static read of the logs
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# WHAT THIS IS FOR. Crashes announce themselves. The problems that do not - a
# data file that silently failed to parse, a script calling an API that was
# removed two updates ago, "Can't keep up!" on 64% of days - just accumulate in
# the log until somebody happens to look. This looks, once a day, and writes
# down what it saw.
#
# WHAT THIS IS NOT FOR. It fixes nothing and changes nothing. It is READ ONLY
# except for the report it writes into <ServerDir>\respawnkeeper\reports\.
# The output is meant to be read by a human who is awake and has time - which
# is the opposite end of the day from the crash path.
#
# NO MODEL IS INVOLVED. Same reasoning as the Tier1 crash table [R-006]:
# counting and grouping is arithmetic, and paying a model to do arithmetic every
# morning is how a good idea turns into a standing bill. The rules in
# rules\logscan-rules.psd1 only decide where in the report something is printed.
#
# Usage:
#   powershell -File rk-logscan.ps1 -ServerDir <dir>
#   powershell -File rk-logscan.ps1 -ServerDir <dir> -SinceHours 48
# ============================================================

param(
  [Parameter(Mandatory)][string]$ServerDir,
  [int]$SinceHours = 0,        # 0 = since the last report, else last 24h
  [string]$OutFile = '',
  [int]$TopUnknown = 25,
  [int]$MaxSampleChars = 220,
  [string]$GamesDir = '',      # see rk-diagnose.ps1; same reason
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\rk-common.ps1')
# The half of the report a person reads. Loaded here rather than inlined
# because counting what happened and counting WARN lines are separate jobs -
# see the header of rk-highlights.ps1.
. (Join-Path $PSScriptRoot 'lib\rk-highlights.ps1')
. (Join-Path $PSScriptRoot 'lib\rk-humanreport.ps1')

$ServerDir = Resolve-RkServerDir -Path $ServerDir -AnyFolder -GamesDir $GamesDir
$StateDir  = Get-RkStateDir -ServerDir $ServerDir
$ReportDir = Join-Path $StateDir 'reports'
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null }
if (-not $OutFile) { $OutFile = Join-Path $ReportDir ('daily-' + (Get-Date -Format 'yyyyMMdd') + '.md') }

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

$Game = Find-RkGame -ServerDir $ServerDir -Templates (Get-RkGameTemplates -GamesDir $GamesDir)

# ---- Window ----------------------------------------------------------------
$since = (Get-Date).AddHours(-24)
if ($SinceHours -gt 0) { $since = (Get-Date).AddHours(-$SinceHours) }
else {
  $prev = @(Get-ChildItem -LiteralPath $ReportDir -Filter 'daily-*.md' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $OutFile } | Sort-Object LastWriteTime)
  if ($prev.Count -gt 0) { $since = $prev[-1].LastWriteTime }
}

# ---- Which files to read ---------------------------------------------------
$sources = New-Object System.Collections.ArrayList
$namedLog = ''
if ($Game -and $Game.paths.logFile) { $namedLog = Split-Path -Leaf ([string]$Game.paths.logFile) }

function Add-Source([string]$path) {
  if (-not $path) { return }
  if (-not (Test-Path -LiteralPath $path)) { return }
  $it = Get-Item -LiteralPath $path
  if ($it.PSIsContainer) { return }
  if ($it.LastWriteTime -lt $since) { return }
  # IMPORTANT: debug.log IS latest.log, PLUS the DEBUG lines. Forge/NeoForge write both,
  # so reading both counts every join, every death and every WARN exactly
  # twice. Measured on pokemoncraft: one player came out with fifteen sessions,
  # of which the last three were the first three again.
  # Skipped unless the game template names it as THE log, in which case there
  # is no second copy to duplicate.
  if (($it.Name -match '^debug(-\d+)?\.log(\.gz)?$') -and ($it.Name -ne $namedLog)) { return }
  [void]$sources.Add($it)
}

if ($Game -and $Game.paths.logFile) { Add-Source (Join-Path $ServerDir $Game.paths.logFile) }
foreach ($d in @(($Game.paths.logDir), 'logs')) {
  if (-not $d) { continue }
  $dir = Join-Path $ServerDir $d
  if (-not (Test-Path $dir)) { continue }
  foreach ($f in (Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -match '^\.(log|txt|gz)$' })) { Add-Source $f.FullName }
}
# The console respawnkeeper captured itself, for games that write no log at all.
$consoleDir = Join-Path $StateDir 'console'
if (Test-Path $consoleDir) {
  foreach ($f in (Get-ChildItem -LiteralPath $consoleDir -File -Filter '*.log' -ErrorAction SilentlyContinue)) { Add-Source $f.FullName }
}
$sources = @($sources | Sort-Object FullName -Unique)

function ConvertFrom-LogBytes([byte[]]$bytes) {
  # Encoding has to be DETECTED, not assumed. Neither guess is safe on its own:
  #   - assume ANSI  -> UTF-8 logs turn to mojibake
  #   - assume UTF-8 -> logs written in the system codepage turn to mojibake
  # fc8's Forge logs are the second kind: log4j writes with the PLATFORM DEFAULT
  # charset, so on this machine (codepage 932) its Japanese KubeJS messages are
  # Shift-JIS. Confirmed at byte level: 8c8e and 8354 815b 836f 815b are CP932 kanji/katakana, not UTF-8.
  # The test is decisive: decode as UTF-8 and look for U+FFFD. Valid UTF-8 never
  # produces one; a mis-decode almost always does.
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($text.IndexOf([char]0xFFFD) -ge 0) { $text = [System.Text.Encoding]::Default.GetString($bytes) }
  # A BOM survives the decode as U+FEFF and glues itself to the first line, which
  # then normalises to a DIFFERENT signature than every identical line after it.
  # PowerShell's own Set-Content -Encoding UTF8 writes one, so this is not a
  # hypothetical: the self-test caught it by writing its fixture that way.
  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
  return $text
}

# Files the scan could not read. NOT the same as files that were empty, and the
# whole point of keeping them apart is that the report must never present the
# second as if it were the first.
$script:RkUnreadable = New-Object System.Collections.ArrayList

function Read-LogBytesShared($path) {
  # 🔴 FileShare.ReadWrite, and it matters.
  # [System.IO.File]::ReadAllBytes opens with FileShare.Read, which means "other
  # handles may read but not write". The launcher's own '>' redirect is holding
  # this file open FOR WRITING the whole time the server is up, so that open
  # fails with a sharing violation on every live server.
  # Measured 2026-09-15 on the Everheim instance: a 67,009-byte log with 778
  # lines was reported as "files: 1  lines: 0  complaints: 0" while the server
  # was running. Get-Content had read the same file a minute earlier, because
  # Get-Content asks for FileShare.ReadWrite.
  # The old code then swallowed the exception and returned an empty array, so
  # "I could not open this" and "this was a quiet day" printed identically.
  $fs = New-Object System.IO.FileStream($path,
        [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $ms = New-Object System.IO.MemoryStream
    $fs.CopyTo($ms)
    $b = $ms.ToArray()
    $ms.Close()
    return $b
  } finally { $fs.Close() }
}

function Read-LogLines($file) {
  # Minecraft rotates yesterday's log into a .gz, so a day's evidence is split
  # across plain and compressed files. Both go through the SAME decode: getting
  # this right for plain files only was the first version of this bug - 246 of
  # fc8's 274 log files are .gz, so the report was still full of mojibake.
  if ($file.Extension -eq '.gz') {
    try {
      $raw = Read-LogBytesShared $file.FullName
      $ms0 = New-Object System.IO.MemoryStream(,$raw)
      $gz = New-Object System.IO.Compression.GZipStream($ms0, [System.IO.Compression.CompressionMode]::Decompress)
      $ms = New-Object System.IO.MemoryStream
      $gz.CopyTo($ms)
      $gz.Close(); $ms0.Close()
      $text = ConvertFrom-LogBytes $ms.ToArray()
      $ms.Close()
      return $text -split "`r?`n"
    } catch {
      [void]$script:RkUnreadable.Add(@{ name = $file.Name; why = $_.Exception.Message })
      return @()
    }
  }
  try {
    return ((ConvertFrom-LogBytes (Read-LogBytesShared $file.FullName)) -split "`r?`n")
  } catch {
    # 🔴 Record it. An unreadable file that returns silently is a file the
    # report will describe as quiet.
    [void]$script:RkUnreadable.Add(@{ name = $file.Name; why = $_.Exception.Message })
    return @()
  }
}

# ---- Normalising a line into a signature -----------------------------------
function Get-Signature([string]$line) {
  # Strip everything that makes two occurrences of the same problem look
  # different: timestamps, thread names, coordinates, ids, paths, numbers.
  # What is left is the shape of the message, which is what we count.
  $s = $line
  # A leading [...] that contains a clock time is a timestamp, whatever else is
  # in it. fc8's Forge logs use a LOCALISED date (a localised month name sits where a number would be),
  # so matching on a fixed date shape does not work - matching on the time does.
  $s = $s -replace '^\[[^\]]*\d{1,2}:\d{2}:\d{2}[^\]]*\]\s*', ''
  $s = $s -replace '^\[?\d{2}:\d{2}:\d{2}\]?\s*', ''
  $s = $s -replace '\[[^\]]*(thread|Thread|Server|Worker|main)[^\]]*\]', '[T]'
  $s = $s -replace '[A-Za-z]:[\\/][^\s"'']+', '<path>'
  $s = $s -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<uuid>'
  $s = $s -replace '0x[0-9a-fA-F]+', '<hex>'
  $s = $s -replace '-?\d+\.\d+', '<f>'
  $s = $s -replace '\d+', '<n>'
  # Quoted content is almost always the VARIABLE part of an otherwise identical
  # message ("Ignoring unknown attribute 'x'"), so it has to collapse too or
  # every occurrence looks like a different problem. Measured on fc8's 274 real
  # log files: without this, 2.75M lines produced 37,198 distinct signatures -
  # a "report" nobody could read. It is the difference between a summary and a
  # second copy of the log.
  $s = $s -replace "'[^']*'", '<q>'
  $s = $s -replace '"[^"]*"', '<q>'
  $s = $s -replace '\s+', ' '
  $s = $s.Trim()
  # Long tails carry the rest of the variability (stack frames, file paths,
  # script excerpts). The head of the message is what identifies it.
  if ($s.Length -gt 150) { $s = $s.Substring(0, 150) }
  return $s
}

function Remove-Secrets([string]$line) {
  # Reports live on disk and get read later; game configs are full of
  # credentials (Valheim writes the server password straight into its start
  # script, Palworld keeps AdminPassword in its ini). Nothing that looks like
  # one survives into a report.
  $s = $line
  $s = $s -replace '(?i)(password|passwd|pass|adminpassword|token|secret|apikey|api_key)\s*[:=]\s*\S+', '$1=<redacted>'
  $s = $s -replace '(?i)(Authorization:\s*)\S+', '$1<redacted>'
  $s = $s -replace '\b(\d{1,3}\.){3}\d{1,3}\b', '<ip>'
  return $s
}

# ---- Scan -------------------------------------------------------------------
# 2026-09-12 ([R-072]): the template's 'logscan' field was read by nothing, so it
# could name a file that does not exist and nobody would find out - minecraft.psd1
# pointed at rules\logscan-minecraft.psd1 for weeks and that file has never
# existed. It is consumed now, and a name that does not resolve is an error
# rather than a silent fallback.
$rulesFile = ''
if ($Game -and $Game.logscan) {
  $rulesFile = Join-Path $PSScriptRoot (Join-Path 'rules' ([string]$Game.logscan))
  if (-not (Test-Path -LiteralPath $rulesFile)) {
    throw ("logscan rules named by the " + $Game.id + " template do not exist: " + $rulesFile)
  }
} else {
  # These rules only decide WHERE in the report a line is printed; they are not
  # game specific, so every game gets them when it names nothing of its own.
  $rulesFile = Join-Path $PSScriptRoot 'rules\logscan-rules.psd1'
}
$rules = @()
if (Test-Path $rulesFile) { $rules = @((Import-PowerShellDataFile -LiteralPath $rulesFile).rules) }

$sig = @{}
$totalLines = 0
$totalHits  = 0
# WHICH LINES COUNT AS A COMPLAINT. Per game since 2026-09-15, and the reason
# is the same disease as [R-071] one level up.
#
# This used to be the constant below, unconditionally. It is log4j's vocabulary
# and it is correct for Minecraft, which tags every line [WARN] or [ERROR]. A
# Valheim dedicated server tags NOTHING - what the launcher redirects is raw
# stdout - so the constant matched 0 of 1,613 lines across the six real
# Everheim logs, and the report said "WARN/ERROR: 0" for a set of logs holding
# 239 lines that say, in the game's own words, that something failed.
#
# Zero matches of a pattern the game never emits reads exactly like a healthy
# server. So the template supplies its own vocabulary and the constant is only
# the fallback for a game that has not been looked at yet.
$reLevel = '\b(WARN|WARNING|ERROR|SEVERE|FATAL|CRITICAL)\b'
$reLevelFrom = 'the default (log4j severity tags)'
if ($Game -and $Game.evidence -and $Game.evidence.level) {
  $reLevel = [string]$Game.evidence.level
  $reLevelFrom = ('games\' + [string]$Game.id + '.psd1 evidence.level')
}

# Every line, kept PER FILE, because the human half needs the ones that are
# NOT WARN/ERROR - a player joining, a quest finished and a death are all INFO -
# and it needs to know which file each came from. A log line carries a
# LOCALISED month name, so the only reliable date is the file's.
# The window filter above keeps this bounded: only files touched since the
# last report are read at all.
$scanSources = New-Object System.Collections.ArrayList

# IMPORTANT: ORDER BY mtime, NOT BY NAME. Measured on pokemoncraft 2026-09-14:
#   2026-09-13-1.log.gz  mtime 09-14 00:00  contains 20:26 -> 23:59
#   2026-09-13-2.log.gz  mtime 09-13 20:26  contains 00:00 -> 07:24
# The '-2' file is EARLIER than the '-1' file. log4j numbers an archive when it
# rotates, and a restart at 20:26 rotates the morning's log after the numbering
# for that date has already been used. Sorting by name ran the timeline
# backwards and produced a session of MINUS 1,254 minutes.
# An archive's mtime is the moment it was closed, which is always after its own
# last line, so mtime does order the CONTENT correctly.
$sources = @($sources | Sort-Object LastWriteTime, Name)

foreach ($f in $sources) {
  $fileLines = New-Object System.Collections.ArrayList
  foreach ($line in (Read-LogLines $f)) {
    if (-not $line) { continue }
    [void]$fileLines.Add($line)
    $totalLines++
    # -cnotmatch, case SENSITIVE: log levels are uppercase by convention, and a
    # case-insensitive test counts any line with the word 'warning' or 'error'
    # in ordinary prose. The self-test caught this on the line
    # 'this line is not a warning and must not be counted'.
    if ($line -cnotmatch $reLevel) { continue }
    $totalHits++
    $k = Get-Signature $line
    if (-not $k) { continue }
    if (-not $sig.ContainsKey($k)) {
      $sig[$k] = @{ count = 0; sample = (Remove-Secrets $line).Trim(); files = @{} }
    }
    $sig[$k].count++
    $sig[$k].files[$f.Name] = $true
  }
  # No date: the reader places files by order plus their own clocks, because
  # both dates a log file carries have been measured to be wrong.
  [void]$scanSources.Add(@{ name = $f.Name; lines = @($fileLines.ToArray()) })
}

# ---- Classify ---------------------------------------------------------------
$rows = New-Object System.Collections.ArrayList
foreach ($k in $sig.Keys) {
  $entry = $sig[$k]
  $cls = 'unknown'; $title = ''; $note = ''; $ruleId = ''
  foreach ($r in $rules) {
    if ($entry.sample -match $r.pattern) { $cls = $r.class; $title = $r.title; $note = $r.note; $ruleId = $r.id; break }
  }
  $sample = $entry.sample
  if ($sample.Length -gt $MaxSampleChars) { $sample = $sample.Substring(0, $MaxSampleChars) + ' ...' }
  [void]$rows.Add([ordered]@{
    signature = $k
    count     = $entry.count
    class     = $cls
    ruleId    = $ruleId
    title     = $title
    note      = $note
    sample    = $sample
    files     = @($entry.files.Keys)
  })
}
$rows = @($rows | Sort-Object @{Expression={$_.count};Descending=$true})

$chronic = @($rows | Where-Object { $_.class -eq 'chronic' })
$notable = @($rows | Where-Object { $_.class -eq 'notable' })
$unknown = @($rows | Where-Object { $_.class -eq 'unknown' })
$benign  = @($rows | Where-Object { $_.class -eq 'benign' })

# ---- Report -----------------------------------------------------------------
# Japanese wording lives in rules\logscan-report.ja.json, NOT here: PS 5.1 reads
# a BOM-less .ps1 as ANSI, so non-ASCII in this file breaks the parser outright
# (learned the hard way while writing this very script - see
# the project notes (powershell51-gotchas)). -Encoding UTF8 makes the decode explicit.
$strFile = Join-Path $PSScriptRoot 'rules\logscan-report.ja.json'
$S = $null
try { $S = Get-Content -LiteralPath $strFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
if (-not $S) { throw ("report string table missing or unreadable: " + $strFile) }

function Esc([string]$s) { return ($s -replace '\|', '\|') }
function F { param([string]$fmt) $rest = @($args); return [string]::Format($fmt, $rest) }

$sb = New-Object System.Text.StringBuilder
function W([string]$s) { [void]$sb.AppendLine($s) }
function WL($lines) { foreach ($l in @($lines)) { [void]$sb.AppendLine([string]$l) } }

# ---- the half a person reads, FIRST -----------------------------------------
# Order is the point. Eva, on the previous draft: the report opened with the
# signature count and the methodology, and she had to scroll past both to find
# out whether anybody had played. The conclusion goes at the top, the workings
# go at the bottom, and the WARN tables are workings.
$humanStr = $null
$causeTbl = $null
try { $humanStr = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'rules\report-human.ja.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
try { $causeTbl = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'rules\death-causes.ja.json')  -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
if (-not $humanStr) { throw ("human report string table missing or unreadable: " + (Join-Path $PSScriptRoot 'rules\report-human.ja.json')) }

# The chronic rows, already classified, handed over as one topic each rather
# than recomputed. A cause of death table has no opinion about log4j.
$topics = @()
foreach ($r in $chronic) { $topics += @{ title = [string]$r.title; count = [int]$r.count } }

# The name Eva gave this server, not the folder it happens to sit in. A card
# titled "server" is what "pokemoncraft\server" produces on its own.
$rkLabel = Split-Path -Leaf $ServerDir
try {
  $prof = Get-Content -LiteralPath (Join-Path $StateDir 'profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($prof -and $prof.serverLabel) { $rkLabel = [string]$prof.serverLabel }
} catch {}

# The window, dated. A scan that covers three days must not be headed with one.
$nowT = Get-Date
$dayLabel = $(if ($since.Date -eq $nowT.Date) { $nowT.ToString('yyyy-MM-dd') }
              else { $since.ToString('yyyy-MM-dd') + '-' + $nowT.ToString('yyyy-MM-dd') })
$windowText = $since.ToString('yyyy-MM-dd HH:mm') + ' - ' + $nowT.ToString('yyyy-MM-dd HH:mm')

# WHICH SENTENCES MEAN WHAT, for THIS game. Named by the template if it says
# so, otherwise by convention. A game with no table gets an EMPTY one, not
# Minecraft's: running one game's patterns over another's log invents events
# rather than finding none, and a false player is worse than no player.
$evName = ''
if ($Game -and $Game.events) { $evName = [string]$Game.events }
elseif ($Game -and $Game.id) { $evName = 'events-' + [string]$Game.id + '.psd1' }
$evTable = $null
if ($evName) {
  $evPath = Join-Path $PSScriptRoot (Join-Path 'rules' $evName)
  if (Test-Path -LiteralPath $evPath) { $evTable = Import-PowerShellDataFile -LiteralPath $evPath }
  elseif ($Game.events) { throw ("event table named by the " + $Game.id + " template does not exist: " + $evPath) }
}
if (-not $evTable) {
  $evTable = @{
    schema = 'respawnkeeper/events/1'
    game = $(if ($Game) { [string]$Game.id } else { '' })
    boot = ''; rosterFrom = @(); notPlayer = ''; rules = @()
    deathVerbs = @(); idleCauses = @(); nameShape = ''
    cannotAnswer = @('name', 'death', 'chat', 'achievement')
  }
}

# THE SUPERVISOR'S OWN RECORD. watchdog.log is not in logDir and was read by
# nothing, so the report could not say the server had gone down - the loudest
# fact of the day. Its timestamps are absolute and unlocalised (respawnkeeper
# writes them), so unlike the game's log this one can simply be filtered by
# date. Every field is a count of lines that were actually there; a missing
# file leaves $wdFacts null and the section disappears rather than reading 0.
$wdFacts = $null
$wdPath = Join-Path $StateDir 'watchdog.log'
if (Test-Path -LiteralPath $wdPath) {
  $starts = 0; $exits = 0; $dirty = 0; $halts = 0; $upMin = 0.0
  # A COUNT OVER A WINDOW HIDES WHETHER IT IS STILL HAPPENING. Valheim came
  # out as '3 unclean stops out of 8', all three of which were the morning
  # before the log path was fixed - and every stop since has been clean.
  # Same number, opposite meaning.
  $lastDirty = $null; $cleanSince = 0
  try {
    foreach ($wl in [System.IO.File]::ReadAllLines($wdPath)) {
      if ($wl -notmatch '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') { continue }
      # SEEDED WITH A REAL DATE, not $null. PowerShell cannot pick the
      # TryParse overload for [ref]$null and THROWS "no overload with 2
      # arguments" - which the catch below then swallowed, so this whole block
      # produced nothing and looked exactly like a server that never restarted.
      $ts = [datetime]::MinValue
      if (-not [datetime]::TryParse($Matches[1], [ref]$ts)) { continue }
      if ($ts -lt $since) { continue }
      if ($wl -match 'started:') { $starts++ }
      if ($wl -match 'server exited\. code=(-?\d+) uptime=([0-9.]+)min') {
        $exits++
        $u = 0.0; [void][double]::TryParse($Matches[2], [ref]$u); $upMin += $u
      }
      # 'verdict=clean' is the supervisor's own three-evidence test [R-018].
      # Anything else it wrote is a stop it could NOT call clean.
      if ($wl -match 'shutdown evidence: verdict=(\w+)') {
        if ($Matches[1] -ne 'clean') { $dirty++; $lastDirty = $ts; $cleanSince = 0 }
        else { $cleanSince++ }
      }
      if ($wl -match 'HALT') { $halts++ }
    }
    $wdFacts = @{ starts = $starts; exits = $exits; dirty = $dirty; halts = $halts
                  upMinutes = $upMin; lastDirty = $lastDirty; cleanSince = $cleanSince }
  } catch {
    # Say it. A silent null here is indistinguishable from "the server never
    # went down", which is the single most misleading thing this report could
    # imply - and it is exactly what happened while the line above was wrong.
    $wdFacts = $null
    Say ('watchdog.log could not be read, so the report says nothing about restarts: ' + $_.Exception.Message)
  }
}

$hl = Get-RkHighlights -Sources @($scanSources.ToArray()) -Events $evTable
W (Get-RkHumanReport -Highlights $hl -S $humanStr -Causes $causeTbl `
     -Label $rkLabel -Day $dayLabel -WindowText $windowText `
     -FileCount $sources.Count -Problems $topics -Watchdog $wdFacts -UnknownCount $unknown.Count)

# ---- the machine half, below ------------------------------------------------
WL $S.h_machine
W ''
# The ruler and the table are named IN the report, not just on the console.
# The report is the thing that gets read a week later, and "0 complaints" in it
# is only trustworthy if the reader can see what was being counted.
$rulesBase = ''
if ($rulesFile) { $rulesBase = [System.IO.Path]::GetFileName($rulesFile) }
W (F $S.machine_lead (Get-Date -Format 'yyyy-MM-dd HH:mm') $reLevelFrom $rulesBase)
W ''
WL $S.intro
W ''
W $S.h_conclusion
W ''
if ($chronic.Count -gt 0) { W (F $S.c_chronic $chronic.Count) } else { W $S.c_nochronic }
W (F $S.c_unknown $unknown.Count)
W (F $S.c_benign  $benign.Count)
W ''
W $S.h_numbers
W ''
W $S.n_header
W '|---|---|'
W (F $S.n_window ($since.ToString('yyyy-MM-dd HH:mm')))
W (F $S.n_files  $sources.Count)
W (F $S.n_lines  $totalLines)
W (F $S.n_hits   $totalHits)
W (F $S.n_sigs   $rows.Count)
W (F $S.n_game   $(if ($Game) { $Game.id } else { $S.n_unknown_game }))
W ''

if (($chronic.Count -gt 0) -or ($unknown.Count -gt 0)) {
  W $S.h_think
  W ''
  foreach ($r in $chronic) {
    W (F $S.t_item $r.count $r.title $r.ruleId)
    W ''
    W '```'; W $r.sample; W '```'
    W ''
    W (F $S.t_why $r.note)
    W ''
  }
  if ($unknown.Count -gt 0) {
    W (F $S.h_unclassified $unknown.Count ([Math]::Min($TopUnknown, $unknown.Count)))
    W ''
    WL $S.u_lead
    W ''
    W $S.u_header
    W '|---:|---|---|'
    foreach ($r in ($unknown | Select-Object -First $TopUnknown)) {
      W ('| ' + $r.count + ' | ' + (Esc (@($r.files) -join ', ')) + ' | ' + (Esc $r.sample) + ' |')
    }
    W ''
  }
}

if ($notable.Count -gt 0) {
  W $S.h_notable
  W ''
  W $S.no_header
  W '|---:|---|---|'
  foreach ($r in $notable) { W ('| ' + $r.count + ' | ' + (Esc $r.title) + ' | ' + (Esc $r.note) + ' |') }
  W ''
}

if ($benign.Count -gt 0) {
  $benignTotal = 0
  foreach ($r in $benign) { $benignTotal += $r.count }
  W $S.h_benign
  W ''
  W (F $S.b_total $benignTotal $benign.Count $rulesBase)
  W ''
  W $S.b_header
  W '|---:|---|'
  foreach ($r in $benign) { W ('| ' + $r.count + ' | ' + (Esc $r.title) + ' |') }
  W ''
}

W $S.h_limits
W ''
WL $S.limits
W ''

[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Say ''
Say '=== respawnkeeper daily log scan ==============================='
Say ('server    : ' + $ServerDir)
Say ('window    : since ' + $since.ToString('yyyy-MM-dd HH:mm'))
Say ('files     : ' + $sources.Count + '   lines: ' + $totalLines + '   complaints: ' + $totalHits)
# ALWAYS say which ruler was used, and say it loudest when the answer is zero.
# A count of 0 has two completely different meanings - "the server had a quiet
# day" and "this pattern does not belong to this game" - and they are
# indistinguishable from the number alone. Naming the ruler is what separates
# them, so it is printed next to the count rather than in a footnote.
Say ('            counted with: ' + $reLevelFrom)
# 🔴 Loudest of all. A file that could not be opened contributed zero lines, and
# zero lines look exactly like a quiet file. Say which ones, and why.
if ($script:RkUnreadable.Count -gt 0) {
  Say ('            !! ' + $script:RkUnreadable.Count + ' FILE(S) COULD NOT BE READ - their contents are NOT in the numbers above:')
  foreach ($u in $script:RkUnreadable) { Say ('               ' + $u.name + '  -  ' + $u.why) }
}
if ($totalHits -eq 0 -and $totalLines -gt 0) {
  Say ('            NOTE: zero complaints in ' + $totalLines + ' lines. Before reading that as a quiet day,')
  Say ('                  check that this ruler matches how THIS game words trouble.')
}
Say ('signatures: ' + $rows.Count + '  (chronic ' + $chronic.Count + ' / notable ' + $notable.Count + ' / unknown ' + $unknown.Count + ' / benign ' + $benign.Count + ')')
Say ('report    : ' + $OutFile)
Say '================================================================'
exit 0
