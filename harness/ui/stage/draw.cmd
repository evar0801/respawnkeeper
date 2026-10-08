@echo off
REM Double-click this after saving frames into stage\draw\ .
REM One PNG per frame, named after the frame: run.0.png, run.1.png, care.0.png ...
REM Paint the status-light pixels in #FF00FF (bright) or #FF80FF (dimmed).
REM ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0rk-draw.ps1" %*
echo.
pause
