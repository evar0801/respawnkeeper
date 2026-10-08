# ============================================================
# respawnkeeper Tier1 crash rule table - VALHEIM  (LLM-FREE)
# ASCII only (PS 5.1 parses BOM-less .ps1/.psd1 as ANSI).
#
# Loaded with Import-PowerShellDataFile by rk-diagnose.ps1. Data only - no code.
#
# WHY THIS FILE EXISTS (2026-09-15)
#
# valheim.psd1 set rules = '' and the header said, correctly, that empty was
# the honest value: diagnosis would report "the server died" and nothing more,
# rather than silently falling through to the Minecraft table and talking
# about jars, mixins and Forge. That was right while nothing had been
# measured. It is no longer true - real failures of THIS game now exist on
# this machine, verbatim, so the honest value is a table built from them.
#
# ---- THREE THINGS THAT MAKE THIS TABLE DIFFERENT FROM MINECRAFT'S ----------
#
# 1. EVERY RULE IS scope = 'log'. Valheim writes no crash report of its own.
#    rk-diagnose.ps1 feeds scope='report' rules the crash-report text, which
#    for this game is always empty - a rule written that way could never fire
#    and would look configured. The only evidence is the log the launcher
#    redirects.
#
# 2. EVERY RULE IS autoFixable = $false, action = 'HALT'. The repair verbs
#    respawnkeeper implements are Minecraft-shaped: QUARANTINE_MOD moves a
#    *.jar out of paths.modsDir, and for this game paths.modsDir is not set
#    and the mods are BepInEx *.dll plugins living under the Steam install,
#    outside the server directory. Identifying the cause is still most of the
#    value - it turns a 3am HALT from "it died" into "plugin X wants
#    dependency Y version Z". Wire a real consumer before promoting any of
#    these to autoFixable; do not make the action say something the repair
#    path cannot do.
#
# 3. EVERY RULE HAS A REAL FAILURE BEHIND IT. Two rules were drafted and
#    DELETED before this file was first saved, and the reason is worth keeping:
#      - a port-conflict rule whose wording was guessed. A regex nobody has
#        watched fire is the mistake [R-071] is about, and naming a landing
#        place is not worth inventing evidence for.
#      - a "disk full" rule matching 'Saving is blocked'. That phrase is in
#        the HEALTHY guard line every server prints on every save ("Available
#        space to current user: N. Saving is blocked if below: N bytes"), so
#        at priority 5 it would have won against every real rule and
#        diagnosed every Valheim crash as a full disk. The free-space watch
#        lives in rules\logscan-valheim.psd1 instead, as a 'notable' whose
#        note says to read the first number - which is where a standing
#        observation belongs, not here.
#
# ---- PROVENANCE ------------------------------------------------------------
# Rules 10-23 were taken VERBATIM, on 2026-09-15, from real failure logs
# produced on this machine on 2026-09-14 while Everheim's preloader shims were
# being developed:
#   valheim-work\backup\LogOutput_BROKEN_3shim_20260914.log.gz
#   valheim-work\backup\LogOutput_18shims_20260914.log.gz
#   valheim-work\backup\LogOutput_before_shim_20260914.log.gz
#   valheim-work\docs\research\_verify\*.log
# Counted across that set: MissingMethodException 113,851 / IL Compile Error
# 74 / Ambiguous match 56 / "Could not load [...]" 16.
#
# Rule 6 comes from the six real Everheim DEDICATED SERVER logs in
# Servers\valheim\logs\ (2026-09-13 and 2026-09-14).
#
# !! ONE HONEST LIMIT. The BepInEx rules were measured on the CLIENT and on
# the verification server, NOT on the dedicated server that respawnkeeper
# supervises - because that server has no BepInEx installed and has never
# loaded a plugin (0 BepInEx lines in 6/6 boot logs). The strings come from
# BepInEx and HarmonyX, which are the same code wherever they run, so the
# patterns are expected to hold; but the day BepInEx is actually installed on
# the dedicated server, re-check this file against the first real failure
# there. "Expected to hold" is not "observed".
#
# priority: lower number wins when several rules match.
# ============================================================
@{
  rules = @(

  # ---------- The dedicated server itself (measured on OUR server) ----------

  @{
    id          = 'valheim-world-save-missing'
    softFork    = 'none'
    softForkNote = 'the save is a data question, not a code question'
    priority    = 6
    title       = 'The world file the server expected was not there'
    scope       = 'log'
    pattern     = 'missing .*worlds_local'
    action      = 'HALT'
    target      = 'none'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'everheim_20260913_112915.log: "missing C:\Servers\valheim\savedir/worlds_local/Everheim.db" on the first boot'
    note        = 'HALT and not RESTART, deliberately. On a FIRST boot this line is normal - the server looks for the old single-file layout, does not find it, and creates a new world. On any later boot it means the save is gone, and restarting would cheerfully generate a fresh empty world on top of it. A machine cannot tell those two apart from this line alone, so it must stop and ask. savedir\worlds_local\<name>\ holds the real world on buildid 25253791 (_main.N.db2 / .fwl2 / .chunk) plus timestamped auto-backups next to it.'
  },

  # ---------- BepInEx plugin loading (only fires once BepInEx exists) -------

  @{
    id          = 'bepinex-missing-dependency'
    softFork    = 'none'
    softForkNote = 'the plugin is asking for another plugin that is not installed - install the dependency, do not patch anything'
    priority    = 10
    title       = 'A BepInEx plugin was skipped because a dependency is missing'
    scope       = 'log'
    pattern     = 'Could not load \[(?<plugin>[^\]]+)\] because it has missing dependencies: (?<dep>.+)'
    action      = 'HALT'
    target      = 'none'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'LogOutput_*_20260914.log.gz: "Could not load [Item Stacks Item Weights 1.1.1] because it has missing dependencies: _shudnal.ConditionalConfigSync (v1.0.5 or newer)"'
    note        = 'BepInEx names the plugin, the dependency and the minimum version, so there is nothing to guess. The server usually still starts - which is the danger: the plugin is simply absent and whatever it was balancing is back to vanilla. A boot that "succeeded" is not a boot that loaded what you meant to load.'
  },

  @{
    id          = 'bepinex-incompatible-plugin'
    softFork    = 'none'
    softForkNote = 'two plugins refuse to coexist; one of them has to go, and which one is a design decision'
    priority    = 10
    title       = 'A BepInEx plugin was skipped because it is incompatible with another'
    scope       = 'log'
    pattern     = 'Could not load \[(?<plugin>[^\]]+)\] because it is incompatible with: (?<other>.+)'
    action      = 'HALT'
    target      = 'none'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'LogOutput_*_20260914.log.gz: "Could not load [Jewelcrafting 2.0.1] because it is incompatible with: randyknapp.mods.epicloot" and the same for [Vitality 1.1.3]'
    note        = 'Declared incompatibility, not a crash. Same danger as the rule above: the server starts and one of the two mods is simply not there. Both observed cases were plugins that refuse to run alongside EpicLoot.'
  },

  # ---------- Harmony patching (the real failure mode of this game) ---------

  @{
    id          = 'harmony-ambiguous-match'
    softFork    = 'harmony'
    softForkNote = 'the patch names a method by name only and the class has more than one overload - give the patch an explicit argument list'
    priority    = 21
    title       = 'A Harmony patch matched more than one method'
    scope       = 'log'
    pattern     = 'Ambiguous match for HarmonyMethod\[\(class=(?<class>[^,]+), methodname=(?<method>[^,]+)'
    action      = 'HALT'
    target      = 'none'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'LogOutput_18shims_20260914.log.gz: "Rethrow as HarmonyException: Ambiguous match for HarmonyMethod[(class=EffectList, methodname=Create, type=Normal, args=undefined)]" - 56 hits in the 18-shim build'
    note        = 'Note "args=undefined" in the real line: the patch did not say WHICH overload it meant. This is a patch-authoring bug, not a version-drift bug, and it is fixed in the patch, not in the game.'
  },

  @{
    id          = 'harmony-il-compile-error'
    softFork    = 'harmony'
    softForkNote = 'a transpiler produced IL the runtime will not accept - usually two transpilers fighting over the same method'
    priority    = 22
    title       = 'A Harmony transpiler produced invalid IL'
    scope       = 'log'
    pattern     = 'HarmonyException: IL Compile Error'
    action      = 'HALT'
    target      = 'none'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'LogOutput_BROKEN_3shim_20260914.log.gz (2 hits) and LogOutput_18shims_20260914.log.gz (72 hits), 74 total'
    note        = 'The measured lesson from 2026-09-14 is that the COUNT is not the signal. Two hits (the 3-shim build) was the build that never finished starting; 72 hits (the 18-shim build) was merely broken. What decided it was WHICH method was patched - ItemData::GetTooltip is a method Blacksmithing already transpiles, and adding a second transpiler there is what wedged the boot. Read the method name, not the number.'
  },

  @{
    id          = 'missing-method-after-update'
    softFork    = 'harmony'
    softForkNote = 'a plugin is calling a game method whose signature changed in this build - the plugin needs rebuilding against the current game, or a shim'
    priority    = 23
    title       = 'A plugin called a game method that no longer exists'
    scope       = 'log'
    pattern     = 'MissingMethodException: Method not found: (?<sig>.+)'
    action      = 'HALT'
    target      = 'none'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'LogOutput_before_shim_20260914.log.gz: "MissingMethodException: Method not found: void .ConsoleCommand..ctor(string,string,Terminal/ConsoleEvent,bool,bool,bool,bool,bool,Terminal/ConsoleOptionsFetcher,bool,bool,bool)" - 113,829 hits before the shim, 3 after'
    note        = 'The signature in the message is the one the PLUGIN wants; the game now has a different one. Six figures of hits is normal for this - it is thrown per call, not once - so treat the count as "is it zero or not", never as a severity. This is the exact failure the Everheim preloader shims exist to absorb.'
  },

  # Broadest of the Harmony rules, so it sorts LAST of them: the three above
  # name the specific cause, this one catches any other patch failure and
  # still names the method, which is most of what a human needs at 3am.
  @{
    id          = 'harmony-patch-failed'
    softFork    = 'harmony'
    softForkNote = 'the patch target moved - re-point the patch at the method the current build actually has'
    priority    = 30
    title       = 'A Harmony patch could not be applied'
    scope       = 'log'
    pattern     = 'Failed to patch (?<method>[^:]+::[^:(]+)\([^)]*\): (?<ex>[\w\.]+Exception)'
    action      = 'HALT'
    target      = 'none'
    autoFixable = $false
    severity    = 'blocker'
    evidence    = 'LogOutput_18shims_20260914.log.gz: "[Error  :  HarmonyX] Failed to patch void FejdStartup::Awake(): System.Reflection.AmbiguousMatchException: Ambiguous match found."'
    note        = 'The single most useful line shape in a modded Valheim log: it names the exact method that could not be patched AND the reason.'
  }

  )
}
