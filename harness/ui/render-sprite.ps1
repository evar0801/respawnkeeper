# ============================================================
# render-sprite.ps1 - draw every frame of a .rkspr to one PNG, off screen.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# Same reason render-preview.ps1 exists: a process launched by an agent has no
# interactive desktop [R-033], so the only honest way to draw a character is to
# rasterise it and look at the pixels. A contact sheet of all frames on the
# theme's own ground is the view that catches what a single frame hides -
# a two-frame loop that shifts the whole body, a colour that vanishes against
# the card behind it.
#
#   powershell -STA -File harness\ui\render-sprite.ps1
#   powershell -STA -File harness\ui\render-sprite.ps1 -Scale 8 -Signal '#FF3D7F'
# ============================================================

param(
  [string]$Sprite = '',
  [int]$Scale = 6,
  [string]$Signal = '#22E6FF',
  [string]$Ground = '#0A1220',
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'rk-sprite.ps1')

if (-not $Sprite) { throw 'pass -Sprite <file.rkspr>  (for example ui\stage\art\belka-eye.rkspr)' }
if (-not $Out)    { $Out = Join-Path $env:TEMP ('rk-sprite-' + [System.IO.Path]::GetFileNameWithoutExtension($Sprite) + '.png') }

$spr = Read-RkSprite -Path $Sprite
$names = @($spr.Frames.Keys)

$pad = 16
$labelH = 18
$cellW = ($spr.Width * $Scale) + $pad
$cellH = ($spr.Height * $Scale) + $pad + $labelH
$W = ($cellW * $names.Count) + $pad
$H = $cellH + $pad

$dv = New-Object System.Windows.Media.DrawingVisual
$dc = $dv.RenderOpen()
$bg = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($Ground))
$dc.DrawRectangle($bg, $null, (New-Object System.Windows.Rect(0, 0, $W, $H)))

$ink = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#8FB8CC'))
$typeface = New-Object System.Windows.Media.Typeface('Consolas')

for ($i = 0; $i -lt $names.Count; $i++) {
  $bmp = New-RkSpriteImage -Sprite $spr -Frame $names[$i] -Scale $Scale -Signal $Signal
  $x = $pad + ($i * $cellW)
  $dc.DrawImage($bmp, (New-Object System.Windows.Rect($x, $pad, $bmp.PixelWidth, $bmp.PixelHeight)))
  $ft = New-Object System.Windows.Media.FormattedText(
      $names[$i],
      [System.Globalization.CultureInfo]::InvariantCulture,
      [System.Windows.FlowDirection]::LeftToRight,
      $typeface, 12, $ink, 96)
  $dc.DrawText($ft, (New-Object System.Windows.Point($x, ($pad + $bmp.PixelHeight + 4))))
}
$dc.Close()

$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($dv)
$enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$fs = [System.IO.File]::Open($Out, 'Create')
try { $enc.Save($fs) } finally { $fs.Close() }

Write-Host ('rendered ' + $names.Count + ' frame(s) ' + $spr.Width + 'x' + $spr.Height + ' @' + $Scale + 'x -> ' + $Out)
