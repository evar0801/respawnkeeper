# ============================================================
# respawnkeeper Tier1 crash rule table  (LLM-FREE)
# ASCII only (PS 5.1 parses BOM-less .ps1/.psd1 as ANSI).
#
# Loaded with Import-PowerShellDataFile by rk-diagnose.ps1. Data only - no code.
#
# PROVENANCE. Every rule below was derived from crash reports that ACTUALLY
# HAPPENED on this machine, not from imagination ([R-004]):
#   - fc8 (Forge 1.20.1)            : 60 crash-reports, classified in
#                                     ..\..\the project notes (crash-patterns)
#   - pokemoncraft (NeoForge 1.21.1): 7 crash-reports under server\crash-reports\
# The "evidence" field on each rule names where it came from. A rule with no
# real crash behind it does not belong in this table.
#
# ACTION VOCABULARY (rk-repair.ps1 implements exactly these):
#   HALT              - stop and wait for a human. THE DEFAULT for anything
#                       uncertain. Not a failure mode; it is the safe answer.
#   RESTART           - no repair needed, start the server again. The
#                       crash-loop breaker in respawnkeeper.ps1 still applies.
#   QUARANTINE_MOD    - move the offending jar out of mods\ into
#                       <StateDir>\quarantine\<stamp>\ (MOVE, never delete).
#   RESET_CONFIG      - copy the named config file into quarantine, then delete
#                       it so the mod regenerates defaults on next boot.
#   CLEAR_WORLD_LOCK  - delete <level-name>\session.lock, and only when no java
#                       process is alive and the port is free.
#
# autoFixable = $false means "this rule identifies the cause but the fix is a
# human judgement call". rk-repair.ps1 refuses to act on those even with
# -Apply. Identifying the cause is still worth a lot: it turns a 3am HALT
# message from "it crashed" into "mod X needs dependency Y version Z".
#
# priority: lower number wins when several rules match the same report.
# ============================================================
# PS 5.1 Import-PowerShellDataFile returns only the FIRST element when the top
# level of a .psd1 is a bare array (verified 2026-08-26 on 5.1.26100). So the
# rules live under a single top-level hashtable key instead.
@{
  rules = @(

  # ---------- Mod loading failures (the single largest real category) -------
  # fc8: 22/60 reports = "Mod Loading has failed".
  # pokemoncraft: 7/7 reports = "Mod loading failures have occurred".
  @{
    id          = 'fml-invalid-mod-file'
    softFork    = 'none'
    softForkNote = 'the jar itself is unreadable - there is nothing to patch'
    priority    = 10
    title       = 'A file in mods\ is not a loadable mod jar'
    scope       = 'report'
    pattern     = 'Failure message: File (?<jar>.+?\.jar) is not a valid mod file'
    action      = 'QUARANTINE_MOD'
    target      = 'jar'
    autoFixable = $true
    severity    = 'blocker'
    evidence    = 'pokemoncraft crash 2026-08-01 21.04.29 / 21.04.49 / 21.06.00 (Structory_Towers_26.2_v1.0.17.jar, 3 crashes in 2 minutes)'
    note        = 'The report names the exact absolute path, so there is nothing to guess. Moving it out is fully reversible (rk-repair.ps1 -Undo).'
  },
  @{
    id          = 'dist-client-class-on-server'
    softFork    = 'high'
    softForkNote = 'THE canonical Mixin case: make the class load server-side or stub it. fc8efnvfx exists for exactly this'
    priority    = 11
    title       = 'A mod loaded a CLIENT-only class on a dedicated server'
    scope       = 'report'
    pattern     = 'Attempted to load class (?<class>\S+) for invalid dist DEDICATED_SERVER'
    action      = 'QUARANTINE_MOD'
    target      = 'modfile'
    autoFixable = $true
    severity    = 'blocker'
    evidence    = 'fc8 crash 2026-06-25 04.48.02 (ToadLib, enhanced_boss_bars); 3x EpicFight Nightfall dist crash'
    note        = 'The report carries a "Mod File:" line next to the exception, so the jar is named outright. This is what analyze-mod calls a Dist crash. Singleplayer is unaffected, which is why it survives testing and only bites the dedicated server.'
  },
  @{
    id          = 'config-load-failed'
    softFork    = 'none'
    softForkNote = 'fix the config file; no code change is involved'
    priority    = 12
    title       = 'A mod config file failed to parse'
    scope       = 'report'
    pattern     = 'ConfigLoadingException: Failed loading config file (?<file>\S+) of type (?<cfgtype>\w+) for modid (?<modid>\w+)'
    action      = 'RESET_CONFIG'
    target      = 'file'
    autoFixable = $true
    severity    = 'blocker'
    evidence    = 'fc8 crash-report for irons_spellbooks-server.toml (1 occurrence)'
    note        = 'Recorded the hard way: a broken TOML does not merely lose the broken line - Forge resets EVERY setting in that file to defaults. Quarantining the file therefore loses nothing the crash was not already going to lose, and the server boots. The copy in quarantine\ is what you diff afterwards. Most common cause here: a BOM written by PowerShell Set-Content -Encoding utf8.'
  },
  @{
    id          = 'fml-mixin-apply-failed'
    softFork    = 'medium'
    softForkNote = 'another mod mixin is failing. Sometimes avoidable by priority or by patching the target yourself'
    priority    = 13
    title       = 'A mod mixin failed to apply during mod loading'
    scope       = 'report'
    pattern     = 'Failure message: Mixin application of (?<mixin>\S+) from .*?\((?<modid>[a-z0-9_]+)\) has failed'
    action      = 'QUARANTINE_MOD'
    target      = 'modid'
    autoFixable = $true
    severity    = 'blocker'
    evidence    = 'pokemoncraft crash 2026-08-01 21.08.30 (bits_n_bobs FluidPipeBlockMixin)'
    note        = 'Quarantining the mixin OWNER is right when it is an addon. rk-repair.ps1 refuses if the jar cannot be resolved to exactly one file.'
  },
  @{
    id          = 'world-session-lock-held'
    softFork    = 'none'
    softForkNote = 'not a mod problem'
    priority    = 14
    title       = 'The world is still locked by a previous (dead) server process'
    scope       = 'both'
    pattern     = '(Failed to check session lock|session\.lock).{0,160}(already in use|another instance|not writable)'
    action      = 'CLEAR_WORLD_LOCK'
    autoFixable = $true
    severity    = 'blocker'
    evidence    = 'fc8: the documented chain "Ticking entity crash -> ~180s save hang -> restart fails on session.lock" (the project notes (crash-patterns) section 1 item 2)'
    note        = 'Only safe because rk-repair.ps1 re-proves there is no live java for this ServerDir AND the port is free before touching world\. This is the single action that writes under world\.'
  },

  # ---------- Identified, but the fix is a human call ----------------------
  @{
    id          = 'fml-missing-dependency'
    softFork    = 'none'
    softForkNote = 'the fix is a download'
    priority    = 20
    title       = 'A mod requires a dependency that is missing or too old'
    scope       = 'report'
    pattern     = 'Failure message: Mod (?<modid>\S+) requires (?<dep>\S+) (?<ver>[^\r\n]+?) or above'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'pokemoncraft crash 2026-08-01 20.50.38 (8 occurrences in one report), 20.55.08; fc8 22x Mod Loading has failed'
    note        = 'Fixing this means downloading a mod. Automated downloads are forbidden by the mod workspace rules (Modrinth/CurseForge by hand only, after the fake-OptiFine trojan). HALT and name the exact mod+version so the human can fetch it in one step.'
  },
  @{
    id          = 'fml-missing-dependency-any'
    softFork    = 'none'
    softForkNote = 'the fix is a download'
    priority    = 21
    title       = 'A mod requires a dependency that is not installed at all'
    scope       = 'report'
    pattern     = 'Failure message: Mod (?<modid>\S+) requires (?<dep>\S+) any'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'pokemoncraft crash 2026-08-01 20.50.38 ("Mod cobblepedia requires patchouli any")'
    note        = 'Same as fml-missing-dependency but with no version floor.'
  },
  @{
    id          = 'fml-incompatible-mods'
    softFork    = 'medium'
    softForkNote = 'the incompatibility declaration can be removed by patch, but it was declared for a reason'
    priority    = 22
    title       = 'Two installed mods declare each other incompatible'
    scope       = 'report'
    pattern     = 'Failure message: Mod (?<modid>\S+) is incompatible with (?<other>\S+)'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'pokemoncraft crash 2026-08-01 21.04.10 ("Mod sable is incompatible with scalablelux any")'
    note        = 'Which of the two to drop is a gameplay decision, not a mechanical one. Never guess - list both and HALT.'
  },
  @{
    id          = 'ticking-entity-npe'
    softFork    = 'high'
    softForkNote = 'a null guard injected at the throwing method. undyings_bosses ItemUtil2.hasItem is exactly this shape'
    priority    = 23
    title       = 'An entity threw while ticking (mod bug on live world data)'
    scope       = 'report'
    pattern     = '(?s)Description: Ticking entity.*?Entity Type: (?<entity>\S+)'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'fc8 9/60 reports; 5 of them undyings_bosses InventoryCarrier NPE'
    note        = 'The offending entity is IN THE SAVED WORLD, so restarting re-ticks it and crashes again - a guaranteed loop. Fixing it means removing the entity or the mod, both of which touch player-visible state. HALT with the entity type and coordinates, which the report always carries.'
  },
  @{
    id          = 'missing-class-own-mod'
    softFork    = 'none'
    softForkNote = 'our own mod needs rebuilding'
    priority    = 24
    title       = 'A class from one of our OWN mods is missing (stale build)'
    scope       = 'report'
    pattern     = 'java\.lang\.NoClassDefFoundError: (?<class>(com/example/shauradungeon|com/fc8)/\S+)'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'fc8 7/60 reports (shauradungeon dev classes)'
    note        = 'Means a jar was hot-swapped or built stale. The fix is a gradle rebuild + redeploy, which is squarely outside the harness (no builds, ever). HALT and say which class.'
  },
  @{
    id          = 'nosuchmethod-mod-api-drift'
    softFork    = 'high'
    softForkNote = 'supply the missing signature yourself - a classpath shim. cataclysm_dungeoneye_shim is exactly this'
    priority    = 25
    title       = 'Two mods disagree on a method signature (version drift)'
    scope       = 'report'
    pattern     = 'java\.lang\.NoSuchMethodError: .(?<sig>[^\r\n]+).'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'fc8 2/60 (cataclysm x traveloptics Laser_Beam_Entity constructor)'
    note        = 'The fix is a version bump of one of the two mods - a download, therefore human-only. Naming both class owners in the HALT message is most of the work.'
  },
  @{
    id          = 'fml-init-cascade'
    softFork    = 'medium'
    softForkNote = 'depends on why the root mod failed to initialise'
    priority    = 26
    title       = 'A mod failed because ANOTHER mod did not initialise (cascade)'
    scope       = 'report'
    pattern     = 'NoClassDefFoundError: Could not initialize class (?<class>\S+)'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'pokemoncraft crash 2026-08-01 21.08.30 (3 mods all failing on com.simibubi.create.AllBlocks)'
    note        = 'A cascade. The named class belongs to the mod that really broke, and it is usually NOT in the failure list. Quarantining the visible victims would remove working mods. Report the class and HALT.'
  },

  # ---------- Environment: another process is involved, never auto-fix -----
  @{
    id          = 'port-already-bound'
    softFork    = 'none'
    softForkNote = 'another process holds the port'
    priority    = 30
    title       = 'The server port is already taken (double start)'
    scope       = 'both'
    pattern     = '(FAILED TO BIND TO PORT|Address already in use|java\.net\.BindException)'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'fc8 tier2_prompt_template.txt names this as a known pattern; respawnkeeper preflight already aborts on it'
    note        = 'Restarting cannot help - something else holds the port. Auto-killing whatever it is would be exactly the cross-server kill risk the -ServerDir tightening was meant to remove.'
  },
  @{
    id          = 'out-of-memory'
    softFork    = 'none'
    softForkNote = 'a JVM setting, not a mod'
    priority    = 31
    title       = 'JVM ran out of heap'
    scope       = 'both'
    pattern     = 'java\.lang\.OutOfMemoryError'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'NOT SEEN in fc8 (0/60). Kept because the consequence of mishandling it is a restart loop that fills the disk with heap dumps.'
    note        = 'Raising -Xmx is a decision about the whole machine, not about this server. HALT.'
  },

  # ---------- Too generic to act on: escalate -----------------------------
  @{
    id          = 'failed-to-initialize-server'
    softFork    = 'medium'
    softForkNote = 'too generic to say without reading the rest of the report'
    priority    = 40
    title       = 'Server initialisation failed (cause is further down the report)'
    scope       = 'report'
    pattern     = 'java\.lang\.IllegalStateException: Failed to initialize server'
    action      = 'HALT'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'fc8 8/60 reports, clustered right after config/mod changes'
    note        = 'Too generic to act on: the real cause is a few lines further down and differs every time. This is exactly the shape Tier2/Tier3 escalation exists for.'
  },

  # ---------- Scored last on purpose: usually a SYMPTOM, not a cause -------
  @{
    id          = 'server-hang-watchdog'
    softFork    = 'medium'
    softForkNote = 'usually a symptom of something else'
    priority    = 90
    title       = 'Vanilla ServerHangWatchdog killed the server after a stuck tick'
    scope       = 'report'
    pattern     = 'ServerHangWatchdog detected that a single server tick took (?<secs>[\d.]+) seconds'
    action      = 'RESTART'
    autoFixable = $true
    severity    = 'transient'
    evidence    = 'fc8 10/60 reports'
    note        = 'In fc8 this was almost always a FOLLOW-ON to another crash in the same second, not a cause - hence priority 90, so any co-occurring real cause wins. On its own a restart is the right move and the crash-loop breaker catches it if the hang repeats. NOTE pokemoncraft sets max-tick-time=-1, so this rule can never fire there; that gap is what the hang-watch heuristic covers instead.'
  }
)
}
