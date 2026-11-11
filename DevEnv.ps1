<#
    DevEnv -- the whole engine, in one file.

    Dot-sourced by Generate.ps1 and Restore.ps1:

        . (Join-Path $PSScriptRoot 'DevEnv.ps1')

    Sections below, in dependency order:
        Interop    native calls (user32, dwmapi, IVirtualDesktopManager)
        Desktop    virtual desktop order, identity, navigation
        Window     enumeration, frame maths, positioning
        Config     load a layout, expand zones and workspaces
        Plan       match, judge, launch, re-assert
        StatusUi   the please-wait panel

    Everything here ships with Windows. Nothing is third-party or installed.
#>

############################################################################
#  DPI AWARENESS
#
#  Must happen before anything reads a screen or creates a window. A DPI-unaware
#  process is shown scaled-down screen sizes (a 3840x2160 panel at 200% reads
#  as 1920x1080), while DWM reports window frames in real pixels -- so windows
#  appear to sit off the monitor and are silently dropped. Per-monitor-aware
#  makes screens, frames and SetWindowPos all use the same physical pixels,
#  on any machine, at any scaling, with one screen or several.
############################################################################

if (-not ('DevEnvDpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DevEnvDpi
{
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    public static void Enable()
    {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }  // per-monitor v2
        try { SetProcessDPIAware(); } catch { }                                       // older Windows
    }
}
'@
}
[DevEnvDpi]::Enable()

############################################################################
#  INTEROP
############################################################################

<#
    DevEnv.Interop -- every native call the module makes, in one place.

    All of it ships with Windows:
      user32.dll              window enumeration, geometry, positioning, keys
      dwmapi.dll              true visible frame bounds
      IVirtualDesktopManager  documented shell COM; reads a window's desktop

    Nothing here is third-party and nothing is installed.
#>

if (-not ('DevEnvNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct DERECT { public int Left, Top, Right, Bottom; }

[ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDeVdm
{
    [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr hwnd, out int onCurrent);
    [PreserveSig] int GetWindowDesktopId(IntPtr hwnd, out Guid desktopId);
    [PreserveSig] int MoveWindowToDesktop(IntPtr hwnd, ref Guid desktopId);
}

[ComImport, Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A")]
public class DeVdmClass { }

public static class DevEnvNative
{
    private delegate bool EnumProc(IntPtr h, IntPtr p);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out DERECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr h, int attr, out DERECT r, int size);
    [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);

    public const uint SWP_NOZORDER   = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const int  SW_RESTORE     = 9;
    public const int  GWL_EXSTYLE    = -20;
    public const int  WS_EX_TOOLWINDOW = 0x00000080;
    public const uint GA_ROOTOWNER   = 3;

    private const byte VK_LWIN = 0x5B, VK_CTRL = 0x11, VK_LEFT = 0x25, VK_RIGHT = 0x27;
    private const uint KEYUP = 0x0002, EXTENDED = 0x0001;

    private static IDeVdm _vdm;
    public static string InitError = "";

    static DevEnvNative()
    {
        try { _vdm = (IDeVdm)(new DeVdmClass()); }
        catch (Exception ex) { InitError = ex.Message; _vdm = null; }
    }

    public static bool VirtualDesktopsAvailable { get { return _vdm != null; } }

    /// <summary>Which virtual desktop a window lives on. Empty string on failure.</summary>
    public static string DesktopIdOf(IntPtr h)
    {
        if (_vdm == null) return "";
        Guid g;
        try { if (_vdm.GetWindowDesktopId(h, out g) == 0) return g.ToString("B").ToUpperInvariant(); }
        catch { }
        return "";
    }

    public static bool IsOnCurrentDesktop(IntPtr h)
    {
        if (_vdm == null) return false;
        int on;
        try { return _vdm.IsWindowOnCurrentVirtualDesktop(h, out on) == 0 && on != 0; }
        catch { return false; }
    }

    /// <summary>
    /// Move a window to another desktop. Windows only permits this for windows
    /// the CALLING process owns, so it works for our status panel and nothing
    /// else. That restriction is why restore walks the desktops.
    /// </summary>
    public static bool MoveOwnWindowToDesktop(IntPtr h, string guid)
    {
        if (_vdm == null) return false;
        try { Guid g = new Guid(guid); return _vdm.MoveWindowToDesktop(h, ref g) == 0; }
        catch { return false; }
    }

    /// <summary>One step left or right, by synthesising Win+Ctrl+Arrow.</summary>
    public static void StepDesktop(bool right)
    {
        byte arrow = right ? VK_RIGHT : VK_LEFT;
        keybd_event(VK_LWIN, 0, 0, IntPtr.Zero);
        keybd_event(VK_CTRL, 0, 0, IntPtr.Zero);
        keybd_event(arrow, 0, EXTENDED, IntPtr.Zero);
        keybd_event(arrow, 0, EXTENDED | KEYUP, IntPtr.Zero);
        keybd_event(VK_CTRL, 0, KEYUP, IntPtr.Zero);
        keybd_event(VK_LWIN, 0, KEYUP, IntPtr.Zero);
    }

    public static List<IntPtr> TopLevelWindows()
    {
        var list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr p) { list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    public static string TitleOf(IntPtr h)
    {
        var sb = new StringBuilder(512);
        int n = GetWindowTextW(h, sb, sb.Capacity);
        return n > 0 ? sb.ToString() : "";
    }

    /// <summary>
    /// The frame you actually see. GetWindowRect includes an invisible resize
    /// border, which is why a window can report x=891 while sitting flush
    /// against a monitor whose left edge is 914.
    /// </summary>
    public static bool FrameOf(IntPtr h, out DERECT r)
    {
        return DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(DERECT))) == 0;
    }
}
'@
}

function Test-DevEnvInterop {
    <#
    .SYNOPSIS
        Is the virtual desktop COM interface usable in this session?
    .OUTPUTS
        PSCustomObject with Available and Error.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        Available = [DevEnvNative]::VirtualDesktopsAvailable
        Error     = [DevEnvNative]::InitError
    }
}

############################################################################
#  DESKTOP
############################################################################

<#
    DevEnv.Desktop -- virtual desktops: enumerate, identify, navigate.

    Windows exposes no public API for the order, the names, or for switching.
    So: order and names come from the registry, "which one am I on" comes from
    the documented COM call, and navigation is synthesised Win+Ctrl+Arrow.
#>

$script:DevEnvVdRoots = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\1\VirtualDesktops'
)

