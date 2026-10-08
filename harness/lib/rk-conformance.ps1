# ============================================================
# rk-conformance.ps1 - static conformance check for games\*.psd1 templates.
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI). Dot-sourced; functions only.
#
# WHAT THIS IS, AND WHAT IT IS NOT
#
#   Test-RkGameTemplate (lib\rk-games.ps1) checks a template AGAINST A REAL
#   FOLDER: "you said valheim_server.exe is there - is it?".
#
#   This file checks a template AGAINST ITSELF and against the harness code:
#   "you said capture.stdout AND stop=close - those cannot both hold", "you set
#   a field no code path reads", "this feature needs evidence you never
#   supplied". NO FOLDER IS TOUCHED. No server is started, stopped or probed.
#
# The two do not overlap. Never move a folder check in here: a conformance run
# must give the same answer on a machine that has none of these games installed.
#
# WHY IT EXISTS ([R-071][R-072], 2026-09-12). The Valheim template was written
# carefully by hand and still shipped three defects at once, every one of which
# a machine could have seen:
#   1. capture.stdout=$true together with stop.kind='close'. A child launched
#      with redirected handles has no main window, so CloseMainWindow() cannot
#      work. Measured 2026-09-12.
#   2. an evidence.cleanShutdown regex whose first alternative, 'Shutdown',
#      also matches the line a server prints when it goes down WITHOUT saving.
#   3. 'rules' and 'logscan' - fields no code has ever read. minecraft.psd1
#      points logscan at a file that does not exist, and nothing noticed,
#      because nothing looked.
# Only #2 needs a human. #1 and #3 are checked here.
#
# ---- the one thing to be careful about -------------------------------------
# Requirement 2 is a NEGATIVE observation: "no code reads this field". This
# harness has been burned by exactly that shape of claim before (a name-equality
# search concluded a mod was absent when it was sitting right there, and two
# days of work went the wrong way). So the consumption scan:
#   - parses every .ps1 into an AST instead of grepping text, and
#   - additionally probes two more spellings (index literal $x['rules'], and the
#     bare quoted string 'rules' used for dynamic access $x.$k), and
#   - reports a field as CONSUMED on any bound hit, AMBIGUOUS when the only
#     hits are on a receiver that is not a template, and DEAD only when all
#     three probes came back empty.
# Every hit is printed with file:line so the negative can be checked by eye.
# ============================================================

# NOTE: this file deliberately does NOT call Set-StrictMode. It is dot-sourced,
# so a mode set here would leak into whatever sourced it, and half the checks
# below are "is this optional key absent?" questions that strict mode turns into
# exceptions instead of answers.

# ---- Provenance ------------------------------------------------------------
# rk-capabilities.psd1: measured / human / inferred, and a MISSING entry reads
# as 'inferred'. A template may carry an explicit provenance block:
#
#   provenance = @{
#     'evidence.cleanShutdown' = 'measured'      # flat dotted key, or
#     paths = @{ logFile = 'measured' }          # nested - both are accepted
#   }
#
# Where a template has no explicit entry, this checker falls back to the
# verified block that already exists (verified.layout / .launch / .stop), which
# by its own definition records what A HUMAN WATCHED HAPPEN. That mapping is a
# CHECKER-SIDE DEFAULT, not something the capabilities contract states - it is
# printed by -Explain so it can be argued with, and an explicit provenance entry
# always wins over it.
$script:RkConfVerifiedFallback = @{
  launchOwned           = 'launch'
  stopChannel           = 'stop'
  broadcastChannel      = 'stop'
  cleanShutdownEvidence = 'stop'
  logStream             = 'layout'
  logFileStable         = 'layout'
  crashArtifacts        = 'layout'
  portProbe             = 'layout'
  processProbe          = 'layout'
  modsDir               = 'layout'
  exceptionEvidence     = 'layout'
  # 'launch', not 'layout': a line that means "it is up" can only have been
  # identified by watching the thing come up. Knowing where the files live
  # proves nothing about which line matters.
  readyEvidence         = 'launch'
  connectEvidence       = 'layout'
  pidFileProbe          = 'layout'
  # 'layout' would be wrong for both of these. Knowing where the files live
  # says nothing about which WORDS this game uses when it is unhappy or slow -
  # that can only come from reading real output, which is what verified.launch
  # certifies. Getting this wrong is how a guessed vocabulary would inherit a
  # promotion somebody earned by watching a server start.
  lagEvidence           = 'launch'
  levelEvidence         = 'launch'
}

# Requirements that are facts about RESPAWNKEEPER, not claims about a game: they
# are true or false by reading harness source, and Invoke-SelfTest exercises
# them against a real process. No template can make them more or less true, so
# they are not gated on a template's provenance.
$script:RkConfHarnessMeasured = @{
  exitCode = 'respawnkeeper starts and owns the process, so it sees the exit code (Invoke-SelfTest)'
}

# Which template fields each requirement actually consults. Used for provenance
# lookup and for the -Explain dump.
$script:RkConfReqFields = @{
  launchOwned           = @('launch.kind')
  logStream             = @('paths.logFile', 'capture.stdout')
  logFileStable         = @('paths.logFile')
  exitCode              = @('launch.kind')
  crashArtifacts        = @('paths.crashDirs', 'paths.jvmCrashGlob')
  portProbe             = @('paths.settingsFile', 'process.port', 'process.portProtocol')
  processProbe          = @('process.names')
  pidFileProbe          = @('process.names')
  twoLivenessProbes     = @()
  stopChannel           = @('stop.kind', 'capture.stdout', 'launch.kind')
  broadcastChannel      = @('broadcast.kind', 'stop.kind')
  cleanShutdownEvidence = @('evidence.cleanShutdown')
  exceptionEvidence     = @('evidence.exception')
  readyEvidence         = @('evidence.ready')
  connectEvidence       = @('evidence.connect', 'evidence.disconnect')
  modsDir               = @('paths.modsDir')
  modDependencySource   = @('mods.dependencySource')
  diagnosisRules        = @('rules')
  # Both added 2026-09-15. lagEvidence had been DECLARED in
  # lib\rk-capabilities.psd1 since 2026-09-12 and never implemented here, so
  # every template printed "[ ??? ] lagEvidence - this checker does not
  # implement requirement id 'lagEvidence'" and the vitals feature carried a
  # note about a requirement nothing could ever satisfy. A requirement with no
  # test is not a stricter contract, it is a blind spot with a name.
  lagEvidence           = @('evidence.lag')
  levelEvidence         = @('evidence.level')
}

