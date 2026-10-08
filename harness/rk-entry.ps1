# ============================================================
# rk-entry.ps1 - the ONE place that decides what a double-click does.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS FILE EXISTS (2026-09-13, [R-080])
#
# There were two front doors with the same name and different behaviour:
#
#     respawnkeeper.exe   double-clicked -> the control panel
#     respawnkeeper.bat   double-clicked -> the setup wizard
#
# and the rule that produced that difference was written twice, in two
# languages - once in C# (harness\launcher\RespawnKeeper.cs) and once in cmd
# (respawnkeeper.bat, panel.bat). Duplicated routing is not a tidiness
# complaint; it has already cost something measurable. The -WindowStyle Hidden
# defect in [R-077] existed in BOTH copies and had to be found and fixed twice.
#
# So the doors stay - a named, double-clickable file is how a person finds a
# thing - but every one of them is now a shell with no decisions in it. They all
# call this script, and this script alone knows what each shape of invocation
# means. Adding a fifth door, or changing what "no arguments" means, is one edit
# here instead of three edits that can disagree.
#
# WHAT EACH SHAPE MEANS
#
#   rk-entry.ps1                        -> the control panel
#   rk-entry.ps1 <server folder>        -> the setup wizard for that folder
#   rk-entry.ps1 -Task panel            -> the control panel, said explicitly
#   rk-entry.ps1 -Task setup -Target X  -> the wizard, said explicitly
#   rk-entry.ps1 -Task finish-setup     -> the two steps only a person can take
#
# "No arguments" means THE PANEL, which is what the exe already did and what
# respawnkeeper.bat did not. The panel wins because it is the superset: it lists
# every server already set up AND has an Add button that runs this same wizard.
# Starting at the wizard means a returning operator has to go through a setup
# screen to reach servers that are already set up.
#
# ON WINDOWS. A GUI child is started with CreateNoWindow, never
# -WindowStyle Hidden: the latter is a REQUEST that Windows Terminal ignores,
# which is exactly the [R-077] defect. A console child is left alone - it
# inherits the console this script is already running in, so the wizard prints
# where the operator is looking.
# ============================================================

param(
  # A server folder. Positional so that dropping a folder on a shell that
  # forwards %1 just works.
  [Parameter(Position = 0)]
  [string]$Target = '',

  [ValidateSet('', 'panel', 'setup', 'finish-setup')]
  [string]$Task = '',

  # Anything else is handed to the script that ends up running, so
  # rk-setup.ps1's own switches (-Policy, -NonInteractive, -Lang, ...) keep
  # working through the front door instead of only when called directly.
  [Parameter(ValueFromRemainingArguments = $true)]
  $Rest
)

$ErrorActionPreference = 'Stop'
$HarnessDir = $PSScriptRoot

function Fail([string]$m) {
  Write-Host ''
  Write-Host ('  x ' + $m) -ForegroundColor Red
  Write-Host ''
  exit 2
}

function ConvertTo-RkArgTable {
  # Turn the leftover tokens into a hashtable so they can be splatted BY NAME.
  #
  # WHY NOT JUST @Rest. Splatting an ARRAY passes its elements POSITIONALLY, so
  # '-Policy','manual' arrives as two positional values and '-Policy' itself
  # lands in the first free positional parameter. Measured 2026-09-13 against
  # rk-setup.ps1:
  #
  #   & $script -ServerDir X @Rest
  #   -> Cannot validate argument on parameter 'Policy'. The argument "-Policy"
  #      does not belong to the set ",watch,unattended,manual"
  #
  # Splatting a HASHTABLE passes by name, which is what forwarding means. The
  # same call built as a table binds Policy=manual, NonInteractive=True,
  # Lang=en correctly.
  #
  # A token starting with '-' is a name; the token after it is its value unless
  # that one also starts with '-', in which case the first was a switch. That
  # rule cannot express a VALUE that itself starts with '-', which nothing this
  # forwards to takes - say so here rather than pretend the parser is general.
  param($Tokens)
  $h = @{}
  $t = @($Tokens)
  $i = 0
  while ($i -lt $t.Count) {
    $tok = [string]$t[$i]
    if (-not $tok.StartsWith('-')) { Fail ('unexpected argument: ' + $tok); }
    $name = $tok.Substring(1)
    if (-not $name) { Fail 'a bare "-" is not an argument.' }
    if (($i + 1) -lt $t.Count -and -not ([string]$t[$i + 1]).StartsWith('-')) {
      $h[$name] = $t[$i + 1]; $i += 2
    } else {
      $h[$name] = $true;     $i += 1
    }
  }
  return $h
}

