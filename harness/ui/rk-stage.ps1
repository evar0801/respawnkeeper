# ============================================================
# rk-stage.ps1 - a stage: background layers and characters, driven by a
# manifest, not by code. ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS. The keeper was drawn as a text pixel map because there was no
# art yet. There will be art. The point of this file is that adding it - a
# background, a second character, a longer walk cycle - must not require editing
# any .ps1. A layer is an entry in stage.json; a frame is a cell in a PNG.
#
# WHAT A STAGE IS
#   size    the logical pixel canvas everything is positioned in (before zoom)
#   scale   integer nearest-neighbour zoom. 1 logical px -> N screen px
#   layers  painted back to front, exactly in the order written
#
# A LAYER
#   { "id", "source", "at":[x,y], "anchor", "anim":{...}, "byState":{...} }
#
#   source ending .rkspr   text pixel map. Recolourable: '*' becomes the state
#                          colour, which is how a sprite can BE a status light.
#   source ending .png     sprite sheet. Needs "frame":[w,h]; cells are counted
#                          left to right, top to bottom. Carries its own
#                          colours - a PNG cannot be recoloured, so a state that
#                          must look different needs its own frames.
#
#   anim    { "<name>": { "frames":[...], "hold":[...] } }
#           frames are .rkspr frame names OR sheet cell numbers.
#           hold is how many ticks each frame stays up (same length as frames,
#           or omitted for 1 each). TIMING LIVES HERE. It used to be a hashtable
#           in panel-model.ps1, which meant changing a blink rate was a
#           PowerShell edit.
#
#   byState maps a server state (run/care/halt/sleep) to an anim name. A layer
#           without byState just plays "idle" forever - which is what a
#           background is.
#
#   at/anchor  position in logical pixels. anchor says what "at" refers to on
#           the sprite: top-left (default), bottom-center, center.
#
# WHAT IT DELIBERATELY DOES NOT DO. No easing, no tweening, no physics, no
# per-layer clocks. One integer tick drives everything, frames are held for
# whole ticks, and positions are whole logical pixels. Sub-pixel motion is what
# makes pixel art stop looking like pixel art.
# ============================================================

. (Join-Path $PSScriptRoot 'rk-sprite.ps1')

