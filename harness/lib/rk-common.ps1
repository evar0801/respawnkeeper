# ============================================================
# respawnkeeper - shared helpers (dot-sourced; defines functions only)
# ASCII only (PS 5.1 decodes BOM-less .ps1 as ANSI; non-ASCII breaks the parser).
#
# Dot-source with:  . (Join-Path $PSScriptRoot 'lib\rk-common.ps1')
# Nothing in here writes to the server. Read-only + state-dir writes only.
# ============================================================

# ---- ServerDir validation ---------------------------------------------------

function Resolve-RkServerDir {
  # Fails loudly rather than watching an empty folder forever: a wrong
  # -ServerDir is otherwise indistinguishable from "the server never crashes"
  # ([R-003] - this actually happened during the move to respawnkeeper\).
  #
  # 2026-08-27: the guard used to be "does it have libraries\", which is a
  # Minecraft-only question and would have rejected every other game. It is now
  # "does ANY game template recognise this folder", which is the same guard
  # generalised - the Minecraft answer is just one template among several.
  # Pass -AnyFolder for the utility scripts, where the caller has already
  # decided what it is pointing at.
  param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$AnyFolder,
    # Same test seam as respawnkeeper.ps1 -GamesDir, and it has to be here too:
    # this function decides "is this folder a server at all" BEFORE the caller
    # gets a chance to say where templates live. Without it the supervisor
    # refused the fixture folder and exited before its own -GamesDir was ever
    # read - which is how the first run of L5 failed ([R-084] follow-up).
    [string]$GamesDir = ''
  )
  $p = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
  if (-not $p) { throw "ServerDir does not exist: $Path" }
  $full = $p.Path
  if ($AnyFolder) { return $full }
  $g = $null
  try { $g = Find-RkGame -ServerDir $full -Templates (Get-RkGameTemplates -GamesDir $GamesDir) } catch {}
  if (-not $g) {
    throw ("no game template recognises this folder, so respawnkeeper does not know how to run or read it: " + $full + "`r`n" +
           "  Run rk-setup.ps1 on it - it can generate a template for an unknown game (rk-newgame.ps1).")
  }
  return $full
}

function Get-RkStateDir {
  # State lives NEXT TO THE SERVER it describes, never next to the harness:
  # one harness serves several servers, so a shared log would interleave fc8
  # and pokemoncraft and make STATUS.txt mean "whichever wrote last" ([R-003]).
  param([Parameter(Mandatory)][string]$ServerDir)
  $d = Join-Path $ServerDir 'respawnkeeper'
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}

# ---- server.properties ------------------------------------------------------

function Get-RkServerProperty {
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory)][string]$Key,
    [string]$Default = ''
  )
  $f = Join-Path $ServerDir 'server.properties'
  if (-not (Test-Path $f)) { return $Default }
  foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
    if ($line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*?)\s*$')) {
      $v = $Matches[1]
      if ($v -ne '') { return $v }
      return $Default
    }
  }
  return $Default
}

function Get-RkServerPort {
  # Returns 0 when the port cannot be determined. 0 means "do not use the port
  # as evidence" - which is the honest answer for games whose port lives inside
  # a launch script rather than a settings file, and is much better than
  # defaulting to 25565 and then watching the WRONG port.
  #
  # Two sources, in this order:
  #   1. paths.settingsFile - the port the server will actually read at startup.
  #      Always preferred: it is the live value, so an operator editing it is
  #      followed without anybody touching the template.
  #   2. process.port - an integer written into the template itself. This exists
  #      for games with NO settings file at all (Valheim keeps its port in the
  #      launch script next to the password, which respawnkeeper deliberately
  #      never parses). It is a declared constant, so it loses to (1) whenever
  #      (1) can answer.
  # Anything else is 0, and 0 is NOT a default - it is the refusal to guess.
  # The 25565 branch below is a separate thing: it is the pre-template-layer
  # behaviour, kept so a -Template-less call behaves exactly as it did before.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    $Template = $null
  )
  if (-not $Template) {
    $v = Get-RkServerProperty -ServerDir $ServerDir -Key 'server-port' -Default '25565'
    $n = 25565
    if ([int]::TryParse($v, [ref]$n)) { return $n }
    return 25565
  }
  $settings = ''
  try { $settings = [string]$Template.paths.settingsFile } catch { $settings = '' }
  if ($settings) {
    $f = Join-Path $ServerDir $settings
    if (Test-Path -LiteralPath $f) {
      # server.properties (=), Terraria serverconfig.txt (=), PalWorldSettings.ini (=)
      foreach ($key in @('server-port', 'port', 'PublicPort', 'RESTAPIPort')) {
        try {
          $m = Select-String -LiteralPath $f -Pattern ('(?m)^\s*' + [regex]::Escape($key) + '\s*=\s*(\d+)') -ErrorAction SilentlyContinue |
            Select-Object -First 1
          if ($m -and $m.Matches.Count -gt 0) { return [int]$m.Matches[0].Groups[1].Value }
        } catch {}
      }
    }
  }
  $literal = 0
  try { if ($Template.process.port) { $literal = [int]$Template.process.port } } catch { $literal = 0 }
  if ($literal -gt 0 -and $literal -le 65535) { return $literal }
  return 0
}

function Get-RkPortProtocol {
  # 'tcp' or 'udp'. Absent/unrecognised -> 'tcp', which is what every template
  # written before this field existed meant.
  param($Template = $null)
  $p = ''
  if ($Template) { try { $p = [string]$Template.process.portProtocol } catch { $p = '' } }
  if ($p -and $p.Trim().ToLower() -eq 'udp') { return 'udp' }
  return 'tcp'
}

function Initialize-RkNetTable {
  # One P/Invoke pair, compiled once per process. GetExtendedTcpTable /
  # GetExtendedUdpTable are what Get-NetTCPConnection and Get-NetUDPEndpoint
  # call underneath - through CIM, which is where the time goes. Measured
  # 2026-09-13 on this machine, one port, one running server:
  #
  #   Get-NetTCPConnection -LocalPort 25565        298 - 1495 ms
  #   Add-Type for the two calls below (once)      172 ms
  #   [RkNet.Table]::TcpListeners(25565)           17 ms cold, 1 ms after
  #
  # The panel asks this for every server on every four-second refresh, the
  # console asked it on its UI thread every two seconds, and the supervisor
  # asks it on every pass. Same answer, three hundred times cheaper.
  #
  # $false when the type cannot be compiled (no C# compiler, a locked-down
  # host): every caller then falls back to the cmdlets, which is exactly the
  # code that ran before this existed.
  if ($null -ne $script:RkNetTableReady) { return $script:RkNetTableReady }
  $script:RkNetTableReady = $false
  try {
    if (-not ('RkNet.Table' -as [type])) {
      Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace RkNet {
  public static class Table {
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool sort, int ipVersion, int tblClass, uint reserved);
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedUdpTable(IntPtr pUdpTable, ref int dwOutBufLen, bool sort, int ipVersion, int tblClass, uint reserved);
    // dwLocalPort holds the port in network byte order in its low 16 bits.
    static int HostPort(uint lp) { return (int)(((lp & 0xFF) << 8) | ((lp >> 8) & 0xFF)); }
    // TCP_TABLE_OWNER_PID_LISTENER = 3. AF_INET = 2, AF_INET6 = 23.
    // MIB_TCPROW_OWNER_PID  (24 bytes): state, localAddr, localPort@8, remoteAddr, remotePort, pid@20
    // MIB_TCP6ROW_OWNER_PID (56 bytes): localAddr[16], localScope, localPort@20, remoteAddr[16], remoteScope, remotePort, state, pid@52
    // null = "could not read the table" (the caller falls back to the cmdlets).
    // An error must never come back as an empty list: an empty list means
    // "nothing holds this port", and that is the answer that opens the gate in
    // front of a running server. ERROR_INSUFFICIENT_BUFFER on the second call
    // (the table grew between the size query and the read) is retried.
    public static List<int> TcpListeners(int port) {
      var found = new List<int>();
      foreach (int ver in new int[] { 2, 23 }) {
        bool got = false;
        for (int attempt = 0; attempt < 4 && !got; attempt++) {
          int len = 0;
          uint rc0 = GetExtendedTcpTable(IntPtr.Zero, ref len, false, ver, 3, 0);
          if (rc0 != 122 || len <= 0) { if (rc0 == 0 && len == 0) { got = true; break; } return null; }
          IntPtr buf = Marshal.AllocHGlobal(len);
          try {
            uint rc = GetExtendedTcpTable(buf, ref len, false, ver, 3, 0);
            if (rc == 122) continue;
            if (rc != 0) return null;
            got = true;
            int n = Marshal.ReadInt32(buf);
          long p = buf.ToInt64() + 4;
          int rowSize = (ver == 2) ? 24 : 56;
          int portAt  = (ver == 2) ? 8  : 20;
          int pidAt   = (ver == 2) ? 20 : 52;
          for (int i = 0; i < n; i++) {
            IntPtr rp = new IntPtr(p + (long)i * rowSize);
            if (HostPort((uint)Marshal.ReadInt32(rp, portAt)) != port) continue;
            int pid = Marshal.ReadInt32(rp, pidAt);
            if (!found.Contains(pid)) found.Add(pid);
          }
          } finally { Marshal.FreeHGlobal(buf); }
        }
        if (!got) return null;
      }
      return found;
    }
    // UDP_TABLE_OWNER_PID = 1.
    // MIB_UDPROW_OWNER_PID  (12 bytes): localAddr, localPort@4, pid@8
    // MIB_UDP6ROW_OWNER_PID (28 bytes): localAddr[16], scope, localPort@20, pid@24
    public static List<int> UdpBinders(int port) {
      var found = new List<int>();
      foreach (int ver in new int[] { 2, 23 }) {
        bool got = false;
        for (int attempt = 0; attempt < 4 && !got; attempt++) {
          int len = 0;
          uint rc0 = GetExtendedUdpTable(IntPtr.Zero, ref len, false, ver, 1, 0);
          if (rc0 != 122 || len <= 0) { if (rc0 == 0 && len == 0) { got = true; break; } return null; }
          IntPtr buf = Marshal.AllocHGlobal(len);
          try {
            uint rc = GetExtendedUdpTable(buf, ref len, false, ver, 1, 0);
            if (rc == 122) continue;
            if (rc != 0) return null;
            got = true;
            int n = Marshal.ReadInt32(buf);
          long p = buf.ToInt64() + 4;
          int rowSize = (ver == 2) ? 12 : 28;
          int portAt  = (ver == 2) ? 4  : 20;
          int pidAt   = (ver == 2) ? 8  : 24;
          for (int i = 0; i < n; i++) {
            IntPtr rp = new IntPtr(p + (long)i * rowSize);
            if (HostPort((uint)Marshal.ReadInt32(rp, portAt)) != port) continue;
            int pid = Marshal.ReadInt32(rp, pidAt);
            if (!found.Contains(pid)) found.Add(pid);
          }
          } finally { Marshal.FreeHGlobal(buf); }
        }
        if (!got) return null;
      }
      return found;
    }
  }
}
'@
    }
    $script:RkNetTableReady = $true
  } catch { $script:RkNetTableReady = $false }
  return $script:RkNetTableReady
}

function Get-RkPortHolders {
  # "Is anything holding this port, and which process?" for BOTH protocols.
  # Returns @{ bound = [bool]; pids = @(int) }.
  #
  # UDP IS NOT TCP-WITH-A-DIFFERENT-CMDLET. There is no Listen state on a UDP
  # socket - it is connectionless, so the socket is simply bound or it is not,
  # and Get-NetUDPEndpoint has no -State parameter to filter on. Asking the TCP
  # question of a UDP game therefore does not return "not listening", it returns
  # nothing at all, forever. That is exactly how a probe stops being a probe
  # while still looking like one (Valheim talks over UDP 2456/2457).
  #
  # PS 5.1 TRAP, actually hit by this harness before: (Get-NetTCPConnection ...).Count
  # is an EMPTY STRING when exactly one object comes back, because a scalar has
  # no .Count. It compares equal to nothing useful and the caller concludes
  # "port free" while a server is running on it. Everything here is forced into
  # an array with @() BEFORE .Count is read.
  #
  # THE TABLE IS READ DIRECTLY (Initialize-RkNetTable) and the cmdlets are the
  # fallback, not the other way round: the cmdlets cost 300-1500 ms per call
  # and this is asked several times a second across the windows and the
  # supervisor. Both paths answer the same question of the same kernel table.
  param(
    [Parameter(Mandatory)][int]$Port,
    [string]$Protocol = 'tcp'
  )
  $res = @{ bound = $false; pids = @() }
  if ($Port -le 0 -or $Port -gt 65535) { return $res }

  if (Initialize-RkNetTable) {
    # $null from the table reader means "could not read", never "nothing
    # there" - so it is tested BEFORE the @() wrap (PowerShell turns @($null)
    # into a one-element array, which would have read as "bound by pid 0").
    $raw = $null
    try {
      if ($Protocol -eq 'udp') { $raw = [RkNet.Table]::UdpBinders($Port) }
      else                     { $raw = [RkNet.Table]::TcpListeners($Port) }
    } catch { $raw = $null }
    if ($null -ne $raw) {
      $ids = @($raw)
      if ($ids.Count -eq 0) { return $res }
      $res.bound = $true
      foreach ($op in $ids) { if ([int]$op -gt 0 -and ($res.pids -notcontains [int]$op)) { $res.pids += [int]$op } }
      return $res
    }
  }

  $rows = @()
  if ($Protocol -eq 'udp') {
    try { $rows = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction Stop) } catch { $rows = @() }
  } else {
    try { $rows = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) } catch { $rows = @() }
  }
  if ($rows.Count -eq 0) { return $res }
  $res.bound = $true
  foreach ($r in $rows) {
    $op = 0
    try { $op = [int]$r.OwningProcess } catch { $op = 0 }
    if ($op -gt 0 -and ($res.pids -notcontains $op)) { $res.pids += $op }
  }
  return $res
}

