<#
.SYNOPSIS
    Reconcile the desktop layout toward a layout file. Idempotent.

.DESCRIPTION
    Entry point. All the work lives in the DevEnv module under .\lib.

    RECONCILE, NOT REPLAY. Per entry it counts what is already in place,
    launches only the shortfall, then positions. Running it twice does nothing
    the second time.

    WHY IT WALKS DESKTOPS. New windows are always created on the ACTIVE virtual
    desktop and Windows offers no supported way to move another process's
    window between desktops. So it steps to a desktop, launches there,
    positions, and moves on. A desktop already correct is never visited.

    SAFETY
      * Dry run by default. Only -Apply changes anything.
      * Nothing is ever closed, killed or minimized. Unclaimed windows are
        reported as surplus and left alone.
      * Desktops marked IntentionallyEmpty are never filled or flagged.
      * Apps with Policy 'place' are positioned but never launched.
      * Only writes logs under <Root>\logs.

.PARAMETER Apply
    Launch and move for real.

.PARAMETER Rehearse
    Walk each desktop showing what it WOULD do, paced by you with Next/Stop.
    Changes nothing.

.PARAMETER Desktop
    Limit to desktops by name or index, e.g. -Desktop Main,Gaming

.EXAMPLE
    .\Restore-DevEnv.ps1
    Preview. Prints a plan per desktop.

.EXAMPLE
    .\Restore-DevEnv.ps1 -Rehearse
    Walk the desktops and show the plan on each, changing nothing.

.EXAMPLE
    .\Restore-DevEnv.ps1 -Apply
    Do it.

.NOTES
    Windows PowerShell 5.1. Run non-elevated.
    Cursor needs window.restoreWindows = "none", or it reopens its own windows
    onto one desktop and you end up with duplicates.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]   $Root,
    [string]   $ManifestPath,
    [switch]   $Apply,
    [switch]   $Rehearse,
    [string[]] $Desktop,
    [switch]   $SkipGlobal,
    [switch]   $NoUi
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# --- paths ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    # One config per machine, named for it, so a single folder serves them all.
    # layout.psd1 is the fallback for a folder that only ever lives on one box.
    $ManifestPath = Join-Path $Root ('layout.{0}.psd1' -f $env:COMPUTERNAME)
    if (-not (Test-Path -LiteralPath $ManifestPath)) { $ManifestPath = Join-Path $Root 'layout.psd1' }
}
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Host ("No layout for {0}: {1}" -f $env:COMPUTERNAME, $ManifestPath) -ForegroundColor Red
    Write-Host 'Arrange your desktops, then run Generate.ps1 to capture one.' -ForegroundColor Yellow
    exit 1
}

. (Join-Path $PSScriptRoot 'DevEnv.ps1')