function Read-RkStage {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { throw ('no such stage: ' + $Path) }
  $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $dir  = Split-Path -Parent $Path

  $scale = 1
  if ($json.scale) { $scale = [int]$json.scale }
  $w = 240; $h = 160
  if ($json.size) { $w = [int]$json.size[0]; $h = [int]$json.size[1] }

  $layers = New-Object System.Collections.ArrayList
  foreach ($L in @($json.layers)) {
    $src = Join-Path $dir ([string]$L.source)
    if (-not (Test-Path -LiteralPath $src)) { throw ('layer ' + $L.id + ' points at a file that is not there: ' + $src) }

    $kind = 'rkspr'
    $sprite = $null; $sheet = $null
    if ([System.IO.Path]::GetExtension($src).ToLower() -eq '.png') {
      $kind = 'sheet'
      if (-not $L.frame) { throw ('layer ' + $L.id + ' is a .png sheet and needs "frame": [w, h]') }
      $sheet = Read-RkSheet -Path $src -FrameW ([int]$L.frame[0]) -FrameH ([int]$L.frame[1])
    } else {
      $sprite = Read-RkSprite -Path $src
    }

    # Animations are validated HERE, at load, against the art that is actually
    # present. The alternative is discovering a renamed frame at the moment the
    # server goes down - in a window whose whole job is to be trustworthy then.
    $anims = @{}
    $moves = @{}
    foreach ($p in @($L.anim.PSObject.Properties)) {
      $frames = @($p.Value.frames)
      if ($frames.Count -eq 0) { throw ('layer ' + $L.id + ' animation ' + $p.Name + ' has no frames') }
      $hold = @()
      if ($p.Value.hold) { $hold = @($p.Value.hold | ForEach-Object { [int]$_ }) }
      if ($hold.Count -eq 0) { $hold = @(1) * $frames.Count }
      if ($hold.Count -ne $frames.Count) {
        throw ('layer ' + $L.id + ' animation ' + $p.Name + ' has ' + $frames.Count + ' frames but ' + $hold.Count + ' hold values')
      }
      foreach ($f in $frames) {
        if ($kind -eq 'sheet') {
          $c = [int]$f
          if ($c -lt 0 -or $c -ge $sheet.Count) { throw ('layer ' + $L.id + ' animation ' + $p.Name + ' wants cell ' + $c + ', sheet has 0..' + ($sheet.Count - 1)) }
        } else {
          if (-not $sprite.Frames.Contains([string]$f)) { throw ('layer ' + $L.id + ' animation ' + $p.Name + ' wants frame ' + $f + ', which is not in ' + (Split-Path -Leaf $src)) }
        }
      }
      # ---- move: the part travels instead of being redrawn ----------------
      # Eva, 2026-09-14: "making the texture in parts and moving them is easier,
      # isn't it? Terraria-ish movement would probably feel right. Actually
      # animating it does not seem realistic."
      #
      # She is right, and until now the engine could not do it: 'at' was fixed
      # per layer and was not in the timeline, so an arm that swings had to be
      # DRAWN four times. 'move' is one [dx,dy] per FRAME, in stage units, added
      # to the layer's position for that tick. So a part can be drawn ONCE and
      # the motion is numbers.
      #
      # It is deliberately a translation and not a rotation: this stage draws
      # whole pixels at an integer zoom, and rotating a sprite resamples it -
      # the dot grid shimmers and the art stops being pixel art. Sliding by
      # whole stage units keeps every dot on the grid.
      $move = @()
      if ($p.Value.PSObject.Properties.Name -contains 'move') {
        $move = @($p.Value.move)
        if ($move.Count -ne $frames.Count) {
          throw ('layer ' + $L.id + ' animation ' + $p.Name + ' has ' + $frames.Count + ' frames but ' + $move.Count + ' move values')
        }
      }

      # Flattened once into tick -> frame, instead of walking hold counters
      # every tick in three different callers.
      $timeline = New-Object System.Collections.ArrayList
      $movetl   = New-Object System.Collections.ArrayList
      for ($i = 0; $i -lt $frames.Count; $i++) {
        $d = @(0, 0)
        if ($move.Count -gt 0) {
          $mi = @($move[$i])
          if ($mi.Count -lt 2) { throw ('layer ' + $L.id + ' animation ' + $p.Name + ' move[' + $i + '] must be [dx, dy]') }
          $d = @([int]$mi[0], [int]$mi[1])
        }
        for ($k = 0; $k -lt $hold[$i]; $k++) {
          [void]$timeline.Add($frames[$i])
          [void]$movetl.Add($d)
        }
      }
      $anims[$p.Name] = @($timeline)
      $moves[$p.Name] = @($movetl)
    }
    if ($anims.Count -eq 0) { throw ('layer ' + $L.id + ' has no animations (give it at least "idle")') }

    # A missing byState is normal - a background has no states. It has to be
    # tested for explicitly: $null.PSObject.Properties does not come back empty,
    # it comes back with one nameless entry, so the loop below ran once for
    # every background and threw about an animation called "".
    $byState = @{}
    $stateMap = $null
    if ($L.PSObject.Properties.Name -contains 'byState') { $stateMap = $L.byState }
    foreach ($p in @($stateMap.PSObject.Properties | Where-Object { $_ -and $_.Name })) {
      if (-not $anims.ContainsKey([string]$p.Value)) { throw ('layer ' + $L.id + ' maps state ' + $p.Name + ' to animation ' + $p.Value + ', which it does not have') }
      $byState[$p.Name] = [string]$p.Value
    }

    $at = @(0, 0)
    if ($L.at) { $at = @([int]$L.at[0], [int]$L.at[1]) }

    # A layer may draw at its own zoom. Default is the stage's, which is what
    # every layer did before this existed, so nothing that omits it changes.
    # The point is the eye: at the stage's 2x an iris is a handful of pixels and
    # nothing can happen inside it. The same strip of screen at 1x holds four
    # times the dots. "at" is untouched by this - it is in stage units either
    # way, so a layer keeps its place on the stage when its zoom changes.
    $lscale = $scale
    if ($L.PSObject.Properties.Name -contains 'scale') { $lscale = [int]$L.scale }
    if ($lscale -lt 1) { throw ('layer ' + $L.id + ' has scale ' + $lscale + '; it must be 1 or more') }

    # A nudge in whole PIXELS, applied after everything else. "at" is in stage
    # units, so on a 2x stage it can only land on even pixels - and a layer that
    # has to line up with something inside a sprite drawn at 2x will sometimes
    # need an odd one. bottom-center subtracts [int](width / 2), which makes the
    # parity of every offset inside that sprite depend on its width.
    $atpx = @(0, 0)
    if ($L.atPx) { $atpx = @([int]$L.atPx[0], [int]$L.atPx[1]) }

    [void]$layers.Add([pscustomobject]@{
      Id = [string]$L.id; Kind = $kind; Sprite = $sprite; Sheet = $sheet
      Anims = $anims; Moves = $moves; ByState = $byState
      At = $at; Anchor = $(if ($L.anchor) { [string]$L.anchor } else { 'top-left' })
      Tint = $(if ($L.tint) { [string]$L.tint } else { 'state' })
      Scale = $lscale
      AtPx = $atpx
      Image = $null
    })
  }

  return [pscustomobject]@{
    Path = $Path; Width = $w; Height = $h; Scale = $scale
    Layers = @($layers); Cache = @{}
  }
}

