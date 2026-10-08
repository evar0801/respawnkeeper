# ============================================================
# rk-modgraph.ps1 - who depends on whom, and who is watching
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI). Dot-sourced by rk-common.
#
# WHY THIS EXISTS. "Quarantine the mod that crashed" sounds like removing one
# thing. On the real pokemoncraft install it is not:
#
#     163 mods with metadata
#     125 are LEAVES        - nobody requires them
#      38 are LOAD-BEARING  - something requires them
#         create        <- required by 33 mods
#         architectury  <- required by 28
#         cobblemon     <- required by 8
#
# So pulling `create` is not "removing 1 mod", it is REMOVING 34. Unattended,
# at 3am, that turns one crash into a modpack that no longer exists.
#
# The dependency graph is not a guess - every mod jar declares its requirements
# in META-INF/mods.toml (Forge) or META-INF/neoforge.mods.toml (NeoForge). This
# file reads them.
#
# ---- HOW THE GRAPH IS USED, AND HOW IT IS NOT -----------------------------
# [R-011] rejected "look at the dependency graph" on 2026-08-26, and that
# rejection was aimed at the wrong use. Using the graph to decide WHAT ELSE TO
# PULL (an expander) really is dangerous - it walks outward and takes working
# mods with it. Using it to decide WHETHER TO PULL AT ALL (a veto) only ever
# says no. This file is the veto, and only the veto: it never returns a list of
# things to remove.
# ============================================================

function Get-RkModTomlText {
  param([Parameter(Mandatory)][string]$JarPath)
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $z = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
      $e = $z.Entries | Where-Object {
        ($_.FullName -eq 'META-INF/neoforge.mods.toml') -or ($_.FullName -eq 'META-INF/mods.toml')
      } | Select-Object -First 1
      if (-not $e) { return '' }
      $sr = New-Object System.IO.StreamReader($e.Open())
      $t = $sr.ReadToEnd()
      $sr.Close()
      return $t
    } finally { $z.Dispose() }
  } catch { return '' }
}

function Test-RkJarReadable {
  # Can the file be opened as a zip at all? This separates two situations that
  # Get-RkModTomlText returns identically (empty string) but which mean opposite
  # things for the veto:
  #   readable, no mods.toml -> it is NOT a mod. Nothing can declare a
  #                             dependency on it, because it provides no modId.
  #                             (This is literally the fml-invalid-mod-file case.)
  #   not readable           -> we know nothing. Refuse.
  param([Parameter(Mandatory)][string]$JarPath)
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $z = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    $z.Dispose()
    return $true
  } catch { return $false }
}

