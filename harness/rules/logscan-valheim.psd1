# ============================================================
# respawnkeeper daily log-scan rules - VALHEIM
# ASCII only. Data only (Import-PowerShellDataFile).
#
# WHY THIS FILE EXISTS (2026-09-15)
#
# Before it, valheim.psd1 set logscan = '' and the scan fell through to
# rules\logscan-rules.psd1 - a table built from 28 real Minecraft logs, naming
# KubeJS, Forge and chunk saving. None of those words exist in a Valheim log,
# so every rule missed and every line landed in "unknown = interesting".
#
# That was the SECOND half of the problem. The first half was worse: the scan
# only counts a line if it matches
#     \b(WARN|WARNING|ERROR|SEVERE|FATAL|CRITICAL)\b
# and a Valheim dedicated server writes NO severity tags at all, because the
# "log" is just stdout redirected by the launcher. Measured on the six real
# Everheim logs: 0 matches in 1,613 lines. The daily report therefore said
# "WARN/ERROR: 0" for a set of logs containing 239 lines that say, in the
# game's own words, that something failed.
#
# Zero hits of a pattern the game never emits is indistinguishable from a
# healthy server. That is the same mistake as [R-071], one level up. The fix
# has two halves and BOTH are needed: evidence.level in games\valheim.psd1
# supplies this game's own vocabulary of trouble, and this file says which of
# those lines are worth a human's attention.
#
# PROVENANCE. Every rule below was derived from the six real logs in
# C:\Servers\valheim\logs\ (everheim_20260913_112915 /
# _131812 / _133724 / _133858 and everheim_20260914_132805 / _164437),
# profiled 2026-09-15 by collapsing every run of digits and counting. The
# counts in each note are that sample's actual counts. A rule with no real
# line behind it does not belong here.
#
#   class = 'benign'  - known harmless. Counted, folded into one line.
#   class = 'chronic' - evidence of a standing problem. Printed at the TOP.
#   class = 'notable' - known, worth a look when the count moves.
#   (no rule)         - unknown. Listed in full, because unknown is the
#                       interesting case and the reason to read the report.
#
# ORDER MATTERS: the first rule whose pattern matches the sample line wins
# (rk-logscan.ps1, "foreach ($r in $rules) { ... break }"). Narrow rules go
# above broad ones.
# ============================================================
@{
  rules = @(

    # ---- chronic: the ones that mean something is actually wrong -----------

    # THE ONE THAT MATTERS MOST ON THIS INSTANCE. Valheim prints its own
    # verdict on whether anything was injected into it, once per boot, and it
    # has said False in all six logs. That single word is the difference
    # between "the Everheim server" and "a vanilla Valheim server wearing the
    # name Everheim" - and until 2026-09-15 nothing in the harness read it, so
    # the supervisor could not tell the two apart.
    #
    # It is 'chronic' rather than 'notable' on purpose: it is not an incident,
    # it is a standing condition, and the report's chronic section is the one
    # that rewards sitting down and thinking.
    @{
      id = 'valheim-vanilla-not-modded'
      class = 'chronic'
      pattern = 'isModded:\s*False'
      title = 'This server is running VANILLA - no mods were loaded'
      note = 'Six of six logs. The BepInEx loader shell is present in the Steam folder (winhttp.dll, doorstop_config.ini, doorstop_libs) and doorstop_config.ini has enabled=true pointing at BepInEx\core\BepInEx.Preloader.dll - but no BepInEx folder exists there, so nothing is injected and the server boots vanilla. server\SERVER_SETUP.md step 4 is the copy that has never been done. If this line ever reads True, mods ARE loading and the clean-stop measurement needs re-checking: a plugin that throws in OnApplicationQuit turns a clean stop into a hang.'
    },

    # 'chronic' FOR ONE MEASUREMENT, THEN DEMOTED TO 'benign' (2026-09-15).
    # Worth keeping the reason. Run against the six real logs, this produced
    # ELEVEN chronic rows - one per structure name, because the signature
    # collapses digits but not words, so Crypt2 and NorthVillage are different
    # signatures of the same phenomenon. The top of the report, which is
    # supposed to be the two or three things worth thinking about, became
    # eleven copies of one sentence.
    #
    # And the demotion is right on the merits, not just the rendering: this
    # note already said "This is boot cost, not play cost". A one-time world
    # generation expense is not a standing problem, so it was never chronic.
    # The aggregate the game prints itself - the rule below - is the single row
    # that belongs at the top, and it carries the total in seconds, which is
    # strictly more useful than eleven per-structure rows.
    @{
      id = 'valheim-slow-location-placement'
      class = 'benign'
      pattern = 'took more than [0-9.]+ seconds to place'
      title = 'A structure took seconds to place during world generation'
      note = 'Sample: 18 hits across the six logs, worst offenders TarPit2_1 (3), StoneTowerRuins1_sunk (3), GoblinHut2 (3). The game prints its own summary too ("There are N that take a long time to generate ... Total slow location time is N seconds that could be saved on world gen!"). This is boot cost, not play cost.'
    },

    @{
      id = 'valheim-slow-worldgen-summary'
      class = 'chronic'
      pattern = 'take a long time to generate'
      title = 'World generation reported its own total slow time'
      note = 'The game adding up the line above and telling you how many seconds could be saved. One hit in the sample - it only prints on a generation pass.'
    },

    # ---- notable: known, and the count is the interesting part -------------

    # ---- RkBridge, the server-side mod that prints what vanilla will not ----
    # These two lines appear once per boot each. Neither is a failure; both are
    # the only place the report can learn things the game never says.
    # Measured on the real server 2026-09-15 (11:10:33 and 11:13:34).

    @{
      id = 'rkbridge-mod-accounting'
      class = 'notable'
      pattern = '\[RKB1\] mods '
      title = 'Which mods actually loaded, and which did not'
      note = 'Read the numbers, not the fact that the line exists. First real boot: announced=72 loaded=68 skipped=2 refused=2 unexplained=0. "skipped" is BepInEx own process filter - the mod declares [BepInProcess("valheim.exe")] and is CLIENT ONLY (FistAttackMod, SpecialAttack), which is correct and needs no action. "refused" means the mod is simply NOT THERE (Jewelcrafting 2.0.1 and Vitality 1.1.3, both incompatible with EpicLoot): the server starts fine and those features do not exist. !! unexplained > 0 means the four numbers do not add up - that is a gap in the accounting itself, and it matters more than any of the other numbers.'
    },

    @{
      id = 'rkbridge-up'
      class = 'notable'
      pattern = '\[RKB1\] up '
      title = 'RkBridge attached, and how many of its hooks took'
      note = 'patches=4/4 is the healthy reading. Anything less and the missing hook reports nothing for the rest of the run - which is indistinguishable from the event never happening, so the count is printed rather than assumed. The four are: join (ZNet.RPC_PeerInfo), leave (ZNet.Disconnect), spawn/death (ZNet.RPC_CharacterID) and chat (ZRoutedRpc.HandleRoutedRPC). If this line is missing entirely, the plugin did not load at all and every player-facing section of the report is back to what vanilla says - which is nothing.'
    },

    # ---- Harmony patches that did not attach (2026-09-23, T5) --------------
    #
    # WHAT WAS THERE BEFORE THIS RULE: a guess, written down in HANDOFF as a
    # guess - "client-side UI patches have no target in a headless build, so
    # probably harmless". It is NOT confirmed, and for at least two of the four
    # it is contradicted: the name ItemDrop.ItemData.GetTooltip IS present in
    # this server's own valheim_server_Data\Managed\assembly_valheim.dll
    # (checked 2026-09-23). A method that exists cannot be missing because the
    # build is headless.
    #
    # What IS established: Harmony could not resolve the declared target, so
    # those four mods' patches never attached. The likeliest remaining cause is
    # a signature change in this build - the same shape as the
    # ConsoleCommand..ctor residue below, which is a confirmed version drift.
    # That link is a HYPOTHESIS, not a measurement; it is written here as one.
    #
    # So: 'notable', not 'benign'. Folding an unexplained patch failure into
    # the harmless pile is how the next one gets missed.
    @{
      id = 'valheim-harmony-undefined-target'
      class = 'notable'
      pattern = 'Undefined target method for patch method'
      title = 'A mod patch never attached - Harmony could not find what it was aiming at'
      note = 'FOUR per boot, identical across the three modded boots of 2026-09-15, always the same four mods: Blacksmithing (UpdateDurabilityDisplay), Cooking (UpdateFoodDisplay), DualWielder (ItemDrop_ItemData_GetTooltip_Patch) and Exploration (MultiplyTreasure). What is lost is those four patches - the rest of each mod still loads. !! 4 is the known set: a FIFTH means a new mod joined them, and that one is unexamined. NOT verified: the old note said "headless has no UI target", and that is contradicted for the tooltip ones - GetTooltip exists in this server assembly. Most likely a changed signature in this build (same family as the ConsoleCommand..ctor rule below), but that is a hypothesis.'
    },

    # The wrapper lines of the SAME four failures. Harmony prints the
    # ArgumentException, then re-throws it as a HarmonyException, then unwinds
    # through its own stack - so one failed patch produces several lines and
    # the report would otherwise show one event three times over.
    #
    # Benign means "counted and folded", not "ignored": if the count of these
    # ever stops tracking the rule above, the shape of the failure changed.
    @{
      id = 'valheim-harmony-patch-envelope'
      class = 'benign'
      pattern = 'Rethrow as HarmonyException|HarmonyLib\.PatchClassProcessor\.ReportException'
      title = 'The wrapper Harmony prints around a patch it could not apply'
      note = 'Four of each per boot in the sample, one pair per failure in the rule above - count the EVENTS there, not the lines here. Only the ReportException frame reaches the report; the other stack frames carry no word the ruler recognises, which is why the line count here is smaller than what the log actually holds.'
    },

    # ONE per boot, and it has a name (2026-09-23). The line itself says
    # nothing - the attribution is on the NEXT line, which the ruler does not
    # forward, so the report can only show the bare exception. Measured stack:
    #   ServerDevcommands.DevcommandsCommand.Set (System.Boolean)
    #   <- ServerDevcommands.Admin.Reset <- AdminReset.Postfix <- Game.Start
    #
    # !! The pattern is as generic as the line is: ANY NullReferenceException
    # lands here. That is stated in the note rather than hidden, because the
    # alternative - leaving it unclassified - buries a stable, explained event
    # in the bucket meant for surprises.
    @{
      id = 'valheim-nre-at-boot'
      class = 'notable'
      pattern = '^NullReferenceException'
      title = 'A mod threw a null reference while the game was starting'
      note = 'One per boot in all three modded boots of 2026-09-15. In every one the next line named ServerDevcommands.DevcommandsCommand.Set, reached from Game.Start via AdminReset.Postfix - i.e. the ServerDevcommands mod, not the game. The server finishes starting and plays. !! THIS RULE CANNOT TELL ONE NRE FROM ANOTHER: the message line is identical for every null reference in the process. If the count moves off 1, do not trust this title - open the log and read the frame under it. Not established: whether this shares a cause with the ConsoleCommand..ctor drift (both are mods touching the console), only that they are different mods - UpgradeWorld throws that one, ServerDevcommands throws this.'
    },

    # THE SHIM'S OWN TELLTALE (2026-09-23, T6). A mod registers a console
    # command against an OLDER Terminal.ConsoleCommand constructor than the one
    # this build ships, and the call throws. Measured: three per boot in each of
    # the three modded boots of 2026-09-15 (09:32:04 / 10:58:46 / 11:10:13), and
    # zero in the six earlier logs - those boots had no BepInEx at all, so zero
    # there means "no mods", not "no problem".
    #
    # WHY IT IS WORTH A RULE RATHER THAN A MEMORY. Before the shim another
    # session measured 113,829 of these (recorded in DECISIONS.md [R-101 addendum]; not reproduced
    # here). The shim brought it to 3, and THREE IS THE EXPECTED RESIDUE - the
    # number only means something when it MOVES. Until now the only thing that
    # knew the baseline was a person; a number nobody counts cannot move.
    #
    # Read it per boot: the window can span several starts, so divide by the
    # number of "Valheim version:" lines before comparing with 3.
    @{
      id = 'valheim-console-command-ctor-mismatch'
      class = 'notable'
      pattern = 'ConsoleCommand\.\.ctor'
      title = 'A mod registered a console command against a signature this build does not have'
      note = 'Three per boot is the expected residue after the shim (measured 2026-09-15 across three boots; the six pre-BepInEx logs have zero because they had no mods). Thrown from UpgradeWorld.Upgrade.Postfix while Terminal.InitTerminal runs, so what is lost is that mod''s console commands - the server itself starts and plays fine. !! MORE than three per boot means the shim no longer matches the game build (it was 113,829 before the shim, per DECISIONS.md [R-101 addendum]) - check whether Valheim updated. FEWER is also worth a look: it usually means the mod that throws them is no longer loading at all.'
    },

    # This is the disk-space guard, printed on EVERY save. It is not an error;
    # what matters is the FIRST number. Notable rather than benign because the
    # day it matters, it will look exactly like the day it did not.
    @{
      id = 'valheim-save-space-guard'
      class = 'notable'
      pattern = 'Saving is blocked if below'
      title = 'Free-space check before a world save'
      note = 'Eight hits in the sample, one per save, always healthy. The line reads "Available space to current user: N. Saving is blocked if below: N bytes. Warnings are given if below: N". Read the FIRST number: if it ever approaches the second one, the world stops being saved. The count moving is normal (it tracks saves); the number shrinking is not.'
    },

    # The world file the server looked for and did not find. Harmless on a
    # first boot - it is how a new world gets created - and alarming on any
    # other, which is exactly why it is notable and not benign.
    @{
      id = 'valheim-world-file-missing'
      class = 'notable'
      pattern = 'missing .*worlds_local'
      title = 'The world file was not found where the server looked'
      note = 'One hit in the sample, on the very first boot (11:29 on 09-13), naming savedir/worlds_local/Everheim.db - the OLD single-file world layout. Buildid 25253791 writes a world DIRECTORY instead (_main.N.db2 / .fwl2 / .chunk), so the server looks for the old name, does not find it, and moves on. Normal on a first boot. On any later boot this line means the save it expected is gone - do not restart, look first.'
    },

    # Demoted from 'notable' to 'benign' for the same reason as the rule above:
    # 26 lines across 19 distinct structure names, i.e. 19 rows for one
    # ordinary behaviour. The note below already called it ordinary, so the
    # class was arguing with the note.
    @{
      id = 'valheim-structure-placement-shortfall'
      class = 'benign'
      pattern = 'Failed to place all '
      title = 'World generation could not fit every copy of a structure'
      note = 'Twenty-three hits across the sample (TarPit2_1, SwampHut5_2, StoneTowerRuins1_sunk, GoblinHut2, WoodVillage1, TrollCave1, ShipWreck2_D2, Runestone_Mountains, NorthVillage, MountainWell1, MorgenHole1, Mistlands_Giant1, GoblinCamp2_1, GoblinCamp2, Crypt2, CombatRuin1 ...). Ordinary Valheim behaviour: the generator gives up after N tries when the terrain has nowhere that satisfies the spawn conditions. Worth a glance only if a structure your players need is on the list.'
    },

    # ---- benign: headless Unity noise ---------------------------------------
    # A dedicated server runs -nographics -batchmode on a machine with no GPU
    # available to it, so the Unity engine complains about its own rendering
    # assets at every boot. None of it has anything to do with the server. It
    # is 149 of the 239 problem-shaped lines in the sample - i.e. without
    # these rules, five out of eight lines in the report would be noise.

    @{
      id = 'valheim-headless-missing-script'
      class = 'benign'
      pattern = 'referenced script on this Behaviour .* is missing'
      title = 'Unity: a MonoBehaviour has no script attached'
      note = 'Seventy-eight hits in the sample: 60 name the Game Object as <null> and 18 name it as the empty string. Client-side components in the shared asset bundles that a headless server does not instantiate. Present in every boot, including the ones that ran fine for hours.'
    },

    @{
      id = 'valheim-headless-shader-unsupported'
      class = 'benign'
      pattern = 'is not supported on this platform|not supported on the current platform|custom render path shader needs'
      title = 'Unity: a screen-space shader is unavailable without a GPU'
      note = 'Thirty-six hits in the sample (SunShaftsComposite, SimpleClear, Dof/DepthOfFieldHdr, and the two image effects that get disabled as a result). This is what -nographics looks like from the inside. It also means bare "  at UnityEngine..." stack frames appear in a HEALTHY boot, which is why evidence.exception in the template requires a named exception rather than a stack frame.'
    },

    @{
      id = 'valheim-headless-hdr-rendertexture'
      class = 'benign'
      pattern = 'HDR Render Texture not supported'
      title = 'Unity: HDR disabled on reflection probes'
      note = 'Eighteen hits in the sample, three per boot. Same cause as the shaders above.'
    },

    @{
      id = 'valheim-headless-async-upload'
      class = 'benign'
      pattern = 'AsyncResourceUpload failed'
      title = 'Unity: a texture upload to the GPU failed'
      note = 'Twelve hits in the sample, two per boot, always at startup. There is no GPU to upload to. Harmless.'
    },

    @{
      id = 'valheim-headless-intro-cinematic'
      class = 'benign'
      pattern = 'Failed to play intro cinematic'
      title = 'The server tried to play the opening cinematic'
      note = 'Six hits, exactly one per boot. The dedicated server runs the same scene the client does and reaches the same line.'
    },

    @{
      id = 'valheim-headless-missing-audio'
      class = 'benign'
      pattern = 'Missing audio clip'
      title = 'Unity: an audio clip is not loaded'
      note = 'Six hits, one per boot ("Missing audio clip in music respawn"). Audio is stripped from a headless build.'
    },

    @{
      id = 'valheim-steam-not-logged-on'
      class = 'benign'
      pattern = 'BLoggedOn'
      title = 'Steam client interface: not logged on'
      note = 'Eight hits in the sample ("src\clientdll\cminterface.cpp (N) : !BLoggedOn()"). A dedicated server authenticates as an anonymous game server, not as a Steam USER, so the user-facing half of the Steam client has nobody logged in. Expected. It does NOT mean the server failed to register - "Steam game server initialized" and "Opened Steam server" are the lines that say that, and both are present in every boot.'
    }
  )
}