# --- logging ----------------------------------------------------------------
$logDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir ('restore-{0}-{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$script:Changes = 0

function Log {
    param([string] $Message, [string] $Level = 'INFO')
    Add-Content -LiteralPath $logPath -Encoding UTF8 `
        -Value ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)
    $colour = switch ($Level) {
        'WARN'  { 'Yellow' } 'ERROR' { 'Red' } 'DO' { 'Green' }
        'PLAN'  { 'Cyan' }   'HEAD'  { 'White' } default { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $colour
}
$warn = { param($m) Log ('      ' + $m) 'WARN' }

# A bare 'throw' inside a trap raises a generic ScriptHalted and loses the
# real error, so log it and re-throw the original record explicitly.
trap {
    Close-DevEnvStatus
    try {
        Log ("FAILED: {0}" -f $_.Exception.Message) 'ERROR'
        Log ("  at {0}" -f $_.InvocationInfo.PositionMessage) 'ERROR'
    } catch { }
    throw $_
}

# --- preflight --------------------------------------------------------------
$interop = Test-DevEnvInterop
if (-not $interop.Available) {
    Log ("IVirtualDesktopManager unavailable: {0}" -f $interop.Error) 'ERROR'
    exit 1
}

$mode = if ($Apply) { 'APPLY' } elseif ($Rehearse) { 'REHEARSAL' } else { 'DRY RUN' }
Log ("=== Restore-DevEnv [{0}] ===" -f $mode) 'HEAD'
Log ("layout : {0}" -f $ManifestPath)
Log ("log    : {0}" -f $logPath)
Log ''

$config  = Import-DevEnvConfig -Path $ManifestPath
if ($config.Machine -and $config.Machine -ne $env:COMPUTERNAME) {
    Log ("this layout was captured on '{0}', you are on '{1}'" -f $config.Machine, $env:COMPUTERNAME) 'WARN'
    Log 'Monitors and virtual desktops are unlikely to match. Run Generate.ps1 here instead.' 'WARN'
    Log ''
}

$timing  = Get-DevEnvTiming -Config $config
$monitors = Resolve-DevEnvMonitor -Config $config -OnWarning $warn

foreach ($k in ($monitors.Keys | Sort-Object)) {
    $m = $monitors[$k]
    Log ("monitor {0} -> {1}  {2}x{3}  work {4}x{5} @{6},{7}  grid {8}x{9}  via {10}" -f `
        $m.Key, $m.DeviceName, $m.Width, $m.Height, `
        $m.WorkWidth, $m.WorkHeight, $m.WorkX, $m.WorkY, $m.Cols, $m.Rows, $m.MatchedBy)
}
if ($monitors.Count -eq 0) { Log 'No monitors matched. Nothing to do.' 'ERROR'; return }

$order = @(Get-DevEnvDesktopOrder)
if ($order.Count -eq 0) { Log 'Could not read the virtual desktop order.' 'ERROR'; return }
Log ("{0} virtual desktop(s)" -f $order.Count)

# --- map the config's desktops onto this machine's ---------------------------
# Virtual desktop GUIDs are generated per machine, so a config carried from
# somewhere else matches none of them. Fall back to position: desktop 3 there
# becomes desktop 3 here. Desktops with no counterpart are dropped, because
# there is nowhere to put their windows.
$liveById = @{}
foreach ($o in $order) { $liveById[([string]$o.Id).ToUpperInvariant()] = $o }

$keep = @()
foreach ($d in @($config.Desktops)) {
    $cid = ([string]$d.Id).ToUpperInvariant()
    if ($liveById.ContainsKey($cid)) { $keep += $d; continue }

    $byIndex = $order | Where-Object { $_.Index -eq [int]$d.Index } | Select-Object -First 1
    if ($byIndex) {
        Log ("desktop [{0}] '{1}' is not on this machine; using position {0}, '{2}'" -f `
            $d.Index, $d.Name, $byIndex.Name) 'WARN'
        $d.Id = $byIndex.Id
        $keep += $d
    } else {
        Log ("desktop [{0}] '{1}' has no counterpart here - skipped. Create {2} virtual desktops to restore it." -f `
            $d.Index, $d.Name, $d.Index) 'WARN'
    }
}
$config.Desktops = @($keep)
if ($config.Desktops.Count -eq 0) { Log 'None of the configured desktops exist here.' 'ERROR'; return }

# Transient system windows that are never layout. The same on every machine,
# so it lives here rather than being copied into each generated config; a
# config may still add to it.
$ignore = @(
    'TextInputHost.exe'
    'ApplicationFrameHost.exe'
    'SystemSettings.exe'
    'explorer.exe:Program Manager'
) + @($config.IgnoreProcesses)
$entries = @(Expand-DevEnvConfig -Config $config -MonitorMap $monitors `
                -DesktopFilter $Desktop -SkipGlobal:$SkipGlobal -OnWarning $warn)
if ($entries.Count -eq 0) { Log 'Layout defines nothing for the selected desktops.' 'WARN'; return }

$windows = @(Get-DevEnvWindow -IgnoreProcess $ignore)
Log ("{0} candidate window(s)" -f $windows.Count)
Log ''

Join-DevEnvWindow -Entries $entries -Windows $windows

# --- plan -------------------------------------------------------------------
function Format-Entry {
    param($Entry, [string] $Verdict)
    $zone = if ($Entry.Region) { $Entry.Region } else { $Entry.Monitor }
    $proj = if ($Entry.Project) { '  ~' + $Entry.Project } else { '' }
    '{0,-8} {1,-20} {2,-12} {3},{4} {5}x{6}{7}' -f `
        $Verdict, $Entry.Process, $zone, $Entry.X, $Entry.Y, $Entry.Width, $Entry.Height, $proj
}

Log '--- PLAN -------------------------------------------------------------' 'PLAN'
foreach ($d in @($config.Desktops)) {
    if ($Desktop -and -not (($Desktop -contains [string]$d.Name) -or ($Desktop -contains [string]$d.Index))) { continue }
    if ($d.IntentionallyEmpty) {
        Log ("[{0}] {1,-12} intentionally empty - skipped" -f $d.Index, $d.Name) 'PLAN'
        continue
    }
    $mine = @($entries | Where-Object { $_.Scope -eq 'desktop' -and $_.DesktopIndex -eq [int]$d.Index })
    if ($mine.Count -eq 0) { continue }

    $verdicts = @{}
    foreach ($e in $mine) { $verdicts[$e] = Get-DevEnvVerdict -Entry $e }
    $nLaunch = @($mine | Where-Object { $verdicts[$_] -eq 'launch' }).Count
    $nMove   = @($mine | Where-Object { $verdicts[$_] -eq 'move' }).Count

    Log ("[{0}] {1,-12} {2} window(s)   launch {3}   move {4}" -f $d.Index, $d.Name, $mine.Count, $nLaunch, $nMove) 'PLAN'
    foreach ($e in $mine) { Log ('      ' + (Format-Entry -Entry $e -Verdict $verdicts[$e])) 'PLAN' }
}
foreach ($e in @($entries | Where-Object { $_.Scope -eq 'global' })) {
    Log ('[-] global   ' + (Format-Entry -Entry $e -Verdict (Get-DevEnvVerdict -Entry $e))) 'PLAN'
}

$surplus = @(Get-DevEnvSurplus -Windows $windows -Entries $entries)
if ($surplus.Count -gt 0 -and -not $Desktop) {
    # Located, not just counted: a window you cannot find is a window you
    # cannot tidy. Desktop name comes from the config's own GUID map.
    $deskName = @{}
    foreach ($d in $config.Desktops) { $deskName[([string]$d.Id).ToUpperInvariant()] = ('[{0}] {1}' -f $d.Index, $d.Name) }
    Log ''
    Log ("surplus (left alone, never closed): {0}" -f $surplus.Count) 'WARN'
    foreach ($s in ($surplus | Sort-Object Process, FrameY, FrameX)) {
        $where = $deskName[([string]$s.DesktopId).ToUpperInvariant()]
        if (-not $where) { $where = '[?]' }
        $title = [string]$s.Title
        if ($title.Length -gt 40) { $title = $title.Substring(0, 37) + '...' }
        Log ("      {0,-20} {1,-14} {2},{3} {4}x{5}  {6}" -f `
            $s.Process, $where, $s.FrameX, $s.FrameY, $s.FrameWidth, $s.FrameHeight, $title) 'WARN'
    }
}
Log ''

