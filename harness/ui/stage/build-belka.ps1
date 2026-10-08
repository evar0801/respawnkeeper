# ============================================================
# build-belka.ps1 - rebuild every piece of art the stage uses, from the
# generated pictures, in one go. ASCII only (PS 5.1 decodes BOM-less as ANSI).
#
# WHY THIS EXISTS. The stage art is not hand-drawn yet: it is a generated
# picture plus a short list of DECLARED edits (which palette entry is the status
# light, which rectangle holds an eye). Those edits are lost on re-import, so
# either they live in a script or they live in someone's memory. This is the
# script. Re-run it and the art comes back identical - the importer's median cut
# is deterministic and every edit below is a stated substitution.
#
# It writes into art\ and prints what changed. It does NOT touch stage.json.
#
#   powershell -STA -File harness\ui\stage\build-belka.ps1
#   powershell -STA -File harness\ui\stage\build-belka.ps1 -InDir <folder of the pngs>
# ============================================================

param(
  [string]$InDir = (Join-Path $env:USERPROFILE 'Pictures\AIart\_inbox'),
  [string]$Room  = 'rk_room2_940102_00001_.png',        # the room, no chair, no person
  [string]$Wide  = 'rk_coat_960103_00001_.png',         # her in the white coat and boots
  [string]$Near  = 'rk_near_940301_00001_.png',    # the close-up cut
  [string]$RailBg = 'rk_rail_bg_950101_00001_.png',      # the bed, from above, empty
  [string]$RailBelka = 'rk_rail_hair_950203_00001_.png'   # her lying on it, longer hair
)

$ErrorActionPreference = 'Stop'
$here   = $PSScriptRoot
$art    = Join-Path $here 'art'
$import = Join-Path $here 'rk-import-art.ps1'
$derive = Join-Path $here 'rk-derive.ps1'
$draw   = Join-Path $here 'rk-draw.ps1'
$recolour = Join-Path $here 'rk-palette.ps1'
$prekey   = Join-Path $here 'prekey.py'
$tmp      = Join-Path $env:TEMP 'rk-prekey'
New-Item -ItemType Directory -Force $tmp | Out-Null

# Pillow lives in ComfyUI's venv, which is the only Python this machine is sure
# to have with it. Named rather than assumed: a bare "python" here would find
# whatever is on PATH and fail on the import, minutes later, with a stack trace
# instead of a sentence.
$python = $(if ($env:RK_ART_PYTHON) { $env:RK_ART_PYTHON } else { 'C:\ComfyUI\venv\Scripts\python.exe' })
if (-not (Test-Path -LiteralPath $python)) { throw ('no python with Pillow at ' + $python) }

function Step($msg) { Write-Host ''; Write-Host ('== ' + $msg) }

# ---------------------------------------------------------------- the room --
# 36 colours. The screens are one palette entry, so the whole room can BE the
# status readout without anyone painting a mask.
Step 'room -> art\bg-far.rkspr'
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File $import `
  -In (Join-Path $InDir $Room) -Name 'bg-far' -Width 560 -Height 376 -Fit cover `
  -Colors 36 -Png -PngScale 2 -Force | Where-Object { $_ -match 'wrote|opaque|WARNING' }

# P = #466AAC is the screen glow, G = #145680 the spill around it. Measured, not
# guessed: they are the two brightest entries with five figures of pixels.
& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'bg-far.rkspr') -Base 'idle.0' -Name 'lit.0' -Map 'P=*,G=+' -Force

# ------------------------------------------------------------ the wide cut --
# Her, cut out of the orange. 249x320 puts her at ~85% of the stage height.
Step 'wide cut -> art\belka.rkspr'
# Key first, shrink second. The importer then only has to reduce the colours:
# it is handed RGBA at the final size, and alpha decides what is transparent.
& $python $prekey (Join-Path $InDir $Wide) (Join-Path $tmp 'wide.png') 249 320 auto 40
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File $import `
  -In (Join-Path $tmp 'wide.png') -Name 'belka' -Width 249 -Height 320 `
  -Scaling nearest -Colors 24 -FrameNames 'raw.0' -Png -PngScale 2 -Force |
  Where-Object { $_ -match 'wrote|opaque' }

# H/N are the teal of the iris, by rectangle because the head is turned and the
# two eyes are not on one row. 13 pixels - too small to blink, the right size for
# "the light is on".
$wideEyes = '96-106,48-57; 109-120,42-50'
& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'belka.rkspr') -Base 'raw.0' -Name 'run.0' `
  -Map 'Q=*,M=+' -Boxes $wideEyes -Force
& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'belka.rkspr') -Base 'run.0' -Name 'run.1' `
  -Map '*=+' -Boxes $wideEyes -Force

