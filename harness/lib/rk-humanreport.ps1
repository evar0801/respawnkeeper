# ============================================================
# rk-humanreport.ps1 - turns Get-RkHighlights output into the part of the
# daily report that a person reads. ASCII only (PS 5.1 reads a BOM-less .ps1
# as ANSI); every visible word comes from rules\report-human.ja.json.
#
# WHY THIS IS A SEPARATE FILE FROM rk-highlights.ps1:
#   counting and phrasing are different jobs and they fail differently. The
#   panel card that printed '3h60m' did it because the rounding lived in the
#   same expression as the wording, so nobody could see either one. Here the
#   arithmetic returns parts (Get-RkHlSpanParts) and this file picks the
#   sentence.
#
# THE VOICE (Eva, 2026-09-14): no keigo, terse, researcher-ish - it remarks on
# distributions, not on feelings. The character's NAME never appears, here or
# anywhere a user can read ([R-063]). All of that lives in the .json; this file
# only decides which line to reach for.
# ============================================================

function ConvertTo-RkCauseJa {
  # A death cause in the game's words -> Japanese, via the table. A cause the
  # table has never seen comes back UNCHANGED and is reported as untranslated.
  # Guessing here would be the worst possible place to guess: the cause is the
  # evidence for "where is this player stuck", so a wrong translation destroys
  # the only thing the line was for.
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Cause,
    $Causes = $null
  )
  if (-not $Causes) { return @{ text = $Cause; translated = $false } }

  # The opponent's name is translated first and separately: it is a captured
  # group, so it has to be a NAME lookup, not a phrase lookup. Anything the mob
  # table does not know (mod mobs, Pokemon, player names) stays as it is -
  # translating a player's name would make the line unreadable.
  $mobs = $Causes.mobs
  foreach ($r in @($Causes.causes)) {
    $re = [string]$r.re
    if ($Cause -notmatch $re) { continue }
    $g = @()
    for ($i = 1; $i -lt $Matches.Count; $i++) {
      $v = [string]$Matches[$i]
      if ($mobs -and ($mobs.PSObject.Properties.Name -contains $v)) { $v = [string]$mobs.$v }
      $g += $v
    }
    $out = [string]$r.ja
    for ($i = 0; $i -lt $g.Count; $i++) { $out = $out.Replace('{' + $i + '}', $g[$i]) }
    return @{ text = $out; translated = $true }
  }
  return @{ text = $Cause; translated = $false }
}

function Format-RkSpanJa {
  param([double]$Minutes, [Parameter(Mandatory)]$S)
  $p = Get-RkHlSpanParts -Minutes $Minutes
  switch ($p.shape) {
    'tiny'    { return [string]$S.span_tiny }
    'min'     { return [string]::Format([string]$S.span_min, $p.minutes) }
    'hour'    { return [string]::Format([string]$S.span_hour, $p.hours) }
    default   { return [string]::Format([string]$S.span_hourmin, $p.hours, $p.minutes) }
  }
}

