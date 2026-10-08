# ============================================================
# rk-city.ps1 - the skyline behind the panel. ASCII only (PS 5.1 decodes
# BOM-less .ps1 as ANSI).
#
# WHY A CITY. [R-043] said nothing in this window may move, because a readout
# that fights its reader is a costume. The keeper was allowed in as an instance
# of that rule rather than an exception: what animates is the status itself.
# The city is the same bargain taken further - every building, every lit window
# and every beacon is a value that was already on disk and already being
# ignored, so the busier the screen looks, the more of the state is visible.
#
# THE MAPPING - all of it comes from the SAME row objects the cards are built
# from, so the city can never disagree with the text next to it:
#
#   one tower          one supervised server
#   tower height       how long it has been up
#   lit windows        how many mods it is carrying
#   window colour      its state - accent running, danger halted, dim stopped
#   dark tower         stopped, or never supervised
#   rooftop beacon     daily maintenance is armed
#
# The far skyline behind them is NOT data. It is three bands of silhouette to
# give the towers something to stand in front of, and it is drawn dark enough
# to read as depth rather than as content. Saying so here matters: a decoration
# that looks like a reading is worse than no decoration.
#
# DETERMINISM. Every random-looking value comes from a seeded LCG keyed on the
# server label, never from Get-Random. The panel redraws every four seconds
# forever; a skyline that reshuffled on each tick would be the exact flicker
# [R-043] banned, and two renders of the same state would not be comparable.
# ============================================================

$script:CityRandState = 0

function Reset-RkCityRand {
  param([int]$Seed)
  $script:CityRandState = ($Seed -band 0x7FFFFFFF)
  if ($script:CityRandState -eq 0) { $script:CityRandState = 1 }
}

function Get-RkCityNext {
  param([int]$Max)
  if ($Max -le 0) { return 0 }
  $script:CityRandState = [int]((([long]$script:CityRandState * 1103515245) + 12345) -band 0x7FFFFFFF)
  return [int]($script:CityRandState % $Max)
}

function Get-RkCitySeed {
  param([string]$Text)
  $h = 17
  if ($Text) {
    foreach ($c in $Text.ToCharArray()) { $h = (($h * 31) + [int]$c) -band 0x7FFFFFFF }
  }
  return $h
}