function Get-RkModIndex {
  # Reads every jar in mods\ once and returns
  #   @{ mods = @{ modid -> @{ modid; jar; jarPath; requires = @(modid...) } }
  #      dependents = @{ modid -> @(jar names that REQUIRE it) }
  #      scanned; skipped }
  #
  # Cached in <StateDir>\modgraph.json, keyed on the jar count and the newest
  # write time: opening 167 zips takes seconds, and a crash loop would pay it
  # every time otherwise.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    $Template = $null,
    [switch]$Force
  )
  $modsRel = 'mods'
  if ($Template -and $Template.paths.modsDir) { $modsRel = [string]$Template.paths.modsDir }
  $modsDir = Join-Path $ServerDir $modsRel
  $empty = @{ mods = @{}; dependents = @{}; scanned = 0; skipped = 0; modsDir = $modsDir; available = $false }
  if (-not (Test-Path $modsDir)) { return $empty }

  $jars = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue)
  if ($jars.Count -eq 0) { return $empty }

  $stamp = '' + $jars.Count + '|' + (($jars | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime.Ticks)
  $cacheFile = Join-Path (Get-RkStateDir -ServerDir $ServerDir) 'modgraph.json'
  if (-not $Force) {
    $cached = Read-RkJson -Path $cacheFile
    if ($cached -and ($cached.stamp -eq $stamp)) {
      $mods = @{}; $deps = @{}
      foreach ($p in $cached.mods.PSObject.Properties) {
        $mods[$p.Name] = @{ modid = $p.Value.modid; jar = $p.Value.jar; jarPath = $p.Value.jarPath; requires = @($p.Value.requires) }
      }
      foreach ($p in $cached.dependents.PSObject.Properties) { $deps[$p.Name] = @($p.Value) }
      return @{ mods = $mods; dependents = $deps; scanned = [int]$cached.scanned; skipped = [int]$cached.skipped; modsDir = $modsDir; available = $true }
    }
  }

  $mods = @{}
  $deps = @{}
  $skipped = 0
  # Declared by the loader itself, not by an installed mod. Counting these as
  # dependencies would make every single mod look load-bearing.
  $notMods = @('neoforge', 'forge', 'minecraft', 'java', 'fml', 'mcp')

  foreach ($j in $jars) {
    $t = Get-RkModTomlText -JarPath $j.FullName
    if (-not $t) { $skipped++; continue }

    $mine = [regex]::Match($t, '(?ms)\[\[mods\]\].*?modId\s*=\s*"([^"]+)"')
    $myId = ''
    if ($mine.Success) { $myId = $mine.Groups[1].Value }
    if ($myId) { $mods[$myId] = @{ modid = $myId; jar = $j.Name; jarPath = $j.FullName; requires = @() } }

    # Dependency blocks look like:
    #   [[dependencies.<myid>]]
    #       modId="architectury"
    #       type="required"      (NeoForge)  /  mandatory=true  (Forge)
    # Split rather than regex the whole block: the fields come in any order, and
    # a lazy regex silently stops before reaching type=/mandatory= - which made
    # the first version of this report ZERO load-bearing mods on a modpack where
    # 33 mods require create.
    $chunks = $t -split '\[\[dependencies\.'
    for ($i = 1; $i -lt $chunks.Count; $i++) {
      $c = $chunks[$i]
      $cut = $c.IndexOf('[[')
      if ($cut -ge 0) { $c = $c.Substring(0, $cut) }
      $dm = [regex]::Match($c, 'modId\s*=\s*"([^"]+)"')
      if (-not $dm.Success) { continue }
      $depId = $dm.Groups[1].Value
      if ($notMods -contains $depId.ToLower()) { continue }
      $required = ($c -match 'mandatory\s*=\s*true') -or ($c -match 'type\s*=\s*"?required')
      if (-not $required) { continue }
      if ($myId -and $mods.ContainsKey($myId)) { $mods[$myId].requires += $depId }
      if (-not $deps.ContainsKey($depId)) { $deps[$depId] = @() }
      if ($deps[$depId] -notcontains $j.Name) { $deps[$depId] += $j.Name }
    }
  }

  $result = @{ mods = $mods; dependents = $deps; scanned = $jars.Count; skipped = $skipped; modsDir = $modsDir; available = $true }
  try {
    Write-RkJson -Path $cacheFile -Object ([ordered]@{
      stamp = $stamp; generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
      scanned = $jars.Count; skipped = $skipped; mods = $mods; dependents = $deps
    }) -Depth 6
  } catch {}
  return $result
}