# What the harness can actually do today, read out of the code (see the notes on
# each line). These are the "is implemented" halves of the requirement tests.
$script:RkConfLaunchKinds = @('script', 'exe', 'builtin')   # Resolve-RkLaunch
# 'ctrlc' added 2026-09-12. Request-RkStop (respawnkeeper.ps1) dispatches it to
# Send-RkCtrlC; before that split it existed only as an unnamed fallback inside
# Request-RkClose, so a template that meant Ctrl+C had to declare 'close' and be
# wrong. Leaving it off this list would report the implemented kind as missing.
$script:RkConfStopKinds   = @('stdin', 'script', 'close', 'ctrlc')   # Request-RkStop
# 'udp' added 2026-09-14. This list said 'tcp' because the probe once WAS
# Get-NetTCPConnection alone; Get-RkPortHolders has taken a -Protocol since
# 2026-09-12 ([R-071]) and reads the UDP table (GetExtendedUdpTable, cmdlet
# fallback Get-NetUDPEndpoint). Leaving the contract behind the code reported a
# working probe as impossible: valheim declares udp honestly and was told "the
# harness probes tcp only", which dropped it to one liveness probe and switched
# safetyGate off - the strictest possible answer, arrived at for a reason that
# had stopped being true. Confirmed by measurement before this line was changed:
# UDP 2456 was observed BOUND by valheim_server pid 22416 through
# Get-RkPortHolders while the real server was serving.
$script:RkConfPortProto   = @('tcp', 'udp')                 # Get-RkPortHolders -Protocol

# ---- small value helpers ---------------------------------------------------

function Get-RkConfList {
  # @($null) has Count 1 in PowerShell, so an absent optional key ('wants' on a
  # feature that has none) turns into a one-element list holding $null and the
  # next ContainsKey() throws. Every optional list goes through here.
  param($Value)
  if ($null -eq $Value) { return @() }
  return @(@($Value) | Where-Object { $null -ne $_ })
}

function Get-RkConfValue {
  # Nested lookup by dotted path. $null when any segment is absent.
  param($Root, [string]$Path)
  $cur = $Root
  foreach ($seg in ($Path -split '\.')) {
    if ($null -eq $cur) { return $null }
    if ($cur -is [System.Collections.IDictionary]) {
      if (-not $cur.Contains($seg)) { return $null }
      $cur = $cur[$seg]
    } else {
      $p = $null
      try { $p = $cur.PSObject.Properties[$seg] } catch { return $null }
      if ($null -eq $p) { return $null }
      $cur = $p.Value
    }
  }
  return $cur
}

function Test-RkConfHasKey {
  # Does the key EXIST, whatever its value? A present-but-empty field still
  # "looks configured" to a reader, which is the whole complaint about rules
  # and logscan - so presence and non-emptiness are tracked separately.
  param($Root, [string]$Path)
  $segs = @($Path -split '\.')
  $cur = $Root
  for ($i = 0; $i -lt $segs.Count; $i++) {
    if ($null -eq $cur) { return $false }
    if ($cur -is [System.Collections.IDictionary]) {
      if (-not $cur.Contains($segs[$i])) { return $false }
      $cur = $cur[$segs[$i]]
    } else { return $false }
  }
  return $true
}

function Test-RkConfSet {
  # Set = present and carrying something. $false is "set" (it is a decision);
  # '' and @() are not.
  param($Root, [string]$Path)
  if (-not (Test-RkConfHasKey $Root $Path)) { return $false }
  $v = Get-RkConfValue $Root $Path
  if ($null -eq $v) { return $false }
  if ($v -is [bool]) { return $true }
  if ($v -is [string]) { return ($v.Trim().Length -gt 0) }
  if ($v -is [System.Collections.IDictionary]) { return ($v.Count -gt 0) }
  if ($v -is [System.Collections.IEnumerable]) { return ((@($v) | Where-Object { $_ }).Count -gt 0) }
  return $true
}

function Test-RkConfTrue {
  param($Root, [string]$Path)
  $v = Get-RkConfValue $Root $Path
  if ($null -eq $v) { return $false }
  return [bool]$v
}

function Get-RkConfString {
  param($Root, [string]$Path)
  $v = Get-RkConfValue $Root $Path
  if ($null -eq $v) { return '' }
  return ([string]$v).Trim()
}

# ---- the consumption index (AST, not grep) ---------------------------------

function Get-RkConfAstRootVar {
  param($Expr)
  $cur = $Expr
  for ($guard = 0; $guard -lt 64; $guard++) {
    if ($null -eq $cur) { return '(null)' }
    if ($cur -is [System.Management.Automation.Language.VariableExpressionAst]) {
      return $cur.VariablePath.UserPath
    }
    if ($cur -is [System.Management.Automation.Language.MemberExpressionAst]) { $cur = $cur.Expression; continue }
    if ($cur -is [System.Management.Automation.Language.IndexExpressionAst])  { $cur = $cur.Target;     continue }
    if ($cur -is [System.Management.Automation.Language.ConvertExpressionAst]) { $cur = $cur.Child;     continue }
    if ($cur -is [System.Management.Automation.Language.ParenExpressionAst])  { return '(sub-expression)' }
    return '(' + $cur.GetType().Name + ')'
  }
  return '(deep)'
}

function Test-RkConfTemplateVar {
  # Receiver names that plausibly hold a game template. Generous on purpose: a
  # false "consumed" only costs a missed warning, a false "dead" sends somebody
  # deleting a live field.
  param([string]$Name)
  return ($Name -match '^(?i)(template|templates|gametemplate|gt|game|games|tpl|tmpl|t|g)$')
}

