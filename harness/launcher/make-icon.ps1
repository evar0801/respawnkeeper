# ============================================================
# make-icon.ps1 - build respawnkeeper.ico from a single source PNG.
# ASCII only (PS 5.1 safe: a BOM-less script is read as ANSI, so no
# non-ASCII characters anywhere in this file, comments included).
#
# Crops a square region out of the source illustration (a face closeup),
# resizes it to 16 / 32 / 48 / 256, and packs all four sizes into one
# .ico so Explorer can pick whichever fits its current display scale.
#
# This script owns respawnkeeper.ico. build-exe.ps1 does not draw it
# anymore when this file is present - it just embeds whatever is here.
#
# Re-run whenever the source art changes - same command, new PNG:
#   powershell -File harness\launcher\make-icon.ps1 -SourcePng <path to new art>
#
# The crop rectangle below is tuned for the "belka face" reference art
# (896x1152, orange background, character looking toward camera). If a
# later revision keeps the same framing, this default still applies.
# If the framing changes, pass -CropX/-CropY/-CropWidth/-CropHeight for
# the new image (open it, read off pixel coordinates of the face box).
# ============================================================

param(
  [Parameter(Mandatory=$true)][string]$SourcePng,
  [string]$OutIco,
  [int]$CropX = 210,
  [int]$CropY = 40,
  [int]$CropWidth = 270,
  [int]$CropHeight = 270,
  [string]$PreviewPng,
  [string]$Key = 'auto',        # 'auto' | '#RRGGBB' | 'none'
  [string]$Backdrop = 'none',   # 'none' | '#RRGGBB' - a rounded ground behind her
  [string]$Python = $(if ($env:RK_ART_PYTHON) { $env:RK_ART_PYTHON } else { 'C:\ComfyUI\venv\Scripts\python.exe' })
)

$ErrorActionPreference = 'Stop'
$LauncherDir = $PSScriptRoot
if (-not $OutIco) { $OutIco = Join-Path $LauncherDir 'respawnkeeper.ico' }

function Say([string]$m) { Write-Host ('  ' + $m) }
function Good([string]$m) { Write-Host ('  o ' + $m) -ForegroundColor Green }
function Bad([string]$m)  { Write-Host ('  x ' + $m) -ForegroundColor Red }

Write-Host ''
Write-Host '  making respawnkeeper.ico' -ForegroundColor Cyan
Write-Host '  ------------------------' -ForegroundColor DarkCyan

if (-not (Test-Path -LiteralPath $SourcePng)) { Bad ('missing source PNG: ' + $SourcePng); exit 2 }

Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Image]::FromFile($SourcePng)
Say ('source: ' + $SourcePng + '  (' + $src.Width + 'x' + $src.Height + ')')

if ($CropX -lt 0 -or $CropY -lt 0 -or $CropWidth -le 0 -or $CropHeight -le 0 -or
    ($CropX + $CropWidth) -gt $src.Width -or ($CropY + $CropHeight) -gt $src.Height) {
  $src.Dispose()
  Bad ('crop rectangle (X=' + $CropX + ' Y=' + $CropY + ' W=' + $CropWidth + ' H=' + $CropHeight + ') is outside the source image bounds.')
  exit 2
}
Say ('crop: X=' + $CropX + ' Y=' + $CropY + ' Width=' + $CropWidth + ' Height=' + $CropHeight)