if (-not $Apply -and -not $Rehearse) {
    Log 'DRY RUN - nothing changed. Add -Rehearse to walk it, or -Apply to execute.' 'PLAN'
    Log ("log: {0}" -f $logPath)
    return
}

# --- walk -------------------------------------------------------------------
$banner = ("--- {0} " -f $mode).PadRight(70, '-')
Log $banner $(if ($Rehearse) { 'PLAN' } else { 'DO' })
Log 'Keep hands off the keyboard: desktop navigation uses Win+Ctrl+Arrow.' 'WARN'
Log ''

New-DevEnvStatus -Rehearsal:$Rehearse -Disabled:$NoUi
if ($Rehearse) { Set-DevEnvStatus -Step 'rehearsal - nothing will be changed' }

# Desktops worth visiting: the ones that actually produced entries. Asking the
# raw config instead would be wrong -- a desktop can get its windows from a
# layout template and have no Windows key at all.
$hasEntries = @{}
foreach ($e in $entries) { if ($e.Scope -eq 'desktop') { $hasEntries[[int]$e.DesktopIndex] = $true } }

$touched = @($config.Desktops | Where-Object {
    -not $_.IntentionallyEmpty -and $hasEntries.ContainsKey([int]$_.Index) -and
    (-not $Desktop -or ($Desktop -contains [string]$_.Name) -or ($Desktop -contains [string]$_.Index))
})
Initialize-DevEnvStatusPlan -Desktops $touched