function ConvertTo-DevEnvGuidList {
    <# Split a REG_BINARY blob of packed GUIDs into brace-formatted strings. #>
    [CmdletBinding()]
    param([byte[]] $Bytes)

    $out = @()
    if (-not $Bytes) { return $out }
    for ($i = 0; ($i + 16) -le $Bytes.Length; $i += 16) {
        $b = New-Object byte[] 16
        [Array]::Copy($Bytes, $i, $b, 0, 16)
        $out += (New-Object Guid (,$b)).ToString('B').ToUpperInvariant()
    }
    return $out
}

function Get-DevEnvDesktopOrder {
    <#
    .SYNOPSIS
        The virtual desktops in their current left-to-right order.
    .OUTPUTS
        Array of PSCustomObject: Index (1-based), Id, Name.
    #>
    [CmdletBinding()]
    param()

    $ids = @()
    foreach ($root in $script:DevEnvVdRoots) {
        if ($ids.Count -gt 0) { break }
        try {
            $raw = (Get-ItemProperty -Path $root -Name 'VirtualDesktopIDs' -ErrorAction SilentlyContinue).VirtualDesktopIDs
            $ids = @(ConvertTo-DevEnvGuidList -Bytes $raw)
        } catch { }
    }
    if ($ids.Count -eq 0) { return @() }

    $names = @{}
    try {
        $key = Join-Path $script:DevEnvVdRoots[0] 'Desktops'
        if (Test-Path $key) {
            foreach ($k in Get-ChildItem $key -ErrorAction SilentlyContinue) {
                $g = ('{0}' -f $k.PSChildName).ToUpperInvariant()
                $n = (Get-ItemProperty -Path $k.PSPath -Name 'Name' -ErrorAction SilentlyContinue).Name
                if ($n) { $names[$g] = $n }
            }
        }
    } catch { }

    $i = 0
    $out = @()
    foreach ($g in $ids) {
        $i++
        $out += [pscustomobject]@{
            Index = $i
            Id    = $g
            Name  = if ($names.ContainsKey($g)) { $names[$g] } else { ('Desktop ' + $i) }
        }
    }
    return $out
}

function Get-DevEnvCurrentDesktopId {
    <#
    .SYNOPSIS
        The desktop currently in view.
    .DESCRIPTION
        Preferred path is the documented COM call against any window whose
        desktop we know. Falls back to the registry, which matters when the
        active desktop holds no windows at all.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Windows
    )

    if ($null -eq $Windows) { $Windows = @(Get-DevEnvWindow) }
    foreach ($w in $Windows) {
        if ($w.DesktopId -and $w.DesktopId -ne '{00000000-0000-0000-0000-000000000000}') {
            if ([DevEnvNative]::IsOnCurrentDesktop($w.Handle)) { return $w.DesktopId }
        }
    }

    foreach ($root in $script:DevEnvVdRoots) {
        try {
            $raw = (Get-ItemProperty -Path $root -Name 'CurrentVirtualDesktop' -ErrorAction SilentlyContinue).CurrentVirtualDesktop
            $g = @(ConvertTo-DevEnvGuidList -Bytes $raw)
            if ($g.Count -gt 0) { return $g[0] }
        } catch { }
    }
    return ''
}

function Switch-DevEnvDesktop {
    <#
    .SYNOPSIS
        Navigate to a virtual desktop by id, one verified step at a time.
    .DESCRIPTION
        Presses Win+Ctrl+Arrow once, waits for the active desktop to actually
        change, then reassesses. A swallowed keystroke returns $false rather
        than blind-firing into the wrong desktop.
    .OUTPUTS
        Boolean: did we arrive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $TargetId,
        [int] $TimeoutMs = 4000,
        [scriptblock] $OnWarning
    )

    $order = @(Get-DevEnvDesktopOrder)
    if ($order.Count -eq 0) { return $false }
    $ids = @($order | ForEach-Object { $_.Id })

    $target = $ids.IndexOf($TargetId.ToUpperInvariant())
    if ($target -lt 0) {
        if ($OnWarning) { & $OnWarning "target desktop is not in the current order" }
        return $false
    }

    for ($guard = 0; $guard -lt ($ids.Count + 2); $guard++) {
        $current = Get-DevEnvCurrentDesktopId
        if ($current -eq $TargetId.ToUpperInvariant()) { return $true }

        $from = $ids.IndexOf($current)
        if ($from -lt 0) {
            if ($OnWarning) { & $OnWarning "current desktop could not be identified" }
            return $false
        }

        [DevEnvNative]::StepDesktop($target -gt $from)

        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        $moved = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 150
            if ((Get-DevEnvCurrentDesktopId) -ne $current) { $moved = $true; break }
        }
        if (-not $moved) {
            if ($OnWarning) { & $OnWarning "desktop did not change; keystroke may have been swallowed" }
            return $false
        }
    }
    return ((Get-DevEnvCurrentDesktopId) -eq $TargetId.ToUpperInvariant())
}

############################################################################
#  WINDOW
############################################################################

<#
    DevEnv.Window -- enumerate windows, and move them accurately.

    The frame/border distinction matters everywhere here. We target the frame
    you can see; SetWindowPos speaks in outer rect including the invisible
    resize border. The inset is measured per window rather than assumed,
    because it differs by app and by DPI.
#>

function Get-DevEnvWindow {
    <#
    .SYNOPSIS
        Top-level windows, each tagged with its process, desktop and geometry.
    .PARAMETER IgnoreProcess
        Process names to drop. An entry of the form 'explorer.exe:Program Manager'
        drops only that process/title pair.
    .PARAMETER Process
        If given, keep only these process names.
    .OUTPUTS
        Array of PSCustomObject. Frame* is the visible frame; Outer* is the
        rect including the invisible border.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Process,
        [string[]] $IgnoreProcess = @()
    )

    $byPid = @{}
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        try { $byPid[$p.Id] = [pscustomobject]@{ Name = $p.ProcessName + '.exe'; Path = $p.Path } } catch { }
    }

    $out = @()
    foreach ($h in [DevEnvNative]::TopLevelWindows()) {
        try {
            if ([DevEnvNative]::GetAncestor($h, [DevEnvNative]::GA_ROOTOWNER) -ne $h) { continue }

            $procId = 0
            [void][DevEnvNative]::GetWindowThreadProcessId($h, [ref] $procId)
            if (-not $byPid.ContainsKey([int]$procId)) { continue }
            $info = $byPid[[int]$procId]

            if ($Process -and ($Process -notcontains $info.Name)) { continue }
            if ($IgnoreProcess -contains $info.Name) { continue }

            $title = [DevEnvNative]::TitleOf($h)
            if ($IgnoreProcess -contains ('{0}:{1}' -f $info.Name, $title)) { continue }

            $outer = New-Object DERECT
            [void][DevEnvNative]::GetWindowRect($h, [ref] $outer)
            $frame = New-Object DERECT
            if (-not [DevEnvNative]::FrameOf($h, [ref] $frame)) { $frame = $outer }
            if (($frame.Right - $frame.Left) -le 0) { continue }

            $style = [DevEnvNative]::GetWindowLong($h, [DevEnvNative]::GWL_EXSTYLE)

            $out += [pscustomobject]@{
                Handle      = $h
                ProcessId   = [int]$procId
                Process     = $info.Name
                ExePath     = $info.Path
                Title       = $title
                IsVisible   = [DevEnvNative]::IsWindowVisible($h)
                IsToolWindow= (($style -band [DevEnvNative]::WS_EX_TOOLWINDOW) -ne 0)
                IsMinimized = [DevEnvNative]::IsIconic($h)
                DesktopId   = [DevEnvNative]::DesktopIdOf($h)
                FrameX      = $frame.Left
                FrameY      = $frame.Top
                FrameWidth  = ($frame.Right - $frame.Left)
                FrameHeight = ($frame.Bottom - $frame.Top)
                OuterX      = $outer.Left
                OuterY      = $outer.Top
                OuterWidth  = ($outer.Right - $outer.Left)
                OuterHeight = ($outer.Bottom - $outer.Top)
                ClaimedBy   = $null
            }
        } catch { }
    }
    return $out
}