# ---- crop once at full quality, then downsample per target size -----------
$cropRect = New-Object System.Drawing.Rectangle($CropX, $CropY, $CropWidth, $CropHeight)
$cropped = New-Object System.Drawing.Bitmap($CropWidth, $CropHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gc = [System.Drawing.Graphics]::FromImage($cropped)
try {
  $gc.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $gc.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $gc.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $destRect = New-Object System.Drawing.Rectangle(0, 0, $CropWidth, $CropHeight)
  $gc.DrawImage($src, $destRect, $cropRect, [System.Drawing.GraphicsUnit]::Pixel)
} finally {
  $gc.Dispose()
  $src.Dispose()
}

# ---- the source pixels ------------------------------------------------------
# THE ORANGE IN THE SOURCE IS NOT A BACKGROUND. It is the chroma key this
# project paints behind every generation so it can be taken out later (see
# stage\prekey.py, and 'key #EA8A3F' in build-belka.ps1's log). An icon that
# keeps it has her framed in the studio backdrop.
#
# Removing it here is not enough on its own: GDI+ HighQualityBicubic lets a
# fully transparent pixel keep its colour and vote, so shrinking a keyed image
# paints the key back along every edge. The order that works is
#   key at full size -> premultiply by alpha -> shrink -> un-premultiply
# and that lives in icon-src.py, which emits one PNG per size. [R-067]
$sizes = @(16, 32, 48, 256)
$srcDir = ''
$helper = Join-Path $PSScriptRoot 'icon-src.py'
if (($Key -ne 'none' -or $Backdrop -ne 'none') -and (Test-Path -LiteralPath $helper) -and (Test-Path -LiteralPath $Python)) {
  $srcDir = Join-Path $env:TEMP ('rk-icon-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
  $argv = @($helper, $SourcePng, $srcDir,
            '--crop', ('{0},{1},{2},{3}' -f $CropX, $CropY, $CropWidth, $CropHeight),
            '--key', $Key, '--backdrop', $Backdrop,
            '--sizes', ($sizes -join ','))
  & $Python @argv
  if ($LASTEXITCODE -ne 0) { Bad 'icon-src.py failed; falling back to the plain crop.'; $srcDir = '' }
} else {
  Say 'icon-src.py or python not found - falling back to the plain crop (the key colour will be kept).'
}

$entries = @()
foreach ($s in $sizes) {
  if ($srcDir) {
    $one = Join-Path $srcDir ('icon.' + $s + '.png')
    if (Test-Path -LiteralPath $one) {
      $pngBytes = [System.IO.File]::ReadAllBytes($one)
      $entries += [PSCustomObject]@{ Size = $s; Bitmap = $null; Png = $pngBytes }
      Say ('keyed   ' + $s + 'x' + $s + '  (' + $pngBytes.Length + ' bytes PNG)')
      continue
    }
    Bad ('icon-src.py did not produce ' + $one + '; rendering this size the old way.')
  }
  $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($cropped, 0, 0, $s, $s)
  } finally {
    $g.Dispose()
  }
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngBytes = $ms.ToArray()
  $ms.Dispose()
  $entries += [PSCustomObject]@{ Size = $s; Bitmap = $bmp; Png = $pngBytes }
  Say ('rendered ' + $s + 'x' + $s + '  (' + $pngBytes.Length + ' bytes PNG)')
}
$cropped.Dispose()

# ---- pack into one .ico ----------------------------------------------------
# Vista-style icon: each entry's payload is a PNG blob rather than a raw
# BMP/AND-mask pair. Supported since Windows Vista for any listed size, and
# is what build-exe.ps1 already used for its single 256 entry.
$headerSize = 6 + (16 * $entries.Count)
$ico = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($ico)
$w.Write([UInt16]0)                 # reserved
$w.Write([UInt16]1)                 # type 1 = icon
$w.Write([UInt16]$entries.Count)    # image count

$offset = $headerSize
foreach ($e in $entries) {
  $wOrH = if ($e.Size -ge 256) { 0 } else { $e.Size }
  $w.Write([Byte]$wOrH)             # width  (0 == 256)
  $w.Write([Byte]$wOrH)             # height (0 == 256)
  $w.Write([Byte]0)                 # palette colours
  $w.Write([Byte]0)                 # reserved
  $w.Write([UInt16]1)               # colour planes
  $w.Write([UInt16]32)              # bits per pixel
  $w.Write([UInt32]$e.Png.Length)   # size of this image's data
  $w.Write([UInt32]$offset)         # offset from start of file
  $offset += $e.Png.Length
}
foreach ($e in $entries) { $w.Write($e.Png) }
$w.Flush()
[System.IO.File]::WriteAllBytes($OutIco, $ico.ToArray())
$w.Dispose(); $ico.Dispose()
if ($srcDir -and (Test-Path -LiteralPath $srcDir)) { Remove-Item -LiteralPath $srcDir -Recurse -Force -ErrorAction SilentlyContinue }
Good ('icon: ' + $OutIco + '  (' + [math]::Round((Get-Item $OutIco).Length / 1KB, 1) + ' KB, ' + $entries.Count + ' sizes)')

# ---- optional preview PNG, for a human to actually look at ----------------
if ($PreviewPng) {
  $biggest = $entries | Sort-Object Size -Descending | Select-Object -First 1
  [System.IO.File]::WriteAllBytes($PreviewPng, $biggest.Png)
  Good ('preview: ' + $PreviewPng + '  (' + $biggest.Size + 'x' + $biggest.Size + ' PNG, for human eyes)')
}

# Bitmap is $null for entries that came from icon-src.py as ready-made PNGs.
foreach ($e in $entries) { if ($e.Bitmap) { $e.Bitmap.Dispose() } }

Write-Host ''
Say 'next: powershell -File harness\launcher\build-exe.ps1'
Write-Host ''
