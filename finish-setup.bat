@echo off
rem ============================================================
rem respawnkeeper - finish setup.  DOUBLE-CLICK THIS. Nothing to decide.
rem
rem Runs the two steps an agent is not allowed to take:
rem   1. sign the claude CLI in     (a credential - only a person enters one)
rem   2. disarm the fc8 heartbeat   (needs one UAC approval)
rem
rem Starts no server. Safe to run twice - each step skips itself if done.
rem The logic lives in harness\rk-finish-setup.ps1; this file only launches it.
rem ============================================================
title respawnkeeper - finish setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0harness\rk-finish-setup.ps1"
echo.
pause
