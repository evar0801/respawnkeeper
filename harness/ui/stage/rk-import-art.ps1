# ============================================================
# rk-import-art.ps1 - turn what an image generator produced into what the stage
# can read. ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS. The stage already reads .rkspr and .png sheets, so the LAST
# step of getting art onto the window was never the problem. The missing step is
# the one before it: ComfyUI hands you an 832x1216 full-colour PNG and the stage
# wants a small indexed picture whose pixels are pixels. Nothing converted
# between those, so every generated image stopped at the door.
#
#   ComfyUI  ->  [this]  ->  art\<name>.rkspr  ->  stage.json  ->  the window
#
# IT DOES NOT DRAW ANYTHING. It resamples, cuts a background out, reduces the
# colours and writes the result as text. Every pixel it emits came from the file
# it was handed.
#
# WHY .rkspr AND NOT .png. Three reasons, all of them the format's original ones:
#   - '*' and '+' are the state colour. A PNG is never recoloured, so a PNG
#     character cannot be the status readout - which is the keeper's entire
#     reason to exist. In a .rkspr you open the file and change the pixels that
#     should glow into '*'.
#   - a re-import shows up in git as the pixels that changed.
#   - nothing binary ships to a friend's machine.
# A real Aseprite sheet can still go in as .png via stage.json; both are
# supported. This is for the generated case.
#
# COLOUR REDUCTION IS MEDIAN CUT, NOT K-MEANS, deliberately. The ComfyUI-Pixelate
# node samples 10,000 pixels for k-means with no seed, so its palette drifts on
# every run and re-importing one file gives different art each time. Median cut
# is a deterministic function of the histogram: same input, same output, always.
#
# AT MOST 36 COLOURS, and that is a hard limit of the .rkspr format rather than
# a round number: a legend cannot contain two characters that differ only by
# case. See the LEGEND comment further down for what happens when it does.
#
#   # a background, sized exactly to the stage, never recoloured
#   powershell -STA -File rk-import-art.ps1 -In room.png -Name bg-room -Width 128 -Height 128 -Fit cover
#
#   # a character, background keyed out, two frames sharing one legend
#   powershell -STA -File rk-import-art.ps1 -In "sit0.png,sit1.png" -Name belka -Width 48 -Transparent auto -FrameNames sit.0,sit.1
#
# It prints the stage.json layer to paste, warns if the result will not fit the
# stage next door, and never overwrites a hand-marked file without saying so.
# ============================================================

param(
  [Parameter(Mandatory)][string[]]$In,      # source images. Order = frame order.
  [string]$Name = '',                       # output basename (default: first input's)
  [string]$OutDir = '',                     # default: art\ next to this script
  [int]$Width  = 128,                       # logical pixels. 0 = derive from Height
  [int]$Height = 0,                         # 0 = derive from Width, keeping aspect
  [ValidateRange(2, 36)]
  [int]$Colors = 16,                        # 36 is the hard ceiling - see LEGEND below
  [ValidateSet('none', 'contain', 'cover', 'stretch')]
  [string]$Fit = 'none',                    # what to do when BOTH -Width and -Height are given
  [ValidateSet('fant', 'nearest')]
  [string]$Scaling = 'fant',                # 'nearest' if the source is ALREADY pixel art
  [string]$Transparent = 'none',            # 'none' | 'auto' (corners) | '#RRGGBB'
  [int]$Tolerance = 24,                     # 0-255, how close counts as the key colour
  [int]$Deedge = 0,                         # 0 = off. Pixels TOUCHING a keyed-out pixel get a
                                            # second, wider key test at this distance. Cuts the
                                            # resampled halo the per-pixel key cannot reach; safe
                                            # to set generously because it only ever looks at the
                                            # outline. See the note at the edge pass.
  [int]$DeedgePasses = 1,                   # how many one-pixel rings to peel
  [string]$Glow = '',                       # #RRGGBB painted in the art -> '*' (the state colour)
  [string]$Dim  = '',                       # #RRGGBB painted in the art -> '+' (state colour, dimmed)
  [string[]]$FrameNames = @(),              # default: idle.0, idle.1, ...
  [switch]$Png,                             # also write the result as a PNG
  [int]$PngScale = 4,                       # extra enlarged copy; 1 = don't write one
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, WindowsBase, PresentationFramework

# powershell.exe -File does not parse PowerShell arrays: "-In a.png,b.png" arrives
# as ONE string with a comma in it, and the documented invocation above would die
# with "no such image: a.png,b.png". Split it back, but only when every piece is
# a file that exists - a real filename containing a comma must survive untouched.
function Expand-RkListArg([string[]]$items) {
  $out = New-Object System.Collections.ArrayList
  foreach ($it in $items) {
    if ($it -like '*,*' -and -not (Test-Path -LiteralPath $it)) {
      $parts = $it.Split(',')
      $missing = @($parts | Where-Object { -not (Test-Path -LiteralPath $_) })
      if ($missing.Count -eq 0) { foreach ($p in $parts) { [void]$out.Add($p) }; continue }
      # Naming the pieces that are missing rather than echoing the whole joined
      # string back: one typo in a five-file list used to print all five as a
      # single unfindable path, which reads as "the splitting is broken".
      if ($missing.Count -lt $parts.Count) {
        throw ('-In looks like a comma-separated list, but these do not exist:' + [Environment]::NewLine +
               '  ' + ($missing -join ([Environment]::NewLine + '  ')))
      }
    }
    [void]$out.Add($it)
  }
  return @($out)
}
$In = Expand-RkListArg $In
if ($FrameNames.Count -eq 1 -and $FrameNames[0] -like '*,*') { $FrameNames = @($FrameNames[0].Split(',')) }

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'art' }
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir) }
if (-not $Name) { $Name = [System.IO.Path]::GetFileNameWithoutExtension($In[0]) }
$outFile = Join-Path $OutDir ($Name + '.rkspr')
if (Test-Path -LiteralPath $outFile) {
  if (-not $Force) {
    throw ($outFile + ' exists. Pass -Force to overwrite - the file there may be art you are still using.')
  }
  # The one edit an import cannot reproduce is the * pass: which pixels are the
  # status light is a decision that exists nowhere in the source image. Silently
  # overwriting it is the difference between losing a file you can regenerate
  # and losing a judgement you cannot.
  $prior = [System.IO.File]::ReadAllLines($outFile)
  $marked = 0
  foreach ($l in $prior) {
    if ($l -match '^\s*#' -or $l -match '^@' -or $l -match '^\s*\S\s*=\s*#') { continue }
    $marked += ([regex]::Matches($l, '[\*\+]')).Count
  }
  if ($marked -gt 0) {
    Write-Host ('  WARNING: ' + (Split-Path -Leaf $outFile) + ' has ' + $marked +
                ' state-colour pixels (* or +) marked by hand. -Force is about to discard them.')
    Write-Host ('           A copy is being kept at ' + (Split-Path -Leaf $outFile) + '.marked')
    Copy-Item -LiteralPath $outFile -Destination ($outFile + '.marked') -Force
  }
}