# ---- Where the evidence actually lives (template-driven, never hardcoded) ----

function Get-RkLogFilePatterns {
  # The absolute path pattern(s) this game's readable output lands in. Returned
  # as PATTERNS rather than resolved files because several games name the file
  # per launch (Valheim's own launcher writes logs\everheim_<stamp>.log), so
  # anything that resolves once at supervisor start would pin a file that does
  # not exist yet and never look again.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    $Template = $null
  )
  if (-not $Template) {
    # Pre-template-layer behaviour, kept deliberately: Minecraft.
    return @((Join-Path $ServerDir 'logs\latest.log'))
  }
  $rel = ''
  try { $rel = [string]$Template.paths.logFile } catch { $rel = '' }
  if ($rel) { return @((Join-Path $ServerDir $rel)) }
  $cap = $false
  try { $cap = [bool]$Template.capture.stdout } catch { $cap = $false }
  if ($cap) {
    # The console respawnkeeper captures itself - see Invoke-ServerRun, which
    # writes <ServerDir>\respawnkeeper\console\console-<stamp>.log, one per run.
    # Built by hand rather than via Get-RkStateDir because a resolver must not
    # create directories as a side effect of being asked a question.
    return @((Join-Path (Join-Path (Join-Path $ServerDir 'respawnkeeper') 'console') 'console-*.log'))
  }
  # No log file and no capture: this game has no readable stream. Saying so is
  # the point - the caller must switch its feature off rather than watch a path
  # that will never exist.
  return @()
}

function Get-RkLogFile {
  # The ONE file to read right now, or $null.
  #
  # Contract, and every clause of it is load-bearing:
  #   - a pattern containing * or ? resolves to the NEWEST match by LastWriteTime
  #   - no match -> $null
  #   - a path that does not exist is NEVER returned. Returning one would let the
  #     caller believe there is a log, and "Test-Path said no so I skipped it"
  #     silently is the failure this whole change exists to remove.
  #   - $Template $null -> logs\latest.log, Minecraft-compatible, still only if
  #     it exists.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    $Template = $null
  )
  $best = $null
  foreach ($pat in (Get-RkLogFilePatterns -ServerDir $ServerDir -Template $Template)) {
    if (-not $pat) { continue }
    if ($pat -match '[\*\?]') {
      foreach ($f in @(Get-ChildItem -Path $pat -File -ErrorAction SilentlyContinue)) {
        if ((-not $best) -or ($f.LastWriteTime -gt $best.LastWriteTime)) { $best = $f }
      }
      continue
    }
    if (Test-Path -LiteralPath $pat -PathType Leaf) {
      $f = Get-Item -LiteralPath $pat -ErrorAction SilentlyContinue
      if ($f -and ((-not $best) -or ($f.LastWriteTime -gt $best.LastWriteTime))) { $best = $f }
    }
  }
  if ($best) { return $best.FullName }
  return $null
}

function Get-RkCrashDirs {
  # Crash-artifact directories that EXIST, absolute. Zero is a legitimate answer:
  # most games leave no crash report at all, and the caller must degrade rather
  # than read an empty folder as "no crashes".
  # Wrap the call in @() - PowerShell unrolls a one-element return.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    $Template = $null
  )
  $rels = @('crash-reports')
  if ($Template) {
    $rels = @()
    try { $rels = @($Template.paths.crashDirs | Where-Object { $_ }) } catch { $rels = @() }
  }
  $out = New-Object System.Collections.ArrayList
  foreach ($r in $rels) {
    $rel = [string]$r
    if (-not $rel) { continue }
    $p = Join-Path $ServerDir $rel
    if ($rel -match '[\*\?]') {
      foreach ($d in @(Get-ChildItem -Path $p -Directory -ErrorAction SilentlyContinue)) {
        if (-not $out.Contains($d.FullName)) { [void]$out.Add($d.FullName) }
      }
      continue
    }
    if (Test-Path -LiteralPath $p -PathType Container) {
      $full = $p
      try { $full = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch {}
      if (-not $out.Contains($full)) { [void]$out.Add($full) }
    }
  }
  return @($out.ToArray())
}

function Get-RkLevelName {
  param([Parameter(Mandatory)][string]$ServerDir)
  return (Get-RkServerProperty -ServerDir $ServerDir -Key 'level-name' -Default 'world')
}

# ---- Loader / Java resolution (Forge 1.20.1 AND NeoForge 1.21.1) ------------

function Get-RkLoader {
  # Returns @{ kind; version; winArgsRel; javaMajor } or $null.
  # Both loaders ship libraries\<group>\<artifact>\<version>\win_args.txt; only
  # the group path and the version-string shape differ:
  #   NeoForge 1.21.1 : net\neoforged\neoforge\21.1.247\        -> Java 21
  #   Forge    1.20.1 : net\minecraftforge\forge\1.20.1-47.4.10\-> Java 17
  # The Java major is derived from the MINECRAFT version, not the loader: fc8's
  # own run.bat pins Java 17 explicitly and warns that a bare "java" picking up
  # Java 21 from PATH makes 1.20.1 Forge unstable.
  param([Parameter(Mandatory)][string]$ServerDir)

  $candidates = @(
    @{ kind = 'neoforge'; root = 'libraries\net\neoforged\neoforge';   rel = 'libraries/net/neoforged/neoforge' },
    @{ kind = 'forge';    root = 'libraries\net\minecraftforge\forge'; rel = 'libraries/net/minecraftforge/forge' }
  )

  foreach ($c in $candidates) {
    $root = Join-Path $ServerDir $c.root
    if (-not (Test-Path $root)) { continue }

    # Newest version wins. [version] cannot parse "1.20.1-47.4.10", so sort on
    # the loader part after the last '-' when there is one.
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName 'win_args.txt') })
    if ($dirs.Count -eq 0) { continue }

    $best = $dirs | Sort-Object {
      $n = $_.Name
      if ($n -match '-') { $n = $n.Substring($n.LastIndexOf('-') + 1) }
      try { [version]$n } catch { [version]'0.0.0' }
    } | Select-Object -Last 1

    # Minecraft version: from the folder name for Forge (1.20.1-47.4.10), and
    # from the loader major for NeoForge (21.1.247 -> 1.21.1).
    $mcVersion = ''
    if ($best.Name -match '^(?<mc>\d+\.\d+(\.\d+)?)-') { $mcVersion = $Matches['mc'] }
    elseif ($best.Name -match '^(?<maj>\d+)\.(?<min>\d+)\.') { $mcVersion = '1.' + $Matches['maj'] + '.' + $Matches['min'] }

    # Java major comes from the MINECRAFT version. The boundary inside 1.20 is
    # real: 1.20.1 runs on Java 17 (fc8's run.bat pins it and warns that a bare
    # "java" resolving to 21 makes it unstable), while 1.20.5+ requires 21.
    $javaMajor = 21
    if ($mcVersion -match '^1\.(?<m>\d+)(\.(?<p>\d+))?') {
      $m = [int]$Matches['m']
      $p = 0
      if ($Matches['p']) { $p = [int]$Matches['p'] }
      if ($m -le 16) { $javaMajor = 8 }
      elseif ($m -le 19) { $javaMajor = 17 }
      elseif ($m -eq 20) { if ($p -le 4) { $javaMajor = 17 } else { $javaMajor = 21 } }
      else { $javaMajor = 21 }
    }

    return @{
      kind       = $c.kind
      version    = $best.Name
      mcVersion  = $mcVersion
      winArgsRel = ($c.rel + '/' + $best.Name + '/win_args.txt')
      javaMajor  = $javaMajor
    }
  }
  return $null
}

function Get-RkJavaMajor {
  # Verifies by EXECUTING java -version, never by trusting the folder name.
  # "Check the result, not the value you set" - a JAVA_HOME can point anywhere.
  param([Parameter(Mandatory)][string]$JavaExe)
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $JavaExe
    $psi.Arguments = '-version'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEnd()
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.WaitForExit(15000)
    $text = $err + $out
    if ($text -match 'version "(?<v>[0-9._]+)"') {
      $v = $Matches['v']
      if ($v -match '^1\.(?<m>\d+)') { return [int]$Matches['m'] }   # 1.8.0_xxx
      if ($v -match '^(?<m>\d+)')    { return [int]$Matches['m'] }   # 17.0.x / 21.0.x
    }
  } catch {}
  return 0
}

function Resolve-RkJava {
  # Finds a java.exe whose ACTUAL major version matches $Major.
  # Search order: JAVA_HOME, Adoptium install dirs, PATH. PATH is last on
  # purpose - it is the one most likely to hold the wrong major.
  param([Parameter(Mandatory)][int]$Major)

  $cands = New-Object System.Collections.ArrayList
  if ($env:JAVA_HOME) { [void]$cands.Add((Join-Path $env:JAVA_HOME 'bin\java.exe')) }
  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $base) { continue }
    foreach ($vendorDir in @('Eclipse Adoptium', 'Java', 'Microsoft', 'Amazon Corretto', 'Zulu')) {
      $vroot = Join-Path $base $vendorDir
      if (-not (Test-Path $vroot)) { continue }
      foreach ($d in (Get-ChildItem -LiteralPath $vroot -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $d.FullName 'bin\java.exe'
        if (Test-Path $exe) { [void]$cands.Add($exe) }
      }
    }
  }
  $onPath = Get-Command java -ErrorAction SilentlyContinue
  if ($onPath) { [void]$cands.Add($onPath.Source) }

  $seen = @{}
  foreach ($c in $cands) {
    if (-not (Test-Path $c)) { continue }
    if ($seen.ContainsKey($c.ToLower())) { continue }
    $seen[$c.ToLower()] = $true
    if ((Get-RkJavaMajor -JavaExe $c) -eq $Major) { return $c }
  }
  return $null
}

# ---- Process attribution: WHICH server does this pid belong to? -------------
# Added 2026-09-12 ([R-072] stage 4). Until now every probe asked "is something
# of this shape running ANYWHERE ON THE MACHINE", which is a different question
# from "is THIS server running" and gives the same answer only when exactly one
# server exists. fc8 and pokemoncraft are BOTH on server-port=25565 (measured),
# so they were never told apart: one of them running made the other one look
# alive too.
#
# The strong test is the executable path. For most games the server binary lives
# inside the server folder (Valheim, Palworld, Terraria, tModLoader, Core
# Keeper), so Win32_Process.ExecutablePath decides ownership outright. Minecraft
# is the exception - java.exe is a shared JDK somewhere else entirely - and for
# it the loader path + version on the command line remains the only handle,
# exactly as before.
#
# DIRECTION OF ERROR, and it is the whole design: a wrong "owned" costs nothing
# (the gate refuses a write it did not have to refuse); a wrong "foreign" opens
# the gate in front of a RUNNING server. So 'foreign' is returned ONLY on
# positive evidence that the process belongs somewhere else, and everything
# uncertain lands in 'unknown', which callers must keep treating as alive.