$stopped = $false
foreach ($d in $touched) {
    if ($stopped) { break }
    $did  = ([string]$d.Id).ToUpperInvariant()
    $mine = @($entries | Where-Object { $_.Scope -eq 'desktop' -and $_.DesktopIndex -eq [int]$d.Index })

    $toLaunch = @($mine | Where-Object { (Get-DevEnvVerdict -Entry $_) -eq 'launch' })
    $toMove   = @($mine | Where-Object { (Get-DevEnvVerdict -Entry $_) -eq 'move' })
    foreach ($e in @($mine | Where-Object { (Get-DevEnvVerdict -Entry $_) -eq 'missing' })) {
        Log ("[{0}] {1}: {2} missing, Policy=place - not launching" -f $d.Index, $d.Name, $e.Process) 'WARN'
    }

    if (-not $Rehearse -and $toLaunch.Count -eq 0 -and $toMove.Count -eq 0) {
        Log ("[{0}] {1,-12} already correct" -f $d.Index, $d.Name)
        Set-DevEnvStatusDesktop -Index ([int]$d.Index) -State 'done'
        continue
    }

    Set-DevEnvStatusDesktop -Index ([int]$d.Index) -State 'active'
    Set-DevEnvStatus -Hint 'switching desktop...'
    Log ("[{0}] {1,-12} switching..." -f $d.Index, $d.Name) $(if ($Rehearse) { 'PLAN' } else { 'DO' })

    if (-not (Switch-DevEnvDesktop -TargetId $did -TimeoutMs $timing.SwitchTimeoutMs -OnWarning $warn)) {
        Log ("      could not reach '{0}' - skipping it" -f $d.Name) 'ERROR'
        continue
    }
    Start-Sleep -Milliseconds $timing.SettleMs
    Move-DevEnvStatus -DesktopId $did

    if ($Rehearse) {
        $lines = @($mine | ForEach-Object { Format-Entry -Entry $_ -Verdict (Get-DevEnvVerdict -Entry $_) })
        if ($lines.Count -eq 0) { $lines = @('(nothing defined here)') }
        Set-DevEnvStatusRehearsal -Lines $lines
        foreach ($l in $lines) { Log ('      would: ' + $l) 'PLAN' }

        if (-not (Wait-DevEnvStatusStep)) { Log 'stopped by user' 'WARN'; $stopped = $true }
        Set-DevEnvStatusDesktop -Index ([int]$d.Index) -State 'done'
        continue
    }

    foreach ($e in $toLaunch) {
        $what = if ($e.Project) { ' -> ' + $e.Project } else { '' }
        Log ("      launch {0}{1}" -f $e.Process, $what) 'DO'
        Set-DevEnvStatus -Hint ("launching {0}" -f $e.Process)
        $w = Start-DevEnvWindow -Entry $e -IgnoreProcess $ignore -OnWarning $warn
        if ($w) { $e.Window = $w; $windows += $w; $script:Changes++ }
    }

    foreach ($e in @($mine | Where-Object { $_.Window -and -not $_.NoPosition })) {
        if (Test-DevEnvWindowPlaced -Window $e.Window -Target $e) { continue }
        Set-DevEnvStatus -Hint ("positioning {0}" -f $e.Process)
        if (Set-DevEnvWindowFrame -Window $e.Window -Target $e -SettleMs $timing.SettleMs) {
            Log ("      moved  {0,-20} -> {1},{2} {3}x{4}" -f $e.Process, $e.X, $e.Y, $e.Width, $e.Height) 'DO'
            $script:Changes++
        } else {
            Log ("      REFUSED {0,-20} (elevated, or the app overrode the move)" -f $e.Process) 'WARN'
        }
    }

    Set-DevEnvStatusDesktop -Index ([int]$d.Index) -State 'done'
}

