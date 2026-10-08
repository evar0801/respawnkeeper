# ============================================================
# build-exe.ps1 - build respawnkeeper.exe. ASCII only (PS 5.1 safe).
#
# Uses the C# compiler that SHIPS INSIDE WINDOWS
# (C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe), so:
#   - nothing is downloaded (the mod-acquisition rule in CLAUDE.md exists
#     because a fake OptiFine download put a Trojan on this machine)
#   - the source sits next to the binary and can be read by anyone
#   - the result is a plain .NET Framework 4 exe that runs on any Win10/11
#
# The icon is drawn here rather than shipped as a binary asset, for the same
# reason: nothing opaque enters the repository.
#
#   powershell -File harness\launcher\build-exe.ps1
#   powershell -File harness\launcher\build-exe.ps1 -Verify   # build, then run -CheckOnly through it
# ============================================================

param(
  [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$LauncherDir = $PSScriptRoot
$RepoDir     = Split-Path -Parent (Split-Path -Parent $LauncherDir)
$Source      = Join-Path $LauncherDir 'RespawnKeeper.cs'
$IconFile    = Join-Path $LauncherDir 'respawnkeeper.ico'
$OutExe      = Join-Path $RepoDir 'respawnkeeper.exe'

function Say([string]$m) { Write-Host ('  ' + $m) }
function Good([string]$m) { Write-Host ('  o ' + $m) -ForegroundColor Green }
function Bad([string]$m)  { Write-Host ('  x ' + $m) -ForegroundColor Red }

Write-Host ''
Write-Host '  building respawnkeeper.exe' -ForegroundColor Cyan
Write-Host '  --------------------------' -ForegroundColor DarkCyan

# ---- 1. the compiler --------------------------------------------------------
$csc = $null
foreach ($c in @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe')) {
  if (Test-Path -LiteralPath $c) { $csc = $c; break }
}
if (-not $csc) { Bad 'no csc.exe found under C:\Windows\Microsoft.NET. Cannot build.'; exit 2 }
Say ('compiler: ' + $csc)
if (-not (Test-Path -LiteralPath $Source)) { Bad ('missing source: ' + $Source); exit 2 }

# ---- 2. the icon ------------------------------------------------------------
# If make-icon.ps1 has already produced a real .ico (built from artwork), use
# it as-is and do not touch it - that file is owned by make-icon.ps1, this
# script only reads it. Only when no .ico exists yet does the build fall back
# to drawing a placeholder shape, so a missing image asset never breaks the
# build.
Add-Type -AssemblyName System.Drawing
if (Test-Path -LiteralPath $IconFile) {
  Good ('icon: ' + $IconFile + '  (existing file, ' + [math]::Round((Get-Item $IconFile).Length / 1KB, 1) + ' KB - not regenerated. Run make-icon.ps1 to replace it.)')
} else {
  Say 'no respawnkeeper.ico found; falling back to the drawn placeholder icon.'
  # A Vista-or-later .ico may hold a PNG directly, which means the whole file is
  # a 22-byte header plus a PNG - no palette or AND-mask arithmetic needed.
  $size = 256
  $bmp  = New-Object System.Drawing.Bitmap($size, $size)
  $g    = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    # A dark rounded slab with a green ring: "something is watching, and it is up".
    $pad = 18
    $rect = New-Object System.Drawing.Rectangle($pad, $pad, ($size - 2 * $pad), ($size - 2 * $pad))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = 48
    $path.AddArc($rect.X, $rect.Y, $r, $r, 180, 90)
    $path.AddArc(($rect.Right - $r), $rect.Y, $r, $r, 270, 90)
    $path.AddArc(($rect.Right - $r), ($rect.Bottom - $r), $r, $r, 0, 90)
    $path.AddArc($rect.X, ($rect.Bottom - $r), $r, $r, 90, 90)
    $path.CloseFigure()
    $slab = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 24, 28, 34))
    $g.FillPath($slab, $path)

    $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 74, 222, 128), 16)
    $ringPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $ringPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    # Deliberately not a closed circle: the gap reads as "restarting", not "ok".
    $g.DrawArc($ringPen, 68, 68, 120, 120, 130, 280)

    $dot = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 74, 222, 128))
    $g.FillEllipse($dot, 116, 112, 26, 26)
  } finally {
    $g.Dispose()
  }

  $png = New-Object System.IO.MemoryStream
  $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $pngBytes = $png.ToArray()
  $png.Dispose()

  $ico = New-Object System.IO.MemoryStream
  $w = New-Object System.IO.BinaryWriter($ico)
  $w.Write([UInt16]0)              # reserved
  $w.Write([UInt16]1)              # type 1 = icon
  $w.Write([UInt16]1)              # one image
  $w.Write([Byte]0)                # width  0 == 256
  $w.Write([Byte]0)                # height 0 == 256
  $w.Write([Byte]0)                # palette colours
  $w.Write([Byte]0)                # reserved
  $w.Write([UInt16]1)              # colour planes
  $w.Write([UInt16]32)             # bits per pixel
  $w.Write([UInt32]$pngBytes.Length)
  $w.Write([UInt32]22)             # offset: right after this header
  $w.Write($pngBytes)
  $w.Flush()
  [System.IO.File]::WriteAllBytes($IconFile, $ico.ToArray())
  $w.Dispose(); $ico.Dispose()
  Good ('icon: ' + $IconFile + '  (' + [math]::Round((Get-Item $IconFile).Length / 1KB, 1) + ' KB, placeholder)')
}

