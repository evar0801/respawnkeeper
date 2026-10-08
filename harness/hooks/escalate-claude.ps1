# ============================================================
# escalate-claude.ps1 - Tier2/Tier3 escalation hook (OPT-IN, off by default)
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI).
#
# Called by respawnkeeper.ps1 ONLY when Tier1's rule table had no match, and
# ONLY while the server is stopped. Enable it by setting, in
# respawnkeeper.config.ps1:
#     $EscalationHook = "<harness>\hooks\escalate-claude.ps1"
#
# CONTRACT (identical to what Tier1 repairs produce, so the supervisor cannot
# tell the two apart):
#   - write the verdict as the FIRST LINE of -ResultFile:
#       FIXED: <what was changed, one line>
#       HALT: <why a human is needed>
#       SECURITY-HALT: <why this stopped on security grounds>
#   - never start or restart the server. That is the supervisor's job.
#   - no gradle builds, no downloads, no jar edits, no world\ edits.
#
# LINEAGE AND WHY IT IS OFF. fc8 ran this exact escalation for months. Measured
# result: 1 FIXED out of 3 invocations. The two HALTs were correct HALTs - the
# real fix was outside what a repair pass may do (a jar rebuild once, a mod
# version bump once). So this hook earns its keep as a DIAGNOSER far more than
# as a fixer, and the default stays off because it spends tokens.
# ============================================================

param(
  [Parameter(Mandatory)][string]$ServerDir,
  [Parameter(Mandatory)][string]$DiagnosisFile,
  [Parameter(Mandatory)][string]$ResultFile,
  [string]$Model = '',
  [string]$BashExe = 'C:\Program Files\Git\bin\bash.exe'
)

# ---- Which account pays -----------------------------------------------------
# Read from <ServerDir>\respawnkeeper\profile.json, so it is per server and
# changeable from the setup window without editing any script:
#
#   backend = 'subscription'  the claude CLI runs on the account login. No
#                             metered charge. THE DEFAULT.
#   backend = 'api'           the same CLI bills an API key instead.
#
# The KEY IS NEVER STORED HERE. The profile records the NAME of an environment
# variable; the value has to already be in the machine's environment. If it is
# not, this hook HALTs and says so rather than prompting for a secret or
# quietly falling back to the subscription and running up a different bill than
# the one that was chosen.
$ModelBackend = 'subscription'
$ApiKeyEnv    = 'ANTHROPIC_API_KEY'
try {
  $prof = Get-Content -LiteralPath (Join-Path $ServerDir 'respawnkeeper\profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($prof.model.backend)   { $ModelBackend = [string]$prof.model.backend }
  if ($prof.model.apiKeyEnv) { $ApiKeyEnv    = [string]$prof.model.apiKeyEnv }
  if ((-not $Model) -and $prof.model.name) { $Model = [string]$prof.model.name }
} catch {}
if (-not $Model) { $Model = 'claude-opus-5' }

$ErrorActionPreference = 'Continue'
$HookDir  = $PSScriptRoot
$StateDir = Join-Path $ServerDir 'respawnkeeper'
$Template = Join-Path $HookDir 'escalate-prompt.md'
$Prompt   = Join-Path $StateDir 'escalate-prompt.current.md'
$OutLog   = Join-Path $StateDir 'escalate-out.log'

function Write-Verdict([string]$v) {
  [System.IO.File]::WriteAllText($ResultFile, ($v + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

if (-not (Test-Path -LiteralPath $Template)) { Write-Verdict ('HALT: escalation prompt template missing: ' + $Template); exit 3 }
if (-not (Test-Path -LiteralPath $BashExe))  { Write-Verdict ('HALT: bash not found at ' + $BashExe); exit 3 }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Write-Verdict 'HALT: the claude CLI is not on PATH'; exit 3 }

# ---- Can it actually sign in? ----------------------------------------------
# Found 2026-08-27, on the first real run of this hook: the session came back in
# 4 seconds having printed "OAuth session expired and could not be refreshed",
# and the harness reported "the escalation session finished without writing a
# verdict" - true, useless, and 8 hours from anyone reading it.
#
# `claude auth status` answers this as JSON and spends nothing, so the failure
# is named up front instead of being inferred from an empty result. Only the
# subscription backend is checked: with backend=api the credential is the key,
# not an OAuth session, and auth status legitimately reports loggedIn=false.
function Test-ClaudeLogin {
  try {
    $raw = (& claude auth status 2>&1 | Out-String)
    if ($raw -match '"loggedIn"\s*:\s*true')  { return @{ known = $true;  loggedIn = $true;  raw = $raw } }
    if ($raw -match '"loggedIn"\s*:\s*false') { return @{ known = $true;  loggedIn = $false; raw = $raw } }
    return @{ known = $false; loggedIn = $false; raw = $raw }    # older CLI, or unexpected output
  } catch { return @{ known = $false; loggedIn = $false; raw = $_.Exception.Message } }
}

if ($ModelBackend -ne 'api') {
  $login = Test-ClaudeLogin
  if ($login.known -and (-not $login.loggedIn)) {
    Write-Verdict 'HALT: the claude CLI is not signed in (claude auth status reports loggedIn=false), so the escalation session cannot run. Sign in once with "claude auth login" - respawnkeeper cannot do this for you, and will not ask for or store a credential. Until then Tier1 still runs and the server still restarts; only the model pass is unavailable.'
    exit 3
  }
}

$crashPath = 'NONE'
try {
  $d = Get-Content -LiteralPath $DiagnosisFile -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($d.crashReport) { $crashPath = $d.crashReport }
} catch {}

$tpl = Get-Content -LiteralPath $Template -Raw -Encoding UTF8
$tpl = $tpl.Replace('{{SERVER_DIR}}',     $ServerDir)
$tpl = $tpl.Replace('{{CRASH_REPORT}}',   $crashPath)
$tpl = $tpl.Replace('{{DIAGNOSIS_FILE}}', $DiagnosisFile)
$tpl = $tpl.Replace('{{RESULT_FILE}}',    $ResultFile)
$tpl = $tpl.Replace('{{STATE_DIR}}',      $StateDir)
[System.IO.File]::WriteAllText($Prompt, $tpl, (New-Object System.Text.UTF8Encoding($false)))

function BashPath([string]$p) {
  $q = $p -replace '\\', '/'
  if ($q -match '^([A-Za-z]):(.*)$') { return ('/' + $Matches[1].ToLower() + $Matches[2]) }
  return $q
}

$cmd = "export PYTHONUTF8=1; cat '" + (BashPath $Prompt) + "' | claude -p --model $Model --dangerously-skip-permissions > '" + (BashPath $OutLog) + "' 2>&1"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $BashExe
$psi.Arguments = '-c "' + $cmd.Replace('"', '\"') + '"'
$psi.UseShellExecute = $false
# If this harness was itself launched from inside a Claude Code terminal, a
# leaked BASH_EXECUTION_STRING re-triggers shell-snapshot sourcing and floods
# stdout with a `declare -x` dump instead of running the command. Found the
# hard way in fc8, 2026-07-05.
foreach ($k in @('BASH_ENV', 'ENV', 'BASH_EXECUTION_STRING')) {
  if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) }
}

# Choosing the backend IS choosing the child's environment: the claude CLI bills
# an API key when ANTHROPIC_API_KEY is set and uses the account login when it is
# not. So 'subscription' has to actively REMOVE the variable - otherwise a key
# that happens to be set on this machine would silently move the charge onto
# metered billing, which is the exact thing the setting exists to control.
if ($ModelBackend -eq 'api') {
  $keyValue = [System.Environment]::GetEnvironmentVariable($ApiKeyEnv)
  if (-not $keyValue) {
    Write-Verdict ('HALT: backend is set to api but the environment variable ' + $ApiKeyEnv + ' is not set on this machine. Set it (or switch the profile back to subscription) and try again - respawnkeeper will not ask for or store a key.')
    exit 3
  }
  $psi.EnvironmentVariables['ANTHROPIC_API_KEY'] = $keyValue
} else {
  foreach ($k in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN')) {
    if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) }
  }
}

