@{
  # ============================================================
  # What a Valheim dedicated server's log says about the people on it.
  #
  # IMPORTANT: MEASURED ANSWER: ALMOST NOTHING. Five real Everheim logs were profiled
  # on 2026-09-14 (everheim_20260913_* and everheim_20260914_*). Collapsing
  # every number, the entire vocabulary is Unity engine noise, world saves, and
  # ONE line about people:
  #
  #     Connections 0 ZDOS:2144  sent:0 recv:0        (4 occurrences)
  #
  # There is no join line, no chat, no achievement and no death message,
  # because Valheim is a Unity server that writes no log of its own - what is
  # in this file is stdout, redirected by the launcher.
  #
  # SO THIS TEMPLATE IS THE POINT OF THE EXERCISE. The report has to degrade:
  # say what this game CAN answer, and say plainly that the rest is not in the
  # log - which is a different statement from "nobody died today".
  # ============================================================

  schema = 'respawnkeeper/events/1'
  game   = 'valheim'

  # Both markers appear exactly once per boot in each of five real logs
  # (the same pair the readiness check uses, [R-096]).
  boot = 'Opened Steam server|Game server connected'

  # Valheim's launcher stamps its own prefix - '09/14/2026 16:55:06:  ' -
  # instead of log4j's '[...]: '. Measured on the real line, two spaces and all.
  #
  # ---- WIDENED 2026-09-15: THE PREFIX CHANGES THE DAY BepInEx ARRIVES -------
  # The optional bracket group is not decoration. With BepInEx installed, the
  # same lines come out through its logger and the prefix grows a tag in front
  # of the date:
  #
  #     09/12/2026 14:27:32: Connections 4                    (vanilla)
  #     [Info   : Unity Log] 09/12/2026 14:27:32: Connections 4   (BepInEx)
  #
  # Both shapes are real and both are on this machine: the vanilla one in
  # server\logs\everheim_*.log, the BepInEx one in
  # docs\research\_verify\*.log, which is the verification server the Everheim
  # work runs against.
  #
  # Without the optional group, installing BepInEx would strip nothing, every
  # '^'-anchored rule below would stop matching, and the report would say the
  # server had nobody on it - silently, with no error anywhere, on the exact
  # day the server finally becomes the thing it is named after. That is the
  # same failure the per-game preamble was invented to fix (Valheim's own
  # prefix has no ']: ', so every log4j-shaped pattern missed), one build
  # later.
  preamble = '^(\[[^\]]*\]\s*)?\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}:\d{2}:\s*'

  rosterFrom = @()
  notPlayer  = ''

  rules = @(
    # THE ONE VERIFIED LINE. Valheim prints its own population every few
    # minutes, which answers "was anybody on, and how many at once" without
    # naming anyone. Tier 2 of the report, for free.
    @{ kind = 'population'; re = '^Connections (\d+)\b'; count = 1 }
  )

  deathVerbs = @()
  idleCauses = @()
  nameShape  = '^[A-Za-z0-9_ -]{2,24}$'

  # Printed by the report, in these words, instead of a zero.
  cannotAnswer = @('name', 'death', 'chat', 'achievement')

  # ---- NOT RUN. Candidates, kept where the next person will find them -------
  # Valheim is documented to log 'Got connection SteamID <id>' and
  # 'Got character ZDOID from <name> : <id>:<n>' when somebody joins, with
  # ZDOID 0:0 reportedly meaning a death. NONE OF IT IS IN OUR LOGS, because
  # nobody has connected to this server yet, so none of it is verified and none
  # of it is in 'rules' above - a regex nobody has seen fire is a guess.
  #
  # TO PROMOTE: have one person connect once, die once, and leave. Then grep
  # the log for their character name, move the lines that actually appeared
  # into 'rules', and drop the kinds they cover from 'cannotAnswer'.
  candidates = @(
    @{ kind = 'join';  re = '^Got character ZDOID from (.+) : (?!0:0)'; who = 1 }
    @{ kind = 'death'; re = '^Got character ZDOID from (.+) : 0:0$';    who = 1 }
    @{ kind = 'leave'; re = '^Closing socket (\d+)$' }
  )

  # ---- NOT RUN EITHER. The other way to get these lines: emit them ourselves.
  #
  # The three candidates above are VANILLA's wording, and vanilla's wording has
  # a shelf life: the Steam update of 2026-09-13 reversed this game's save
  # messages overnight ('World saved' gone, 'World save (5/5) done' new). A
  # reader built on the game's phrasing is a reader the game can break without
  # telling anybody.
  #
  # So valheim-work\dev\RkBridge is a small server-side BepInEx plugin that
  # prints the events in a shape WE own, with a version number in the prefix.
  # Built and compiling as of 2026-09-15; NEVER RUN, because the server it
  # belongs on has no BepInEx yet. Hence: candidates, not rules.
  #
  # It also solves the thing no amount of log-reading can: it watches
  # <ServerDir>\respawnkeeper\console-in\ and broadcasts 'say <text>' in game.
  # That is the missing broadcastChannel, and therefore the only route by which
  # dailyMaintenance can ever be honest for this game.
  #
  # TO PROMOTE: install BepInEx on the server (valheim-work\tools\
  # install_bepinex_to_live_server.ps1), start it, and look for the 'up' line.
  # It reports patches=<n>/<n> on purpose - a hook that failed to attach would
  # otherwise be indistinguishable from an event that never happened. Then have
  # one person join, say something, die and leave; move whichever of these
  # actually appeared into 'rules', and drop the kinds they cover from
  # 'cannotAnswer'.
  bridgeCandidates = @(
    @{ kind = 'join';  re = '^\[RKB1\] join name=(\S+)';  who = 1 }
    @{ kind = 'leave'; re = '^\[RKB1\] leave name=(\S+)'; who = 1 }
    @{ kind = 'death'; re = '^\[RKB1\] death name=(\S+)'; who = 1 }
    # text LAST and greedy, because a message can contain spaces and '='.
    @{ kind = 'chat';  re = '^\[RKB1\] chat name=(\S+) kind=\S+ text=(.*)$'; who = 1; what = 2 }
    @{ kind = 'population'; re = '^\[RKB1\] pop n=(\d+)\b'; count = 1 }
  )
}