# --- globals ----------------------------------------------------------------
foreach ($e in @($entries | Where-Object { $_.Scope -eq 'global' })) {
    $v = Get-DevEnvVerdict -Entry $e
    if ($Rehearse) { Log ("[-] global would: {0} {1}" -f $v, $e.Process) 'PLAN'; continue }

    if ($v -eq 'launch') {
        Log ("[-] global: launch {0}" -f $e.Process) 'DO'
        Set-DevEnvStatus -Hint ("launching {0}" -f $e.Process)
        $w = Start-DevEnvWindow -Entry $e -IgnoreProcess $ignore -OnWarning $warn
        if ($w) { $e.Window = $w; $script:Changes++ }
    }
    if ($e.Window -and -not $e.NoPosition -and -not (Test-DevEnvWindowPlaced -Window $e.Window -Target $e)) {
        if (Set-DevEnvWindowFrame -Window $e.Window -Target $e -SettleMs $timing.SettleMs) {
            Log ("[-] global: moved {0}" -f $e.Process) 'DO'; $script:Changes++
        } else {
            Log ("[-] global: REFUSED {0}" -f $e.Process) 'WARN'
        }
    }
}

# --- re-assert --------------------------------------------------------------
if (-not $Rehearse) {
    $n = Invoke-DevEnvReassert -Entries $entries `
            -DelayMs $timing.ReassertDelayMs -Rounds $timing.ReassertRounds -SettleMs $timing.SettleMs `
            -OnRound  { param($r,$t) Set-DevEnvStatus -Step 'verifying positions' -Hint ("settling, round {0} of {1}" -f $r, $t) } `
            -OnFixed  { param($e) Log ("      re-asserted {0,-20} -> {1},{2}" -f $e.Process, $e.X, $e.Y) 'DO' } `
            -OnWarning $warn
    $script:Changes += $n
    if ($n -gt 0) { Log ("{0} window(s) had to be re-asserted" -f $n) 'WARN' }
}

# --- home -------------------------------------------------------------------
$homeIndex = if ($config.ReturnToDesktopIndex) { [int]$config.ReturnToDesktopIndex } else { 0 }
if ($homeIndex -gt 0) {
    # Not $home -- that is a PowerShell automatic variable.
    $homeDesk = @($order | Where-Object { $_.Index -eq $homeIndex } | Select-Object -First 1)
    if ($homeDesk.Count -gt 0) {
        Log ''
        Log ("returning to desktop {0} ({1})" -f $homeIndex, $homeDesk[0].Name) 'DO'
        Set-DevEnvStatus -Hint ("returning to {0}" -f $homeDesk[0].Name)
        [void](Switch-DevEnvDesktop -TargetId $homeDesk[0].Id -TimeoutMs $timing.SwitchTimeoutMs -OnWarning $warn)
        Move-DevEnvStatus -DesktopId $homeDesk[0].Id
    }
}

Log ''
Log ("done. {0} change(s). log: {1}" -f $script:Changes, $logPath) $(if ($Rehearse) { 'PLAN' } else { 'DO' })
Complete-DevEnvStatus -Changes $script:Changes -Rehearsal:$Rehearse
