# ============================================================
# rk-sprite.ps1 - text pixel maps -> BitmapSource. ASCII only (PS 5.1 decodes a
# BOM-less .ps1 as ANSI).
#
# WHY A TEXT FORMAT AND NOT A PNG. Every other visual decision in this window is
# reviewable in a diff and recolourable by the theme; a binary sprite would be
# neither. A .rkspr is a legend plus rows of characters, so a frame edit shows
# up in git as the pixels that changed, and the two characters that carry
# MEANING - '*' and '+' - are left unbound in the file and filled in at build
# time with the state colour. The keeper's eyes are the status light; they
# cannot be baked into an image.
#
# It also means no image file ships with the panel, which is the same promise
# the pixel and cyber themes make: nothing to download, nothing to install on a
# friend's machine.
#
# FORMAT
#   @palette                  X #RRGGBB per line ('.' is reserved: transparent)
#   @frame <name>             rows of legend characters until the next @ line
#   @frame <name> from <base> copy <base>, then apply "<rowIndex> = <row>" lines
#   '*'                       the signal colour, supplied by the caller
#   '+'                       the signal colour at reduced alpha
#
# The "from" form is not a convenience. Eight full copies of one character drift:
# an edit meant for one pose lands in one frame and not its pair, and a two-frame
# loop that was supposed to blink starts twitching sideways instead. Writing a
# pose as the rows that differ makes that class of mistake unrepresentable.
#
# Frames are rasterised at Scale by repeating pixels rather than by letting WPF
# scale the bitmap: a blurred sprite is the one failure this whole file exists
# to avoid, and RenderTargetBitmap does not honour NearestNeighbor set on an
# ancestor.
# ============================================================

function Read-RkSprite {
  param([Parameter(Mandatory)][string]$Path)

  $palette = @{}
  $frames  = [ordered]@{}
  $cur     = $null
  $rows    = $null

  # One read of the file: the same bytes feed the parser and the hash below.
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
  foreach ($raw in ($text -split "`r?`n")) {
    $line = $raw.TrimEnd()
    if ($line -match '^\s*#') { continue }
    if ($line -match '^@palette\s*$') {
      if ($cur) { $frames[$cur] = @($rows) }
      $cur = $null; $rows = $null
      $mode = 'palette'
      continue
    }
    if ($line -match '^@frame\s+(\S+)(?:\s+from\s+(\S+))?\s*$') {
      if ($cur) { $frames[$cur] = @($rows) }
      $cur = $Matches[1]
      $rows = New-Object System.Collections.ArrayList
      $mode = 'frame'
      $base = $Matches[2]
      if ($base) {
        if (-not $frames.Contains($base)) { throw ('frame ' + $cur + ' derives from ' + $base + ', which is not defined above it') }
        foreach ($r in $frames[$base]) { [void]$rows.Add($r) }
        $mode = 'diff'
      }
      continue
    }
    if ($line -match '^\s*$') { continue }

    if ($mode -eq 'palette') {
      if ($line -match '^\s*(\S)\s*=\s*(#[0-9A-Fa-f]{6})\s*$') { $palette[$Matches[1]] = $Matches[2] }
      continue
    }
    if ($mode -eq 'diff') {
      if ($line -notmatch '^\s*(\d+)\s*=\s*(\S+)\s*$') { throw ('frame ' + $cur + ' is a diff, so every line must be "<row> = <pixels>": ' + $line) }
      $idx = [int]$Matches[1]
      if ($idx -lt 0 -or $idx -ge $rows.Count) { throw ('frame ' + $cur + ' patches row ' + $idx + ', which is outside 0..' + ($rows.Count - 1)) }
      $rows[$idx] = $Matches[2]
      continue
    }
    if ($mode -eq 'frame') { [void]$rows.Add($line) }
  }
  if ($cur) { $frames[$cur] = @($rows) }

  if ($frames.Count -eq 0) { throw ('sprite has no frames: ' + $Path) }

  # Every frame must be the same size, or a two-frame animation moves the whole
  # character sideways when it was only meant to blink.
  $w = 0; $h = 0
  foreach ($k in $frames.Keys) {
    $f = $frames[$k]
    if ($h -eq 0) { $h = $f.Count; $w = $f[0].Length }
    if ($f.Count -ne $h) { throw ('frame ' + $k + ' has ' + $f.Count + ' rows, expected ' + $h) }
    foreach ($r in $f) { if ($r.Length -ne $w) { throw ('frame ' + $k + ' has a row of ' + $r.Length + ' chars, expected ' + $w) } }
  }

  # A fingerprint of the FILE, so anything cached from this sprite (rasterised
  # frames on disk, see Get-RkStageFrameImage) is keyed to these exact bytes
  # and falls out of use the moment the art is re-imported or hand-edited.
  # Sixteen hex digits of MD5 over the raw bytes; 2 ms for a 190 KB sprite.
  $hash = ''
  try {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = (([System.BitConverter]::ToString($md5.ComputeHash($bytes))) -replace '-', '').Substring(0, 16).ToLower()
    $md5.Dispose()
  } catch { $hash = '' }

  return [pscustomobject]@{ Palette = $palette; Frames = $frames; Width = $w; Height = $h; Path = $Path; Hash = $hash }
}