# ---- 1. Work out what was asked for -----------------------------------------
if (-not $Task) {
  if ($Target) {
    # A path was given. It has to be a DIRECTORY: dropping a file on the icon is
    # a slip, and guessing its parent folder would silently set up the wrong
    # server - the failure mode CLAUDE.md calls out as indistinguishable from a
    # server that simply never crashes.
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
      Fail ('not a folder: ' + $Target + [Environment]::NewLine +
            '    Drop the SERVER FOLDER on respawnkeeper, not a file inside it.')
    }
    $Task = 'setup'
  } else {
    $Task = 'panel'
  }
}
if ($Task -eq 'setup' -and -not $Target) { Fail '-Task setup needs -Target <server folder>.' }

# ---- 2. Run it ---------------------------------------------------------------
switch ($Task) {

  'panel' {
    # A WPF window. It gets no console at all: CreateNoWindow is a CreateProcess
    # flag, so no terminal gets to overrule it ([R-077]). Fire and forget - the
    # operator closes the window whenever they like, and nothing here waits.
    $script = Join-Path $HarnessDir 'ui\rk-panel.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { Fail ('missing: ' + $script) }

    # IN THIS PROCESS WHEN THIS PROCESS IS ALREADY THE RIGHT SHAPE. The exe
    # starts this script with -STA and CreateNoWindow, which is exactly what
    # the child below is started with - so from the exe, the child was a
    # second powershell.exe (400 ms to a prompt, measured 2026-09-14) started
    # purely to be identical to its parent. Eva: "opening it is quite slow".
    # The panel runs here instead when BOTH hold: this thread is STA (WPF
    # requires it) and there is no console window attached (a bat's console
    # would otherwise sit behind the panel, which is the [R-077] defect the
    # child exists to avoid). From respawnkeeper.bat / panel.bat neither test
    # is ever wrong: the bat has a console, so the child is still spawned.
    $inProcess = $false
    try {
      if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        if (-not ('RkEntry.Native' -as [type])) {
          Add-Type -Namespace RkEntry -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
'@ -ErrorAction Stop
        }
        if ([RkEntry.Native]::GetConsoleWindow() -eq [IntPtr]::Zero) { $inProcess = $true }
      }
    } catch { $inProcess = $false }
    if ($inProcess) {
      Set-Location -LiteralPath $HarnessDir
      & $script
      exit $LASTEXITCODE
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName         = (Get-Command powershell).Source
    $psi.Arguments        = ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + $script + '"')
    $psi.UseShellExecute  = $false
    $psi.CreateNoWindow   = $true
    $psi.WorkingDirectory = $HarnessDir
    [void][System.Diagnostics.Process]::Start($psi)
    exit 0
  }

  'setup' {
    # A console program, run IN THIS CONSOLE rather than launched into another
    # one. That keeps the wizard's output where the person double-clicking is
    # already looking, and it means its exit code is this script's exit code.
    $script = Join-Path $HarnessDir 'rk-setup.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { Fail ('missing: ' + $script) }
    $full = (Resolve-Path -LiteralPath $Target).Path
    $fwd = ConvertTo-RkArgTable $Rest
    $fwd['ServerDir'] = $full
    & $script @fwd
    exit $LASTEXITCODE
  }

  'finish-setup' {
    $script = Join-Path $HarnessDir 'rk-finish-setup.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { Fail ('missing: ' + $script) }
    # Splatting needs a VARIABLE - @( ) is an array subexpression, not a splat,
    # and would have passed the hashtable itself as one positional argument.
    $fwd = ConvertTo-RkArgTable $Rest
    & $script @fwd
    exit $LASTEXITCODE
  }
}