function Get-RkConfConsumption {
  # Scans harness .ps1 files and returns, per field name, where it is read.
  # @{ fields = @{ name = @{ state; bound = @(); ambiguous = @(); literal = @() } }
  #    files = n; parseErrors = @() }
  param(
    [Parameter(Mandatory)][string]$HarnessRoot,
    [Parameter(Mandatory)][string[]]$Fields,
    [string[]]$ExcludeDirs = @('tests'),
    [string[]]$ExcludeFiles = @('rk-conformance.ps1')
  )

  $acc = @{}
  foreach ($f in $Fields) { $acc[$f] = @{ bound = @(); ambiguous = @(); literal = @() } }
  $parseErrors = @()
  $scanned = 0

  $files = @(Get-ChildItem -LiteralPath $HarnessRoot -Filter '*.ps1' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      $rel = $_.FullName.Substring($HarnessRoot.Length).TrimStart('\', '/')
      $top = ($rel -split '[\\/]')[0]
      (-not ($_.Name -like '*.bak*')) -and
      (-not ($_.FullName -like '*.bak_*')) -and
      ($ExcludeDirs -notcontains $top) -and
      ($ExcludeFiles -notcontains $_.Name)
    })

  foreach ($file in $files) {
    $scanned++
    $tokens = $null
    $errs = $null
    $ast = $null
    try {
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errs)
    } catch {
      $parseErrors += ($file.Name + ': ' + $_.Exception.Message)
      continue
    }
    if ($errs -and @($errs).Count -gt 0) {
      foreach ($e in @($errs)) {
        $parseErrors += ($file.Name + ':' + $e.Extent.StartLineNumber + ': ' + $e.Message)
      }
    }
    if ($null -eq $ast) { continue }

    $rel = $file.FullName.Substring($HarnessRoot.Length).TrimStart('\', '/')

    # probe 1 - property access  $x.field
    $members = @($ast.FindAll({
      param($n)
      ($n -is [System.Management.Automation.Language.MemberExpressionAst]) -and
      (-not ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]))
    }, $true))
    foreach ($m in $members) {
      if (-not ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst])) { continue }
      $name = [string]$m.Member.Value
      if (-not $acc.ContainsKey($name)) { continue }
      $root = Get-RkConfAstRootVar $m.Expression
      $hit = ($rel + ':' + $m.Extent.StartLineNumber + '  $' + $root + '.' + $name)
      if (Test-RkConfTemplateVar $root) { $acc[$name].bound += $hit } else { $acc[$name].ambiguous += $hit }
    }

    # probe 2 - index access  $x['field']
    $idx = @($ast.FindAll({
      param($n) $n -is [System.Management.Automation.Language.IndexExpressionAst]
    }, $true))
    foreach ($ix in $idx) {
      if (-not ($ix.Index -is [System.Management.Automation.Language.StringConstantExpressionAst])) { continue }
      $name = [string]$ix.Index.Value
      if (-not $acc.ContainsKey($name)) { continue }
      $root = Get-RkConfAstRootVar $ix.Target
      $hit = ($rel + ':' + $ix.Extent.StartLineNumber + "  `$" + $root + "['" + $name + "']")
      if (Test-RkConfTemplateVar $root) { $acc[$name].bound += $hit } else { $acc[$name].ambiguous += $hit }
    }

    # probe 3 - the bare quoted name, which is how dynamic access $x.$k reaches
    # a field without ever spelling it as a member.
    $strs = @($ast.FindAll({
      param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true))
    foreach ($s in $strs) {
      $name = [string]$s.Value
      if (-not $acc.ContainsKey($name)) { continue }
      if ($s.Parent -is [System.Management.Automation.Language.MemberExpressionAst]) { continue }
      if ($s.Parent -is [System.Management.Automation.Language.IndexExpressionAst]) { continue }
      $acc[$name].literal += ($rel + ':' + $s.Extent.StartLineNumber + "  '" + $name + "'")
    }
  }

  foreach ($f in $Fields) {
    $e = $acc[$f]
    if ($e.bound.Count -gt 0) { $e['state'] = 'consumed' }
    elseif ($e.ambiguous.Count -gt 0 -or $e.literal.Count -gt 0) { $e['state'] = 'ambiguous' }
    else { $e['state'] = 'dead' }
  }

  return @{ fields = $acc; files = $scanned; parseErrors = $parseErrors }
}

# ---- conflicts -------------------------------------------------------------

