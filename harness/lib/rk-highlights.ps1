# ============================================================
# rk-highlights.ps1 - what actually HAPPENED on the server, for a person.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY (Eva, 2026-09-14): "if you are going to report to me, what I want to know
# is the main problems, one line per topic, and anything interesting that
# happened on that server."
#
# The daily report already answers a different question - how many WARN lines
# were there - and answers it to a developer. Nobody who owns a server wakes up
# wanting the signature count. They want: did it stay up, did anything break,
# and what did my friends do.
#
# ---- IMPORTANT: THIS FILE KNOWS NO GAME ---------------------------------------------
# Eva, the same day, after the first draft: "if it takes a long time that is
# probably a big obstacle to generalising. Think about doing this mechanism for
# Valheim. Let us look for the way that generalises best."
#
# She was right, and the first version was the thing she was warning about:
# 'joined the game', 'has made the advancement' and thirty vanilla death
# sentences were compiled INTO this file, so it read exactly one game and a
# second one meant editing the reader. Measured on five real Valheim logs the
# same day: not one of those strings appears, so the whole report would have
# come out empty and looked like a quiet day.
#
# So this file knows only KINDS - join, leave, chat, achievement, quest, beat,
# namedDeath, death, timeout, population - and a per-game table in
# rules\events-<game>.psd1 says which sentences mean which kind. Adding a game
# is a few lines of data, the same way harness\games\<id>.psd1 already works.
#
# A game lists in 'cannotAnswer' the things its log does not record. The
# report prints that, instead of a zero: "nobody died" and "this log does not
# record deaths" are different facts and must not look the same.
#
# THIS FILE ONLY READS. Rendering is rk-humanreport.ps1's job.
#
# ---- THE TRAPS, ALL MEASURED ------------------------------------------------
#   * EVERY DEATH IS LOGGED TWICE by mod entity logging. Counting raw lines
#     doubles everything.
#   * MOST DEATHS ARE NOT PLAYERS. Of 256 death lines on pokemoncraft 09-09,
#     the great majority are villagers, skeleton horses and TrainerMobs.
#   * A TRAINER DYING IS A PLAYER WINNING - an achievement, not a death.
#   * A POKEMON CAN LAND THE KILLING BLOW and the log names it exactly the way
#     it names a person; "Greninja" came out in the player list. The roster is
#     therefore built only from the kinds a game lists in 'rosterFrom'.
#   * A LIBRARY'S STARTUP JOKE LOOKS LIKE A DEATH: "[owo/]: Jello was 126 years
#     old when we added this line". The roster test kills it.
#   * THE TIMESTAMP IS LOCALISED - "[099<month>2026 10:05:44.672]". Only the clock
#     inside the leading bracket can be parsed.
#   * A DAY IS SPREAD OVER SEVERAL FILES and their NAMES ARE NOT IN ORDER.
#     Measured: 2026-09-13-1.log.gz holds 20:26-23:59 while 2026-09-13-2.log.gz
#     holds 00:00-07:24 of the same day. Sorting by name ran the clock backwards
#     and produced a session of MINUS 1,254 minutes. Files are placed by their
#     ORDER (which the caller fixes with mtime) plus their own clocks - never by
#     a date, because both dates a log file carries have been measured wrong.
#   * debug.log IS latest.log PLUS DEBUG LINES. Reading both counts everything
#     twice; the caller excludes it.
# ============================================================

$script:RkHlEventsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'rules'

function Get-RkEventTable {
  # The per-game sentence table. -Name is a file in harness\rules\.
  param([string]$Name = 'events-minecraft.psd1')
  $p = $Name
  if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $script:RkHlEventsDir $Name }
  if (-not (Test-Path -LiteralPath $p)) { throw ('event table not found: ' + $p) }
  return (Import-PowerShellDataFile -LiteralPath $p)
}

function Get-RkHlBody {
  # The message, with the timestamp preamble taken off.
  #
  # The shape of that preamble is the ENGINE's, so a game may supply its own:
  # log4j writes '[099<month>2026 10:05:44.672] [Server thread/INFO] [x/]: msg' and
  # the ']: ' split handles it, but Valheim's launcher writes
  # '09/14/2026 16:55:06:  msg' - measured, two spaces and all - which has no
  # ']: ' anywhere, so the whole line came back and every pattern anchored at ^
  # silently failed to match.
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
    [string]$Preamble = ''
  )
  if ($Preamble -and ($Line -match $Preamble)) {
    return $Line.Substring($Matches[0].Length).Trim()
  }
  $i = $Line.IndexOf(']: ')
  if ($i -lt 0) { return $Line.Trim() }
  return $Line.Substring($i + 3).Trim()
}

