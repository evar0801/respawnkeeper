@echo off
REM Double-click this after saving the BEDROOM BACKDROP into stage\draw-bg\ .
REM One PNG per frame, named after the frame. The rail only needs lit.0.png
REM (296x600) - the dimmed lit.1 is generated from it automatically.
REM
REM Paint the status-light pixels in #FF00FF (bright) or #FF80FF (dimmed).
REM Those two colours cost no palette entry and SURVIVE re-importing; every
REM other pixel is yours and keeps its own colour.
REM
REM This replaces the generated backdrop: while draw-bg\lit.0.png exists,
REM build-belka.ps1 uses it and does not run the sign painter.
REM ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0rk-draw.ps1" -Name rail-bg -From "%~dp0draw-bg" -Colors 36 -PngScale 2 %*
echo.
pause