function ConvertTo-RkColor([string]$hex, [int]$alpha = -1) {
  # Accepts #RRGGBB and #AARRGGBB. The second form is not hypothetical: the
  # state colours reach here from Color.ToString(), which always emits
  # #AARRGGBB, so reading the first six digits gave FF-FF-3D for magenta and
  # drew the keeper's eyes yellow while she was reporting a dead server. The
  # colour that carries the meaning was the colour that was wrong.
  # An explicit -alpha wins over the one in the string, or the dim variant of a
  # colour that arrived as #AARRGGBB would silently come back fully opaque.
  $h = $hex.TrimStart('#')
  $a = 255
  if ($h.Length -eq 8) { $a = [Convert]::ToInt32($h.Substring(0, 2), 16); $h = $h.Substring(2) }
  if ($alpha -ge 0) { $a = $alpha }
  $alpha = $a
  if ($h.Length -ne 6) { throw ('not a colour: ' + $hex) }
  $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
  $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
  $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
  return @($b, $g, $r, $alpha)   # Bgra32 order
}

function New-RkSpriteImage {
  param(
    [Parameter(Mandatory)]$Sprite,
    [Parameter(Mandatory)][string]$Frame,
    [int]$Scale = 4,
    [string]$Signal = '#22E6FF',
    [int]$DimAlpha = 110
  )

  if (-not $Sprite.Frames.Contains($Frame)) { throw ('no such frame: ' + $Frame) }
  $rows = $Sprite.Frames[$Frame]
  $w = $Sprite.Width; $h = $Sprite.Height
  $ow = $w * $Scale;  $oh = $h * $Scale

  # Resolve the legend once per call instead of per pixel.
  $map = @{}
  foreach ($k in $Sprite.Palette.Keys) { $map[[char]$k] = (ConvertTo-RkColor $Sprite.Palette[$k]) }
  $map[[char]'*'] = (ConvertTo-RkColor $Signal)
  $map[[char]'+'] = (ConvertTo-RkColor $Signal $DimAlpha)

  $stride = $ow * 4
  $buf = New-Object 'byte[]' ($stride * $oh)

  for ($y = 0; $y -lt $h; $y++) {
    $row = $rows[$y]
    for ($x = 0; $x -lt $w; $x++) {
      $ch = $row[$x]
      if ($ch -eq '.') { continue }
      $c = $map[$ch]
      if (-not $c) { continue }        # unknown legend char = hole, not a crash
      for ($sy = 0; $sy -lt $Scale; $sy++) {
        $base = (($y * $Scale + $sy) * $stride) + ($x * $Scale * 4)
        for ($sx = 0; $sx -lt $Scale; $sx++) {
          $o = $base + ($sx * 4)
          $buf[$o]     = $c[0]
          $buf[$o + 1] = $c[1]
          $buf[$o + 2] = $c[2]
          $buf[$o + 3] = $c[3]
        }
      }
    }
  }

  $bmp = [System.Windows.Media.Imaging.BitmapSource]::Create(
    $ow, $oh, 96, 96, [System.Windows.Media.PixelFormats]::Bgra32, $null, $buf, $stride)
  $bmp.Freeze()
  return $bmp
}

