# ============================================================
# rk-palette.ps1 - read or change the COLOURS of an imported .rkspr, without
# touching a single pixel. ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS. Three kinds of adjustment come up constantly once art is in:
# "her eyes should be the other green", "this black is too heavy", "the lashes
# are too pale". None of them is a drawing job and none of them is a reason to
# generate the picture again:
#
#   generate again -> a different picture. Same prompt, one word changed, and
#                     the pose, the hands and the face all move. Whatever match
#                     you already had is gone. (See
#                     the image-generation notes)
#   paint by hand  -> hundreds of pixels edited to change one value that is
#                     written once, on one line, in the legend.
#   change the hex -> every pixel using that entry moves together, exactly,
#                     reversibly, and the diff is one line.
#
# In an indexed picture, "what colour is this" is a fact about the LEGEND. So it
# is edited in the legend.
#
# WHAT IT WILL NOT DO. It cannot add tone where the median cut did not put an
# entry: if a dress came out as one flat black, this makes that black a
# different black, not a black with folds in it. Folds are more entries, which
# is -Colors on the importer, or a different source picture. (Measured
# 2026-09-09: raising -Colors from 24 to 36 on the wide cut took the dark
# entries from 6 to 8 - the median cut spent the rest on skin. Colour count is
# not the lever for that; the source is.)
#
#   powershell -File rk-palette.ps1 -File art\belka.rkspr                  # show
#   powershell -File rk-palette.ps1 -File art\belka.rkspr -Set "A=#343435"
#   powershell -File rk-palette.ps1 -File art\belka.rkspr -Set "A=#343435,E=#4A4A4B"
#
# Re-importing overwrites the file and loses this. Put the call in
# build-belka.ps1 next to the derives, which is where the rest of the declared
# edits live.
# ============================================================

param(
  [Parameter(Mandatory)][string]$File,
  [string]$Set = ''                        # "A=#RRGGBB[,B=#RRGGBB]". Empty = just show.
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'rk-sprite.ps1')

if (-not (Test-Path -LiteralPath $File)) { throw ('no such sprite: ' + $File) }
$File = (Resolve-Path -LiteralPath $File).Path

# The real parser, so this tool and the window cannot disagree about what the
# legend is. Frames come back resolved, which is what makes the pixel counts
# below true of every frame and not just the first.
$sprite = Read-RkSprite -Path $File

# How many pixels each entry actually paints, across every frame. Printed with
# the colour because "is this entry worth changing" is a question about area.
$counts = @{}
foreach ($k in @($sprite.Frames.Keys)) {
  foreach ($row in @($sprite.Frames[$k])) {
    foreach ($ch in $row.ToCharArray()) {
      $c = [string]$ch
      if (-not $counts.ContainsKey($c)) { $counts[$c] = 0 }
      $counts[$c]++
    }
  }
}
$nFrames = $sprite.Frames.Count

if ($Set -eq '') {
  Write-Host ((Split-Path -Leaf $File) + '  ' + $sprite.Width + 'x' + $sprite.Height +
              ', ' + $sprite.Palette.Count + ' colours, ' + $nFrames + ' frame(s)')
  Write-Host '  char  colour    pixels/frame'
  foreach ($c in ($sprite.Palette.Keys | Sort-Object { -$counts[$_] })) {
    Write-Host ('  ' + $c.PadRight(5) + ' ' + $sprite.Palette[$c] + '  ' +
                ([int]($counts[$c] / $nFrames)).ToString().PadLeft(8))
  }
  foreach ($c in @('.', '*', '+')) {
    if ($counts.ContainsKey($c)) {
      $what = @{ '.' = 'transparent'; '*' = 'state colour'; '+' = 'state, dimmed' }[$c]
      Write-Host ('  ' + $c.PadRight(5) + ' ' + $what.PadRight(9) + '  ' +
                  ([int]($counts[$c] / $nFrames)).ToString().PadLeft(8))
    }
  }
  exit 0
}

# ---- change ----------------------------------------------------------------
$want = [ordered]@{}
foreach ($pair in $Set.Split(',')) {
  $p = $pair.Trim()
  if ($p -eq '') { continue }
  if ($p -notmatch '^(.)\s*=\s*(#[0-9A-Fa-f]{6})$') {
    throw ('-Set wants "<char>=#RRGGBB[,<char>=#RRGGBB]". Got: ' + $p)
  }
  $c = $Matches[1]; $hex = $Matches[2].ToUpper()
  if ($c -eq '.' -or $c -eq '*' -or $c -eq '+') {
    throw ($c + ' is not a palette entry. ''.'' is transparent and ''*''/''+'' are the state colour, which the theme supplies.')
  }
  if (-not $sprite.Palette.ContainsKey($c)) {
    throw ('legend character ' + $c + ' is not in the palette of ' + (Split-Path -Leaf $File) +
           '. Run without -Set to see what is.')
  }
  if ($sprite.Palette[$c].ToUpper() -eq $hex) { throw ($c + ' is already ' + $hex) }
  if (-not $counts.ContainsKey($c)) {
    throw ($c + ' is in the legend but paints no pixel - changing it would do nothing.')
  }
  $want[$c] = $hex
}
if ($want.Count -eq 0) { throw '-Set is empty' }

$lines = [System.IO.File]::ReadAllLines($File)
$out   = New-Object System.Collections.ArrayList
$done  = @{}
$mode  = ''
foreach ($l in $lines) {
  if ($l -match '^@palette\s*$') { $mode = 'p' }
  elseif ($l -match '^@') { $mode = 'f' }
  if ($mode -eq 'p' -and $l -match '^\s*(\S)\s*=\s*#[0-9A-Fa-f]{6}\s*$') {
    $c = $Matches[1]
    if ($want.Contains($c)) {
      [void]$out.Add($c + ' = ' + $want[$c])
      $done[$c] = $true
      continue
    }
  }
  [void]$out.Add($l)
}
foreach ($c in @($want.Keys)) {
  if (-not $done.ContainsKey($c)) { throw ('found ' + $c + ' in the parsed legend but not as a line in the file') }
}

[System.IO.File]::WriteAllLines($File, $out, (New-Object System.Text.UTF8Encoding($false)))

# ---- prove it -------------------------------------------------------------
$after = Read-RkSprite -Path $File
foreach ($c in @($want.Keys)) {
  if ($after.Palette[$c].ToUpper() -ne $want[$c]) {
    throw ('wrote ' + $c + '=' + $want[$c] + ' but the file reads back ' + $after.Palette[$c])
  }
  Write-Host ('  ' + $c + ': ' + $sprite.Palette[$c] + ' -> ' + $want[$c] +
              '   (' + [int]($counts[$c] / $nFrames) + ' px/frame)')
}
Write-Host ((Split-Path -Leaf $File) + ': ' + $want.Count + ' entr' +
            $(if ($want.Count -eq 1) { 'y' } else { 'ies' }) + ' changed, 0 pixels moved')
