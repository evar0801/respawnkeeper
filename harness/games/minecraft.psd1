# ============================================================
# Minecraft dedicated server (Forge 1.20.1 / NeoForge 1.21.1)
# ASCII only. Data only - loaded with Import-PowerShellDataFile.
#
# The reference template: this is the one respawnkeeper was built against, and
# the only one whose launch and stop paths have actually been exercised
# end to end (self-test, real java process, 2026-08-26/27).
#
# Note for anyone writing another template: Minecraft is the ODD ONE OUT in
# writing logs\latest.log. Most game servers print to the console and leave no
# file behind - see capture.stdout in the other templates.
# ============================================================
@{
  id          = 'minecraft'
  displayName = 'Minecraft dedicated server (Forge / NeoForge)'

  verified = @{ layout = $true; launch = $true; stop = $true }
  verifiedNote = 'End to end against a real java process in the self-test, and -CheckOnly against both live installs (fc8 Forge 1.20.1 / pokemoncraft NeoForge 1.21.1), 2026-08-27.'

  detect = @{
    allOf = @('libraries')
    anyOf = @('libraries\net\neoforged\neoforge', 'libraries\net\minecraftforge\forge')
  }

  # 'builtin' because the launch command is genuinely computed, not fixed: the
  # loader version decides win_args.txt, and the Minecraft version decides which
  # Java major is required (1.20.1 -> 17, 1.21.1 -> 21). See Resolve-RkLaunch.
  launch = @{ kind = 'builtin'; builtin = 'minecraft' }

  # The server keeps its own console window and writes logs\latest.log, so there
  # is nothing for respawnkeeper to capture.
  capture = @{ stdout = $false }

  stop = @{ kind = 'stdin'; command = 'stop'; timeoutSec = 120 }
  broadcast = @{ kind = 'stdin'; format = 'say {0}' }

  # java.exe alone would match every Java program on the machine, so the
  # supervisor additionally matches the loader path and version on the command
  # line (Get-RkServerLiveness). Windows does not expose a process working
  # directory, so that is as precise as it gets - and why nothing is ever killed.
  # portProtocol is stated even though tcp is the default: leaving it implicit is
  # how Valheim ended up being probed over TCP when it only ever speaks UDP.
  process = @{ names = @('java.exe'); matchCommandLine = $true; portProtocol = 'tcp' }

  paths = @{
    logFile      = 'logs\latest.log'
    logDir       = 'logs'
    crashDirs    = @('crash-reports')
    jvmCrashGlob = 'hs_err_pid*.log'
    modsDir      = 'mods'
    configDir    = 'config'
    settingsFile = 'server.properties'
    # The set players download. AutoModpack syncs this to clients, so a jar in
    # here is not merely a server file: removing it stops friends connecting
    # until they re-sync. Used as a veto by Test-RkModRemovable.
    distributedModsDir = 'automodpack\host-modpack\main\mods'
  }

  evidence = @{
    # THE LINE THAT MEANS "PEOPLE CAN JOIN NOW". Added 2026-09-14: a held port
    # and a live java process are true for the whole of a modded boot, which on
    # pokemoncraft is 19-31 seconds of a server nobody can connect to. Measured
    # from three real boots (logs\debug-3/4/5.log.gz): 'Done (31.456s)! For
    # help, type "help"' / (27.555s) / (19.319s), once each, from
    # net.minecraft.server.dedicated.DedicatedServer. The elapsed time varies so
    # the digits are a class, and the '!' and the parens are escaped because
    # this is a regex, not a substring.
    ready         = 'Done \([0-9.]+s\)! For help'
    cleanShutdown = 'Stopping server|Saving worlds|All chunks are saved|Stopping the server|All dimensions are saved'
    exception     = '(?m)^\s+at [\w\.$]+\(.*\)|Exception in server tick loop|java\.lang\.\w+(Error|Exception)'
  }

  # 2026-09-12 ([R-071]): this said 'logscan-minecraft.psd1', which has never
  # existed under rules\. Nothing noticed for the same reason nothing noticed the
  # field at all - no code path reads it; rk-logscan.ps1 hardcodes its rules
  # file. A field nobody reads is worse than a missing one: it looks configured.
  # Corrected to the file that actually exists. tests\Invoke-TemplateConformance
  # now fails on both mistakes.
  rules   = 'crash-rules.psd1'
  logscan = 'logscan-rules.psd1'

  # ---- Where every claim above came from ----------------------------------
  # measured = observed by running something and reading real output
  # human    = a person watched it happen
  # inferred = deduced from files or research. NOT evidence; keeps dependent
  #            features switched off. Missing entries are read as 'inferred'.
  # This is the reference template, so almost everything here is measured: it is
  # the only game whose launch and stop paths have been exercised end to end.
  provenance = @{
    detect        = @{ by = 'measured'; on = '2026-08-27'; how = '-CheckOnly against both live installs (fc8 Forge 1.20.1, pokemoncraft NeoForge 1.21.1)' }
    launch        = @{ by = 'measured'; on = '2026-08-27'; how = 'self-test starts a real java process through the real argfile path' }
    logFile       = @{ by = 'measured'; on = '2026-09-12'; how = 'logs\latest.log exists and is read on both live installs' }
    port          = @{ by = 'measured'; on = '2026-09-12'; how = 'server-port read from server.properties; 25565 on both installs' }
    portProtocol  = @{ by = 'measured'; on = '2026-09-12'; how = 'observed LISTENING via Get-NetTCPConnection' }
    processNames  = @{ by = 'measured'; on = '2026-08-27'; how = 'matched against the live java process plus loader path on the command line' }
    stop          = @{ by = 'measured'; on = '2026-08-27'; how = 'stdin "stop" exercised end to end in the self-test' }
    cleanShutdown = @{ by = 'measured'; on = '2026-08-27'; how = 'taken from real shutdown transcripts, not guessed' }
    exception     = @{ by = 'measured'; on = '2026-08-27'; how = 'matched against real crash logs in the rule table' }
    # The pattern was FOUND in debug-*.log.gz, but the harness reads
    # logs\latest.log - a different appender - so the receipt names the file the
    # code actually opens. Checked there too: exactly one match.
    ready         = @{ by = 'measured'; on = '2026-09-14'; how = 'one match in the live pokemoncraft logs\latest.log (the file paths.logFile names), and once in each of three archived boots (debug-3/4/5.log.gz: 19.319s / 27.555s / 31.456s), always from DedicatedServer and always after mod loading' }
  }
}
