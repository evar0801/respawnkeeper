# ============================================================
# rk-setup.ps1 - build a respawnkeeper environment for ONE server folder,
#                in its own window, and hand back a double-clickable launcher.
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# Entry point: respawnkeeper.bat (double-click, or drop a server folder on it).
#
# WHAT IT PRODUCES, all inside the server folder - nothing is written anywhere
# else, and nothing is started without being asked:
#
#   <ServerDir>\respawnkeeper\profile.json   the per-server policy
#   <ServerDir>\rk-start.bat                 double-click to run the server under respawnkeeper
#   <ServerDir>\rk-stop.bat                  double-click for a clean stop that will NOT be restarted
#   <ServerDir>\rk-restart.bat               double-click to restart NOW through the maintenance lap
#   <ServerDir>\rk-diagnose.bat              double-click to read the last crash without changing anything
#
# WHY PER-SERVER. One harness serves fc8 (friends play on it) and pokemoncraft
# (nobody connected yet). "Repair and restart while I sleep" is a reasonable
# answer for one and not the other, so the policy cannot live in a single
# harness-wide config file.
#
# NOTE ON THE WINDOW. When the operator double-clicks respawnkeeper.bat, this runs in
# a real console window and can show a folder picker. A process launched by an
# agent gets no interactive desktop, so the picker is skipped there and the
# path has to be passed on the command line - see -ServerDir / -NonInteractive.
# ============================================================

param(
  [string]$ServerDir = '',        # skip the picker
  [ValidateSet('', 'watch', 'unattended', 'manual')]
  [string]$Policy   = '',        # skip the policy question ('profile' is a reserved PS variable)
  [switch]$NonInteractive,        # never prompt; requires -ServerDir and -Profile
  [switch]$NoLaunch,              # create everything, do not offer to start
  [switch]$NoRegister,            # do not add this folder to servers.json (the test sandboxes pass this)
  [ValidateSet('ja', 'en')]
  [string]$Lang = 'ja',           # 'en' shows the original text and loads no dictionary
  [string]$LangReport = ''        # write every line that had no translation to this file
)

$ErrorActionPreference = 'Stop'
$HarnessDir = $PSScriptRoot
. (Join-Path $HarnessDir 'lib\rk-common.ps1')

# ============================================================================
# LANGUAGE LAYER (2026-09-13, [R-079])
#
# The wizard has 143 places that print something. Rewriting all of them to look
# a string up would be 143 chances to break a working tool, so the swap happens
# at the ONE place they all pass through instead: Write-Host and Read-Host are
# shadowed here by functions of the same name, and PowerShell resolves a call
# to the nearest definition - so every existing call site is covered with no
# call site edited.
#
# THE JAPANESE IS NOT IN THIS FILE ON PURPOSE. PS 5.1 decodes a BOM-less .ps1
# as ANSI, and a single Japanese character in a script file breaks the parser
# (project rule; same reason as rules\logscan-report.ja.json and
# ui\panel-strings.ja.json). It lives in rk-setup-strings.ja.json, read as UTF-8.
#
# SAFETY PROPERTY, and it is the reason this shape was chosen: T() returns its
# input unchanged when there is no entry. So with the dictionary absent, empty,
# or -Lang en, the wizard prints EXACTLY what it printed before - byte for byte.
# That is checked by capturing the output before and after and diffing it, not
# by reading the code.
#
# Anything with no entry is COLLECTED rather than guessed at: -LangReport writes
# the untranslated lines out, so the dictionary can be finished from what the
# tool actually printed instead of from what someone thought it printed. Lines
# built by concatenation ('  x ' + $ex.Message) can never match a fixed key and
# are expected to stay English; they are runtime detail, not UI.
# ============================================================================
$global:RkSetupLang        = @{}
$global:RkSetupLangMissing = New-Object 'System.Collections.Generic.HashSet[string]'

function Test-RkConsoleCanShowJapanese {
  # Can this console actually PRINT the dictionary, or would it print question
  # marks? PowerShell 5.1 encodes console output with [Console]::OutputEncoding,
  # which is the console codepage - 932 on this machine (measured 2026-09-13, so
  # Japanese renders natively and nothing needs changing). On a console left at
  # 437 the same text would come out as '?????'.
  #
  # Switching the encoding to UTF-8 would NOT fix that: the console still
  # interprets the bytes with its own codepage, so it trades one kind of garbage
  # for another. Falling back to English is the honest answer - the operator
  # gets text they can read either way, and is told why.
  #
  # Every string in rk-setup-strings.ja.json is checked to survive cp932 as part
  # of adding it, so this probe standing in for the whole file is sound.
  try {
    $enc   = [Console]::OutputEncoding
    if (-not $enc) { return $false }
    $probe = [string][char]0x30C6 + [string][char]0x30B9 + [string][char]0x30C8   # katakana TE SU TO
    return ($enc.GetString($enc.GetBytes($probe)) -eq $probe)
  } catch { return $false }
}