function Get-RkStageCacheDir {
  # stage\.cache, beside the manifest. Rasterised frames as PNG, one file per
  # (layer, frame, scale, signal colour, sprite bytes). Safe to delete at any
  # time; nothing in it is authored.
  param([Parameter(Mandatory)]$Stage)
  return (Join-Path (Split-Path -Parent $Stage.Path) '.cache')
}

# Bumped whenever New-RkSpriteImage / ConvertTo-RkColor change what a pixel
# comes out as (DimAlpha, the '.' rule, the scaling loop). The sprite hash in
# the file name covers the ART; this covers the RENDERER. Without it a change
# to either would keep serving yesterday's PNGs (review of [R-095]).
$script:RkRasterVersion = 'r1'

function Get-RkStageFramePath {
  # The cache file for one (layer, frame, scale, signal). '' when the sprite
  # has no hash (nothing to key on). Layer id and frame are both sanitised
  # and joined with a separator that neither can contain, so two different
  # pairs cannot share a name.
  param([Parameter(Mandatory)]$Stage, [Parameter(Mandatory)]$Layer, [Parameter(Mandatory)][string]$Frame, [Parameter(Mandatory)][string]$Signal)
  if (-not $Layer.Sprite.Hash) { return '' }
  $safeId    = ([string]$Layer.Id) -replace '[^A-Za-z0-9_.-]', '_'
  $safeFrame = $Frame -replace '[^A-Za-z0-9_.-]', '_'
  $hex = ($Signal -replace '[^0-9A-Fa-f]', '').ToUpper()
  if ($hex.Length -eq 6) { $hex = 'FF' + $hex }   # #RRGGBB and #FFRRGGBB are the same pixels: one file
  return (Join-Path (Get-RkStageCacheDir -Stage $Stage) (
    $safeId + '~' + $safeFrame + '~x' + $Layer.Scale + '~' + $hex + '~' + $Layer.Sprite.Hash + '~' + $script:RkRasterVersion + '.png'))
}