function Get-DevEnvWindowFrame {
    <#
    .SYNOPSIS
        Re-read a window's visible frame right now.
    .DESCRIPTION
        Needed because some apps move themselves after we position them, so a
        cached rect cannot be trusted when verifying.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Handle)

    $frame = New-Object DERECT
    if (-not [DevEnvNative]::FrameOf($Handle, [ref] $frame)) {
        [void][DevEnvNative]::GetWindowRect($Handle, [ref] $frame)
    }
    [pscustomobject]@{
        X      = $frame.Left
        Y      = $frame.Top
        Width  = ($frame.Right - $frame.Left)
        Height = ($frame.Bottom - $frame.Top)
    }
}

function Test-DevEnvWindowPlaced {
    <#
    .SYNOPSIS
        Is this window already where the target says, within tolerance?
    .PARAMETER Live
        Re-read the geometry instead of trusting the cached values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)] $Target,
        [int]    $Tolerance = 8,
        [switch] $Live
    )

    if ($Live) {
        $f = Get-DevEnvWindowFrame -Handle $Window.Handle
        $x = $f.X; $y = $f.Y; $w = $f.Width; $h = $f.Height
    } else {
        $x = $Window.FrameX; $y = $Window.FrameY
        $w = $Window.FrameWidth; $h = $Window.FrameHeight
    }

    ([Math]::Abs($x - $Target.X) -le $Tolerance) -and
    ([Math]::Abs($y - $Target.Y) -le $Tolerance) -and
    ([Math]::Abs($w - $Target.Width)  -le $Tolerance) -and
    ([Math]::Abs($h - $Target.Height) -le $Tolerance)
}

function Set-DevEnvWindowFrame {
    <#
    .SYNOPSIS
        Move and size a window so its VISIBLE frame matches the target.
    .DESCRIPTION
        Measures this window's invisible border, corrects for it, then verifies
        and retries once. Restores a minimized window first, since a minimized
        window cannot be positioned meaningfully.
    .OUTPUTS
        Boolean: did the frame end up where asked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)] $Target,
        [int] $SettleMs = 400,
        [int] $Attempts = 2
    )

    $h = $Window.Handle

    if ([DevEnvNative]::IsIconic($h)) {
        [void][DevEnvNative]::ShowWindow($h, [DevEnvNative]::SW_RESTORE)
        Start-Sleep -Milliseconds $SettleMs
    }

    $outer = New-Object DERECT
    [void][DevEnvNative]::GetWindowRect($h, [ref] $outer)
    $frame = New-Object DERECT
    if (-not [DevEnvNative]::FrameOf($h, [ref] $frame)) { $frame = $outer }

    # Per-window invisible border. Differs by app and DPI, so never assumed.
    $insetLeft   = $frame.Left   - $outer.Left
    $insetTop    = $frame.Top    - $outer.Top
    $insetRight  = $outer.Right  - $frame.Right
    $insetBottom = $outer.Bottom - $frame.Bottom

    $x  = $Target.X - $insetLeft
    $y  = $Target.Y - $insetTop
    $cx = $Target.Width  + $insetLeft + $insetRight
    $cy = $Target.Height + $insetTop  + $insetBottom

    $flags = [DevEnvNative]::SWP_NOZORDER -bor [DevEnvNative]::SWP_NOACTIVATE

    for ($i = 0; $i -lt $Attempts; $i++) {
        [void][DevEnvNative]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, $cx, $cy, $flags)
        Start-Sleep -Milliseconds $SettleMs
        $now = Get-DevEnvWindowFrame -Handle $h
        if (([Math]::Abs($now.X - $Target.X) -le 10) -and ([Math]::Abs($now.Y - $Target.Y) -le 10)) {
            return $true
        }
    }
    return $false
}

############################################################################
#  CONFIG
############################################################################

<#
    DevEnv.Config -- load a layout file and expand it into concrete targets.

    The config you read is deliberately abstract:

        Monitors    a screen, and the grid it is divided into
        Regions     a named span of grid cells      'M1.center'
        Workspaces  a Cursor folder URI, named once  'CLI'
        Layouts     a window shape many desktops share
        Desktops    reference those by name          @{ App='cursor'; Region='M1.left'; Project='CLI' }

    Expansion resolves all of that into absolute pixels and real URIs, so the
    rest of the module never deals with names and the config never deals with
    pixels.
#>