try {
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.WaitForExit()
} catch {
  Write-Verdict ('HALT: could not launch the escalation session: ' + $_.Exception.Message)
  exit 3
}

# The session writes the verdict itself. If it did not, that IS the verdict -
# but say WHY where the transcript makes it obvious, because "no verdict" on its
# own sends the reader to the wrong place. These are the failures that end a
# session before it can think, so they leave a one-line transcript.
$tail = ''
try { if (Test-Path -LiteralPath $OutLog) { $tail = (Get-Content -LiteralPath $OutLog -Tail 20 | Out-String) } } catch {}

function Get-SessionFailure([string]$text) {
  if ($text -match 'OAuth session expired|Failed to authenticate|Invalid API key|authentication_error|Please run .?claude login') {
    return 'the model session could not authenticate. Sign in with "claude auth login" (or fix the API key if the profile uses backend=api). Tier1 and restarts are unaffected; only the model pass is unavailable. Transcript: ' + $OutLog
  }
  if ($text -match 'rate.?limit|429|usage limit|quota') {
    return 'the model session was rate limited or out of quota. Transcript: ' + $OutLog
  }
  if ($text -match 'ENOTFOUND|ETIMEDOUT|ECONNREFUSED|getaddrinfo|network') {
    return 'the model session could not reach the network. Transcript: ' + $OutLog
  }
  return ''
}

$why = Get-SessionFailure $tail
if (-not (Test-Path -LiteralPath $ResultFile)) {
  if ($why) { Write-Verdict ('HALT: ' + $why) }
  else { Write-Verdict ('HALT: the escalation session finished without writing a verdict. Transcript: ' + $OutLog) }
  exit 3
}
$first = (Get-Content -LiteralPath $ResultFile -TotalCount 1)
if (-not $first) { Write-Verdict 'HALT: the escalation session wrote an empty verdict'; exit 3 }
if ($first.Trim() -like 'FIXED*') { exit 0 }
exit 3
