# ============================================================
# rk-derive.ps1 - make a new frame out of an existing one by a DECLARED
# substitution, and write it as a row diff. ASCII only (PS 5.1 decodes a
# BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS. rk-import-art.ps1 turns one picture into one frame. An
# animation needs several, and the pictures for them do not exist: a second
# generation of the same character is a different character (see
# the image-generation notes), and hand-drawing
# every frame is the work this whole pipeline is trying to make optional.
#
# But a great many frames are not new drawings at all. They are the SAME drawing
# with one thing swapped:
#
#   blink        the iris colour becomes the eyelid colour
#   asleep       the same swap, held
#   powered down a lit colour becomes its unlit neighbour
#
# In an indexed picture those are palette-level facts, so they can be stated
# instead of drawn - and stated things can be counted, which is the point.
# "It looks like she blinked" is not a check; "1,204 pixels on 9 rows changed,
# and only on those rows" is.
#
# WHAT IT REFUSES TO DO
#   - write a frame that changes nothing (a silent no-op is the failure this
#     file is meant to make impossible)
#   - overwrite an existing frame without -Force
#   - touch '*' or '+' (the state colour) unless you name them explicitly:
#     those are the status readout, not decoration
#
#   powershell -File rk-derive.ps1 -File art\belka.rkspr -Base idle.0 `
#              -Name idle.1 -Map "G=S" -Rows 40-70
#   powershell -File rk-derive.ps1 -File art\belka.rkspr -Base idle.0 `
#              -Name sleep.0 -Map "G=S,H=S" -Force
# ============================================================

param(
  [Parameter(Mandatory)][string]$File,
  [Parameter(Mandatory)][string]$Base,     # frame to derive from (must already exist)
  [Parameter(Mandatory)][string]$Name,     # frame to write
  [string]$Map = '',                       # "A=B" or "A=B,C=D" - legend char -> legend char
  [string]$Rows = '',                      # "" = every row. "40-70" = that band only.
  [string]$Cols = '',                      # "" = every column. "190-240,280-335" = those only.
                                           # Rows alone is not enough: a colour that means "iris"
                                           # inside a face means "monitor" twenty pixels to the
                                           # left, on the same rows.
  [string]$Boxes = '',                     # "x0-x1,y0-y1; x0-x1,y0-y1" - one rectangle per feature.
                                           # Two eyes on a tilted head are not one row band and not
                                           # one column band; they are two rectangles. Supersedes
                                           # -Rows/-Cols when given.
  [switch]$All,                            # map EVERY palette char to -To. "Fill this rectangle
                                           # with skin" is one instruction, not thirty-six.
  [string]$To = '',                        # the destination char for -All
  [switch]$Blank,                          # every pixel -> '.' (transparent). For a cut that is
                                           # "not showing": a layer has no visibility flag, so the
                                           # off state of an overlay IS a frame full of nothing.
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'rk-sprite.ps1')

if (-not (Test-Path -LiteralPath $File)) { throw ('no such sprite: ' + $File) }
$File = (Resolve-Path -LiteralPath $File).Path

# Read with the REAL parser, so this tool and the window can never disagree
# about what a frame is. Diffs are already resolved into full rows here.
$sprite = Read-RkSprite -Path $File
if (-not $sprite.Frames.Contains($Base)) {
  throw ('no such frame: ' + $Base + '  (have: ' + ((@($sprite.Frames.Keys)) -join ', ') + ')')
}
if ($sprite.Frames.Contains($Name) -and -not $Force) {
  throw ('frame ' + $Name + ' already exists. Pass -Force to replace it.')
}

# ---- the substitution ------------------------------------------------------
if ($Blank -and $Map -ne '') { throw '-Blank and -Map are two different intentions. Pass one.' }
if ($All -and $Map -ne '')   { throw '-All and -Map are two different intentions. Pass one.' }
if ($All -and $Blank)        { throw '-All and -Blank are two different intentions. Pass one.' }
if (-not $Blank -and -not $All -and $Map -eq '') { throw 'pass -Map "A=B", -All -To <char>, or -Blank' }

$subs = @{}
if ($Blank) {
  foreach ($c in @($sprite.Palette.Keys)) { $subs[$c] = '.' }
  $subs['*'] = '.'; $subs['+'] = '.'
}
if ($All) {
  if ($To -eq '') { throw '-All needs -To <char>' }
  if ($To -ne '.' -and $To -ne '*' -and $To -ne '+' -and -not $sprite.Palette.ContainsKey($To)) {
    throw ('-To ' + $To + ' is not in the palette of ' + (Split-Path -Leaf $File))
  }
  foreach ($c in @($sprite.Palette.Keys)) { if ($c -ne $To) { $subs[$c] = $To } }
}
foreach ($pair in $Map.Split(',')) {
  $p = $pair.Trim()
  if ($p -eq '') { continue }
  if ($p -notmatch '^(.)=(.)$') { throw ('-Map wants single characters: "A=B[,C=D]". Got: ' + $p) }
  $from = $Matches[1]; $to = $Matches[2]
  if ($from -eq $to) { throw ('mapping ' + $p + ' changes nothing') }
  foreach ($c in @($from, $to)) {
    if ($c -eq '.') { continue }                                  # transparent is legal
    if ($c -eq '*' -or $c -eq '+') { continue }                   # named on purpose = allowed
    if (-not $sprite.Palette.ContainsKey($c)) {
      throw ('legend character ' + $c + ' is not in the palette of ' + (Split-Path -Leaf $File))
    }
  }
  $subs[$from] = $to
}
if ($subs.Count -eq 0) { throw '-Map is empty' }
$what = $(if ($Blank) { 'blank' } elseif ($All) { 'all -> ' + $To } else { $Map })

