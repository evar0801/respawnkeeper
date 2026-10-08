# ============================================================
# rk-rough.ps1 - take the newest rough Eva drew and hand it to the model.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS (Eva, 2026-09-14): "the folder is in Pictures and under
# the workspace and going back and forth is a pain. Seriously annoying."
# She was going: Pictures for the original -> the repo to run a script ->
# Pictures again for the result. Now there is ONE folder, it has the buttons
# in it, and this script is what those buttons call.
#
# ---- IMPORTANT: WHY THE FOLDER NAMES ARE NOT IN THIS FILE ---------------------------
# Eva also asked for the folders to be named in Japanese. A .ps1 and a .cmd in
# this project must be ASCII (PS 5.1 reads a BOM-less .ps1 as ANSI; cmd.exe
# reads a .bat in the console codepage - the project notes (bat-encoding-and-paren-traps)).
# So the folders carry a NUMBER for the machine and Japanese for the person:
#
#     0_...  the reference, do not touch
#     1_...  the originals to draw over
#     2_...  where a rough goes
#     3_...  where the model's answer lands
#
# Nothing here spells a Japanese name; it matches on the digit. Eva can rename
# the Japanese half whenever she likes and none of this breaks.
# ============================================================

param(
  [Parameter(Mandatory)][string]$Root,
  [double]$Denoise = 0.65,
  [string]$Name = '',          # a rough by name; default is the newest one
  [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Say([string]$m) { Write-Host $m }

# ---- find the folders by their number ---------------------------------------
if (-not (Test-Path -LiteralPath $Root)) { throw ('no such folder: ' + $Root) }
function Get-Slot([string]$digit) {
  $d = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -like ($digit + '_*') })
  if ($d.Count -eq 0) { throw ('no folder starting with "' + $digit + '_" in ' + $Root) }
  return $d[0].FullName
}
$roughDir = Get-Slot '2'
$outDir   = Get-Slot '3'

# ---- pick the rough ---------------------------------------------------------
$imgs = @(Get-ChildItem -LiteralPath $roughDir -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|webp)$' })
if ($Name) { $imgs = @($imgs | Where-Object { $_.Name -like ('*' + $Name + '*') }) }
if ($imgs.Count -eq 0) {
  Say ''
  Say ('nothing to do: no image in ' + $roughDir)
  Say '  draw over one of the originals next door, save it there, and run this again.'
  exit 1
}
$rough = @($imgs | Sort-Object LastWriteTime -Descending)[0]

# The model refuses to be useful below this. Measured: a 249x320 sprite came
# back destroyed, because SDXL wants about 1024 and the alpha arrives as black.
# The rough must be the size of the ORIGINAL it was drawn over.
Add-Type -AssemblyName System.Drawing
$bmp = [System.Drawing.Image]::FromFile($rough.FullName)
$w = $bmp.Width; $h = $bmp.Height
$bmp.Dispose()
if ([Math]::Max($w, $h) -lt 640) {
  Say ''
  Say ('that rough is ' + $w + 'x' + $h + ', which is too small for the model (long side must be 640+).')
  Say '  draw at the size of the original you drew over - the sprite is the END of this pipeline, not the start.'
  exit 1
}

Say ''
Say ('rough   : ' + $rough.Name + '   ' + $w + 'x' + $h)
Say ('denoise : ' + $Denoise + '   (0.55 keeps more of your lines, 0.75 lets the model redraw more)')

# ---- is the model even up ---------------------------------------------------
$listening = @(Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue).Count
if ($listening -eq 0) {
  if ($NoStart) { throw 'ComfyUI is not running (port 8188) and -NoStart was given.' }
  # IMPORTANT: NOT while a game is up. ComfyUI holds about 5GB of an 8GB card, and the
  # measured symptom of losing that fight is the GAME stuttering - which looks
  # like a server problem and is not one.
  $busy = @(Get-Process -Name 'java', 'valheim_server', 'PalServer-Win64-Shipping-Cmd' -ErrorAction SilentlyContinue)
  if ($busy.Count -gt 0) {
    Say ''
    Say ('NOT starting ComfyUI: a game server is running (' + (($busy | ForEach-Object { $_.Name }) -join ', ') + ').')
    Say '  they share the graphics card, and the one that loses is the game. Stop the server first.'
    exit 1
  }
  $comfy = $(if ($env:COMFYUI_HOME) { $env:COMFYUI_HOME } else { 'C:\ComfyUI' })
  Say ''
  Say 'ComfyUI is not up. Starting it (about 30 seconds)...'
  Start-Process -FilePath (Join-Path $comfy 'venv\Scripts\python.exe') `
    -ArgumentList @('main.py', '--output-directory', (Join-Path $env:USERPROFILE 'Pictures\AIart\_inbox')) `
    -WorkingDirectory $comfy -WindowStyle Minimized | Out-Null
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (@(Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { break }
  }
  if (@(Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue).Count -eq 0) {
    throw 'ComfyUI did not come up within 180s.'
  }
  Say '  up.'
}

# ---- run it -----------------------------------------------------------------
# rk-refine writes into ComfyUI's own output folder, because that is the only
# place ComfyUI can be told about without restarting it. The result is moved
# next door afterwards, so Eva only ever looks in one place.
$INBOX = (Join-Path $env:USERPROFILE 'Pictures\AIart\_inbox')
$stamp = 'rk_rough_' + (Get-Date -Format 'MMddHHmmss')
$before = @(Get-ChildItem -LiteralPath $INBOX -Filter ($stamp + '*.png') -ErrorAction SilentlyContinue).Count

# IMPORTANT: THE UPLOAD DIES ON A JAPANESE FILE NAME. Measured just now:
# /upload/image answered 500 Internal Server Error for a rough called
# "<japanese>_<japanese>.png", and the identical picture went through under an
# ASCII name. Eva names her files in Japanese - that is the whole point of the
# folder - so the picture is handed over under a throwaway ASCII name and the
# result is named back afterwards. The rough on disk is never touched.
$tmpIn = Join-Path ([System.IO.Path]::GetTempPath()) ($stamp + '_in' + $rough.Extension)
Copy-Item -LiteralPath $rough.FullName -Destination $tmpIn -Force
if (-not (Test-Path -LiteralPath $tmpIn -PathType Leaf)) { throw ('could not stage the rough at ' + $tmpIn) }

Say ''
& (Join-Path $here 'rk-refine.ps1') -In $tmpIn -Denoise $Denoise -Out $stamp
Remove-Item -LiteralPath $tmpIn -Force -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { throw ('the model step failed (exit ' + $LASTEXITCODE + ')') }

$made = @(Get-ChildItem -LiteralPath $INBOX -Filter ($stamp + '*.png') -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending)
if ($made.Count -le $before) { throw 'the model produced no file.' }

$base = [System.IO.Path]::GetFileNameWithoutExtension($rough.Name)
$dest = Join-Path $outDir ($base + '_d' + ([int]($Denoise * 100)) + '_' + (Get-Date -Format 'MMdd-HHmm') + '.png')
Move-Item -LiteralPath $made[0].FullName -Destination $dest -Force
# Copy-Item/Move-Item to a DIRECTORY succeeds by putting the file INSIDE it and
# reports success either way, so the result is checked as a FILE.
if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw ('the result did not land at ' + $dest) }

Say ''
Say ('done -> ' + $dest)
Say '  look at it. nothing has been imported into the window yet.'
exit 0
