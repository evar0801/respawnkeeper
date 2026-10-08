# ============================================================
# Valheim dedicated server
# ASCII only. Data only.
#
# REWRITTEN 2026-09-12 ([R-071] / [R-072]). The previous version was written by
# inspecting the Steam install folder and it was wrong in three ways that the
# new conformance checker now catches:
#
#   1. capture.stdout = $true together with stop.kind = 'close'. Those cannot
#      both hold: a child launched with redirected stdout has no main window, so
#      CloseMainWindow() returns false. Measured 2026-09-12.
#   2. evidence.cleanShutdown matched the bare word 'Shutdown', which also
#      appears in "ZNet Shutdown WITHOUT save" - i.e. it read a world-losing
#      exit as a clean one.
#   3. It pointed at the Steam folder. The server is not actually run from
#      there.
#
# ---- WHAT THIS TEMPLATE NOW TARGETS ---------------------------------------
# The real instance directory is C:\Servers\valheim\, which
# holds the launcher, the save directory and the logs. The Valheim binary lives
# in the Steam folder and is invoked BY that launcher (it does a pushd), so the
# Steam folder is a dependency, not the server directory.
#
# start_everheim_server.bat already does three things that make this game behave
# like Minecraft, and they are the reason this template is workable at all:
#   - it redirects stdout AND stderr into logs\everheim_<timestamp>.log, so
#     there IS a log file and respawnkeeper does not need to capture anything
#   - it passes -savedir server\savedir, keeping this world away from the frozen
#     worlds_local set
#   - it reads the password from server_secret.txt, so nothing here ever sees a
#     credential (the stock Steam script hardcodes it on the command line; this
#     one does not)
#
# ---- STILL NOT VERIFIED ----------------------------------------------------
# The server has never been started under respawnkeeper, and as of 2026-09-12
# the dedicated server itself is 848 MB behind the client (appmanifest
# StateFlags 6), so it cannot currently accept a connection at all. Everything
# below whose provenance is 'inferred' is a reading of the shipped assembly or
# of the launcher script - NOT an observation of a running server. Features that
# depend on those items stay off until somebody promotes them. See the
# provenance block and lib\rk-capabilities.psd1.
#
# ---- STOPPING: never force-kill -------------------------------------------
# Valheim saves on a graceful shutdown request and does NOT save when killed.
# stop.kind = 'close' dispatches Request-RkClose, which asks the window to close
# and falls back to a console Ctrl+C - the method the launcher itself documents.
# The supervisor never escalates to a forced kill on its own, because the cost
# of getting that wrong is somebody's world rolled back to the last autosave.
# ============================================================
@{
  id          = 'valheim'
  displayName = 'Valheim dedicated server (Everheim instance)'

  verified = @{ layout = $true; launch = $true; stop = $true }
  # PROMOTED 2026-09-13 ([R-086]). What earned it, in order:
  #
  #   1. The Everheim instance itself - its own launcher, its own savedir, its
  #      own world - was started and stopped by respawnkeeper. Not a copy, not a
  #      throwaway world. That was the one thing every earlier note said was
  #      missing.
  #   2. A HUMAN drove it. Eva pressed the maintenance-restart button and
  #      watched the lap: 13:38:36 requested -> 13:38:42 the server was gone ->
  #      13:38:57 it was running again.
  #   3. The world was written, not just the process ended:
  #      'World save (5/5) done. Total time [54ms]' at 13:38:37, and
  #      savedir\worlds_local\Everheim\_main.3.db2 / .fwl2 / .ok all stamped
  #      13:38:37 on disk.
  #   4. Get-RkShutdownEvidence read that run back as verdict=clean,
  #      cleanShutdownLogged=True - so the machine agrees with the human.
  #   5. The stop path is now covered by a test that reproduces this game's
  #      SHAPE, not Minecraft's: tests\fixtures\games\wrappergame.psd1 + L5,
  #      where the launcher outlives the server ([R-085]).
  #
  # Two defects were found and fixed between the first attempt and this one
  # ([R-082] the wait watched the wrapper, [R-084] the wait after it had no
  # bound). Both were found BY watching a real stop, which is exactly what this
  # flag is supposed to certify - so it is being flipped on the strength of the
  # run that found them, after they were fixed and re-run clean.
  #
  # What flipping it changes TODAY: nothing on its own. It lifts the blanket
  # gate; this server's profile still has autoRestart=false, so nothing starts
  # itself until Eva says so separately.
  verifiedNote = 'Layout checked 2026-09-12. Stop and launch PROMOTED 2026-09-13 [R-086]: the Everheim instance itself (own launcher, own savedir, own world) was started and stopped through respawnkeeper with Eva watching - forced maintenance restart at 13:38:36, server gone 13:38:42, running again 13:38:57. World save (5/5) done [54ms] and _main.3.db2/.fwl2/.ok all written 13:38:37; evidence read back verdict=clean. The launcher-outlives-the-server shape is now covered by tests\fixtures\games\wrappergame.psd1 (Invoke-LiveTest L5). Still true: BepInEx is NOT installed, this instance runs vanilla, Steam buildid 25253791.'

  # ---- Where every claim below came from ----------------------------------
  # measured = observed by running something and reading real output
  # human    = a person watched it happen
  # inferred = deduced from files, scripts or decompiled strings. NOT evidence.
  #            Anything 'inferred' keeps its dependent features switched off.
  # Missing entries are read as 'inferred'.
  #
  # !! THE ENTRIES BELOW OUTRANK verified. Get-RkConfReqProvenance reads this
  # block FIRST and only falls back to the verified flags when a field has no
  # entry here - so an entry left at 'inferred' does not merely fail to help,
  # it OVERRIDES a promotion somebody made on the strength of a real run.
  # [R-086] flipped verified.launch and verified.stop to $true on 2026-09-13 and
  # did not touch this block; the template went on reporting 0 features on /
  # 9 blocked while its own header described the run that earned them, and
  # nothing warned, because each half was internally consistent. There is now a
  # conformance check for exactly that pair (kind 'ledger-contradiction').
  # If you promote a verified flag, come here in the same edit.
  provenance = @{
    detect          = @{ by = 'measured'; on = '2026-09-12'; how = 'listed the real instance directory' }
    # PROMOTED 2026-09-13, recorded 2026-09-14. Eva pressed the panel's
    # maintenance-restart button on the Everheim instance and respawnkeeper
    # launched it through this very script four times (watchdog.log 13:18:11,
    # 13:37:23, 13:38:57, and the run measured on 09-14). The old text here
    # said "never executed by respawnkeeper", which stopped being true the
    # moment [R-086] was written.
    launch          = @{ by = 'human';    on = '2026-09-13'; how = 'Eva pressed maintenance-restart; respawnkeeper started the server through start_everheim_server.bat and logged it (watchdog.log 13:18:11 / 13:37:23 / 13:38:57)' }
    # The old text said "no run has produced one yet (logs\ holds only
    # .gitkeep)". Four now exist, the glob resolved to the newest one, and
    # Get-RkShutdownEvidence read a verdict back out of it - which is the whole
    # capability, exercised end to end, not just a file sitting there.
    logFile         = @{ by = 'measured'; on = '2026-09-13'; how = 'logs\everheim_20260913_{112915,131812,133724,133858}.log written by real runs; the newest-match glob resolved and Get-RkShutdownEvidence parsed verdict=clean out of it' }
    # POSITIVE CONTROL, 2026-09-14. Everything before this was the ABSENCE of
    # the server ("no probe reported it alive" at the moment it stopped), which
    # is not evidence that a probe can ever find it - the shape of mistake
    # the project notes (live-verification) is about. So the server was started and
    # watched WHILE RUNNING: valheim_server pid 22416 held UDP 2456, both probes
    # fired, and Get-RkServerLiveness returned alive on every one of ~30 samples.
    # 2456 ONLY. The launcher also uses 2457, and that one has never been
    # observed - it is not probed either, so nothing rests on it.
    port            = @{ by = 'measured'; on = '2026-09-14'; how = 'UDP 2456 observed BOUND by valheim_server pid 22416 throughout a real run (positive control, 155 alive samples). Port 2457 is used by the game and has NOT been observed' }
    # Deliberately not "the TCP probe sees nothing at any time" - that is a
    # universal negative from one run. What was measured is the one direction.
    portProtocol    = @{ by = 'measured'; on = '2026-09-14'; how = 'the bind was found in the UDP table; the TCP table showed nothing for 2456 during the same run' }
    processNames    = @{ by = 'measured'; on = '2026-09-14'; how = 'Get-Process -Name valheim_server returned pid 22416 throughout the run; Get-RkServerLiveness reported alive from it' }
    # !! NOT PROMOTED, and it cannot be. The pid file holds the pid of whatever
    # respawnkeeper started, and for launch.kind='script' that is the LAUNCHER:
    # measured 2026-09-14, server.pid pointed at cmd while the game ran as a
    # grandchild. The probe therefore proves the wrapper is alive, which is a
    # different question - [R-084] is the bug that came from confusing the two.
    # There is deliberately NO 'pidFile' entry: the resolver looks pidFileProbe
    # up under process.names, so an entry by that name would be read by nobody
    # and would only look configured. The fact is expressed where it can act -
    # Test-RkConfRequirement now returns met=$false for pidFileProbe whenever
    # launch.kind is 'script', which is the honest count for THIS game and for
    # palworld too.
    stop            = @{ by = 'measured'; on = '2026-09-12'; how = 'a console Ctrl+C was fired at a running server; it shut down and WROTE THE WORLD TO DISK. Measured on a copy with a throwaway world, NOT on the Everheim instance - see verified.stop' }
    cleanShutdown   = @{ by = 'measured'; on = '2026-09-12'; how = 'taken from a 225-line transcript of a real Ctrl+C shutdown. The previous guess, read out of assembly strings, matched ZERO lines' }
    exception       = @{ by = 'measured'; on = '2026-09-12'; how = 'tightened after the old pattern produced 4 false positives in a HEALTHY boot (Unity prints stack frames for unsupported shaders when headless)' }
    savedir         = @{ by = 'measured'; on = '2026-09-12'; how = '-savedir was honoured: the server logged the path and wrote worlds_local\<name>.db underneath it, leaving the frozen world set untouched' }
    connect         = @{ by = 'inferred'; on = '2026-09-12'; how = 'strings extracted from assembly_valheim.dll' }
    # THE ONE THAT UNBLOCKS dailyMaintenance (2026-09-23). Not "the mod was
    # built" and not "the file was dropped" - the server SAID IT SAID IT, in
    # its own log, with the text that was sent.
    broadcast       = @{ by = 'measured'; on = '2026-09-15'; how = '09/15/2026 11:13:34 "[RKB1] cmd-ok kind=say text=..." in logs\everheim_20260915_111013.log, after a .txt was dropped in console-in\ (the file is still in console-in\done\). The same log''s up line names the inbox: inbox=C:\Servers\valheim\respawnkeeper\console-in' }
    # TWO matches per log, not one: the pattern is a two-marker alternation and
    # each marker appears once. The first version of this line said "exactly one
    # match", which is what a reader would go and re-check and find wrong.
    ready           = @{ by = 'measured'; on = '2026-09-14'; how = 'both markers present in each of five real logs (2 matches per log, one each); timed against the probes on 09-14 - probes said alive 13:28:06, the log said ready 13:28:25' }
    # ADDED 2026-09-15. Every alternative in evidence.level was taken from a
    # line that is actually in the six real dedicated-server logs, by
    # collapsing every run of digits and counting distinct shapes: 239 of
    # 1,613 lines match, against 0 for the log4j default the scanner used
    # before. The only alternatives with no hits HERE are the BepInEx and
    # HarmonyX severity tags, and those were measured in the client and
    # verification-server logs of 2026-09-14 instead - recorded that way on
    # purpose rather than quietly counted as if this server had produced them.
    level           = @{ by = 'measured'; on = '2026-09-15'; how = 'profiled all six logs in server\logs\; 239/1613 lines match, 0/1613 matched the log4j default. The [Error:]/[Warning:] alternatives were measured in the BepInEx logs (backup\LogOutput_*_20260914.log.gz) and have zero hits on this server, which has no BepInEx' }
    # 'rules' is what the diagnosisRules requirement reads. Six of the seven
    # rules are verbatim strings from real failures logged on this machine on
    # 2026-09-14; the seventh is from our own server log of 09-13. Two further
    # rules were drafted and deleted for having no real failure behind them.
    rules           = @{ by = 'measured'; on = '2026-09-15'; how = 'rules\crash-rules-valheim.psd1 - every pattern copied from a real failure (BepInEx/HarmonyX logs of 2026-09-14, and everheim_20260913_112915.log for the missing-world-file rule). No invented patterns: see the deletions recorded in that file header' }
  }

  # Matches both shapes a Valheim instance takes here: the wrapper directory
  # (start_everheim_server.bat + savedir) and a stock Steam install
  # (valheim_server.exe). Detection is deliberately the broad step; the strict
  # step is Test-RkGameTemplate, which re-checks every claim against the folder
  # and says exactly which one is missing.
  detect = @{
    allOf = @('*_server.bat')
    anyOf = @('valheim_server.exe', 'valheim_server_Data', 'server_secret.txt.example', 'savedir')
  }

  # Launch the script, never a reconstructed command line. The script owns the
  # password, the world name, the save directory and the log redirect; rebuilding
  # those here would mean two places to edit and one of them would rot.
  launch = @{ kind = 'script'; script = 'start_everheim_server.bat' }

  # FALSE on purpose: the launcher already redirects both streams to a file.
  # Setting this true as well would mean two owners for one stream - see the
  # 'capture-vs-external-redirect' conflict in lib\rk-capabilities.psd1.
  capture = @{ stdout = $false }

  # 'ctrlc', not 'close'. Measured 2026-09-12: the server runs -nographics
  # -batchmode and has NO window, so WM_CLOSE has nothing to arrive at; 'close'
  # only ever reached this server by silently falling through to its Ctrl+C
  # fallback. Declaring what actually happens is the whole point of the template.
  #
  # Keep the timeout generous. In the measured run the shutdown was not instant:
  # a 60-second observation window expired with the process still alive, and the
  # clean exit (world written, sockets torn down) landed after that. Escalating
  # to a kill at 60s would have destroyed exactly what waiting preserved.
  stop = @{ kind = 'ctrlc'; timeoutSec = 180 }

  # THE BROADCAST CHANNEL, AND WHY IT IS NOT THE STOP CHANNEL (2026-09-23).
  #
  # Until 2026-09-15 this block said: "No broadcast channel. The server reads no
  # console commands and exposes no admin socket, so a scheduled stop CANNOT
  # warn the people online." Every word of that is still true OF THE VANILLA
  # SERVER. What changed is that the server is no longer vanilla: RkBridge
  # ([R-101]) is a BepInEx plugin that watches respawnkeeper's own console-in
  # folder and says what it finds there in-game.
  #
  # 'bridge' is therefore its own kind, NOT a second name for stdin:
  #   - it does not ride the stop channel, so the usual rule (broadcast.kind
  #     must equal stop.kind) does not apply - there is no shared pipe to share
  #   - it is a FILE DROP: one command per .txt in <ServerDir>\respawnkeeper\
  #     console-in\, which is the exact path the plugin resolves for itself
  #     (measured: "inbox=C:\...\valheim\respawnkeeper\console-in" in its up line)
  #   - it only works if the plugin is actually loaded, which is why readyLine
  #     exists: the plugin announces itself once per boot, and that line is the
  #     only honest proof the channel is there. A declaration alone would light
  #     dailyMaintenance for a server that cannot say a word - which is the
  #     [R-071] mistake with a different name.
  broadcast = @{
    kind      = 'bridge'
    format    = 'say {0}'
    readyLine = '\[RKB1\] up '
  }

  process = @{
    names            = @('valheim_server')
    matchCommandLine = $false
    port             = 2456          # +1 is used as well
    portProtocol     = 'udp'
  }

  paths = @{
    # A NEW FILE PER RUN, so this has to be a newest-match glob. There is no
    # fixed 'latest.log' equivalent.
    logFile   = 'logs\everheim_*.log'
    logDir    = 'logs'
    saveDir   = 'savedir'
    # Valheim writes no crash report of its own. A crash can only be read from
    # the tail of the captured log, which is exactly why crashArtifacts is
    # unmet for this game.
    #
    # ---- LOOKED AT PROPERLY 2026-09-15 AND DELIBERATELY LEFT EMPTY ---------
    # It is not quite true that nothing is written. Every boot logs 'Setting
    # breakpad minidump AppID = 892970', and Steam's breakpad really does
    # produce dumps on this machine - C:\Program Files (x86)\Steam\dumps holds
    # real ones (assert_terraria.exe_20260819034235_1.dmp and two others). So
    # the mechanism exists and could in principle be pointed at.
    #
    # Three reasons it is still @( ):
    #   1. That folder is SHARED BY EVERY STEAM GAME. The dumps in it right now
    #      are Terraria's. Pointed at as-is, a Terraria crash from three weeks
    #      ago would be reported as a Valheim crash report - a false positive
    #      that reads exactly like a true one.
    #   2. Get-RkCrashDirs does Join-Path $ServerDir $rel, so an absolute path
    #      does not resolve at all today. Setting one would look configured and
    #      do nothing, which is the failure this whole template layer exists to
    #      stop.
    #   3. The path is machine-specific - Steam's install location is not a
    #      property of the GAME - and a template is a game definition, not
    #      machine config. Hardcoding it here would break the one thing that
    #      makes these files worth having.
    #
    # And the payoff is small: a native minidump is not something respawnkeeper
    # can read. It would upgrade "the log tail shows an exception" to "the log
    # tail shows an exception and a .dmp exists". crashDetect already runs on
    # the log tail, which for this game carries the real evidence.
    #
    # If it is ever worth closing: resolve the dumps folder at runtime (Steam's
    # registry key, or from the launcher's SERVER_DIR) rather than in data, and
    # filter by process.names so only *valheim_server*.dmp counts.
    crashDirs = @()
  }

  # ---- CORRECTED 2026-09-13 -------------------------------------------------
  # An earlier note here said the instance "is driven by an r2modman profile".
  # That is the PLAN, not the state. Measured 2026-09-13: the dedicated server
  # install has NO BepInEx folder, so the Everheim instance currently runs
  # VANILLA. What is present is the BepInEx pack's loader shell only -
  # winhttp.dll, doorstop_config.ini, doorstop_libs, start_*_bepinex.sh - whose
  # target_assembly (BepInEx\core\BepInEx.Preloader.dll) does not exist, so
  # nothing is injected. server\SERVER_SETUP.md says the same ("BepInEx not
  # installed, vanilla, confirmed") and step 4 of that document is the copy that
  # has not been done. The r2modman profiles (Evar, Everheim_1.0) are on the
  # CLIENT side.
  #
  # This matters for verified.stop: the plugin set is the biggest difference
  # between the measured Ctrl+C run and production, and right now that
  # difference DOES NOT EXIST. Re-check this before promoting, and re-open the
  # question the day BepInEx is actually installed here - a plugin that throws
  # in OnApplicationQuit turns a clean stop into a hang.
  #
  # Mods, when they do arrive, are BepInEx plugins and do NOT live under the
  # server directory as respawnkeeper understands it: they go under the Steam
  # install (...\steamapps\common\Valheim dedicated server\BepInEx\plugins\),
  # which is a dependency of this ServerDir, not part of it.
  #
  # There is deliberately NO 'mods' block here. One was written on 2026-09-12 and
  # removed the same day, because Invoke-TemplateConformance immediately caught
  # that no code path reads $Template.mods - it would have been a fourth dead
  # field, and a dead field is worse than a missing one because it looks
  # configured. paths.modsDir is likewise absent, which is what makes the whole
  # mod-removal path report itself unavailable instead of guessing.
  # Wire a real consumer first; only then describe the layout in data.

  # ---- MEASURED 2026-09-12 ---------------------------------------------------
  # One real run of valheim_server.exe (a copy, throwaway world, -public 0),
  # stopped with a console Ctrl+C. 225 lines of transcript. What that run taught:
  #
  #   * The patterns previously guessed from assembly strings were WRONG.
  #     'World save (5/5) done' and 'done. Total time' appear ZERO times in a
  #     real transcript. The string exists in the binary; the server does not
  #     print it. Reading strings out of an assembly is not evidence.
  #
  #     !! AND THEN THE BUILD CHANGED (2026-09-13). After the 848 MB Steam
  #     update to buildid 25253791, a real shutdown of the real instance prints
  #     'World save (5/5) done. Total time [99ms]' exactly ONCE and does NOT
  #     print 'World saved' at all - the precise OPPOSITE of what was measured
  #     the day before. The save pipeline was rewritten: the world is now a
  #     DIRECTORY (savedir\worlds_local\<name>\_main.1.db2 / .fwl2 / .chunk),
  #     not a single <name>.db file.
  #     So "measured" has a shelf life, and the thing it is measured against is
  #     the BUILD. What saved this template is that cleanShutdown was
  #     deliberately built from network and scene teardown rather than from save
  #     messages - all four of its markers still matched, unchanged, across the
  #     update. Structural markers outlived the build; save markers did not.
  #   * 'Game - OnApplicationQuit' IS printed, exactly once, at shutdown. The one
  #     half of the old guess that happened to be right.
  #   * A Ctrl+C shutdown DOES save the world: 'World save writing finished' ->
  #     'World saved ( 19.3719ms )' -> RkVerify.db written to disk. So Ctrl+C is
  #     a real clean stop for this game, not a kill.
  #   * !! The old exception pattern had FOUR false positives in a HEALTHY run.
  #     A headless Unity server prints ordinary '  at UnityEngine...' stack
  #     frames for every unsupported shader at startup (no GPU). Matching bare
  #     stack frames means "this server crashes every single boot".
  #
  # Deliberately NOT used as clean-shutdown markers, even though each appeared
  # exactly once here: 'World saved', 'World save writing finished'. Those are
  # SAVE markers and a periodic autosave prints them too - this run was only six
  # minutes, shorter than the autosave interval, so "once" proves nothing about
  # them. Picking them would repeat the tModLoader mistake (an autosave read as a
  # clean stop). The markers below are network/scene teardown, which structurally
  # cannot happen while the server is still serving.
  evidence = @{
    # THE LINE THAT MEANS "PEOPLE CAN JOIN NOW". This game is the reason the
    # field exists. Measured 2026-09-14 with the real server running: the
    # process appeared and UDP 2456 was bound at 13:28:06, and the log did not
    # say 'Opened Steam server' until 13:28:25 - NINETEEN SECONDS in which both
    # liveness probes read alive and nobody could have connected. On a first
    # world generation that window is 113 seconds ([R-076]), which is how the
    # first stop measurement came to be taken against a server that had not
    # finished starting.
    #
    # 'Opened Steam server' and 'Game server connected' each appear EXACTLY ONCE
    # in all five real logs (11:29, 13:18, 13:37, 13:38 on 09-13 and 13:28 on
    # 09-14), in that order, right after 'Registering lobby'. Both are network
    # bring-up, so neither can be printed by a server that is still loading.
    # 'Done generating locations' - suggested in an earlier note - appears ZERO
    # times in all five, and was checked before being discarded.
    ready         = 'Opened Steam server|Game server connected'
    cleanShutdown = 'Game - OnApplicationQuit|Net scene destroyed|Stopping listening socket|Sending disconnect msg'
    # Requires an actual exception, not just an indented stack frame.
    exception     = 'Unhandled Exception|NullReferenceException|IndexOutOfRangeException|InvalidOperationException|System\.\w+Exception'
    # STILL INFERRED: no client connected during the measured run, so these two
    # have never been seen. They also carry no capture group for the player name,
    # which is why playerRoster stays unavailable rather than showing zero.
    connect       = 'Got connection SteamID|Got handshake from client'
    disconnect    = 'Closing socket|Peer disconnected'

    # ---- ADDED 2026-09-15: WHICH LINES ARE A COMPLAINT --------------------
    # rk-logscan.ps1 used to decide this with one hardcoded constant,
    # '\b(WARN|WARNING|ERROR|SEVERE|FATAL|CRITICAL)\b'. That is log4j's
    # vocabulary. A Valheim dedicated server tags nothing at all - the "log" is
    # the launcher's stdout redirect - so that constant matched 0 of 1,613
    # lines across the six real Everheim logs, while 239 of those lines say in
    # the game's own words that something failed. The daily report printed
    # "WARN/ERROR: 0", which is what a perfectly healthy day also looks like.
    #
    # Every alternative below was taken from those six logs:
    #   [Error : ...] / [Warning: ...]  BepInEx and HarmonyX tag their own
    #                                   lines. ZERO hits today (no BepInEx is
    #                                   installed here) - measured in the
    #                                   CLIENT and verification-server logs,
    #                                   and included so the day BepInEx lands
    #                                   the scanner does not go blind again.
    #   Exception                       not \b-bounded on purpose:
    #                                   MissingMethodException has no word
    #                                   break before it.
    #   fail / failure / missing        'AsyncResourceUpload failed.' (12),
    #                                   'Failed to place all X' (23),
    #                                   'Failed to play intro cinematic' (6),
    #                                   '... is missing!' (78),
    #                                   'Missing audio clip' (6)
    #   not supported                   the headless shader and HDR lines (54)
    #   took more than N seconds        slow world generation (18)
    #   Saving is blocked               the free-space guard printed on every
    #                                   save (8). Not a complaint - it is the
    #                                   only free-space signal this game gives,
    #                                   and a folded 'notable' row carrying the
    #                                   real numbers is worth one line a day.
    #
    # Case is written out rather than using (?i), because rk-logscan matches
    # with -cnotmatch and a blanket fold would widen this beyond what was
    # measured.
    #
    # Most of what this now catches is headless-Unity noise, which is the
    # point: rules\logscan-valheim.psd1 folds it into one 'benign' line each,
    # and anything NOT in that table is listed in full as unknown. Unknown is
    # the interesting case; it just could not exist while the count was zero.
    # !! FOUR ALTERNATIVES WERE ADDED AFTER MEASURING, NOT BEFORE. The first
    # version of this pattern was written from the profile of what the logs
    # contain, and it left FOUR of the thirteen rules in
    # rules\logscan-valheim.psd1 unreachable - including the single most
    # important one, 'isModded: False'. The rules were correct and the ruler
    # never handed them a line, so they scored zero and looked like rules for
    # things that never happen.
    #
    # That is a two-layer version of the same blindness this field exists to
    # fix, and it is only visible if you check the layers TOGETHER. The check
    # is in the project notes (per-game-log-vocabulary): for each rule, count lines in
    # the raw log vs lines that survive this pattern. inLog > 0 and reached = 0
    # means a dead rule. Run it whenever either layer changes.
    #
    #   isModded: False            the vanilla/modded verdict, 6 hits. Only
    #                              False is listed: True is the desired state,
    #                              not a complaint.
    #   take a long time to ...    the world-gen slow summary, 1 hit
    #   BLoggedOn                  the Steam client interface line, 8 hits
    #   custom render path shader  12 of the 72 headless shader lines, which
    #                              the 'not supported' alternative missed
    #
    # ---- ADDED 2026-09-15 (second measurement) --------------------------
    #   \[RKB1\] (up|mods)   the two lines RkBridge prints once per boot.
    #                        Neither is a failure, and both belong in the
    #                        report anyway:
    #                          up   ... patches=4/4   did every hook attach?
    #                          mods ... refused=2     what did NOT load?
    #                        Measured on the real server 2026-09-15 11:10:33
    #                        and 11:13:34. Without this the lines sit in the
    #                        log and nothing reads them - which is how 2 mods
    #                        being absent stayed invisible.
    level         = '\[\s*(Error|Warning|Fatal)\s*:|Exception|\b([Ff]ail(ed|ure|s)?|[Mm]issing)\b|not supported|custom render path shader|took more than [0-9.]+ seconds|take a long time to generate|Saving is blocked|isModded:\s*False|BLoggedOn|\[RKB1\] (up|mods) '
  }

  # ---- FILLED IN 2026-09-15 -------------------------------------------------
  # These were both '' and the comment said empty was the honest value:
  # diagnosis would report "the server died" and nothing more, rather than
  # falling through to the Minecraft tables, which name jars, mixins and Forge.
  # That was right while nothing had been measured about how THIS game fails.
  #
  # It is no longer right. Real failures of this game now exist on this machine
  # in writing, so the honest value is a table built from them:
  #
  #   crash-rules-valheim.psd1   7 rules. One from our own dedicated-server
  #                              logs (the missing world file on first boot);
  #                              six taken verbatim from the BepInEx/HarmonyX
  #                              failures logged on 2026-09-14 while Everheim's
  #                              preloader shims were being built. Every rule
  #                              is scope='log' (this game writes no crash
  #                              report, so a scope='report' rule could never
  #                              fire) and every rule is autoFixable=$false
  #                              (QUARANTINE_MOD moves a *.jar out of
  #                              paths.modsDir, and this game has neither).
  #
  #   logscan-valheim.psd1       13 rules over the real log vocabulary. The
  #                              chronic section leads with 'isModded: False',
  #                              which is this game telling you, once per boot,
  #                              that nothing was injected into it.
  #
  # Both files record where each rule came from, and two drafted rules were
  # deleted for having no real failure behind them - the reasons are kept in
  # the crash table's header so nobody re-adds them.
  rules   = 'crash-rules-valheim.psd1'
  logscan = 'logscan-valheim.psd1'
}