# ---- load + resample ---------------------------------------------------------
# The resample runs inside WPF rather than in a PowerShell pixel loop: Fant is a
# proper area filter implemented natively, and a 1M-pixel loop in PS 5.1 takes
# minutes. Only the small result is ever read back.
function Get-RkResampled([string]$path, [int]$w, [int]$h) {
  if (-not (Test-Path -LiteralPath $path)) { throw ('no such image: ' + $path) }
  $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
  $fs = [System.IO.File]::Open((Resolve-Path -LiteralPath $path).Path, 'Open', 'Read', 'ReadWrite')
  try {
    $bmp.BeginInit()
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.StreamSource = $fs
    $bmp.EndInit()
  } finally { $fs.Close() }
  $bmp.Freeze()

  # Aspect is derived here rather than guessed by the caller, so -Width alone is
  # a complete instruction.
  if ($w -le 0 -and $h -le 0) { throw 'give -Width or -Height' }
  if ($w -le 0) { $w = [int][math]::Max(1, [math]::Round($bmp.PixelWidth  * ($h / $bmp.PixelHeight))) }
  if ($h -le 0) { $h = [int][math]::Max(1, [math]::Round($bmp.PixelHeight * ($w / $bmp.PixelWidth))) }

  # WHERE THE PICTURE SITS INSIDE THE CANVAS. With -Fit none the canvas IS the
  # picture and the aspect above decided it, which is why "-Width 128" on a
  # 832x1216 frame produces 128x187 - taller than a 128x128 stage, and the
  # console's ClipToBounds then eats the bottom 59 rows without saying anything.
  # -Fit contain keeps the whole picture and pads with transparent; cover fills
  # the canvas and lets the overflow fall off the edge; stretch distorts.
  $dx = 0.0; $dy = 0.0; $dw = [double]$w; $dh = [double]$h
  if ($Fit -ne 'none') {
    if ($Width -le 0 -or $Height -le 0) { throw ('-Fit ' + $Fit + ' needs both -Width and -Height') }
    $w = $Width; $h = $Height
    $sx = $w / $bmp.PixelWidth; $sy = $h / $bmp.PixelHeight
    if ($Fit -eq 'stretch') {
      $dw = [double]$w; $dh = [double]$h
    } else {
      $s = $(if ($Fit -eq 'contain') { [math]::Min($sx, $sy) } else { [math]::Max($sx, $sy) })
      $dw = $bmp.PixelWidth * $s; $dh = $bmp.PixelHeight * $s
    }
    $dx = ($w - $dw) / 2.0; $dy = ($h - $dh) / 2.0
  }

  $dv = New-Object System.Windows.Media.DrawingVisual
  $dc = $dv.RenderOpen()
  if ($Scaling -eq 'nearest') {
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($dv, [System.Windows.Media.BitmapScalingMode]::NearestNeighbor)
  } else {
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($dv, [System.Windows.Media.BitmapScalingMode]::Fant)
  }
  $dc.DrawImage($bmp, (New-Object System.Windows.Rect($dx, $dy, $dw, $dh)))
  $dc.Close()

  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($dv)
  $stride = $w * 4
  $buf = New-Object byte[] ($stride * $h)
  $rtb.CopyPixels($buf, $stride, 0)
  return [pscustomobject]@{ Px = $buf; W = $w; H = $h; SrcW = $bmp.PixelWidth; SrcH = $bmp.PixelHeight }
}