function Get-RkHlClock {
  # Minutes-of-day as a double, or $null when the line carries no clock.
  # Two shapes, both measured: log4j puts it inside a leading bracket
  # ("[099<month>2026 10:05:44.672] ..."), Valheim's launcher puts it bare at the
  # start of the line ("09/14/2026 16:44:37: ...").
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
  if ($Line -match '^\[[^\]]*?(\d{1,2}):(\d{2}):(\d{2})') {
    return (([double]$Matches[1]) * 60.0) + ([double]$Matches[2]) + (([double]$Matches[3]) / 60.0)
  }
  if ($Line -match '^[^\[\]]{0,24}?\b(\d{1,2}):(\d{2}):(\d{2})\b') {
    return (([double]$Matches[1]) * 60.0) + ([double]$Matches[2]) + (([double]$Matches[3]) / 60.0)
  }
  return $null
}

function Format-RkHlClock {
  # Minutes-since-log-start back to a wall clock. Days roll over silently:
  # a report that said 27:15 would be worse than one that said 03:15.
  param([double]$Minutes)
  $m = [int][Math]::Floor($Minutes) % 1440
  if ($m -lt 0) { $m += 1440 }
  return ('{0:d2}:{1:d2}' -f [int]([Math]::Floor($m / 60)), [int]($m % 60))
}

function Get-RkHlSpanParts {
  # Splits a duration into the pieces a sentence needs, and says which shape
  # to use. The WORDS are not here: this file is ASCII, and picking phrasing in
  # the same place that does arithmetic is how '3h60m' happened on the panel
  # card - the rounding was invisible because the formatting was.
  param([double]$Minutes)
  $t = [int][Math]::Round($Minutes)
  if ($t -lt 1)  { return @{ shape = 'tiny';  hours = 0; minutes = 0 } }
  if ($t -lt 60) { return @{ shape = 'min';   hours = 0; minutes = $t } }
  $h = [int][Math]::Floor($t / 60)
  $r = $t % 60
  if ($r -eq 0)  { return @{ shape = 'hour';  hours = $h; minutes = 0 } }
  return @{ shape = 'hourmin'; hours = $h; minutes = $r }
}

function Test-RkHlPlayerName {
  # Does this look like a name in THIS game. The shape is the game's, not this
  # file's: a Minecraft username has no spaces, a Valheim character name does.
  param([string]$Name, [string]$Shape = '^[A-Za-z0-9_]{3,16}$')
  if (-not $Name) { return $false }
  if (-not $Shape) { return $true }
  return ($Name -match $Shape)
}

function Remove-RkHlSecrets {
  # Chat is quoted now, so it goes through the same filter the rest of the
  # report does. Somebody typing a password into chat is exactly the accident
  # this catches, and the one the owner would least want written down.
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
  $s = $Text
  $s = $s -replace '(?i)(password|passwd|adminpassword|token|secret|apikey|api_key)\s*[:=]?\s*\S+', '$1=<redacted>'
  $s = $s -replace '\b(\d{1,3}\.){3}\d{1,3}\b', '<ip>'
  return $s
}