# ----------------------------------------------------------- the close-up --
# The cut the reference is actually made of: the eye is ~40px across here, which
# is above the 22px line where the iris gradient survives.
Step 'close-up -> art\belka-near.rkspr'
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File $import `
  -In (Join-Path $InDir $Near) -Name 'belka-near' -Width 560 -Height 376 -Fit cover `
  -Colors 36 -FrameNames 'raw.0' -Png -PngScale 1 -Force | Where-Object { $_ -match 'wrote|opaque' }

# Two rectangles, because the head is tilted and the eyes are not on one row.
$eyes = '212-264,151-175; 322-374,179-199'
$iris = (@('1','V','N','J','L','X','4','5','K','M') | ForEach-Object { $_ + '=*' }) -join ','
& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'belka-near.rkspr') -Base 'raw.0' -Name 'near.0' -Map $iris -Boxes $eyes -Force
& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'belka-near.rkspr') -Base 'near.0' -Name 'near.1' -Map '*=+' -Boxes $eyes -Force
# The overlay's off state. A layer has no visibility flag, so "not showing" is a
# frame with nothing in it.
& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'belka-near.rkspr') -Base 'raw.0' -Name 'idle.0' -Blank -Force

# --------------------------------------------------------------- the rail --
# The panel's side rail is a stage too (rail.json): the bed underneath, her on
# top. Splitting them is the point - she can be moved or replaced without a hole
# appearing where she used to be [R-064].
Step 'rail -> art\rail-bg.rkspr + art\belka-rail.rkspr'

