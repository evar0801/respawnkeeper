@echo off
REM Double-click this to import the close-up face (console overlay).
REM Same as draw.cmd, but routes to belka-near instead of the default "belka".
REM Save your frames into stage\draw\ named after the frame (idle.0.png ...), 560x376.
REM Paint the status-light pixels in #FF00FF (bright) or #FF80FF (dimmed).
REM ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0rk-draw.ps1" -Name belka-near %*
echo.
pause
