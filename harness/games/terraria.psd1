# ============================================================
# Terraria dedicated server (vanilla TerrariaServer.exe)
# ASCII only. Data only.
#
# LAYOUT VERIFIED 2026-08-27 against the real install:
#   ...\steamapps\common\Terraria\
#     TerrariaServer.exe
#     serverconfig.txt   (the shipped example config, with every switch documented)
#
# LAUNCH AND STOP ARE NOT VERIFIED by respawnkeeper.
#
# ---- serverconfig.txt carries the password --------------------------------
# Terraria's config file holds `password=` and the world path. This template
# points the server at that file with -config and reads NOTHING out of it, so
# the password never reaches respawnkeeper. Same rule as Valheim: let the game's
# own configuration stay the only place the secret lives.
#
# ---- Stopping ---------------------------------------------------------------
# TerrariaServer takes commands on its console; `exit` saves the world and shuts
# down. That is the clean stop. A forced kill loses everything since the last
# autosave, so the supervisor never escalates to one on its own.
#
# ---- No log file -------------------------------------------------------------
# Vanilla Terraria's server prints to the console and writes no log (crashlog.txt
# only appears if it crashes). capture.stdout is on.
# ============================================================
@{
  id          = 'terraria'
  displayName = 'Terraria dedicated server (vanilla)'

  verified = @{ layout = $true; launch = $false; stop = $false }
  verifiedNote = 'Layout checked against the Steam install on 2026-08-27. Launch/stop never exercised by respawnkeeper.'

  detect = @{
    allOf = @('TerrariaServer.exe')
    anyOf = @('serverconfig.txt', 'Content')
  }

  launch = @{
    kind = 'exe'
    exe  = 'TerrariaServer.exe'
    args = @('-config', 'serverconfig.txt')
  }

  capture = @{ stdout = $true }

  stop = @{ kind = 'stdin'; command = 'exit'; timeoutSec = 120 }
  broadcast = @{ kind = 'stdin'; format = 'say {0}' }

  process = @{ names = @('TerrariaServer'); matchCommandLine = $false }

  paths = @{
    crashDirs    = @()
    configDir    = ''
    settingsFile = 'serverconfig.txt'
  }

  evidence = @{
    cleanShutdown = 'Saving world data|Saving world|Server shutting down|Backing up world file'
    exception     = '(?m)^\s+at [\w\.<>`]+ ?\(.*\)|Unhandled Exception|System\.\w+Exception'
  }

  rules   = ''
  logscan = ''
}