function New-RkCityBrush {
  param([string]$Hex)
  return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

function Add-RkCityRect {
  param($Canvas, [double]$X, [double]$Y, [double]$W, [double]$H,
        [string]$Fill, [double]$Opacity = 1.0)
  if ($W -le 0 -or $H -le 0) { return $null }
  $r = New-Object System.Windows.Shapes.Rectangle
  $r.Width = $W
  $r.Height = $H
  $r.Fill = New-RkCityBrush $Fill
  $r.Opacity = $Opacity
  [System.Windows.Controls.Canvas]::SetLeft($r, $X)
  [System.Windows.Controls.Canvas]::SetTop($r, $Y)
  [void]$Canvas.Children.Add($r)
  return $r
}

# ---- the far skyline: depth, not data ---------------------------------------
#
# Bands are placed by their ROOFLINE, not by their height. The cards are opaque
# and cover the middle of the window, so a skyline built from "height above the
# street" puts every interesting edge behind a card and shows nothing - which is
# exactly what the first version did. Anchoring the roofs into a band near the
# top of the window means the part that carries the shape is the part that is
# actually visible, and the bodies just fall away behind the cards.
function Add-RkCitySkyline {
  param($Canvas, [double]$Width, [double]$BaseY)

  $bands = @(
    @{ fill = '#0A1220'; minTop = 168; maxTop = 250; minW = 16; maxW = 34; op = 0.75 },
    @{ fill = '#0D1928'; minTop = 140; maxTop = 224; minW = 22; maxW = 46; op = 0.85 },
    @{ fill = '#101F31'; minTop = 112; maxTop = 200; minW = 30; maxW = 62; op = 1.00 }
  )

  $bandIndex = 0
  foreach ($b in $bands) {
    Reset-RkCityRand (1000 + $bandIndex * 7919)
    $x = -20.0
    while ($x -lt $Width + 20) {
      $w = $b.minW + (Get-RkCityNext ($b.maxW - $b.minW))
      $top = $b.minTop + (Get-RkCityNext ($b.maxTop - $b.minTop))
      [void](Add-RkCityRect -Canvas $Canvas -X $x -Y $top -W $w -H ($BaseY - $top) -Fill $b.fill -Opacity $b.op)
      # A gap of zero every so often makes blocks fuse into wider massing,
      # which is what stops the band looking like a bar chart.
      $x = $x + $w + (Get-RkCityNext 14) - 2
    }
    $bandIndex++
  }
}

# ---- one tower per server: this part IS the data ----------------------------
function Add-RkCityTower {
  param($Canvas, [double]$X, [double]$BaseY, $Row, [string]$Accent, [string]$Danger,
        [string]$Amber, [string]$Dim, [int]$Tick)

  $w = 84.0

  # Uptime moves the ROOF inside a fixed band near the top of the window, it
  # does not scale the tower from the ground. Twelve hours saturates it. This is
  # the only way the reading survives the cards: the roofline stays on screen,
  # so "which of my servers has been up longest" is answerable at a glance even
  # though the lower two thirds of every tower is hidden.
  $mins = 0
  if ($Row.PSObject.Properties['UptimeMinutes'] -and $Row.UptimeMinutes) { $mins = [double]$Row.UptimeMinutes }
  $frac = 0.0
  if ($mins -gt 0) { $frac = [Math]::Min(1.0, $mins / 720.0) }

  $roofLow  = 152.0   # a server that is not running, or has just come up
  $roofHigh = 58.0    # twelve hours and over
  $roofY = $roofLow - (($roofLow - $roofHigh) * $frac)
  if (-not $Row.CanStop) { $roofY = $roofLow + 14.0 }

  # State decides the whole tower's mood in one place, so the city and the card
  # cannot drift apart.
  $lit = $Dim
  $halted = $false
  foreach ($n in @($Row.Notices)) { if ($n.Level -eq 'danger') { $halted = $true } }
  if ($Row.CanStop) { $lit = $Accent }
  if ($halted) { $lit = $Danger }

  [void](Add-RkCityRect -Canvas $Canvas -X $X -Y $roofY -W $w -H ($BaseY - $roofY) -Fill '#0B1626' -Opacity 1.0)
  # A hairline in the state colour along the top edge. This is the single most
  # load-bearing pixel row in the city - on a busy screen it is what tells the
  # towers apart from the silhouettes behind them.
  [void](Add-RkCityRect -Canvas $Canvas -X $X -Y $roofY -W $w -H 2 -Fill $lit -Opacity 0.95)

  # ---- windows = mods ----
  $mods = 0
  if ($Row.PSObject.Properties['ModCount'] -and $Row.ModCount) { $mods = [int]$Row.ModCount }

  $cols = 5
  $cell = 14.0
  $pad = ($w - ($cols * $cell)) / 2.0
  # Only the top of the tower is ever on screen, so only the top is drawn. Eight
  # rows is about 112px, which covers the visible band on every roof height and
  # nothing more - the alternative is a per-pixel loop over five hundred rows of
  # windows that no one can see, four times a second, forever.
  $rowsAvail = 8
  $capacity = $cols * $rowsAvail

  # 240 mods will not fit in a tower, and pretending otherwise would make every
  # modded server look identical. The windows are a proportion of capacity, and
  # the exact number is on the card two inches away.
  $litCount = 0
  if ($mods -gt 0 -and $capacity -gt 0) {
    $litCount = [int][Math]::Round($capacity * [Math]::Min(1.0, $mods / 260.0))
    if ($litCount -lt 1) { $litCount = 1 }
  }
  if ((-not $Row.CanStop) -and (-not $halted)) { $litCount = 0 }

  Reset-RkCityRand (Get-RkCitySeed ([string]$Row.Label))
  $slots = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $capacity; $i++) { [void]$slots.Add($i) }
  # Fisher-Yates with the seeded generator: which windows are lit stays fixed
  # for a given server, so the tower is recognisable between refreshes.
  for ($i = $slots.Count - 1; $i -gt 0; $i--) {
    $j = Get-RkCityNext ($i + 1)
    $tmp = $slots[$i]; $slots[$i] = $slots[$j]; $slots[$j] = $tmp
  }

  $on = @{}
  for ($i = 0; $i -lt $litCount; $i++) { $on[$slots[$i]] = $true }

  for ($i = 0; $i -lt $capacity; $i++) {
    $cx = $X + $pad + (($i % $cols) * $cell)
    $cy = $roofY + 10 + ([int][Math]::Floor($i / $cols) * $cell)
    if ($on.ContainsKey($i)) {
      [void](Add-RkCityRect -Canvas $Canvas -X $cx -Y $cy -W 8 -H 8 -Fill $lit -Opacity 0.85)
    } else {
      [void](Add-RkCityRect -Canvas $Canvas -X $cx -Y $cy -W 8 -H 8 -Fill '#0E1B2B' -Opacity 1.0)
    }
  }

  # ---- rooftop beacon = daily maintenance is armed ----
  $daily = $false
  if ($Row.PSObject.Properties['DailyOn']) { $daily = [bool]$Row.DailyOn }
  if ($daily) {
    # Two ticks lit, two dark. Slow enough to read as a beacon rather than a
    # fault, which is the halt pose's job and must stay distinguishable.
    $bo = 1.0
    if (($Tick % 4) -ge 2) { $bo = 0.25 }
    [void](Add-RkCityRect -Canvas $Canvas -X ($X + ($w / 2) - 1) -Y ($roofY - 12) -W 2 -H 12 -Fill $Amber -Opacity 0.45)
    [void](Add-RkCityRect -Canvas $Canvas -X ($X + ($w / 2) - 3) -Y ($roofY - 18) -W 6 -H 6 -Fill $Amber -Opacity $bo)
  }
}