function Test-RkPathUnder {
  # Is $Path inside $Root (or equal to it)? Both are normalised first, so
  # trailing slashes and ..\ segments cannot produce a false negative.
  param([string]$Path, [string]$Root)
  if ((-not $Path) -or (-not $Root)) { return $false }
  $p = ''
  $r = ''
  try { $p = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
  try { $r = [System.IO.Path]::GetFullPath($Root) } catch { return $false }
  $p = $p.TrimEnd('\', '/')
  $r = $r.TrimEnd('\', '/')
  if ($p.ToLower() -eq $r.ToLower()) { return $true }
  return $p.ToLower().StartsWith(($r + '\').ToLower())
}

# ---- What a process is (name, exe, command line), remembered ---------------
#
# WHY THERE IS A CACHE. Win32_Process through CIM costs 278-574 ms per pid on
# this machine (measured 2026-09-13, several times), and it was being asked for
# the SAME pid by every probe of every server on every refresh - the port
# holder, the pid-file process and the loader-signature scan all ask "what is
# pid 38204", and the two Minecraft servers share port 25565 so they ask about
# the same one. One panel refresh paid it four to six times; the console window
# paid it on its UI thread every two seconds.
#
# WHY IT IS SAFE TO REMEMBER. A process's name, executable and command line
# never change while it lives. The key is pid PLUS start time, so a recycled
# pid is a different key - the case a pid-only cache would get wrong. When the
# start time cannot be read (another user's process across an elevation
# boundary) nothing is remembered and the question is asked every time; being
# right matters more than being quick there.
#
# WHY IT IS ON DISK TOO. Every window is its own process, and the panel reads
# in a second runspace with its own module state, so an in-memory cache is cold
# four times over. A file next to the harness (harness\.cache\procfacts.json)
# is read on the first miss in each process; entries are keyed the same way,
# so a stale file can only cost a lookup, never a wrong answer. Written
# atomically; the last writer wins; losing an entry means one more CIM query.

$script:RkProcFacts      = @{}     # 'pid@startTicks' -> @{ name; exePath; commandLine; cmdKnown }
$script:RkProcFactsLoaded = $false

function Get-RkCacheDir {
  # harness\.cache - beside the code, not in a server folder, because the
  # answers are about this MACHINE, not about any one server.
  if ($script:RkCacheDir) { return $script:RkCacheDir }
  return (Join-Path (Split-Path -Parent $PSScriptRoot) '.cache')
}

function Get-RkProcFactsFile { return (Join-Path (Get-RkCacheDir) 'procfacts.json') }

function Import-RkProcFacts {
  # Merge the on-disk cache into memory. Never throws; a missing or damaged file
  # is simply an empty one.
  $f = Get-RkProcFactsFile
  $j = Read-RkJson -Path $f
  if (-not ($j -and $j.entries)) { return }
  foreach ($p in $j.entries.PSObject.Properties) {
    $e = $p.Value
    if ($script:RkProcFacts.ContainsKey($p.Name)) {
      # Keep whichever knows more: an entry another process completed (command
      # line read, exe path read) must not be shadowed by this process's
      # partial one.
      $have = $script:RkProcFacts[$p.Name]
      $better = ((-not $have.cmdKnown) -and ($e.cmdKnown -eq $true)) -or ((-not $have.exePath) -and [string]$e.exePath)
      if (-not $better) { continue }
    }
    $script:RkProcFacts[$p.Name] = @{
      name        = [string]$e.name
      exePath     = [string]$e.exePath
      commandLine = [string]$e.commandLine
      cmdKnown    = ($e.cmdKnown -eq $true)
    }
  }
}

function Save-RkProcFacts {
  # Prune what is dead first, so the file cannot grow past the number of
  # processes that were ever alive at once. One Get-Process snapshot (37 ms)
  # rather than one per key.
  try {
    # Keyed exactly as the entries are - pid@startTicks - so a pid that was
    # recycled keeps only its CURRENT generation; pruning by pid alone kept
    # every old generation of a reused number forever (review of [R-095]).
    $alive = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
      $t = ''
      try { $t = $p.StartTime.Ticks.ToString() } catch { $t = '' }
      if ($t) { $alive[([string]$p.Id + '@' + $t)] = $true }
    }
    $keep = [ordered]@{}
    foreach ($k in @($script:RkProcFacts.Keys)) {
      if (-not $alive.ContainsKey($k)) { $script:RkProcFacts.Remove($k); continue }
      $keep[$k] = $script:RkProcFacts[$k]
    }
    $dir = Get-RkCacheDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    Write-RkJson -Path (Get-RkProcFactsFile) -Object ([ordered]@{
      schema  = 'respawnkeeper/procfacts/1'
      written = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
      entries = $keep
    })
  } catch { }
}

function Get-RkProcessFacts {
  # @{ name; exePath; commandLine; cmdKnown } for one pid, or $null when the
  # process is gone. An UNREADABLE ExecutablePath (another user, an elevation
  # boundary) is returned as an empty string rather than an error: "we could
  # not look" and "it is not ours" are different answers and must not collapse
  # into one.
  #
  # -NeedCommandLine: the command line is the one fact only CIM can give and
  # the one that costs the 300-500 ms, so it is fetched only when asked for
  # and only once per process. Without the switch, commandLine may be '' with
  # cmdKnown = $false, which means "not asked", not "empty".
  param([Parameter(Mandatory)][int]$ProcessId, [switch]$NeedCommandLine)
  if ($ProcessId -le 0) { return $null }
  $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $p) { return $null }
  $stamp = ''
  try { $stamp = $p.StartTime.Ticks.ToString() } catch { $stamp = '' }
  $key = ''
  if ($stamp) { $key = ([string]$ProcessId + '@' + $stamp) }

  $facts = $null
  if ($key) {
    if (-not $script:RkProcFactsLoaded) { $script:RkProcFactsLoaded = $true; Import-RkProcFacts }
    if ($script:RkProcFacts.ContainsKey($key)) { $facts = $script:RkProcFacts[$key] }
    # Another process may have learned MORE since this one loaded the file -
    # asked again whenever what is in memory is incomplete for this question.
    if ((-not $facts) -or (($NeedCommandLine -and (-not $facts.cmdKnown)) -or (-not $facts.exePath))) {
      if (Test-Path -LiteralPath (Get-RkProcFactsFile)) {
        Import-RkProcFacts
        if ($script:RkProcFacts.ContainsKey($key)) { $facts = $script:RkProcFacts[$key] }
      }
    }
  }
  # A hit is only a hit when it is complete for what was asked. An empty
  # exePath is "could not read it then", not a fact - it is retried every time
  # (Get-Process .Path is cheap), the same way an unread command line is.
  if ($facts -and $facts.exePath -and ($facts.cmdKnown -or (-not $NeedCommandLine))) {
    return @{ name = $facts.name; exePath = $facts.exePath; commandLine = $facts.commandLine; cmdKnown = $facts.cmdKnown }
  }

  # Cold, or the command line / exe path has not been read yet.
  $name = [string]$p.ProcessName
  $exe  = ''
  $cl   = ''
  $cmdKnown = $false
  if ($facts) { $name = $facts.name; $exe = $facts.exePath; if ($facts.cmdKnown) { $cl = $facts.commandLine; $cmdKnown = $true } }
  if (-not $exe) { try { $exe = [string]$p.Path } catch { $exe = '' } }
  if ($exe) { try { $name = [System.IO.Path]::GetFileName($exe) } catch { } }

  if (($NeedCommandLine -and (-not $cmdKnown)) -or (-not $exe)) {
    $w = $null
    try { $w = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $ProcessId) -ErrorAction Stop } catch { $w = $null }
    if ($w) {
      if ([string]$w.Name) { $name = [string]$w.Name }
      if ((-not $exe) -and [string]$w.ExecutablePath) { $exe = [string]$w.ExecutablePath }
      if ($null -ne $w.CommandLine) { $cl = [string]$w.CommandLine; $cmdKnown = $true }
    }
  }
  $out = @{ name = $name; exePath = $exe; commandLine = $cl; cmdKnown = $cmdKnown }
  if ($key) {
    # Remembered only when it is complete for what was asked: a command line
    # CIM refused to give is asked for again next time, never cached as ''.
    if ($cmdKnown -or (-not $NeedCommandLine)) {
      $script:RkProcFacts[$key] = @{ name = $name; exePath = $exe; commandLine = $cl; cmdKnown = $cmdKnown }
      Save-RkProcFacts
    }
  }
  return $out
}

function Test-RkOwnCopyExists {
  # Does THIS server folder hold its own executable called $Leaf?
  # Used for the one remaining "foreign" verdict: if this server ships its own
  # valheim_server.exe and the running valheim_server.exe is a different copy,
  # that process is provably a different instance. Without this check the
  # verdict would rest on "the exe is not under ServerDir", which is also true
  # of a perfectly ordinary vanilla Minecraft server running on a shared JDK -
  # and calling THAT foreign would open the gate on a live server.
  param([string]$ServerDir, [string]$Leaf, $Template = $null)
  if ((-not $ServerDir) -or (-not $Leaf)) { return $false }
  if (Test-Path -LiteralPath (Join-Path $ServerDir $Leaf) -PathType Leaf) { return $true }
  if ($Template) {
    $rel = ''
    try { $rel = [string]$Template.launch.exe } catch { $rel = '' }
    if ($rel) {
      $p = Join-Path $ServerDir $rel
      if ((Test-Path -LiteralPath $p -PathType Leaf) -and
          ([System.IO.Path]::GetFileName($p).ToLower() -eq $Leaf.ToLower())) { return $true }
    }
  }
  return $false
}

function Get-RkProcessOwnership {
  # @{ verdict = 'owned' | 'foreign' | 'unknown'; how; detail; exePath }
  #   owned   - this process belongs to THIS ServerDir. Use it as evidence.
  #   foreign - it provably belongs to a DIFFERENT install. NOT evidence here.
  #   unknown - we could not tell. Callers must still treat it as alive.
  # 'how' names the method that decided, so the reason line can say it:
  #   exe-path         - Win32_Process.ExecutablePath, the strong test
  #   loader-signature - the Minecraft fallback (loader path + version on the
  #                      command line); cannot separate two servers on the
  #                      identical loader version, which is why it is second.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory)][int]$ProcessId,
    [hashtable]$Loader,
    $Template = $null
  )
  $res = @{ verdict = 'unknown'; how = 'none'; detail = ''; exePath = '' }
  if ($ProcessId -le 0) { $res.detail = 'no pid to inspect'; return $res }
  # The executable path first, WITHOUT the command line: Get-Process answers
  # that in 12-34 ms and it settles every non-Minecraft server. The command
  # line (CIM, 300-500 ms, then cached) is fetched only when the path test
  # could not decide.
  $facts = Get-RkProcessFacts -ProcessId $ProcessId
  if (-not $facts) { $res.detail = 'the process could not be inspected'; return $res }
  $res.exePath = [string]$facts.exePath

  # (1) THE STRONG TEST. The server binary lives in the server folder for every
  # game here except Minecraft.
  if ($res.exePath -and (Test-RkPathUnder -Path $res.exePath -Root $ServerDir)) {
    $res.verdict = 'owned'
    $res.how     = 'exe-path'
    $res.detail  = 'its executable is inside this server folder (' + $res.exePath + ')'
    return $res
  }

  # (2) MINECRAFT. java.exe is a shared runtime outside every server folder, so
  # the path test can never decide. The loader group+version on the command line
  # is the same handle the old code used - kept exactly, now with the ability to
  # say "that is a DIFFERENT Minecraft server" instead of only "not mine".
  $facts = Get-RkProcessFacts -ProcessId $ProcessId -NeedCommandLine
  if (-not $facts) { $res.detail = 'the process went away while it was being inspected'; return $res }
  if ((-not $res.exePath) -and [string]$facts.exePath) {
    # CIM could read the path where Get-Process could not: run the strong test
    # now rather than carrying an empty path into the weaker ones.
    $res.exePath = [string]$facts.exePath
    if (Test-RkPathUnder -Path $res.exePath -Root $ServerDir) {
      $res.verdict = 'owned'
      $res.how     = 'exe-path'
      $res.detail  = 'its executable is inside this server folder (' + $res.exePath + ')'
      return $res
    }
  }
  if (-not $facts.cmdKnown) {
    # "Could not read the command line" is not "an empty command line". The
    # loader-signature test below cannot run without one, and a verdict from
    # its absence would be a guess; unknown keeps the process counted alive.
    $res.detail = 'the command line could not be read (another user, or CIM refused), so the loader test cannot run'
    return $res
  }
  $cl = [string]$facts.commandLine
  if ($cl -match 'libraries[\\/]net[\\/](?<grp>neoforged[\\/]neoforge|minecraftforge[\\/]forge)[\\/](?<ver>[^\s\\/]+)[\\/]win_args') {
    $clGrp = [string]$Matches['grp']
    $clVer = [string]$Matches['ver']

    # "Is that loader INSTALLED HERE?" is asked of the disk, NOT of the single
    # version Get-RkLoader picked. Get-RkLoader returns the NEWEST loader in
    # libraries\, and a folder often keeps the previous one after an update - so
    # a server genuinely running the older loader would fail a comparison
    # against the newest and be called foreign. That verdict would drop the port
    # evidence and open the gate in front of a RUNNING server, which is the one
    # outcome this whole file exists to prevent.
    $grpRel = 'net\neoforged\neoforge'
    if ($clGrp -match 'minecraftforge') { $grpRel = 'net\minecraftforge\forge' }
    $hereArgs = Join-Path $ServerDir (Join-Path 'libraries' (Join-Path $grpRel (Join-Path $clVer 'win_args.txt')))
    if (Test-Path -LiteralPath $hereArgs -PathType Leaf) {
      $wantGrp = 'neoforged'
      if ($Loader -and ($Loader.kind -eq 'forge')) { $wantGrp = 'minecraftforge' }
      if ($Loader -and ($clVer -eq [string]$Loader.version) -and ($clGrp -match $wantGrp)) {
        $res.verdict = 'owned'
        $res.how     = 'loader-signature'
        $res.detail  = ('its command line names this server loader ' + $Loader.kind + ' ' + $Loader.version +
                        ' (the exe is a shared JDK, so the path test cannot decide)')
        return $res
      }
      # That loader IS installed here, just not the newest one. It could be this
      # server on an older loader, or another install on the same one. Cannot
      # tell -> unknown, which keeps counting as alive.
      $res.detail = ('its loader (' + $clVer + ') is also installed under this server folder, so this process may or may not be this server')
      return $res
    }

    $res.verdict = 'foreign'
    $res.how     = 'loader-signature'
    $res.detail  = ('its command line names loader ' + $clVer + ', which is not installed under this server folder')
    return $res
  }

  # (3) Same executable NAME, different copy on disk.
  if ($res.exePath) {
    $leaf = ''
    try { $leaf = [System.IO.Path]::GetFileName($res.exePath) } catch { $leaf = '' }
    if ($leaf -and (Test-RkOwnCopyExists -ServerDir $ServerDir -Leaf $leaf -Template $Template)) {
      $res.verdict = 'foreign'
      $res.how     = 'exe-path'
      $res.detail  = ('this server has its own ' + $leaf + ', and that process is running a different copy (' +
                      $res.exePath + ')')
      return $res
    }
    $res.detail = ('its executable (' + $res.exePath + ') is outside this server folder, and this folder holds no copy of it to compare against')
    return $res
  }

  $res.detail = 'the executable path could not be read (access denied, or a 32/64-bit boundary)'
  return $res
}

# ---- Liveness: is a server actually running for THIS ServerDir? -------------

function Get-RkPidFileProcess {
  # Reads a PID file and returns the process only if it is alive AND still looks
  # like this game. Guards against PID recycling (the same guard fc8's heartbeat
  # needed): a pid file outlives its process, and the number gets handed out
  # again.
  #
  # 2026-09-12 ([R-072] item 2): this used to require ProcessName -match 'java',
  # which meant the pidFileProbe could not fire for ANY non-Minecraft game -
  # while lib\rk-capabilities.psd1 counts it toward twoLivenessProbes, the one
  # requirement the safety gate has. The name now comes from the template.
  #
  # EXACT MATCH ONLY, never a wildcard - the Palworld rule (the server is
  # PalServer-Win64-Shipping-Cmd, the game somebody is playing is
  # Palworld-Win64-Shipping). Get-Process gives a name WITHOUT the extension
  # while Win32_Process gives one WITH it, and templates are written both ways
  # ('java.exe', 'valheim_server'), so both sides are normalised the way
  # Get-RkGameProcesses already does it.
  #
  # -ServerDir is optional and only ever WIDENS the answer: a process whose
  # executable sits inside the server folder is this server whatever it is
  # called.
  param(
    [Parameter(Mandatory)][string]$PidFile,
    $Template = $null,
    [string[]]$Names = @(),
    [string]$ServerDir = ''
  )
  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return $null }
  $raw = ''
  try { $raw = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction Stop).Trim() } catch { return $null }
  if ($raw -notmatch '^\d+$') { return $null }
  $p = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue
  if (-not $p) { return $null }

  $wanted = @($Names | Where-Object { $_ })
  if (($wanted.Count -eq 0) -and $Template) {
    try { $wanted = @($Template.process.names | Where-Object { $_ }) } catch { $wanted = @() }
  }
  if ($wanted.Count -eq 0) {
    # Pre-template-layer behaviour, kept verbatim so a call with no template
    # behaves exactly as it did before this change. Nothing widens here.
    if ($p.ProcessName -match 'java') { return $p }
    return $null
  }
  $norm = @($wanted | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$_).ToLower() })
  if ($norm -contains $p.ProcessName.ToLower()) { return $p }
  if ($ServerDir) {
    $exe = ''
    try { $exe = [string]$p.Path } catch { $exe = '' }
    if ($exe -and (Test-RkPathUnder -Path $exe -Root $ServerDir)) { return $p }
  }
  return $null
}