function Import-DevEnvConfig {
    <#
    .SYNOPSIS
        Read a .psd1 or .json layout file.
    .DESCRIPTION
        .psd1 goes through Import-PowerShellDataFile, which parses DATA ONLY --
        a layout file can never execute code. Hashtable member access is
        case-insensitive, so key casing in the file does not matter.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Layout file not found: $Path" }

    if ($Path -like '*.psd1') {
        return Import-PowerShellDataFile -LiteralPath $Path
    }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Resolve-DevEnvMonitor {
    <#
    .SYNOPSIS
        Map each configured monitor key to a real screen.
    .DESCRIPTION
        Matches on primary-flag plus resolution, not device name, so Windows
        re-enumerating displays after a restart cannot silently send windows
        to the wrong screen. Device name is a last-resort fallback.
    .OUTPUTS
        Hashtable of key -> PSCustomObject (Key, DeviceName, X, Y, Width, Height, MatchedBy).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [scriptblock] $OnWarning
    )

    Add-Type -AssemblyName System.Windows.Forms
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    $map  = @{}
    $used = @{}

    function Add-Mon {
        param($Cfg, $Screen, [string] $How)
        $cols = 1; $rows = 1
        if ($Cfg.Grid) {
            if ($Cfg.Grid.Cols) { $cols = [int]$Cfg.Grid.Cols }
            if ($Cfg.Grid.Rows) { $rows = [int]$Cfg.Grid.Rows }
        }
        $map[[string]$Cfg.Key] = [pscustomobject]@{
            Key        = [string]$Cfg.Key
            DeviceName = $Screen.DeviceName
            X          = $Screen.Bounds.X
            Y          = $Screen.Bounds.Y
            Width      = $Screen.Bounds.Width
            Height     = $Screen.Bounds.Height
            # Regions divide the WORK area, not the bounds, so a region never
            # lands under the taskbar and the same region name survives a
            # screen of a different size.
            WorkX      = $Screen.WorkingArea.X
            WorkY      = $Screen.WorkingArea.Y
            WorkWidth  = $Screen.WorkingArea.Width
            WorkHeight = $Screen.WorkingArea.Height
            Cols       = [Math]::Max(1, $cols)
            Rows       = [Math]::Max(1, $rows)
            MatchedBy  = $How
        }
        $used[$Screen.DeviceName] = $true
    }

    $cfgMons = @($Config.Monitors)
    $free    = { $screens | Where-Object { -not $used.ContainsKey($_.DeviceName) } }

    # Pass 1 -- primary flag plus exact resolution. The trustworthy case.
    foreach ($m in $cfgMons) {
        $hit = & $free | Where-Object {
            $_.Primary -eq $m.Match.Primary -and
            $_.Bounds.Width  -eq $m.Match.Width -and
            $_.Bounds.Height -eq $m.Match.Height
        } | Select-Object -First 1
        if ($hit) { Add-Mon -Cfg $m -Screen $hit -How 'resolution' }
    }

    # Pass 2 -- device name, for a screen that changed resolution in place.
    foreach ($m in $cfgMons) {
        if ($map.ContainsKey([string]$m.Key) -or -not $m.FallbackDeviceName) { continue }
        $hit = & $free | Where-Object { $_.DeviceName -eq $m.FallbackDeviceName } | Select-Object -First 1
        if ($hit) {
            Add-Mon -Cfg $m -Screen $hit -How 'device name'
            if ($OnWarning) { & $OnWarning ("monitor {0} matched by device name, not resolution" -f $m.Key) }
        }
    }

    # Pass 3 -- role and position: the primary screen for the primary entry,
    # then remaining screens in order. Different hardware entirely, which is
    # why regions are fractions of the work area rather than pixels.
    foreach ($m in $cfgMons) {
        if ($map.ContainsKey([string]$m.Key)) { continue }
        $hit = if ($m.Match.Primary) {
            & $free | Where-Object { $_.Primary } | Select-Object -First 1
        } else {
            & $free | Where-Object { -not $_.Primary } | Select-Object -First 1
        }
        if ($hit) {
            Add-Mon -Cfg $m -Screen $hit -How 'position (different screen size)'
            if ($OnWarning) {
                & $OnWarning ("monitor {0} was captured at {1}x{2} but matched a {3}x{4} screen; regions rescale" -f `
                    $m.Key, $m.Match.Width, $m.Match.Height, $hit.Bounds.Width, $hit.Bounds.Height)
            }
        }
        elseif ($OnWarning) {
            & $OnWarning ("monitor {0} has NO match; its windows will be skipped" -f $m.Key)
        }
    }

    return $map
}

function Resolve-DevEnvTarget {
    <#
    .SYNOPSIS
        Turn one window entry into an absolute rectangle.
    .DESCRIPTION
        A region is normally a span of cells in its monitor's grid, so the
        pixels are computed here from the live work area rather than stored.
        A region may instead carry a literal X/Y/Width/Height for a window
        that does not sit on the grid at all.

        Also accepts an inline literal (Monitor + Frame) for hand edits.
        Returns $null when the monitor is absent, so callers can skip rather
        than place windows off-screen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $MonitorMap
    )

    # 'Zone' is the former name for 'Region'; both read the same table.
    $regionName = if ($Entry.Region) { [string]$Entry.Region } elseif ($Entry.Zone) { [string]$Entry.Zone } else { $null }
    $table      = if ($Config.Regions) { $Config.Regions } else { $Config.Zones }

    if ($regionName) {
        $r = $table.$regionName
        if (-not $r) { throw "Entry references unknown region '$regionName'" }
        $monKey = [string]$r.Monitor
        if (-not $MonitorMap.ContainsKey($monKey)) { return $null }
        $mon = $MonitorMap[$monKey]

        if ($null -ne $r.Col -or $null -ne $r.Row) {
            # Grid cell span. Rounded off the running total so adjacent
            # regions share an edge exactly and leave no seam.
            $col     = if ($r.Col) { [int]$r.Col } else { 1 }
            $row     = if ($r.Row) { [int]$r.Row } else { 1 }
            $colSpan = if ($r.ColSpan) { [int]$r.ColSpan } else { 1 }
            $rowSpan = if ($r.RowSpan) { [int]$r.RowSpan } else { 1 }

            $cw = $mon.WorkWidth  / $mon.Cols
            $ch = $mon.WorkHeight / $mon.Rows
            $x0 = [int][Math]::Round(($col - 1) * $cw)
            $y0 = [int][Math]::Round(($row - 1) * $ch)
            $x1 = [int][Math]::Round([Math]::Min($col - 1 + $colSpan, $mon.Cols) * $cw)
            $y1 = [int][Math]::Round([Math]::Min($row - 1 + $rowSpan, $mon.Rows) * $ch)

            return [pscustomobject]@{
                Monitor = $monKey
                Region  = $regionName
                X       = $mon.WorkX + $x0
                Y       = $mon.WorkY + $y0
                Width   = $x1 - $x0
                Height  = $y1 - $y0
            }
        }

        # Literal region, relative to the monitor origin.
        return [pscustomobject]@{
            Monitor = $monKey
            Region  = $regionName
            X       = $mon.X + [int]$r.X
            Y       = $mon.Y + [int]$r.Y
            Width   = [int]$r.Width
            Height  = [int]$r.Height
        }
    }

    if ($Entry.Monitor -and $Entry.Frame) {
        $monKey = [string]$Entry.Monitor
        if (-not $MonitorMap.ContainsKey($monKey)) { return $null }
        $mon = $MonitorMap[$monKey]
        return [pscustomobject]@{
            Monitor = $monKey
            Region  = $null
            X       = $mon.X + [int]$Entry.Frame.X
            Y       = $mon.Y + [int]$Entry.Frame.Y
            Width   = [int]$Entry.Frame.Width
            Height  = [int]$Entry.Frame.Height
        }
    }

    throw 'Entry has neither Region nor Monitor+Frame'
}

function Expand-DevEnvConfig {
    <#
    .SYNOPSIS
        Flatten the config into one concrete entry per expected window.
    .PARAMETER DesktopFilter
        Names or indices to keep. Omit for all.
    .OUTPUTS
        Array of PSCustomObject, each with absolute X/Y/Width/Height, resolved
        Uri and TitleContains, and the app definition attached.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $MonitorMap,
        [string[]] $DesktopFilter,
        [switch]   $SkipGlobal,
        [scriptblock] $OnWarning
    )

    function Test-Selected {
        param($Desktop)
        if (-not $DesktopFilter) { return $true }
        foreach ($f in $DesktopFilter) {
            if ($f -eq ([string]$Desktop.Index)) { return $true }
            if ($f -eq [string]$Desktop.Name)    { return $true }
        }
        return $false
    }

    function Expand-Tokens {
        <# Copy a template window, filling {project} / {path} from the desktop.
           A copy, because one template is shared by many desktops. #>
        param($Win, $Desktop)
        $out = @{}
        foreach ($k in @($Win.Keys)) {
            $v = $Win[$k]
            if ($v -is [string]) {
                $v = $v.Replace('{project}', [string]$Desktop.Project).
                        Replace('{path}',    [string]$Desktop.Path)
            }
            $out[$k] = $v
        }
        return $out
    }

    function Get-DesktopWindows {
        <# A desktop's windows: its layout template expanded, plus any of its
           own extra Windows. Either part may be absent. #>
        param($Desktop)
        $list = @()
        if ($Desktop.Layout) {
            $name = [string]$Desktop.Layout
            $tpl  = if ($Config.Layouts) { $Config.Layouts.$name } else { $null }
            if (-not $tpl) {
                if ($OnWarning) { & $OnWarning ("desktop '{0}' uses unknown layout '{1}'" -f $Desktop.Name, $name) }
            } else {
                foreach ($t in @($tpl)) { $list += (Expand-Tokens -Win $t -Desktop $Desktop) }
            }
        }
        foreach ($w in @($Desktop.Windows)) { if ($w) { $list += $w } }
        return $list
    }

    function New-Entry {
        param($Win, $Scope, $Desktop)

        $appKey = [string]$Win.App
        $app    = $Config.Apps.$appKey
        if (-not $app) {
            if ($OnWarning) { & $OnWarning ("unknown app key '{0}'" -f $appKey) }
            return $null
        }

        $target = Resolve-DevEnvTarget -Entry $Win -Config $Config -MonitorMap $MonitorMap
        if (-not $target) { return $null }

        # A named project resolves to both the folder URI and the title
        # fragment used to tell one Cursor window from another.
        $uri   = $Win.Uri
        $title = if ($Win.Match) { $Win.Match.TitleContains } else { $null }
        if ($Win.Project) {
            if (-not $uri) {
                $uri = $Config.Workspaces.($Win.Project)
                if (-not $uri -and $OnWarning) {
                    & $OnWarning ("project '{0}' has no entry under Workspaces" -f $Win.Project)
                }
            }
            if (-not $title) { $title = [string]$Win.Project }
        }

        [pscustomobject]@{
            Scope         = $Scope
            DesktopIndex  = if ($Desktop) { [int]$Desktop.Index } else { 0 }
            DesktopName   = if ($Desktop) { [string]$Desktop.Name } else { '(all desktops)' }
            DesktopId     = if ($Desktop) { ([string]$Desktop.Id).ToUpperInvariant() } else { '' }
            AppKey        = $appKey
            Process       = [string]$app.Process
            Policy        = if ($app.Policy) { [string]$app.Policy } else { 'launch' }
            App           = $app
            Region        = $target.Region
            Monitor       = $target.Monitor
            X             = $target.X
            Y             = $target.Y
            Width         = $target.Width
            Height        = $target.Height
            Project       = $Win.Project
            Uri           = $uri
            Path          = $Win.Path
            TitleContains = $title
            AllowHidden   = [bool]$Win.AllowHidden
            NoPosition    = [bool]$Win.NoPosition
            Window        = $null
        }
    }

    $entries = @()

    foreach ($d in @($Config.Desktops)) {
        if (-not (Test-Selected -Desktop $d)) { continue }
        if ($d.IntentionallyEmpty) { continue }
        foreach ($w in (Get-DesktopWindows -Desktop $d)) {
            $e = New-Entry -Win $w -Scope 'desktop' -Desktop $d
            if ($e) { $entries += $e }
        }
    }

    if (-not $SkipGlobal -and -not $DesktopFilter) {
        foreach ($w in @($Config.Global)) {
            if (-not $w) { continue }
            $e = New-Entry -Win $w -Scope 'global' -Desktop $null
            if ($e) { $entries += $e }
        }
    }

    return $entries
}

function Get-DevEnvTiming {
    <#
    .SYNOPSIS
        Timing values, from the config's Timing block or sane defaults.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $t = $Config.Timing
    [pscustomobject]@{
        SettleMs        = if ($t -and $t.SettleMs)        { [int]$t.SettleMs }        elseif ($Config.SettleMs)        { [int]$Config.SettleMs }        else { 400 }
        SwitchTimeoutMs = if ($t -and $t.SwitchTimeoutMs) { [int]$t.SwitchTimeoutMs } elseif ($Config.SwitchTimeoutMs) { [int]$Config.SwitchTimeoutMs } else { 4000 }
        ReassertDelayMs = if ($t -and $t.ReassertDelayMs) { [int]$t.ReassertDelayMs } elseif ($Config.ReassertDelayMs) { [int]$Config.ReassertDelayMs } else { 3000 }
        ReassertRounds  = if ($t -and $t.ReassertRounds)  { [int]$t.ReassertRounds }  elseif ($Config.ReassertRounds)  { [int]$Config.ReassertRounds }  else { 2 }
    }
}

############################################################################
#  PLAN
############################################################################

<#
    DevEnv.Plan -- decide what to do, and launch things.

    Matching is two-pass, and that is what makes restore idempotent:
      pass 1  claim windows already sitting in their target
      pass 2  claim the nearest unclaimed window of the same app

    So a second run finds everything already claimed in pass 1, computes a
    shortfall of zero, and does nothing.
#>

function Join-DevEnvWindow {
    <#
    .SYNOPSIS
        Match expected entries to real windows, in place.
    .DESCRIPTION
        Sets Entry.Window and Window.ClaimedBy. Candidates must agree on
        process, desktop, and the title fragment when one is given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Entries,
        [Parameter(Mandatory)] [object[]] $Windows,
        [int] $Tolerance = 8
    )

    function Get-Candidate {
        param($Entry)
        @($Windows | Where-Object {
            $null -eq $_.ClaimedBy -and
            $_.Process -eq $Entry.Process -and
            ($Entry.AllowHidden -or ($_.IsVisible -and -not $_.IsToolWindow -and $_.Title)) -and
            ([string]::IsNullOrEmpty($Entry.DesktopId) -or $_.DesktopId -eq $Entry.DesktopId) -and
            ($null -eq $Entry.TitleContains -or $_.Title -like ('*' + $Entry.TitleContains + '*'))
        })
    }

    # Pass 1 -- already in place.
    foreach ($e in $Entries) {
        foreach ($w in (Get-Candidate -Entry $e)) {
            if (Test-DevEnvWindowPlaced -Window $w -Target $e -Tolerance $Tolerance) {
                $w.ClaimedBy = $e; $e.Window = $w; break
            }
        }
    }

    # Pass 2 -- nearest unclaimed.
    foreach ($e in ($Entries | Where-Object { $null -eq $_.Window })) {
        $best = Get-Candidate -Entry $e |
                Sort-Object { [Math]::Abs($_.FrameX - $e.X) + [Math]::Abs($_.FrameY - $e.Y) } |
                Select-Object -First 1
        if ($best) { $best.ClaimedBy = $e; $e.Window = $best }
    }
}

function Get-DevEnvVerdict {
    <#
    .SYNOPSIS
        What needs doing to this one entry: ok, move, launch, missing, leave.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [int] $Tolerance = 8
    )

    if ($null -eq $Entry.Window) {
        if ($Entry.Policy -eq 'place') { return 'missing' }
        return 'launch'
    }
    if ($Entry.NoPosition) { return 'leave' }
    if (Test-DevEnvWindowPlaced -Window $Entry.Window -Target $Entry -Tolerance $Tolerance) { return 'ok' }
    return 'move'
}

function Get-DevEnvSurplus {
    <#
    .SYNOPSIS
        Real windows of known apps that no entry claimed.
    .DESCRIPTION
        Reported so you can see them, never acted on. Nothing is ever closed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Windows,
        [Parameter(Mandatory)] [object[]] $Entries
    )

    $known = @($Entries | ForEach-Object { $_.Process } | Select-Object -Unique)
    @($Windows | Where-Object {
        $null -eq $_.ClaimedBy -and $_.IsVisible -and -not $_.IsToolWindow -and
        $_.Title -and ($known -contains $_.Process)
    })
}

function Resolve-DevEnvLaunchPath {
    <#
    .SYNOPSIS
        The executable for an app definition.
    .DESCRIPTION
        PathGlob exists for self-extracting builds whose filename carries a
        version number; the newest match wins so an upgrade does not break it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App)

    if ($App.Path -and (Test-Path -LiteralPath $App.Path)) { return $App.Path }
    if ($App.PathGlob) {
        $c = @(Get-ChildItem -Path $App.PathGlob -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
        if ($c.Count -gt 0) { return $c[0].FullName }
    }
    return $null
}

function Start-DevEnvWindow {
    <#
    .SYNOPSIS
        Launch one window for an entry and return the window that appeared.
    .DESCRIPTION
        New windows always appear on the ACTIVE desktop, so the caller must
        already be on the right one. Identifies the new window by diffing
        handles for that process before and after, which is reliable even for
        apps like Chrome where every window shares one process.
    .OUTPUTS
        The new window object, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [string[]] $IgnoreProcess = @(),
        [scriptblock] $OnWarning
    )

    $exe = Resolve-DevEnvLaunchPath -App $Entry.App
    if (-not $exe) {
        if ($OnWarning) { & $OnWarning ("cannot resolve a launch path for {0}" -f $Entry.Process) }
        return $null
    }

    $argv = @()
    foreach ($a in @($Entry.App.Args)) {
        $s = [string]$a
        if ($Entry.Uri)  { $s = $s.Replace('{uri}',  $Entry.Uri) }
        if ($Entry.Path) { $s = $s.Replace('{path}', $Entry.Path) }
        $argv += $s
    }

    # Windows Graphics Settings, per exe: 0 = let Windows decide, 1 = power
    # saving, 2 = high performance. Same value TOOLBAR-LITE.bat wrote by hand.
    # HKCU, so no elevation; harmless on a machine with only one GPU.
    if ($Entry.App.GpuPreference) {
        try {
            $key = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -Path $key -Name $exe -PropertyType String `
                -Value ('GpuPreference={0};' -f [int]$Entry.App.GpuPreference) -Force | Out-Null
        } catch {
            if ($OnWarning) { & $OnWarning ("could not set GPU preference: {0}" -f $_.Exception.Message) }
        }
    }

    $before = @((Get-DevEnvWindow -Process $Entry.Process -IgnoreProcess $IgnoreProcess).Handle)

    # Launched through a short-lived HIDDEN PowerShell, not directly. A direct
    # child shares this console, and Electron apps (Cursor) attach to their
    # parent's console and log into it -- so the console never finishes, and
    # closing it kills every app underneath. Via the hidden launcher the app
    # hangs off a console nobody sees, and this one is free to exit.
    # The command travels base64-encoded so no quoting layer can mangle a URI.
    try {
        $sq = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
        $inner = 'Start-Process -FilePath ' + (& $sq $exe)
        if ($argv.Count -gt 0) {
            $quoted = @($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } } |
                        ForEach-Object { & $sq $_ })
            $inner += ' -ArgumentList @(' + ($quoted -join ',') + ')'
        }
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) | Out-Null
    } catch {
        if ($OnWarning) { & $OnWarning ("launch failed: {0}" -f $_.Exception.Message) }
        return $null
    }

    $timeout = if ($Entry.App.LaunchTimeoutSec) { [int]$Entry.App.LaunchTimeoutSec } else { 25 }
    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $now  = @(Get-DevEnvWindow -Process $Entry.Process -IgnoreProcess $IgnoreProcess)
        # Only a REAL window counts -- the same test Join-DevEnvWindow uses.
        # Chrome creates hidden helper windows on startup; taking the first new
        # handle meant positioning an invisible window while the real one
        # opened wherever Chrome liked, and the re-check then "verified" the
        # invisible one.
        # AllowHidden apps (tray toolbars) may be invisible, but still need a
        # title -- and the expected one, when the entry names it. A
        # self-extracting app shows helper windows first; taking one of those
        # meant the real window arrived after we had stopped looking.
        $fresh = @($now | Where-Object {
            $before -notcontains $_.Handle -and
            -not [string]::IsNullOrWhiteSpace($_.Title) -and
            ($Entry.AllowHidden -or ($_.IsVisible -and -not $_.IsToolWindow)) -and
            ($null -eq $Entry.TitleContains -or $_.Title -like ('*' + $Entry.TitleContains + '*'))
        })
        if ($fresh.Count -gt 0) { return $fresh[0] }
    }

    if ($OnWarning) { & $OnWarning ("no new {0} window appeared within {1}s" -f $Entry.Process, $timeout) }
    return $null
}