# HAND-PAINTED BACKDROP WINS, the same way the hand-painted character does.
#
# The generated route below has to say WHICH COLOURS are the sign light, by
# palette letter ($signMap), and then a script writes the words into the sprite
# afterwards - a chain that breaks the moment the quantiser renumbers anything,
# and that can only stamp a font. A hand-painted frame needs none of it: the
# light is whatever is painted #FF00FF / #FF80FF, which rk-draw.ps1 turns into
# * and + WITHOUT spending a palette entry, so it survives every re-import. The
# words are just part of the picture, drawn by somebody who can draw.
#
# draw-bg\lit.0.png is 296x600. lit.1 (the dimmed frame) is generated from it,
# so one file is the whole backdrop.
$drawBg = Join-Path $here 'draw-bg'
$handBg = Join-Path $drawBg 'lit.0.png'
if (Test-Path -LiteralPath $handBg) {
  Write-Host ('  rail-bg: using the hand-painted ' + (Split-Path -Leaf $handBg))
  & powershell -NoProfile -STA -ExecutionPolicy Bypass -File $draw `
    -Name 'rail-bg' -From $drawBg -Colors 36 -NoPng |
    Where-Object { $_ -match 'wrote|markers' }
} else {
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File $import `
  -In (Join-Path $InDir $RailBg) -Name 'rail-bg' -Width 296 -Height 600 -Fit cover `
  -Colors 36 -Png -PngScale 1 -Force | Where-Object { $_ -match 'wrote|opaque' }

# X = #BD23B5 is the neon sign over the headboard, T = #881893 its halo. Her
# eyes cannot be the readout at this size: the iris is three pixels and the
# 24-colour reduction does not even keep a green for it (measured).
# The sign is marked by RECTANGLE, not by colour. At 148x300 its magenta was a
# palette entry of its own; at 296x600 the quantiser gives the duvet its own
# magentas too, and they are the same hue - so a colour rule lit the whole bed.
# The box is the only thing that separates a sign from a bedspread. [R-067]
$signBox = '190-292,38-82; 46-96,62-82'
$signMap = '9=*,8=*,7=*,2=*,3=*,6=*,4=*,5=*,1=+,Z=+,W=+,V=+,X=+,Y=+,0=+'
& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'rail-bg.rkspr') -Base 'idle.0' -Name 'lit.0' `
  -Map $signMap -Boxes $signBox -Force

# THE SIGNS SAY SOMETHING, and what they say does not come out of the generator.
# The big one over the headboard carries five characters meaning "lying down in
# idleness"; the little clock on the left reads a radical sign and BELKA. (The
# words are not written here - this file is ASCII, because PS 5.1 reads a
# BOM-less script as ANSI. They are in paint-signs.py and in DECISIONS.md
# [R-092].)
#
# It runs BETWEEN the two derive steps because it needs lit.0 to know which
# cells the sign has enclosed, and it writes into idle.0 - so lit.0 has to be
# built again afterwards, off the repainted base.
#
# WHY NOT A HAND-PAINTED PNG, the way belka-rail does it. Measured 2026-09-13:
# feeding art/rail-bg.png (this importer's own 36-colour output) straight back
# through it with no edits at all comes back with THIRTY-FOUR distinct colours.
# The quantiser hands out palette letters in sorted order, so two lost colours
# renumber the legend - and $signMap above names those letters by hand. A hand
# PNG would light up whatever landed on '9'. The .rkspr is the artefact the
# panel reads, so that is where the text goes.
# $python, not a bare "python" - the reason is written at the top of this file
# and the first version of this line ignored it. A bare python finds whatever
# is on PATH and fails on the Pillow import with a stack trace; worse, if there
# is no python at all the call never runs, so $LASTEXITCODE still holds the 0
# left by the powershell.exe above and the guard below waves it through.
& $python (Join-Path $here 'paint-signs.py')
if ($LASTEXITCODE -ne 0) { throw ('paint-signs.py failed with exit code ' + $LASTEXITCODE) }

& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'rail-bg.rkspr') -Base 'idle.0' -Name 'lit.0' `
  -Map $signMap -Boxes $signBox -Force
& powershell -NoProfile -ExecutionPolicy Bypass -File $derive `
  -File (Join-Path $art 'rail-bg.rkspr') -Base 'lit.0' -Name 'lit.1' `
  -Map '*=+' -Boxes $signBox -Force
}

# 260x434 inside a 296x600 canvas. The rail is the same 320px wide on screen as
# it always was - what changed is that the stage draws at 1x instead of 2x, so
# the same strip of window holds four times the pixels. Eva's call, and the
# reason is measured: at 130x217 both irises together were ELEVEN pixels, and no
# amount of palette work makes eleven pixels into a face.
# HAND-PAINTED FRAME WINS. Eva painted the irises on this one by hand, and a
# build that re-imported the raw generation would throw that away - which is the
# whole reason [R-062] says the build is the only path. If the hand file is
# there it IS the source; the generation is only the fallback for a fresh start.
$railHand = Join-Path $art 'belka-rail.hand.png'
if (Test-Path -LiteralPath $railHand) {
  Write-Host ('  rail: using the hand-painted ' + (Split-Path -Leaf $railHand))
  $railSrc = $railHand
} else {
  & $python $prekey (Join-Path $InDir $RailBelka) (Join-Path $tmp 'rail.png') 260 434 auto 40
  $railSrc = (Join-Path $tmp 'rail.png')
}
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File $import `
  -In $railSrc -Name 'belka-rail' -Width 260 -Height 434 `
  -Scaling nearest -Colors 32 -FrameNames 'idle.0' -Png -PngScale 2 -Force |
  Where-Object { $_ -match 'wrote|opaque' }

# NO EYE RECTANGLES HERE ANY MORE. They existed so the state colour could paint
# the iris, and measurement showed why that had to stop: the letters they marked
# were pale tones the HAIR also uses, so the status colour landed on her fringe
# and her cheek rather than in her eyes. Rectangles cannot follow the shape of an
# iris, and at 28 colours the iris had no colour of its own to select either.
#
# Eva painted the irises herself instead, and they are now a real palette entry.
# "tint": "state" only ever touches * and + pixels, so with no markers here her
# green is simply left alone. The room's neon still carries the status. [R-068]

# ------------------------------------------------------- matching the two --
# NOT MATCHED ANY MORE, on purpose. [R-065] edited the wide cut's black to the
# rail's tone because the same outfit rendered two ways read as a mistake. The
# outfits are now deliberately different - white coat at the desk, black dress in
# bed - which is Eva's own idea and a better one: two views of the same person in
# different clothes read as "she changed", so the blacks no longer have to agree.
# What must still agree is identity - hair, eyes, face - and that is what the
# same-seed hair change and the iris rectangles above are for. [R-066]
#
# Also: here 'A' is mostly BOOTS (10,652 px of leather), and lightening leather to
# match a dress is the wrong instruction to give a palette. If the black is ever
# wanted lighter, it is one command and nothing in this script has to change:
#   rk-palette.ps1 -File art\belka.rkspr -Set 'A=#313338'

# ------------------------------------------------------------- her eyes --
# The eye is its own layer, drawn at 1x over a body drawn at 2x, so the same
# strip of screen carries four times the dots. gen-eye.py builds every frame
# from that region plus the iris Eva painted by hand in eye-iris-mask.png. If
# the mask is missing it says so and stops - the correct outcome, because a
# guessed iris is what put the status colour on her fringe.
#
# It is HERE, in the build, for the reason [R-062] exists: it was run by hand
# once, and the next full rebuild would have erased it. [R-069]
$genEye  = Join-Path $here 'gen-eye.py'
$eyeMask = Join-Path $here 'eye-iris-mask.png'
Write-Host ''
Write-Host '== eyes -> art\belka-eye.rkspr'
if (-not (Test-Path -LiteralPath $eyeMask)) {
  Write-Host ('  SKIPPED: no ' + (Split-Path -Leaf $eyeMask) + ' - run gen-eye.py once and paint the iris in it.')
} else {
  & $python $genEye
  if ($LASTEXITCODE -ne 0) { throw 'gen-eye.py failed' }
  & powershell -NoProfile -STA -ExecutionPolicy Bypass -File $draw `
    -Name 'belka-eye' -From (Join-Path $here 'draw-eye') -Colors 36 -NoPng |
    Where-Object { $_ -match 'wrote|distinct' }
}

Write-Host ''
Write-Host 'done. stage.json and rail.json were not touched.'
