# ============================================================
# rk-async.ps1 - one background read at a time, picked up by a timer.
# ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS FILE EXISTS. The panel moved its four-second read off the dispatcher
# thread in [R-091] and the freeze went away there. The console window kept
# reading on its own dispatcher thread every two seconds - Get-RkPanelRow at
# 1.4 to 3.5 s per call, measured 2026-09-13 - and that is the window Eva was
# looking at when she said it "still freezes a little". Two windows, one
# pattern, so the mechanics live here once and both windows call them. The
# rationale for each rule below was written in rk-panel.ps1 first; it is kept
# there, next to the code that learned it.
#
# THE SHAPE
#   $g = New-RkGather -Name 'rows'
#   if (Start-RkGather -Gather $g -Script {...} -Arguments @(...)) { ... }
#   $r = Complete-RkGather -Gather $g -Pick { param($out) ... }   # on a timer
#   switch ($r.state) { 'done' {...} 'failed' {...} 'timeout' {...} }
#   Close-RkGather -Gather $g                                       # on Closed
#
# RULES THAT ARE NOT OPTIONAL
#   - the script gets NOTHING by closure: AddScript re-parses it in the other
#     runspace, so every input is an explicit argument
#   - the script may touch no WPF object; it returns plain data
#   - one gather per handle is in flight at a time
#   - the runspace is REUSED (dot-sourced state and caches survive) and is
#     rebuilt only after a failure
#   - Close never calls PowerShell.Dispose(): that WAITS for the pipeline, and
#     inside a native child it waits for the child (28,468 ms measured, on the
#     dispatcher thread, no exception). CloseAsync only.
#   - a deadline, because a wedged read with no deadline is a window that keeps
#     drawing pre-hang data while looking perfectly alive
# ============================================================

function New-RkGather {
  param([string]$Name = 'gather', [int]$DeadlineSec = 60)
  return [pscustomobject]@{
    Name     = $Name
    Runspace = $null
    Ps       = $null
    Handle   = $null
    Started  = [datetime]::MinValue
    Fails    = 0
    LastErr  = ''
    Deadline = $DeadlineSec
  }
}

function Start-RkGather {
  # $true if a read is now in flight (or already was). $false if it could not
  # be started - Fails is incremented and LastErr says why.
  param(
    [Parameter(Mandatory)]$Gather,
    [Parameter(Mandatory)][scriptblock]$Script,
    [object[]]$Arguments = @()
  )
  if ($Gather.Handle) { return $true }
  $ps = $null
  try {
    if (-not $Gather.Runspace) {
      $rs = [runspacefactory]::CreateRunspace()
      # MTA on purpose: nothing in here may touch a window, and saying so in
      # the apartment model is cheaper than trusting a comment.
      $rs.ApartmentState = 'MTA'
      $rs.ThreadOptions  = 'ReuseThread'
      $rs.Open()
      $Gather.Runspace = $rs
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $Gather.Runspace
    [void]$ps.AddScript($Script.ToString())
    foreach ($a in @($Arguments)) { [void]$ps.AddArgument($a) }
    $Gather.Ps      = $ps
    $Gather.Started = Get-Date
    $Gather.Handle  = $ps.BeginInvoke()
    return $true
  } catch {
    # BeginInvoke on a runspace that will not open throws SYNCHRONOUSLY, into
    # here. The runspace is dropped so the next attempt builds a fresh one, and
    # Started is set regardless so a caller's cadence gate still closes.
    $Gather.LastErr = $_.Exception.Message
    try { if ($ps) { $ps.Dispose() } } catch { }
    try { if ($Gather.Runspace) { $Gather.Runspace.Dispose() } } catch { }
    $Gather.Runspace = $null
    $Gather.Ps       = $null
    $Gather.Handle   = $null
    $Gather.Started  = Get-Date
    $Gather.Fails++
    return $false
  }
}

function Test-RkGatherBusy {
  param([Parameter(Mandatory)]$Gather)
  return [bool]$Gather.Handle
}

function Complete-RkGather {
  # @{ state = 'idle' | 'running' | 'done' | 'failed' | 'timeout'; data; why }
  # -Pick chooses the result out of everything the script emitted (dot-sourcing
  # a model file emits nothing today, but "the last thing that came out" is not
  # a contract). It receives the output array and returns the object or $null.
  param(
    [Parameter(Mandatory)]$Gather,
    [Parameter(Mandatory)][scriptblock]$Pick
  )
  if (-not $Gather.Handle) { return @{ state = 'idle'; data = $null; why = '' } }

  if (-not $Gather.Handle.IsCompleted) {
    if (((Get-Date) - $Gather.Started).TotalSeconds -ge $Gather.Deadline) {
      # NOT COMING BACK. BeginStop, not Stop: Stop waits for the pipeline, and
      # what it would be waiting for is the thing that is stuck.
      try { [void]$Gather.Ps.BeginStop($null, $null) } catch { }
      try { if ($Gather.Runspace) { $Gather.Runspace.CloseAsync() } } catch { }
      $Gather.Runspace = $null     # a fresh one next time; the old one is wedged
      $Gather.Ps       = $null
      $Gather.Handle   = $null
      $Gather.Fails++
      $Gather.LastErr  = 'timed out after ' + $Gather.Deadline + ' s'
      return @{ state = 'timeout'; data = $null; why = $Gather.LastErr }
    }
    return @{ state = 'running'; data = $null; why = '' }
  }

  $data = $null
  $why  = ''
  try {
    $out = @($Gather.Ps.EndInvoke($Gather.Handle))
    $data = & $Pick $out
  } catch { $data = $null; $why = $_.Exception.Message }
  # Three layers used to drop the reason (EndInvoke's catch, the runspace error
  # stream, the result's own error list); the first two are read here, the
  # third is the caller's, inside its data.
  if ((-not $why) -and $Gather.Ps -and ($Gather.Ps.Streams.Error.Count -gt 0)) {
    $why = [string]$Gather.Ps.Streams.Error[0]
  }
  # Dispose is safe HERE: the pipeline has completed, so there is nothing for
  # it to wait on.
  try { $Gather.Ps.Dispose() } catch { }
  $Gather.Ps     = $null
  $Gather.Handle = $null

  if ($null -ne $data) {
    $Gather.Fails   = 0
    $Gather.LastErr = ''
    return @{ state = 'done'; data = $data; why = $why }
  }
  if (-not $why) { $why = 'the read produced no result' }
  $Gather.Fails++
  $Gather.LastErr = $why
  return @{ state = 'failed'; data = $null; why = $why }
}

function Reset-RkGather {
  # Throw the runspace away (asynchronously) so the next Start builds a new
  # one. For "three failures in a row" callers.
  param([Parameter(Mandatory)]$Gather)
  try { if ($Gather.Runspace) { $Gather.Runspace.CloseAsync() } } catch { }
  $Gather.Runspace = $null
  $Gather.Ps       = $null
  $Gather.Handle   = $null
  $Gather.Fails    = 0     # a fresh runspace starts with a clean count
}

function Close-RkGather {
  # For the window's Closed handler. NOTHING HERE MAY BLOCK.
  param([Parameter(Mandatory)]$Gather)
  try { if ($Gather.Runspace) { $Gather.Runspace.CloseAsync() } } catch { }
  $Gather.Ps       = $null
  $Gather.Handle   = $null
  $Gather.Runspace = $null
}