function Invoke-DevEnvReassert {
    <#
    .SYNOPSIS
        Re-fix windows that moved themselves after being positioned.
    .DESCRIPTION
        Electron apps (Cursor among them) restore their own saved bounds once
        initialisation finishes, overriding a move that already verified. So
        wait, re-read live geometry, and fix what drifted back.
    .OUTPUTS
        Number of windows re-asserted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Entries,
        [int] $DelayMs = 3000,
        [int] $Rounds  = 2,
        [int] $SettleMs = 400,
        [scriptblock] $OnRound,
        [scriptblock] $OnFixed,
        [scriptblock] $OnWarning
    )

    $managed = @($Entries | Where-Object { $_.Window -and -not $_.NoPosition })
    if ($managed.Count -eq 0) { return 0 }

    $fixed = 0
    for ($r = 1; $r -le $Rounds; $r++) {
        if ($OnRound) { & $OnRound $r $Rounds }
        Start-Sleep -Milliseconds $DelayMs

        $drift = @($managed | Where-Object {
            -not (Test-DevEnvWindowPlaced -Window $_.Window -Target $_ -Live)
        })
        if ($drift.Count -eq 0) { break }

        foreach ($e in $drift) {
            if (Set-DevEnvWindowFrame -Window $e.Window -Target $e -SettleMs $SettleMs) {
                $fixed++
                if ($OnFixed) { & $OnFixed $e }
            } elseif ($OnWarning) {
                & $OnWarning ("{0} keeps overriding the move" -f $e.Process)
            }
        }
    }
    return $fixed
}

