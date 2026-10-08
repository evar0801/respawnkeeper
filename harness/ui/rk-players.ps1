# ============================================================
# rk-players.ps1 - who is on the server right now.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS IS NOT A ONE-LINE GREP OF latest.log. Log4j rolls the file at
# midnight, so latest.log holds TODAY only. A player who logged in at 22:00 and
# is still playing at 01:00 has their "joined the game" line in yesterday's
# .log.gz - fold only latest.log and that player is invisible, or worse, their
# eventual "left the game" takes the count negative. Measured on pokemoncraft
# 2026-09-07: latest.log had 0 joins and 2 leaves.
#
# So the fold starts where the SERVER started, not where the file started:
#   server.pid -> process StartTime -> every log written at or after it,
#   oldest first, .log.gz included, then the current log.
# A "Done (" line inside that range clears the set: that is a restart, and
# nobody carries over one.
#
# After the first fold it is incremental - the console window feeds it the same
# lines it is already reading, so watching the roster costs nothing extra.
#
# IT NEVER TALKS TO THE SERVER. No RCON, no `list`, no stdin. Reading a file
# cannot lag a tick or need a port opened, and this window is not worth either.
#
# ---- WHAT CHANGED 2026-09-12 ([R-071] / [R-072]) ---------------------------
# The join and leave patterns below are Minecraft's, and the file they were read
# out of was hardcoded to logs\latest.log. On any game that does not write that
# file - which is MOST of them - the fold read nothing, matched nothing, and the
# window said "nobody is here". Not "I cannot tell": nobody. A quiet evening and
# a blind roster looked exactly alike, and the blind one looked calmer.
#
# lib\rk-capabilities.psd1 names this, feature 'playerRoster', onUnmet = 'off',
# note: "Off must render as 'not available for this game', never as an empty
# roster. An empty roster reads as 'nobody is playing'." So the roster now
# carries Available/Reason, every caller must read them, and an unavailable
# roster refuses to accumulate names at all rather than half-counting.
# ============================================================

# Shared evidence plumbing (Get-RkUiLogSource / Get-RkUiTemplate /
# Get-RkCapabilityWhy) lives in rk-vitals.ps1. Loaded here only if it is not
# already in scope, so this file stays dot-sourceable on its own and
# rk-console.ps1 (which loads both) pays for it once.
if (-not (Get-Command Get-RkUiLogSource -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'rk-vitals.ps1')
}

# Minecraft usernames are 3-16 of [A-Za-z0-9_]. Anchoring on "]: " immediately
# before the name is what separates a real event from a player TYPING
# "bob joined the game" in chat - chat renders as "]: <sender> text", so the
# character after "]: " is "<" and this pattern does not match it.
#
# These are the BUILT-IN Minecraft patterns. They are evidence in their own
# right - measured against pokemoncraft's real logs, 2026-09-07 - and they are
# used when the resolved template is Minecraft and declares no patterns of its
# own. For every other game the patterns must come from the template; guessing
# them is what produced a Valheim roster that could only ever read zero.
$script:RkJoinRe  = [regex]'\]:\s([A-Za-z0-9_]{1,16})\sjoined the game\s*$'
$script:RkLeftRe  = [regex]'\]:\s([A-Za-z0-9_]{1,16})\sleft the game\s*$'
# Both spellings appear across versions; "Done (" is the vanilla ready line.
$script:RkBootRe  = [regex]'Done \(|Starting minecraft server version'

function New-RkRoster {
  # An ordered set: who is on, in the order they arrived. A hashtable alone
  # would lose that, and "who came back first" is the thing a person reads.
  return [pscustomobject]@{
    Names   = New-Object System.Collections.ArrayList
    Since   = @{}          # name -> DateTime the join line was seen
    Folded  = $false       # has the initial history pass run
    Source  = ''           # what the fold read, for the window to be honest about

    # ---- can this game's roster be read at all? ---------------------------
    # Available starts true so a roster used without Initialize-RkRoster keeps
    # the old Minecraft behaviour. Initialize-RkRoster decides it for real.
    Available = $true
    Reason    = ''         # requirement id from lib\rk-capabilities.psd1
    Why       = ''         # that requirement's sentence, verbatim
    Detail    = ''         # extra English detail for -Once / logs
    LogPath   = ''
    LogMode   = ''         # 'resolver' or 'legacy' (see Get-RkUiLogSource)
    GameId    = ''
    Evidence  = ''         # 'builtin-minecraft' or 'template'
    JoinRe    = $script:RkJoinRe
    LeftRe    = $script:RkLeftRe
    BootRe    = $script:RkBootRe
  }
}

function Set-RkRosterUnavailable {
  param([pscustomobject]$Roster, [string]$Reason, [string]$Detail = '')
  $Roster.Available = $false
  $Roster.Reason    = $Reason
  $Roster.Detail    = $Detail
  $Roster.Why       = Get-RkCapabilityWhy -Requirement $Reason
  [void]$Roster.Names.Clear()
  $Roster.Since = @{}
  return $Roster
}