function Get-RkHighlights {
  # Everything a person would retell about a run of the server, from log TEXT.
  # Reads nothing off disk except the event table.
  #
  # -Sources is the real interface: @( @{ name; lines = @() } ), one entry per
  # log FILE, IN CHRONOLOGICAL ORDER (the caller sorts by mtime; see the header
  # for why not by name). -Lines stays for a single file or a test fixture.
  #
  # AllowEmptyString, because a log HAS blank lines and Mandatory on a
  # [string[]] validates every ELEMENT as non-empty - so the whole call was
  # rejected with "cannot bind ... because it is an empty string" and the
  # report came out empty with a red error above it.
  param(
    [AllowEmptyString()][string[]]$Lines,
    $Sources = $null,
    $Events = $null
  )
  if (-not $Sources) {
    if ($null -eq $Lines) { throw 'Get-RkHighlights needs -Lines or -Sources' }
    $Sources = @(@{ name = ''; lines = @($Lines) })
  }
  $Sources = @($Sources)
  if (-not $Events) { $Events = Get-RkEventTable }

  $rules      = @($Events.rules)
  $rosterFrom = @($Events.rosterFrom)
  $deathVerbs = @($Events.deathVerbs)
  $idleCauses = @($Events.idleCauses)
  $notPlayer  = [string]$Events.notPlayer
  $nameShape  = [string]$Events.nameShape
  $bootRe     = [string]$Events.boot
  $preamble   = [string]$Events.preamble

  $res = @{
    players      = @{}
    roster       = @()
    deaths       = @{}   # cause -> count   (players only)
    deathEvents  = @()   # @{ who; cause; at }
    achievements = @()   # @{ who; what; kind }
    lostNamed    = @()   # named non-player entities that died
    chat         = @()   # @{ who; at; text }
    chatCount    = 0
    timedOut     = 0
    population   = @()   # @{ at; n }  - games that only count heads
    peakPop      = 0
    lineCount    = 0
    firstAt      = $null
    lastAt       = $null
    cannotAnswer = @($Events.cannotAnswer)
    game         = [string]$Events.game
  }
  foreach ($s0 in $Sources) { $res.lineCount += @($s0.lines).Count }

  function _p([string]$n) {
    if (-not $res.players.ContainsKey($n)) {
      $res.players[$n] = @{
        joins = 0; leaves = 0; deaths = 0; advancements = 0; quests = 0
        trainers = 0; chat = 0
        minutes = 0.0; firstSeen = $null; lastSeen = $null
        sessions = @(); causes = @{}; events = @()
        partial = $false; stillOn = $false
      }
    }
    return $res.players[$n]
  }

  # Runs the table against one line body. Returns the first rule that matched
  # together with its captures, or $null.
  function _match([string]$body) {
    foreach ($r in $rules) {
      if ($body -match ([string]$r.re)) {
        $g = @{}
        foreach ($f in @('who', 'what', 'text', 'count', 'ofKind')) {
          if ($null -ne $r[$f]) { $g[$f] = [string]$Matches[[int]$r[$f]] }
        }
        return @{ rule = $r; g = $g }
      }
    }
    return $null
  }

  # ---- PASS 1: who is actually a person ------------------------------------
  # Only the kinds the game says can only ever be about a human.
  $real = @{}
  if ($rosterFrom.Count -gt 0) {
    foreach ($src0 in $Sources) {
      foreach ($raw in @($src0.lines)) {
        $b = Get-RkHlBody -Line ([string]$raw) -Preamble $preamble
        if (-not $b) { continue }
        $m = _match $b
        if (-not $m) { continue }
        if ($rosterFrom -notcontains [string]$m.rule.kind) { continue }
        $w = [string]$m.g['who']
        if (Test-RkHlPlayerName -Name $w -Shape $nameShape) { $real[$w] = $true }
      }
    }
  }
  $res['roster'] = @($real.Keys | Sort-Object)

  # ---- PASS 2: the run, in order -------------------------------------------
  $now = $null
  $openFrom = @{}
  $lastAbs = $null
  $prevSegBase = 0.0

  # Sessions end here, not at the end of the whole scan. The hashtable is
  # CLEARED rather than reassigned: an assignment inside a nested function
  # makes a new local and the parent keeps the old one, so the sessions would
  # never actually close.
  function _closeAll([double]$at, [bool]$final) {
    foreach ($w in @($openFrom.Keys)) {
      $q = _p $w
      if ($at -gt $openFrom[$w]) {
        $q.minutes += ($at - $openFrom[$w])
        $q.sessions += @{ from = $openFrom[$w]; to = $at }
      }
      $q.lastSeen = $at
      if ($final) { $q.stillOn = $true }
    }
    $openFrom.Clear()
  }

  foreach ($src in $Sources) {
    $srcLines = @($src.lines)
    if ($srcLines.Count -eq 0) { continue }

    # WHERE THIS FILE SITS ON THE TIMELINE - from order and clocks only.
    # Each file is placed at the earliest whole day that puts its first line at
    # or after the last line of the file before it.
    $firstClk = $null
    foreach ($probe in $srcLines) {
      $firstClk = Get-RkHlClock -Line ([string]$probe)
      if ($null -ne $firstClk) { break }
    }
    if ($null -eq $lastAbs) {
      $segBase = 0.0
    } elseif ($null -eq $firstClk) {
      $segBase = $prevSegBase
    } else {
      $cand = $prevSegBase + $firstClk
      while ($cand -lt $lastAbs) { $cand += 1440.0 }
      $segBase = $cand - $firstClk
    }
    $prevSegBase = $segBase

    # A boot banner means the server came up empty, so anybody still counted as
    # online in the previous file was disconnected when it went down.
    if (($null -ne $lastAbs) -and $bootRe) {
      $booted = $false
      foreach ($probe in ($srcLines | Select-Object -First 400)) {
        if ([string]$probe -match $bootRe) { $booted = $true; break }
      }
      if ($booted) { _closeAll $lastAbs $false }
    }

    $intra = 0.0
    $prevRaw = $null

    foreach ($raw in $srcLines) {
      $line = [string]$raw
      $clk = Get-RkHlClock -Line $line
      if ($null -ne $clk) {
        # Midnight INSIDE one file. Between files the placement above does this
        # job; within one, a jump back of more than an hour is the only thing
        # that cannot be ordinary drift.
        if (($null -ne $prevRaw) -and ($clk -lt ($prevRaw - 60.0))) { $intra += 1440.0 }
        $prevRaw = $clk
        $now = $segBase + $clk + $intra
        $lastAbs = $now
        if (($null -eq $res.firstAt) -or ($now -lt $res.firstAt)) { $res.firstAt = $now }
        if (($null -eq $res.lastAt)  -or ($now -gt $res.lastAt))  { $res.lastAt  = $now }
      }

      $body = Get-RkHlBody -Line $line -Preamble $preamble
      if (-not $body) { continue }

      $m = _match $body
      if ($m) {
        $kind = [string]$m.rule.kind
        $who  = [string]$m.g['who']
        $what = [string]$m.g['what']

        switch ($kind) {
          'population' {
            $n = 0
            [void][int]::TryParse([string]$m.g['count'], [ref]$n)
            $res.population += @{ at = $now; n = $n }
            if ($n -gt $res.peakPop) { $res.peakPop = $n }
          }
          'chat' {
            # Counted whoever said it, quoted either way: on a server the owner
            # runs, a line from the console is still something that was said.
            $res.chatCount++
            $res.chat += @{ who = $who; at = $now; text = (Remove-RkHlSecrets -Text ([string]$m.g['text'])) }
            if ($real.ContainsKey($who)) { (_p $who).chat++; (_p $who).events += $now }
          }
          'join' {
            if ($real.ContainsKey($who)) {
              $p = _p $who
              $p.joins++
              if ($null -eq $p.firstSeen) { $p.firstSeen = $now }
              # A second join with no leave between is a reconnect the server
              # never logged the other half of. Close the old one rather than
              # dropping it, or the time is lost.
              if ($openFrom.ContainsKey($who) -and ($null -ne $now)) {
                $p.minutes += ($now - $openFrom[$who])
                $p.sessions += @{ from = $openFrom[$who]; to = $now }
              }
              if ($null -ne $now) { $openFrom[$who] = $now }
              $p.events += $now
            }
          }
          'leave' {
            if ($real.ContainsKey($who)) {
              $p = _p $who
              $p.leaves++
              if ($openFrom.ContainsKey($who)) {
                if ($null -ne $now) {
                  $p.minutes += ($now - $openFrom[$who])
                  $p.sessions += @{ from = $openFrom[$who]; to = $now }
                }
                $openFrom.Remove($who)
              } else {
                # Left without joining: this window began after they were
                # already on. Their time is unknowable and "0" would be a lie.
                $p.partial = $true
              }
              $p.lastSeen = $now
              $p.events += $now
            }
          }
          'achievement' {
            if ($real.ContainsKey($who)) {
              $p = _p $who; $p.advancements++
              $res.achievements += @{ who = $who; what = $what; kind = 'advancement'; at = $now }
              $p.events += $now
            }
          }
          'quest' {
            if ($real.ContainsKey($who)) {
              $p = _p $who; $p.quests++
              $res.achievements += @{ who = $who; what = $what; kind = 'quest'; at = $now }
              $p.events += $now
            }
          }
          'beat' {
            if ($real.ContainsKey($who)) {
              $p = _p $who; $p.trainers++
              $res.achievements += @{ who = $who; what = $what; kind = 'trainer'; at = $now }
              $p.events += $now
            }
          }
          'namedDeath' {
            $ofKind = [string]$m.g['ofKind']
            $skipK = [string]$m.rule.skipKind
            $skipW = [string]$m.rule.skipWhat
            $drop = $false
            if ($skipK -and ($ofKind -match $skipK)) { $drop = $true }
            if ($skipW -and ($what -match $skipW))   { $drop = $true }
            if (-not $what) { $drop = $true }
            if (-not $drop) {
              $res.lostNamed += @{ name = $what; kind = $ofKind; how = [string]$m.g['text']; at = $now }
            }
          }
          'death' {
            # A game whose log names the dead player outright, with no cause.
            if ($real.ContainsKey($who)) {
              $p = _p $who; $p.deaths++
              if (-not $res.deaths.ContainsKey('died')) { $res.deaths['died'] = 0 }
              $res.deaths['died']++
              if (-not $p.causes.ContainsKey('died')) { $p.causes['died'] = 0 }
              $p.causes['died']++
              $res.deathEvents += @{ who = $who; cause = 'died'; at = $now }
              $p.events += $now
            }
          }
          'timeout' { $res.timedOut++ }
        }
        continue
      }

      # --- a PLAYER died, for games that broadcast a whole sentence ----------
      # Matched by VERB because the subject is a name this table cannot know
      # and the tail varies with the weapon. No entity-debug prefix: that is
      # what mod logging puts in front of everything that is not a player.
      if ($deathVerbs.Count -eq 0) { continue }
      if ($notPlayer -and ($body -match $notPlayer)) { continue }
      foreach ($v in $deathVerbs) {
        $idx = $body.IndexOf([string]$v)
        if ($idx -lt 1) { continue }
        $who = $body.Substring(0, $idx).Trim()
        if (-not $real.ContainsKey($who)) { break }
        $p = _p $who
        $p.deaths++
        # The cause stays in the game's own words. Turning it into Japanese is
        # a table lookup in rk-humanreport.ps1, so a phrase nobody has seen
        # survives to the report instead of being guessed at.
        $cause = $body.Substring($idx).Trim()
        if (-not $res.deaths.ContainsKey($cause)) { $res.deaths[$cause] = 0 }
        $res.deaths[$cause]++
        if (-not $p.causes.ContainsKey($cause)) { $p.causes[$cause] = 0 }
        $p.causes[$cause]++
        $res.deathEvents += @{ who = $who; cause = $cause; at = $now }
        $p.events += $now
        break
      }
    }
  }

  if ($null -ne $res.lastAt) { _closeAll ([double]$res.lastAt) $true }

  # ---- the things a duration makes possible --------------------------------
  foreach ($who in @($res.players.Keys)) {
    $p = $res.players[$who]

    # (1) THE LONGEST STRETCH WITH NOTHING IN IT. Eva wants to guess who was
    # idling. This is the only measurable version of that question, and it is
    # NOT proof: a player quietly building a base logs nothing either.
    #
    # Measured PER SESSION and INCLUDING BOTH ENDS. Walking the event list
    # alone got it exactly backwards for the one player it mattered most for:
    # somebody who joins, does nothing for 74 minutes and never logs another
    # line has ONE event, so the loop never ran and their quiet stretch came
    # out as zero.
    $ev = @($p.events | Where-Object { $null -ne $_ } | Sort-Object)
    $quiet = 0.0
    $quietFrom = $null
    foreach ($s in @($p.sessions)) {
      $marks = @([double]$s.from)
      foreach ($e in $ev) { if (($e -ge $s.from) -and ($e -le $s.to)) { $marks += [double]$e } }
      $marks += [double]$s.to
      $marks = @($marks | Sort-Object)
      for ($i = 1; $i -lt $marks.Count; $i++) {
        $gap = $marks[$i] - $marks[$i - 1]
        if ($gap -gt $quiet) { $quiet = $gap; $quietFrom = $marks[$i - 1] }
      }
    }
    $p['quietMax'] = $quiet
    $p['quietFrom'] = $quietFrom
    # As a share of the time they were online. A 40-minute gap means something
    # different in a 45-minute session than in a 10-hour one, and without the
    # ratio this fired for seven of nine players on a real day - a finding that
    # fires for everybody is not a finding.
    $p['quietShare'] = $(if ([double]$p.minutes -gt 0) { $quiet / [double]$p.minutes } else { 0.0 })

    # (2) WHERE THEY GOT STUCK. The same cause three times is not bad luck, it
    # is a place on the map or a fight they cannot get past - which is the
    # thing Eva said she actually got out of the first report.
    $stuck = @()
    foreach ($c in @($p.causes.Keys)) {
      if ($p.causes[$c] -ge 3) { $stuck += @{ cause = $c; count = $p.causes[$c] } }
    }
    $p['stuck'] = @($stuck | Sort-Object { -$_.count })

    # (3) DEATHS THAT NEEDED NOBODY AT THE KEYBOARD. Carried on the player
    # rather than looked up again by the renderer: data travels between files,
    # a $script: variable does not.
    $idle = 0
    $idleList = @()
    foreach ($c in @($p.causes.Keys)) {
      foreach ($ic in $idleCauses) {
        if ($c -eq $ic) { $idle += $p.causes[$c]; $idleList += $c; break }
      }
    }
    $p['idleDeaths'] = $idle
    $p['idleCauses'] = @($idleList)
  }

  return $res
}