# ---- the transparent key -----------------------------------------------------
# 'auto' reads the four corners and takes the colour owning at least three of
# them. Two different corner colours means the image does not HAVE a flat
# background, and quietly picking one would punch a hole in the picture.
function Get-RkKeyColour($img) {
  if ($Transparent -eq 'none') { return $null }
  if ($Transparent -match '^#([0-9A-Fa-f]{6})$') {
    $v = [Convert]::ToInt32($Matches[1], 16)
    return @{ R = (($v -shr 16) -band 255); G = (($v -shr 8) -band 255); B = ($v -band 255) }
  }
  if ($Transparent -ne 'auto') { throw '-Transparent must be none, auto, or #RRGGBB' }

  # THE CORNERS ARE COMPARED WITH THE SAME TOLERANCE THAT DOES THE KEYING.
  # The first version matched them as exact strings while the cut below used
  # +/-Tolerance, so a genuinely flat background came back as "4 colours,
  # disagreeing" and nothing was keyed out. Measured on a real ComfyUI frame,
  # the four corners of a perfectly flat background land on #3F5D5F #3D5B5E
  # #3E5C5F #3D5C5F once Fant has resampled it - a spread of 2/255. An exact
  # match can only ever succeed on an image that was already indexed, which is
  # exactly the image that does not need this option.
  $corners = @(@(0, 0), @(($img.W - 1), 0), @(0, ($img.H - 1)), @(($img.W - 1), ($img.H - 1)))
  $cols = @()
  foreach ($c in $corners) {
    $i = (($c[1] * $img.W) + $c[0]) * 4
    $cols += , @([int]$img.Px[$i + 2], [int]$img.Px[$i + 1], [int]$img.Px[$i])
  }
  $best = $null; $bestN = 0
  foreach ($a in $cols) {
    $grp = @($cols | Where-Object {
        [math]::Abs($_[0] - $a[0]) -le $Tolerance -and
        [math]::Abs($_[1] - $a[1]) -le $Tolerance -and
        [math]::Abs($_[2] - $a[2]) -le $Tolerance
      })
    if ($grp.Count -gt $bestN) { $bestN = $grp.Count; $best = $grp }
  }
  if ($bestN -lt 3) {
    Write-Host ('  -Transparent auto: the corners disagree by more than -Tolerance ' + $Tolerance +
                '. Keying nothing out - raise -Tolerance, or pass an explicit #RRGGBB.')
    return $null
  }
  # The average of the agreeing corners, not one arbitrary corner: the key sits
  # in the middle of the cluster so +/-Tolerance reaches all of it.
  $r = 0; $g = 0; $b = 0
  foreach ($c in $best) { $r += $c[0]; $g += $c[1]; $b += $c[2] }
  return @{ R = [int][math]::Round($r / $best.Count)
            G = [int][math]::Round($g / $best.Count)
            B = [int][math]::Round($b / $best.Count) }
}

# ---- median cut --------------------------------------------------------------
# Deterministic: the palette is a function of the histogram, so re-importing the
# same file gives the same palette. See the header for why that matters.
function Get-RkPalette($pixels, [int]$n) {
  if ($pixels.Count -eq 0) { return @() }
  $boxes = @(, $pixels)
  while ($boxes.Count -lt $n) {
    $bi = -1; $bestRange = -1; $bestCh = 0
    for ($i = 0; $i -lt $boxes.Count; $i++) {
      if ($boxes[$i].Count -lt 2) { continue }
      for ($ch = 0; $ch -lt 3; $ch++) {
        $lo = 255; $hi = 0
        foreach ($p in $boxes[$i]) { $v = $p[$ch]; if ($v -lt $lo) { $lo = $v }; if ($v -gt $hi) { $hi = $v } }
        $r = $hi - $lo
        if ($r -gt $bestRange) { $bestRange = $r; $bi = $i; $bestCh = $ch }
      }
    }
    if ($bi -lt 0 -or $bestRange -le 0) { break }   # every box is one colour: done
    $sorted = @($boxes[$bi] | Sort-Object -Property @{ Expression = { $_[$bestCh] } })

    # THE SPLIT POINT IS NUDGED OFF THE MEDIAN, and this is not a detail.
    # A generated illustration is mostly flat background, so the median of a box
    # usually lands in the middle of a long run of ONE value. Cutting there puts
    # that value on both sides, and the two new boxes average to the same colour:
    # #3E5C5E and #3E5C5F end up as separate palette entries while the character
    # gets nothing. Walking the boundary to the next distinct value makes the
    # halves disjoint on this channel, which is what "cut" was supposed to mean.
    $mid = [int]($sorted.Count / 2)
    $v = $sorted[$mid][$bestCh]
    $up = $mid
    while ($up -lt $sorted.Count -and $sorted[$up][$bestCh] -eq $v) { $up++ }
    $dn = $mid
    while ($dn -gt 0 -and $sorted[$dn - 1][$bestCh] -eq $v) { $dn-- }
    # whichever boundary is nearer the median keeps the halves closest to even
    $mid = $up
    if ($dn -ge 1 -and ($mid - [int]($sorted.Count / 2)) -gt ([int]($sorted.Count / 2) - $dn)) { $mid = $dn }
    if ($mid -lt 1 -or $mid -ge $sorted.Count) { break }

    $new = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $boxes.Count; $i++) { if ($i -ne $bi) { [void]$new.Add($boxes[$i]) } }
    [void]$new.Add(@($sorted[0..($mid - 1)]))
    [void]$new.Add(@($sorted[$mid..($sorted.Count - 1)]))
    $boxes = @($new)
  }
  $pal = New-Object System.Collections.ArrayList
  foreach ($b in $boxes) {
    $r = 0; $g = 0; $bl = 0
    foreach ($p in $b) { $r += $p[0]; $g += $p[1]; $bl += $p[2] }
    [void]$pal.Add(@([int][math]::Round($r / $b.Count), [int][math]::Round($g / $b.Count), [int][math]::Round($bl / $b.Count)))
  }
  return @($pal)
}