function Get-RkServerLiveness {
  # Three independent probes. Any ONE of them saying "alive" means alive.
  #
  # ATTRIBUTION (2026-09-12, [R-072] stage 4). Every probe used to answer "is
  # something of this shape running on this MACHINE". That is a different
  # question from "is THIS server running", and the two answers only coincide
  # when exactly one server exists. fc8 and pokemoncraft are both on
  # server-port=25565 (measured), so neither could be told from the other.
  #
  # Each candidate pid now goes through Get-RkProcessOwnership:
  #   owned   -> evidence, and the reason line says which method proved it
  #   foreign -> NOT evidence for this server; recorded in .excluded instead
  #   unknown -> still counted as alive, marked [unattributed]
  # Only a POSITIVE foreign verdict ever removes evidence, so this cannot make
  # the safety gate more permissive than it was - only more precise.
  #
  # Honest limitation, unchanged and still the reason nothing here kills
  # anything on its own: Windows does not expose a process's working directory,
  # so a java.exe launched as `java @user_jvm_args.txt @libraries/...` carries
  # no absolute path identifying its server. For Minecraft the loader path and
  # version from this ServerDir's win_args remains the handle - enough to tell
  # forge 1.20.1-47.4.10 from neoforge 21.1.247, NOT enough to tell two servers
  # on the identical loader version apart. Those two still read alive for each
  # other, which is the safe direction.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    [hashtable]$Loader,
    $Template = $null
  )
  # Non-Minecraft games are identified by their own executable name instead of a
  # loader path. That is MORE precise, not less - but it must be an exact match:
  # Palworld's server is PalServer-Win64-Shipping-Cmd while the game somebody is
  # playing is Palworld-Win64-Shipping, and a wildcard would kill the client.
  # See Get-RkGameProcesses.
  $useTemplateProcess = $false
  if ($Template -and @($Template.process.names | Where-Object { $_ }).Count -gt 0 -and (-not $Template.process.matchCommandLine)) {
    $useTemplateProcess = $true
  }
  if ((-not $Loader) -and (-not $useTemplateProcess)) { $Loader = Get-RkLoader -ServerDir $ServerDir }
  $stateDir = Get-RkStateDir -ServerDir $ServerDir
  $port = Get-RkServerPort -ServerDir $ServerDir -Template $Template

  $result = @{
    alive        = $false
    reasons      = @()
    excluded     = @()   # candidates that were proved to belong to another server
    port         = $port
    portProtocol = 'tcp'
    portHolder   = 0
    pids         = @()
  }

  # 1) port. Skipped when the port is unknown (0) - watching the wrong port is
  # worse than not watching one. The protocol comes from the template: a UDP
  # game asked the TCP question answers "nothing there" forever, which reads as
  # a dead server no matter how many people are playing on it.
  $proto = Get-RkPortProtocol -Template $Template
  $result.portProtocol = $proto
  if ($port -gt 0) {
    $holders = Get-RkPortHolders -Port $port -Protocol $proto
    if ($holders.bound) {
      $state = 'is LISTENING'
      if ($proto -eq 'udp') { $state = 'is BOUND (udp)' }   # udp sockets have no Listen state
      # The holder is reported in portHolder only, not merged into .pids - the
      # pid list is "processes we believe are the server", and a port holder is
      # evidence of life without being identified as this server.
      $hpids = @($holders.pids)
      if ($hpids.Count -eq 0) {
        # Bound, but nothing said who holds it. Still evidence of life.
        $result.alive = $true
        $result.reasons += ('port ' + $port + ' ' + $state + ' (owning pid not readable) [unattributed]')
      } else {
        foreach ($hp in $hpids) {
          $own = Get-RkProcessOwnership -ServerDir $ServerDir -ProcessId ([int]$hp) -Loader $Loader -Template $Template
          if ($own.verdict -eq 'foreign') {
            # THE fc8 / pokemoncraft case: both declare 25565, so one running
            # made the other look alive. A port held by a provably different
            # install is not evidence about this one.
            $result.excluded += ('port ' + $port + ' is held by pid ' + $hp +
                                 ', which belongs to ANOTHER server (' + $own.how + '): ' + $own.detail)
            continue
          }
          $result.alive = $true
          if ($result.portHolder -eq 0) { $result.portHolder = [int]$hp }
          $tag = '[unattributed: ' + $own.detail + ']'
          if ($own.verdict -eq 'owned') { $tag = '[' + $own.how + ': ' + $own.detail + ']' }
          $result.reasons += ('port ' + $port + ' ' + $state + ' (pid ' + $hp + ') ' + $tag)
        }
      }
    }
  }

  # 2) our own pid file, and the one start_server.ps1 writes. Both live inside
  # this server folder, so the file itself is already attributed - what the name
  # check defends against is PID RECYCLING, and the ownership check on top of it
  # against the recycled pid happening to be another copy of the same game.
  foreach ($pf in @((Join-Path $stateDir 'server.pid'), (Join-Path $ServerDir 'RUNNING.pid'))) {
    $p = Get-RkPidFileProcess -PidFile $pf -Template $Template -ServerDir $ServerDir
    if (-not $p) { continue }
    $own = Get-RkProcessOwnership -ServerDir $ServerDir -ProcessId $p.Id -Loader $Loader -Template $Template
    if ($own.verdict -eq 'foreign') {
      $result.excluded += ('pid file ' + (Split-Path -Leaf $pf) + ' points at pid ' + $p.Id +
                           ', which belongs to ANOTHER server (' + $own.how + '): ' + $own.detail)
      continue
    }
    $result.alive = $true
    if ($result.pids -notcontains $p.Id) { $result.pids += $p.Id }
    $tag = '[pid-file + name match]'
    if ($own.verdict -eq 'owned') { $tag = '[pid-file + ' + $own.how + ']' }
    $result.reasons += ('pid file ' + (Split-Path -Leaf $pf) + ' -> live ' + $p.ProcessName + ' pid ' + $p.Id + ' ' + $tag)
  }

  # 3a) the game's own process, by exact name (non-Minecraft templates).
  # Get-RkGameProcesses looks at the WHOLE MACHINE by design - it only knows a
  # name. Narrowing it to this ServerDir happens here, because only here is the
  # ServerDir known.
  if ($useTemplateProcess) {
    foreach ($pr in (Get-RkGameProcesses -Template $Template)) {
      $own = Get-RkProcessOwnership -ServerDir $ServerDir -ProcessId $pr.Id -Loader $Loader -Template $Template
      if ($own.verdict -eq 'foreign') {
        $result.excluded += ('process ' + $pr.ProcessName + ' (pid ' + $pr.Id +
                             ') is running, but it is NOT this server (' + $own.how + '): ' + $own.detail)
        continue
      }
      $result.alive = $true
      if ($result.pids -notcontains $pr.Id) { $result.pids += $pr.Id }
      $tag = '[unattributed: ' + $own.detail + ']'
      if ($own.verdict -eq 'owned') { $tag = '[' + $own.how + ': ' + $own.detail + ']' }
      $result.reasons += ('process ' + $pr.ProcessName + ' (pid ' + $pr.Id + ') is running ' + $tag)
    }
  }

  # 3b) command-line loader signature (Minecraft)
  if ($Loader) {
    $sig = [regex]::Escape($Loader.version)
    $grp = 'neoforged[\\/]neoforge'
    if ($Loader.kind -eq 'forge') { $grp = 'minecraftforge[\\/]forge' }
    # Get-Process names the java processes (32 ms); the command line of each
    # comes from the facts cache, so the 448 ms CIM sweep this used to be is
    # paid once per java process for its whole lifetime, not once per refresh.
    foreach ($jp in @(Get-Process -Name 'java' -ErrorAction SilentlyContinue)) {
      $jf = Get-RkProcessFacts -ProcessId $jp.Id -NeedCommandLine
      if (-not ($jf -and $jf.cmdKnown)) { continue }
      $jcl = [string]$jf.commandLine
      if (-not ($jcl -and ($jcl -match $grp) -and ($jcl -match $sig))) { continue }
      $result.alive = $true
      if ($result.pids -notcontains $jp.Id) { $result.pids += $jp.Id }
      $result.reasons += ('java pid ' + $jp.Id + ' command line references ' + $Loader.kind + ' ' + $Loader.version +
                          ' [loader-signature: java.exe lives outside the server folder, so the path test cannot apply]')
    }
  }

  return $result
}

