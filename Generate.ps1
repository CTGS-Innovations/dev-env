<#
.SYNOPSIS
    Read-only: write a layout file describing the environment as it is now.

.DESCRIPTION
    The authoring half of the pair. Arrange your desktops by hand, run this,
    and it emits a .psd1 that Restore-DevEnv.ps1 replays. Nothing hand-written.

    It works out for you:
      * virtual desktops, by name and order
      * which desktop each window is on
      * ZONES -- repeated rectangles are collapsed into named regions
        ('M1.center') so pixels appear once instead of seven times
      * WORKSPACES -- Cursor folder URIs named by project ('CLI')
      * monitor identity by primary-flag + resolution, not device name
      * real executable paths, from the running processes
      * Explorer folder paths, via Shell COM

    SAFETY: reads only. Nothing launched, moved, closed or reconfigured. The
    only write is the output file, and never over an existing one without -Force.

    IT CANNOT TELL INTENT FROM ACCIDENT. Everything it emits is simply what was
    true at the moment it ran. Generate to -Out and diff before replacing a
    config you trust.

.PARAMETER Out
    Output path. Defaults to <Root>\layout.<COMPUTERNAME>.psd1 -- one config
    per machine, side by side in the same folder. Restore picks the one whose
    name matches the machine it is running on.

.PARAMETER SkipDesktop
    Desktop name(s) never to capture, e.g. -SkipDesktop Open. Remembered in
    capture.psd1, so you only say it once. Written as IntentionallyEmpty.

.PARAMETER NoPrompt
    Don't ask about apps it hasn't seen before; just list them.

.PARAMETER NoLauncher
    Skip writing the launcher files (see NOTES).

.PARAMETER LauncherOnly
    Write the launcher files for this machine's existing config and stop,
    without capturing anything. Use after copying the folder somewhere new.

.NOTES
    NEW APPS. Anything with a visible window that isn't in $AppRules and that
    you haven't answered before gets a question:
        [y] add it    [n] never ask again    [Enter] not this time
    Answers live in <Root>\capture.psd1 (Add / Ignore / SkipDesktops) --
    plain text, edit it any time. An added app is launched from the exe it
    was running from, with no arguments.

    LAUNCHERS. After a successful write it also writes two pairs:
      <Root>\Restore-DevEnv.cmd                 portable: run on any machine,
      <Root>\Capture-DevEnv.cmd                 each picks layout.<COMPUTERNAME>.psd1
      <Desktop>\DevEnv Restore - <MACHINE>.cmd  same, absolute paths, for
      <Desktop>\DevEnv Capture - <MACHINE>.cmd  double-clicking
    Restore runs Restore -Apply. Capture runs this script with -Force, then
    opens the new layout in Notepad for review. Extra arguments pass through,
    e.g.  "DevEnv Restore - ATLAS.cmd" -Desktop Main

    BACKUP. Overwriting an existing layout first copies it to
    <Root>\_archive\layout.<COMPUTERNAME>.previous.psd1.

.PARAMETER ZoneTolerance
    Pixels within which two rectangles count as the same zone. Default 12,
    which absorbs the few-pixel differences apps introduce themselves.

.EXAMPLE
    .\Generate.ps1 -Out D:\tmp\try.psd1 -Force -NoLauncher
    Write a trial config so you can diff it before committing.

.EXAMPLE
    .\Generate.ps1 -LauncherOnly
    Just (re)create the desktop launcher for this machine.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]   $Root,
    [string]   $Out,
    [switch]   $Force,
    [int]      $ZoneTolerance = 12,
    [string[]] $SkipDesktop,
    [switch]   $NoPrompt,
    [switch]   $NoLauncher,
    [switch]   $LauncherOnly,
    # Defaults to every process with a rule in $AppRules below, except those
    # marked Skip. One table to maintain, not two lists.
    [string[]] $IncludeProcess
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# How each process maps to an app definition.
#   Policy  launch | place     place = positioned but never launched
#   Scope   desktop | global   global = one instance for the whole session
# ---------------------------------------------------------------------------
$AppRules = @{
    'chrome.exe'           = @{ Key='chrome';   Policy='launch'; Scope='desktop'
                                Args=@('--profile-directory=Default','--new-window','about:blank') }
    'Cursor.exe'           = @{ Key='cursor';   Policy='launch'; Scope='desktop'
                                Args=@('--new-window','--folder-uri','{uri}'); LaunchTimeoutSec=45 }
    # Skip = known, but not captured unless you say so: Generate asks about it
    # like a new app, and a yes is remembered in capture.psd1.
    'Tabby.exe'            = @{ Key='tabby';    Policy='launch'; Scope='desktop'; Args=@(); Skip=$true }
    'explorer.exe'         = @{ Key='explorer'; Policy='launch'; Scope='desktop'; Args=@('{path}') }
    'claude.exe'           = @{ Key='claude';   Policy='place';  Scope='desktop'
                                Note='Store-packaged app with no stable exe launch path. Positioned, never launched.' }
    'MVP-Echo Toolbar.exe' = @{ Key='mvpecho';  Policy='launch'; Scope='global'
                                AllowHidden=$true; NoPosition=$true
                                TitleInclude='^MVP-Echo Toolbar$'
                                # Self-extracting build: the running process reports a %TEMP%
                                # path, so the launch target has to come from the rule. The
                                # glob tolerates a version bump in the filename.
                                # Candidates in order; the first that matches on this machine
                                # is written to the config. The laptop keeps it in Desktop\echo.
                                PathGlob=@('%USERPROFILE%\Desktop\echo\MVP-Echo Toolbar *.exe'
                                           '%USERPROFILE%\Desktop\MVP-Echo.Toolbar.*.exe'
                                           '%USERPROFILE%\Desktop\MVP-Echo Toolbar *.exe')
                                # What TOOLBAR-LITE.bat did by hand: pin the exe to the high
                                # performance GPU (Windows Graphics Settings, 2 = high perf)
                                # and tell Chromium to use it. Restore does both at launch.
                                GpuPreference=2
                                Args=@('--force_high_performance_gpu')
                                Note='Tray-anchored; it repositions itself, so position is left unmanaged.' }
}