function Set-RkRosterEvidence {
  # Decides which join/leave patterns this game gets, or turns the roster off.
  # Returns the roster.
  param([pscustomobject]$Roster, $Template)

  $connect = ''; $disconnect = ''; $ready = ''
  if ($Template -and $Template.evidence) {
    if ($Template.evidence.connect)    { $connect    = [string]$Template.evidence.connect }
    if ($Template.evidence.disconnect) { $disconnect = [string]$Template.evidence.disconnect }
    if ($Template.evidence.ready)      { $ready      = [string]$Template.evidence.ready }
  }
  $Roster.GameId = $(if ($Template -and $Template.id) { [string]$Template.id } else { '' })

  if ($connect -and $disconnect) {
    $jr = $null; $lr = $null
    try { $jr = [regex]$connect; $lr = [regex]$disconnect }
    catch { return (Set-RkRosterUnavailable -Roster $Roster -Reason 'connectEvidence' -Detail ('the template pattern does not compile: ' + $_.Exception.Message)) }
    # A pattern that matches a line but captures no name cannot be folded into a
    # set: there is nothing to add, and nothing for the leave line to remove. A
    # count kept that way drifts silently, which is worse than saying so.
    if ($jr.GetGroupNumbers().Count -lt 2 -or $lr.GetGroupNumbers().Count -lt 2) {
      return (Set-RkRosterUnavailable -Roster $Roster -Reason 'connectEvidence' -Detail 'evidence.connect / evidence.disconnect match a line but capture no player name (group 1), so arrivals cannot be told apart from each other')
    }
    $Roster.JoinRe   = $jr
    $Roster.LeftRe   = $lr
    $Roster.BootRe   = $(if ($ready) { [regex]$ready } else { $null })
    $Roster.Evidence = 'template'
    return $Roster
  }

  if ($Roster.GameId -eq 'minecraft') {
    $Roster.JoinRe   = $script:RkJoinRe
    $Roster.LeftRe   = $script:RkLeftRe
    $Roster.BootRe   = $script:RkBootRe
    $Roster.Evidence = 'builtin-minecraft'
    return $Roster
  }

  if (-not $Template) {
    return (Set-RkRosterUnavailable -Roster $Roster -Reason 'gameUnknown' -Detail 'no game template matched this folder, so there is no way to know what a join line looks like here')
  }
  return (Set-RkRosterUnavailable -Roster $Roster -Reason 'connectEvidence' -Detail ('template ' + $Roster.GameId + ' declares no evidence.connect / evidence.disconnect'))
}

function Add-RkRosterLine {
  param([pscustomobject]$Roster, [string]$Line, [datetime]$When = [datetime]::MinValue)

  # An unavailable roster does not half-count. Feeding it lines it cannot
  # interpret would produce a number, and a number is read as a measurement.
  if (-not $Roster.Available) { return }

  $bootRe = $Roster.BootRe
  if ($bootRe -and $bootRe.IsMatch($Line)) {
    # A restart. Everyone who was on is not on any more, whatever the log says
    # later - and clearing here is what keeps a boot inside the folded range
    # from leaving ghosts behind.
    [void]$Roster.Names.Clear()
    $Roster.Since = @{}
    return
  }

  $m = $Roster.JoinRe.Match($Line)
  if ($m.Success) {
    $n = $m.Groups[1].Value
    if (-not $Roster.Names.Contains($n)) { [void]$Roster.Names.Add($n) }
    $Roster.Since[$n] = $When
    return
  }

  $m = $Roster.LeftRe.Match($Line)
  if ($m.Success) {
    $n = $m.Groups[1].Value
    if ($Roster.Names.Contains($n)) { [void]$Roster.Names.Remove($n) }
    if ($Roster.Since.ContainsKey($n)) { [void]$Roster.Since.Remove($n) }
  }
}

function Get-RkServerStartTime {
  param([string]$ServerDir)
  # The supervisor writes the pid it is holding. If that process is alive its
  # StartTime is the only trustworthy "since when" - a file timestamp is not,
  # because logs get touched by rotation.
  $pf = Join-Path $ServerDir 'respawnkeeper\server.pid'
  if (-not (Test-Path -LiteralPath $pf)) { return $null }
  try {
    $id = [int]((Get-Content -LiteralPath $pf -Raw).Trim())
    if ($id -le 0) { return $null }
    $p = Get-Process -Id $id -ErrorAction Stop
    return $p.StartTime
  } catch { return $null }
}

function Read-RkGzLines {
  param([string]$Path)
  try {
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
      try {
        # UTF8 first, fall back the same way rk-console does: U+FFFD cannot come
        # out of valid UTF-8, so seeing one means this is the ANSI codepage.
        $sr = New-Object System.IO.StreamReader($gz, [System.Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Close() }
      } finally { $gz.Close() }
    } finally { $fs.Close() }
  } catch { return @() }
  if ($text.IndexOf([char]0xFFFD) -ge 0) { return @() }   # unreadable: skip rather than guess
  return @($text -split "`r?`n")
}