# ---- run ---------------------------------------------------------------------
Write-Host ('importing ' + $In.Count + ' image(s) -> ' + $outFile)

$imgs = @()
$W = 0; $H = 0
foreach ($src in $In) {
  $img = Get-RkResampled $src $Width $Height
  if ($W -eq 0) { $W = $img.W; $H = $img.H }
  # Every frame must be the same size or the stage refuses the file, and that
  # error would surface far from here.
  if ($img.W -ne $W -or $img.H -ne $H) {
    throw ('frames disagree on size: ' + $src + ' resampled to ' + $img.W + 'x' + $img.H + ', expected ' + $W + 'x' + $H)
  }
  Write-Host ('  ' + (Split-Path -Leaf $src) + '  ' + $img.SrcW + 'x' + $img.SrcH + ' -> ' + $img.W + 'x' + $img.H + '  (' + $Scaling + ')')
  $imgs += $img
}

$key = Get-RkKeyColour $imgs[0]
if ($key) { Write-Host ('  keying out #{0:X2}{1:X2}{2:X2} +/-{3}' -f $key.R, $key.G, $key.B, $Tolerance) }

# ---- MARKER COLOURS ----------------------------------------------------------
# WHY THIS EXISTS. '*' and '+' are the state colour, and nothing in an image can
# say which pixels those are - so the pass was done by hand, in the text, LAST,
# "or keep the edited copy under a different name". That instruction is the
# problem: every correction to the drawing throws the pass away, so the cost is
# not paid once, it is paid on every iteration forever. The person drawing then
# learns to avoid re-importing, which is the opposite of what a drawing tool is for.
#
# Declaring it IN THE PICTURE moves the decision to where it is actually made -
# while looking at the face. Paint the eyes in the marker colour and they ARE the
# readout; re-import as often as you like.
#
# Marker pixels are removed from the histogram, so they cost NO palette entry.
# That matters: a marker is not one of the sprite's colours, it is a label.
function Get-RkMarker([string]$spec, [string]$what) {
  if (-not $spec) { return $null }
  if ($spec -notmatch '^#([0-9A-Fa-f]{6})$') { throw ('-' + $what + ' must be #RRGGBB, got: ' + $spec) }
  $v = [Convert]::ToInt32($Matches[1], 16)
  return @{ R = (($v -shr 16) -band 255); G = (($v -shr 8) -band 255); B = ($v -band 255) }
}
$glowC = Get-RkMarker $Glow 'Glow'
$dimC  = Get-RkMarker $Dim  'Dim'

# A marker has to survive resampling to be found again, and Fant BLENDS - a 1px
# magenta eye beside black comes out muddy and matches nothing. Say so rather
# than marking zero pixels, which looks identical to having forgotten the flag.
if (($glowC -or $dimC) -and $Scaling -ne 'nearest') {
  Write-Host '  NOTE: marker colours are being resampled with fant, which blends them.'
  Write-Host '        Draw at the final pixel size and pass -Scaling nearest for exact markers.'
}
if ($glowC -and $key -and
    [math]::Abs($glowC.R - $key.R) -le $Tolerance -and
    [math]::Abs($glowC.G - $key.G) -le $Tolerance -and
    [math]::Abs($glowC.B - $key.B) -le $Tolerance) {
  throw '-Glow is within -Tolerance of the key colour: every glow pixel would be cut away as background'
}

# Every opaque pixel of every frame goes into one histogram: one palette for the
# whole file, because a .rkspr has exactly one legend.
$opaque = New-Object System.Collections.ArrayList
$masks  = @()
$glows  = @()
$dims   = @()
$nGlow  = 0
$nDim   = 0
foreach ($img in $imgs) {
  $mask = New-Object bool[] ($W * $H)
  $gm   = New-Object bool[] ($W * $H)
  $dm   = New-Object bool[] ($W * $H)
  for ($i = 0; $i -lt ($W * $H); $i++) {
    $o = $i * 4
    $b = $img.Px[$o]; $g = $img.Px[$o + 1]; $r = $img.Px[$o + 2]; $a = $img.Px[$o + 3]
    $clear = ($a -lt 128)
    if (-not $clear -and $key) {
      if ([math]::Abs($r - $key.R) -le $Tolerance -and
          [math]::Abs($g - $key.G) -le $Tolerance -and
          [math]::Abs($b - $key.B) -le $Tolerance) { $clear = $true }
    }
    $mask[$i] = $clear
    if ($clear) { continue }

    # Glow wins when both markers are set and both would match. The two are meant
    # to be far apart; if they are not, that is a mistake, and a mistake should
    # resolve the same way every time instead of by pixel order.
    if ($glowC -and
        [math]::Abs($r - $glowC.R) -le $Tolerance -and
        [math]::Abs($g - $glowC.G) -le $Tolerance -and
        [math]::Abs($b - $glowC.B) -le $Tolerance) { $gm[$i] = $true; $nGlow++; continue }
    if ($dimC -and
        [math]::Abs($r - $dimC.R) -le $Tolerance -and
        [math]::Abs($g - $dimC.G) -le $Tolerance -and
        [math]::Abs($b - $dimC.B) -le $Tolerance) { $dm[$i] = $true; $nDim++; continue }

  }
  $masks += , $mask
  $glows += , $gm
  $dims  += , $dm
}