function Test-RkProvenDead {
  # "The process is still alive, but the SERVER inside it is already dead -
  # and it finished saving before it died."
  #
  # WHY THIS EXISTS (2026-09-07, pokemoncraft, three friends online):
  #   A Fish Trap built an ItemStack with count=102. ItemStack.CODEC only
  #   accepts [1;99], so saving it threw and that killed the world tick. The
  #   server then ran its shutdown properly: it saved every dimension, wrote
  #   "All dimensions are saved", and released 25565 - and the JVM did not
  #   exit. It sat there holding nothing but the BlueMap port.
  #
  #   Get-RkServerLiveness calls that ALIVE, correctly by its own rules: any
  #   one probe saying alive means alive, and the process probe still matched.
  #   So the supervisor believed a dead server was running. For 76 minutes.
  #   Nobody could connect, and no restart was attempted.
  #
  # Killing a Minecraft server is normally the wrong move, and killing one
  # mid-save is worse than leaving a bad one up. This function exists to name
  # the ONE case where that argument does not apply: THE SAVE IS ALREADY ON
  # DISK. It demands four INDEPENDENT pieces of evidence and returns dead=$false
  # the moment one of them is missing. It never kills anything itself - it only
  # answers the question, and records why.
  #
  # Deliberately NOT evidence:
  #   - CPU near zero. A quiet server with nobody online looks the same.
  #   - "the log has an exception in it". Servers survive exceptions constantly.
  #   - a crash report existing. That is written on the way down, long before
  #     we know whether the JVM will actually exit.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    [int]$ProcessId = 0,
    $Template = $null,
    [int]$StaleMin = 5,
    [int]$TailLines = 400
  )

  $r = @{
    dead         = $false
    evidence     = @()
    missing      = @()
    port         = 0
    portProtocol = 'tcp'
    logAgeMin    = -1
  }

  # (1) the process is still there. If it is gone there is nothing to decide.
  if ($ProcessId -le 0) { $r.missing += 'no pid was given'; return $r }
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $proc) { $r.missing += ('pid ' + $ProcessId + ' has already exited - nothing to end'); return $r }
  $r.evidence += ('pid ' + $ProcessId + ' is still running')

  # (2) it is not serving anybody. An unknown port is NOT treated as "closed" -
  # that would turn "we cannot tell" into "go ahead and kill it".
  $port = Get-RkServerPort -ServerDir $ServerDir -Template $Template
  $r.port = $port
  if ($port -le 0) { $r.missing += 'the server port is unknown, so "not serving" cannot be proved'; return $r }
  $proto = Get-RkPortProtocol -Template $Template
  $r.portProtocol = $proto
  $holders = Get-RkPortHolders -Port $port -Protocol $proto
  if ($holders.bound) {
    $word = 'LISTENING'
    if ($proto -eq 'udp') { $word = 'BOUND (udp)' }
    $r.missing += ('port ' + $port + ' is still ' + $word + ' - it is serving'); return $r
  }
  $r.evidence += ('port ' + $port + ' is not ' + $(if ($proto -eq 'udp') { 'bound' } else { 'listening' }))

  # (3) it has stopped doing anything at all. Which file that is, is the
  # template's answer, not this function's - including the case where the only
  # stream is the console respawnkeeper captured, named per run.
  $log = Get-RkLogFile -ServerDir $ServerDir -Template $Template
  if (-not $log) { $r.missing += 'there is no log file to read'; return $r }
  $ageMin = ((Get-Date) - (Get-Item -LiteralPath $log).LastWriteTime).TotalMinutes
  $r.logAgeMin = [math]::Round($ageMin, 1)
  if ($ageMin -lt $StaleMin) { $r.missing += ('the log moved ' + $r.logAgeMin + ' min ago - it is still doing something'); return $r }
  $r.evidence += ('the log has not moved for ' + $r.logAgeMin + ' min')

  # (4) and the last thing it did was finish saving. This is the one that makes
  # ending the process safe rather than destructive.
  $pattern = 'All chunks are saved|All dimensions are saved'
  if ($Template -and $Template.evidence -and $Template.evidence.cleanShutdown) {
    $pattern = [string]$Template.evidence.cleanShutdown
  }
  $tail = ''
  try {
    # ReadWrite share: the JVM still holds the handle open.
    $fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    $sr = New-Object System.IO.StreamReader($fs)
    $all = $sr.ReadToEnd()
    $sr.Close(); $fs.Close()
    $lines = @($all -split "`r?`n")
    if ($lines.Count -gt 0) {
      $take = [Math]::Min($TailLines, $lines.Count)
      $tail = ($lines[($lines.Count - $take)..($lines.Count - 1)]) -join "`n"
    }
  } catch {
    $r.missing += ('could not read the log: ' + $_.Exception.Message)
    return $r
  }
  if ($tail -notmatch $pattern) {
    $r.missing += 'the log does not end with a completed save - it may still hold unsaved world state'
    return $r
  }
  $r.evidence += 'the log ends with a completed save'

  $r.dead = $true
  return $r
}

function Assert-RkServerStopped {
  # THE gate in front of every write to the server. "Repair only while stopped"
  # is not a promise the harness makes to itself - it is re-proved here, from
  # the machine, every single time ([R-007] item 1; the fc8 hot-swap incident).
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    [hashtable]$Loader,
    $Template = $null
  )
  $live = Get-RkServerLiveness -ServerDir $ServerDir -Loader $Loader -Template $Template
  if ($live.alive) {
    throw ("REFUSING to touch a running server. " + ($live.reasons -join ' | '))
  }
  return $true
}

# ---- Logging / status -------------------------------------------------------

function Get-RkServerReadiness {
  # DID IT ACTUALLY COME UP, AND IS ANYTHING WRONG - read from the log.
  #
  # WHY THIS EXISTS (Eva, 2026-09-14): "to say it is running, there should be a
  # layer that checks, from the log's location and how it is emitted, whether it
  # started and whether there is a problem."
  #
  # She is pointing at a real gap. Get-RkServerLiveness answers "is a process of
  # this shape here, and is the port held" - three probes, none of which knows
  # the difference between a server that is SERVING and one that is still
  # loading. On this very game that difference was 113 SECONDS: world generation
  # ran that long, and during it "the server did not stop" and "the server had
  # not started yet" produced identical readings. The first Valheim stop
  # measurement was invalidated by exactly that ([R-076]) - Ctrl+C was sent into
  # a server that had not finished starting, and nobody could tell from outside.
  #
  # So this reads the ONE artefact that knows: the log the game itself writes.
  # It never guesses. A game whose ready marker has not been identified gets
  # 'nomarker', which is not 'ready' and must never be rounded up to it.
  #
  # IT IS NOT A REPLACEMENT FOR LIVENESS, AND MUST NOT BE USED AS ONE. A log is
  # a record of the past: for a game whose launcher writes a new file per run,
  # the newest log after a clean stop still ends in a perfectly good "ready".
  # Pass -Since (the run's start time) when the question is about THIS run;
  # without it the answer is about the most recent run, whenever that was.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    $Template = $null,
    [datetime]$Since = [datetime]::MinValue,
    [int]$TailLines = 200,
    [int]$MaxScanBytes = 4194304,
    # How long after -Since a missing ready marker may still be read as "still
    # coming up". Beyond it the honest answer is 'unknown', not 'starting' -
    # see the rotation note below. 15 minutes against a 31 s pokemoncraft boot
    # and a 113 s Valheim first world generation.
    [int]$StartWindowSec = 900
  )

  $res = @{
    verdict  = 'nolog'      # nolog | nomarker | stale | starting | trouble | ready | unknown
    logPath  = ''
    ready    = $false
    readyLine = ''
    problems = @()
    detail   = ''
  }

  $pat = ''
  try { $pat = [string]$Template.evidence.ready } catch { $pat = '' }
  $exc = ''
  try { $exc = [string]$Template.evidence.exception } catch { $exc = '' }

  # ONE WINDOW RULE FOR EVERY "NOT YET" ANSWER. nolog, stale and starting are
  # all "ask again in a moment", and every one of them needs the same escape
  # hatch or a caller waits for ever. The first version only put the bound on
  # 'starting', so a launcher whose redirect never produced a file, or a glob
  # that only ever resolved to yesterday's run, sat at nolog/stale silently and
  # for ever - and nolog, being the LESSER failure, was the one that got logged.
  $overWindow = (($Since -ne [datetime]::MinValue) -and (((Get-Date) - $Since).TotalSeconds -gt $StartWindowSec))
  $waited = $(if ($Since -ne [datetime]::MinValue) { [int](((Get-Date) - $Since).TotalSeconds) } else { -1 })

  $log = $null
  try { $log = Get-RkLogFile -ServerDir $ServerDir -Template $Template } catch { $log = $null }
  if (-not $log) {
    if ($overWindow) {
      $res.verdict = 'unknown'
      $res.detail  = 'no log after ' + $waited + ' s. Either this game writes none, or the launcher was meant to redirect one and did not'
    } else {
      $res.detail = 'no log yet. This game may write none, or the launcher may not have created it yet'
    }
    return $res
  }
  $res.logPath = $log

  if (-not $pat) {
    # THE HONEST ANSWER, and the reason step 1 of adding a game is "find the
    # log and the line that says it is up". Without that line the harness can
    # see a process and a port and still have no idea whether anybody could
    # join. Reporting 'ready' here would be inventing evidence.
    $res.verdict = 'nomarker'
    $res.detail  = 'evidence.ready is not declared for this game: nothing in the log has been identified as "it is up"'
    return $res
  }

  $fi = $null
  try { $fi = Get-Item -LiteralPath $log -ErrorAction Stop } catch { $fi = $null }
  if (-not $fi) { $res.detail = 'the log resolved to a path that is not there'; return $res }
  if (($Since -ne [datetime]::MinValue) -and ($fi.LastWriteTime -lt $Since)) {
    # Not this run's log. Saying 'starting' here would be a window that waits
    # forever for a line that was already written yesterday, in another file.
    if ($overWindow) {
      $res.verdict = 'unknown'
      $res.detail  = 'after ' + $waited + ' s the newest log is still one from before this run (' + $fi.LastWriteTime.ToString('HH:mm:ss') + '). This run has written nothing anywhere the template looks'
    } else {
      $res.verdict = 'stale'
      $res.detail  = 'the newest log was last written ' + $fi.LastWriteTime.ToString('HH:mm:ss') + ', before this run began'
    }
    return $res
  }

  # --- the ready marker: from the TOP, with an early exit ---------------------
  # Startup output is at the beginning of a per-run log by construction, so this
  # stops at the first match and never reads the rest. The byte cap is the
  # backstop for the case where the marker is absent and the file is enormous
  # (a busy latest.log); lines are not counted because a modded server can emit
  # thousands before it is up - measured: 13,553-13,560 lines into the debug log
  # of three real pokemoncraft boots.
  $seen = 0
  $capped = $false
  $sr = $null
  try {
    $fs = New-Object System.IO.FileStream($log, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    $sr = New-Object System.IO.StreamReader($fs)
    while (-not $sr.EndOfStream) {
      $line = $sr.ReadLine()
      if ($null -eq $line) { break }
      $seen += ($line.Length + 2)
      if ($line -match $pat) { $res.ready = $true; $res.readyLine = $line.Trim(); break }
      # Characters, not bytes, and these logs carry multi-byte timestamps - so
      # the real limit is larger than the name says, which is the safe
      # direction. Measured for scale: fc8's boot reaches its ready line 1.09 MB
      # into latest.log, pokemoncraft's 844 KB, so 4 MB is about four boots of
      # headroom on a 241-mod pack. Reaching it must NOT read as "no ready line"
      # - that is a third answer and it gets said out loud.
      if ($seen -ge $MaxScanBytes) { $capped = $true; break }
    }
  } catch {
    $res.detail = 'could not read the log: ' + $_.Exception.Message
    return $res
  } finally {
    if ($sr) { try { $sr.Close() } catch { } }
  }

  # !! PROBLEMS ARE ONLY ASKED ABOUT ONCE IT IS UP, AND THAT ORDER IS THE WHOLE
  # POINT. The first version asked first, and it was wrong on the game this
  # harness exists for: minecraft's evidence.exception matches bare indented
  # stack frames, and a healthy modded boot prints thousands of them - measured
  # 2,767 hits before the ready line in one fc8 boot, 29 in a pokemoncraft one,
  # with 28 of those inside a two-second window at +14 s. Every one is an
  # ordinary "[mixin/]: Error loading class ... ClassNotFoundException" that the
  # loader handles. Asking about problems first therefore turned EVERY healthy
  # modded start into 'trouble', and because the supervisor settles on the first
  # answer it gets, 'ready' could never be reached at all.
  #
  # The question this function answers is "did it come up". Noise during startup
  # is not an answer to that. Once the ready line is in hand, the tail is a fair
  # question again, because now it means "and is it complaining NOW".
  if (-not $res.ready) {
    if ($overWindow) {
      $res.verdict = 'unknown'
      if ($capped) {
        $res.detail = 'stopped looking after ' + [int]($MaxScanBytes / 1024) + ' KB without finding the ready line. The log is bigger than this scan, so this is "we did not look far enough", not "it never came up"'
      } else {
        $res.detail = 'no ready line after ' + $waited + ' s. Either it never came up, or the log rolled and took the startup lines with it - this cannot tell those apart, so it claims neither'
      }
      return $res
    }
    $res.verdict = 'starting'
    $res.detail  = 'the log is being written but has not said it is up yet'
    if ($capped) { $res.detail = 'stopped looking after ' + [int]($MaxScanBytes / 1024) + ' KB; no ready line in what was read' }
    return $res
  }

  # It is up. NOW the tail means something.
  $tailRead = $true
  if ($exc) {
    try {
      $tail = @(Get-Content -LiteralPath $log -Tail $TailLines -ErrorAction Stop)
      foreach ($l in $tail) { if ($l -match $exc) { $res.problems += $l.Trim() } }
    } catch {
      # !! AN EMPTY CATCH HERE MEANT "COULD NOT LOOK" CAME OUT AS "NOTHING IS
      # WRONG". A locked file or a roll mid-read fell straight through to
      # 'ready' with an empty problems list and no hint that a check had been
      # skipped. Not being able to check is a third state and it is said.
      $tailRead = $false
      $res.detail = 'could not read the tail: ' + $_.Exception.Message
    }
  }

  if (@($res.problems).Count -gt 0) {
    $res.verdict = 'trouble'
    $res.detail  = 'it finished starting, and ' + @($res.problems).Count.ToString() + ' line(s) in the last ' + $TailLines + ' look like an exception'
    return $res
  }
  if ($true) {
    $res.verdict = 'ready'
    if ($tailRead) {
      $res.detail = 'the log says it finished starting'
    } else {
      $res.detail = 'the log says it finished starting, but the tail could not be read - nothing was checked for problems (' + $res.detail + ')'
    }
    return $res
  }
  # THE ROTATION NOTE, kept because the reason outlives the code that used to be
  # here: pokemoncraft's latest.log is rolled by log4j at midnight, so a server
  # up since yesterday has a latest.log whose first line is 00:00:08 and which
  # will NEVER contain 'Done (...)! For help'. That is why "no ready line past
  # the window" is 'unknown' and not "it never came up".
  #
  # The obvious detection does not work, and was measured before being
  # discarded: latest.log's CreationTime is 2026-08-01, six weeks before its
  # own first line, because NTFS file tunneling hands the original timestamp
  # back to a file recreated under the same name. Parsing the first line's
  # timestamp would need a format per game.
}