function Initialize-RkRoster {
  param([pscustomobject]$Roster, [string]$ServerDir, $Template)

  if (-not $Template) { $Template = Get-RkUiTemplate -ServerDir $ServerDir }
  [void](Set-RkRosterEvidence -Roster $Roster -Template $Template)

  $src = Get-RkUiLogSource -ServerDir $ServerDir -Template $Template
  $Roster.LogPath = [string]$src.Path
  $Roster.LogMode = $src.Mode

  # Two separate reasons to be off, and they are not interchangeable: one says
  # "this game's joins are unreadable", the other says "there is no log at all".
  # Reporting the wrong one sends a person to fix the wrong thing.
  if (-not $src.Path) {
    $Roster.Folded = $true
    return (Set-RkRosterUnavailable -Roster $Roster -Reason 'logStream' -Detail ('no readable log under ' + $ServerDir))
  }
  if (-not $Roster.Available) { $Roster.Folded = $true; return $Roster }

  $logDir = Split-Path -Parent $src.Path
  $start  = Get-RkServerStartTime -ServerDir $ServerDir
  $files  = @()

  if ($start -and $logDir -and (Test-Path -LiteralPath $logDir)) {
    # Rolled files written at or after the server came up. A file rolled AT
    # 00:00 contains the hours before it, so anything whose last write is after
    # the start time may hold joins that are still standing.
    # debug-N.log.gz is EXCLUDED. It carries the same join lines a second time
    # and rolls on its own schedule, so mixing it in reorders the fold - which
    # for a set built by replaying events in order is not a duplicate, it is a
    # wrong answer.
    #
    # ORDER COMES FROM THE NAME, NOT FROM LastWriteTime. Measured on
    # pokemoncraft 2026-09-07: sorting by LastWriteTime put 2026-09-06-2 BEFORE
    # 2026-09-06-1, which replayed the morning's joins after the evening's
    # leaves and reported 4 players online when 1 was. Log4j names these
    # <date>-<n>.log.gz and that name is the true sequence.
    #
    # This is log4j's scheme, so on a game that rolls its logs differently the
    # list simply comes back empty and the fold is the current log only. That is
    # a smaller window, not a wrong answer - and the roster still says which
    # files it read.
    $keyed = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $logDir -Filter '*.log.gz' -File -ErrorAction SilentlyContinue)) {
      $m = [regex]::Match($f.Name, '^(\d{4})-(\d{2})-(\d{2})-(\d+)\.log\.gz$')
      if (-not $m.Success) { continue }            # debug-N.log.gz and anything hand-named
      $day = $null
      try { $day = [datetime]::ParseExact(($m.Groups[1].Value + '-' + $m.Groups[2].Value + '-' + $m.Groups[3].Value), 'yyyy-MM-dd', $null) }
      catch { continue }
      # Same calendar day as the boot counts: that file holds the boot itself,
      # and the "Done (" line inside it clears whatever preceded it anyway.
      if ($day -lt $start.Date) { continue }
      $keyed += [pscustomobject]@{
        File = $f
        Key  = ($day.ToString('yyyyMMdd') + '-' + ([int]$m.Groups[4].Value).ToString('00000'))
      }
    }
    $files += @($keyed | Sort-Object Key | ForEach-Object { $_.File })
  }

  $names = @()
  foreach ($f in $files) {
    foreach ($ln in (Read-RkGzLines -Path $f.FullName)) { Add-RkRosterLine -Roster $Roster -Line $ln }
    $names += $f.Name
  }

  try {
    $fs = New-Object System.IO.FileStream($src.Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
      $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
      try { while (($ln = $sr.ReadLine()) -ne $null) { Add-RkRosterLine -Roster $Roster -Line $ln } }
      finally { $sr.Close() }
    } finally { $fs.Close() }
  } catch { }
  $names += (Split-Path -Leaf $src.Path)

  $Roster.Folded = $true
  $Roster.Source = ($names -join ', ')
  return $Roster
}

function Get-RkRosterNames { param([pscustomobject]$Roster); return @($Roster.Names) }

function Get-RkRosterStatus {
  # What a window needs to draw three DIFFERENT things: a roster with people on
  # it, an empty roster on a game whose joins are readable, and a game where the
  # question cannot be answered at all.
  param([pscustomobject]$Roster)
  return [pscustomobject]@{
    Available = [bool]$Roster.Available
    Count     = @($Roster.Names).Count
    Reason    = [string]$Roster.Reason
    Why       = [string]$Roster.Why
    Detail    = [string]$Roster.Detail
    Source    = [string]$Roster.Source
    LogPath   = [string]$Roster.LogPath
    LogMode   = [string]$Roster.LogMode
    GameId    = [string]$Roster.GameId
    Evidence  = [string]$Roster.Evidence
    Folded    = [bool]$Roster.Folded
  }
}