# ---------------------------------------------------------------------------
# capture.psd1 -- your answers about apps and desktops, remembered between runs
# ---------------------------------------------------------------------------
$explicitInclude = [bool]$IncludeProcess
$settingsRoot = if ([string]::IsNullOrWhiteSpace($Root)) { $PSScriptRoot } else { $Root }
$SettingsPath = Join-Path $settingsRoot 'capture.psd1'
$Settings = @{ Add = @(); Ignore = @(); SkipDesktops = @() }
if (Test-Path -LiteralPath $SettingsPath) {
    $loaded = Import-PowerShellDataFile -LiteralPath $SettingsPath
    foreach ($k in @('Add', 'Ignore', 'SkipDesktops')) { if ($loaded.$k) { $Settings[$k] = @($loaded.$k) } }
}
$settingsDirty = $false
foreach ($d in @($SkipDesktop)) {
    if ($d -and $Settings.SkipDesktops -notcontains $d) { $Settings.SkipDesktops += $d; $settingsDirty = $true }
}

function New-GenericRule {
    # An app you added: launched from the exe it was running from, no args.
    param([string] $Process)
    $base = (($Process -replace '\.exe$', '').ToLowerInvariant() -replace '[^a-z0-9]', '')
    if (-not $base) { $base = 'app' }
    $key = $base; $n = 2
    while (@($AppRules.Values | Where-Object { $_.Key -eq $key }).Count -gt 0) { $key = '{0}{1}' -f $base, $n; $n++ }
    @{ Key = $key; Policy = 'launch'; Scope = 'desktop'; Args = @(); Generic = $true }
}