# ---- rain = the model tier is unreachable -----------------------------------
function Add-RkCityRain {
  param($Canvas, [double]$Width, [double]$Height, [int]$Tick)
  Reset-RkCityRand 4242
  for ($i = 0; $i -lt 90; $i++) {
    $x = Get-RkCityNext ([int]$Width)
    $y = (Get-RkCityNext ([int]$Height)) + ($Tick * 11)
    $y = $y % [int]$Height
    [void](Add-RkCityRect -Canvas $Canvas -X $x -Y $y -W 1 -H 9 -Fill '#2F7CA6' -Opacity 0.30)
  }
}

function Update-RkCity {
  param([Parameter(Mandatory)]$Window, $Rows, [double]$Width, [double]$Height,
        [int]$Tick = 0, [bool]$SignedOut = $false)

  $canvas = $Window.FindName('CityLayer')
  if (-not $canvas) { return $null }
  if (-not (Get-RkThemeFlag $Window 'CityOn')) {
    $canvas.Visibility = 'Collapsed'
    return $null
  }
  $canvas.Visibility = 'Visible'
  $canvas.Children.Clear()

  # The towers stand on a horizon a little above the bottom edge so the ground
  # band reads as street rather than as a cut-off.
  $baseY = $Height - 26

  Add-RkCitySkyline -Canvas $canvas -Width $Width -BaseY $baseY

  $rows = @($Rows)
  if ($rows.Count -gt 0) {
    $span = 118.0
    $total = ($rows.Count * $span) - 34.0
    $startX = ($Width - $total) / 2.0
    if ($startX -lt 20) { $startX = 20 }
    $i = 0
    foreach ($r in $rows) {
      Add-RkCityTower -Canvas $canvas -X ($startX + ($i * $span)) -BaseY $baseY -Row $r -Accent $script:Col.accent -Danger $script:Col.danger -Amber $script:Col.amber -Dim $script:Col.inkSubtle -Tick $Tick
      $i++
    }
  }

  # street
  [void](Add-RkCityRect -Canvas $canvas -X 0 -Y $baseY -W $Width -H 2 -Fill '#1D4260' -Opacity 0.8)

  if ($SignedOut) { Add-RkCityRain -Canvas $canvas -Width $Width -Height $Height -Tick $Tick }

  return [pscustomobject]@{ Towers = $rows.Count; Rain = $SignedOut }
}