# ---- the row band ----------------------------------------------------------
$r0 = 0; $r1 = $sprite.Height - 1
if ($Rows -ne '') {
  if ($Rows -notmatch '^(\d+)-(\d+)$') { throw '-Rows wants "<first>-<last>", e.g. 40-70' }
  $r0 = [int]$Matches[1]; $r1 = [int]$Matches[2]
  if ($r0 -gt $r1) { throw ('-Rows is backwards: ' + $Rows) }
  if ($r1 -ge $sprite.Height) { throw ('-Rows ends at ' + $r1 + ' but the sprite is ' + $sprite.Height + ' rows (0..' + ($sprite.Height - 1) + ')') }
}

# ---- the column bands ------------------------------------------------------
$bands = @()
if ($Cols -ne '') {
  foreach ($b in $Cols.Split(',')) {
    $t = $b.Trim()
    if ($t -eq '') { continue }
    if ($t -notmatch '^(\d+)-(\d+)$') { throw '-Cols wants "<first>-<last>[,<first>-<last>]", e.g. 190-240,280-335' }
    $c0 = [int]$Matches[1]; $c1 = [int]$Matches[2]
    if ($c0 -gt $c1) { throw ('-Cols is backwards: ' + $t) }
    if ($c1 -ge $sprite.Width) { throw ('-Cols ends at ' + $c1 + ' but the sprite is ' + $sprite.Width + ' wide (0..' + ($sprite.Width - 1) + ')') }
    $bands += , @($c0, $c1)
  }
  if ($bands.Count -eq 0) { throw '-Cols is empty' }
}
function Test-RkInBand([int]$x) {
  if ($bands.Count -eq 0) { return $true }
  foreach ($b in $bands) { if ($x -ge $b[0] -and $x -le $b[1]) { return $true } }
  return $false
}

# ---- rectangles (supersede rows+cols) --------------------------------------
$rects = @()
if ($Boxes -ne '') {
  foreach ($r in $Boxes.Split(';')) {
    $t = $r.Trim()
    if ($t -eq '') { continue }
    if ($t -notmatch '^(\d+)-(\d+)\s*,\s*(\d+)-(\d+)$') {
      throw '-Boxes wants "x0-x1,y0-y1[; x0-x1,y0-y1]", e.g. "208-265,149-175; 322-374,179-199"'
    }
    $bx0 = [int]$Matches[1]; $bx1 = [int]$Matches[2]
    $by0 = [int]$Matches[3]; $by1 = [int]$Matches[4]
    if ($bx0 -gt $bx1 -or $by0 -gt $by1) { throw ('-Boxes rectangle is backwards: ' + $t) }
    if ($bx1 -ge $sprite.Width)  { throw ('-Boxes x ends at ' + $bx1 + ' but the sprite is ' + $sprite.Width + ' wide') }
    if ($by1 -ge $sprite.Height) { throw ('-Boxes y ends at ' + $by1 + ' but the sprite is ' + $sprite.Height + ' tall') }
    $rects += , @($bx0, $bx1, $by0, $by1)
  }
  if ($rects.Count -eq 0) { throw '-Boxes is empty' }
  $r0 = 0; $r1 = $sprite.Height - 1     # rectangles do the limiting now
}
function Test-RkInRect([int]$x, [int]$y) {
  if ($rects.Count -eq 0) { return (Test-RkInBand $x) }
  foreach ($r in $rects) { if ($x -ge $r[0] -and $x -le $r[1] -and $y -ge $r[2] -and $y -le $r[3]) { return $true } }
  return $false
}

# ---- build the new rows ----------------------------------------------------
$baseRows = @($sprite.Frames[$Base])
$diff     = New-Object System.Collections.ArrayList
$nPix     = 0

for ($i = 0; $i -lt $baseRows.Count; $i++) {
  if ($i -lt $r0 -or $i -gt $r1) { continue }
  $src = $baseRows[$i]
  $sb  = New-Object System.Text.StringBuilder
  $hit = 0
  for ($x = 0; $x -lt $src.Length; $x++) {
    $k = [string]$src[$x]
    if ($subs.ContainsKey($k) -and (Test-RkInRect $x $i)) { [void]$sb.Append($subs[$k]); $hit++ }
    else                                               { [void]$sb.Append($src[$x]) }
  }
  if ($hit -gt 0) {
    $nPix += $hit
    [void]$diff.Add(('' + $i + ' = ' + $sb.ToString()))
  }
}

