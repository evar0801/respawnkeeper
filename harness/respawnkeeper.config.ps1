# ============================================================
# respawnkeeper - tunable settings
# ASCII only. Dot-sourced by respawnkeeper.ps1 AFTER its built-in defaults, so
# anything set here overrides them. Edit this file for routine tuning; do not
# edit respawnkeeper.ps1.
#
# These settings are HARNESS-WIDE, not per-server. One harness serves fc8 and
# pokemoncraft, so anything you want to differ per server belongs on the
# command line (-AutoRestart / -AutoRepair) or in the shortcut that launches it.
# ============================================================

# 2026-08-27: this file now only holds defaults that apply to EVERY server.
# Per-server policy lives in <ServerDir>\respawnkeeper\profile.json and wins
# over anything here; respawnkeeper.bat (rk-setup.ps1) writes it, and that is
# the file to edit day to day.
#   precedence: command-line switch > profile.json > this file > built-in default

# ---- The two switches that decide how unattended this thing is -------------
# Both default to OFF, and that is a decision, not an oversight.
#
# AutoRestart: starting and stopping a live server is the operator's call
# (the workspace-level CLAUDE.md, "irreversible operations stay with the human").
# Turn it on for a server you have decided may come back up on its own.
$AutoRestartEnabled = $false

# AutoRepair: lets Tier1 apply a reversible repair (quarantine a jar, reset one
# config file, clear a stale world lock) while the server is stopped. The
# measured success rate of unattended repair in this project is 1 in 3
# ([R-007]), which is exactly why this is opt-in and why a repair that does not
# stick HALTs instead of trying again.
$AutoRepairEnabled  = $false

# ---- Crash-loop breaker. NOT optional. -------------------------------------
# "React on crash #1" and "give up after N crashes" are separate settings and
# both are meant to be on. Lowering CrashLoopCount to 1 makes the harness HALT
# on the very first crash without ever restarting - a legitimate, very
# conservative setting. Setting it to 0 or a huge number is how a broken server
# spends the night filling the disk with crash reports.
$CrashLoopCount     = 3    # this many crashes...
$CrashLoopWindowMin = 30   # ...within this many minutes => HALT
$SoakMin            = 20   # uptime that counts as "recovered" and resets the counters

# How many repairs may be applied without a soak in between. 1 means: repair
# once, and if it crashes again, stop and wait for a human.
$MaxRepairAttempts  = 1

# Seconds to wait before a restart attempt.
$RestartBackoffSec  = 10

# Seconds to wait for a clean shutdown after "stop" is sent, before giving up
# on graceful exit. The harness does NOT kill the server when this expires - it
# stands down and says so.
$StopTimeoutSec     = 120

# ---- Tier2 / Tier3 escalation (empty = off) --------------------------------
# Runs only when Tier1's table had no match. The hook is called as:
#   powershell -File <hook> -ServerDir <dir> -DiagnosisFile <json> -ResultFile <txt>
# and must write the verdict as the FIRST LINE of <ResultFile>:
#   FIXED: <what was changed>   |   HALT: <why>   |   SECURITY-HALT: <why>
# It must never start the server. See hooks\escalate-claude.ps1 for the one
# that ships with this harness (a headless model session, still opt-in).
$EscalationHook       = ''
$EscalationTimeoutMin = 45

# escalateOnHalt: what to do when Tier1 DID identify the cause but its table has
# no safe mechanical answer (a missing dependency, two incompatible mods, an
# entity that crashes on every tick).
#   $false - park the server and wait for a human. Correct when somebody is awake.
#   $true  - hand the case to the model instead. It is not limited to the five
#            actions rk-repair implements, so it can look for a config-level or
#            script-level fix that the table has no way to express.
# This is what makes "the model works on it from crash #1" true rather than
# "the model works on it only when Tier1 draws a blank".
$EscalateOnHalt       = $false

# ---- What counts as a crash ------------------------------------------------
# An exit with NO crash report, NO hs_err_pid file, NO exception in the log tail
# and NO logged shutdown sequence is not a crash - it is what killing java from
# Task Manager, closing the window, or the machine sleeping looks like.
#   $false - do not restart it. Refusing costs one manual start.
#   $true  - treat it as a crash anyway.
# Leave this false unless you have a reason: restarting a server somebody was in
# the middle of taking down by hand is the exact accident it prevents.
$RestartAfterUnknownExit = $false

# ---- Hang watch (detect only; it never kills or restarts) ------------------
# A hang does not reach the crash path at all: the process never exits, so
# there is no exit code and no crash report. pokemoncraft additionally sets
# max-tick-time=-1, which disables the vanilla ServerHangWatchdog that fc8
# relied on. This heuristic notices that logs\latest.log has stopped moving and
# writes a line to hangwatch.log. That is all it does: staleness alone is not
# enough evidence to kill a possibly-fine-but-quiet server unattended.
$EnableHangWatch    = $true
$HangStaleMin       = 15
$PollIntervalSec    = 20

# ---- Notifications ----------------------------------------------------------
# A toast is one-way: nothing here reads one back, and every state it announces
# is also in STATUS.txt / state.json / watchdog.log / reports\. So its only job
# is waking a person, and the only state that needs a person is "the server is
# down and staying down".
#   off       - never notify. The HALT notice goes too; you find out in the morning.
#   important - DEFAULT. HALT, a repair that needs a manual start, "already running".
#   all       - the above plus routine progress (maintenance done, crashed-and-handling,
#               stopped from outside).
$EnableToast        = $true
$ToastLevel         = 'important'
$ServerLabel        = ''   # blank = use the ServerDir folder name in the window title
