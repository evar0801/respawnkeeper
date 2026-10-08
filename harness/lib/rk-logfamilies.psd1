# ============================================================
# rk-logfamilies.psd1 - where a game's log is, guessed from what BUILT it.
# ASCII only. Data only.
#
# WHY THIS FILE EXISTS (Eva, 2026-09-14):
#   "games differ in how they emit logs, where their directories are, what
#    libraries they use - so pattern that by the language and the OS, make a
#    guess like 'this pattern would be here', go and look, and when you find it,
#    keep it per game as strategy notes. I thought that was the golden pattern."
#
# It is. Finding Valheim's log took a day of hand work and the answer turned out
# to be a property of UNITY, not of Valheim: a headless Unity server writes no
# log file of its own, so somebody has to redirect it, so the log is wherever
# the launch script put it - which is why the template's logFile is a glob with
# a timestamp in it. Every Unity game lands in the same place. Minecraft's
# answer is a property of LOG4J. Palworld's is a property of UNREAL.
#
# So the engine is the unit of reuse, and the per-game file (games\*.psd1) stays
# the record of what was actually FOUND. This table only says where to look.
#
# ---- READ THIS BEFORE ADDING A FAMILY --------------------------------------
# A guess that is treated as an answer is worse than no guess. Nothing here is
# ever written into a template automatically: rk-logscout reports candidates, a
# human picks, and the pick is verified against the folder by
# Test-RkGameTemplate before it counts.
#
# 'by' says how the entry was established:
#   measured - a real FOLDER of this family on this machine was read
#   inferred - the engine's documented or conventional layout, not seen here
# An 'inferred' family still gets searched; it just does not get to sound sure.
# !! Reading another TEMPLATE is not "measured". That mistake was made once here
# and corrected on 2026-09-14 (dotnet-console).
#
# ---- ORDER AND SPECIFICITY -------------------------------------------------
# The first family whose markers hold wins, so ORDER IS PART OF THE DATA. Three
# of these have no markersAll, so "most specific first" is not enforced by the
# shape of the file and has to be maintained by hand. Use markersAnyMin when one
# marker is too weak on its own: 'unreal' matched a bare '*Server.exe' and stole
# TerrariaServer.exe and tModLoaderServer.exe from the family that had actually
# been measured on them (found by adversarial review, 2026-09-14).
# ============================================================
@{
  schema = 'respawnkeeper/logfamilies/2'

  families = @(

    @{
      id    = 'java-log4j'
      label = 'Java server using log4j (Minecraft and its loaders)'
      by    = 'measured'
      how   = 'fc8 (Forge 1.20.1) and pokemoncraft (NeoForge 1.21.1) on this machine; ready line confirmed in logs\latest.log and in three archived boots'
      # markersAll USED TO BE @('libraries'), which is a modern-Forge/NeoForge
      # detail, not a Java-server one. Vanilla, Fabric, Spigot and pre-1.17
      # Forge have no root libraries\, so an ordinary Minecraft server came back
      # UNKNOWN. Measured 2026-09-14: server.jar + server.properties +
      # logs\latest.log matched nothing. The two folders that made it look
      # right were the only two ever tested, and they both happen to have one.
      markersAll = @()
      markersAny = @('server.properties', 'libraries', 'logs\latest.log', '*.jar')
      logGlobs   = @('logs\latest.log', 'logs\server.log', 'logs\*.log')
      # Present, proves the family, and is NOT the file to read.
      notTheLog  = @('debug.log', 'logs\debug.log')
      crashDirs  = @('crash-reports')
      crashGlobs = @('hs_err_pid*.log', 'replay_pid*.log')
      readyHints = @('Done \([0-9.]+s\)! For help')
      emit       = 'the game writes the file itself; stdout is a duplicate of it'
      note       = 'log4j rolls latest.log daily, so a server up past midnight has a latest.log with no startup lines in it. Measured, not theoretical - see Get-RkServerReadiness.'
    }

    @{
      id    = 'unity-headless'
      label = 'Unity dedicated server run with -nographics -batchmode'
      by    = 'measured'
      how   = 'Valheim dedicated server on this machine (2026-09-12..14): no log file of its own, launcher redirect, per-run filename'
      markersAll = @()
      markersAny = @('*_Data', 'UnityPlayer.dll', 'UnityCrashHandler64.exe')
      # !! A HEADLESS UNITY SERVER WRITES NO LOG FILE UNLESS TOLD TO. Its output
      # goes to the console it was started in, so the log is wherever whoever
      # wrote the launch script sent it - and the commonest shape by far is a
      # redirect with a timestamp in the name, which is why the globs are broad
      # and the launcher is worth reading before any of them.
      logGlobs   = @('logs\*.log', 'log\*.log', 'Logs\*.log', '*.log')
      notTheLog  = @()
      crashDirs  = @()
      crashGlobs = @('crash.dmp', 'error.log')
      readyHints = @()
      emit       = 'NOT written by the game. Either the launch script redirects it, or -logFile <path> is passed, or respawnkeeper has to capture stdout itself.'
      launcherFlags = @('-logFile', '-nographics', '-batchmode')
      note       = 'Read <name>_Data\app.info (two lines: Company, Product) for the LocalLow path. Valheim''s server shares IronGate/Valheim with the CLIENT, so that file is the wrong one to read - it is a trap, not a target.'
    }

    @{
      id    = 'dotnet-console'
      label = '.NET console server (Terraria, tModLoader)'
      # DOWNGRADED 2026-09-14. This said 'measured', and its own 'how' described
      # reading games\tmodloader.psd1 - a template, not a folder. The file's own
      # definition of measured is "a real folder of this family was read", so the
      # entry was claiming a level its receipt did not support, and the report
      # prints the "never been seen on this machine" caveat only when the level
      # is not measured. It was getting to sound certain for free.
      by    = 'inferred'
      how   = 'taken from games\tmodloader.psd1 and games\terraria.psd1, which were themselves written against real folders. No .NET server folder has been read by this table.'
      # BEFORE unreal on purpose: both can match a *Server.exe.
      markersAll = @()
      markersAny = @('TerrariaServer.exe', 'tModLoader.dll', 'tModLoader-Logs', '*.runtimeconfig.json', 'serverconfig.txt')
      logGlobs   = @('tModLoader-Logs\*.log', 'Logs\*.log', 'logs\*.log')
      notTheLog  = @()
      crashDirs  = @()
      crashGlobs = @('client-crashlog.txt', 'server-crashlog.txt')
      readyHints = @()
      emit       = 'usually stdout only. tModLoader is the exception and writes tModLoader-Logs\server.log.'
      note       = 'Vanilla Terraria writes nothing. If nothing is found, that IS the finding: the template must set capture.stdout and let respawnkeeper own the stream.'
    }

    @{
      id    = 'unreal'
      label = 'Unreal Engine dedicated server'
      by    = 'inferred'
      how   = 'the palworld template on this machine names <Game>\Saved\Crashes and <Game>\Saved\Config, which is the Unreal Saved\ layout. The Logs sibling has NOT been observed here.'
      markersAll = @()
      # TWO of these, not one. A bare '*Server.exe' used to be enough and it
      # matched TerrariaServer.exe and tModLoaderServer.exe; it has been removed
      # outright, and two of the remaining structural markers are required.
      markersAny = @('*\Binaries\Win64', '*\Saved\Config', '*\Saved\SaveGames', '*\Saved\Logs', '*\Saved\Crashes')
      markersAnyMin = 2
      logGlobs   = @('*\Saved\Logs\*.log', 'Saved\Logs\*.log', 'logs\*.log')
      notTheLog  = @()
      crashDirs  = @('Saved\Crashes')
      crashGlobs = @()
      readyHints = @()
      emit       = 'the engine writes <Game>\Saved\Logs\<Game>.log and also mirrors it to stdout'
      # !! CONTRADICTED BY THIS REPO'S OWN NOTE, and both statements are shipped
      # in the same run: harness\hooks\newgame-prompt.md records that Palworld's
      # Pal\Saved\Logs is EMPTY. Until somebody looks at a live Unreal server,
      # treat 'the engine writes it' as the guess it is labelled as.
      note       = 'The game folder under the install root carries the project name, so the Saved path has a variable segment - match it with a wildcard. NOT OBSERVED HERE: newgame-prompt.md records Palworld''s Pal\Saved\Logs as empty, so this family may need capture.stdout after all.'
    }
  )

  # Tried for every folder, after the family's own globs and never instead.
  genericGlobs = @(
    'logs\*.log', 'log\*.log', 'Logs\*.log', '*.log',
    'server\logs\*.log', 'data\logs\*.log'
  )

  # Ranked last even when no family was detected. Without this, a vanilla
  # Minecraft folder (family UNKNOWN) whose debug.log was touched after
  # latest.log put debug.log FIRST - measured 2026-09-14.
  demoteAlways = @('debug.log', 'stderr.log', 'stdout.log', 'launcher.log', 'crash.log')

  # Looks like a log, is not the server's own output. Matched against BOTH the
  # relative path and its leaf: these are bare filenames and the candidates are
  # relative paths, so 'logs\debug.log' -like 'debug.log' is False and the whole
  # list used to miss everything inside a subfolder - which is where logs live.
  neverTheLog = @(
    'steamapps\*', 'steam_*.log', 'content_log.txt', 'connection_log*.txt',
    '*.log.gz', '*.log.[0-9]*'
  )
}
