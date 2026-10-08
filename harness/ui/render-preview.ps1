# ============================================================
# render-preview.ps1 - draw panel.xaml to a PNG without showing a window.
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI; the sample text comes from
# panel-strings.ja.json for that reason - writing it inline here broke the
# parser once already).
#
# WHY THIS EXISTS. A process launched by an agent gets no interactive desktop,
# so Claude cannot see a window it just built [R-033], and screen access was
# declined. That would normally make "design a GUI" impossible to do honestly:
# clipping, overflow, contrast and dark-theme faults are exactly what only shows
# up visually.
#
# WPF does not need a screen to lay out and rasterise. Measure + Arrange +
# RenderTargetBitmap produces the pixels the window would have, off screen. So
# the design can be looked at and corrected rather than guessed at.
#
# It renders SAMPLE rows by default, so every state - running, halted, notices,
# empty - can be inspected without arranging for a server to be in that state.
#
#   powershell -STA -File harness\ui\render-preview.ps1
#   powershell -STA -File harness\ui\render-preview.ps1 -Scenario live
#   powershell -STA -File harness\ui\render-preview.ps1 -Scenario empty
# ============================================================

param(
  [ValidateSet('sample', 'empty', 'live')]
  [string]$Scenario = 'sample',
  [string]$Theme = 'modern',
  [string]$Out = '',
  [int]$Width = 860,
  [int]$Height = 660,
  [int]$Tick = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'panel-model.ps1')

if (-not $Out) { $Out = Join-Path $env:TEMP ('rk-panel-' + $Theme + '-' + $Scenario + '.png') }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$win = New-RkPanelWindow -Theme $Theme

# Take the size from the window the loader actually built, unless the caller
# asked for a specific box. A theme that turns the keeper on makes the window
# wider; a preview pinned to 860 would then render a window nobody will ever
# see, and would report clipping that does not exist (or miss clipping that
# does).
if (-not $PSBoundParameters.ContainsKey('Width'))  { $Width  = [int]$win.Width }
if (-not $PSBoundParameters.ContainsKey('Height')) { $Height = [int]$win.Height }

$ListServers  = $win.FindName('ListServers')
$EmptyState   = $win.FindName('EmptyState')
$TxtFooter    = $win.FindName('TxtFooter')
$BannerGlobal = $win.FindName('BannerGlobal')
$TxtGlobal    = $win.FindName('TxtGlobal')

$rows = New-Object System.Collections.ArrayList

if ($Scenario -eq 'live') {
  foreach ($d in @(Get-RkKnownServers)) {
    try { [void]$rows.Add((Get-RkPanelRow -ServerDir $d)) } catch {}
  }
}
elseif ($Scenario -eq 'sample') {
  # Every state on one screen, including the ugly ones. A preview that only
  # shows the happy path hides exactly the layout that will break: the card
  # with three notices is the one that overflows.
  [void]$rows.Add([pscustomobject]@{
    Label      = T 'sample.labelA'
    StateText  = T 'state.running'
    StateBrush = $script:Col.accent
    DotBrush   = $script:Col.accent
    Uptime     = '2h14m'
    UptimeMinutes = 134
    ModCount   = 167
    DailyOn    = $true
    Meta       = ((@(
                    (T 'meta.policyUnattended'),
                    (TF 'meta.dailyOn' '10:00'),
                    (TF 'meta.loader' 'neoforge 21.1.247' '21'),
                    (TF 'meta.modsGraph' '167' '125')
                  )) -join (T 'meta.separator'))
    Notices    = @(
      (New-RkNotice (TF 'notice.modelNotReady' (T 'sample.signedOutShort')) $script:Col.amber 'care'),
      (New-RkNotice (T 'notice.newReport') $script:Col.accent 'info')
    )
    CanStart = $false; CanStop = $true; CanRestart = $true; Supervised = $true; Busy = ''; HasReport = $true
    ReportLabel = (T 'button.report'); ServerDir = ''; ReportPath = ''
  })
  [void]$rows.Add([pscustomobject]@{
    Label      = T 'sample.labelB'
    StateText  = T 'state.halted'
    StateBrush = $script:Col.danger
    DotBrush   = $script:Col.danger
    Uptime     = ''
    UptimeMinutes = 0
    ModCount   = 247
    DailyOn    = $false
    Meta       = ((@(
                    (T 'meta.policyWatch'),
                    (T 'meta.dailyOff'),
                    (TF 'meta.loader' 'forge 1.20.1-47.4.10' '17'),
                    (TF 'meta.modsGraph' '247' '168')
                  )) -join (T 'meta.separator'))
    Notices    = @(
      (New-RkNotice (T 'notice.halted') $script:Col.danger 'danger'),
      (New-RkNotice (T 'notice.legacyWatchdog') $script:Col.danger 'danger'),
      (New-RkNotice (TF 'notice.comeback' '2') $script:Col.amber 'care')
    )
    CanStart = $true; CanStop = $false; CanRestart = $false; Supervised = $false; Busy = ''; HasReport = $false
    ReportLabel = (T 'button.noReport'); ServerDir = ''; ReportPath = ''
  })
  # A server mid-lap: the badge says what the supervisor is doing, and every
  # button that would ask it for something else is held back.
  [void]$rows.Add([pscustomobject]@{
    Label      = T 'sample.labelD'
    StateText  = T 'busy.stopping'
    StateBrush = $script:Col.amber
    DotBrush   = $script:Col.amber
    Uptime     = '5h02m'
    UptimeMinutes = 302
    ModCount   = 0
    DailyOn    = $false
    Meta       = ((@((T 'meta.policyWatch'), (T 'meta.dailyOff'))) -join (T 'meta.separator'))
    Notices    = @()
    CanStart = $false; CanStop = $false; CanRestart = $false; Supervised = $true; Busy = (T 'busy.stopping'); HasReport = $false
    ReportLabel = (T 'button.noReport'); ServerDir = ''; ReportPath = ''
  })
  [void]$rows.Add([pscustomobject]@{
    Label      = T 'sample.labelC'
    StateText  = T 'state.stopped'
    StateBrush = $script:Col.inkMuted
    DotBrush   = $script:Col.inkSubtle
    Uptime     = ''
    UptimeMinutes = 0
    ModCount   = 0
    DailyOn    = $false
    Meta       = ((@((T 'meta.policyManual'), (T 'meta.dailyOff'))) -join (T 'meta.separator'))
    Notices    = @( (New-RkNotice (T 'notice.verifyStop') $script:Col.amber 'care') )
    CanStart = $true; CanStop = $false; CanRestart = $false; Supervised = $false; Busy = ''; HasReport = $false
    ReportLabel = (T 'button.noReport'); ServerDir = ''; ReportPath = ''
  })
}