# ---- -Deedge: peel the halo the per-pixel key could not reach ---------------
# A fringe is a POSITION, not a colour: the ring of pixels touching the ground.
# Colour alone cannot separate it - on the coat picture the halo entries sit 42,
# 51 and 74 from the key while her own warm shadows sit at 96 and 113, so any
# threshold either leaves the rim or eats her cheek. Adding "must touch
# transparency" makes a generous distance safe, because her interior never does.
#
# The canvas edge counts as outside, so a figure running off the frame is peeled
# there too rather than keeping a bright line along the border.
if ($Deedge -gt 0) {
  if (-not $key) { throw '-Deedge needs -Transparent: there is no key colour to measure against' }
  $peeled = 0
  for ($f = 0; $f -lt $imgs.Count; $f++) {
    $img = $imgs[$f]; $mask = $masks[$f]; $gm = $glows[$f]; $dm = $dims[$f]
    for ($pass = 1; $pass -le $DeedgePasses; $pass++) {
      $newly = New-Object System.Collections.ArrayList
      for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
          $i = ($y * $W) + $x
          if ($mask[$i] -or $gm[$i] -or $dm[$i]) { continue }
          $touching = $false
          for ($dy = -1; $dy -le 1 -and -not $touching; $dy++) {
            for ($dx = -1; $dx -le 1; $dx++) {
              if ($dx -eq 0 -and $dy -eq 0) { continue }
              $nx = $x + $dx; $ny = $y + $dy
              if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $W -or $ny -ge $H) { $touching = $true; break }
              if ($mask[($ny * $W) + $nx]) { $touching = $true; break }
            }
          }
          if (-not $touching) { continue }
          $o = $i * 4
          if ([math]::Abs($img.Px[$o + 2] - $key.R) -le $Deedge -and
              [math]::Abs($img.Px[$o + 1] - $key.G) -le $Deedge -and
              [math]::Abs($img.Px[$o]     - $key.B) -le $Deedge) { [void]$newly.Add($i) }
        }
      }
      # Applied after the sweep, not during it: masking as we go would let this
      # pass eat into the next ring in the same iteration, and -DeedgePasses
      # would stop meaning anything.
      foreach ($i in $newly) { $mask[$i] = $true }
      $peeled += $newly.Count
      if ($newly.Count -eq 0) { break }
    }
  }
  Write-Host ('  -Deedge ' + $Deedge + ' x' + $DeedgePasses + ': ' + $peeled + ' halo pixels went transparent')
}

# Now collect what is left. AFTER the edge pass on purpose: halo colours that
# never reach here never spend a palette entry either.
foreach ($f in 0..($imgs.Count - 1)) {
  $img = $imgs[$f]; $mask = $masks[$f]; $gm = $glows[$f]; $dm = $dims[$f]
  for ($i = 0; $i -lt ($W * $H); $i++) {
    if ($mask[$i] -or $gm[$i] -or $dm[$i]) { continue }
    $o = $i * 4
    [void]$opaque.Add(@($img.Px[$o + 2], $img.Px[$o + 1], $img.Px[$o]))
  }
}
if ($glowC -or $dimC) {
  Write-Host ('  markers: ' + $nGlow + ' glow (*), ' + $nDim + ' dim (+) - these cost no palette entry')
  if ($glowC -and $nGlow -eq 0) { Write-Host '  WARNING: -Glow matched NOTHING. Wrong colour, or blended away by resampling.' }
  if ($dimC  -and $nDim  -eq 0) { Write-Host '  WARNING: -Dim matched NOTHING. Wrong colour, or blended away by resampling.' }
}
if ($opaque.Count -eq 0) { throw 'every pixel was keyed out or transparent - nothing to write' }

# MEDIAN CUT RUNS OVER DISTINCT COLOURS, NOT OVER PIXELS, and that choice is the
# difference between a usable palette and a wasted one. Textbook median cut is
# population-weighted, so it hands out palette entries in proportion to AREA: a
# generated illustration whose background is 60% of the pixels takes 60% of the
# palette and comes back with four indistinguishable teals while the face gets
# one colour. Counting each distinct colour once instead allocates by how much
# of colour SPACE the image occupies, so a big flat background costs exactly one
# entry - which is what it is worth in a picture made of flat blocks.
$seen = @{}
$distinct = New-Object System.Collections.ArrayList
foreach ($p in $opaque) {
  $k = ($p[0] -shl 16) -bor ($p[1] -shl 8) -bor $p[2]
  if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$distinct.Add($p) }
}
Write-Host ('  ' + $opaque.Count + ' opaque pixels, ' + $distinct.Count + ' distinct -> median cut to ' + $Colors + ' colours')
$pal = Get-RkPalette $distinct $Colors

# ONE COLOUR IS A SHAPE, NOT A COUNT. PowerShell unwraps a one-element array both
# on return from a function and through a pipeline, so a palette holding a single
# colour @(@(20,20,30)) arrives here as @(20,20,30) - three entries that are
# really one colour's channels. The legend then emits "A = #14 / B = #14 /
# C = #1E" and every pixel points at a colour that does not exist.
#
# This was always here; -Glow is what made it reachable. Markers are removed from
# the histogram, so a two-tone drawing with its eyes marked has exactly one colour
# left, which is the case that breaks. Found by a marker test rather than by
# looking at art: the damage is in the legend, and the picture still "renders".
if ($pal.Count -gt 0 -and $pal[0] -isnot [System.Array]) { $pal = @(, $pal) }

