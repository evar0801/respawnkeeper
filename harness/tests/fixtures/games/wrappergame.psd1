@{
  # ============================================================
  # wrappergame - a THROWAWAY game template. Not a game anybody plays.
  # ASCII only (PS 5.1 decodes BOM-less files as ANSI).
  #
  # WHY THIS EXISTS ([R-084]).
  #
  # Both suites only ever drove Minecraft, whose launch.kind is 'builtin': the
  # process respawnkeeper starts IS the server. Everything about stopping was
  # therefore tested in the one shape where "the launched process exited" and
  # "the server is gone" mean the same thing.
  #
  # They do not mean the same thing for a SCRIPT launch. There the launched
  # process is a wrapper - cmd.exe running a .bat - and the game is its
  # grandchild. Stop the game and the wrapper can outlive it, which on Windows
  # is the normal outcome of a Ctrl+C: cmd.exe holds at "Terminate batch job
  # (Y/N)?" until a human answers.
  #
  # Two defects came out of that gap on real hardware, three days apart, with
  # both suites green the whole time:
  #   [R-082]  Wait-RkStopped watched the wrapper, so a clean stop was reported
  #            as "did not exit within 180s".
  #   [R-084]  the fix reported correctly and then the NEXT line, an unbounded
  #            WaitForExit on that same wrapper, hung the supervisor forever.
  #
  # This template reproduces the shape with no game installed and nothing real
  # at risk. It is NOT in harness\games on purpose - it is reached only through
  # respawnkeeper.ps1 -GamesDir, which no ordinary run passes.
  #
  # The sandbox that goes with it is built by Invoke-LiveTest.ps1 (L5):
  #   fakegame.exe      a copy of cmd.exe, so the process has a name of its own
  #                     and an image path inside the server folder
  #   start-fake.bat    starts fakegame.exe as a GRANDCHILD, then holds - this
  #                     is the wrapper that outlives the server
  #   game-loop.bat     what fakegame.exe runs: waits for GAME_STOP, logs a
  #                     clean shutdown line, exits
  #   stop-fake.ps1     drops GAME_STOP. Touches the wrapper not at all.
  # ============================================================
  id          = 'wrappergame'
  displayName = 'wrapper-launch test fixture (NOT a real game)'

  # Verified by construction: this fixture's whole purpose is to exercise the
  # stop path, and it is built fresh by the test every run.
  verified     = @{ layout = $true; launch = $true; stop = $true }
  verifiedNote = 'Test fixture. Built by tests\Invoke-LiveTest.ps1 L5 immediately before use; never points at anything installed.'

  detect = @{
    allOf = @('fakegame.exe')
    anyOf = @('start-fake.bat', 'game-loop.bat')
  }

  launch  = @{ kind = 'script'; script = 'start-fake.bat' }
  # The game writes its own log, exactly like Valheim. Capturing stdout here
  # would ALSO capture the wrapper's, and then "the log went quiet" would stop
  # being evidence about the game.
  capture = @{ stdout = $false }

  # A .ps1 because Request-RkStop runs stop scripts with `powershell -File`
  # whatever their extension - a .bat here would fail to launch and the test
  # would be measuring the wrong thing.
  stop = @{ kind = 'script'; script = 'stop-fake.ps1'; timeoutSec = 60 }

  # The whole point: liveness must find the GRANDCHILD by name, never the
  # wrapper. fakegame.exe lives inside the server folder, so the attribution
  # layer resolves it by exe-path - the strong answer, no guessing.
  process = @{ names = @('fakegame'); matchCommandLine = $false }

  paths = @{
    logDir  = 'logs'
    logFile = 'logs\fake-*.log'
  }

  evidence = @{
    cleanShutdown = 'fake server: clean shutdown'
    exception     = 'fake server: EXPLODED'
  }

  rules   = ''
  logscan = ''
}
