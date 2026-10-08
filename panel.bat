@echo off
rem ============================================================
rem respawnkeeper - the control panel, explicitly.
rem
rem This is now the same thing as double-clicking respawnkeeper.bat or
rem respawnkeeper.exe with no arguments. It is kept because a file named
rem panel.bat is how somebody looks for the panel, but it holds no decision of
rem its own: it asks harness\rk-entry.ps1 for the panel by name ([R-080]).
rem
rem It used to launch rk-panel.ps1 itself with -WindowStyle Hidden, which is a
rem REQUEST that Windows Terminal ignores - so it left an empty "powershell"
rem window next to the panel for as long as the panel was open ([R-077]).
rem That bug existed here AND in the exe because the launch was written twice.
rem It is written once now.
rem ============================================================
title respawnkeeper

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0harness\rk-entry.ps1" -Task panel

if errorlevel 1 pause