# Legend order is by luminance so the palette block reads dark-to-light and a diff
# of it means something rather than being arbitrary. SORTED BY INDEX, not by piping
# the colours themselves: Sort-Object enumerates, and enumerating a list of arrays
# unwraps it again the moment it holds one item.
$lum = { param($c) (0.299 * $c[0]) + (0.587 * $c[1]) + (0.114 * $c[2]) }
$order = @(0..($pal.Count - 1) | Sort-Object -Property @{ Expression = { & $lum $pal[$_] } })
$sorted = New-Object System.Collections.ArrayList
foreach ($ix in $order) { [void]$sorted.Add($pal[$ix]) }
$pal = $sorted

# NO TWO LEGEND CHARACTERS MAY DIFFER ONLY BY CASE, and this is not style.
# Read-RkSprite keeps the palette in a PowerShell @{} whose keys are STRINGS,
# and PowerShell string hashtables are case-INSENSITIVE: writing 'H' and then
# 'h' leaves one entry, and the second colour wins. The renderer then rebuilds
# that into a [char]-keyed table, and char keys ARE case-sensitive, so every
# pixel drawn with the losing character finds nothing and is dropped as
# transparent (rk-sprite.ps1:38, :133-135, :143-146).
#
# The first version of this file used 'KHhSsCcMW...' - colliding at the third
# character. A 16-colour import came back as 13 real colours, 3 wrong ones, and
# 77% of its pixels missing from the window; the holes were mistaken for a
# successful background cut, because the source's background happened to be
# exactly what disappeared.
#
# 26 uppercase + 10 digits = 36 characters that cannot collide. That is the
# ceiling, enforced on -Colors so it fails in the parameter binder rather than
# after a minute of resampling.
$LEGEND = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
if ($pal.Count -gt $LEGEND.Length) { throw ('too many colours for the legend: ' + $pal.Count) }
$ci = @{}
foreach ($ch in $LEGEND.ToCharArray()) {
  $k = ([string]$ch).ToUpperInvariant()
  if ($ci.ContainsKey($k)) { throw ('LEGEND has a case collision on "' + $ch + '" - see the comment above') }
  $ci[$k] = $true
}

# Nearest-palette lookup cached on the packed colour. After resampling there are
# only a few thousand distinct colours, so this turns an O(pixels * colours)
# scan into one search per distinct colour.
$script:Cache = @{}
function Get-RkIndex([int]$r, [int]$g, [int]$b) {
  $k = ($r -shl 16) -bor ($g -shl 8) -bor $b
  if ($script:Cache.ContainsKey($k)) { return $script:Cache[$k] }
  $best = 0; $bestD = [int]::MaxValue
  for ($i = 0; $i -lt $pal.Count; $i++) {
    $dr = $r - $pal[$i][0]; $dg = $g - $pal[$i][1]; $db = $b - $pal[$i][2]
    $d = ($dr * $dr) + ($dg * $dg) + ($db * $db)
    if ($d -lt $bestD) { $bestD = $d; $best = $i }
  }
  $script:Cache[$k] = $best
  return $best
}

$names = @($FrameNames)
if ($names.Count -eq 0) { for ($i = 0; $i -lt $imgs.Count; $i++) { $names += ('idle.' + $i) } }
if ($names.Count -ne $imgs.Count) { throw ('-FrameNames has ' + $names.Count + ' names for ' + $imgs.Count + ' images') }