function Test-RkConfConflicts {
  # Implements rk-capabilities.psd1 'conflicts' BY ID. A conflict id the checker
  # does not implement is reported as such rather than passed over - a silently
  # unchecked rule is how this layer got into trouble in the first place.
  param([Parameter(Mandatory)]$Template, [Parameter(Mandatory)]$Caps)

  $hits = @()
  $unimplemented = @()

  $captureStdout = Test-RkConfTrue $Template 'capture.stdout'
  $stopKind      = (Get-RkConfString $Template 'stop.kind').ToLower()
  $launchKind    = (Get-RkConfString $Template 'launch.kind').ToLower()
  $logFile       = Get-RkConfString $Template 'paths.logFile'
  $bcastKind     = (Get-RkConfString $Template 'broadcast.kind').ToLower()

  foreach ($c in @($Caps.conflicts)) {
    $id = [string]$c.id
    $fired = $false
    $detail = ''
    switch ($id) {

      'capture-vs-window-close' {
        if ($captureStdout -and ($stopKind -eq 'close')) {
          $fired = $true
          $detail = 'capture.stdout = $true AND stop.kind = ''close'''
        }
      }

      'capture-vs-external-redirect' {
        if ($captureStdout -and $logFile) {
          $fired = $true
          $detail = 'capture.stdout = $true AND paths.logFile = ''' + $logFile + ''''
        }
      }

      'stdin-without-console' {
        if (($stopKind -eq 'stdin') -and (-not $captureStdout) -and ($launchKind -eq 'script')) {
          $fired = $true
          $detail = 'stop.kind = ''stdin'' AND capture.stdout is not true AND launch.kind = ''script'''
        }
      }

      'broadcast-without-stop-channel' {
        # 'bridge' is exempt by construction: it is a file drop read by a server
        # mod, so it neither needs nor shares the stop channel (2026-09-23).
        if ($bcastKind -and ($bcastKind -ne 'bridge') -and ($bcastKind -ne $stopKind)) {
          $fired = $true
          $st = $stopKind
          if (-not $st) { $st = '(none)' }
          $detail = 'broadcast.kind = ''' + $bcastKind + ''' but stop.kind = ''' + $st + ''''
        }
      }

      default { $unimplemented += $id }
    }
    if ($fired) { $hits += @{ id = $id; detail = $detail; why = [string]$c.why } }
  }

  return @{ hits = $hits; unimplemented = $unimplemented }
}

# ---- requirements ----------------------------------------------------------

# Last segments too generic to be a provenance key on their own: 'kind' says
# nothing about WHICH kind. These are only matched in their qualified forms.
$script:RkConfGenericLeaf = @('kind', 'names', 'script', 'exe', 'builtin', 'command', 'format', 'stdout', 'args')

function Get-RkConfProvenanceKeys {
  # A template may spell a provenance key several ways and all of them are
  # legitimate, so try each rather than insisting on one house style:
  #   'paths.logFile' (dotted)  'logFile' (leaf)  'processNames' (camel)
  #   'process' (the whole block)
  param([Parameter(Mandatory)][string]$Path)
  $segs = @($Path -split '\.')
  $out = @($Path)
  if ($segs.Count -ge 2) {
    $parent = $segs[0]
    $leaf = $segs[$segs.Count - 1]
    $out += ($parent + $leaf.Substring(0, 1).ToUpper() + $leaf.Substring(1))
    if ($script:RkConfGenericLeaf -notcontains $leaf) { $out += $leaf }
    $out += $parent
  }
  return @($out)
}

function Get-RkConfProvenance {
  # measured | human | inferred, for one template field path. '' when the
  # template says nothing about it (the caller then falls back to verified).
  #
  # Two value shapes are accepted, because both are in use:
  #   'measured'                                   - bare level
  #   @{ by = 'measured'; on = '...'; how = '...' } - level plus its receipt
  param([Parameter(Mandatory)]$Template, [Parameter(Mandatory)][string]$Path)
  $prov = Get-RkConfValue $Template 'provenance'
  if ($null -eq $prov -or (-not ($prov -is [System.Collections.IDictionary]))) { return '' }

  foreach ($k in (Get-RkConfProvenanceKeys $Path)) {
    $v = $null
    if ($prov.Contains($k)) { $v = $prov[$k] } else { $v = Get-RkConfValue $prov $k }
    if ($null -eq $v) { continue }
    if ($v -is [string]) {
      if ($v.Trim()) { return $v.Trim().ToLower() }
      continue
    }
    if ($v -is [System.Collections.IDictionary]) {
      foreach ($levelKey in @('by', 'level', 'provenance')) {
        if ($v.Contains($levelKey)) {
          $s = ([string]$v[$levelKey]).Trim()
          if ($s) { return $s.ToLower() }
        }
      }
    }
  }
  return ''
}

function Get-RkConfReqProvenance {
  # Worst provenance across the fields a requirement actually used, falling back
  # to the verified block (see RkConfVerifiedFallback).
  param([Parameter(Mandatory)]$Template, [Parameter(Mandatory)][string]$ReqId)

  $rank = @{ measured = 3; human = 2; inferred = 1 }

  # twoLivenessProbes has no template fields of its own - it is only ever as
  # trustworthy as the probes it actually counted, so take the worst of those.
  if ($ReqId -eq 'twoLivenessProbes') {
    $worst = ''
    $used = @()
    foreach ($p in @('portProbe', 'processProbe', 'pidFileProbe')) {
      $r = Test-RkConfRequirement -Template $Template -ReqId $p -Ctx @{ rulesDir = ''; supervisorWritesPidFile = $true; pidFileName = '' }
      if ($r.met -ne $true) { continue }
      $sub = Get-RkConfReqProvenance -Template $Template -ReqId $p
      $used += ($p + '=' + $sub.level)
      if ((-not $worst) -or ($rank[$sub.level] -lt $rank[$worst])) { $worst = $sub.level }
    }
    if (-not $worst) { $worst = 'inferred' }
    return @{ level = $worst; source = ('worst of the probes counted: ' + (@($used) -join ', ')) }
  }

  if ($script:RkConfHarnessMeasured.ContainsKey($ReqId)) {
    return @{ level = 'measured'; source = $script:RkConfHarnessMeasured[$ReqId] }
  }

  $explicit = @()
  $paths = @()
  if ($script:RkConfReqFields.ContainsKey($ReqId)) { $paths = Get-RkConfList $script:RkConfReqFields[$ReqId] }
  foreach ($p in $paths) {
    if (-not $p) { continue }
    $v = Get-RkConfProvenance $Template $p
    if ($v) { $explicit += @{ path = $p; level = $v } }
  }
  if ($explicit.Count -gt 0) {
    $worst = 'measured'
    foreach ($e in $explicit) {
      $v = $e.level
      $rv = 1
      if ($rank.ContainsKey($v)) { $rv = $rank[$v] } else { $v = 'inferred' }
      if ($rv -lt $rank[$worst]) { $worst = $v }
    }
    $shown = @($explicit | ForEach-Object { $_.path + '=' + $_.level })
    return @{ level = $worst; source = ('provenance block: ' + ($shown -join ', ')) }
  }

  if ($script:RkConfVerifiedFallback.ContainsKey($ReqId)) {
    $flag = $script:RkConfVerifiedFallback[$ReqId]
    if (Test-RkConfTrue $Template ('verified.' + $flag)) {
      return @{ level = 'human'; source = ('verified.' + $flag + ' = $true') }
    }
    return @{ level = 'inferred'; source = ('verified.' + $flag + ' is not $true, and no provenance entry') }
  }
  return @{ level = 'inferred'; source = 'no provenance entry' }
}

function Test-RkConfRequirement {
  # Structural evaluation of ONE requirement id. Returns @{ met; detail }.
  # 'met' is $null for a requirement this checker does not implement.
  param([Parameter(Mandatory)]$Template, [Parameter(Mandatory)][string]$ReqId, [Parameter(Mandatory)]$Ctx)

  $captureStdout = Test-RkConfTrue $Template 'capture.stdout'
  $stopKind      = (Get-RkConfString $Template 'stop.kind').ToLower()
  $launchKind    = (Get-RkConfString $Template 'launch.kind').ToLower()
  $logFile       = Get-RkConfString $Template 'paths.logFile'

  switch ($ReqId) {

    'launchOwned' {
      if ($script:RkConfLaunchKinds -notcontains $launchKind) {
        return @{ met = $false; detail = ('launch.kind = ''' + $launchKind + ''' is not one of ' + ($script:RkConfLaunchKinds -join '/')) }
      }
      $targetField = ''
      if ($launchKind -eq 'script')  { $targetField = 'launch.script' }
      if ($launchKind -eq 'exe')     { $targetField = 'launch.exe' }
      if ($launchKind -eq 'builtin') { $targetField = 'launch.builtin' }
      if (-not (Test-RkConfSet $Template $targetField)) {
        return @{ met = $false; detail = ($targetField + ' is empty') }
      }
      return @{ met = $true; detail = ('launch.kind = ' + $launchKind + ' (the target is checked against the real folder by Test-RkGameTemplate, not here)') }
    }

    'logStream' {
      if ($logFile) { return @{ met = $true; detail = ('paths.logFile = ' + $logFile) } }
      if ($captureStdout) { return @{ met = $true; detail = 'capture.stdout = $true' } }
      return @{ met = $false; detail = 'neither paths.logFile nor capture.stdout' }
    }

    'logFileStable' {
      if (-not $logFile) { return @{ met = $false; detail = 'paths.logFile is not set' } }
      return @{ met = $true; detail = ('paths.logFile = ' + $logFile) }
    }

    'exitCode' {
      if ($script:RkConfLaunchKinds -notcontains $launchKind) {
        return @{ met = $false; detail = ('launch.kind = ''' + $launchKind + ''' - respawnkeeper would not own the process') }
      }
      return @{ met = $true; detail = ('launch.kind = ' + $launchKind + ' - the supervisor owns the process and sees it exit') }
    }

    'crashArtifacts' {
      $dirs = @(Get-RkConfValue $Template 'paths.crashDirs')
      $dirs = @($dirs | Where-Object { $_ })
      $glob = Get-RkConfString $Template 'paths.jvmCrashGlob'
      if ($dirs.Count -gt 0) { return @{ met = $true; detail = ('paths.crashDirs = ' + ($dirs -join ', ')) } }
      if ($glob) { return @{ met = $true; detail = ('paths.jvmCrashGlob = ' + $glob) } }
      return @{ met = $false; detail = 'paths.crashDirs is empty and paths.jvmCrashGlob is not set' }
    }

    'portProbe' {
      $known = ''
      if (Test-RkConfSet $Template 'paths.settingsFile') { $known = 'paths.settingsFile = ' + (Get-RkConfString $Template 'paths.settingsFile') }
      elseif (Test-RkConfSet $Template 'process.port')   { $known = 'process.port = ' + (Get-RkConfString $Template 'process.port') }
      if (-not $known) { return @{ met = $false; detail = 'no paths.settingsFile and no process.port - the port is not knowable without starting the server' } }
      $proto = (Get-RkConfString $Template 'process.portProtocol').ToLower()
      if (-not $proto) {
        return @{ met = $false; detail = ($known + ', but process.portProtocol is not declared. Get-RkPortHolders needs to be told tcp or udp - there is no listening state on a UDP socket, so asking the TCP question of a UDP game returns nothing forever rather than an error.') }
      }
      if ($script:RkConfPortProto -notcontains $proto) {
        return @{ met = $false; detail = ('process.portProtocol = ''' + $proto + ''' - the harness probes ' + ($script:RkConfPortProto -join '/') + ' only') }
      }
      return @{ met = $true; detail = ($known + ', protocol ' + $proto) }
    }

    'processProbe' {
      $names = @(Get-RkConfValue $Template 'process.names')
      $names = @($names | Where-Object { $_ })
      if ($names.Count -eq 0) { return @{ met = $false; detail = 'process.names is empty' } }
      return @{ met = $true; detail = ('process.names = ' + ($names -join ', ')) }
    }

    'pidFileProbe' {
      $names = @(Get-RkConfValue $Template 'process.names')
      $names = @($names | Where-Object { $_ })
      if (-not $Ctx.supervisorWritesPidFile) { return @{ met = $false; detail = 'the supervisor does not write a pid file' } }
      if ($names.Count -eq 0) { return @{ met = $false; detail = 'the supervisor writes a pid file, but process.names is empty so the pid cannot be confirmed to be this game' } }
      # THE PID FILE HOLDS WHAT RESPAWNKEEPER STARTED, WHICH IS NOT ALWAYS THE
      # GAME. With launch.kind='script' the supervisor starts a .bat and the
      # server is a grandchild, so the recorded pid is cmd.exe's. Measured
      # 2026-09-14 on the Everheim instance: server.pid named cmd while
      # valheim_server ran as pid 22416, and the runtime probe correctly
      # declined to count it (it confirms the pid against process.names, and
      # 'cmd' is not 'valheim_server') - so this probe can never fire for this
      # launch kind. Counting it anyway inflated twoLivenessProbes from the two
      # that work to three, and twoLivenessProbes is what safetyGate rests on.
      # A safety gate that over-counts its own evidence is the one failure
      # rk-capabilities.psd1 calls the worst outcome in the harness.
      # NOT "can never": the runtime reads TWO pid files - respawnkeeper's own
      # <state>\server.pid, which for a script launch holds the LAUNCHER, and
      # <ServerDir>\RUNNING.pid, which some launch scripts write themselves and
      # which does hold the game. Nothing in a template declares whether the
      # second one exists, so this checker cannot know. It counts the probe out,
      # which is the restrictive direction and cannot open a gate - but the
      # reason is "cannot be assumed", not "impossible".
      if ((Get-RkConfString $Template 'launch.kind').ToLower() -eq 'script') {
        return @{ met = $false; detail = "launch.kind='script': respawnkeeper's own pid file records the LAUNCHER, not the game (measured 2026-09-14: server.pid held cmd while valheim_server ran as a grandchild). A launcher-written RUNNING.pid would identify it, but no template declares one, so this probe is not counted" }
      }
      return @{ met = $true; detail = ('the supervisor writes ' + $Ctx.pidFileName + ', confirmed against process.names') }
    }

    'twoLivenessProbes' {
      $ok = @()
      foreach ($p in @('portProbe', 'processProbe', 'pidFileProbe')) {
        $r = Test-RkConfRequirement -Template $Template -ReqId $p -Ctx $Ctx
        if ($r.met -eq $true) { $ok += $p }
      }
      if ($ok.Count -ge 2) { return @{ met = $true; detail = ($ok.Count.ToString() + ' independent probes: ' + ($ok -join ', ')) } }
      return @{ met = $false; detail = ('only ' + $ok.Count.ToString() + ' probe(s) available: ' + (@($ok) -join ', ')) }
    }

    'stopChannel' {
      if (-not $stopKind) { return @{ met = $false; detail = 'stop.kind is not set' } }
      if ($script:RkConfStopKinds -notcontains $stopKind) {
        return @{ met = $false; detail = ('stop.kind = ''' + $stopKind + ''' is not implemented by Get-RkStopPlan (' + ($script:RkConfStopKinds -join '/') + ')') }
      }
      if ($stopKind -eq 'close' -and $captureStdout) {
        return @{ met = $false; detail = 'stop.kind = ''close'' cannot work while capture.stdout = $true (see conflict capture-vs-window-close)' }
      }
      if ($stopKind -eq 'stdin' -and ($launchKind -eq 'script') -and (-not $captureStdout)) {
        return @{ met = $false; detail = 'stop.kind = ''stdin'' has nothing to write to: a script owns its own console (see conflict stdin-without-console)' }
      }
      if ($stopKind -eq 'stdin' -and (-not (Test-RkConfSet $Template 'stop.command'))) {
        return @{ met = $false; detail = 'stop.kind = ''stdin'' but stop.command is empty' }
      }
      if ($stopKind -eq 'script' -and (-not (Test-RkConfSet $Template 'stop.script'))) {
        return @{ met = $false; detail = 'stop.kind = ''script'' but stop.script is empty' }
      }
      return @{ met = $true; detail = ('stop.kind = ' + $stopKind) }
    }

    'broadcastChannel' {
      $bk = (Get-RkConfString $Template 'broadcast.kind').ToLower()
      if (-not $bk) { return @{ met = $false; detail = 'broadcast.kind is not set' } }

      # 'bridge' - a server mod reads a file respawnkeeper drops and says it
      # in-game (2026-09-23, valheim/RkBridge). It is the one kind that does NOT
      # ride the stop channel: there is no shared pipe, so the "same channel as
      # stop" rule below has nothing to check and would only reject a channel
      # that demonstrably works.
      #
      # What replaces that rule is readyLine. A mod can be uninstalled, fail to
      # patch, or be left out of a second install of the same game, and a
      # template cannot see any of that. The mod announcing itself in the log
      # can, so the requirement is: say which line proves you are there. The
      # supervisor checks for it before it promises anybody a warning.
      if ($bk -eq 'bridge') {
        if (-not (Test-RkConfSet $Template 'broadcast.format')) {
          return @{ met = $false; detail = 'broadcast.kind = ''bridge'' but broadcast.format is empty' }
        }
        if (-not (Test-RkConfSet $Template 'broadcast.readyLine')) {
          return @{ met = $false; detail = 'broadcast.kind = ''bridge'' but broadcast.readyLine is empty - nothing would prove the mod is actually loaded' }
        }
        return @{ met = $true; detail = 'broadcast.kind = bridge (a server mod reads console-in\*.txt); presence is proven per boot by broadcast.readyLine' }
      }

      if ($bk -ne $stopKind) { return @{ met = $false; detail = ('broadcast.kind = ''' + $bk + ''' but the stop channel is ''' + $stopKind + '''') } }
      $sc = Test-RkConfRequirement -Template $Template -ReqId 'stopChannel' -Ctx $Ctx
      if ($sc.met -ne $true) { return @{ met = $false; detail = ('the shared channel does not work: ' + $sc.detail) } }
      if ($bk -eq 'stdin' -and (-not (Test-RkConfSet $Template 'broadcast.format'))) {
        return @{ met = $false; detail = 'broadcast.format is empty' }
      }
      return @{ met = $true; detail = ('broadcast.kind = ' + $bk + ', same channel as stop') }
    }

    'cleanShutdownEvidence' {
      if (-not (Test-RkConfSet $Template 'evidence.cleanShutdown')) {
        return @{ met = $false; detail = 'evidence.cleanShutdown is not set' }
      }
      return @{ met = $true; detail = 'evidence.cleanShutdown is set (its provenance is scored separately - a regex nobody watched match is not evidence)' }
    }

    'exceptionEvidence' {
      if (-not (Test-RkConfSet $Template 'evidence.exception')) { return @{ met = $false; detail = 'evidence.exception is not set' } }
      return @{ met = $true; detail = 'evidence.exception is set' }
    }

    'readyEvidence' {
      # Structural only. Whether the pattern MATCHES anything is a question for
      # a real log, which is what its provenance level records - a regex nobody
      # has watched match is not evidence, the same clause cleanShutdownEvidence
      # carries.
      if (-not (Test-RkConfSet $Template 'evidence.ready')) {
        return @{ met = $false; detail = 'evidence.ready is not set - no line has been identified as "it has finished starting"' }
      }
      return @{ met = $true; detail = 'evidence.ready is set (its provenance is scored separately)' }
    }

    'connectEvidence' {
      $c = Test-RkConfSet $Template 'evidence.connect'
      $d = Test-RkConfSet $Template 'evidence.disconnect'
      if ($c -and $d) { return @{ met = $true; detail = 'evidence.connect and evidence.disconnect are set' } }
      $miss = @()
      if (-not $c) { $miss += 'evidence.connect' }
      if (-not $d) { $miss += 'evidence.disconnect' }
      return @{ met = $false; detail = (($miss -join ' and ') + ' not set') }
    }

    'modsDir' {
      if (-not (Test-RkConfSet $Template 'paths.modsDir')) { return @{ met = $false; detail = 'paths.modsDir is not set' } }
      return @{ met = $true; detail = ('paths.modsDir = ' + (Get-RkConfString $Template 'paths.modsDir') + ' (existence is a folder check, done by Test-RkGameTemplate)') }
    }

    'modDependencySource' {
      if (-not (Test-RkConfSet $Template 'mods.dependencySource')) { return @{ met = $false; detail = 'mods.dependencySource is not set' } }
      return @{ met = $true; detail = ('mods.dependencySource = ' + (Get-RkConfString $Template 'mods.dependencySource')) }
    }

    'diagnosisRules' {
      $r = Get-RkConfString $Template 'rules'
      if (-not $r) { return @{ met = $false; detail = 'rules is not set' } }
      $p = Join-Path $Ctx.rulesDir $r
      if (-not (Test-Path -LiteralPath $p)) { return @{ met = $false; detail = ('rules = ''' + $r + ''' but rules\' + $r + ' does not exist') } }
      return @{ met = $true; detail = ('rules\' + $r) }
    }

    # Both implemented 2026-09-15. They are deliberately plain "is it set"
    # tests: whether the pattern is any GOOD is what the provenance column is
    # for, and conflating the two would let a guessed regex score as a met
    # requirement just because somebody wrote it down.
    'lagEvidence' {
      if (-not (Test-RkConfSet $Template 'evidence.lag')) {
        return @{ met = $false; detail = 'evidence.lag is not set - no phrase is known for "this server is falling behind"' }
      }
      return @{ met = $true; detail = 'evidence.lag is set (its provenance is scored separately)' }
    }

    # The daily scan has to decide which lines are a complaint before it can
    # classify any of them. Unset means it falls back to log4j severity tags,
    # which is right for Minecraft and matches nothing at all in a game that
    # does not tag its output - and zero matches is indistinguishable from a
    # quiet day. See evidence.level in games\valheim.psd1.
    'levelEvidence' {
      if (-not (Test-RkConfSet $Template 'evidence.level')) {
        return @{ met = $false; detail = 'evidence.level is not set - the daily scan falls back to log4j severity tags (WARN/ERROR/...), which a game that does not tag its output will never match' }
      }
      return @{ met = $true; detail = 'evidence.level is set (its provenance is scored separately)' }
    }

    default { return @{ met = $null; detail = 'this checker does not implement requirement id ''' + $ReqId + '''' } }
  }
}

# ---- one template ----------------------------------------------------------

function Invoke-RkTemplateConformance {
  # Everything above, for one template. Returns a result object; printing is the
  # caller's job.
  param(
    [Parameter(Mandatory)]$Template,
    [Parameter(Mandatory)]$Caps,
    [Parameter(Mandatory)]$Consumption,
    [Parameter(Mandatory)]$Ctx
  )

  $fails = @()
  $warns = @()

  # --- 1. conflicts
  $cf = Test-RkConfConflicts -Template $Template -Caps $Caps
  foreach ($h in $cf.hits) {
    $fails += @{ kind = 'conflict'; id = $h.id; detail = $h.detail; why = $h.why }
  }
  foreach ($u in $cf.unimplemented) {
    $warns += @{ kind = 'unimplemented-conflict'; id = $u; detail = 'rk-capabilities.psd1 declares this conflict but the checker has no rule for it'; why = 'An unchecked rule is indistinguishable from a passing one.' }
  }

  # --- 2/3. fields that must be consumed, and the files they point at
  $fieldFindings = @()
  foreach ($f in @($Caps.mustBeConsumed)) {
    $name = [string]$f
    if (-not (Test-RkConfHasKey $Template $name)) { continue }
    $state = $Consumption.fields[$name].state
    $isSet = Test-RkConfSet $Template $name
    $val = ''
    $raw = Get-RkConfValue $Template $name
    if ($raw -is [string]) { $val = $raw }

    if ($state -ne 'consumed') {
      # WHY the two halves are scored differently:
      #   a field carrying a real value that nothing reads is a live claim being
      #     thrown away -> FAIL (minecraft's logscan = 'logscan-minecraft.psd1')
      #   a field declared empty that nothing reads is clutter that still reads
      #     as "configured" to the next person -> WARN (valheim's rules = '')
      # The bound/ambiguous distinction does not change the score, only the
      # wording: it says whether the checker found NOTHING at all, or found
      # references that turned out to be on some other object. Both are printed
      # with file:line so the negative can be checked by eye.
      $how = ''
      if ($state -eq 'dead') {
        $how = 'no harness code reads <template>.' + $name + ' - all three probes came back empty ($x.' + $name + ", `$x['" + $name + "'], and the bare quoted name)"
      } else {
        $refs = @(@($Consumption.fields[$name].ambiguous) + @($Consumption.fields[$name].literal))
        $how = 'no harness code reads <template>.' + $name + '. The ' + $refs.Count + ' reference(s) found are on other objects, not on a game template: ' + (($refs | Select-Object -First 4) -join '; ')
      }
      if ($isSet) {
        $rec = @{ kind = 'dead-field'; id = $name; severity = 'FAIL'
                  detail = ('set' + $(if ($val) { " to '" + $val + "'" } else { '' }) + ', but ' + $how) }
        $fails += $rec
      } else {
        $rec = @{ kind = 'dead-field'; id = $name; severity = 'WARN'
                  detail = ('declared but empty, and ' + $how + '. Remove it or wire it up - an empty field still reads as configured.') }
        $warns += $rec
      }
      $fieldFindings += $rec
    }
    else {
      $where = @(@($Consumption.fields[$name].bound) | Select-Object -First 2)
      $fieldFindings += @{ kind = 'consumed-field'; id = $name; severity = 'ok'
                           detail = ('read at ' + ($where -join '; ')) }
    }
  }

  # referenced rule tables must exist on disk
  $refFindings = @()
  foreach ($name in @('rules', 'logscan')) {
    if (-not (Test-RkConfHasKey $Template $name)) { continue }
    $v = Get-RkConfString $Template $name
    if (-not $v) { continue }
    $p = Join-Path $Ctx.rulesDir $v
    if (Test-Path -LiteralPath $p) {
      $refFindings += @{ id = $name; severity = 'ok'; detail = ($name + ' -> rules\' + $v + ' exists') }
    } else {
      $rec = @{ kind = 'missing-file'; id = $name; severity = 'FAIL'
                detail = ($name + ' -> rules\' + $v + ' DOES NOT EXIST') }
      $fails += $rec
      $refFindings += $rec
    }
  }

  # --- 4/5. requirements, then features
  $reqs = @{}
  foreach ($k in @($Caps.requirements.Keys)) {
    $r = Test-RkConfRequirement -Template $Template -ReqId $k -Ctx $Ctx
    $prov = Get-RkConfReqProvenance -Template $Template -ReqId $k
    $reqs[$k] = @{
      met       = $r.met
      detail    = $r.detail
      why       = [string]$Caps.requirements[$k].why
      test      = [string]$Caps.requirements[$k].test
      provLevel = $prov.level
      provWhere = $prov.source
    }
    if ($null -eq $r.met) {
      $warns += @{ kind = 'unimplemented-requirement'; id = $k; detail = $r.detail
                   why = 'A requirement the checker cannot evaluate must not be reported as satisfied.' }
    }
  }

  # --- 4b. THE TWO LEDGERS MUST AGREE ---------------------------------------
  # A template states the same claim in two places and they are read in
  # different orders:
  #
  #   verified   = @{ launch = $true }              <- what a person promoted
  #   provenance = @{ launch = @{ by = 'inferred' } } <- what the file still says
  #
  # Get-RkConfReqProvenance consults the provenance block FIRST and only falls
  # back to verified when there is no explicit entry. So an entry left at
  # 'inferred' does not merely fail to help - it OVERRIDES the promotion, and
  # the stricter answer wins silently. Deleting the entry would have unblocked
  # the feature; writing it honestly, and then not maintaining it, blocked it.
  #
  # That is what happened to valheim: [R-086] flipped verified.launch and
  # verified.stop to $true on the strength of a real supervised run, the
  # provenance block was never touched, and the template went on reporting
  # 0 features on / 9 blocked while its own header described the run that
  # earned them. Nothing warned, because each half was internally consistent.
  #
  # SEVERITY IS SPLIT, because only some of these pairs are actually a
  # contradiction. 'launch' and 'stop' each certify ONE event, and the
  # provenance key of the same name describes that same event - "a person
  # watched it launch" and "never executed by respawnkeeper" cannot both be
  # true, so that is a FAIL. 'layout' is the catch-all fallback for nine
  # different requirements (ports, process names, connect strings, mods dir).
  # Saying "the folder was checked" and then "this particular port has never
  # been observed" is a REFINEMENT, not a contradiction - the honest, narrower
  # statement is the one that should win. That is a WARN: worth seeing, because
  # it means the promotion buys nothing for that requirement, but not a defect.
  $seenContra = @{}
  foreach ($rid in @($script:RkConfVerifiedFallback.Keys)) {
    $flag = $script:RkConfVerifiedFallback[$rid]
    if (-not (Test-RkConfTrue $Template ('verified.' + $flag))) { continue }
    $paths = @()
    if ($script:RkConfReqFields.ContainsKey($rid)) { $paths = Get-RkConfList $script:RkConfReqFields[$rid] }
    foreach ($p in $paths) {
      if (-not $p) { continue }
      if ((Get-RkConfProvenance $Template $p) -ne 'inferred') { continue }
      $key = $flag + '/' + $p
      if ($seenContra.ContainsKey($key)) { continue }
      $seenContra[$key] = $true
      # ...WITH ONE EXCEPTION. 'layout' is a catch-all for nine requirements, so
      # a narrower 'inferred' under it is usually a refinement. It is NOT a
      # refinement for the three that feed twoLivenessProbes: portProbe,
      # processProbe and pidFileProbe are the entire evidence base of
      # safetyGate, and an inferred one there drops the gate to
      # blocked:provenance - which is a WARN in a run that already prints two
      # dozen of them, so it disappears. Those three are scored as FAIL.
      $probeReq = @('portProbe', 'processProbe', 'pidFileProbe')
      $sev = 'FAIL'
      if (($flag -eq 'layout') -and ($probeReq -notcontains $rid)) { $sev = 'WARN' }
      $rec = @{ kind = 'ledger-contradiction'; id = $key; severity = $sev
                detail = ('verified.' + $flag + ' = $true, but the provenance entry covering ' + $p + ' still says inferred')
                why    = 'The provenance block is consulted before verified, so this entry silently overrides the promotion and keeps every feature that needs it blocked. Promote the entry to measured/human, or take verified.' + $flag + ' back down.' }
      if ($sev -eq 'FAIL') { $fails += $rec } else { $warns += $rec }
      $fieldFindings += $rec
    }
  }

  $features = @()
  $featureNames = @($Caps.features.Keys | Sort-Object)
  # features can need other features (dailyMaintenance needs autoRestart), so
  # resolve iteratively until it settles.
  $state = @{}
  for ($pass = 0; $pass -lt 8; $pass++) {
    foreach ($fn in $featureNames) {
      $spec = $Caps.features[$fn]
      $unmet = @()
      $inferredOn = @()
      $pending = $false
      foreach ($n in (Get-RkConfList $spec.needs)) {
        if ($reqs.ContainsKey($n)) {
          if ($reqs[$n].met -ne $true) { $unmet += $n }
          elseif ($reqs[$n].provLevel -eq 'inferred') { $inferredOn += $n }
        }
        elseif ($Caps.features.ContainsKey($n)) {
          if (-not $state.ContainsKey($n)) { $pending = $true; continue }
          if ($state[$n].status -eq 'off' -or $state[$n].status -eq 'degraded') { $unmet += ($n + ' (feature)') }
          elseif ($state[$n].status -eq 'blocked:provenance') { $inferredOn += ($n + ' (feature)') }
        }
        else { $unmet += ($n + ' (unknown requirement)') }
      }
      if ($pending) { continue }
      $status = 'on'
      if ($unmet.Count -gt 0) {
        $status = [string]$spec.onUnmet
        if (-not $status) { $status = 'off' }
      } elseif ($inferredOn.Count -gt 0) {
        $status = 'blocked:provenance'
      }
      $wantsUnmet = @()
      foreach ($w in (Get-RkConfList $spec.wants)) {
        if ($reqs.ContainsKey($w) -and $reqs[$w].met -ne $true) { $wantsUnmet += $w }
      }
      $state[$fn] = @{ name = $fn; label = [string]$spec.label; status = $status
                       unmet = $unmet; inferred = $inferredOn; wantsUnmet = $wantsUnmet
                       note = [string]$spec.note }
    }
  }
  foreach ($fn in $featureNames) {
    if ($state.ContainsKey($fn)) { $features += $state[$fn] }
    else { $features += @{ name = $fn; label = ''; status = 'unresolved'; unmet = @('circular needs'); inferred = @(); wantsUnmet = @(); note = '' } }
  }

  # safetyGate failing structurally is the one capability failure that is a
  # conformance FAIL, because the capabilities file says so in as many words:
  # "This feature failing OPEN is the worst outcome in the whole harness."
  foreach ($ft in $features) {
    if ($ft.name -eq 'safetyGate' -and $ft.status -eq 'off') {
      $fails += @{ kind = 'safety-gate-off'; id = 'safetyGate'
                   detail = ('needs unmet: ' + (@($ft.unmet) -join ', '))
                   why = 'Every repair path must refuse to write while this is unmet. A template that cannot support it must not be driven unattended.' }
    }
    if ($ft.status -eq 'blocked:provenance') {
      $warns += @{ kind = 'provenance'; id = $ft.name
                   detail = ('everything it needs is structurally present, but ' + (@($ft.inferred) -join ', ') + ' rests on inferred claims')
                   why = 'inferred = deduced from layout, docs or research. Research is not evidence. Promote to measured or human before switching this on.' }
    }
  }

  return @{
    id       = [string]$Template.id
    name     = [string]$Template.displayName
    file     = [string]$Template.templateFile
    fails    = $fails
    warns    = $warns
    fields   = $fieldFindings
    refs     = $refFindings
    reqs     = $reqs
    features = $features
    conflicts = $cf
  }
}
