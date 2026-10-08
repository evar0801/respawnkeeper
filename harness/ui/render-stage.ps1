# ============================================================
# render-stage.ps1 - draw the stage to a PNG without showing a window.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# The stage is the part an artist iterates on, so it gets its own offscreen
# renderer rather than being visible only inside the console window. One column
# per state, so a change to a background or an anchor is checked against EVERY
# state at once - a keeper who stands correctly while running and sinks into the
# floor when halted is exactly the bug a single-state preview hides.
#
#   powershell -STA -File harness\ui\render-stage.ps1
#   powershell -STA -File harness\ui\render-stage.ps1 -Tick 9
# ============================================================

param(
  [string]$Stage = '',
  [int]$Tick = 0,
  [string]$Out = '',
  [string[]]$States = @('run', 'care', 'halt', 'sleep'),
  [string]$Theme = ''          # default: whatever panel-settings.json says, else eve
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'panel-model.ps1')
. (Join-Path $PSScriptRoot 'rk-stage.ps1')

if (-not $Stage) { $Stage = Join-Path $PSScriptRoot 'stage\stage.json' }
if (-not $Out)   { $Out = Join-Path $env:TEMP 'rk-stage.png' }

# THE FOUR STATE COLOURS COME FROM THE THEME FILE, the same one the window
# splices in. This used to be a hand-copied table of eve's values, which meant
# the one tool built to look at the stage before shipping it previewed every
# other theme in eve's colours - and, before [R-092], previewed the sleep
# state in a colour the window never used at all ([R-040], [R-091] U20).
# A preview that disagrees with the window is worse than no preview.
if (-not $Theme) {
  $stg = Read-RkJson -Path (Join-Path $PSScriptRoot 'panel-settings.json')
  if ($stg -and $stg.theme) { $Theme = [string]$stg.theme } else { $Theme = 'eve' }
}
$pal = Get-RkThemeColors -Theme $Theme
if (-not $pal) { throw ('theme not readable: ' + $Theme) }
foreach ($k in @('accent', 'amber', 'danger', 'idle')) {
  # A hashtable is truthy even when empty, so each colour is checked by name -
  # a theme missing one would otherwise preview that state in white, silently.
  if (-not $pal[$k]) { throw ('theme ' + $Theme + ' does not define the ' + $k + ' colour (Accent / Amber / Danger / KeeperIdle)') }
}
$signals = @{ run = $pal.accent; care = $pal.amber; halt = $pal.danger; sleep = $pal.idle
              near = $pal.accent }   # 'near' is the close-up cut, not a server state - it borrows run's colour
Write-Host ('theme ' + $Theme + ': run ' + $pal.accent + ' care ' + $pal.amber + ' halt ' + $pal.danger + ' sleep ' + $pal.idle)

$probe = Read-RkStage -Path $Stage
$w = $probe.Width * $probe.Scale
$h = $probe.Height * $probe.Scale

# ONE FILE PER STATE, one visual tree each.
#
# The contact-sheet version of this file - four stages side by side in one
# canvas - rendered only its first column, and the reason was never pinned down
# (layout and the visual tree both measured correctly when probed). A preview
# tool that might be lying about three quarters of what it shows is worse than
# no preview tool, which is the whole argument [R-040] rests on. So it writes
# one honest PNG per state instead of one clever sheet.
foreach ($state in $States) {
  $st = Read-RkStage -Path $Stage
  $canvas = New-Object System.Windows.Controls.Canvas
  $canvas.Background = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.ColorConverter]::ConvertFromString('#05080F'))
  [void](New-RkStageVisual -Stage $st -Canvas $canvas)

  $sig = '#FFFFFFFF'
  if ($signals.ContainsKey($state)) { $sig = $signals[$state] }
  Update-RkStage -Stage $st -Tick $Tick -State $state -Signal $sig

  $size = New-Object System.Windows.Size($w, $h)
  $canvas.Measure($size)
  $canvas.Arrange((New-Object System.Windows.Rect(0, 0, $w, $h)))
  $canvas.UpdateLayout()

  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($canvas)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))

  $path = $Out
  if ($States.Count -gt 1) {
    $path = Join-Path (Split-Path -Parent $Out) (
      [System.IO.Path]::GetFileNameWithoutExtension($Out) + '-' + $state + '.png')
  }
  $fs = [System.IO.File]::Open($path, 'Create')
  try { $enc.Save($fs) } finally { $fs.Close() }
  Write-Host ('  ' + $state + ' tick=' + $Tick + ' -> ' + $path)
}

Write-Host ('stage ' + $probe.Width + 'x' + $probe.Height + ' @' + $probe.Scale + 'x, ' +
            $probe.Layers.Count + ' layers')
