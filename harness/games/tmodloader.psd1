# ============================================================
# tModLoader dedicated server (modded Terraria)
# ASCII only. Data only.
#
# LAYOUT RE-CHECKED 2026-09-12 against the real install (2026-08-27 first pass):
#   C:\Program Files (x86)\Steam\steamapps\common\tModLoader\
#     start-tModLoaderServer.bat   (3 lines: cd /D %~dp0, then
#                                   LaunchUtils/busybox-sh.bat ./start-tModLoaderServer.sh)
#     serverconfig.txt             (present, but every line except priority=1 is
#                                   commented out - no port and no world in it)
#     tModLoader-Logs\             server.log 237 KB, server2.log 222 KB,
#                                  client.log, environment-server*.log, Old\
#     DedicatedServerUtils\  LaunchUtils\  Libraries\  dotnet\  Content\
#     tModLoader.dll  start.bat  start-tModLoader.bat
#   NOT present: a Mods\ folder (see paths below).
#
# LAUNCH AND STOP ARE STILL NOT VERIFIED by respawnkeeper - it has never started
# or stopped this server. Everything marked 'inferred' below stays off.
#
# ---- Why paths.logFile is NOT set, even though a log file exists -----------
# tModLoader really does write tModLoader-Logs\server.log and rotate old ones
# into Old\ (measured: the file is there, 1,788 lines, full [tML] log lines with
# stack traces). The obvious template is "capture.stdout = $false, keep
# paths.logFile". That was tried on 2026-09-12 and it does NOT work here:
#
#   capture.stdout $true  + paths.logFile set  -> conflict capture-vs-external-redirect
#   capture.stdout $false + paths.logFile set  -> conflict stdin-without-console
#                                                 (stop.kind 'stdin' + launch.kind
#                                                 'script' needs the capture path)
#
# Both were measured with tests\Invoke-TemplateConformance.ps1, one FAIL each.
# The second one costs more: it takes away stop.kind = 'stdin', which is
# tModLoader's only documented clean stop ("exit" on the server console). Trading
# a working stop channel for a log file we can reach another way is the wrong
# trade - a stop that does not save is not recoverable.
#
# So respawnkeeper captures the console and that capture is the primary stream
# (<ServerDir>\respawnkeeper\console\console-<stamp>.log, one per run). The
# game's own tModLoader-Logs is still reachable: paths.logDir points at it and
# rk-logscan.ps1 reads logDir directly, so the daily scan still sees server.log.
#
# !! NOTE FOR WHOEVER REVISITS THIS: it is NOT established that everything in
# server.log also reaches stdout. That is the assumption this shape rests on, it
# is 'inferred', and one real run settles it - start the server under
# respawnkeeper and diff the captured console against server.log for the same
# run. If stdout turns out to be thinner, the right fix is a capabilities change
# (allow one game to have BOTH a captured console and a secondary log file), not
# a quiet edit here.
#
# ---- Detection order matters ----------------------------------------------
# A tModLoader folder also contains serverconfig.txt, so it could look like
# vanilla Terraria. It does NOT contain TerrariaServer.exe, which is what the
# terraria template requires - so the two never both match. If a future install
# breaks that assumption, the higher-scoring (more specific) template wins.
# ============================================================
@{
  id          = 'tmodloader'
  displayName = 'tModLoader dedicated server (modded Terraria)'

  verified = @{ layout = $true; launch = $false; stop = $false }
  verifiedNote = 'Layout checked against the Steam install on 2026-08-27 and re-checked on 2026-09-12 (log folder, config file, launch script and the absence of a Mods folder all confirmed by listing the real directory). Launch and stop have never been exercised by respawnkeeper.'

  # ---- Where every claim below came from ----------------------------------
  # measured = observed by running something and reading real output
  # human    = a person watched it happen
  # inferred = deduced from files, docs or a model's research. NOT evidence.
  #            Anything 'inferred' keeps its dependent features switched off.
  # Missing entries are read as 'inferred'.
  provenance = @{
    detect        = @{ by = 'measured'; on = '2026-09-12'; how = 'listed the Steam install directory; start-tModLoaderServer.bat, tModLoader-Logs and DedicatedServerUtils are all there' }
    logDir        = @{ by = 'measured'; on = '2026-09-12'; how = 'read tModLoader-Logs\server.log (237 KB, 1,788 lines) from a real 2026-08-23 server run' }
    settingsFile  = @{ by = 'measured'; on = '2026-09-12'; how = 'serverconfig.txt exists; read it - only priority=1 is uncommented, so no port and no world path can be taken from it' }
    launch        = @{ by = 'inferred'; on = '2026-09-12'; how = 'read start-tModLoaderServer.bat (it hands off to busybox-sh and start-tModLoaderServer.sh); never executed by respawnkeeper' }
    stop          = @{ by = 'inferred'; on = '2026-09-12'; how = '"exit" is the documented console command; never sent by respawnkeeper, and the path it would have to travel (bat -> sh -> dotnet) has not been shown to carry stdin' }
    processNames  = @{ by = 'inferred'; on = '2026-08-27'; how = 'the .sh starts dotnet; never matched against a running server' }
    cleanShutdown = @{ by = 'inferred'; on = '2026-09-12'; how = 'the phrases DO occur in a real server.log, but they do not mean what this field needs them to mean - see the evidence block' }
    exception     = @{ by = 'measured'; on = '2026-09-12'; how = 'the leading-whitespace "at Namespace.Method(...)" form matches the real stack traces in server.log (verified against the 2026-08-23 run)' }
  }

  detect = @{
    allOf = @('start-tModLoaderServer.bat')
    anyOf = @('tModLoader-Logs', 'tModLoader.dll', 'DedicatedServerUtils')
  }

  launch = @{ kind = 'script'; script = 'start-tModLoaderServer.bat' }

  # The console IS the stream respawnkeeper reads. See the header for why the
  # game's own server.log is not used as paths.logFile.
  capture = @{ stdout = $true }

  stop = @{ kind = 'stdin'; command = 'exit'; timeoutSec = 180 }
  broadcast = @{ kind = 'stdin'; format = 'say {0}' }

  # The .bat starts dotnet, so the process to watch is not the .bat.
  process = @{ names = @('dotnet', 'tModLoader'); matchCommandLine = $true }

  paths = @{
    # No logFile on purpose (header). logDir still points at the game's own logs
    # so rk-logscan can read them as a secondary source.
    logDir       = 'tModLoader-Logs'
    crashDirs    = @()
    settingsFile = 'serverconfig.txt'
    # No modsDir. It used to say 'Mods', which is a path relative to the server
    # directory - and there is no Mods folder there. Measured 2026-09-12: the
    # real one is outside the server directory entirely. The 2026-08-23 run
    # recorded its own launch parameters in server.log:
    #   -modpath C:\Users\<user>\Documents\My Games\Terraria\tModLoader\Mods
    # Test-RkPathClaim joins claims onto the server directory and has no way to
    # express that, so the honest value is no value: mod quarantine reports
    # itself unavailable instead of quarantining nothing and calling it done.
  }

  evidence = @{
    # !! MEASURED, AND MEASURED TO BE WRONG - left as-is on purpose, see below.
    #
    # All four phrases really do appear in the real server.log. The problem is
    # that three of them appear during a ROUTINE AUTOSAVE as well. From the
    # 2026-08-23 run, the autosave at 01:05:40 and the shutdown at 01:19:13 are
    # character-for-character the same four lines:
    #     Saving world data / Validating world save /
    #     Backing up world file / Saving modded world data
    # The only difference is the thread tag ([.NET TP Worker] vs [Main Thread]),
    # and one sample is not enough to promote that to a rule. "Server shutting
    # down" does not occur at all (0 hits in 1,788 lines).
    #
    # That means this regex reads a normal 10-minute autosave as a clean
    # shutdown. The consequence is the same one [R-071] found on Valheim: a real
    # crash gets recorded as "a human stopped it" and the server is not brought
    # back. It fails SAFE (nothing is restarted that should not be), and
    # provenance keeps everything that depends on it switched off anyway, so
    # nothing is running on this regex today.
    #
    # It is NOT corrected here because correcting it needs the one sample nobody
    # has: a transcript of a shutdown driven by the "exit" console command. The
    # only shutdown on record was an -autoshutdown ("Local player left") from a
    # Steam friends lobby. Guessing a narrower regex would just move the error to
    # "never matches a real stop", which fails the other way - restarting a
    # server somebody deliberately took down.
    cleanShutdown = 'Saving world data|Saving world|Server shutting down|Backing up world file'
    exception     = '(?m)^\s+at [\w\.<>`]+ ?\(.*\)|Unhandled Exception|System\.\w+Exception'
  }

  rules   = ''
  logscan = ''
}