if ($Lang -eq 'ja' -and -not (Test-RkConsoleCanShowJapanese)) {
  Microsoft.PowerShell.Utility\Write-Host '  ! this console cannot display Japanese (codepage), so this run is in English.' -ForegroundColor DarkGray
  $Lang = 'en'
}

if ($Lang -eq 'ja') {
  $langFile = Join-Path $HarnessDir 'rk-setup-strings.ja.json'
  if (Test-Path -LiteralPath $langFile -PathType Leaf) {
    try {
      $raw = [System.IO.File]::ReadAllText($langFile, (New-Object System.Text.UTF8Encoding($false)))
      $obj = $raw | ConvertFrom-Json
      foreach ($p in $obj.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }   # _comment and friends are notes, not strings
        $global:RkSetupLang[[string]$p.Name] = [string]$p.Value
      }
    } catch {
      # A broken dictionary must not stop somebody setting up a server. Fall
      # back to English and say so once, in English, because the thing that
      # renders Japanese is what just failed.
      $global:RkSetupLang = @{}
      Microsoft.PowerShell.Utility\Write-Host ('  ! could not read ' + $langFile + ' - falling back to English: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
  }
}

function T {
  # Look up one line. Leading spaces are layout, not text, so they are peeled
  # off before the lookup and put back afterwards - that keeps the dictionary
  # keys readable and stops the same sentence needing three entries because it
  # is indented differently in three places.
  param([string]$s)
  if ([string]::IsNullOrEmpty($s)) { return $s }
  $trimmed = $s.TrimStart(' ')
  if ($trimmed.Length -eq 0) { return $s }
  $indent  = $s.Substring(0, $s.Length - $trimmed.Length)
  $tail    = ''
  $core    = $trimmed.TrimEnd(' ')
  if ($core.Length -lt $trimmed.Length) { $tail = $trimmed.Substring($core.Length) }
  if ($global:RkSetupLang.ContainsKey($core)) { return ($indent + $global:RkSetupLang[$core] + $tail) }
  [void]$global:RkSetupLangMissing.Add($core)
  return $s
}

function Write-Host {
  # Shadows the cmdlet for this script and anything it calls. Only the two
  # parameters this wizard actually uses are accepted; a third one appearing in
  # future should fail loudly here rather than be silently dropped.
  [CmdletBinding()]
  param(
    [Parameter(Position = 0, ValueFromPipeline = $true)] [object]$Object,
    [System.ConsoleColor]$ForegroundColor,
    [switch]$NoNewline
  )
  $s = if ($null -eq $Object) { '' } else { T ([string]$Object) }
  if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
    Microsoft.PowerShell.Utility\Write-Host $s -ForegroundColor $ForegroundColor -NoNewline:$NoNewline
  } else {
    Microsoft.PowerShell.Utility\Write-Host $s -NoNewline:$NoNewline
  }
}

function Read-Host {
  [CmdletBinding()]
  param([Parameter(Position = 0)] [string]$Prompt)
  Microsoft.PowerShell.Utility\Read-Host -Prompt (T $Prompt)
}