############################################################################
#  STATUSUI
############################################################################

<#
    DevEnv.StatusUi -- the "please wait" panel.

    Borderless, always on top, no taskbar entry. It follows the active desktop
    as restore walks around, which is allowed because the panel belongs to our
    own process (see MoveOwnWindowToDesktop in DevEnv.Interop).
#>

$script:DevEnvUi     = $null
$script:DevEnvUiNext = $false
$script:DevEnvUiStop = $false
$script:DevEnvUiPlan = @()

function New-DevEnvStatus {
    <#
    .SYNOPSIS
        Show the status panel.
    .DESCRIPTION
        Sized as a share of the screen (30% of its width), centred, and laid out
        by flow rather than fixed pixels: text wraps and the panel grows to fit,
        so it reads the same at any resolution or display scaling.
    .PARAMETER Rehearsal
        Adds a plan pane and Next/Stop buttons.
    #>
    [CmdletBinding()]
    param(
        [switch] $Rehearsal,
        [switch] $Disabled
    )

    if ($Disabled) { return }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $area  = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $width = [int]($area.Width * 0.30)
    $pad   = [int]($width * 0.05)
    $inner = $width - (2 * $pad)

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.TopMost         = $true
    $form.ShowInTaskbar   = $false
    $form.StartPosition   = 'Manual'
    $form.BackColor       = [System.Drawing.Color]::FromArgb(18, 18, 22)
    $form.Padding         = New-Object System.Windows.Forms.Padding($pad)
    $form.AutoSize        = $true
    $form.AutoSizeMode    = 'GrowAndShrink'
    $form.MinimumSize     = New-Object System.Drawing.Size($width, 0)
    $form.MaximumSize     = New-Object System.Drawing.Size($width, $area.Height)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents  = $false
    $flow.AutoSize      = $true
    $flow.AutoSizeMode  = 'GrowAndShrink'
    $flow.Dock          = 'Top'
    $flow.BackColor     = $form.BackColor

    $gap   = [int]($pad / 2)
    $reg   = [System.Drawing.FontStyle]::Regular
    $bold  = [System.Drawing.FontStyle]::Bold
    $amber = [System.Drawing.Color]::FromArgb(255, 193, 94)
    $blue  = [System.Drawing.Color]::FromArgb(170, 220, 255)
    $green = [System.Drawing.Color]::FromArgb(140, 230, 150)
    $grey  = [System.Drawing.Color]::FromArgb(130, 130, 140)

    function New-Lbl {
        param($Text, $Colour, $FontName, $Size, $Style)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text        = $Text
        $lbl.ForeColor   = $Colour
        $lbl.Font        = New-Object System.Drawing.Font($FontName, $Size, $Style)
        $lbl.AutoSize    = $true
        $lbl.MaximumSize = New-Object System.Drawing.Size($inner, 0)
        $lbl.Margin      = New-Object System.Windows.Forms.Padding(0, 0, 0, $gap)
        return $lbl
    }

    $title = New-Lbl 'Setting up your dev environment' ([System.Drawing.Color]::White) 'Segoe UI' 14 $bold
    $wait  = New-Lbl 'Hands off the keyboard until this says Done.' $amber 'Segoe UI' 10 $reg
    $step  = New-Lbl 'starting...' $blue 'Segoe UI' 11 $reg
    $prog  = New-Lbl '' $green 'Segoe UI' 9 $reg
    $hint  = New-Lbl '' $grey  'Segoe UI' 9 $reg
    $plan  = New-Lbl '' ([System.Drawing.Color]::FromArgb(210, 210, 220)) 'Consolas' 9 $reg
    $plan.Visible = [bool]$Rehearsal
    $prog.Visible = $false   # shown once the first desktop is done

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = 'Next desktop'
    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = 'Stop'
    foreach ($btn in @($btnNext, $btnStop)) {
        $btn.AutoSize  = $true
        $btn.FlatStyle = 'Flat'
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.Padding   = New-Object System.Windows.Forms.Padding($gap, 2, $gap, 2)
        $btn.Margin    = New-Object System.Windows.Forms.Padding(0, 0, $gap, 0)
        $btn.Visible   = $false
    }
    $btnNext.BackColor = [System.Drawing.Color]::FromArgb(45, 95, 60)
    $btnStop.BackColor = [System.Drawing.Color]::FromArgb(95, 45, 45)
    $btnNext.Add_Click({ $script:DevEnvUiNext = $true })
    $btnStop.Add_Click({ $script:DevEnvUiStop = $true })

    $flow.Controls.AddRange(@($title, $wait, $step, $prog, $hint, $plan))
    if ($Rehearsal) {
        $row = New-Object System.Windows.Forms.FlowLayoutPanel
        $row.FlowDirection = 'LeftToRight'
        $row.AutoSize      = $true
        $row.Margin        = New-Object System.Windows.Forms.Padding(0)
        $row.Controls.AddRange(@($btnNext, $btnStop))
        $flow.Controls.Add($row)
    }
    $form.Controls.Add($flow)

    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $form.Location = New-Object System.Drawing.Point(
        ($area.X + [int](($area.Width - $form.Width) / 2)),
        ($area.Y + [int]($area.Height * 0.25)))
    [System.Windows.Forms.Application]::DoEvents()

    $script:DevEnvUi = [pscustomobject]@{
        Form = $form; Title = $title; Wait = $wait; Step = $step
        Prog = $prog; Hint = $hint; Plan = $plan
        BtnNext = $btnNext; BtnStop = $btnStop
        Rehearsal = [bool]$Rehearsal
    }
}