$ListServers.ItemsSource = $rows
if ($rows.Count -eq 0) { $EmptyState.Visibility = 'Visible' } else { $EmptyState.Visibility = 'Collapsed' }
$TxtGlobal.Text = T 'global.signedOut'
# -Scenario live must render what is actually true. Forcing the banner on there
# was a preview telling a lie about the machine it was running on - which is the
# one thing a preview must never do. sample/empty stay forced so the banner's
# own layout can be inspected on demand.
if ($Scenario -eq 'live') {
  $BannerGlobal.Visibility = $(if (Get-RkSignedOut) { 'Visible' } else { 'Collapsed' })
} else {
  $BannerGlobal.Visibility = $(if ($Scenario -eq 'empty') { 'Collapsed' } else { 'Visible' })
}
$TxtFooter.Text = TF 'footer.counted' $rows.Count (Get-Date -Format 'HH:mm:ss')
# The theme button is labelled by rk-panel.ps1 at runtime; without this the
# preview renders an empty box where a button will be, which is a preview
# showing something the user will never see.
$btnTheme = $win.FindName('BtnTheme')
if ($btnTheme) { $btnTheme.Content = Get-RkThemeLabel (Get-RkNextTheme $Theme) }

# The keeper is posed from the SAME rows the cards were built from, through the
# same function the live window calls. -Tick picks which frame of her loop gets
# rasterised, so a pose can be inspected without waiting for the window to reach
# it - the sample scenario carries a halted server, so this is where the alarm
# pose gets looked at.
$keeper = Update-RkKeeper -Window $win -Rows $rows -Tick $Tick
if ($keeper) { Write-Host ('keeper: ' + $keeper.Pose + '  ' + $keeper.Brush) }

# The city is drawn from the SAME rows, at the size the window will actually
# open at, and it takes its rain from whether the banner is up - so the preview
# cannot show a calm sky over a signed-out machine.
$signedOut = ($BannerGlobal.Visibility -eq 'Visible')
$city = Update-RkCity -Window $win -Rows $rows -Width $Width -Height $Height -Tick $Tick -SignedOut $signedOut
if ($city) { Write-Host ('city: ' + $city.Towers + ' towers, rain=' + $city.Rain) }

# ---- rasterise --------------------------------------------------------------
# A Window that was never shown has no size, so it is measured and arranged by
# hand at the size it would open at. Content that overflows THIS box is content
# that would overflow the real window.
#
# Do NOT set $root.Width/$root.Height here. The root Grid carries
# Margin="32,28,32,24", and in WPF a margin sits OUTSIDE an explicit Width - so
# pinning Width to the bitmap width pushes the content 32px past the right edge
# and 24px past the bottom. The first render did exactly that and clipped the
# state badges and the whole footer. Measure/Arrange against the box and let the
# layout system subtract the margin itself.
$size = New-Object System.Windows.Size($Width, $Height)
$root = $win.Content
$win.Content = $null                 # detach: a Window cannot be a rendered visual
$root.Measure($size)
$root.Arrange((New-Object System.Windows.Rect(0, 0, $Width, $Height)))
$root.UpdateLayout()

$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)

# RenderTargetBitmap paints only the visual it is given, never the Window's own
# Background. Without this the PNG is transparent where the canvas should be,
# which would read as "the dark theme is broken" when it is not.
$dv = New-Object System.Windows.Media.DrawingVisual
$dc = $dv.RenderOpen()
# The ground must come from the THEME, not a constant: hardcoding #121212 made
# the pixel theme render on the modern theme's background, which is the kind of
# error a preview exists to prevent rather than commit.
$bgBrush = $win.TryFindResource('Canvas')
$bg = $(if ($bgBrush) { $bgBrush } else { New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#121212')) })
$dc.DrawRectangle($bg, $null, (New-Object System.Windows.Rect(0, 0, $Width, $Height)))
$dc.Close()
$rtb.Render($dv)
$rtb.Render($root)

$enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$fs = [System.IO.File]::Open($Out, 'Create')
try { $enc.Save($fs) } finally { $fs.Close() }

Write-Host ('rendered ' + $Theme + '/' + $Scenario + ' -> ' + $Out + '  (' + [math]::Round((Get-Item $Out).Length / 1KB, 1) + ' KB, ' + $Width + 'x' + $Height + ')')