function Get-RkShutdownEvidence {
  # Answers ONE question: did this server stop because a human stopped it, or
  # because it broke? Getting this wrong in the "human" direction means the
  # harness resurrects a server somebody deliberately took down.
  #
  # The exit code alone is not enough. Killing java from Task Manager gives a
  # NON-ZERO exit code and leaves NO crash report - identical, from the outside,
  # to a crash that failed to write a report. So three signals are read:
  #
  #   cleanShutdownLogged : the vanilla shutdown sequence is in the log tail
  #                         ("Stopping server" / "Saving worlds" / "All chunks
  #                         are saved"). Present ONLY when the server was asked
  #                         to stop and did so - a crash never writes it.
  #   jvmCrashLog         : an hs_err_pid*.log newer than this run = the JVM
  #                         itself died. That IS a crash, even with no report.
  #   exceptionInTail     : a stack trace at the end of the log.
  #
  # Verdict:
  #   crash   - a crash report, or hs_err, or an exception with no clean shutdown
  #   clean   - the shutdown sequence was logged
  #   unknown - nothing says either way (the classic Task-Manager kill)
  #
  # "unknown" is deliberately NOT treated as a crash. Refusing to restart costs
  # a manual start; restarting into something a human was in the middle of
  # costs a corrupted afternoon.
  param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory)][datetime]$Since,
    [int]$TailLines = 60,
    $Template = $null,          # game template; absent = the Minecraft defaults
    [string]$ConsoleLog = ''    # captured console, for games that write no log file
  )
  $res = @{ verdict = 'unknown'; cleanShutdownLogged = $false; jvmCrashLog = ''; exceptionInTail = $false; crashReport = '' }

  # Defaults are Minecraft's, so a call with no template behaves exactly as
  # before the template layer existed.
  $jvmGlob     = 'hs_err_pid*.log'
  $reClean     = 'Stopping server|Saving worlds|All chunks are saved|Stopping the server|ThreadedAnvilChunkStorage .*: All dimensions are saved'
  $reException = '(?m)^\s+at [\w\.$]+\(.*\)|Exception in server tick loop|java\.lang\.\w+(Error|Exception)'
  if ($Template) {
    $jvmGlob = [string]$Template.paths.jvmCrashGlob
    if ($Template.evidence.cleanShutdown) { $reClean = [string]$Template.evidence.cleanShutdown }
    if ($Template.evidence.exception)     { $reException = [string]$Template.evidence.exception }
  }
  # Both of these are the template's answer now, resolved in one place each
  # (Get-RkCrashDirs / Get-RkLogFile) instead of being rebuilt from a hardcoded
  # Minecraft relative path here.
  $crashDirs = @(Get-RkCrashDirs -ServerDir $ServerDir -Template $Template)
  $logPath   = Get-RkLogFile -ServerDir $ServerDir -Template $Template

  foreach ($d in $crashDirs) {
    $r = Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt $Since } | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($r) { $res.crashReport = $r.FullName }
  }

  if ($jvmGlob) {
    $hs = @(Get-ChildItem -LiteralPath $ServerDir -Filter $jvmGlob -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt $Since } | Sort-Object LastWriteTime)
    if ($hs.Count -gt 0) { $res.jvmCrashLog = $hs[-1].FullName }
  }

  # Where to read the last lines from. Most games are NOT Minecraft: they print
  # to the console and leave no log file, so the console respawnkeeper captured
  # is the only evidence there is.
  $tail = ''
  $sources = New-Object System.Collections.ArrayList
  if ($logPath) { [void]$sources.Add($logPath) }
  if ($ConsoleLog -and ($ConsoleLog -ne $logPath)) { [void]$sources.Add($ConsoleLog) }
  foreach ($src in $sources) {
    if (-not (Test-Path -LiteralPath $src)) { continue }
    try { $tail += ((Get-Content -LiteralPath $src -Tail $TailLines -ErrorAction Stop) -join "`n") + "`n" } catch {}
  }
  if ($tail) {
    if ($tail -match $reClean) { $res.cleanShutdownLogged = $true }
    if ($tail -match $reException) { $res.exceptionInTail = $true }
  }

  if ($res.crashReport -or $res.jvmCrashLog) { $res.verdict = 'crash' }
  elseif ($res.cleanShutdownLogged) { $res.verdict = 'clean' }
  elseif ($res.exceptionInTail) { $res.verdict = 'crash' }
  else { $res.verdict = 'unknown' }

  return $res
}

function Get-RkProfile {
  # Per-server settings, written by rk-setup.ps1 to
  # <ServerDir>\respawnkeeper\profile.json.
  #
  # These have to be per-server, not harness-wide: fc8 is a live server friends
  # play on, pokemoncraft has nobody connected yet. "Restart and repair while I
  # sleep" is a reasonable answer for one and not the other, and one harness
  # serves both.
  param([Parameter(Mandatory)][string]$ServerDir)
  return (Read-RkJson -Path (Join-Path (Get-RkStateDir -ServerDir $ServerDir) 'profile.json'))
}

function Test-RkScheduledTaskArmed {
  # "Is any scheduled task whose NAME matches this pattern in a state other
  # than Disabled?" -> @{ armed; name; probed }
  #
  # Split out of Get-RkLegacyWatchdog for one reason: on this machine the only
  # task the caller cares about is Disabled, so a check that compared this
  # against Get-ScheduledTask could only ever compare $false with $false. A
  # test that cannot go red in the dangerous direction is not a test
  # (the project notes (verification-that-cannot-fail)). With the pattern as a
  # parameter, the self-test can point it at a task it can SEE is enabled and
  # require a yes.
  param([Parameter(Mandatory)][string]$NamePattern)
  $out = @{ armed = $false; name = ''; probed = $false }
  $svc = $null
  $seen = New-Object System.Collections.ArrayList   # RCWs to release
  try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $stack = New-Object System.Collections.Stack
    $stack.Push($svc.GetFolder('\'))
    while ($stack.Count -gt 0) {
      $folder = $stack.Pop()
      [void]$seen.Add($folder)
      foreach ($sub in @($folder.GetFolders(0))) { $stack.Push($sub) }
      foreach ($t in @($folder.GetTasks(1))) {     # 1 = include hidden
        [void]$seen.Add($t)
        if ([string]$t.Name -like $NamePattern) {
          # IRegisteredTask.State: 0 Unknown, 1 Disabled, 2 Queued, 3 Ready,
          # 4 Running. Anything not provably Disabled counts as armed, so an
          # Unknown falls on the safe side - the same direction the cmdlet's
          # 'State -ne Disabled' test fell.
          if ([int]$t.State -ne 1) { $out.armed = $true; $out.name = [string]$t.Name }
        }
      }
    }
    $out.probed = $true
  } catch {
    $out.probed = $false
    $out.armed  = $false
    $out.name   = ''
  } finally {
    # Measured 2026-09-13: about 33 KB held per unreleased RCW, and the panel
    # calls this every refresh for as long as it is open.
    foreach ($o in $seen) { try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($o) } catch {} }
    if ($svc) { try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($svc) } catch {} }
  }
  return $out
}

function Get-RkLegacyWatchdog {
  # fc8 shipped its own supervisor (watchdog\fc8_watchdog.ps1) AND a Layer2
  # scheduled task (FC8WatchdogHeartbeat, wscript -> fc8_heartbeat_launcher.vbs)
  # that relaunches fc8_watchdog.bat every ~2 minutes whenever state.json says
  # intent=SHOULD_RUN. That task is still installed and still firing (observed
  # running 2026-08-26; it currently exits early only because fc8's own
  # STATUS.txt says STOPPED_BY_USER).
  #
  # Two supervisors on one server is not a style problem: the heartbeat would
  # start the old watchdog, which would start the server, underneath a running
  # respawnkeeper. So respawnkeeper refuses to run against a server that still
  # has an ARMED legacy heartbeat, and says how to disarm it.
  param([Parameter(Mandatory)][string]$ServerDir)
  # probed: did we actually get to LOOK? Callers today only read taskArmed, and
  # this gate has always been fail-open (an unreadable task store reads as "not
  # armed"). That polarity is not changed here, but "we could not look" is now
  # distinguishable from "we looked and it is off", so it can be.
  $res = @{ present = $false; taskArmed = $false; script = ''; taskName = ''; uninstall = ''; probed = $false }
  $legacy = Join-Path $ServerDir 'watchdog\fc8_watchdog.ps1'
  if (-not (Test-Path -LiteralPath $legacy)) { return $res }
  $res.present   = $true
  $res.script    = $legacy
  $res.uninstall = Join-Path $ServerDir 'watchdog\uninstall_heartbeat.ps1'
  # ASK THE TASK BY NAME, NOT BY ENUMERATING THE STORE.
  #
  # Get-ScheduledTask with no arguments loads every task on the machine and the
  # filtering then happens in PowerShell. Measured 2026-09-13, three runs each:
  #   Get-ScheduledTask | Where-Object   1040 - 1296 ms
  #   Get-ScheduledTask -TaskName '*..*'  978 - 1035 ms   (the cmdlet still loads the store)
  #   Schedule.Service COM, by name          2 -   86 ms
  # The panel calls this once per server on a four second timer, so that one
  # second was the single largest thing freezing the window - and it was buying
  # one boolean about one named task. [R-091]
  #
  # A cache was the obvious fix and is the wrong one: this answers "is a second
  # supervisor armed right now", and a stale yes/no there is exactly the fault
  # this function exists to catch. 2ms needs no cache.
  #
  # !! THE FIRST VERSION OF THIS SPEEDUP NARROWED THE GATE, and an adversarial
  # review caught it before it shipped. It asked GetFolder('\').GetTask() for
  # the EXACT name in the ROOT folder, and treated "a task by that name exists"
  # - disabled or not - as reason to skip the fallback. The code it replaced
  # matched '-match FC8WatchdogHeartbeat' (a SUBSTRING) across ALL folders. So
  # an armed FC8WatchdogHeartbeat_pokemoncraft, or an armed copy in a subfolder,
  # would have been answered "not armed" while a disabled one sat in the root -
  # and this gate is the only thing stopping two supervisors starting one
  # server. Speed is not allowed to shrink what a safety gate can see. The COM
  # path now walks every folder and matches the same substring the old code did.
  $fast = Test-RkScheduledTaskArmed -NamePattern '*FC8WatchdogHeartbeat*'
  $probed = [bool]$fast.probed
  if ($probed -and $fast.armed) { $res.taskArmed = $true; $res.taskName = [string]$fast.name }
  $res.probed = $probed

  # Only when the fast path could not look AT ALL - no COM class, no scheduler
  # service, no permission. This is the same enumeration the function used to
  # do, so the answer cannot get narrower than it was.
  if (-not $probed) {
    $now = Get-Date
    if ((-not $script:RkLegacyTaskSeenAt) -or (($now - $script:RkLegacyTaskSeenAt).TotalSeconds -ge 60)) {
      $armed = $false; $name = ''; $ok = $false
      try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop |
                         Where-Object { $_.TaskName -match 'FC8WatchdogHeartbeat' })) {
          if ($t.State -ne 'Disabled') { $armed = $true; $name = [string]$t.TaskName }
        }
        $ok = $true
      } catch { $ok = $false }
      # !! ONLY A SUCCESSFUL LOOK IS WORTH REMEMBERING. Memoising a failure
      # turns "we could not see" into "there is nothing there" and serves it
      # for the next sixty seconds - on the one question where not knowing and
      # knowing-it-is-safe must never be the same answer.
      if ($ok) {
        $script:RkLegacyTaskSeenAt = $now
        $script:RkLegacyTaskArmed  = $armed
        $script:RkLegacyTaskName   = $name
      }
      $res.probed = $ok
    } else {
      $res.probed = $true
    }
    if ($script:RkLegacyTaskArmed) { $res.taskArmed = $true; $res.taskName = [string]$script:RkLegacyTaskName }
  }
  return $res
}

