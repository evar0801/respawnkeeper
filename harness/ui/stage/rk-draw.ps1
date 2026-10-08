# ============================================================
# rk-draw.ps1 - the one command between "I drew something" and "the window
# shows it". ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS. rk-import-art.ps1 is the general tool and takes eleven
# switches, because it also has to turn a 832x1216 generated illustration into a
# small indexed picture. None of that applies to hand-drawn work: the drawing is
# ALREADY at the final pixel size, its background is ALREADY transparent, and the
# only question left is what the file is called. Every switch that still has to
# be typed is a thing to remember wrongly at 2am.
#
# So this bakes the hand-drawn case in and asks for nothing:
#
#     draw.cmd                      <- everything in draw\, into art\belka.rkspr
#     rk-draw.ps1 -Name bg-near     <- same, but a different sprite
#
# THE FILENAME IS THE FRAME NAME. draw\run.0.png becomes frame "run.0", which is
# the name stage.json already uses. Nothing has to agree with anything by hand.
#
# WHAT IT ASSUMES, and each one is checked rather than trusted:
#   - all frames are the same size          (the stage refuses a file that is not)
#   - the background is transparent         (no colour key: alpha decides)
#   - nearest-neighbour, no resampling      (Fant would blend the marker colours)
#
# MARKER COLOURS. Paint the pixels that should be the status light in
# #FF00FF (bright) or #FF80FF (dimmed). They become * and + and are NOT part of
# the palette - they are labels, not colours. They survive re-import, which is
# the whole point: the old instruction was to edit the text by hand, last, and
# lose it on the next correction.
# ============================================================

param(
  [string]$Name = 'belka',                   # output basename in art\
  [string]$From = '',                       # default: draw\ next to this script
  [string]$OutDir = '',                     # default: art\ next to this script
  [string[]]$In = @(),                      # explicit files; overrides -From
  [int]$Colors = 32,
  [string]$Glow = '#FF00FF',
  [string]$Dim  = '#FF80FF',
  [int]$PngScale = 6,
  [bool]$Pulse = $true,                      # for every frame X.0 that has * in it, also write
                                            # X.1 = the same frame with * dimmed to +. Every loop in
                                            # this project is that pair, and stage.json expects both;
                                            # without it a hand-drawn run.0 arrives alone and the
                                            # stage throws on the missing run.1.
  [switch]$NoPng
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, WindowsBase

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $From) { $From = Join-Path $here 'draw' }

# ---- gather ------------------------------------------------------------------
if ($In.Count -gt 0) {
  $files = @($In | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
} else {
  if (-not (Test-Path -LiteralPath $From)) {
    New-Item -ItemType Directory -Force -Path $From | Out-Null
    Write-Host ('made ' + $From)
    Write-Host 'Put one PNG per frame in there, named after the frame: run.0.png, run.1.png, ...'
    Write-Host 'Then run this again.'
    exit 0
  }
  # Sorted by name, so run.0 comes before run.1 and the frame order is the one
  # you can see in the folder. Sorting by write time would reorder frames every
  # time one of them is corrected.
  $files = @(Get-ChildItem -LiteralPath $From -Filter '*.png' | Sort-Object Name | ForEach-Object { $_.FullName })
}
if ($files.Count -eq 0) { throw ('no .png files in ' + $From) }

# ---- frame names come from the filenames -------------------------------------
# "run.0.png" -> "run.0". Only the LAST extension is dropped, because the dot in
# a frame name is part of it.
$frames = @($files | ForEach-Object {
  $n = Split-Path -Leaf $_
  $n.Substring(0, $n.Length - 4)
})
$dupes = @($frames | Group-Object | Where-Object { $_.Count -gt 1 })
if ($dupes.Count -gt 0) { throw ('two files would make the same frame name: ' + ($dupes[0].Name)) }

# ---- size: read it, do not ask for it ----------------------------------------
# The drawing is the sprite, so its own width is the answer. Reading it here also
# catches the mistake that matters most - one frame drawn on a different canvas -
# before rk-import-art gets far enough to say it in its own words.
$sizes = @()
foreach ($f in $files) {
  $fs = [System.IO.File]::OpenRead($f)
  try {
    $bm = [System.Windows.Media.Imaging.BitmapFrame]::Create($fs,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $sizes += , @($bm.PixelWidth, $bm.PixelHeight, (Split-Path -Leaf $f))
  } finally { $fs.Close() }
}
$w = $sizes[0][0]; $h = $sizes[0][1]
$bad = @($sizes | Where-Object { $_[0] -ne $w -or $_[1] -ne $h })
if ($bad.Count -gt 0) {
  Write-Host 'frames disagree on canvas size:'
  foreach ($s in $sizes) { Write-Host ('  {0,4} x {1,-4}  {2}' -f $s[0], $s[1], $s[2]) }
  throw 'every frame must be drawn on the same canvas'
}

Write-Host ('drawing -> ' + $Name + '.rkspr   ' + $w + 'x' + $h + ', ' + $files.Count + ' frame(s)')
foreach ($fr in $frames) { Write-Host ('  @frame ' + $fr) }

# ---- hand it to the real importer --------------------------------------------
# -Transparent none on purpose: a drawing already has an alpha channel, and a
# colour key would eat whatever pixel happens to sit in the corner.
# A HASHTABLE, not an array. Splatting an array passes the items POSITIONALLY -
# "-Width" and 12 arrive as two separate positional arguments and the binder ends
# up trying to read the sprite's name as its width. Only a hashtable splats as
# named parameters. NOT named $args either: that is an automatic variable.
$argv = @{
  In          = $files
  Name        = $Name
  Width       = $w
  Height      = $h
  Fit         = 'stretch'
  Scaling     = 'nearest'
  Transparent = 'none'
  Colors      = $Colors
  Glow        = $Glow
  Dim         = $Dim
  FrameNames  = $frames
  Force       = $true
}
if (-not $NoPng) { $argv['Png'] = $true; $argv['PngScale'] = $PngScale }
if ($OutDir)     { $argv['OutDir'] = $OutDir }

& (Join-Path $here 'rk-import-art.ps1') @argv

$art = $(if ($OutDir) { $OutDir } else { Join-Path $here 'art' })
$sprite = Join-Path $art ($Name + '.rkspr')

# ---- the dim half of every loop -------------------------------------------
# Every animation in this project is the same pair: the marked pixels at full
# state colour, then the same frame with them dimmed. Only the first is worth
# drawing, so only the first is asked for - the second is a stated substitution
# and rk-derive writes it as a row diff.
#
# Without this, a hand-drawn run.0 arrives on its own and stage.json throws on
# the missing run.1. That is a bad way to find out, ten seconds after saving.
if ($Pulse) {
  . (Join-Path (Split-Path -Parent $here) 'rk-sprite.ps1')
  $s = Read-RkSprite -Path $sprite
  foreach ($fr in @($s.Frames.Keys)) {
    if ($fr -notmatch '^(.+)\.0$') { continue }
    $pair = $Matches[1] + '.1'
    $hasStar = $false
    foreach ($row in @($s.Frames[$fr])) { if ($row.Contains('*')) { $hasStar = $true; break } }
    if (-not $hasStar) { continue }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'rk-derive.ps1') `
      -File $sprite -Base $fr -Name $pair -Map '*=+' -Force
  }
}

Write-Host ''
Write-Host ('look at it:  ' + (Join-Path $art ($Name + '.x' + $PngScale + '.png')))
Write-Host ('check it:    powershell -File harness\ui\rk-panel.ps1 -Once')