if ($diff.Count -eq 0) {
  throw ('nothing changed - ' + $what + ' matched no pixel in ' + $Base +
         $(if ($Rows -ne '') { ' rows ' + $Rows } else { '' }) +
         '. Wrong legend character, or the wrong band.')
}

# ---- write it --------------------------------------------------------------
$lines = New-Object System.Collections.ArrayList
foreach ($l in [System.IO.File]::ReadAllLines($File)) { [void]$lines.Add($l) }

# Replacing: drop the old block (its @frame line up to the next @ line) and
# remember WHERE it was. Appending the replacement at the end instead would
# reorder the file, and "from" only looks upwards - so re-deriving a frame that
# something else is built on top of would break the file that was working a
# moment ago. (Found by doing exactly that, 2026-09-09.)
$insertAt = -1
if ($sprite.Frames.Contains($Name)) {
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match ('^@frame\s+' + [regex]::Escape($Name) + '(\s|$)')) { $start = $i; break }
  }
  if ($start -ge 0) {
    # Where the block ENDS is measured from the @frame line, not from $start:
    # $start moves up onto the comment a moment later, and scanning from there
    # finds the @frame line itself as the terminator - so the old block survived
    # and only its comment was removed. The parser takes the LAST definition of a
    # name, which meant a re-derive silently kept the OLD frame while printing
    # the new one's numbers. (Found 2026-09-10 by the self-check at the bottom of
    # this file: "claimed 2726 changed pixels but the file reads back 1101".)
    $frameAt = $start
    if ($start -gt 0 -and $lines[$start - 1] -match '^#\s+\S+ - derived from ') { $start-- }
    $end = $lines.Count
    for ($i = $frameAt + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^@') { $end = $i; break } }
    $lines.RemoveRange($start, $end - $start)
    $insertAt = $start
  }
}

$out = New-Object System.Collections.ArrayList
# One blank line before the block - but only if there is not one there already.
# Replacing a frame removes its comment and rows and leaves the blank that
# preceded them, so adding another here grew the file by a line on every
# re-derive ([R-091] W13). Harmless, and still wrong.
$prevLine = $null
if ($insertAt -gt 0) { $prevLine = $lines[$insertAt - 1] } elseif ($insertAt -lt 0 -and $lines.Count -gt 0) { $prevLine = $lines[$lines.Count - 1] }
if ($null -eq $prevLine -or $prevLine.Trim() -ne '') { [void]$out.Add('') }
[void]$out.Add('# ' + $Name + ' - derived from ' + $Base + ' by rk-derive.ps1: ' + $what +
               $(if ($Rows -ne '') { ' on rows ' + $Rows } else { ' on every row' }) + $(if ($Cols -ne '') { ' cols ' + $Cols } else { '' }) + $(if ($Boxes -ne '') { ' boxes ' + $Boxes } else { '' }) +
               '. ' + $nPix + ' pixels on ' + $diff.Count + ' rows.')
[void]$out.Add('@frame ' + $Name + ' from ' + $Base)
foreach ($d in $diff) { [void]$out.Add($d) }

if ($insertAt -ge 0) { $lines.InsertRange($insertAt, $out) } else { $lines.AddRange($out) }
[System.IO.File]::WriteAllLines($File, $lines, (New-Object System.Text.UTF8Encoding($false)))

# ---- prove it parses, and that it changed exactly what was claimed ---------
$after = Read-RkSprite -Path $File
if (-not $after.Frames.Contains($Name)) { throw 'wrote the frame but the parser does not see it' }
$a = @($after.Frames[$Base]); $b = @($after.Frames[$Name])
$check = 0
for ($i = 0; $i -lt $a.Count; $i++) {
  for ($c = 0; $c -lt $a[$i].Length; $c++) { if ($a[$i][$c] -ne $b[$i][$c]) { $check++ } }
}
if ($check -ne $nPix) { throw ('claimed ' + $nPix + ' changed pixels but the file reads back ' + $check) }

Write-Host ('wrote @frame ' + $Name + ' from ' + $Base + '  (' + $what +
            $(if ($Rows -ne '') { ', rows ' + $Rows } else { '' }) + $(if ($Cols -ne '') { ', cols ' + $Cols } else { '' }) + $(if ($Boxes -ne '') { ', boxes ' + $Boxes } else { '' }) + ')')
Write-Host ('  ' + $nPix + ' pixels on ' + $diff.Count + ' of ' + $sprite.Height + ' rows')
Write-Host ('  ' + (Split-Path -Leaf $File) + ' now has ' + $after.Frames.Count + ' frames, ' + $after.Width + 'x' + $after.Height)
