# ============================================================
# Core Keeper dedicated server
# ASCII only. Data only.
#
# !! UNVERIFIED - NOTHING IN THIS FILE HAS BEEN CHECKED AGAINST A REAL INSTALL.
#
# Core Keeper's dedicated server is a SEPARATE Steam tool from the game. On this
# machine only the client is installed (steamapps\common\Core Keeper\ holds
# CoreKeeper.exe and CoreKeeper_Data, and no server binary), so there was no
# folder to check these claims against.
#
# That is fine, and it is why the template layer verifies before it trusts:
# Test-RkGameTemplate re-checks every path claim against the actual folder, and
# a template whose markers are not there is REJECTED, not used with a warning.
# So the worst this file can do is fail to match - at which point rk-setup falls
# through to rk-newgame.ps1 and generates a template from the real folder.
#
# If you install the server and this template does match, treat the first run as
# an experiment: rk-setup will force the 'manual' policy (watch only, never
# repair, never restart) for any game whose launch path is unverified.
#
# What to fix once there IS a real folder to look at:
#   - the executable name and how it takes the world id / save path
#   - whether it writes a log file or only prints to the console (capture.stdout)
#   - what a clean shutdown actually prints
#   - whether Ctrl+C really is a saving stop (see the stop block below)
#
# ---- 2026-09-12: the one thing that WAS wrong on paper -------------------
# This file used to declare capture.stdout = $true together with stop.kind =
# 'close'. Those cannot both hold. Capturing stdout means launching the child
# with redirected handles, and such a child has no main window: MainWindowHandle
# is 0 and CloseMainWindow() returns False (measured 2026-09-12). So the declared
# stop channel could never once have run - every stop would have silently fallen
# through to the Ctrl+C branch hidden inside Request-RkClose.
#
# Nothing about the GAME was learned by fixing that; it was a contradiction
# inside this file, caught by tests\Invoke-TemplateConformance.ps1 without any
# folder being looked at. stop.kind is now 'ctrlc', which names what would have
# happened anyway. Everything here stays 'inferred' and every dependent feature
# stays off - "we corrected the paperwork" is not "we verified the server".
# ============================================================
@{
  id          = 'corekeeper'
  displayName = 'Core Keeper dedicated server'

  verified = @{ layout = $false; launch = $false; stop = $false }
  verifiedNote = 'DRAFT. Written 2026-08-27 with no install to check against - only the Core Keeper CLIENT is present on this machine. Every claim here is a guess and the verifier will reject it unless the real folder happens to agree. The 2026-09-12 stop.kind change resolved a contradiction on paper only; no Core Keeper server has ever been started, stopped or observed by respawnkeeper.'

  # ---- Where every claim below came from ----------------------------------
  # measured = observed by running something and reading real output
  # human    = a person watched it happen
  # inferred = deduced from files, scripts or docs. NOT evidence. Anything
  #            'inferred' keeps its dependent features switched off.
  # Missing entries are read as 'inferred' too - this block is written out in
  # full anyway, so that "nobody has checked any of this" is visible rather
  # than implied by absence.
  provenance = @{
    detect        = @{ by = 'inferred'; on = '2026-08-27'; how = 'the dedicated server is a separate Steam tool and is not installed here; file names come from its documentation' }
    launch        = @{ by = 'inferred'; on = '2026-08-27'; how = 'no binary exists on this machine to run' }
    stop          = @{ by = 'inferred'; on = '2026-09-12'; how = 'Ctrl+C is the usual stop for a Unity headless server; never exercised against Core Keeper' }
    processNames  = @{ by = 'inferred'; on = '2026-08-27'; how = 'derived from the expected executable name; never observed running' }
    cleanShutdown = @{ by = 'inferred'; on = '2026-08-27'; how = 'guessed Unity/ Core Keeper phrases; never seen in a real shutdown transcript' }
    exception     = @{ by = 'inferred'; on = '2026-08-27'; how = 'standard .NET / Unity exception shape' }
  }

  detect = @{
    allOf = @('CoreKeeperServer.exe')
    anyOf = @('CoreKeeperServer_Data', 'ServerConfig.json')
  }

  launch = @{ kind = 'exe'; exe = 'CoreKeeperServer.exe'; args = @('-batchmode', '-nographics') }

  # Core Keeper writes no log of its own, so the console IS the only evidence
  # there is. paths.logFile is deliberately absent: declaring both would mean two
  # owners for one stream (conflict 'capture-vs-external-redirect').
  capture = @{ stdout = $true }

  # Ctrl+C, NOT window close. Capturing stdout above is exactly what takes the
  # window away, so 'close' is not available to this template - see the header.
  # Ctrl+C reaches every process sharing the console, including the shell the
  # supervisor was started from; that is a property of the Windows mechanism and
  # is documented at Send-RkCtrlC in respawnkeeper.ps1.
  stop = @{ kind = 'ctrlc'; timeoutSec = 180 }

  process = @{ names = @('CoreKeeperServer'); matchCommandLine = $false }

  paths = @{
    logDir       = 'logs'
    crashDirs    = @()
    settingsFile = 'ServerConfig.json'
  }

  evidence = @{
    cleanShutdown = 'Shutting down|World saved|Saving world|OnApplicationQuit'
    exception     = '(?m)^\s+at [\w\.<>`]+ ?\(.*\)|Unhandled Exception|NullReferenceException'
  }

  rules   = ''
  logscan = ''
}