# ============================================================================
# PNG sprite sheets
#
# The text format above is for art that has to be RECOLOURED at runtime (the
# keeper's eyes carry the server state, so they cannot be baked into an image).
# Everything else - anything drawn in Aseprite and exported - arrives as a PNG
# sheet, and this is the door for it. No PowerShell has to change to add art:
# a .png next to a manifest entry is the whole contract.
#
# Cells are indexed left to right, top to bottom, from a fixed frame size.
# CroppedBitmap costs nothing per frame (it is a view onto the decoded sheet),
# so a 200-cell sheet is one decode and 200 rectangles.
# ============================================================================
function Read-RkSheet {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][int]$FrameW,
    [Parameter(Mandatory)][int]$FrameH
  )
  if (-not (Test-Path -LiteralPath $Path)) { throw ('no such sprite sheet: ' + $Path) }

  # OnLoad + a stream we close ourselves: the default caching keeps the file
  # handle open, and an artist who re-exports the sheet while the window is up
  # would get "the process cannot access the file".
  $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
  $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
  try {
    $bmp.BeginInit()
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.StreamSource = $fs
    $bmp.EndInit()
  } finally { $fs.Close() }
  $bmp.Freeze()

  if ($FrameW -le 0 -or $FrameH -le 0) { throw ('frame size must be positive: ' + $Path) }
  $cols = [math]::Floor($bmp.PixelWidth / $FrameW)
  $rows = [math]::Floor($bmp.PixelHeight / $FrameH)
  if ($cols -lt 1 -or $rows -lt 1) {
    throw ('sheet ' + $Path + ' is ' + $bmp.PixelWidth + 'x' + $bmp.PixelHeight +
           ', smaller than one ' + $FrameW + 'x' + $FrameH + ' frame')
  }

  return [pscustomobject]@{
    Bitmap = $bmp; FrameW = $FrameW; FrameH = $FrameH
    Cols = $cols; Rows = $rows; Count = ($cols * $rows); Path = $Path
  }
}

function New-RkSheetImage {
  param([Parameter(Mandatory)]$Sheet, [Parameter(Mandatory)][int]$Cell, [int]$Scale = 1)
  if ($Cell -lt 0 -or $Cell -ge $Sheet.Count) {
    throw ('cell ' + $Cell + ' is outside ' + (Split-Path -Leaf $Sheet.Path) + ' (0..' + ($Sheet.Count - 1) + ')')
  }
  $x = ($Cell % $Sheet.Cols) * $Sheet.FrameW
  $y = [math]::Floor($Cell / $Sheet.Cols) * $Sheet.FrameH
  $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap(
    $Sheet.Bitmap, (New-Object System.Windows.Int32Rect($x, $y, $Sheet.FrameW, $Sheet.FrameH)))
  $crop.Freeze()
  if ($Scale -le 1) { return $crop }

  # Scaled here rather than by the Image control, for the same reason the text
  # format is: RenderTargetBitmap does not honour NearestNeighbor set on an
  # ancestor, so a preview would show a blurred sheet that the live window does
  # not have - a preview that lies.
  $tb = New-Object System.Windows.Media.Imaging.TransformedBitmap(
    $crop, (New-Object System.Windows.Media.ScaleTransform($Scale, $Scale)))
  $tb.Freeze()
  return $tb
}
