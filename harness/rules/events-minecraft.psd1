@{
  # ============================================================
  # What a Minecraft server's log says about the people on it.
  #
  # WHY THIS IS A TABLE AND NOT CODE (Eva, 2026-09-14): "if it takes a long
  # time that is probably a big obstacle to generalising. Think about doing
  # this mechanism for Valheim."  She was right - the first version of
  # rk-highlights.ps1 had every one of these strings compiled into it, so it
  # read exactly one game and adding a second meant editing the reader.
  # The reader now knows only KINDS; which sentences mean which kind is here.
  #
  # A game supplies only the kinds its log actually contains. Anything not
  # listed goes into 'cannotAnswer', and the report SAYS the game cannot answer
  # it rather than printing a zero - "nobody died" and "this log does not
  # record deaths" are different facts and must not look the same.
  #
  # Groups are named by NUMBER because that is what the regex gives back.
  # ============================================================

  schema = 'respawnkeeper/events/1'
  game   = 'minecraft'

  # A server that has just started has nobody on it. This is what separates a
  # restart (sessions really ended) from a midnight log rotation (they carry
  # on), and it is evidence rather than a guess about the size of a time gap.
  boot = 'ModLauncher running|Starting minecraft server|Loading for game Minecraft|Starting Minecraft server version'

  # Only these prove a HUMAN. A Pokemon that lands the killing blow is written
  # exactly the way a person is - "Greninja" came out in the player list on a
  # real day - so the roster is built from these two kinds and everything else
  # is attributed to it afterwards.
  rosterFrom = @('join', 'achievement', 'quest')

  # Lines that are NOT a player death, however much they look like one. The
  # entity-debug prefix is what mod logging puts in front of everything that is
  # not a player, so its ABSENCE is the test.
  notPlayer = '^(Named entity|Villager|Player|Zombie|Skeleton|.*Mob)\s*\w*\['

  rules = @(
    @{ kind = 'join';        re = '^(\S+) joined the game$';                                    who = 1 }
    @{ kind = 'leave';       re = '^(\S+) left the game$';                                      who = 1 }
    @{ kind = 'chat';        re = '^<([^>]+)>\s?(.*)$';                                         who = 1; text = 2 }
    @{ kind = 'achievement'; re = '^(\S+) has made the advancement \[(.+)\]$';                  who = 1; what = 2 }
    # The pack's own quests. In pokemoncraft these are in Japanese and they are
    # the thing the modpack is FOR, so they are counted apart from vanilla.
    @{ kind = 'quest';       re = '^(\S+) has (?:completed the challenge|reached the goal) \[(.+)\]$'; who = 1; what = 2 }
    # A trainer dying is a player WINNING. Belongs under achievements, not deaths.
    @{ kind = 'beat';        re = "^Named entity \w*Mob\['([^']+)'/\d+.*died: .+ was slain by (\S+)$"; what = 1; who = 2 }
    # Something with a name that a person typed. A TrainerMob is content, not a
    # possession, and the three-word vanilla defaults ("Skeleton Horse") are the
    # mob's type rather than a name.
    @{ kind = 'namedDeath';  re = "^Named entity (\w+)\['([^']+)'/\d+.*died: (.+)$"
       ofKind = 1; what = 2; text = 3; skipKind = 'Trainer'; skipWhat = '^[A-Z][a-z]+( [A-Z][a-z]+)*$' }
    @{ kind = 'timeout';     re = 'lost connection:\s*.*[Tt]imed out' }
  )

  # A player death is the bare vanilla sentence, so it is matched by looking
  # for the verb rather than by a whole-line pattern: the subject is a name
  # this table cannot know and the tail varies with the weapon.
  deathVerbs = @(
    'was slain by', 'was killed by', 'was shot by', 'was pricked to death',
    'drowned', 'fell from a high place', 'fell out of the world', 'hit the ground too hard',
    'was blown up by', 'was killed by magic', 'burned to death', 'was burnt to a crisp',
    'tried to swim in lava', 'starved to death', 'suffocated in a wall',
    'was squashed by', 'went off with a bang', 'was struck by lightning',
    'froze to death', 'was impaled', 'was fireballed by', 'was stung to death',
    'was poked to death', 'walked into a cactus', 'discovered the floor was lava',
    'was doomed to fall', 'died of heatstroke', 'died of hypothermia',
    'was processed by', 'was pummeled by', 'was skewered by', 'died'
  )

  # Causes that need nobody at the keyboard. Not proof of idling - a player can
  # walk into lava on purpose - but the only honest hint a log can give.
  idleCauses = @(
    'drowned', 'starved to death', 'suffocated in a wall', 'burned to death',
    'froze to death', 'died of heatstroke', 'died of hypothermia',
    'was struck by lightning'
  )

  # Names that are usernames. Keeps coordinates, mob names and stray words out.
  nameShape = '^[A-Za-z0-9_]{3,16}$'

  cannotAnswer = @()
}