function Get-RkHumanReport {
  # Returns the markdown for the human half of the daily report.
  #
  # $Problems is what the machine half already worked out, passed in rather
  # than recomputed: @( @{ title; count } ). Eva asked for the problems as one
  # line per topic, so they land in the same bullet list as everything else
  # instead of in their own wall of tables further down.
  param(
    [Parameter(Mandatory)]$Highlights,
    [Parameter(Mandatory)]$S,
    $Causes = $null,
    [string]$Label = '',
    [string]$Day = '',
    # The window as the CALLER knows it, dates included. Deriving it from the
    # clocks in the log produced "10:03 - 01:15" for a three-day scan, which
    # reads as a fifteen-hour evening.
    [string]$WindowText = '',
    [int]$FileCount = 0,
    $Problems = @(),
    # @{ starts; exits; dirty; halts; upMinutes } out of watchdog.log. The
    # supervisor's own record of the day, which is a different witness from the
    # game's log and the only one that knows the server went away.
    $Watchdog = $null,
    [int]$UnknownCount = 0,
    [int]$MaxChat = 200
  )

  $h = $Highlights
  $sb = New-Object System.Text.StringBuilder
  function W([string]$t) { [void]$sb.AppendLine($t) }
  function FMT { param([string]$f) $rest = @($args); return [string]::Format($f, $rest) }
  $SEP = [string]$S.sep

  $roster = @($h.roster)
  $players = $h.players

  # WHAT THIS GAME'S LOG CANNOT RECORD. A section printed with a zero in it is
  # a claim; "nobody died" and "this log has no death line" are different
  # facts. Valheim reaches here with four of these set, so the sections it
  # cannot fill are left out entirely rather than filled with denials.
  $cant = @($h.cannotAnswer)

  # ---- totals ---------------------------------------------------------------
  $totalDeaths = 0
  foreach ($k in $h.deaths.Keys) { $totalDeaths += $h.deaths[$k] }
  $quests  = @($h.achievements | Where-Object { $_.kind -eq 'quest' })
  $vanilla = @($h.achievements | Where-Object { $_.kind -eq 'advancement' })
  $trainer = @($h.achievements | Where-Object { $_.kind -eq 'trainer' })
  $totalMin = 0.0
  foreach ($k in $players.Keys) { $totalMin += [double]$players[$k].minutes }

  # ---- header ---------------------------------------------------------------
  W (FMT ([string]$S.title) $Label $Day)
  W ''
  $win = $WindowText
  if (-not $win) {
    $from = $(if ($null -ne $h.firstAt) { Format-RkHlClock -Minutes $h.firstAt } else { '?' })
    $to   = $(if ($null -ne $h.lastAt)  { Format-RkHlClock -Minutes $h.lastAt }  else { '?' })
    $win = ($from + ' - ' + $to)
  }
  W (FMT ([string]$S.window) $win $h.lineCount $FileCount)
  W ''

  # ---- the one line ---------------------------------------------------------
  # A game whose log has no names is not the same as a quiet day. Valheim's log
  # carries a head count and nothing else, so "nobody came" is only allowed to
  # be said when a counter actually said zero.
  $pop = @($h.population)
  if (($roster.Count -eq 0) -and ([int]$h.peakPop -gt 0)) {
    W (FMT ([string]$S.lead_pop) $h.peakPop)
  } elseif ($roster.Count -eq 0) {
    W ([string]$S.lead_nobody)
  } elseif (($totalDeaths -eq 0) -and (($quests.Count + $vanilla.Count) -eq 0)) {
    W (FMT ([string]$S.lead_quiet) $roster.Count (Format-RkSpanJa -Minutes $totalMin -S $S))
  } else {
    W (FMT ([string]$S.lead_some) $roster.Count (Format-RkSpanJa -Minutes $totalMin -S $S) `
          $totalDeaths ($quests.Count + $vanilla.Count))
  }
  W ''

  # ---- one line per topic ---------------------------------------------------
  W ([string]$S.h_happened)
  W ''
  if ($roster.Count -eq 1) {
    $only = $roster[0]
    W (FMT ([string]$S.hap_solo) $only (Format-RkSpanJa -Minutes ([double]$players[$only].minutes) -S $S))
  } elseif ($roster.Count -gt 1) {
    $longest = ''; $longestMin = -1.0
    foreach ($k in $players.Keys) { if ([double]$players[$k].minutes -gt $longestMin) { $longestMin = [double]$players[$k].minutes; $longest = $k } }
    W (FMT ([string]$S.hap_played) $roster.Count (Format-RkSpanJa -Minutes $totalMin -S $S) `
          $longest (Format-RkSpanJa -Minutes $longestMin -S $S))
  }

  if ($totalDeaths -gt 0) {
    $top = @($h.deaths.Keys | Sort-Object { -$h.deaths[$_] } | Select-Object -First 1)[0]
    $topJa = (ConvertTo-RkCauseJa -Cause $top -Causes $Causes).text
    W (FMT ([string]$S.hap_deaths) $totalDeaths $topJa $h.deaths[$top])
  } elseif ($roster.Count -gt 0) {
    W ([string]$S.hap_deaths_none)
  }

  if (($vanilla.Count -gt 0) -and ($quests.Count -gt 0)) {
    W (FMT ([string]$S.hap_ach) $vanilla.Count $quests.Count)
  } elseif ($quests.Count -gt 0) {
    W (FMT ([string]$S.hap_ach_quest_only) $quests.Count)
  } elseif ($vanilla.Count -gt 0) {
    W (FMT ([string]$S.hap_ach) $vanilla.Count 0)
  }
  if ($trainer.Count -gt 0) { W (FMT ([string]$S.hap_trainer) $trainer.Count) }

  # Somebody is stuck: this is the topic Eva said she actually got out of the
  # first draft. Grouped BY CAUSE, not by player - on a real day it was four
  # separate lines about the same hole in the map, which is not "one line per
  # topic", it is one topic printed four times. The per-player breakdown is
  # still below; this line is the pattern.
  $stuckBy = @{}
  foreach ($k in ($roster | Sort-Object)) {
    foreach ($st in @($players[$k].stuck)) {
      $c = [string]$st.cause
      if (-not $stuckBy.ContainsKey($c)) { $stuckBy[$c] = @() }
      $stuckBy[$c] += $k
    }
  }
  # Three, then a count. Over a one-day window this is two or three lines; over
  # a ten-day one it was TEN, and a topic list that long stops being a topic
  # list. The rest are all in the deaths table anyway.
  $stuckKeys = @($stuckBy.Keys | Sort-Object { -$h.deaths[$_] })
  foreach ($c in ($stuckKeys | Select-Object -First 3)) {
    $ja = (ConvertTo-RkCauseJa -Cause $c -Causes $Causes).text
    W (FMT ([string]$S.hap_stuck) $ja $h.deaths[$c] @($stuckBy[$c]).Count ((@($stuckBy[$c]) | Sort-Object) -join $SEP))
  }
  if ($stuckKeys.Count -gt 3) { W (FMT ([string]$S.hap_stuck_more) ($stuckKeys.Count - 3)) }

  $lostSeen = @{}
  foreach ($l in @($h.lostNamed)) { $lostSeen[([string]$l.name) + "`t" + ([string]$l.how)] = $true }
  foreach ($k in @($lostSeen.Keys)) {
    $parts = $k -split "`t"
    $nm = [string]$parts[0]
    # The 'died:' text repeats the entity's own name in front of the cause
    # ("Pochi was slain by Zombie"). Strip exactly that prefix rather than
    # regexing for a verb - the name can contain anything, including a verb.
    $rawHow = [string]$parts[1]
    if ($rawHow.StartsWith($nm + ' ')) { $rawHow = $rawHow.Substring($nm.Length + 1) }
    $how = (ConvertTo-RkCauseJa -Cause $rawHow -Causes $Causes).text
    W (FMT ([string]$S.hap_lost) $nm $how)
  }

  # WHAT THE SUPERVISOR ITSELF SAW. Eva asked for the main problems, one line
  # per topic - and "it went down four times" is a bigger topic than any WARN
  # count. It does not come from the game's log at all: respawnkeeper writes it
  # to watchdog.log, which nothing was reading.
  $wd = $Watchdog
  if ($wd -and (([int]$wd.starts -gt 0) -or ([int]$wd.exits -gt 0))) {
    W (FMT ([string]$S.hap_wd_up) $wd.starts $wd.exits (Format-RkSpanJa -Minutes ([double]$wd.upMinutes) -S $S))
    if ([int]$wd.exits -gt 0) {
      if ([int]$wd.dirty -gt 0) {
        $when = $(if ($wd.lastDirty) { ([datetime]$wd.lastDirty).ToString('MM-dd HH:mm') } else { '?' })
        # Two clean stops since the last bad one is enough to say "it stopped",
        # and saying so is the difference between a number and an answer.
        if ([int]$wd.cleanSince -ge 2) { W (FMT ([string]$S.hap_wd_recovered) $wd.dirty $when $wd.cleanSince) }
        else                           { W (FMT ([string]$S.hap_wd_dirty) $wd.dirty $wd.exits $when) }
      } else { W (FMT ([string]$S.hap_wd_clean) $wd.exits) }
    }
    if ([int]$wd.halts -gt 0) { W (FMT ([string]$S.hap_wd_halt) $wd.halts) }
  }

  if ($h.chatCount -gt 0)  { W (FMT ([string]$S.hap_chat) $h.chatCount) }
  if ($h.timedOut -gt 0)   { W (FMT ([string]$S.hap_timeout) $h.timedOut) }

  # The machine half, compressed to one line each.
  $probs = @($Problems)
  if ($probs.Count -gt 0) {
    foreach ($p in $probs) { W (FMT ([string]$S.hap_problem) ([string]$p.title) ([string]$p.count)) }
  } else {
    W ([string]$S.hap_clean)
  }
  if ($UnknownCount -gt 0) { W (FMT ([string]$S.hap_unknown) $UnknownCount) }
  W ''

  # ---- per player -----------------------------------------------------------
  # A game that only counts heads gets the section it can fill, not an empty
  # copy of the one it cannot.
  if (($roster.Count -eq 0) -and ($pop.Count -gt 0)) {
    W ([string]$S.h_pop)
    W ''
    W (FMT ([string]$S.pop_lead) $pop.Count)
    W ''
    $withPeople = @($pop | Where-Object { [int]$_.n -gt 0 }).Count
    if ($withPeople -eq 0) {
      W (FMT ([string]$S.pop_empty) $pop.Count)
    } else {
      W (FMT ([string]$S.pop_some) $pop.Count $withPeople)
      $peakAtP = $null
      foreach ($s3 in $pop) { if (([int]$s3.n -eq [int]$h.peakPop) -and ($null -eq $peakAtP)) { $peakAtP = $s3.at } }
      W (FMT ([string]$S.pop_peak) $h.peakPop `
            $(if ($null -ne $peakAtP) { Format-RkHlClock -Minutes $peakAtP } else { '--:--' }))
    }
    W ''
  }

  if ($cant -notcontains 'name') {
  W ([string]$S.h_people)
  W ''
  if ($roster.Count -eq 0) {
    W ([string]$S.ppl_none)
    W ''
  } else {
    W ([string]$S.ppl_header)
    W ([string]$S.ppl_sep)
    foreach ($k in ($roster | Sort-Object { -[double]$players[$_].minutes })) {
      $p = $players[$k]
      $span = $(if ($p.joins -gt 0 -or $p.partial) { Format-RkSpanJa -Minutes ([double]$p.minutes) -S $S } else { '?' })
      $fs = $(if ($null -ne $p.firstSeen) { Format-RkHlClock -Minutes $p.firstSeen } else { '?' })
      $ls = $(if ($null -ne $p.lastSeen)  { Format-RkHlClock -Minutes $p.lastSeen }  else { '?' })
      W ('| ' + $k + ' | ' + $span + ' | ' + $fs + '-' + $ls + ' | ' + $p.joins + ' | ' +
         $p.deaths + ' | ' + $p.advancements + ' | ' + $p.quests + ' | ' + $p.trainers + ' | ' + $p.chat + ' |')
    }
    W ''

    foreach ($k in ($roster | Sort-Object { -[double]$players[$_].minutes })) {
      $p = $players[$k]
      foreach ($st in @($p.stuck)) {
        $ja = (ConvertTo-RkCauseJa -Cause $st.cause -Causes $Causes).text
        W (FMT ([string]$S.ppl_note_stuck) $k $ja $st.count)
      }
      # TWO of them, not one. A single heatstroke is what happens to somebody
      # exploring a desert in a Cold Sweat pack; it is not evidence of anything.
      # At one, this line printed for five of nine players on a real day and
      # accused most of them of idling on no evidence at all.
      if ([int]$p.idleDeaths -ge 2) {
        $names = @()
        foreach ($c in @($p.idleCauses)) { $names += (ConvertTo-RkCauseJa -Cause ([string]$c) -Causes $Causes).text }
        W (FMT ([string]$S.ppl_note_idle) $k $p.idleDeaths (($names | Select-Object -Unique) -join $SEP))
      }
      # Half an hour AND at least 40% of the time they were online. The
      # absolute number alone fired for seven of nine players, because anybody
      # who plays for ten hours has a long gap somewhere in it. The ratio is
      # what separates "took a break" from "was not there".
      if (([double]$p.quietMax -ge 30.0) -and ([double]$p.quietShare -ge 0.4) -and ($null -ne $p.quietFrom)) {
        W (FMT ([string]$S.ppl_note_quiet) $k (Format-RkHlClock -Minutes $p.quietFrom) `
              (Format-RkHlClock -Minutes ([double]$p.quietFrom + [double]$p.quietMax)) `
              ([int][Math]::Round([double]$p.quietShare * 100)))
      }
      if ($p.partial) { W (FMT ([string]$S.ppl_note_partial) $k) }
      if ($p.stillOn) { W (FMT ([string]$S.ppl_note_stillon) $k) }
      # Four reconnects in a ten-hour evening is ordinary. Twelve is a link
      # that keeps dropping, and only that is worth a line.
      if ([int]$p.joins -ge 8) { W (FMT ([string]$S.ppl_note_reconnect) $k $p.joins) }
      if (([int]$p.deaths -eq 0) -and ([int]$p.advancements -eq 0) -and
          ([int]$p.quests -eq 0) -and ([int]$p.trainers -eq 0) -and ([int]$p.chat -eq 0)) {
        W (FMT ([string]$S.ppl_note_lurk) $k (Format-RkSpanJa -Minutes ([double]$p.minutes) -S $S))
      }
    }
    W ''
  }

  }   # end of the per-player section

  # ---- how they died --------------------------------------------------------
  if ($cant -notcontains 'death') {
  W ([string]$S.h_deaths)
  W ''
  if ($totalDeaths -eq 0) {
    W ([string]$S.dth_none)
    W ''
  } else {
    $untranslated = @()
    $byCause = @{}
    foreach ($d in @($h.deathEvents)) {
      $c = [string]$d.cause
      if (-not $byCause.ContainsKey($c)) { $byCause[$c] = @() }
      $byCause[$c] += [string]$d.who
    }
    W ([string]$S.dth_header)
    W ([string]$S.dth_sep)
    foreach ($c in ($h.deaths.Keys | Sort-Object { -$h.deaths[$_] })) {
      $t = ConvertTo-RkCauseJa -Cause $c -Causes $Causes
      if (-not $t.translated) { $untranslated += $c }
      $who = @($byCause[$c] | Group-Object | Sort-Object Count -Descending |
               ForEach-Object { $(if ($_.Count -gt 1) { $_.Name + ' x' + $_.Count } else { $_.Name }) })
      W ('| ' + $h.deaths[$c] + ' | ' + ($t.text -replace '\|', '\|') + ' | ' + (($who -join $SEP) -replace '\|', '\|') + ' |')
    }
    W ''
    if ($untranslated.Count -gt 0) {
      W (FMT ([string]$S.dth_untranslated) $untranslated.Count ('`' + (($untranslated | Select-Object -Unique) -join ('`' + $SEP + '`')) + '`'))
      W ''
      W ([string]$S.dth_addhint)
      W ''
    }
  }

  }   # end of the deaths section

  # ---- what they said -------------------------------------------------------
  # Eva overruled the earlier decision to count chat without reading it:
  # "I would have been happier if you looked and told me."
  if ($cant -notcontains 'chat') {
  W ([string]$S.h_chat)
  W ''
  if (@($h.chat).Count -eq 0) {
    W ([string]$S.chat_none)
  } else {
    W (FMT ([string]$S.chat_lead) $h.chatCount)
    W ''
    foreach ($c in (@($h.chat) | Select-Object -First $MaxChat)) {
      $at = $(if ($null -ne $c.at) { Format-RkHlClock -Minutes $c.at } else { '--:--' })
      W (FMT ([string]$S.chat_row) $at ([string]$c.who) ([string]$c.text))
    }
  }
  W ''

  }   # end of the chat section

  # ---- the interesting part -------------------------------------------------
  # Nothing here can be attributed without names, so a game that has none skips
  # the section rather than printing "nothing to report" every single day.
  if ($cant -notcontains 'name') {
  W ([string]$S.h_fun)
  W ''
  $any = $false

  if ($quests.Count -gt 0) {
    $any = $true
    $byWho = @{}
    foreach ($q in $quests) { if (-not $byWho.ContainsKey($q.who)) { $byWho[$q.who] = @() }; $byWho[$q.who] += [string]$q.what }
    foreach ($k in ($byWho.Keys | Sort-Object { -@($byWho[$_]).Count })) {
      W (FMT ([string]$S.fun_quest) $k @($byWho[$k]).Count ((@($byWho[$k]) | Select-Object -Unique) -join $SEP))
    }
  }

  if ($trainer.Count -gt 0) {
    $byWho = @{}
    foreach ($t in $trainer) { if (-not $byWho.ContainsKey($t.who)) { $byWho[$t.who] = 0 }; $byWho[$t.who]++ }
    $topT = @($byWho.Keys | Sort-Object { -$byWho[$_] })[0]
    if ($byWho[$topT] -ge 10) {
      $any = $true
      W (FMT ([string]$S.fun_rampage) $topT $byWho[$topT] ($trainer.Count - $byWho[$topT]))
    }
  }

  $worst = ''; $worstN = 0
  foreach ($k in $players.Keys) { if ([int]$players[$k].deaths -gt $worstN) { $worstN = [int]$players[$k].deaths; $worst = $k } }
  if ($worstN -ge 5) { $any = $true; W (FMT ([string]$S.fun_worst) $worst $worstN) }

  # Player-versus-player, which the cause table alone would hide inside
  # "was slain by <name>" - a name that happens to be on the roster.
  $pvp = @()
  foreach ($d in @($h.deathEvents)) {
    if ([string]$d.cause -match '\b(?:slain|killed|shot|blown up|impaled|skewered|pummeled) by ([A-Za-z0-9_]{3,16})$') {
      $killer = $Matches[1]
      if ($h.players.ContainsKey($killer)) { $pvp += ([string]$d.who + ' < ' + $killer) }
    }
  }
  if ($pvp.Count -gt 0) { $any = $true; W (FMT ([string]$S.fun_pvp) $pvp.Count (($pvp | Select-Object -Unique) -join $SEP)) }

  $rare = @($h.deaths.Keys | Where-Object { $h.deaths[$_] -eq 1 })
  if ($rare.Count -gt 0) {
    $any = $true
    $rareJa = @($rare | Select-Object -First 6 | ForEach-Object { (ConvertTo-RkCauseJa -Cause $_ -Causes $Causes).text })
    W (FMT ([string]$S.fun_rare) ($rareJa -join ' / '))
  }

  if ($roster.Count -gt 0) {
    $marathon = ''; $mMin = -1.0
    foreach ($k in $players.Keys) { if ([double]$players[$k].minutes -gt $mMin) { $mMin = [double]$players[$k].minutes; $marathon = $k } }
    if ($mMin -ge 120.0) { $any = $true; W (FMT ([string]$S.fun_marathon) $marathon (Format-RkSpanJa -Minutes $mMin -S $S)) }

    # THE BUSIEST MOMENT. A sweep over session boundaries: +1 on a join, -1 on
    # a leave. Sum of playtime says how much the server was used; this says
    # whether they were playing TOGETHER, which is a different question and the
    # one that matters for a server friends share.
    $marks = @()
    foreach ($k in $players.Keys) {
      foreach ($s2 in @($players[$k].sessions)) {
        $marks += @{ at = [double]$s2.from; d = 1 }
        $marks += @{ at = [double]$s2.to;   d = -1 }
      }
    }
    # -1 before +1 at the same instant, so a handover does not read as an
    # overlap that never existed.
    $marks = @($marks | Sort-Object @{Expression = { $_.at }}, @{Expression = { $_.d }})
    $cur = 0; $peak = 0; $peakAt = $null
    foreach ($m in $marks) {
      $cur += $m.d
      if ($cur -gt $peak) { $peak = $cur; $peakAt = $m.at }
    }
    if ($peak -ge 2) {
      $any = $true
      W (FMT ([string]$S.fun_together) $peak (Format-RkHlClock -Minutes $peakAt))
    }

    $firstIn = @($players.Keys | Where-Object { $null -ne $players[$_].firstSeen } | Sort-Object { [double]$players[$_].firstSeen })
    $lastOut = @($players.Keys | Where-Object { $null -ne $players[$_].lastSeen } | Sort-Object { -[double]$players[$_].lastSeen })
    if (($firstIn.Count -gt 0) -and ($lastOut.Count -gt 0)) {
      # Deliberately does NOT set $any: this line always prints when anybody
      # played, so counting it as a finding would make the "nothing to report"
      # branch below unreachable on exactly the days it exists for.
      W (FMT ([string]$S.fun_first) $firstIn[0] (Format-RkHlClock -Minutes ([double]$players[$firstIn[0]].firstSeen)) `
            $lastOut[0] (Format-RkHlClock -Minutes ([double]$players[$lastOut[0]].lastSeen)))
    }
  }

  # A quiet day still had SOMETHING in it if anybody earned anything. The
  # headline counted those advancements, so saying "nothing" three lines later
  # reads as a broken report rather than a quiet day.
  if ((-not $any) -and ($vanilla.Count -gt 0)) {
    $any = $true
    $byWho = @{}
    foreach ($v in $vanilla) { if (-not $byWho.ContainsKey($v.who)) { $byWho[$v.who] = @() }; $byWho[$v.who] += [string]$v.what }
    foreach ($k in ($byWho.Keys | Sort-Object { -@($byWho[$_]).Count })) {
      W (FMT ([string]$S.fun_quest) $k @($byWho[$k]).Count ((@($byWho[$k]) | Select-Object -Unique | Select-Object -First 6) -join $SEP))
    }
  }
  if (-not $any) { W ([string]$S.fun_none) }
  W ''

  }   # end of the interesting section

  # ---- what this GAME cannot tell you --------------------------------------
  # Separate from the method section on purpose. "Nobody died" and "this log
  # does not record deaths" are different facts, and a report that prints a
  # zero for the second one is lying. Valheim is the whole reason this exists:
  # five real logs contain a head count and nothing else.
  if ($cant.Count -gt 0) {
    W ([string]$S.h_cannot)
    W ''
    W ([string]$S.cannot_lead)
    W ''
    foreach ($c in $cant) {
      $key = 'cannot_' + [string]$c
      $txt = $(if ($S.PSObject.Properties.Name -contains $key) { [string]$S.$key } else { [string]$c })
      W (FMT ([string]$S.cannot_row) $txt)
    }
    W ''
    if ($h.game) { W (FMT ([string]$S.cannot_fix) ([string]$h.game)) ; W '' }
  }

  # ---- what this cannot tell you -------------------------------------------
  W ([string]$S.h_method)
  W ''
  foreach ($l in @($S.method)) { W ([string]$l) }
  if ($cant -notcontains 'name') { foreach ($l in @($S.method_players)) { W ([string]$l) } }
  W ''

  return $sb.ToString()
}
