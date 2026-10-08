@echo off
rem ============================================================
rem respawnkeeper - disarm the fc8 legacy heartbeat.  DOUBLE-CLICK THIS.
rem
rem WHY. fc8 still has its own supervisor armed: the scheduled task
rem FC8WatchdogHeartbeat fires every 2 minutes and relaunches
rem fc8_watchdog.bat. Two supervisors on one server is not a style
rem problem - the old one would start the server underneath a running
rem respawnkeeper, which breaks "a server you stopped by hand stays
rem stopped". respawnkeeper therefore REFUSES to run on fc8 while this
rem task is armed. See DECISIONS.md [R-027].
rem
rem WHY A SEPARATE FILE. The task lives in the root of the Task Scheduler
rem library, which Windows protects with administrator ACLs even for the
rem user who owns the task. Disabling it needs one UAC approval, and only
rem a person can give that.
rem
rem IT IS DISABLED, NOT DELETED. Undo with one line:
rem   powershell -Command "Enable-ScheduledTask -TaskName 'FC8WatchdogHeartbeat'"
rem ============================================================
title respawnkeeper - disarm the fc8 legacy heartbeat

net session >nul 2>&1
if %errorlevel%==0 goto elevated

echo.
echo  This needs administrator rights (the task sits in the protected
echo  root folder of the Task Scheduler library).
echo  Windows will ask you to approve. Nothing else is changed.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:elevated
echo.
echo  === before ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = Get-ScheduledTask -TaskName 'FC8WatchdogHeartbeat' -ErrorAction SilentlyContinue; if ($t) { '   FC8WatchdogHeartbeat : ' + $t.State } else { '   FC8WatchdogHeartbeat : not installed - nothing to do'; exit 0 }"
echo.
echo  === disabling ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Disable-ScheduledTask -TaskName 'FC8WatchdogHeartbeat' -ErrorAction Stop | Out-Null; '   ok' } catch { '   FAILED: ' + $_.Exception.Message }"
echo.
echo  === after ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ScheduledTask | Where-Object { $_.TaskName -match 'FC8|Palworld' } | ForEach-Object { '   {0,-24} {1}' -f $_.TaskName, $_.State }"
echo.
echo  PalworldWatchdog is left alone on purpose: respawnkeeper cannot yet
echo  stop Palworld safely, so replacing a working keeper with one that
echo  cannot stop the server would be a step backwards [R-027].
echo.
echo  To undo:
echo    powershell -Command "Enable-ScheduledTask -TaskName 'FC8WatchdogHeartbeat'"
echo.
pause