function Initialize-DevEnvStatusPlan {
    <#
    .SYNOPSIS
        Record which desktops this run will touch, for "desktop 3 of 7".
    #>
    [CmdletBinding()]
    param([object[]] $Desktops)

    $script:DevEnvUiPlan = @()
    foreach ($d in @($Desktops)) {
        $script:DevEnvUiPlan += [pscustomobject]@{
            Index = [int]$d.Index
            Name  = [string]$d.Name
            State = 'pending'
        }
    }
}

function Set-DevEnvStatusDesktop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $Index,
        [Parameter(Mandatory)][ValidateSet('pending','active','done')][string] $State
    )

    foreach ($r in $script:DevEnvUiPlan) { if ($r.Index -eq $Index) { $r.State = $State } }
    if (-not $script:DevEnvUi) { return }

    $total  = $script:DevEnvUiPlan.Count
    $done   = @($script:DevEnvUiPlan | Where-Object { $_.State -eq 'done' })
    $active = @($script:DevEnvUiPlan | Where-Object { $_.State -eq 'active' } | Select-Object -First 1)

    if ($active.Count -gt 0) {
        $script:DevEnvUi.Step.Text = ('desktop {0} of {1}:  {2}' -f ($done.Count + 1), $total, $active[0].Name)
    }
    if ($done.Count -gt 0) {
        $script:DevEnvUi.Prog.Text = 'established: ' + (($done | ForEach-Object { $_.Name }) -join ', ')
        $script:DevEnvUi.Prog.Visible = $true
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-DevEnvStatus {
    [CmdletBinding()]
    param([string] $Step, [string] $Hint)

    if (-not $script:DevEnvUi) { return }
    if ($PSBoundParameters.ContainsKey('Step')) { $script:DevEnvUi.Step.Text = $Step }
    if ($PSBoundParameters.ContainsKey('Hint')) { $script:DevEnvUi.Hint.Text = $Hint }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-DevEnvStatusRehearsal {
    [CmdletBinding()]
    param([string[]] $Lines)

    if (-not $script:DevEnvUi) { return }
    $script:DevEnvUi.Plan.Text = ($Lines -join "`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

function Move-DevEnvStatus {
    <#
    .SYNOPSIS
        Bring the panel to a given virtual desktop so it stays visible.
    #>
    [CmdletBinding()]
    param([string] $DesktopId)

    if (-not $script:DevEnvUi -or -not $DesktopId) { return }
    [void][DevEnvNative]::MoveOwnWindowToDesktop($script:DevEnvUi.Form.Handle, $DesktopId)
    $script:DevEnvUi.Form.TopMost = $true
    [System.Windows.Forms.Application]::DoEvents()
}

function Wait-DevEnvStatusStep {
    <#
    .SYNOPSIS
        Block until the user clicks Next or Stop.
    .OUTPUTS
        Boolean: $false if they chose Stop.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:DevEnvUi) { Start-Sleep -Seconds 2; return $true }

    $script:DevEnvUiNext = $false
    $script:DevEnvUiStop = $false
    $script:DevEnvUi.BtnNext.Visible = $true
    $script:DevEnvUi.BtnStop.Visible = $true
    $script:DevEnvUi.Hint.Text = 'review this desktop, then click Next'

    while (-not $script:DevEnvUiNext -and -not $script:DevEnvUiStop) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    return (-not $script:DevEnvUiStop)
}

function Complete-DevEnvStatus {
    <#
    .SYNOPSIS
        Switch the panel to its finished state, count down, close.
    #>
    [CmdletBinding()]
    param(
        [int]    $Changes = 0,
        [switch] $Rehearsal,
        [int]    $CloseAfterSec = 6
    )

    if (-not $script:DevEnvUi) { return }
    $green = [System.Drawing.Color]::FromArgb(140, 230, 150)
    $done  = @($script:DevEnvUiPlan | Where-Object { $_.State -eq 'done' }).Count

    $script:DevEnvUi.BtnNext.Visible = $false
    $script:DevEnvUi.BtnStop.Visible = $false
    $script:DevEnvUi.Step.Text       = ''
    $script:DevEnvUi.Title.ForeColor = $green
    $script:DevEnvUi.Wait.ForeColor  = $green

    if ($Rehearsal) {
        $script:DevEnvUi.Title.Text = 'Rehearsal complete - nothing was changed'
        $script:DevEnvUi.Wait.Text  = ('{0} desktop(s) walked. Nothing launched, moved or closed.' -f $done)
    } else {
        $script:DevEnvUi.Title.Text = 'Done - your dev environment is ready'
        $script:DevEnvUi.Wait.Text  = ('{0} desktop(s) established, {1} change(s). Keyboard is yours again.' -f $done, $Changes)
    }

    for ($i = $CloseAfterSec; $i -ge 1; $i--) {
        $script:DevEnvUi.Hint.Text = ('closing in {0} second(s)' -f $i)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
    }
    Close-DevEnvStatus
}

function Close-DevEnvStatus {
    <#
    .SYNOPSIS
        Dispose the panel. Safe to call repeatedly, including from a trap.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:DevEnvUi) { return }
    try { $script:DevEnvUi.Form.Close(); $script:DevEnvUi.Form.Dispose() } catch { }
    $script:DevEnvUi = $null
}