function Write-RkLog {
  param(
    [Parameter(Mandatory)][string]$StateDir,
    [Parameter(Mandatory)][string]$Message,
    [string]$LogName = 'watchdog.log',
    [switch]$Quiet
  )
  $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
  if (-not $Quiet) { Write-Host $line }

  # Losing log lines silently is the worst failure mode a forensic log has: the
  # reader concludes the code never ran. Observed 2026-08-28 - two consecutive
  # lines went missing from watchdog.log because something else held the file
  # open for a moment, Add-Content threw, and the empty catch ate it. Anything
  # that reads the log while the supervisor writes it (rk-diagnose, a tail, a
  # test poller) can cause that.
  #
  # FileShare::ReadWrite plus a short retry makes an append survive a concurrent
  # reader. A line that still cannot be written after this is reported on the
  # console rather than vanishing.
  $path = Join-Path $StateDir $LogName
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`r`n")
  $lastErr = $null
  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try {
      $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
      try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush() } finally { $fs.Dispose() }
      return
    } catch {
      $lastErr = $_
      Start-Sleep -Milliseconds (20 * ($attempt + 1))
    }
  }
  Write-Host ('[respawnkeeper] WARNING: could not append to ' + $LogName + ': ' + $lastErr)
}

function Write-RkJson {
  # UTF-8 WITHOUT BOM, always. A BOM in a file another tool re-reads is a
  # recorded failure mode in this project family (TOML crash, stdin "stop").
  #
  # ATOMIC. This used to truncate the file and then write it, so every reader
  # on the machine had a window in which the file was empty or half-written -
  # Unregister-RkUiWindow measured 146 mid-write reads in 730 hand-overs, and
  # servers.json is read by every panel and every console to find its servers.
  # Now the bytes go to a sibling temp file and are swapped in with
  # File.Replace / File.Move, which the file system does as one step: a reader
  # sees the old file or the new one, never the space between. A reader that
  # holds the target open without FILE_SHARE_DELETE makes the swap throw for
  # the few ms it is open, so it is retried; if it still cannot, the old
  # truncate-and-write runs, which is no worse than before.
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Object,
    [int]$Depth = 8
  )
  #
  # !! File.Replace NEEDS A BACKUP NAME UNDER POWERSHELL 5.1. The first version
  # passed $null for the third argument; PS 5.1's method binder turns that
  # into "" and Replace throws "The path is not of a legal form" - EVERY time
  # the target already existed. So the swap never ran, the five retries burned
  # 120 ms, and the old truncate-and-write did the work under a comment
  # claiming otherwise (found by the review of [R-095], measured: 139 ms per
  # write, 0 atomic swaps). The backup is a sibling that is removed afterwards.
  #
  # The temp name carries a random part as well as the pid: two runspaces in
  # ONE process (the window and its background reader) share a $PID and were
  # colliding on the same temp file.
  #
  # $script:RkLastWriteMode says which path ran ('swap' / 'create' /
  # 'fallback') so a test can tell an atomic write from the fallback that
  # produces the same bytes.
  $json = $Object | ConvertTo-Json -Depth $Depth
  $enc  = New-Object System.Text.UTF8Encoding($false)
  $rand = [System.IO.Path]::GetRandomFileName().Replace('.', '')
  $tmp  = $Path + '.tmp-' + $PID + '-' + $rand
  $bak  = $Path + '.prev-' + $PID + '-' + $rand
  $script:RkLastWriteMode = ''
  try {
    [System.IO.File]::WriteAllText($tmp, $json, $enc)
    $done = $false
    for ($try = 0; $try -lt 5 -and -not $done; $try++) {
      try {
        if (Test-Path -LiteralPath $Path) {
          [System.IO.File]::Replace($tmp, $Path, $bak)
          $script:RkLastWriteMode = 'swap'
          try { if (Test-Path -LiteralPath $bak) { [System.IO.File]::Delete($bak) } } catch { }
        } else {
          [System.IO.File]::Move($tmp, $Path)
          $script:RkLastWriteMode = 'create'
        }
        $done = $true
      } catch {
        if ($try -ge 4) { throw }
        Start-Sleep -Milliseconds 20
      }
    }
  } catch {
    try { if (Test-Path -LiteralPath $tmp) { [System.IO.File]::Delete($tmp) } } catch { }
    try { if (Test-Path -LiteralPath $bak) { [System.IO.File]::Delete($bak) } } catch { }
    $script:RkLastWriteMode = 'fallback'
    [System.IO.File]::WriteAllText($Path, $json, $enc)
  }
}

function Read-RkJson {
  # One retry after 15 ms: a file caught mid-write (the fallback path of
  # Write-RkJson is not atomic) parses as nothing, and "nothing" is read by
  # Get-RkSupervisor as "no supervisor" - measured 47 torn reads in 30,573
  # under two writers. Fifteen milliseconds later the write is over.
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  for ($try = 0; $try -lt 2; $try++) {
    try {
      $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
      if ($raw -and $raw.Trim()) { return ($raw | ConvertFrom-Json) }
    } catch { }
    if ($try -eq 0) { Start-Sleep -Milliseconds 15 }
  }
  return $null
}

function Get-RkStamp { return (Get-Date -Format 'yyyyMMdd_HHmmss') }

# ---- Operator signals -------------------------------------------------------
# Everything outside the supervisor talks to it through FILES in the server
# folder. There is no socket and no named pipe on purpose: a file can be
# dropped by a .bat, by the panel, by the console window, by a person in
# Explorer, and it means the same thing from all of them.
#
#   STOP_SERVER       clean stop, and NOT restarted (a person meant it)
#   MAINTENANCE_NOW   the maintenance lap, now: warn -> clean stop -> read the
#                     logs -> start again. The file may hold a number, which is
#                     how many seconds of warning the players get; empty means
#                     the profile's default.
#
# A signal only means anything while a supervisor is there to read it. The
# writer therefore checks for one FIRST and says "nobody is listening" instead
# of leaving a flag on disk that the next start would silently discard - a
# button that appears to work and does nothing is worse than a disabled one.
#
# The supervisor announces itself in respawnkeeper\harness.lock ({pid, since,
# serverDir}); that file exists for the one-supervisor-per-server check and is
# written before the first launch and removed on exit, so it is the honest
# answer to "is somebody watching this folder".

$script:RkSignalNames = @{ stop = 'STOP_SERVER'; maintenance = 'MAINTENANCE_NOW' }

# The (pid + start time) memo this used to keep for "is this a respawnkeeper
# PowerShell" is now Get-RkProcessFacts, which remembers the command line
# itself, is bounded (dead pids are pruned on every write) and is shared with
# every other process on the machine through harness\.cache. One cache, not two.

function Test-RkPidRunsScript {
  # Is pid $Id a live PowerShell running the script named by $ScriptPattern?
  #
  # This is the proof a lock file cannot give on its own: the pid written into
  # one by a process that was killed can be recycled into any process at all,
  # and a wrong "alive" lights up buttons that do nothing - or, worse, stops a
  # window from opening because something else inherited the number.
  #
  # THE COMMAND LINE OF A LIVE PROCESS NEVER CHANGES, so it is asked for once
  # per (pid, start time, pattern) and remembered.
  #
  # Measured 2026-09-13 on this machine: one Win32_Process CIM query costs
  # 278-412ms, while Get-Process -Id costs 6-9ms. The console window re-derives
  # its row every two seconds ON THE UI THREAD, so that query alone held the
  # window for a quarter of a second at a time and a click landing inside it
  # waited - which is what "the close button feels slow" was ([R-085]).
  #
  # The start time is part of the key, not decoration: a recycled pid is a
  # DIFFERENT process, and it is exactly the case this function exists to catch.
  # When the start time cannot be read the answer is not cached at all - being
  # right matters more here than being quick.
  #
  # WHICH WAY AN UNREADABLE COMMAND LINE FALLS IS THE CALLER'S TO CHOOSE.
  # A command line can be unreadable for reasons that have nothing to do with
  # the process: measured 2026-09-13 on this machine, 160 of 172 processes
  # owned by other users hide theirs from a non-elevated reader, and the CIM
  # query can simply throw. The two callers want opposite answers:
  #
  #   harness.lock  - a wrong "no supervisor" lights up stop/restart buttons
  #                   that write flags nobody reads. Unreadable -> assume it IS
  #                   the supervisor. (This is the behaviour that already
  #                   existed and is not being changed.)
  #   console.lock  - a wrong "a window is open" means the supervisor NEVER
  #                   opens one again for that server, silently, with the only
  #                   trace in a log. Unreadable -> assume it is NOT the window.
  #                   The cost of being wrong that way is one extra window.
  #
  # -Strict picks the second. Fail towards the recoverable mistake.
  param(
    [Parameter(Mandatory)][int]$Id,
    [Parameter(Mandatory)][string]$ScriptPattern,
    [string]$What = 'the lock file',
    [switch]$Strict
  )
  $r = @{ ok = $false; reason = '' }
  $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
  if (-not $p) { $r.reason = ('pid ' + $Id + ' from ' + $What + ' is not running (stale lock)'); return $r }
  if (-not ($p.ProcessName -like 'powershell*' -or $p.ProcessName -like 'pwsh*')) {
    $r.reason = ('pid ' + $Id + ' is ' + $p.ProcessName + ', not PowerShell (recycled pid)'); return $r
  }
  $isIt = $null
  $facts = Get-RkProcessFacts -ProcessId $Id -NeedCommandLine
  if (-not ($facts -and $facts.cmdKnown)) {
    # !! NOT CACHED. A command line that cannot be read decides nothing, and
    # Get-RkProcessFacts does not remember a refusal either - so ONE transient
    # CIM failure cannot become a permanent wrong answer for the life of the
    # process (which is what an earlier version of this did, measured
    # 2026-09-13: ok=False, then ok=True for the rest of the session after a
    # single cached miss). The guess is re-made every time.
    $isIt = (-not $Strict)
  } else {
    $isIt = ([string]$facts.commandLine -match $ScriptPattern)
  }
  if (-not $isIt) {
    $r.reason = ('pid ' + $Id + ' is a PowerShell that is not running ' + ($ScriptPattern -replace '\\', '') + ' (recycled pid)'); return $r
  }
  $r.ok = $true
  $r.reason = ('pid ' + $Id + ' is alive and running ' + ($ScriptPattern -replace '\\', ''))
  return $r
}

function Get-RkSignalFile {
  param([Parameter(Mandatory)][string]$ServerDir,
        [Parameter(Mandatory)][ValidateSet('stop', 'maintenance')][string]$Signal)
  return (Join-Path $ServerDir $script:RkSignalNames[$Signal])
}

function Get-RkSupervisor {
  # Is a respawnkeeper supervisor alive on this server folder? Returns
  # @{ alive; pid; since; reason }. Reads harness.lock, then checks that the pid
  # is a live PowerShell whose command line names respawnkeeper.ps1 - the pid in
  # a lock file left behind by a killed supervisor can be recycled into any
  # process at all, and a wrong "alive" here would light up buttons that do
  # nothing. If the command line cannot be read (CIM refused), the name match
  # alone decides, which is the same rule the supervisor's own preflight uses.
  param([Parameter(Mandatory)][string]$ServerDir)
  $res = @{ alive = $false; pid = 0; since = ''; reason = 'no harness.lock' }
  $lock = Join-Path (Join-Path $ServerDir 'respawnkeeper') 'harness.lock'
  if (-not (Test-Path -LiteralPath $lock)) { return $res }
  $j = Read-RkJson -Path $lock
  if (-not ($j -and $j.pid)) { $res.reason = 'harness.lock has no pid'; return $res }
  $id = 0
  try { $id = [int]$j.pid } catch { $res.reason = 'harness.lock pid is not a number'; return $res }
  $res.pid = $id
  if ($j.since) { $res.since = [string]$j.since }
  $proof = Test-RkPidRunsScript -Id $id -ScriptPattern 'respawnkeeper\.ps1' -What 'harness.lock'
  if (-not $proof.ok) { $res.reason = $proof.reason; return $res }
  $res.alive  = $true
  $res.reason = ('supervisor pid ' + $id + $(if ($res.since) { ' since ' + $res.since } else { '' }))
  return $res
}