function Save-CaptureSettings {
    $q   = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
    $fmt = { param($list)
        $items = @(@($list) | Where-Object { $_ } | Sort-Object -Unique)
        if ($items.Count -eq 0) { '@()' } else { '@(' + (($items | ForEach-Object { & $q $_ }) -join ', ') + ')' }
    }
    $text = (@(
        '# What Generate.ps1 captures beyond its built-in apps. Shared by every'
        '# machine using this folder. Edit freely; Generate also updates it when'
        '# you answer its questions.'
        '@{'
        '    # Apps you said yes to: captured and launched like the built-in ones.'
        ('    Add          = {0}' -f (& $fmt $Settings.Add))
        ''
        '    # Apps you said no to: never captured, never asked about again.'
        ('    Ignore       = {0}' -f (& $fmt $Settings.Ignore))
        ''
        '    # Desktops (by name) never captured. Restore leaves them alone.'
        ('    SkipDesktops = {0}' -f (& $fmt $Settings.SkipDesktops))
        '}'
    ) -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($SettingsPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

foreach ($p in @($Settings.Add)) {
    if (-not $p) { continue }
    if ($AppRules.ContainsKey($p)) { $AppRules[$p].Skip = $false }
    else { $AppRules[$p] = New-GenericRule -Process $p }
}

if (-not $IncludeProcess) {
    $IncludeProcess = @($AppRules.Keys | Where-Object { -not $AppRules[$_].Skip })
}

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path $Root ('layout.{0}.psd1' -f $env:COMPUTERNAME)
}

function Write-DevEnvLauncher {
    # Writes the launchers described in .NOTES. ASCII + CRLF so cmd.exe reads
    # them correctly on any code page.
    param([Parameter(Mandatory)][string] $Manifest)

    $here     = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    $manifest = [IO.Path]::GetFullPath($Manifest)
    $std      = Join-Path $here ('layout.{0}.psd1' -f $env:COMPUTERNAME)
    $stamp    = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $ascii    = New-Object System.Text.ASCIIEncoding
    $ps       = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'

    # $Dir is how the launcher names the script folder: '%~dp0' for the
    # portable copies beside the scripts, an absolute path for the desktop.
    # With the standard config name, the layout is named by %COMPUTERNAME% at
    # run time, so the portable copies work on any machine.
    $layoutRef = {
        param($Dir)
        if ($manifest -eq $std) { '{0}layout.%COMPUTERNAME%.psd1' -f $Dir }
        elseif ((Split-Path -Parent $manifest) -eq $here) { $Dir + (Split-Path -Leaf $manifest) }
        else { $manifest }
    }
    $restoreText = {
        param($Dir)
        $lay = & $layoutRef $Dir
        (@(
            '@echo off'
            ('rem DEV-ENV restore -- written by Generate.ps1 on {0}, {1}' -f $env:COMPUTERNAME, $stamp)
            'rem Puts your virtual desktops back. Hands off the keyboard while it runs.'
            ('{0} "{1}Restore.ps1" -ManifestPath "{2}" -Apply %*' -f $ps, $Dir, $lay)
            'if errorlevel 1 pause'
        ) -join "`r`n") + "`r`n"
    }
    # -NoLauncher: cmd.exe reads a batch file as it runs, so the capture must
    # not rewrite the very file that is executing it.
    $captureText = {
        param($Dir)
        $lay   = & $layoutRef $Dir
        $outArg = if ($manifest -eq $std) { '' } else { ' -Out "{0}"' -f $lay }
        (@(
            '@echo off'
            ('rem DEV-ENV capture -- written by Generate.ps1 on {0}, {1}' -f $env:COMPUTERNAME, $stamp)
            'rem Captures your desktops exactly as they are now, asks about any app it'
            'rem has not seen before, then opens the layout so you can review it.'
            'rem The previous layout is kept in _archive\.'
            ('{0} "{1}Generate.ps1" -Force -NoLauncher{2} %*' -f $ps, $Dir, $outArg)
            'if errorlevel 1 ( pause & exit /b 1 )'
            'echo.'
            'echo Next: review the layout. Delete any window lines you do not want, then save.'
            'pause'
            ('start "" notepad "{0}"' -f $lay)
        ) -join "`r`n") + "`r`n"
    }

    $deskDir = [Environment]::GetFolderPath('Desktop')
    $abs     = $here + '\'
    $files = [ordered]@{
        (Join-Path $here 'Restore-DevEnv.cmd')                                   = (& $restoreText '%~dp0')
        (Join-Path $here 'Capture-DevEnv.cmd')                                   = (& $captureText '%~dp0')
        (Join-Path $deskDir ('DevEnv Restore - {0}.cmd' -f $env:COMPUTERNAME))  = (& $restoreText $abs)
        (Join-Path $deskDir ('DevEnv Capture - {0}.cmd' -f $env:COMPUTERNAME))  = (& $captureText $abs)
    }
    foreach ($f in $files.Keys) { [IO.File]::WriteAllText($f, $files[$f], $ascii) }

    # The single-launcher name from before the pair existed.
    $old = Join-Path $deskDir ('DevEnv - {0}.cmd' -f $env:COMPUTERNAME)
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old }

    Write-Host 'Launchers written:' -ForegroundColor Green
    foreach ($f in $files.Keys) { Write-Host ('  {0}' -f $f) }
}

if ($LauncherOnly) {
    if (-not (Test-Path -LiteralPath $Out)) {
        throw ("No config at {0}. Run Generate.ps1 without -LauncherOnly first." -f $Out)
    }
    Write-DevEnvLauncher -Manifest $Out
    return
}

. (Join-Path $PSScriptRoot 'DevEnv.ps1')

$interop = Test-DevEnvInterop
if (-not $interop.Available) { throw "IVirtualDesktopManager unavailable: $($interop.Error)" }

Write-Host ''
Write-Host 'Reading current environment...' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Monitors: M1 = primary, then by position
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
$monitors = @()
$i = 0
foreach ($s in ([System.Windows.Forms.Screen]::AllScreens |
                Sort-Object { -[int]$_.Primary }, { $_.Bounds.Y }, { $_.Bounds.X })) {
    $i++
    $monitors += [pscustomobject]@{
        Key = ('M{0}' -f $i); DeviceName = $s.DeviceName; Primary = $s.Primary
        X = $s.Bounds.X; Y = $s.Bounds.Y; Width = $s.Bounds.Width; Height = $s.Bounds.Height
        # The work area is what windows actually snap into -- bounds minus the
        # taskbar. Regions are fractions of this, never of the raw bounds.
        WorkX = $s.WorkingArea.X; WorkY = $s.WorkingArea.Y
        WorkWidth = $s.WorkingArea.Width; WorkHeight = $s.WorkingArea.Height
        Cols = 1; Rows = 1
    }
    Write-Host ('  {0} -> {1}  {2},{3} {4}x{5}  work {6}x{7}  primary={8}' -f `
        $monitors[-1].Key, $s.DeviceName, $s.Bounds.X, $s.Bounds.Y, $s.Bounds.Width, $s.Bounds.Height, `
        $s.WorkingArea.Width, $s.WorkingArea.Height, $s.Primary)
}

function Find-Monitor {
    param([int] $X, [int] $Y, [int] $W, [int] $H)
    $cx = $X + [int]($W / 2); $cy = $Y + [int]($H / 2)
    foreach ($m in $monitors) {
        if ($cx -ge $m.X -and $cx -lt ($m.X + $m.Width) -and $cy -ge $m.Y -and $cy -lt ($m.Y + $m.Height)) { return $m }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Desktops
# ---------------------------------------------------------------------------
$desktops = @(Get-DevEnvDesktopOrder)
if ($desktops.Count -eq 0) { throw 'Could not read the virtual desktop order.' }
Write-Host ('  {0} virtual desktop(s)' -f $desktops.Count)

# ---------------------------------------------------------------------------
# Cursor workspace URIs, from Cursor's own storage
# ---------------------------------------------------------------------------
$cursorWorkspaces = @()
try {
    $sp = Join-Path $env:APPDATA 'Cursor\User\globalStorage\storage.json'
    if (Test-Path -LiteralPath $sp) {
        $st = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json
        foreach ($w in @($st.windowsState.openedWindows)) {
            $u = if ($w.folder) { $w.folder } elseif ($w.workspace) { $w.workspace } else { $null }
            if ($u) {
                $cursorWorkspaces += [pscustomobject]@{
                    Uri  = $u
                    Leaf = [System.Uri]::UnescapeDataString(($u -split '/')[-1])
                }
            }
        }
    }
} catch { Write-Warning "could not read Cursor storage: $($_.Exception.Message)" }
Write-Host ('  {0} Cursor workspace URI(s)' -f $cursorWorkspaces.Count)

# ---------------------------------------------------------------------------
# Explorer folders
# ---------------------------------------------------------------------------
$explorerPaths = @{}
try {
    $shell = New-Object -ComObject Shell.Application
    foreach ($w in $shell.Windows()) {
        try { $p = $w.Document.Folder.Self.Path; if ($p) { $explorerPaths[[int64]$w.HWND] = $p } } catch { }
    }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
} catch { Write-Warning "could not enumerate Explorer folders: $($_.Exception.Message)" }

# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------
$allWindows = @(Get-DevEnvWindow)
$skipIds = @($desktops | Where-Object { $Settings.SkipDesktops -contains [string]$_.Name } | ForEach-Object { [string]$_.Id })
foreach ($d in @($desktops | Where-Object { $skipIds -contains [string]$_.Id })) {
    Write-Host ('  skipping desktop [{0}] {1} (SkipDesktops)' -f $d.Index, $d.Name)
}

# --- apps not seen before ----------------------------------------------------
# Same "real window" test as everywhere else: visible, titled, not a tool
# window, on a screen, and not on a skipped desktop.
if (-not $explicitInclude) {
    $shellNoise = @('TextInputHost.exe', 'ApplicationFrameHost.exe', 'SystemSettings.exe',
                    'ShellExperienceHost.exe', 'StartMenuExperienceHost.exe', 'SearchHost.exe', 'LockApp.exe')
    $unknown = @($allWindows | Where-Object {
        $_.IsVisible -and -not $_.IsToolWindow -and -not [string]::IsNullOrWhiteSpace($_.Title) -and
        (-not $AppRules.ContainsKey($_.Process) -or $AppRules[$_.Process].Skip) -and
        $Settings.Ignore -notcontains $_.Process -and
        $shellNoise -notcontains $_.Process -and
        $skipIds -notcontains [string]$_.DesktopId -and
        (Find-Monitor -X $_.FrameX -Y $_.FrameY -W $_.FrameWidth -H $_.FrameHeight)
    })
    $groupsNew = @($unknown | Group-Object Process | Sort-Object Name)
    if ($groupsNew.Count -gt 0) {
        $canAsk = -not $NoPrompt -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        $deskName = @{}
        foreach ($d in $desktops) { $deskName[[string]$d.Id] = ('[{0}] {1}' -f $d.Index, $d.Name) }
        Write-Host ''
        Write-Host ('  {0} app(s) not seen before:' -f $groupsNew.Count) -ForegroundColor Yellow
        foreach ($g in $groupsNew) {
            Write-Host ''
            Write-Host ('    {0}  -- {1} window(s)' -f $g.Name, $g.Count) -ForegroundColor White
            foreach ($w in ($g.Group | Select-Object -First 4)) {
                $t = [string]$w.Title; if ($t.Length -gt 50) { $t = $t.Substring(0, 47) + '...' }
                $where = $deskName[[string]$w.DesktopId]; if (-not $where) { $where = '[?]' }
                Write-Host ('      {0,-16} {1}' -f $where, $t)
            }
            if (-not $canAsk) { continue }
            $a = ([string](Read-Host '    Add it?  [y] add   [n] never ask again   [Enter] not this time')).Trim().ToLowerInvariant()
            if ($a -eq 'y' -or $a -eq 'yes') {
                if ($AppRules.ContainsKey($g.Name)) { $AppRules[$g.Name].Skip = $false }
                else { $AppRules[$g.Name] = New-GenericRule -Process $g.Name }
                $Settings.Add += $g.Name; $IncludeProcess += $g.Name; $settingsDirty = $true
                Write-Host ('      added {0}' -f $g.Name) -ForegroundColor Green
            } elseif ($a -eq 'n' -or $a -eq 'no') {
                $Settings.Ignore += $g.Name; $settingsDirty = $true
                Write-Host '      ignored from now on' -ForegroundColor DarkGray
            }
        }
        if (-not $canAsk) {
            Write-Host ''
            Write-Host '    Not captured. Run Generate.ps1 in a console to be asked about them,' -ForegroundColor Yellow
            Write-Host ('    or list them under Add / Ignore in {0}.' -f $SettingsPath) -ForegroundColor Yellow
        }
        Write-Host ''
    }
}
if ($settingsDirty) {
    Save-CaptureSettings
    Write-Host ('  remembered in {0}' -f $SettingsPath)
}

$rows = @()
foreach ($w in @($allWindows | Where-Object { $IncludeProcess -contains $_.Process })) {
    $rule = $AppRules[$w.Process]
    if (-not $rule) { continue }
    if ($rule.Scope -ne 'global' -and $skipIds -contains [string]$w.DesktopId) { continue }

    if ($rule.AllowHidden) {
        if ([string]::IsNullOrWhiteSpace($w.Title)) { continue }
    } else {
        if (-not $w.IsVisible -or $w.IsToolWindow -or [string]::IsNullOrWhiteSpace($w.Title)) { continue }
    }
    if ($rule.TitleInclude -and ($w.Title -notmatch $rule.TitleInclude)) { continue }

    $mon = Find-Monitor -X $w.FrameX -Y $w.FrameY -W $w.FrameWidth -H $w.FrameHeight
    if (-not $mon) {
        Write-Warning ('skipped {0} "{1}": its centre ({2},{3}) is on no detected screen' -f `
            $w.Process, $w.Title, ($w.FrameX + [int]($w.FrameWidth / 2)), ($w.FrameY + [int]($w.FrameHeight / 2)))
        continue
    }

    $rows += [pscustomobject]@{
        Handle = [int64]$w.Handle; Process = $w.Process; ExePath = $w.ExePath; Title = $w.Title
        Rule = $rule; DesktopId = $w.DesktopId; MonKey = $mon.Key
        RelX = ($w.FrameX - $mon.X); RelY = ($w.FrameY - $mon.Y)
        W = $w.FrameWidth; H = $w.FrameHeight
        Fit = $null; Region = $null; Project = $null
    }
}
Write-Host ('  {0} layout window(s)' -f $rows.Count)

# ---------------------------------------------------------------------------
# Grid inference
#
# Snapped windows are not arbitrary rectangles -- they are cells of a grid the
# screen is divided into, and the same grid repeats on every desktop. So find
# the coarsest row/column split of each monitor's WORK AREA that explains where
# the windows actually sit, and record that instead of the pixels. A region is
# then a cell span, which means the same name resolves correctly on a screen of
# a different size.
# ---------------------------------------------------------------------------
function Get-GridFit {
    param($Mon, $Rects, [int] $Cols, [int] $Rows, [int] $TolX, [int] $TolY)

    $cw = $Mon.WorkWidth  / $Cols
    $ch = $Mon.WorkHeight / $Rows
    $out = @()

    foreach ($r in $Rects) {
        # Window position relative to the work area, not the bounds.
        $wx = $r.RelX + $Mon.X - $Mon.WorkX
        $wy = $r.RelY + $Mon.Y - $Mon.WorkY

        $col = [int][Math]::Round($wx / $cw) + 1
        $row = [int][Math]::Round($wy / $ch) + 1
        $cs  = [int][Math]::Round($r.W / $cw)
        $rs  = [int][Math]::Round($r.H / $ch)
        if ($col -lt 1) { $col = 1 }
        if ($row -lt 1) { $row = 1 }
        if ($cs  -lt 1) { $cs  = 1 }
        if ($rs  -lt 1) { $rs  = 1 }
        if ($col -gt $Cols) { $col = $Cols }
        if ($row -gt $Rows) { $row = $Rows }
        if (($col + $cs - 1) -gt $Cols) { $cs = $Cols - $col + 1 }
        if (($row + $rs - 1) -gt $Rows) { $rs = $Rows - $row + 1 }

        $ix = [Math]::Round(($col - 1) * $cw)
        $iy = [Math]::Round(($row - 1) * $ch)
        $iw = [Math]::Round(($col - 1 + $cs) * $cw) - $ix
        $ih = [Math]::Round(($row - 1 + $rs) * $ch) - $iy

        $out += [pscustomobject]@{
            Row = $r; Col = $col; RowIdx = $row; ColSpan = $cs; RowSpan = $rs
            Fits = (([Math]::Abs($wx - $ix) -le $TolX) -and ([Math]::Abs($wy - $iy) -le $TolY) -and
                    ([Math]::Abs($r.W - $iw) -le $TolX) -and ([Math]::Abs($r.H - $ih) -le $TolY))
        }
    }
    return $out
}

foreach ($mon in $monitors) {
    $mine = @($rows | Where-Object { $_.MonKey -eq $mon.Key })
    if ($mine.Count -eq 0) { continue }

    # Snap leaves a few pixels of slop, and it scales with the screen.
    $tolX = [Math]::Max($ZoneTolerance, [int][Math]::Round($mon.WorkWidth  * 0.02))
    $tolY = [Math]::Max($ZoneTolerance, [int][Math]::Round($mon.WorkHeight * 0.02))

    $best = $null
    for ($c = 1; $c -le 4; $c++) {
        for ($rw = 1; $rw -le 3; $rw++) {
            $fit  = Get-GridFit -Mon $mon -Rects $mine -Cols $c -Rows $rw -TolX $tolX -TolY $tolY
            $cand = [pscustomobject]@{
                Cols = $c; Rows = $rw; Cells = ($c * $rw); Fit = $fit
                Hits = @($fit | Where-Object { $_.Fits }).Count
            }
            # Most windows explained wins; on a tie the coarser grid wins, so a
            # 3x1 screen is never described as 3x2 for no reason.
            if (-not $best -or $cand.Hits -gt $best.Hits -or
                ($cand.Hits -eq $best.Hits -and $cand.Cells -lt $best.Cells)) { $best = $cand }
        }
    }

    $mon.Cols = $best.Cols
    $mon.Rows = $best.Rows
    foreach ($f in $best.Fit) { $f.Row.Fit = $f }
    Write-Host ('  {0} grid {1}x{2}  ({3} of {4} window(s) on the grid)' -f `
        $mon.Key, $best.Cols, $best.Rows, $best.Hits, $mine.Count)
}

# ---------------------------------------------------------------------------
# Regions: one per distinct cell span, plus literals for anything off-grid
# ---------------------------------------------------------------------------
$regions = @()
foreach ($r in $rows) {
    $f = $r.Fit
    if ($f -and $f.Fits) {
        $hit = $regions | Where-Object {
            $_.MonKey -eq $r.MonKey -and $_.Grid -and
            $_.Col -eq $f.Col -and $_.Row -eq $f.RowIdx -and
            $_.ColSpan -eq $f.ColSpan -and $_.RowSpan -eq $f.RowSpan
        } | Select-Object -First 1
        if ($hit) { $hit.Count++; $r.Region = $hit; continue }

        $z = [pscustomobject]@{
            MonKey = $r.MonKey; Grid = $true
            Col = $f.Col; Row = $f.RowIdx; ColSpan = $f.ColSpan; RowSpan = $f.RowSpan
            X = 0; Y = 0; Width = 0; Height = 0; Count = 1; Name = $null
        }
        $regions += $z; $r.Region = $z
        continue
    }

    # Off the grid -- a tray popup, a window dragged somewhere odd. Kept as a
    # literal rectangle so nothing is silently moved onto a cell it never used.
    $hit = $regions | Where-Object {
        $_.MonKey -eq $r.MonKey -and -not $_.Grid -and
        [Math]::Abs($_.X - $r.RelX) -le $ZoneTolerance -and
        [Math]::Abs($_.Y - $r.RelY) -le $ZoneTolerance -and
        [Math]::Abs($_.Width  - $r.W) -le $ZoneTolerance -and
        [Math]::Abs($_.Height - $r.H) -le $ZoneTolerance
    } | Select-Object -First 1
    if ($hit) { $hit.Count++; $r.Region = $hit; continue }

    $z = [pscustomobject]@{
        MonKey = $r.MonKey; Grid = $false
        Col = 0; Row = 0; ColSpan = 0; RowSpan = 0
        X = $r.RelX; Y = $r.RelY; Width = $r.W; Height = $r.H; Count = 1; Name = $null
    }
    $regions += $z; $r.Region = $z
}

# Names come from the grid itself: the column word, the row word, and neither
# when the span covers the whole axis.
$colWords = @{ 1 = @('full'); 2 = @('left','right'); 3 = @('left','center','right'); 4 = @('left','midleft','midright','right') }
$rowWords = @{ 1 = @('full'); 2 = @('top','bottom'); 3 = @('top','middle','bottom') }

foreach ($z in $regions) {
    $mon = $monitors | Where-Object { $_.Key -eq $z.MonKey } | Select-Object -First 1
    if (-not $z.Grid) { $z.Name = '{0}.free' -f $z.MonKey; continue }

    $cw = if ($colWords.ContainsKey($mon.Cols)) { $colWords[$mon.Cols] } else { @(1..$mon.Cols | ForEach-Object { 'c' + $_ }) }
    $rw = if ($rowWords.ContainsKey($mon.Rows)) { $rowWords[$mon.Rows] } else { @(1..$mon.Rows | ForEach-Object { 'r' + $_ }) }

    $parts = @()
    if ($z.ColSpan -lt $mon.Cols) { $parts += $cw[$z.Col - 1] }
    if ($z.RowSpan -lt $mon.Rows) { $parts += $rw[$z.Row - 1] }
    $z.Name = if ($parts.Count -eq 0) { '{0}.full' -f $z.MonKey } else { '{0}.{1}' -f $z.MonKey, ($parts -join '-') }
}

# guard against a duplicate name
$seen = @{}
foreach ($z in ($regions | Sort-Object -Property @{ Expression = { $_.Count }; Descending = $true })) {
    $n = $z.Name; $k = 2
    while ($seen.ContainsKey($n)) { $n = ('{0}{1}' -f $z.Name, $k); $k++ }
    $z.Name = $n; $seen[$n] = $true
}
Write-Host ('  {0} distinct region(s)' -f $regions.Count)

# ---------------------------------------------------------------------------
# Projects: name each Cursor window's workspace, uniquely
# ---------------------------------------------------------------------------
$usedUri = @{}
$workspaces = @{}
foreach ($r in ($rows | Where-Object { $_.Rule.Key -eq 'cursor' })) {
    $hit = $cursorWorkspaces | Where-Object {
        $_.Leaf -and $r.Title -like ('*' + $_.Leaf + '*') -and -not $usedUri.ContainsKey($_.Uri)
    } | Select-Object -First 1
    if (-not $hit) { continue }

    $usedUri[$hit.Uri] = $true
    $name = $hit.Leaf; $k = 2
    while ($workspaces.ContainsKey($name) -and $workspaces[$name] -ne $hit.Uri) { $name = ('{0}{1}' -f $hit.Leaf, $k); $k++ }
    $workspaces[$name] = $hit.Uri
    $r.Project = $name
}
Write-Host ('  {0} project(s) named' -f $workspaces.Count)

# ---------------------------------------------------------------------------
# App definitions, from what is actually running
# ---------------------------------------------------------------------------
$apps = @{}
foreach ($g in ($rows | Group-Object Process)) {
    $r = $g.Group[0]; $rule = $r.Rule
    $policy = $rule.Policy
    $note   = $rule.Note
    if ($rule.Generic -and $r.ExePath -like '*\WindowsApps\*') {
        $policy = 'place'
        $note   = 'Store-packaged app with no stable exe launch path. Positioned, never launched.'
    }
    $def = [ordered]@{ Process = $r.Process; Policy = $policy }
    if ($policy -eq 'launch') {
        if ($rule.PathGlob) {
            $globs = @($rule.PathGlob | ForEach-Object { [System.Environment]::ExpandEnvironmentVariables($_) })
            $hit   = @($globs | Where-Object { Get-ChildItem -Path $_ -File -ErrorAction SilentlyContinue } | Select-Object -First 1)
            if ($hit.Count -gt 0) { $def.PathGlob = $hit[0] }
            else {
                $def.PathGlob = $globs[0]
                $def.TODO = 'no file matched PathGlob on this machine; fix the path by hand'
            }
        } elseif ($r.ExePath) { $def.Path = $r.ExePath }
        else { $def.TODO = 'could not read the executable path; fill in Path by hand' }
        $def.Args = @($rule.Args)
        if ($rule.LaunchTimeoutSec) { $def.LaunchTimeoutSec = $rule.LaunchTimeoutSec }
        if ($rule.GpuPreference)    { $def.GpuPreference = $rule.GpuPreference }
    }
    if ($note) { $def.Note = $note }
    $apps[$rule.Key] = $def
}

# ---------------------------------------------------------------------------
# Layouts: the window shape that repeats across desktops
#
# Six desktops holding the same three windows should read as six lines, not six
# blocks. A shape becomes a template when more than one desktop has it and the
# only thing varying between them is the project.
# ---------------------------------------------------------------------------
$deskRows = @{}
$deskSig  = @{}
foreach ($d in $desktops) {
    # Reading order: screen, then left to right, then top to bottom. Also the
    # order the signature is built in, so two desktops with the same shape
    # produce the same signature.
    $mine = @($rows | Where-Object { $_.DesktopId -eq $d.Id -and $_.Rule.Scope -eq 'desktop' } |
             Sort-Object { $_.MonKey }, { $_.RelX }, { $_.RelY }, { $_.Rule.Key })
    $deskRows[$d.Id] = $mine

    $parts = @()
    foreach ($r in $mine) {
        $tag = ''
        if ($r.Project) { $tag = ':project' }
        if ($r.Rule.Key -eq 'explorer') { $tag = ':path' }
        $parts += ('{0}@{1}{2}' -f $r.Rule.Key, $r.Region.Name, $tag)
    }
    $deskSig[$d.Id] = ($parts -join ' + ')
}

$groups = @()
foreach ($d in $desktops) {
    $sig  = $deskSig[$d.Id]
    $mine = $deskRows[$d.Id]
    if (-not $sig) { continue }
    # A per-desktop folder path, or two projects, cannot be expressed by one
    # template token -- those desktops stay literal.
    if (@($mine | Where-Object { $_.Rule.Key -eq 'explorer' }).Count -gt 0) { continue }
    if (@($mine | Where-Object { $_.Project }).Count -gt 1) { continue }

    $g = $groups | Where-Object { $_.Sig -eq $sig } | Select-Object -First 1
    if ($g) { $g.Ids += $d.Id } else { $groups += [pscustomobject]@{ Sig = $sig; Ids = @($d.Id) } }
}

$layouts    = [ordered]@{}
$deskLayout = @{}
$ln = 0
foreach ($g in ($groups | Sort-Object -Property @{ Expression = { @($_.Ids).Count }; Descending = $true })) {
    if (@($g.Ids).Count -lt 2) { continue }
    $ln++
    $name = if ($ln -eq 1) { 'standard' } else { 'standard' + $ln }
    $layouts[$name] = $deskRows[$g.Ids[0]]
    foreach ($id in $g.Ids) { $deskLayout[$id] = $name }
}
Write-Host ('  {0} shared layout(s)' -f $layouts.Count)

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
function W { param([string] $T = '') ; [void]$sb.AppendLine($T) }
function Q { param($V) ; "'" + ([string]$V).Replace("'", "''") + "'" }

function Format-Win {
    param($R, [switch] $Template)
    $line = '@{{ App = {0,-10} Region = {1,-18}' -f ((Q $R.Rule.Key) + ';'), ((Q $R.Region.Name) + ';')
    # TODOs go AFTER the closing brace: a '#' inside a one-line @{ } would
    # comment out the brace and leave the whole file unparseable.
    $todo = $null
    if ($R.Project) {
        $v = if ($Template) { '{project}' } else { $R.Project }
        $line += (' Project = {0};' -f (Q $v))
    }
    elseif ($R.Rule.Key -eq 'cursor') { $todo = 'no Cursor URI matched this window' }
    if ($R.Rule.Key -eq 'explorer') {
        if ($explorerPaths.ContainsKey($R.Handle)) { $line += (' Path = {0};' -f (Q $explorerPaths[$R.Handle])) }
        else { $todo = 'could not read this folder' }
    }
    $line = $line.TrimEnd().TrimEnd(';') + ' }'
    if ($todo) { $line += ('   # TODO: {0}' -f $todo) }
    return $line
}

W '<#'
W '    Dev environment layout -- GENERATED. Re-running the generator replaces it.'
W ''
W ('    Written : {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
W ('    Machine : {0}' -f $env:COMPUTERNAME)
W ''
W '    Read it top-down:'
W '      Monitors    each screen, and the grid its work area divides into'
W '      Regions     a named span of grid cells -- no pixels'
W '      Workspaces  a Cursor folder URI, named once by project'
W '      Apps        how to launch each thing'
W '      Layouts     a window shape that several desktops share'
W '      Desktops    which layout, which project, which desktop'
W ''
W '    Regions are cell spans of the work area rather than stored rectangles,'
W '    so this file carries no screen-size assumptions: the same region name'
W '    resolves to the right rectangle on a different monitor, and on a laptop.'
W ''
W '    Policy  launch = create if missing, then position'
W '            place  = position only, never launch'
W '#>'
W '@{'
W ''
W '    Version    = 4'
W ('    Machine    = {0}' -f (Q $env:COMPUTERNAME))
W ('    CapturedAt = {0}' -f (Q ((Get-Date).ToString('o'))))
W ''
W '    # Desktop to land on when restore finishes. 0 = stay where it ends.'
W '    ReturnToDesktopIndex = 1'
W ''
W '    # Matched on primary-flag and resolution, falling back to position, so'
W '    # different hardware still lands somewhere sensible. Grid is how many'
W '    # columns and rows the work area splits into.'
W '    Monitors = @('
foreach ($m in $monitors) {
    W ('        @{{ Key = {0}; Match = @{{ Primary = ${1}; Width = {2}; Height = {3} }}; Grid = @{{ Cols = {4}; Rows = {5} }}; FallbackDeviceName = {6} }}' -f `
        (Q $m.Key), ($m.Primary.ToString().ToLower()), $m.Width, $m.Height, $m.Cols, $m.Rows, (Q $m.DeviceName))
}
W '    )'
W ''
W '    # Cells of the grid above, named. Restore computes the rectangle from'
W '    # the live work area and measures each window''s invisible border itself.'
W '    Regions = @{'
foreach ($z in ($regions | Sort-Object MonKey, @{ Expression = { -$_.Count } }, Col, Row)) {
    $tail = '   # {0} window(s)' -f $z.Count
    if ($z.Grid) {
        $span = ''
        if ($z.ColSpan -gt 1) { $span += ('; ColSpan = {0}' -f $z.ColSpan) }
        if ($z.RowSpan -gt 1) { $span += ('; RowSpan = {0}' -f $z.RowSpan) }
        W ('        {0,-18} = @{{ Monitor = {1}; Col = {2}; Row = {3}{4} }}{5}' -f `
            (Q $z.Name), (Q $z.MonKey), $z.Col, $z.Row, $span, $tail)
    } else {
        W ('        {0,-18} = @{{ Monitor = {1}; X = {2}; Y = {3}; Width = {4}; Height = {5} }}{6}, off-grid' -f `
            (Q $z.Name), (Q $z.MonKey), $z.X, $z.Y, $z.Width, $z.Height, $tail)
    }
}
W '    }'
W ''
if ($workspaces.Count -gt 0) {
    W '    # Cursor folder URIs. Referenced from a window as Project = ''<name>'','
    W '    # which also supplies the title fragment used to tell windows apart.'
    W '    Workspaces = @{'
    foreach ($k in ($workspaces.Keys | Sort-Object)) {
        W ('        {0,-24} = {1}' -f (Q $k), (Q $workspaces[$k]))
    }
    W '    }'
    W ''
}
W '    Apps = @{'
foreach ($k in ($apps.Keys | Sort-Object)) {
    $d = $apps[$k]
    W ('        {0} = @{{' -f $k)
    foreach ($f in $d.Keys) {
        $v = $d[$f]
        if ($f -eq 'Args') {
            if (@($v).Count -eq 0) { W '            Args             = @()' }
            else { W ('            Args             = @({0})' -f ((@($v) | ForEach-Object { Q $_ }) -join ', ')) }
        }
        elseif ($f -eq 'LaunchTimeoutSec') { W ('            LaunchTimeoutSec = {0}' -f $v) }
        elseif ($f -eq 'GpuPreference')    { W ('            GpuPreference    = {0}' -f $v) }
        elseif ($f -eq 'Note' -or $f -eq 'TODO') { W ('            # {0}: {1}' -f $f, $v) }
        else { W ('            {0,-16} = {1}' -f $f, (Q $v)) }
    }
    W '        }'
}
W '    }'
W ''
if ($layouts.Count -gt 0) {
    W '    # A shape several desktops share. {project} is filled in per desktop.'
    W '    Layouts = @{'
    foreach ($k in $layouts.Keys) {
        $n = @($deskLayout.Keys | Where-Object { $deskLayout[$_] -eq $k }).Count
        W ('        {0} = @(   # used by {1} desktop(s)' -f $k, $n)
        foreach ($r in $layouts[$k]) { W ('            ' + (Format-Win -R $r -Template)) }
        W '        )'
    }
    W '    }'
    W ''
}
W '    Desktops = @('
foreach ($d in $desktops) {
    $mine = @($deskRows[$d.Id])
    W '        @{'
    W ('            Index = {0}' -f $d.Index)
    W ('            Name  = {0}' -f (Q $d.Name))
    W ('            Id    = {0}' -f (Q $d.Id))
    if ($skipIds -contains [string]$d.Id) {
        W '            # Not captured (SkipDesktops in capture.psd1). Restore leaves it alone.'
        W '            IntentionallyEmpty = $true'
    }
    elseif ($mine.Count -eq 0) {
        W '            # Empty when captured. Restore never fills it or reports drift.'
        W '            IntentionallyEmpty = $true'
    }
    elseif ($deskLayout.ContainsKey($d.Id)) {
        $proj = @($mine | Where-Object { $_.Project } | Select-Object -First 1)
        $line = '            Layout = {0}' -f (Q $deskLayout[$d.Id])
        if ($proj.Count -gt 0) { $line += ('; Project = {0}' -f (Q $proj[0].Project)) }
        W $line
        if (@($mine | Where-Object { $_.Rule.Key -eq 'cursor' -and -not $_.Project }).Count -gt 0) {
            W '            # TODO: a Cursor window here matched no workspace URI'
        }
    }
    else {
        W '            Windows = @('
        foreach ($r in $mine) { W ('                ' + (Format-Win -R $r)) }
        W '            )'
    }
    W '        }'
}
W '    )'
W ''
W '    # One instance for the whole session, not per desktop.'
W '    Global = @('
foreach ($r in @($rows | Where-Object { $_.Rule.Scope -eq 'global' })) {
    $flags = ''
    if ($r.Rule.AllowHidden) { $flags += '; AllowHidden = $true' }
    if ($r.Rule.NoPosition)  { $flags += '; NoPosition = $true' }
    W ('        @{{ App = {0}; Region = {1}{2}; Match = @{{ TitleContains = {3} }} }}' -f `
        (Q $r.Rule.Key), (Q $r.Region.Name), $flags, (Q $r.Title))
}
W '    )'
W '}'

if ((Test-Path -LiteralPath $Out) -and -not $Force) {
    Write-Host ''
    Write-Host ("Refusing to overwrite {0}" -f $Out) -ForegroundColor Yellow
    Write-Host 'Pass -Force, or -Out <path> to write elsewhere and diff first.' -ForegroundColor Yellow
    return
}

New-Item -ItemType Directory -Path (Split-Path -Parent $Out) -Force | Out-Null
if (Test-Path -LiteralPath $Out) {
    $prevDir = Join-Path $Root '_archive'
    New-Item -ItemType Directory -Path $prevDir -Force | Out-Null
    $prev = Join-Path $prevDir ([IO.Path]::GetFileNameWithoutExtension($Out) + '.previous.psd1')
    Copy-Item -LiteralPath $Out -Destination $prev -Force
    Write-Host ''
    Write-Host ('Previous layout kept: {0}' -f $prev)
}
[System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# Prove it parses before claiming success.
try {
    $check = Import-PowerShellDataFile -LiteralPath $Out
    $nw = 0
    foreach ($d in $check.Desktops) {
        if ($d.Windows) { $nw += @($d.Windows).Count }
        if ($d.Layout -and $check.Layouts.($d.Layout)) { $nw += @($check.Layouts.($d.Layout)).Count }
    }
    $nFree = @($check.Regions.Keys | Where-Object { $null -eq $check.Regions.$_.Col }).Count
    Write-Host ''
    Write-Host ("Written and parsed: {0}" -f $Out) -ForegroundColor Green
    Write-Host ("  {0} desktop(s), {1} window(s), {2} region(s), {3} layout(s), {4} workspace(s), {5} app(s), {6} global" -f `
        @($check.Desktops).Count, $nw, @($check.Regions.Keys).Count, @($check.Layouts.Keys).Count,
        @($check.Workspaces.Keys).Count, @($check.Apps.Keys).Count, @($check.Global).Count)
    if ($nFree -gt 0) {
        Write-Host ("  {0} region(s) are off-grid literals -- a window sitting somewhere unusual:" -f $nFree) -ForegroundColor Yellow
        foreach ($k in ($check.Regions.Keys | Where-Object { $null -eq $check.Regions.$_.Col } | Sort-Object)) {
            $r = $check.Regions.$k
            Write-Host ("      {0,-18} {1}  {2},{3} {4}x{5}" -f $k, $r.Monitor, $r.X, $r.Y, $r.Width, $r.Height) -ForegroundColor Yellow
        }
        Write-Host '    Snap those windows and re-generate, or keep them -- they are real either way.' -ForegroundColor Yellow
    }
    $todo = ([regex]::Matches((Get-Content -LiteralPath $Out -Raw), 'TODO')).Count
    if ($todo -gt 0) { Write-Host ("  {0} TODO comment(s) need your attention" -f $todo) -ForegroundColor Yellow }
} catch {
    Write-Host ''
    Write-Host ("Written but FAILED to parse: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $NoLauncher = $true
}
if (-not $NoLauncher) {
    Write-Host ''
    Write-DevEnvLauncher -Manifest $Out
}
Write-Host ''