function Get-RkStageFrameImage {
  param([Parameter(Mandatory)]$Stage, [Parameter(Mandatory)]$Layer, [Parameter(Mandatory)]$Frame, [string]$Signal)

  # Rasterising a text map is a per-pixel loop in PowerShell and the window
  # redraws several times a second forever. Keyed by everything that can change
  # the pixels.
  #
  # THREE TIERS, because the second one is what the window actually feels.
  # Measured 2026-09-13 on the dispatcher thread:
  #
  #   memory hit                                              ~0 ms
  #   PNG from stage\.cache (decode + Freeze)                  1 - 35 ms
  #   rasterise 296x600 at 1x (the panel's rail backdrop)       439 ms
  #   rasterise 1120x752 at 2x (the console's room)            1051 ms
  #
  # Every rasterise happened ON THE UI THREAD the first time a frame was shown
  # in a given state colour - so the first pulse of the sign (lit.1), and every
  # change of server state (a new signal colour), froze the window for half a
  # second in the panel and a full second in the console. Eva's "still freezes
  # a little". The memory cache only ever helped the SECOND showing.
  #
  # The PNG on disk survives the process, so the freeze is paid once per
  # (frame, colour, sprite bytes) on this machine, ever - and
  # Initialize-RkStageCache pays it in a background runspace before the UI
  # thread asks. The sprite's own hash is in the file name, so a re-import or a
  # hand edit simply misses and rasterises again; nothing stale can be shown.
  $key = $Layer.Id + '|' + $Frame + '|' + $Signal
  if ($Stage.Cache.ContainsKey($key)) { return $Stage.Cache[$key] }

  $img = $null
  if ($Layer.Kind -eq 'sheet') {
    $img = New-RkSheetImage -Sheet $Layer.Sheet -Cell ([int]$Frame) -Scale $Layer.Scale
    $Stage.Cache[$key] = $img
    return $img
  }

  $sig = $Signal
  if ($Layer.Tint -ne 'state' -or (-not $sig)) { $sig = '#FFFFFFFF' }

  $file = Get-RkStageFramePath -Stage $Stage -Layer $Layer -Frame ([string]$Frame) -Signal $sig
  if ($file) {
    if (Test-Path -LiteralPath $file) {
      try {
        $fs = [System.IO.File]::Open($file, 'Open', 'Read', 'Read')
        try {
          $dec = New-Object System.Windows.Media.Imaging.PngBitmapDecoder(
            $fs, [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
          $img = $dec.Frames[0]
        } finally { $fs.Close() }
        if ($img -and ($img.PixelWidth -eq ($Layer.Sprite.Width * $Layer.Scale)) -and
            ($img.PixelHeight -eq ($Layer.Sprite.Height * $Layer.Scale))) {
          $img.Freeze()
          $Stage.Cache[$key] = $img
          return $img
        }
        $img = $null    # wrong size = not this sprite; rasterise and overwrite
      } catch { $img = $null }
    }
  }

  $img = New-RkSpriteImage -Sprite $Layer.Sprite -Frame ([string]$Frame) -Scale $Layer.Scale -Signal $sig
  $Stage.Cache[$key] = $img

  if ($file) {
    # Written beside, then moved into place: a reader that opens a half-written
    # PNG gets a decoder error, which the branch above treats as a miss - but
    # not paying that round trip at all is better.
    try {
      $dir = Split-Path -Parent $file
      if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
      # pid AND a random part: the background warm-up and the UI thread live in
      # ONE process and can miss the same key at the same moment.
      $tmp = $file + '.tmp-' + $PID + '-' + ([System.IO.Path]::GetRandomFileName().Replace('.', ''))
      $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
      $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($img))
      $out = [System.IO.File]::Open($tmp, 'Create')
      try { $enc.Save($out) } finally { $out.Close() }
      # !! File.Replace needs a REAL backup name under PowerShell 5.1: $null
      # becomes "" and Replace throws "not of a legal form", so the overwrite
      # branch (a wrong-size or damaged PNG) never overwrote and that frame
      # was rasterised on every call, forever (review of [R-095]).
      if (Test-Path -LiteralPath $file) {
        $bak = $tmp + '.prev'
        [System.IO.File]::Replace($tmp, $file, $bak)
        try { if (Test-Path -LiteralPath $bak) { [System.IO.File]::Delete($bak) } } catch { }
      } else {
        [System.IO.File]::Move($tmp, $file)
      }
    } catch {
      try { if ($tmp -and (Test-Path -LiteralPath $tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
    }
  }
  return $img
}

function Initialize-RkStageCache {
  # Rasterise EVERY frame this stage can show, in every state colour it can be
  # shown in, into stage\.cache - so the UI thread only ever decodes. Meant to
  # run in a background runspace right after the window is up (it needs
  # PresentationCore loaded, nothing else; frozen bitmaps do not care which
  # thread made them). Returns how many files it MADE: a frame whose PNG is
  # already on disk is not even decoded (the first version decoded all 67 of
  # the console's frames on every run - 239 ms and 77 MB - and counted them as
  # "made"; review of [R-095]). Nothing decoded here is kept: the bitmaps are
  # for the window's own cache, not this runspace's.
  #
  # PRUNES what no sprite can use any more: files for a layer whose hash is
  # not the current one, or whose renderer version is not the current one.
  # These are regenerable pixels this same function wrote, never anything a
  # person made - the one class of file this project deletes rather than
  # quarantines ([R-095]).
  #
  # $Signals: the four state colours from the theme (accent / amber / danger /
  # idle). A layer that is not tinted by state is rendered once, white.
  param([Parameter(Mandatory)]$Stage, [string[]]$Signals = @())
  $made = 0
  $sigs = @($Signals | Where-Object { $_ })
  if ($sigs.Count -eq 0) { $sigs = @('#FFFFFFFF') }
  $dir = Get-RkStageCacheDir -Stage $Stage
  foreach ($L in $Stage.Layers) {
    if ($L.Kind -ne 'rkspr') { continue }
    if (-not $L.Sprite.Hash) { continue }
    $safeId = ([string]$L.Id) -replace '[^A-Za-z0-9_.-]', '_'
    if (Test-Path -LiteralPath $dir) {
      # Files from the first naming scheme (no '~' in the name) are never
      # read again; they go too.
      foreach ($legacy in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.png' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*~*' })) {
        try { [System.IO.File]::Delete($legacy.FullName) } catch { }
      }
      foreach ($old in @(Get-ChildItem -LiteralPath $dir -File -Filter ($safeId + '~*.png') -ErrorAction SilentlyContinue)) {
        if ($old.Name -notmatch ('~' + [regex]::Escape($L.Sprite.Hash) + '~' + [regex]::Escape($script:RkRasterVersion) + '\.png$')) {
          try { [System.IO.File]::Delete($old.FullName) } catch { }
        }
      }
    }
    $frames = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($L.Anims.Keys)) {
      foreach ($f in @($L.Anims[$a])) { if (-not $frames.Contains([string]$f)) { [void]$frames.Add([string]$f) } }
    }
    $want = $sigs
    if ($L.Tint -ne 'state') { $want = @('#FFFFFFFF') }
    foreach ($f in $frames) {
      foreach ($sg in $want) {
        $sig = $sg
        if ($L.Tint -ne 'state' -or (-not $sig)) { $sig = '#FFFFFFFF' }
        $path = Get-RkStageFramePath -Stage $Stage -Layer $L -Frame $f -Signal $sig
        if ($path -and (Test-Path -LiteralPath $path)) { continue }
        $key = $L.Id + '|' + $f + '|' + $sg
        try { [void](Get-RkStageFrameImage -Stage $Stage -Layer $L -Frame $f -Signal $sg); $made++ } catch { }
        [void]$Stage.Cache.Remove($key)
      }
    }
  }
  return $made
}

function New-RkStageVisual {
  param([Parameter(Mandatory)]$Stage, [Parameter(Mandatory)]$Canvas)

  $Canvas.Width  = $Stage.Width  * $Stage.Scale
  $Canvas.Height = $Stage.Height * $Stage.Scale
  $Canvas.Children.Clear()

  foreach ($L in $Stage.Layers) {
    $img = New-Object System.Windows.Controls.Image
    $img.Stretch = [System.Windows.Media.Stretch]::None
    $img.SnapsToDevicePixels = $true
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::NearestNeighbor)
    [System.Windows.Media.RenderOptions]::SetEdgeMode($img, [System.Windows.Media.EdgeMode]::Aliased)
    [void]$Canvas.Children.Add($img)
    $L.Image = $img
  }
  return $Canvas
}

