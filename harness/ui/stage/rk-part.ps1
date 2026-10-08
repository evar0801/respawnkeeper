# ============================================================
# rk-part.ps1 - a PART, drawn on its own layer, comes back as a PART.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# Eva, 2026-09-14: "I will draw the whole picture as a rough myself, and then
# draw roughs of the parts the animation needs. Can it output a part?"
#
# Yes - but not from the model. SDXL has no alpha and always returns a filled
# rectangle, so the transparency is made by CUTTING. What the model does is
# make the part look finished and put it in the same light as the body it will
# be layered over. The order is:
#
#   her part layer (transparent PNG, original canvas)
#     -> composite over the original            (so the model sees a whole picture)
#     -> mask = her alpha, GROWN                (so the edge is painted in context)
#     -> rk-refine -Mask  (SetLatentNoiseMask)  (nothing outside the mask changes)
#     -> cut by her alpha, NOT the grown one    (or the part carries a halo)
#
# The two image steps are rk-part.py; this file is the order they happen in and
# the model call between them.
#
# The folders are found by their NUMBER, never by their Japanese name: a .ps1
# here must be ASCII. See rk-rough.ps1 for why.
# ============================================================

param(
  [Parameter(Mandatory)][string]$Root,
  [double]$Denoise = 0.60,
  [string]$Name = '',
  [string]$Base = '',        # which original it was drawn over; default is the seated one
  [int]$Grow = 24,
  [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
function Say([string]$m) { Write-Host $m }

function Get-Slot([string]$digit) {
  $d = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -like ($digit + '_*') })
  if ($d.Count -eq 0) { throw ('no folder starting with "' + $digit + '_" in ' + $Root) }
  return $d[0].FullName
}
if (-not (Test-Path -LiteralPath $Root)) { throw ('no such folder: ' + $Root) }
$srcDir   = Get-Slot '1'
$roughDir = Get-Slot '2'
$outDir   = Get-Slot '3'

# ---- the part -----------------------------------------------------------
$imgs = @(Get-ChildItem -LiteralPath $roughDir -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -eq '.png' })
if ($Name) { $imgs = @($imgs | Where-Object { $_.Name -like ('*' + $Name + '*') }) }
if ($imgs.Count -eq 0) {
  Say ''
  Say ('nothing to do: no PNG in ' + $roughDir)
  Say '  a part has to be a PNG - a JPG cannot carry the transparency this needs.'
  exit 1
}
$part = @($imgs | Sort-Object LastWriteTime -Descending)[0]

# ---- the original it was drawn over -------------------------------------
# By number, so "1_<japanese>.png" can be renamed freely. Default 1 is the
# seated figure, which is the only one that needs parts today.
if (-not $Base) { $Base = '1_' }
$bases = @(Get-ChildItem -LiteralPath $srcDir -File -Filter '*.png' |
           Where-Object { $_.Name -like ($Base + '*') })
if ($bases.Count -eq 0) { throw ('no original starting with "' + $Base + '" in ' + $srcDir) }
# NOT $base. PowerShell variable names are case-INSENSITIVE, so $base IS the
# [string]$Base parameter - assigning a FileInfo to it coerced the object to a
# string, .FullName came back empty, and every argument after it shifted left.
# The failure surfaced as python opening the wrong file.
$baseFile = $bases[0]

Say ''
Say ('part    : ' + $part.Name)
Say ('over    : ' + $baseFile.Name)
Say ('denoise : ' + $Denoise + '   grow: ' + $Grow + 'px')
Say ''

# ---- prep ----------------------------------------------------------------
$py = 'python'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rk-part-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$comp = Join-Path $tmp 'comp.png'
$mask = Join-Path $tmp 'mask.png'
& $py (Join-Path $here 'rk-part.py') 'prep' $part.FullName $baseFile.FullName $comp $mask $Grow
if ($LASTEXITCODE -ne 0) { throw 'the prep step failed (see above)' }
if (-not (Test-Path -LiteralPath $comp -PathType Leaf)) { throw 'no composite was written' }
if (-not (Test-Path -LiteralPath $mask -PathType Leaf)) { throw 'no mask was written' }

# ---- the model -----------------------------------------------------------
$listening = @(Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue).Count
if ($listening -eq 0) {
  if ($NoStart) { throw 'ComfyUI is not running (port 8188) and -NoStart was given.' }
  $busy = @(Get-Process -Name 'java', 'valheim_server', 'PalServer-Win64-Shipping-Cmd' -ErrorAction SilentlyContinue)
  if ($busy.Count -gt 0) {
    Say ('NOT starting ComfyUI: a game server is running (' + (($busy | ForEach-Object { $_.Name }) -join ', ') + ').')
    Say '  they share the graphics card, and the one that loses is the game.'
    exit 1
  }
  $comfy = $(if ($env:COMFYUI_HOME) { $env:COMFYUI_HOME } else { 'C:\ComfyUI' })
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

# The upload endpoint answers 500 to a Japanese file name (measured), so the
# staging copies are ASCII and only the OUTPUT carries her name back.
$INBOX = (Join-Path $env:USERPROFILE 'Pictures\AIart\_inbox')
$stamp = 'rk_part_' + (Get-Date -Format 'MMddHHmmss')
$before = @(Get-ChildItem -LiteralPath $INBOX -Filter ($stamp + '*.png') -ErrorAction SilentlyContinue).Count

& (Join-Path $here 'rk-refine.ps1') -In $comp -Mask $mask -Denoise $Denoise -Out $stamp
if ($LASTEXITCODE -ne 0) { throw ('the model step failed (exit ' + $LASTEXITCODE + ')') }

$made = @(Get-ChildItem -LiteralPath $INBOX -Filter ($stamp + '*.png') -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending)
if ($made.Count -le $before) { throw 'the model produced no file.' }

# ---- cut -----------------------------------------------------------------
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($part.Name)
$dest = Join-Path $outDir ($baseName + '_part_d' + ([int]($Denoise * 100)) + '_' + (Get-Date -Format 'MMdd-HHmm') + '.png')
& $py (Join-Path $here 'rk-part.py') 'cut' $made[0].FullName $part.FullName $dest
if ($LASTEXITCODE -ne 0) { throw 'the cut step failed (see above)' }
if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw ('the part did not land at ' + $dest) }

# The whole picture is kept too: it is the only way to see whether the part
# actually sits in the body, and a part judged on its own always looks fine.
# The word in the file name is built from code points, because this file has
# to be ASCII and the name still has to be readable to the person opening
# the folder. U+5168 U+4F53 = 'the whole picture'.
$WHOLE = [string]([char]0x5168) + [string]([char]0x4F53)
$whole = Join-Path $outDir ($baseName + '_' + $WHOLE + '_' + (Get-Date -Format 'MMdd-HHmm') + '.png')
Move-Item -LiteralPath $made[0].FullName -Destination $whole -Force

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Say ''
Say ('done -> ' + $dest)
Say ('       ' + $whole + '   <- look at THIS one to judge it')
Say '  nothing has been imported into the window yet.'
exit 0