function Get-RkModIdForJar {
  # jar file -> modid, from the jar's own metadata. Never from the file name:
  # jar names carry version strings and vary by distributor.
  param([Parameter(Mandatory)][string]$JarPath, $Index = $null)
  if ($Index -and $Index.available) {
    foreach ($k in $Index.mods.Keys) {
      if ($Index.mods[$k].jarPath -eq $JarPath) { return $k }
      if ($Index.mods[$k].jar -eq (Split-Path -Leaf $JarPath)) { return $k }
    }
  }
  $t = Get-RkModTomlText -JarPath $JarPath
  if ($t) {
    $m = [regex]::Match($t, '(?ms)\[\[mods\]\].*?modId\s*=\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return ''
}

function Test-RkModDistributed {
  # Is this mod one of the ones players download? AutoModpack keeps the client
  # set under automodpack\host-modpack\main\mods\, so a jar in there is not just
  # a server file - removing it means every friend re-syncs before they can join.
  # That is an outward-facing change, which is not a 3am decision.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory)][string]$JarPath,
    $Template = $null
  )
  $rels = @('automodpack\host-modpack\main\mods')
  if ($Template -and $Template.paths.distributedModsDir) { $rels = @([string]$Template.paths.distributedModsDir) }
  $leaf = Split-Path -Leaf $JarPath
  foreach ($r in $rels) {
    $d = Join-Path $ServerDir $r
    if (-not (Test-Path $d)) { continue }
    if (Test-Path -LiteralPath (Join-Path $d $leaf)) { return @{ distributed = $true; where = (Join-Path $d $leaf) } }
  }
  return @{ distributed = $false; where = '' }
}

function Test-RkModRemovable {
  # THE VETO. Answers one question: may the unattended path move this jar out of
  # mods\ tonight? Every gate is mechanical - none of them is a judgement call.
  #
  #   gate A  the world has been played           -> removal is a human decision
  #   gate B  something requires this mod         -> pulling 1 would break N
  #   gate C  players download this mod           -> friends would have to re-sync
  #
  # Any gate that fires means NO. There is no threshold and no "only 2 dependents
  # so it is fine": the moment a removal takes something else with it, the
  # premise of unattended repair (one reversible change) is already gone.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory)][string]$JarPath,
    $Template = $null,
    [bool]$AllowModRemoval = $true,
    $Index = $null
  )
  $res = @{
    removable   = $true
    modid       = ''
    jar         = (Split-Path -Leaf $JarPath)
    reasons     = @()
    dependents  = @()
    distributed = $false
    graphAvailable = $false
  }

  if (-not $AllowModRemoval) {
    $res.removable = $false
    $res.reasons += 'this server is marked as an already-played world, where removing a mod can take saved content with it (allowModRemoval = false)'
  }

  if (-not $Index) { $Index = Get-RkModIndex -ServerDir $ServerDir -Template $Template }
  $res.graphAvailable = [bool]$Index.available
  $res.modid = Get-RkModIdForJar -JarPath $JarPath -Index $Index

  if ($Index.available -and $res.modid) {
    $d = @()
    if ($Index.dependents.ContainsKey($res.modid)) { $d = @($Index.dependents[$res.modid]) }
    # A mod is not its own dependent.
    $d = @($d | Where-Object { $_ -ne $res.jar })
    $res.dependents = $d
    if ($d.Count -gt 0) {
      $res.removable = $false
      $res.reasons += ('' + $d.Count + ' installed mod(s) declare ' + $res.modid + ' as a REQUIRED dependency, so removing it would remove them too')
    }
  } elseif (-not $Index.available) {
    # No graph means no veto is possible, which means no confidence. Refuse.
    $res.removable = $false
    $res.reasons += 'the mod dependency graph could not be read, so the blast radius of this removal is unknown'
  } elseif (-not $res.modid) {
    # No modId. Two very different situations, and the difference decides the
    # answer, so it is checked rather than assumed.
    if (Test-RkJarReadable -JarPath $JarPath) {
      # The file opens but declares no mod. Then it PROVIDES no modId, and a
      # dependency is always written against a modId - so nothing in the pack
      # can be depending on it. This is exactly the fml-invalid-mod-file case,
      # which is also the one most worth removing.
      $res.reasons += 'note: this jar declares no modId, so nothing can depend on it (it is not a loadable mod)'
    } else {
      $res.removable = $false
      $res.reasons += 'this file could not be opened, so nothing can be said about what depends on it'
    }
  }

  $dist = Test-RkModDistributed -ServerDir $ServerDir -JarPath $JarPath -Template $Template
  $res.distributed = $dist.distributed
  if ($dist.distributed) {
    $res.removable = $false
    $res.reasons += ('this mod is in the set players download (' + $dist.where + '), so removing it would stop friends connecting until they re-sync')
  }

  return $res
}
