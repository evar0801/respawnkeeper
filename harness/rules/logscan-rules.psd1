# ============================================================
# respawnkeeper daily log-scan rules
# ASCII only. Data only (Import-PowerShellDataFile).
#
# These do NOT decide anything. The daily scan counts every WARN/ERROR signature
# it finds; these rules only decide WHERE IN THE REPORT a signature is printed,
# so that the handful worth thinking about are not buried under thousands of
# lines of known noise.
#
#   class = 'benign'  - known harmless. Counted, but folded into one line.
#   class = 'chronic' - not an error exactly; evidence of a standing problem.
#                       These go at the TOP, because they are the ones that
#                       reward sitting down and thinking.
#   class = 'notable' - known, and worth a look when the count moves.
#   (no rule)         - unknown. Listed in full. Unknown is INTERESTING, not an
#                       error - it is the reason to read the report at all.
#
# PROVENANCE. Every rule comes from the counted table in
# ..\..\the project notes (crash-patterns) section 2-2, which was built from 28 real
# fc8 log files. The counts in the notes are that sample's actual counts.
# ============================================================
@{
  rules = @(

    # ---- chronic: the ones that mean something is actually wrong -----------
    @{
      id = 'cant-keep-up'
      class = 'chronic'
      pattern = "Can't keep up! Is the server overloaded"
      title = 'The server is falling behind on ticks'
      note = 'fc8 sample: 892 hits, present in 18 of 28 log files (64%) - i.e. most days. Vanilla prints this when a tick took far longer than 50ms. One or two after a lag spike is normal; a steady daily count is the single clearest sign the server is chronically overloaded.'
    },
    @{
      id = 'kubejs-emergency-mode'
      class = 'chronic'
      pattern = 'Emergency Mode|CRITICAL LAG|MSPT='
      title = 'The homemade TPS guard is firing'
      note = 'fc8 sample: 3,239 + 1,109 hits. tick_management.js only speaks when the server is already struggling, so its own log volume is a direct measure of how bad the day was.'
    },
    @{
      id = 'oom-warning'
      class = 'chronic'
      pattern = 'OutOfMemoryError|GC overhead limit|Low memory'
      title = 'Memory pressure'
      note = 'Never seen in the fc8 sample (0 of 60 crash reports). Listed because if it EVER appears it outranks everything else in the report.'
    },

    # ---- notable: known, but the count is worth watching -------------------
    @{
      id = 'dist-xform-skipped'
      class = 'notable'
      pattern = 'RuntimeDistCleaner.*invalid dist DEDICATED_SERVER'
      title = 'A client-only class was skipped on the server'
      note = 'fc8 sample: 435 hits. USUALLY harmless - the loader skips the class and carries on. But this is the same mechanism that took the server down via EpicFight Nightfall, so a NEW class name appearing here is worth a look even though the old ones are noise.'
    },
    @{
      id = 'gem-parse-failure'
      class = 'notable'
      pattern = 'Failed parsing gems file|Underlying Exception'
      title = 'A data file failed to parse'
      note = 'fc8 sample: 480 hits (traveloptics gems, via Apotheosis). The affected content silently does not exist in game - which is exactly the kind of thing nobody notices for weeks.'
    },
    @{
      id = 'kubejs-removed-api'
      class = 'notable'
      pattern = "'java\(\)' is no longer supported|is no longer supported!"
      title = 'A script calls an API the mod has removed'
      note = 'fc8 sample: 676 hits. Left over from a KubeJS upgrade. The script line does nothing at all now.'
    },
    @{
      id = 'entity-no-attributes'
      class = 'notable'
      pattern = 'has no attributes'
      title = 'An entity was registered without attributes'
      note = 'fc8 sample: 7,635 hits (legendary_monsters). Printed every boot; never crashed anything. High count, low meaning - but if the entity NAME changes, something new broke.'
    },

    # ---- benign: counted, then folded into one line ------------------------
    @{
      id = 'unknown-attribute'
      class = 'benign'
      pattern = 'Ignoring unknown attribute'
      title = 'Two mods disagree about an attribute id'
      note = 'fc8 sample: 5,750 hits. The word Ignoring is the whole story - it carries on.'
    },
    @{
      id = 'invalid-rotation'
      class = 'benign'
      pattern = 'Invalid entity rotation: NaN'
      title = 'A mob AI produced NaN and the value was discarded'
      note = 'fc8 sample: 364 hits. Discarded and continued.'
    },
    @{
      id = 'skipping-entity'
      class = 'benign'
      pattern = 'Skipping Entity with id|Skipping BlockEntity with id'
      title = 'Leftover references to a mod that is no longer installed'
      note = 'fc8 sample: 277 + 173 hits. Saved-world leftovers being dropped on load.'
    },
    @{
      id = 'defineid-duplicate'
      class = 'benign'
      pattern = 'defineId called for'
      title = 'Duplicate entity-data definition in an inheritance chain'
      note = 'fc8 sample: 450 hits (EpicFight).'
    },
    @{
      id = 'version-checker'
      class = 'benign'
      pattern = 'Failed to process update information|VersionChecker'
      title = 'The update check could not reach the internet'
      note = 'fc8 sample: 118 hits. Offline or DNS; nothing to do with the server.'
    },
    @{
      id = 'dimension-no-region'
      class = 'benign'
      pattern = 'possible mod dimension with no region folder'
      title = 'A dimension has not been generated yet'
      note = 'fc8 sample: ~300 hits (FTB Backups scanning). READ THIS ONE CAREFULLY: it is NOT region corruption. It was misread as corruption once already - the analysis in crash-patterns.md had to walk that back.'
    },
    @{
      id = 'vanilla-rejected'
      class = 'benign'
      pattern = 'rejected vanilla connections|NETREGISTRY'
      title = 'A vanilla client was refused'
      note = 'fc8 sample: 80 hits. Correct behaviour for a modded server.'
    }
  )
}
