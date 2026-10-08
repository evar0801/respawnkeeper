@echo off
rem ============================================================
rem respawnkeeper - double-click this, or drop a server folder on it.
rem
rem   double-click            -> the control panel (every server you have set up)
rem   drop a server folder    -> set that folder up
rem
rem IDENTICAL to respawnkeeper.exe. Both are shells over harness\rk-entry.ps1,
rem which is the only file that decides what a double-click means ([R-080]).
rem Before 2026-09-13 this file opened the WIZARD while the exe opened the
rem PANEL - same name, different behaviour, and the rule written twice in two
rem languages. Do not put a decision back in here.
rem
rem Use the .exe when you can (it has an icon and can be pinned). This file is
rem for when the exe will not run - SmartScreen, or a policy against unsigned
rem binaries.
rem
rem Nothing is started and nothing outside the chosen server folder is written.
rem ============================================================
title respawnkeeper

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0harness\rk-entry.ps1" %*

if errorlevel 1 pause
