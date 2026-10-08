# ============================================================
# rk-capabilities.psd1 - what each respawnkeeper feature NEEDS from a template.
# ASCII only. Data only - loaded with Import-PowerShellDataFile.
#
# WHY THIS FILE EXISTS ([R-072], 2026-09-12)
#
# games\*.psd1 used to be a bag of optional fields. Nothing checked that a field
# was read, that a declared combination was possible, or that a feature had what
# it needed. The result on Valheim: a template that looked complete, was filled
# in carefully by hand, and still shipped
#   - a cleanShutdown regex that matched "ZNet Shutdown WITHOUT save"
#   - capture.stdout=true together with stop=close, which cannot both hold
#   - two fields (rules, logscan) that no code path has ever read
# and, worst of all, autoRepair was not tied to ANY verification flag, so the
# most autonomous preset stayed on for a game nobody had ever stopped by hand.
#
# So: every feature declares its requirements HERE, in one place. A feature whose
# requirements are unmet is turned OFF and SAID to be off. That last part is the
# whole point - the old failure mode was not "the feature stopped working", it
# was "the feature stopped working silently and the UI still showed a green row".
#
# ---- provenance ------------------------------------------------------------
# Every claim in a template carries WHERE IT CAME FROM. The Valheim template was
# "researched", and research produced a wrong regex that nobody could see was
# wrong. Research is not evidence.
#
#   measured - observed by actually running the thing and reading real output.
#              Trustworthy. Features may switch on.
#   human    - a person watched it happen and confirmed it (e.g. a clean stop
#              that saved the world). Trustworthy for things a machine cannot
#              see. Features may switch on.
#   inferred - deduced from folder layout, docs, decompiled strings, or a model's
#              research. NOT trustworthy on its own. Features stay OFF until the
#              item is promoted to measured or human.
#
# A missing provenance entry is read as 'inferred'. That is deliberate: the
# unstated case must be the cautious one.
# ============================================================
@{
  schema = 'respawnkeeper/capabilities/1'

  # ---- The vocabulary of requirements --------------------------------------
  # Each key is a requirement id. 'test' names how the checker decides whether a
  # template satisfies it; the checker implements these by id (see
  # tests\Invoke-TemplateConformance.ps1). 'why' is shown to the user verbatim
  # when a feature is switched off, so write it as a sentence a human can act on.
  requirements = @{

    launchOwned = @{
      test = 'launch.kind is one of script/exe/builtin AND the target exists'
      why  = 'respawnkeeper must be the thing that starts the server. It cannot attach to a process somebody else started.'
    }

    logStream = @{
      test = 'paths.logFile is set, OR capture.stdout is true'
      why  = 'there is no readable stream of what the server is saying, so nothing can be diagnosed from it.'
    }

    logFileStable = @{
      test = 'paths.logFile resolves to exactly one file, allowing a newest-match glob'
      why  = 'the log location is not resolvable to a single current file.'
    }

    exitCode = @{
      test = 'launch.kind is not attach-only'
      why  = 'the supervisor never sees the process exit, so it cannot tell a crash from a stop.'
    }

    crashArtifacts = @{
      test = 'paths.crashDirs is non-empty OR paths.jvmCrashGlob is set'
      why  = 'this game leaves no crash report behind, so a crash can only be inferred from the log tail.'
    }

    portProbe = @{
      test = 'the port is knowable (paths.settingsFile, launch script, or process.port) AND process.portProtocol is supported'
      why  = 'the listening port cannot be observed, so it cannot be used as evidence of life.'
    }

    processProbe = @{
      test = 'process.names is non-empty'
      why  = 'there is no process name to match, so process existence cannot be used as evidence.'
    }

    # The safety gate is the one place where ONE probe is not enough. A single
    # probe that goes wrong flips "running" to "stopped", and the gate then lets
    # a write through to a live server. See [R-071].
    twoLivenessProbes = @{
      test = 'at least TWO of: portProbe, processProbe, pidFileProbe'
      why  = 'only one independent way to tell whether the server is alive. One probe going wrong would let a repair write to a running server.'
    }

    pidFileProbe = @{
      test = 'the supervisor writes a pid file AND process.names can confirm the pid belongs to this game'
      why  = 'the recorded pid cannot be confirmed to still be this server.'
    }

    stopChannel = @{
      test = 'stop.kind is implemented AND is compatible with the capture mode'
      why  = 'there is no working way to ask this server to stop.'
    }

    broadcastChannel = @{
      test = 'broadcast.kind is set and compatible with the capture mode'
      why  = 'players cannot be warned before a scheduled stop.'
    }

    cleanShutdownEvidence = @{
      test = 'evidence.cleanShutdown is set AND its provenance is measured or human'
      why  = 'a clean shutdown cannot be told apart from a crash, so restarting could resurrect a server somebody deliberately took down - or fail to restart one that really died.'
    }

    exceptionEvidence = @{
      test = 'evidence.exception is set'
      why  = 'exceptions in the log cannot be recognised.'
    }

    readyEvidence = @{
      test = 'evidence.ready is set - the line this game prints when it has finished starting and is serving'
      why  = 'a process and a held port do not distinguish a server that is SERVING from one that is still loading. Valheim spends 113 seconds generating a world in exactly that state, and during it "still coming up" and "wedged" are the same reading from outside. Without this line the harness can only report that something of the right shape exists.'
    }

    connectEvidence = @{
      test = 'evidence.connect and evidence.disconnect are set, and both capture the player name'
      why  = 'joins and leaves are not recognisable, so the player list would always read zero.'
    }

    # Added 2026-09-12 after the UI work found the same disease one level down:
    # the lag scanner counts matches of a MINECRAFT phrase ("Running Nms behind").
    # Run that over a Valheim log and it finds zero - which is not "no lag", it is
    # "wrong ruler". Counting zero hits of a pattern the game never emits is
    # indistinguishable from a healthy server, which is exactly the failure this
    # whole file exists to stop.
    lagEvidence = @{
      test = 'evidence.lag is set for this game'
      why  = 'there is no known phrase this game uses to report falling behind, so slowness cannot be measured from the log. Zero matches would mean nothing.'
    }

    # Added 2026-09-15, and it is lagEvidence's twin one level up. lagEvidence
    # says "this game has no known phrase for falling behind". This one says
    # the daily scan does not know which of this game's lines are a COMPLAINT
    # at all. rk-logscan.ps1 falls back to log4j's severity tags, which is
    # correct for Minecraft and matched 0 of 1,613 lines across six real
    # Valheim logs - 239 of which say in the game's own words that something
    # failed. The report printed "WARN/ERROR: 0", which is also exactly what a
    # healthy day prints. Same disease as the lag scanner, same cure: make the
    # ruler belong to the game, and say out loud when there isn't one.
    levelEvidence = @{
      test = 'evidence.level is set for this game'
      why  = 'the daily scan does not know how this game words trouble, so it falls back to log4j severity tags. A game that does not tag its output would score zero complaints every day, which is indistinguishable from a quiet one.'
    }

    modsDir = @{
      test = 'paths.modsDir is set and exists'
      why  = 'the mod folder is unknown, so nothing can be quarantined.'
    }

    modDependencySource = @{
      test = 'mods.dependencySource is set (jar-manifest, thunderstore-manifest, ...)'
      why  = 'mod dependencies cannot be read, so removing one could break others.'
    }

    diagnosisRules = @{
      test = 'rules names a file that exists under rules\'
      why  = 'there is no crash rule table for this game, so causes cannot be identified - only that it died.'
    }
  }

  # ---- The features, and what each one needs -------------------------------
  # onUnmet:
  #   off      - the feature does not run at all, and says so.
  #   degraded - the feature runs with less evidence and must label its output
  #              as partial. It must NEVER present a missing measurement as a
  #              clean result. ("no lag recorded" while reading zero bytes is
  #              the bug this exists to prevent - see rk-vitals, [R-071].)
  features = @{

    crashDetect = @{
      label   = 'tell a crash apart from a stop'
      needs   = @('exitCode', 'logStream')
      wants   = @('crashArtifacts', 'cleanShutdownEvidence', 'exceptionEvidence')
      onUnmet = 'off'
    }

    # ADDED 2026-09-14 at Eva's instruction. The first thing to establish about
    # a new game is where its log comes from and how it is emitted; the second
    # is which line in it means "up". Everything that claims a server is running
    # rests on those two, so they are a feature of their own rather than a
    # footnote inside autoRestart.
    startupCheck = @{
      label   = 'confirm from the log that it actually came up'
      needs   = @('logStream', 'readyEvidence')
      wants   = @('exceptionEvidence')
      onUnmet = 'off'
      note    = 'without it, "started" means only that a process was created'
    }

    safetyGate = @{
      label   = 'refuse to touch a running server'
      needs   = @('twoLivenessProbes')
      onUnmet = 'off'   # off here means: refuse every write, not allow it.
      note    = 'This feature failing OPEN is the worst outcome in the whole harness. With its requirement unmet, every repair path must refuse rather than proceed.'
    }

    autoRestart = @{
      label   = 'bring the server back up by itself'
      needs   = @('launchOwned', 'stopChannel', 'crashDetect', 'cleanShutdownEvidence')
      wants   = @('startupCheck')
      onUnmet = 'off'
      # startupCheck is a WANT, not a NEED, on purpose. Making it a need would
      # switch autoRestart off for every game whose ready line nobody has
      # identified yet, which is a bigger change than the evidence supports
      # today - but a restart that cannot confirm the server came back is a
      # restart that can loop silently, so it is recorded as missing rather
      # than passed over.
    }

    autoRepair = @{
      label   = 'apply a reversible repair while the server is stopped'
      needs   = @('safetyGate', 'launchOwned')
      wants   = @('diagnosisRules', 'modsDir', 'modDependencySource')
      onUnmet = 'off'
      note    = 'Tied to safetyGate on purpose. Before [R-072] this was tied to nothing, which is how the unattended preset stayed on for an unverified game.'
    }

    hangWatch = @{
      label   = 'notice the server has gone quiet'
      needs   = @('logStream')
      onUnmet = 'off'
      note    = 'Must read the SAME stream the game actually writes. Reading a hardcoded logs\latest.log that a game never creates produces a watcher that can never fire - which looks exactly like a healthy server.'
    }

    dailyMaintenance = @{
      label   = 'scheduled stop, log review, restart'
      # broadcastChannel MOVED FROM wants TO needs, 2026-09-14. It was a want,
      # so it could not block, and the moment valheim's launch provenance was
      # promoted this feature came ON for a game whose own template says in as
      # many words: "No broadcast channel. The server reads no console commands
      # and exposes no admin socket, so a scheduled stop CANNOT warn the people
      # online. That is why dailyMaintenance must stay off for this game until
      # that changes." The file was right and the contract disagreed with it.
      #
      # A daily stop is the one automatic action whose cost lands on somebody
      # ELSE - the people in the world when it happens. Doing it without being
      # able to say a word first is not a degraded version of the feature, it
      # is a different and worse thing.
      needs   = @('autoRestart', 'broadcastChannel')
      onUnmet = 'off'
    }

    playerRoster = @{
      label   = 'who is online'
      needs   = @('logStream', 'connectEvidence')
      onUnmet = 'off'
      note    = 'Off must render as "not available for this game", never as an empty roster. An empty roster reads as "nobody is playing".'
    }

    vitals = @{
      label   = 'how the server is doing'
      needs   = @('logStream')
      wants   = @('lagEvidence')
      onUnmet = 'degraded'
      note    = 'Degraded means process-level facts only (uptime, memory). It must say which measurements are unavailable instead of implying they were taken and came back clean.'
    }

    modQuarantine = @{
      label   = 'isolate a mod that breaks startup'
      needs   = @('modsDir', 'modDependencySource', 'safetyGate')
      onUnmet = 'off'
    }

    logscan = @{
      label   = 'daily report of what the logs complained about'
      needs   = @('logStream')
      # levelEvidence added to wants 2026-09-15, NOT to needs. A want, because
      # the fallback still produces a correct report for any game that tags its
      # output the log4j way, and switching the whole feature off for the
      # others would lose the human half of the report (joins, deaths, chat)
      # along with the complaint count. What it must never do is stay silent:
      # as a want it appears as "runs with less than it wants", and rk-logscan
      # now prints which ruler it counted with next to the count itself.
      wants   = @('diagnosisRules', 'levelEvidence')
      onUnmet = 'off'
    }
  }

  # ---- Combinations that cannot both be true -------------------------------
  # The conformance checker rejects a template that declares any of these. Each
  # one is a real contradiction, not a style preference.
  conflicts = @(
    @{
      id   = 'capture-vs-window-close'
      when = 'capture.stdout is true AND stop.kind is close'
      why  = 'Capturing stdout requires launching the child with redirected handles, and such a process has no main window: MainWindowHandle is 0 and CloseMainWindow() returns false. Measured 2026-09-12. Use ctrlc for a console process whose output is being captured.'
    }
    @{
      id   = 'capture-vs-external-redirect'
      when = 'capture.stdout is true AND paths.logFile is set'
      why  = 'Both the launcher and respawnkeeper would claim the same stream. Decide one: either the launch script redirects to a file (set paths.logFile, capture.stdout false) or respawnkeeper captures it (capture.stdout true, no paths.logFile).'
    }
    @{
      id   = 'stdin-without-console'
      when = 'stop.kind is stdin AND capture.stdout is false AND launch.kind is script'
      why  = 'A stop command can only be written to a child whose stdin respawnkeeper holds. Launching a script that owns its own console leaves nothing to write to.'
    }
    @{
      id   = 'broadcast-without-stop-channel'
      when = 'broadcast.kind is set AND stop.kind does not provide the same channel'
      why  = 'Broadcasts go out over the same channel as stop commands. Declaring one without the other means the warning is silently dropped.'
    }
  )

  # ---- Fields that must actually be read by code ---------------------------
  # A field nobody reads is worse than a missing field: it looks configured.
  # The checker greps the harness for each of these and fails if a template sets
  # one that no code path consumes. 'rules' and 'logscan' were both dead when
  # this file was written; minecraft.psd1 pointed 'logscan' at a file that does
  # not exist and nothing noticed, because nothing read it.
  mustBeConsumed = @(
    'launch', 'capture', 'stop', 'broadcast', 'process', 'paths', 'evidence',
    'rules', 'logscan', 'verified', 'mods'
  )
}