function Write-RkLangReport {
  if (-not $LangReport) { return }
  $lines = @('# lines rk-setup printed with no entry in rk-setup-strings.ja.json',
             '# ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  count=' + $global:RkSetupLangMissing.Count, '')
  $lines += (@($global:RkSetupLangMissing) | Sort-Object)
  [System.IO.File]::WriteAllLines($LangReport, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-RkTextWidth {
  # Columns a string occupies in a terminal, not characters. A Japanese
  # character is one .Length but takes TWO columns, so '{0,-14}' and
  # ('-' * $t.Length) - both of which count characters - draw a short rule and a
  # ragged column the moment the text stops being ASCII. Measured 2026-09-13:
  # the first Japanese run had every heading underlined half-way and the value
  # column stepped left and right down the screen.
  #
  # The ranges are the East Asian Wide and Fullwidth blocks that this tool can
  # actually print (kana, CJK, fullwidth punctuation). It is deliberately not a
  # full Unicode width table: anything outside these ranges counts as one, which
  # is the same answer the old code gave, so nothing that used to line up stops
  # lining up.
  param([string]$s)
  $w = 0
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if (($c -ge 0x1100 -and $c -le 0x115F) -or     # Hangul Jamo
        ($c -ge 0x2E80 -and $c -le 0xA4CF) -or     # CJK radicals .. Yi
        ($c -ge 0xAC00 -and $c -le 0xD7A3) -or     # Hangul syllables
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or     # CJK compatibility ideographs
        ($c -ge 0xFE30 -and $c -le 0xFE6F) -or     # CJK compatibility forms
        ($c -ge 0xFF00 -and $c -le 0xFF60) -or     # Fullwidth forms
        ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
  }
  return $w
}

function Title([string]$t) {
  $t = T $t
  Write-Host ''
  Write-Host ('  ' + $t) -ForegroundColor Cyan
  Write-Host ('  ' + ('-' * (Get-RkTextWidth $t))) -ForegroundColor DarkCyan
}
function Item([string]$k, [string]$v) {
  $k = T $k
  $pad = [Math]::Max(1, 14 - (Get-RkTextWidth $k))
  Write-Host ('    ' + $k + (' ' * $pad) + (T $v))
}
function Warn([string]$m) { Write-Host ('    ! ' + (T $m)) -ForegroundColor Yellow }
function Bad([string]$m)  { Write-Host ('    x ' + (T $m)) -ForegroundColor Red }
function Good([string]$m) { Write-Host ('    o ' + (T $m)) -ForegroundColor Green }

try { $host.UI.RawUI.WindowTitle = 'respawnkeeper setup' } catch {}
Write-Host ''
Write-Host '  ===========================================================' -ForegroundColor Cyan
Write-Host '   respawnkeeper - setup' -ForegroundColor Cyan
Write-Host '   Minecraft dedicated server: crash -> diagnose -> repair -> restart' -ForegroundColor DarkGray
Write-Host '  ===========================================================' -ForegroundColor Cyan

# ---- 1. Which server folder? -----------------------------------------------
Title '1. server folder'

function Select-ServerFolder {
  # The folder picker only works from a real interactive desktop session.
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the server folder (the one holding mods\, config\, logs\ and run.bat)'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return ''
  } catch { return '' }
}

if (-not $ServerDir) {
  if ($NonInteractive) { Bad '-ServerDir is required with -NonInteractive.'; exit 2 }
  Write-Host '    Choose the server folder - the one that holds mods\, config\, logs\ and run.bat.'
  Write-Host '    (A folder picker will open. You can also drag the folder onto respawnkeeper.bat.)'
  $ServerDir = Select-ServerFolder
  if (-not $ServerDir) {
    Write-Host ''
    $ServerDir = Read-Host '    Paste the server folder path'
    $ServerDir = $ServerDir.Trim().Trim('"')
  }
}
if (-not $ServerDir) { Bad 'No folder given. Nothing was changed.'; exit 2 }

try { $ServerDir = Resolve-RkServerDir -Path $ServerDir }
catch {
  Bad $_.Exception.Message
  Warn 'That folder has no libraries\ subfolder, so it is not a Minecraft server install.'
  Warn 'Pick the folder run.bat sits in, not the modpack or the client folder.'
  if (-not $NonInteractive) { Write-Host ''; Read-Host '    Press Enter to close' | Out-Null }
  exit 2
}
Good $ServerDir

# ---- 2. What is it? ---------------------------------------------------------
Title '2. what is installed there'

# Which game? A template answers all five questions respawnkeeper needs: how to
# start it, how to stop it without losing the save, where the logs are, what a
# crash looks like, and what may be repaired.
$game = Find-RkGame -ServerDir $ServerDir
if (-not $game) {
  Bad 'No game template recognises this folder.'
  Warn ('Known games: ' + ((Get-RkGameTemplates | ForEach-Object { $_.id }) -join ', '))
  Write-Host ''
  Write-Host '    respawnkeeper can WRITE a template for this folder by looking at what is in it'
  Write-Host '    (rk-newgame.ps1 - it inspects the folder and asks the model to describe it).'
  if ($NonInteractive) { Warn 'Not generating one in -NonInteractive mode.'; exit 2 }
  $gen = Read-Host '    Generate a template for this folder now? [y/N]'
  if ($gen.Trim().ToLower() -ne 'y') { Write-Host '    Nothing was changed.'; Read-Host '    Press Enter to close' | Out-Null; exit 2 }
  & (Join-Path $HarnessDir 'rk-newgame.ps1') -ServerDir $ServerDir
  $game = Find-RkGame -ServerDir $ServerDir
  if (-not $game) {
    Bad 'Still no match after generating. Nothing was changed in the server folder.'
    Read-Host '    Press Enter to close' | Out-Null
    exit 2
  }
}
Good ($game.displayName + '   [' + $game.id + ']')

# Every path claim the template makes is re-checked against the REAL folder. A
# template that guessed wrong is rejected here rather than driving a live server.
$check = Test-RkGameTemplate -ServerDir $ServerDir -Template $game
foreach ($w in $check.warnings) { Warn $w }
if (-not $check.ok) {
  Bad ('The template for ' + $game.id + ' does not match this folder:')
  foreach ($p in $check.problems) { Bad ('  ' + $p) }
  Warn 'Refusing to use it. Fix the template, or let rk-newgame.ps1 write one from the real folder.'
  if (-not $NonInteractive) { Write-Host ''; Read-Host '    Press Enter to close' | Out-Null }
  exit 2
}

$loader = $null
if ($game.launch.kind -eq 'builtin') {
  $loader = Get-RkLoader -ServerDir $ServerDir
  if ($loader) {
    Item 'loader'    ($loader.kind + ' ' + $loader.version)
    Item 'minecraft' $loader.mcVersion
    # Verified by running java -version, not by reading a folder name.
    $java = Resolve-RkJava -Major $loader.javaMajor
    if ($java) { Item ('java ' + $loader.javaMajor) $java }
    else {
      Bad ('No Java ' + $loader.javaMajor + ' found (checked JAVA_HOME, vendor install folders, PATH).')
      Warn ('Minecraft ' + $loader.mcVersion + ' needs exactly Java ' + $loader.javaMajor + '; another major will not do.')
      if (-not $NonInteractive) { Write-Host ''; Read-Host '    Press Enter to close' | Out-Null }
      exit 2
    }
  }
}

try { Item 'launch' (Resolve-RkLaunch -ServerDir $ServerDir -Template $game).describe }
catch { Bad ('Cannot work out how to start it: ' + $_.Exception.Message); if (-not $NonInteractive) { Read-Host '    Press Enter to close' | Out-Null }; exit 2 }
Item 'stop'  (Get-RkStopPlan -ServerDir $ServerDir -Template $game).describe

$port = Get-RkServerPort -ServerDir $ServerDir -Template $game
Item 'port'  $(if ($port -gt 0) { $port } else { '(not discoverable - the port will not be used as evidence)' })
if ($game.id -eq 'minecraft') { Item 'world' (Get-RkLevelName -ServerDir $ServerDir) }

# What a human has actually watched happen. This is the difference between a
# template that was checked against a folder and one that was checked against
# reality, and it decides how bold setup is allowed to be below.
$ver = Get-RkGameVerificationLevel -Template $game
Item 'verified' ('layout=' + $ver.layout + '  launch=' + $ver.launch + '  stop=' + $ver.stop)
if (-not $ver.full) {
  Warn 'This game has NOT been fully verified by a human yet.'
  if ($ver.note) { Warn ('  ' + $ver.note) }
  Warn 'Until the stop path has been watched once, restarts and daily maintenance stay off.'
}

$live = Get-RkServerLiveness -ServerDir $ServerDir -Loader $loader -Template $game
if ($live.alive) { Warn ('That server looks like it is RUNNING right now: ' + ($live.reasons -join ' | ')) }
else { Item 'running now' 'no' }

# A second supervisor is the one conflict that cannot be detected at runtime -
# it just quietly starts the server underneath this one.
$legacy = Get-RkLegacyWatchdog -ServerDir $ServerDir
if ($legacy.taskArmed) {
  Warn ('The legacy fc8 watchdog is installed AND its scheduled task "' + $legacy.taskName + '" is ARMED.')
  Warn 'Two supervisors would start this server underneath each other, so respawnkeeper will refuse to run.'
  Warn ('Disarm it first:  powershell -File "' + $legacy.uninstall + '"')
}
foreach ($tn in @($game.conflicts.scheduledTasks | Where-Object { $_ })) {
  $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
  if ($t -and ($t.State -ne 'Disabled')) {
    Warn ('Another supervisor for this game is ARMED: scheduled task "' + $tn + '" (' + $t.State + ').')
    if ($game.conflicts.note) { Warn ('  ' + $game.conflicts.note) }
    Warn ('  Disable it before letting respawnkeeper run this server:  Disable-ScheduledTask -TaskName "' + $tn + '"')
  }
}

# ---- 3. Policy --------------------------------------------------------------
Title '3. how much should it do on its own'

$profiles = [ordered]@{
  'manual' = @{
    label = 'manual      - watch and record only. Never repairs, never restarts.'
    values = @{ autoRestart = $false; autoRepair = $false; escalateOnHalt = $false; useHook = $false }
  }
  'watch' = @{
    label = 'watch       - diagnose every crash and restart the known-harmless ones. No repairs.'
    values = @{ autoRestart = $true;  autoRepair = $false; escalateOnHalt = $false; useHook = $false }
  }
  'unattended' = @{
    label = 'unattended  - diagnose, repair, and restart without waking you. Uses the model.'
    values = @{ autoRestart = $true;  autoRepair = $true;  escalateOnHalt = $true;  useHook = $true }
  }
}

if (-not $Policy) {
  if ($NonInteractive) { Bad '-Policy is required with -NonInteractive.'; exit 2 }
  # T() here, not on the composed line: the menu line is built from the key
  # letter plus the label, so only the label half is fixed text worth a
  # dictionary entry.
  foreach ($k in $profiles.Keys) { Write-Host ('    [' + $k.Substring(0,1) + '] ' + (T $profiles[$k].label)) }
  Write-Host ''
  Write-Host '    unattended still stops for: a crash loop (3 in 30 min), a repair that did not' -ForegroundColor DarkGray
  Write-Host '    stick, and anything the model flags as needing a person. It never deletes a' -ForegroundColor DarkGray
  Write-Host '    file - everything it moves goes to respawnkeeper\quarantine\ and can be undone.' -ForegroundColor DarkGray
  Write-Host ''
  $ans = Read-Host '    Choose [m/w/u] (default w)'
  switch ($ans.Trim().ToLower()) {
    'm' { $Policy = 'manual' }
    'u' { $Policy = 'unattended' }
    default { $Policy = 'watch' }
  }
}
$sel = $profiles[$Policy]
Good ($Policy + '  -  ' + (T $sel.label))

$hookPath = ''
if ($sel.values.useHook) {
  $hookPath = Join-Path $HarnessDir 'hooks\escalate-claude.ps1'
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Warn 'The claude CLI is not on PATH, so escalation cannot run. Crashes Tier1 cannot place will just HALT.'
    Warn 'That is safe, only less autonomous. Install/authenticate the CLI and re-run setup to enable it.'
    $hookPath = ''
  }
}