# ---- Which UI windows are already open ---------------------------------------
#
# WHY THIS EXISTS (2026-09-13). The console window used to end itself when the
# supervisor that opened it died. That was the fix for windows piling up across
# runs ([R-073]) - the supervisor keeps no handle to the window, so the window
# was the only party that could clean up without breaking that contract.
#
# It also meant that stopping the server FROM the console made the console
# vanish, taking the START button with it. So the window now OUTLIVES its
# supervisor, and the duplicate problem moves here: instead of "the window ends
# when its owner does", the rule is "a second window is never opened while a
# live one is registered". Same guarantee, and the window survives.
#
# A lock file rather than a mutex, for one reason: the reader is a DIFFERENT
# process (the supervisor, deciding whether to open a window) and the answer has
# to outlive that reader being killed. Liveness is proven the same way
# harness.lock's is - Test-RkPidRunsScript - so a stale file is worth nothing.

function Get-RkConsoleLockFile {
  param([Parameter(Mandatory)][string]$ServerDir)
  return (Join-Path (Join-Path $ServerDir 'respawnkeeper') 'console.lock')
}

function Register-RkUiWindow {
  # Claim "the window for this thing is me". $true if the claim was taken,
  # $false if somebody else's LIVE claim is already there.
  #
  # !! IT MUST NOT STEAL A LIVE CLAIM. The first version overwrote whatever was
  # there, and that broke a window nobody was even looking at - measured
  # 2026-09-13, on Eva's own desktop:
  #
  #   her panel was open and registered. A second panel was started (a test, but
  #   double-clicking respawnkeeper.exe twice does the same thing). It
  #   overwrote panel.lock with its own pid, and when IT closed, Unregister saw
  #   its own pid in the file and deleted it - releasing a claim that belonged
  #   to a window still on screen. From then on "back to the list" in the
  #   console would have opened a SECOND panel beside her open one, which is
  #   exactly the duplicate this whole mechanism exists to prevent.
  #
  # So a second window opens - rk-console.ps1's own header promises that two can
  # be open at once, and a person double-clicking a shortcut twice is not an
  # error - it just does not become the registered one. Which is right: the
  # promise being kept is "the SUPERVISOR never opens a second window", and the
  # supervisor asks the registration, not the desktop.
  #
  # Never throws: a window that cannot write its lock must still open. The cost
  # of failing here is a duplicate window later; the cost of throwing is no
  # window at all.
  #
  # $ScriptPattern is what makes the incumbent provable. Without it the check is
  # skipped, because "there is a file" is not evidence of anything - see
  # Get-RkUiWindow.
  #
  # RACE: two windows registering in the same instant can both pass the check
  # and the file ends up naming whichever wrote last. The loser's Unregister
  # then does nothing (the file does not name it), so the claim is still
  # released by a live window, and the worst outcome is one extra window. No
  # path here can leave a server unwatched, which is why it is not worth a
  # mutex.
  param(
    [Parameter(Mandatory)][string]$LockFile,
    [string]$ScriptPattern = ''
  )
  try {
    $dir = Split-Path -Parent $LockFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    if ($ScriptPattern) {
      $held = Get-RkUiWindow -LockFile $LockFile -ScriptPattern $ScriptPattern
      if ($held.alive -and ($held.pid -ne $PID)) { return $false }
    }
    Write-RkJson -Path $LockFile -Object ([ordered]@{
      schema = 'respawnkeeper/uiwindow/1'
      pid    = $PID
      since  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    return $true
  } catch { return $false }
}

function Unregister-RkUiWindow {
  # Removes the registration ONLY if it is still ours. Two windows can exist for
  # a moment - one closing, one already opened - and a blind delete would let the
  # one on its way out take the new one's claim with it.
  param([Parameter(Mandatory)][string]$LockFile)
  try {
    # !! DELETE ONLY ON POSITIVE PROOF THAT IT IS OURS.
    # This used to fall through to the delete whenever the file could not be
    # parsed - unreadable, empty, or read mid-write, since Write-RkJson
    # truncates before it writes. Measured 2026-09-13 under contention: a
    # closing window destroyed a DIFFERENT live window's claim 146 times out of
    # 730 hand-overs. Leaving an unparseable file behind costs nothing:
    # Get-RkUiWindow reads a file with no pid as "no window", so it blocks
    # nobody.
    if (-not (Test-Path -LiteralPath $LockFile)) { return }
    $mine = $false
    $j = Read-RkJson -Path $LockFile
    if ($j -and $j.pid) { try { $mine = ([int]$j.pid -eq $PID) } catch { $mine = $false } }
    if (-not $mine) { return }
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
  } catch { }
}

function Get-RkUiWindow {
  # Is a window of this kind already open? @{ alive; pid; since; reason }.
  param(
    [Parameter(Mandatory)][string]$LockFile,
    [Parameter(Mandatory)][string]$ScriptPattern
  )
  $leaf = Split-Path -Leaf $LockFile
  $res = @{ alive = $false; pid = 0; since = ''; reason = ('no ' + $leaf) }
  if (-not (Test-Path -LiteralPath $LockFile)) { return $res }
  $j = Read-RkJson -Path $LockFile
  if (-not ($j -and $j.pid)) { $res.reason = ($leaf + ' has no pid'); return $res }
  $id = 0
  try { $id = [int]$j.pid } catch { $res.reason = ($leaf + ' pid is not a number'); return $res }
  $res.pid = $id
  if ($j.since) { $res.since = [string]$j.since }
  $proof = Test-RkPidRunsScript -Id $id -ScriptPattern $ScriptPattern -What $leaf -Strict
  if (-not $proof.ok) { $res.reason = $proof.reason; return $res }
  $res.alive  = $true
  # The PATH, not just the pid. When this answer is wrong the symptom is a
  # window that never opens again, and the only cure is deleting a file whose
  # name nobody has been told. A reason that names it turns an incident into a
  # thing Eva can fix.
  $res.reason = ('window pid ' + $id + $(if ($res.since) { ' since ' + $res.since } else { '' }) + ' [' + $LockFile + ']')
  return $res
}

function Get-RkConsoleWindow {
  # The console window FOR THIS SERVER, if one is open.
  #
  # !! THE SERVER DIRECTORY IS PART OF THE IDENTITY. Matching only the script
  # name meant any live console window satisfied EVERY server's lock file -
  # measured 2026-09-13: a console for server B validated server A's stale
  # lock, so server A would never be given a window again. rk-console.ps1 is
  # always launched with -ServerDir on its command line (the supervisor and the
  # panel both pass it), so the folder is right there to check, and the live
  # test was already checking it while the product was not.
  param([Parameter(Mandatory)][string]$ServerDir)
  $pat = 'rk-console\.ps1.*' + [regex]::Escape($ServerDir.TrimEnd('\'))
  return (Get-RkUiWindow -LockFile (Get-RkConsoleLockFile -ServerDir $ServerDir) -ScriptPattern $pat)
}

function Get-RkPendingSignals {
  # Which signals have been written and not yet picked up. The supervisor
  # deletes a flag the moment it reads it (within one 500ms pass), so a flag
  # that is still there either landed a moment ago or has nobody to read it.
  param([Parameter(Mandatory)][string]$ServerDir)
  $out = @()
  foreach ($k in @('stop', 'maintenance')) {
    if (Test-Path -LiteralPath (Get-RkSignalFile -ServerDir $ServerDir -Signal $k)) { $out += $k }
  }
  return $out
}

function Request-RkSignal {
  # Ask the supervisor for a stop or a maintenance restart. Returns
  # @{ ok; reason; file; supervisor }. Never starts anything, never touches the
  # server process: the supervisor does the work, this only asks.
  #   -WarnSeconds  (maintenance only) seconds of warning before the stop.
  #                 Omit for the profile's default. 0 = stop immediately.
  param([Parameter(Mandatory)][string]$ServerDir,
        [Parameter(Mandatory)][ValidateSet('stop', 'maintenance')][string]$Signal,
        [int]$WarnSeconds = -1)
  $sup = Get-RkSupervisor -ServerDir $ServerDir
  $file = Get-RkSignalFile -ServerDir $ServerDir -Signal $Signal
  if (-not $sup.alive) {
    return @{ ok = $false; reason = 'unsupervised'; detail = $sup.reason; file = $file; supervisor = $sup }
  }
  $body = ''
  if ($Signal -eq 'maintenance' -and $WarnSeconds -ge 0) { $body = [string]$WarnSeconds }
  try {
    # ASCII, no BOM, no newline: the supervisor parses the body as an integer
    # and a BOM in front of "0" is not "0".
    [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.ASCIIEncoding))
  } catch {
    return @{ ok = $false; reason = 'write-failed'; detail = $_.Exception.Message; file = $file; supervisor = $sup }
  }
  return @{ ok = $true; reason = 'sent'; detail = $sup.reason; file = $file; supervisor = $sup }
}

function Invoke-RkMaintenanceHook {
  # Run one command WHILE THE SERVER IS DOWN, inside the daily maintenance
  # window, and report what it said.
  #
  # WHY THE WINDOW (2026-09-07):
  #   A Fish Trap grew an ItemStack to count=102 and killed the world tick.
  #   Nothing about it reached any log before the crash - the count went
  #   65, 66, ... 99 in silence - so no amount of log reading would have found
  #   it in advance. Only opening the world files finds that class of fault,
  #   and the only moment they are quiet is while the server is stopped. The
  #   maintenance window is already exactly that moment, every day, for free.
  #
  # TWO RULES, both non-negotiable:
  #   1. This can NEVER keep the server down. A health check that costs
  #      availability has inverted its own purpose. Every failure path here
  #      ends in a returned object - never a throw, and never a branch the
  #      caller could read as "do not restart".
  #   2. It is bounded. An unbounded hook is a hang with extra steps, and this
  #      harness already has one hang detector too many.
  #
  # Exit code convention (what the caller reads):
  #   0 = proved healthy, 1 = worth a look, 2+ = something is wrong.
  # A hook that does not follow it simply reports its own number; nothing here
  # invents a meaning for it.
  param(
    [string]$Command,
    [int]$TimeoutMin = 15,
    [string]$WorkingDir = '',
    [string]$ReportDir = ''
  )

  $res = [ordered]@{
    ran = $false; exitCode = $null; timedOut = $false
    verdict = 'SKIPPED'; seconds = 0.0; log = ''; errLog = ''
    highlights = @(); error = ''
  }
  if ([string]::IsNullOrWhiteSpace($Command)) { return [pscustomobject]$res }
  if ($TimeoutMin -le 0) { $TimeoutMin = 15 }

  if (-not $ReportDir) { $ReportDir = $env:TEMP }
  if (-not (Test-Path -LiteralPath $ReportDir)) {
    try { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
    catch { $ReportDir = $env:TEMP }
  }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $res.log    = Join-Path $ReportDir ('hook-' + $stamp + '.log')
  $res.errLog = Join-Path $ReportDir ('hook-' + $stamp + '.err')
  if (-not $WorkingDir -or -not (Test-Path -LiteralPath $WorkingDir)) {
    $WorkingDir = $ReportDir
  }

  # Deliberately NOT Start-Process -PassThru: on PS 5.1 the object it hands
  # back does not carry ExitCode unless -Wait was used, so every run graded
  # UNKNOWN. And -Wait has no timeout, which is the one thing this must have.
  # A raw Process gives both. Redirection is done by cmd itself rather than by
  # .NET, so there are no pipes to drain and no deadlock when a chatty check
  # fills the buffer.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $env:ComSpec
  $psi.Arguments = '/c ' + $Command + ' 1>"' + $res.log + '" 2>"' + $res.errLog + '"'
  $psi.WorkingDirectory = $WorkingDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $started = Get-Date
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try {
    if (-not $p.Start()) { throw 'the process did not start' }
  } catch {
    $res.verdict = 'START_FAILED'
    $res.error = $_.Exception.Message
    return [pscustomobject]$res
  }
  $res.ran = $true

  if (-not $p.WaitForExit($TimeoutMin * 60 * 1000)) {
    # The hook is the thing that is stuck, so the hook is the thing that dies.
    # This is the only process this function may end, and it is one we started
    # ourselves a moment ago. It is never the server.
    try { $p.Kill() } catch { }
    $res.timedOut = $true
    $res.verdict = 'TIMEOUT'
    $res.seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    return [pscustomobject]$res
  }

  try { $res.exitCode = $p.ExitCode } catch { $res.exitCode = $null }
  $res.seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
  if ($null -eq $res.exitCode) {
    $res.verdict = 'UNKNOWN'
  } else {
    $res.verdict = switch ([int]$res.exitCode) { 0 { 'PASS' } 1 { 'WARN' } default { 'FAIL' } }
  }
  try {
    $res.highlights = @(Get-Content -LiteralPath $res.log -TotalCount 200 -ErrorAction Stop |
                        Where-Object { $_ -match '\|\s*(WARN|FAIL)\s*\|' })
  } catch { }
  return [pscustomobject]$res
}


# ---- Game templates ---------------------------------------------------------
# Loaded last: rk-games.ps1 calls Get-RkLoader / Resolve-RkJava from this file
# at RUN time, so the order only matters for definitions, not for use. Dot-
# sourcing it here means every script that loads rk-common gets both halves and
# nobody has to remember two include lines.
. (Join-Path $PSScriptRoot 'rk-games.ps1')
. (Join-Path $PSScriptRoot 'rk-modgraph.ps1')