function Update-RkStage {
  param(
    [Parameter(Mandatory)]$Stage,
    [int]$Tick = 0,
    [string]$State = 'idle',
    [string]$Signal = '#FFFFFFFF'
  )

  foreach ($L in $Stage.Layers) {
    if (-not $L.Image) { continue }

    $animName = 'idle'
    if ($L.ByState.ContainsKey($State)) { $animName = $L.ByState[$State] }
    elseif (-not $L.Anims.ContainsKey('idle')) { $animName = @($L.Anims.Keys)[0] }
    $timeline = $L.Anims[$animName]
    if (-not $timeline) { continue }

    $frame = $timeline[$Tick % $timeline.Count]
    $img = Get-RkStageFrameImage -Stage $Stage -Layer $L -Frame $frame -Signal $Signal
    $L.Image.Source = $img
    $L.Image.Width  = $img.PixelWidth
    $L.Image.Height = $img.PixelHeight

    # Anchors are resolved every tick because a frame may be a different size
    # from the one before it (a sheet can hold a wide frame next to a narrow
    # one). Anchoring by the sprite's own box keeps her feet on the floor
    # instead of keeping her top-left corner in the same place.
    $x = $L.At[0] * $Stage.Scale
    $y = $L.At[1] * $Stage.Scale
    switch ($L.Anchor) {
      'bottom-center' { $x -= [int]($img.PixelWidth / 2); $y -= $img.PixelHeight }
      'center'        { $x -= [int]($img.PixelWidth / 2); $y -= [int]($img.PixelHeight / 2) }
    }
    if ($L.AtPx) { $x += $L.AtPx[0]; $y += $L.AtPx[1] }
    # The per-frame travel, in stage units so it scales with the stage and
    # always lands on a whole dot. Applied last, on top of the anchor, so a
    # frame that is a different size still hangs off the same point first and
    # then slides.
    if ($L.Moves -and $L.Moves.ContainsKey($animName)) {
      $mtl = $L.Moves[$animName]
      if ($mtl.Count -gt 0) {
        $d = $mtl[$Tick % $mtl.Count]
        $x += $d[0] * $Stage.Scale
        $y += $d[1] * $Stage.Scale
      }
    }
    [System.Windows.Controls.Canvas]::SetLeft($L.Image, $x)
    [System.Windows.Controls.Canvas]::SetTop($L.Image, $y)
  }
}
