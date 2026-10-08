# ============================================================
# Palworld dedicated server
# ASCII only. Data only.
#
# LAYOUT VERIFIED 2026-08-27 against the real install at C:\Servers\palworld:
#   palserver\PalServer.exe
#   palserver\Pal\Saved\{Config,Logs,SaveGames}
#   scripts\{start-server,stop-server,restart-server,watchdog,backup-server,admin}.ps1
#
# LAUNCH AND STOP ARE NOT VERIFIED by respawnkeeper - starting or stopping that
# server is the operator's call, so this template has never been exercised.
#
# ---- Why this template DELEGATES instead of reimplementing -----------------
# The operator already wrote a complete, careful ops suite for this server, and it
# encodes two things that would be dangerous to re-derive:
#
#  1. THE PROCESS NAME MUST BE AN EXACT MATCH.
#       server = PalServer-Win64-Shipping-Cmd   (note the -Cmd)
#       client = Palworld-Win64-Shipping        (the game somebody is playing)
#     A wildcard search kills the player's client. That warning is written in
#     C:\Servers\palworld\scripts\stop-server.ps1 in red, and it is copied here so
#     nobody "simplifies" it later.
#
#  2. FORCE-KILLING LOSES THE LAST SAVE. The correct stop is REST API
#     announce -> save -> shutdown, with a kill only as a last resort. That
#     script reads AdminPassword out of PalWorldSettings.ini and never prints
#     it. respawnkeeper calling the script means respawnkeeper never touches
#     the admin password at all - which is the point.
#
# ---- !! THAT SUITE INCLUDES ITS OWN WATCHDOG --------------------------------
# scripts\watchdog.ps1 runs from the scheduled task "PalworldWatchdog" (State
# Ready as of 2026-08-27) and brings the server back on its own, using
# logs\intentional_stop.flag to tell "the operator stopped it" from "it fell over".
# That is a SECOND SUPERVISOR, exactly like fc8's FC8WatchdogHeartbeat.
# respawnkeeper refuses to run against a server that still has one armed.
# ============================================================
@{
  id          = 'palworld'
  displayName = 'Palworld dedicated server'

  verified = @{ layout = $true; launch = $false; stop = $false }
  verifiedNote = 'Layout checked against C:\Servers\palworld on 2026-08-27. Launch and stop delegate to the operator existing scripts and have NOT been run by respawnkeeper - the first run needs a human watching.'

  detect = @{
    allOf = @('palserver\PalServer.exe')
    anyOf = @('palserver\Pal\Saved', 'scripts\start-server.ps1')
  }

  launch = @{ kind = 'script'; script = 'scripts\start-server.ps1' }

  # Palworld prints to its console and the shipped Pal\Saved\Logs folder was
  # EMPTY on the real install - there is no log file to read, so respawnkeeper
  # captures the console itself or it has no evidence at all.
  capture = @{ stdout = $true }

  stop = @{ kind = 'script'; script = 'scripts\stop-server.ps1'; timeoutSec = 180 }

  process = @{ names = @('PalServer-Win64-Shipping-Cmd'); matchCommandLine = $false }

  paths = @{
    logDir       = 'logs'
    crashDirs    = @('palserver\Pal\Saved\Crashes')
    modsDir      = 'palserver\Mods'
    configDir    = 'palserver\Pal\Saved\Config\WindowsServer'
    settingsFile = 'palserver\Pal\Saved\Config\WindowsServer\PalWorldSettings.ini'
    saveDir      = 'palserver\Pal\Saved\SaveGames'
  }

  # Unreal Engine wording. Unverified against a real Palworld shutdown - marked
  # so, and the supervisor treats "no evidence either way" as "do not restart".
  evidence = @{
    cleanShutdown = 'LogExit: Exiting|Log file closed|Shutdown|LogWindows: FPlatformMisc::RequestExit'
    exception     = 'Fatal error|LogWindows: Error:|Assertion failed|=== Critical error ==='
  }

  # A second supervisor for this game. rk-setup and the supervisor both check it.
  conflicts = @{
    scheduledTasks = @('PalworldWatchdog')
    scripts        = @('scripts\watchdog.ps1')
    note           = 'the operator own Palworld watchdog. Two supervisors would restart the server underneath each other.'
  }

  rules   = ''
  logscan = ''
}