$out = New-Object System.Collections.ArrayList
[void]$out.Add('# ' + $Name + '.rkspr - IMPORTED, not hand-drawn. ' + $W + 'x' + $H + ' logical pixels,')
[void]$out.Add('# ' + $pal.Count + ' colours, median cut - deterministic, so re-importing the same')
[void]$out.Add('# source reproduces this file exactly.')
[void]$out.Add('#')
# Relative to stage\ when the source is under it, so the same picture imported
# from a full path and from a relative one writes the same line - the header
# flip-flopped between the two forms depending on who ran the importer and made
# unchanged art show up as a change ([R-094], recorded there).
$stageRoot = ($PSScriptRoot.TrimEnd('\') + '\')
$srcNames = @($In | ForEach-Object {
  $full = [string]$_
  try { $full = [System.IO.Path]::GetFullPath($full) } catch { }
  if ($full.StartsWith($stageRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $full.Substring($stageRoot.Length) }
  else {
    # Outside the stage: keep the provenance but never the Windows user name.
    # C:\Users\<name>\... is on the pre-publication scan list (the mod workspace rules)
    # and this header is committed with the art.
    $home0 = [string]$env:USERPROFILE
    if ($home0 -and $full.StartsWith($home0, [System.StringComparison]::OrdinalIgnoreCase)) { '~' + $full.Substring($home0.Length) } else { $full }
  }
})
[void]$out.Add('# source: ' + ($srcNames -join ', '))
[void]$out.Add('# made by: rk-import-art.ps1 -Width ' + $Width + ' -Colors ' + $Colors + ' -Scaling ' + $Scaling)
[void]$out.Add('#')
if ($glowC -or $dimC) {
  [void]$out.Add('# THE STATUS LIGHT IS ALREADY IN THIS FILE. * (state colour) and + (the same')
  [void]$out.Add('# colour, dimmed) came from marker colours in the source picture, not from a')
  [void]$out.Add('# hand pass, so RE-IMPORTING KEEPS THEM. Move them by repainting the art.')
  if ($glowC) { [void]$out.Add(('#   * <- #{0:X2}{1:X2}{2:X2}   ({3} pixels)' -f $glowC.R, $glowC.G, $glowC.B, $nGlow)) }
  if ($dimC)  { [void]$out.Add(('#   + <- #{0:X2}{1:X2}{2:X2}   ({3} pixels)' -f $dimC.R,  $dimC.G,  $dimC.B,  $nDim))  }
  [void]$out.Add('#')
  [void]$out.Add('# Whatever is marked here IS the readout: accent while the servers are up,')
  [void]$out.Add('# magenta the moment one is not. Nothing else in the window may move or glow.')
} else {
  [void]$out.Add('# TO MAKE PART OF THIS THE STATUS LIGHT: change those characters to *')
  [void]$out.Add('# (the state colour) or + (the same colour, dimmed). Nothing else in this')
  [void]$out.Add('# window is allowed to move or glow, so whatever is marked here IS the')
  [void]$out.Add('# readout: accent while the servers are up, magenta the moment one is not.')
  [void]$out.Add('#')
  [void]$out.Add('# Re-importing OVERWRITES this file and loses those edits - unless you paint')
  [void]$out.Add('# the marks into the art instead and pass -Glow / -Dim, which survives.')
}
[void]$out.Add('')
[void]$out.Add('@palette')
for ($i = 0; $i -lt $pal.Count; $i++) {
  [void]$out.Add(('{0} = #{1:X2}{2:X2}{3:X2}' -f $LEGEND[$i], $pal[$i][0], $pal[$i][1], $pal[$i][2]))
}
for ($f = 0; $f -lt $imgs.Count; $f++) {
  [void]$out.Add('')
  [void]$out.Add('@frame ' + $names[$f])
  $img = $imgs[$f]; $mask = $masks[$f]; $gm = $glows[$f]; $dm = $dims[$f]
  for ($y = 0; $y -lt $H; $y++) {
    $sb = New-Object System.Text.StringBuilder $W
    for ($x = 0; $x -lt $W; $x++) {
      $i = ($y * $W) + $x
      if ($mask[$i]) { [void]$sb.Append('.'); continue }
      if ($gm[$i])   { [void]$sb.Append('*'); continue }
      if ($dm[$i])   { [void]$sb.Append('+'); continue }
      $o = $i * 4
      [void]$sb.Append($LEGEND[(Get-RkIndex $img.Px[$o + 2] $img.Px[$o + 1] $img.Px[$o])])
    }
    [void]$out.Add($sb.ToString())
  }
}

# UTF-8 without a BOM, not ASCII: the pixels and the legend are ASCII either way,
# but the "# source:" line carries a path the operator typed, and turning their
# folder names into question marks loses the only record of where the art came
# from. File.ReadAllLines, which Read-RkSprite uses, reads UTF-8 by default.
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($outFile, $out.ToArray(), $utf8)
Write-Host ('wrote ' + $outFile + '  (' + $W + 'x' + $H + ', ' + $pal.Count + ' colours, ' + $imgs.Count + ' frame(s))')

# ---- optional PNG ------------------------------------------------------------
# Written from the QUANTISED result and not from the resampled bitmap, so the PNG
# and the .rkspr are the same picture. A PNG made straight off the resample would
# show colours the .rkspr does not have, and then "what I saw" and "what the
# window draws" would be two different things.
#
# Frames go side by side, which makes the file a valid stage sprite sheet as well
# ("frame": [w, h] in stage.json) - the same bytes serve looking at it and using
# it. The 1x file is the real picture; the enlarged copy exists because 160x160
# is a thumbnail on a modern screen and every viewer blurs it when you zoom.
if ($Png) {
  $sheetW = $W * $imgs.Count
  $stride = $sheetW * 4
  $buf = New-Object byte[] ($stride * $H)
  for ($f = 0; $f -lt $imgs.Count; $f++) {
    $img = $imgs[$f]; $mask = $masks[$f]; $gm = $glows[$f]; $dm = $dims[$f]; $ox = $f * $W
    for ($y = 0; $y -lt $H; $y++) {
      for ($x = 0; $x -lt $W; $x++) {
        $i = ($y * $W) + $x
        $d = ($y * $stride) + (($ox + $x) * 4)
        if ($mask[$i]) { continue }                    # left at 0,0,0,0 = transparent
        $o = $i * 4
        # A marker pixel keeps the colour it was painted in. What it becomes is
        # decided when the window runs, so anything drawn here would be a guess.
        if     ($gm[$i]) { $c = @($glowC.R, $glowC.G, $glowC.B) }
        elseif ($dm[$i]) { $c = @($dimC.R,  $dimC.G,  $dimC.B)  }
        else { $c = $pal[(Get-RkIndex $img.Px[$o + 2] $img.Px[$o + 1] $img.Px[$o])] }
        $buf[$d]     = [byte]$c[2]                     # Bgra32
        $buf[$d + 1] = [byte]$c[1]
        $buf[$d + 2] = [byte]$c[0]
        $buf[$d + 3] = 255
      }
    }
  }
  $bs = [System.Windows.Media.Imaging.BitmapSource]::Create(
          $sheetW, $H, 96, 96, [System.Windows.Media.PixelFormats]::Bgra32, $null, $buf, $stride)
  $pngFile = Join-Path $OutDir ($Name + '.png')
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  [void]$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bs))
  $fs = [System.IO.File]::Open($pngFile, 'Create'); try { $enc.Save($fs) } finally { $fs.Close() }
  Write-Host ('wrote ' + $pngFile + '  (' + $sheetW + 'x' + $H + ', 1x - this is the real picture)')

  if ($PngScale -gt 1) {
    # NearestNeighbor, integer scale. Anything else re-blurs the pixels that this
    # whole script exists to produce.
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($dv, [System.Windows.Media.BitmapScalingMode]::NearestNeighbor)
    $dc.DrawImage($bs, (New-Object System.Windows.Rect(0, 0, ($sheetW * $PngScale), ($H * $PngScale))))
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
             ($sheetW * $PngScale), ($H * $PngScale), 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $bigFile = Join-Path $OutDir ($Name + '.x' + $PngScale + '.png')
    $enc2 = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    [void]$enc2.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs2 = [System.IO.File]::Open($bigFile, 'Create'); try { $enc2.Save($fs2) } finally { $fs2.Close() }
    Write-Host ('wrote ' + $bigFile + '  (' + ($sheetW * $PngScale) + 'x' + ($H * $PngScale) + ', for looking at)')
  }
}

# DOES IT FIT ON THE STAGE IT IS BEING IMPORTED FOR. The tool cannot refuse -
# a layer may legitimately be larger than the canvas so a background can pan -
# but silence here is what let a 128x187 import lose its bottom 59 rows to
# ClipToBounds with nothing said. Read the stage next door and speak up.
$stageFile = Join-Path $PSScriptRoot 'stage.json'
$stageSize = $null
if (Test-Path -LiteralPath $stageFile) {
  try {
    $sj = (Get-Content -LiteralPath $stageFile -Raw -Encoding UTF8) | ConvertFrom-Json
    if ($sj.size) { $stageSize = @([int]$sj.size[0], [int]$sj.size[1]) }
  } catch { }
}
if ($stageSize -and ($W -gt $stageSize[0] -or $H -gt $stageSize[1])) {
  Write-Host ''
  Write-Host ('  WARNING: this is ' + $W + 'x' + $H + ' but stage.json is ' + $stageSize[0] + 'x' + $stageSize[1] +
              '. The window CLIPS what does not fit, without complaining.')
  Write-Host ('           To get exactly ' + $stageSize[0] + 'x' + $stageSize[1] + ', re-run with:')
  Write-Host ('             -Width ' + $stageSize[0] + ' -Height ' + $stageSize[1] + ' -Fit contain    (whole picture, padded)')
  Write-Host ('             -Width ' + $stageSize[0] + ' -Height ' + $stageSize[1] + ' -Fit cover      (fills it, edges cropped)')
}

# The layer, ready to paste. Every key the schema defaults badly for is written
# out explicitly: rk-stage.ps1 defaults tint to 'state' (so an imported picture
# gets recoloured by the server state unless told not to) and anchor to
# top-left (so a character lands at the origin and covers whatever is behind
# it). Printing only id/source/at/anim was printing the half that cannot go
# wrong.
$fl = ($names | ForEach-Object { '"' + $_ + '"' }) -join ', '
$anchorX = $(if ($stageSize) { [int]($stageSize[0] / 2) } else { [int]($W / 2) })
$anchorY = $(if ($stageSize) { $stageSize[1] } else { $H })
Write-Host ''
Write-Host 'paste into stage.json "layers" - BACKGROUND (covers the canvas, never recoloured):'
Write-Host ''
Write-Host '    {'
Write-Host ('      "id": "' + $Name + '",')
Write-Host ('      "source": "art/' + $Name + '.rkspr",')
Write-Host '      "at": [0, 0],'
Write-Host '      "tint": "none",'
Write-Host ('      "anim": { "idle": { "frames": [' + $fl + '] } }')
Write-Host '    }'
Write-Host ''
Write-Host 'or as a CHARACTER (stands on the floor, one animation per server state):'
Write-Host ''
Write-Host '    {'
Write-Host ('      "id": "' + $Name + '",')
Write-Host ('      "source": "art/' + $Name + '.rkspr",')
Write-Host ('      "at": [' + $anchorX + ', ' + $anchorY + '],')
Write-Host '      "anchor": "bottom-center",'
Write-Host '      "tint": "state",'
Write-Host '      "byState": { "run": "idle", "care": "idle", "halt": "idle", "sleep": "idle" },'
Write-Host ('      "anim": { "idle": { "frames": [' + $fl + '], "hold": [' + (($names | ForEach-Object { '4' }) -join ', ') + '] } }')
Write-Host '    }'
Write-Host ''
Write-Host '  - "at" for a character is a guess from the canvas size; move it until the feet land.'
Write-Host '  - byState maps every state to the same animation until there are more of them.'
Write-Host '  - "tint": "state" only changes * and + pixels. Without a * pass it does nothing.'
Write-Host ''
Write-Host ('then look at it:  powershell -STA -File "' + (Join-Path (Split-Path -Parent $PSScriptRoot) 'render-stage.ps1') + '"')