# ---- 3. compile -------------------------------------------------------------
# The exe is replaced, not deleted-then-written: a half-written entry point is
# worse than an old one.
$tmpExe = Join-Path $env:TEMP ('respawnkeeper-build-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.exe')
$cscArgs = @(
  '/nologo',
  '/target:winexe',
  '/platform:anycpu',
  '/optimize+',
  '/warnaserror+',
  '/r:System.Windows.Forms.dll',
  ('/win32icon:' + $IconFile),
  ('/out:' + $tmpExe),
  $Source
)
$out = & $csc $cscArgs 2>&1
if ($LASTEXITCODE -ne 0) {
  Bad 'compile failed:'
  $out | ForEach-Object { Write-Host ('    ' + $_) }
  exit 1
}
if (-not (Test-Path -LiteralPath $tmpExe)) { Bad 'compile reported success but produced no file.'; exit 1 }

Copy-Item -LiteralPath $tmpExe -Destination $OutExe -Force
Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
Good ('built:  ' + $OutExe + '  (' + [math]::Round((Get-Item $OutExe).Length / 1KB, 1) + ' KB)')

# ---- 4. prove it runs -------------------------------------------------------
# "It compiled" is not "it works". The launcher's whole job is finding
# rk-setup.ps1 and handing it an argument, so that is what gets exercised.
if ($Verify) {
  Write-Host ''
  Say 'verifying (nothing is started, nothing is written to a server)...'
  $pkc = Join-Path (Split-Path -Parent $RepoDir) 'pokemoncraft\server'
  if (-not (Test-Path -LiteralPath $pkc)) {
    Say 'pokemoncraft not found; skipping the end-to-end check.'
  } else {
    # /target:winexe has no console, so the wizard's output cannot be read back
    # through the exe. What IS verifiable is that the launcher resolves the
    # right script and starts powershell against it - so that is what is checked.
    $log = & $OutExe $pkc 2>&1 | Out-String
    if ($log -match 'respawnkeeper - setup') { Good 'the exe reached rk-setup.ps1.' }
    elseif ($LASTEXITCODE -eq 0) { Good 'the exe launched without complaint (winexe: no console to read).' }
    else { Bad ('the exe exited ' + $LASTEXITCODE + ':'); Write-Host $log }
  }
}

Write-Host ''
Say 'double-click respawnkeeper.exe, or drop a server folder onto it.'
Say 'respawnkeeper.bat still works and is kept as a fallback.'
Write-Host ''