# A game whose stop path has never been watched by a human does not get to be
# stopped and restarted unattended. An untested shutdown that fails to save is
# not a recoverable mistake.
#
# 2026-09-12 ([R-071]): this used to knock down autoRestart ONLY, which left the
# most autonomous preset ('unattended') running with autoRepair still ON for a
# game nobody has ever stopped by hand. Repair writes to the server, and the one
# thing standing in front of that write is Assert-RkServerStopped - whose
# liveness proof is only as strong as the template. On Minecraft it has three
# independent probes; a game verified by layout alone may have one. Unverified
# means unverified: both switches go off together.
if (-not $ver.stop) {
  if ($sel.values.autoRestart -or $sel.values.autoRepair) {
    Warn ('The stop path for ' + $game.id + ' has never been verified, so automatic restart and repair are being turned OFF for now.')
    Warn ('Stop it once by hand with rk-stop.bat, confirm the world saved, then set verified.stop = $true in games\' + $game.id + '.psd1.')
  }
  $sel.values.autoRestart = $false
  $sel.values.autoRepair  = $false
}

# ---- 3b. Which account pays ------------------------------------------------
Title '3b. which account pays for the model'

$modelBackend = 'subscription'
$modelName    = 'claude-opus-5'
$apiKeyEnv    = 'ANTHROPIC_API_KEY'

if ($hookPath) {
  Write-Host '    [s] subscription - run the claude CLI on your account login. No metered charge.  (default)'
  Write-Host '    [a] api          - bill an API key instead (pay per use).'
  Write-Host ''
  Write-Host '    respawnkeeper NEVER stores an API key. Choosing api records only the NAME of an' -ForegroundColor DarkGray
  Write-Host '    environment variable; the value has to already be set on this machine. If it is' -ForegroundColor DarkGray
  Write-Host '    not set when a crash happens, escalation HALTs and says so - it will not quietly' -ForegroundColor DarkGray
  Write-Host '    fall back to the other account and bill the wrong one.' -ForegroundColor DarkGray
  Write-Host ''
  if (-not $NonInteractive) {
    $mb = Read-Host '    Choose [s/a] (default s)'
    if ($mb.Trim().ToLower() -eq 'a') {
      $modelBackend = 'api'
      $envName = Read-Host ('    Environment variable holding the key (Enter for ' + $apiKeyEnv + ')')
      if ($envName.Trim()) { $apiKeyEnv = $envName.Trim() }
      if (-not [System.Environment]::GetEnvironmentVariable($apiKeyEnv)) {
        Warn ($apiKeyEnv + ' is not set on this machine right now.')
        Warn 'That is fine to record, but escalation will HALT until you set it (setx, or System environment variables).'
      } else {
        Good ($apiKeyEnv + ' is set - the value is not read or stored by respawnkeeper.')
      }
    }
  }
  Good ($modelBackend + ($(if ($modelBackend -eq 'api') { '  (' + $apiKeyEnv + ')' } else { '' })))
} else {
  Item 'model' 'not used by this policy'
}

# ---- 3b2. May a mod ever be removed unattended? -----------------------------
Title '3b2. is this world already being played'

# A dependency graph can prove that removing a mod breaks other MODS. Nothing in
# a jar can tell you that removing it empties chests in a world people have been
# playing for months. That is not measurable, so it is declared once, by a human,
# instead of guessed at 3am.
$allowModRemoval = $true
if ($sel.values.autoRepair) {
  $idx = Get-RkModIndex -ServerDir $ServerDir -Template $game
  if ($idx.available) {
    $leaf = 0; $lb = 0
    foreach ($k in $idx.mods.Keys) { if ($idx.dependents.ContainsKey($k)) { $lb++ } else { $leaf++ } }
    Item 'mods scanned' ($idx.scanned)
    Item 'leaf mods'    ($leaf.ToString() + '  (nothing requires them - these are the only ones ever removable)')
    Item 'load-bearing' ($lb.ToString()   + '  (something requires them - never removed unattended)')
    $top = $idx.dependents.GetEnumerator() | Where-Object { $idx.mods.ContainsKey($_.Key) } |
      Sort-Object { @($_.Value).Count } -Descending | Select-Object -First 3
    foreach ($t in $top) { Item '' ('  ' + $t.Key + ' <- required by ' + @($t.Value).Count) }
  }
  Write-Host ''
  Write-Host '    If people have already played on this world, removing a content mod takes its'
  Write-Host '    blocks and items out of the save with it. No jar records that, so it is your call.' -ForegroundColor DarkGray
  Write-Host ''
  if ($NonInteractive) {
    Item 'world played' 'assumed NOT played (-NonInteractive)'
  } else {
    $wp = Read-Host '    Has this world already been played on? [y/N]'
    if ($wp.Trim().ToLower() -eq 'y') {
      $allowModRemoval = $false
      Good 'mods will NEVER be removed unattended. A crash that needs one will HALT with a comeback note.'
    } else {
      Good 'a leaf mod (nothing requires it, not distributed to players) may be pulled for one night.'
    }
  }
} else {
  Item 'mod removal' 'not applicable (this policy never repairs)'
}

# ---- 3c. The daily 10:00 check ---------------------------------------------
Title '3c. the daily restart and log check'

$maintEnabled = $false
$maintAt      = '10:00'
Write-Host '    Once a day: warn, stop cleanly, read the day''s logs, write a report, start again.'
Write-Host '    The report is a list of what the logs complained about WITHOUT crashing - the kind of' -ForegroundColor DarkGray
Write-Host '    thing worth sitting down with. Nothing in it is fixed automatically.' -ForegroundColor DarkGray
Write-Host ''
if (-not $ver.stop) {
  Warn 'Off for now: it needs a verified clean stop, and this game does not have one yet.'
} elseif ($NonInteractive) {
  Item 'daily check' 'off (-NonInteractive)'
} else {
  $dm = Read-Host '    Enable it? [y/N]'
  if ($dm.Trim().ToLower() -eq 'y') {
    $maintEnabled = $true
    $at = Read-Host '    At what time? (HH:MM, Enter for 10:00)'
    if ($at.Trim() -match '^\d{1,2}:\d{2}$') { $maintAt = $at.Trim() }
    Good ('daily at ' + $maintAt)
  } else {
    Item 'daily check' 'off'
  }
}

# ---- 4. Write the environment ----------------------------------------------
Title '4. creating the environment'

$stateDir = Get-RkStateDir -ServerDir $ServerDir
$profileFile = Join-Path $stateDir 'profile.json'

$existing = Read-RkJson -Path $profileFile
# THE NAME SURVIVES A RE-RUN. serverLabel is the one field in this file a person
# types (the panel's rename sheet, [R-093]); rewriting it from the folder name
# on "Overwrite it? y" threw that away, silently ([R-091] W9). Whatever they
# called it is carried across; only a profile with no label gets the folder.
$keepLabel = (Split-Path -Leaf $ServerDir)
if ($existing -and $existing.serverLabel) { $keepLabel = [string]$existing.serverLabel }
if ($existing -and (-not $NonInteractive)) {
  Warn ('A profile already exists here (' + $existing.profile + ', created ' + $existing.createdAt + ').')
  $ow = Read-Host '    Overwrite it? [y/N]'
  if ($ow.Trim().ToLower() -ne 'y') { Write-Host '    Kept the existing profile.'; $Policy = $existing.profile; $sel = $profiles[$Policy] }
  else { $existing = $null }
} elseif ($existing) {
  # -NonInteractive USED TO WRITE NOTHING AT ALL HERE, AND SAY NOTHING ABOUT IT.
  # The overwrite question is the only thing that cleared $existing, so skipping
  # the question left it set, the write below was guarded by `if (-not
  # $existing)`, and the run fell straight through to the summary - which prints
  # the TEMPLATE's values, not the file's. Measured 2026-09-14 on the Everheim
  # instance: the screen said "verified = layout=True launch=True stop=True" and
  # profile.json still held stop=false from 2026-09-13 10:21:38, unchanged, its
  # createdAt untouched. Re-running setup to pick up a promotion is exactly what
  # a person re-runs setup FOR, and it was the one thing it could not do.
  #
  # "Do not ask" now means "do what you were told", not "do nothing quietly":
  # the profile is replaced, the previous one is kept beside it, and the
  # replacement is announced. Nothing that is typed by a person is lost -
  # serverLabel is carried across by $keepLabel above.
  try {
    if (Test-Path -LiteralPath $profileFile) {
      Copy-Item -LiteralPath $profileFile -Destination ($profileFile + '.bak') -Force -ErrorAction Stop
    }
  } catch { Warn ('could not keep a copy of the old profile: ' + $_.Exception.Message) }
  Warn ('Replacing the existing profile (' + $existing.profile + ', created ' + $existing.createdAt + '). The previous one is beside it as profile.json.bak.')
  if (-not $Policy) { $Policy = $existing.profile; $sel = $profiles[$Policy] }
  $existing = $null
}

if (-not $existing) {
  Write-RkJson -Path $profileFile -Object ([ordered]@{
    schema      = 'respawnkeeper/profile/2'
    profile     = $Policy
    createdAt   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    serverDir   = $ServerDir
    serverLabel = $keepLabel

    # Pinned on purpose: if two templates could ever match this folder, the
    # supervisor must keep using the one that was verified here, today, rather
    # than re-deciding on some later boot.
    game        = $game.id
    gameName    = $game.displayName
    gameVerified = @{ layout = $ver.layout; launch = $ver.launch; stop = $ver.stop }

    loader      = $(if ($loader) { $loader.kind + ' ' + $loader.version } else { '' })
    mcVersion   = $(if ($loader) { $loader.mcVersion } else { '' })
    javaMajor   = $(if ($loader) { $loader.javaMajor } else { 0 })

    # Which account pays. The API KEY IS NEVER HERE - only the name of the
    # environment variable that holds it.
    model = @{
      backend   = $modelBackend
      name      = $modelName
      apiKeyEnv = $apiKeyEnv
    }

    # The daily restart + log read. restartAfter is what makes it a maintenance
    # cycle rather than a shutdown.
    dailyMaintenance = @{
      enabled      = $maintEnabled
      at           = $maintAt
      analyzeLogs  = $true
      restartAfter = $true
    }

    autoRestart = $sel.values.autoRestart
    autoRepair  = $sel.values.autoRepair
    escalationHook = $hookPath
    escalateOnHalt = ($sel.values.escalateOnHalt -and $hookPath)
    escalationTimeoutMin = 45

    # The breaker is written out explicitly so it is visible and auditable, not
    # buried in a default. It is meant to be adjusted, not removed [R-007].
    crashLoopCount     = 3
    crashLoopWindowMin = 30
    soakMin            = 20
    maxRepairAttempts  = 1
    restartBackoffSec  = 10

    # An exit with no crash evidence (Task Manager kill, window closed, machine
    # sleep) is NOT a crash and is not restarted. This is requirement 3.
    restartAfterUnknownExit = $false

    # May the unattended path ever move a mod out of mods\? The mechanical gates
    # (nothing depends on it, players do not download it) are enforced anyway
    # and cannot be switched off; this is the extra, non-measurable one - whether
    # the world already holds content from that mod.
    allowModRemoval = $allowModRemoval

    enableHangWatch = $true
    hangStaleMin    = 15

    # Notifications are per-severity, not on/off. 'important' means only the
    # states where the server is DOWN and waiting for a person get a toast;
    # progress reports stay in the logs. Turning the lot off is what buries the
    # HALT notice, which is the one worth hearing [R-023].
    enableToast     = $true
    toastLevel      = 'important'   # off | important | all
  })
  Good ('profile.json  ->  ' + $profileFile)
}

# ---- The three double-clickable files ---------------------------------------
$psExe = 'powershell'
$rkPs1 = Join-Path $HarnessDir 'respawnkeeper.ps1'
$dgPs1 = Join-Path $HarnessDir 'rk-diagnose.ps1'

$startBat = @"
@echo off
rem Generated by rk-setup.ps1 - double-click to run this server under respawnkeeper.
rem Policy lives in respawnkeeper\profile.json, not in this file.
title respawnkeeper - %~n0
"$psExe" -NoProfile -ExecutionPolicy Bypass -File "$rkPs1" -ServerDir "%~dp0."
echo.
echo [respawnkeeper] stopped. This window stays open so you can read the last lines.
pause
"@

$stopBat = @"
@echo off
rem Generated by rk-setup.ps1 - double-click for a CLEAN stop.
rem respawnkeeper treats this as intentional and will NOT restart or repair afterwards.
type nul > "%~dp0STOP_SERVER"
echo Stop signal sent. The server will save the world and shut down shortly.
echo respawnkeeper will exit too - it does not restart a server you stopped on purpose.
pause
"@

$restartBat = @"
@echo off
rem Generated by rk-setup.ps1 - restart NOW through the maintenance lap:
rem   warn the players -> clean stop -> read the day's logs -> start again.
rem Only respawnkeeper reads this file, so it does nothing unless the server
rem was started with rk-start.bat. Nothing is ever killed: if the clean stop
rem does not work, respawnkeeper stands down and says so in watchdog.log.
type nul > "%~dp0MAINTENANCE_NOW"
echo Maintenance-restart signal sent. respawnkeeper will warn the players, stop
echo the server cleanly, read the logs, and start it again.
echo (Nothing happens if respawnkeeper is not watching this server.)
pause
"@

$diagBat = @"
@echo off
rem Generated by rk-setup.ps1 - read the last crash. Changes nothing.
title respawnkeeper - diagnose
"$psExe" -NoProfile -ExecutionPolicy Bypass -File "$dgPs1" -ServerDir "%~dp0."
pause
"@

foreach ($f in @(
    @{ p = (Join-Path $ServerDir 'rk-start.bat');    c = $startBat },
    @{ p = (Join-Path $ServerDir 'rk-stop.bat');     c = $stopBat },
    @{ p = (Join-Path $ServerDir 'rk-restart.bat');  c = $restartBat },
    @{ p = (Join-Path $ServerDir 'rk-diagnose.bat'); c = $diagBat })) {
  # .bat must be ASCII/ANSI without a BOM: cmd.exe echoes a leading BOM as a
  # stray character and can fail on the first line. And CRLF regardless of how
  # THIS file is checked out: the here-strings above carry whatever line ending
  # rk-setup.ps1 has (LF, on this machine), and cmd.exe wants CRLF - LF-only
  # batch files mostly work, until a label or a parenthesised block does not.
  $body = ($f.c -replace "`r?`n", "`r`n")
  [System.IO.File]::WriteAllText($f.p, $body, (New-Object System.Text.ASCIIEncoding))
  Good ((Split-Path -Leaf $f.p) + '  ->  ' + $f.p)
}

# ---- Register with the panel ------------------------------------------------
# The panel finds Minecraft folders by sweeping the two Minecraft trees on its
# own. Anything else - a Valheim server under valheim-work\ - can only be
# found through servers.json, and until 2026-09-13 NOTHING wrote that file
# except the sweep itself: a folder set up from the exe, the .bat, or even the
# panel's own add sheet stayed invisible to the one window that has the
# buttons. Idempotent, and it writes nothing inside the server folder.
if (-not $NoRegister) {
  $registry = Join-Path (Split-Path -Parent $HarnessDir) 'servers.json'
  try {
    $reg = Read-RkJson -Path $registry
    $list = New-Object System.Collections.Generic.List[string]
    if ($reg -and $reg.servers) { foreach ($s in @($reg.servers)) { if ($s) { [void]$list.Add([string]$s) } } }
    $mine = $ServerDir.TrimEnd('\')
    $have = $false
    foreach ($s in $list) { if ($s.TrimEnd('\') -ieq $mine) { $have = $true } }
    if (-not $have) { [void]$list.Add($mine) }
    Write-RkJson -Path $registry -Object ([ordered]@{
      schema  = 'respawnkeeper/servers/1'
      updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
      servers = @($list)
    })
    if ($have) { Good 'servers.json  ->  the panel already lists this folder' }
    else       { Good 'servers.json  ->  registered, so the panel shows this folder' }
  } catch { Warn ('could not register this folder for the panel (servers.json): ' + $_.Exception.Message) }
}

# ---- 5. Verify --------------------------------------------------------------
Title '5. verifying (nothing is started)'
& $rkPs1 -ServerDir $ServerDir -CheckOnly
if ($LASTEXITCODE -ne 0) {
  Bad 'Verification failed - see the lines above. The files were still created.'
  if (-not $NonInteractive) { Write-Host ''; Read-Host '    Press Enter to close' | Out-Null }
  exit 1
}

Title 'done'
Write-Host '    From now on, in that server folder:'
Write-Host ''
Write-Host '      rk-start.bat      run the server under respawnkeeper  (use this instead of run.bat)'
Write-Host '      rk-stop.bat       clean stop - will NOT be auto-restarted'
Write-Host '      rk-restart.bat    restart now through the maintenance lap (warn, clean stop, log scan, start)'
Write-Host '      rk-diagnose.bat   read the last crash, change nothing'
Write-Host ''
Write-Host '    Before writing anything into that server folder yourself, check the repair lock:'
Write-Host ('      powershell -File "' + (Join-Path $HarnessDir 'rk-lock.ps1') + '" -ServerDir "' + $ServerDir + '" -Check')
Write-Host ''

# Only the successful full run writes the report, and that is the run worth
# reporting on: it is the one that exercised every screen. The early exits are
# error paths, where the untranslated line is the error message itself and is
# already on screen.
Write-RkLangReport

if ($NoLaunch -or $NonInteractive) { exit 0 }

$go = Read-Host '    Start the server now? [y/N]'
if ($go.Trim().ToLower() -eq 'y') {
  if ($legacy.taskArmed) { Bad 'Refusing: the legacy watchdog task is still armed (see the warning above).'; Read-Host '    Press Enter to close' | Out-Null; exit 1 }
  & $rkPs1 -ServerDir $ServerDir
} else {
  Write-Host '    Nothing started. Double-click rk-start.bat when you are ready.'
  Read-Host '    Press Enter to close' | Out-Null
}
exit 0
