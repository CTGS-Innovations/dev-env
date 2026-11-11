# DEV-ENV

Put your dev environment back after a restart: the right windows, on the right
virtual desktops, in the right places.

```
DevEnv.ps1                  the engine
Generate.ps1                capture what's running now into this machine's config
Restore.ps1                 replay this machine's config
layout.<COMPUTERNAME>.psd1  one config per machine, e.g. layout.ATLAS.psd1, layout.XPS-C.psd1
Restore-DevEnv.cmd          double-click launcher; works on any machine (written by Generate)
logs\                       one log per restore run
```

**One folder, every machine.** Each machine's config is named for it, and
Restore loads `layout.<COMPUTERNAME>.psd1` for whichever machine it's running
on. (`layout.psd1` is the fallback if no machine-named file exists.) Copy the
whole folder anywhere; on a new machine, capture once and it's set.

**Launchers.** Every successful Generate also writes
`Desktop\DevEnv - <MACHINE>.cmd` — double-click to restore. It runs
`Restore -Apply` and pauses only if something fails. Extra arguments pass
through: `"DevEnv - ATLAS.cmd" -Desktop Main`. To recreate the launcher
without capturing (e.g. after moving the folder): `Generate.ps1 -LauncherOnly`.

Copy the folder to any machine. Nothing is installed and nothing is
third-party — it calls in-box Windows only (`user32.dll`, `dwmapi.dll`,
`IVirtualDesktopManager`).

## A second machine

**Generate there.** It's two commands and it needs nothing from your other
machine:

```powershell
# 1. arrange the laptop the way you want it, then:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Generate.ps1"
# 2. later:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Restore.ps1" -Apply
```

Generate reads that machine's screens, its own grid, its virtual desktop GUIDs,
its Cursor workspaces and its real exe paths. Nothing in the scripts is
machine-specific — the config is.

A config **carried** from another machine also runs, degrading in named ways:

| Difference | What happens |
|---|---|
| Desktop GUIDs don't exist here | Matched by position instead — desktop 3 there is desktop 3 here. Warned. |
| Fewer virtual desktops than the config | The extras are reported and skipped. Desktops are never created for you. |
| A monitor is missing (no second screen) | That monitor's windows are skipped. Warned. |
| A screen is a different size | Regions rescale: a third of 5120 becomes a third of 1920. Correct, but cramped. |

So carrying a config gets the right structure at the wrong scale, which is why
generating locally is better. Keep one config per machine — the `Machine` field
makes restore warn when you've mixed them up; machine-named files let
two live side by side.

## Use

**1. Arrange your desktops the way you want them.**

**2. Capture it:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\CLAUDE_SPACE\DEV-ENV\Generate.ps1"
```

**3. Later, put it back:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\CLAUDE_SPACE\DEV-ENV\Restore.ps1" -Apply
```

| Restore mode | What it does |
|---|---|
| *(no flags)* | Dry run. Prints a plan. Changes nothing. |
| `-Rehearse` | Walks each desktop showing what it *would* do, paced by you with **Next** / **Stop**. Changes nothing. |
| `-Apply` | Does it. |
| `-Desktop Main,Gaming` | Limit to desktops by name or index. |
| `-NoUi` | No status panel. |

`Generate.ps1 -Out <path> -Force` writes elsewhere, so you can diff before
replacing a config you trust. It won't overwrite an existing config without `-Force`.

## Rules it follows

- **Dry run unless you pass `-Apply`.**
- **Nothing is ever closed or killed.** Extra windows are reported as surplus
  and left alone.
- **Re-running is safe.** It counts what's already in place and launches only
  the shortfall, so a second `-Apply` does nothing.
- **Keep off the keyboard during `-Apply`** — see below.

## The config

**It holds no pixels.** A snapped window isn't an arbitrary rectangle, it's a
cell of a grid your screen is divided into — so that's what gets stored. Each
monitor records its grid, and a region is a span of cells:

```powershell
Monitors = @(
    @{ Key = 'M1'; Match = @{ Primary = $true; Width = 5120; Height = 1440 }; Grid = @{ Cols = 3; Rows = 1 } }
    @{ Key = 'M2'; Match = @{ Primary = $false; Width = 3440; Height = 1440 }; Grid = @{ Cols = 3; Rows = 2 } }
)

Regions = @{
    'M1.center'        = @{ Monitor = 'M1'; Col = 2; Row = 1 }
    'M2.left'          = @{ Monitor = 'M2'; Col = 1; Row = 1; RowSpan = 2 }
    'M2.center-bottom' = @{ Monitor = 'M2'; Col = 2; Row = 2 }
}
```

Restore computes the rectangle from the live **work area** — bounds minus the
taskbar — divided by the grid. So `M1.center` is correct on the 5120-wide
monitor it was captured on, on a 3840 one, and on a laptop.

A shape that repeats across desktops is named once:

```powershell
Layouts = @{
    standard = @(
        @{ App = 'cursor';  Region = 'M1.left';   Project = '{project}' }
        @{ App = 'chrome';  Region = 'M1.center' }
        @{ App = 'chrome';  Region = 'M2.left' }
    )
}
```

which makes a whole desktop four lines:

```powershell
@{
    Index = 3
    Name  = 'MVP'
    Id    = '{E3331655-3A25-4F9C-99AB-A8E87276FA76}'
    Layout = 'standard'; Project = 'CLI'
}
```

- `{project}` is the only thing a layout varies per desktop. A desktop with its
  own shape writes `Windows = @(...)` instead; it may also have both, and the
  entries are concatenated.
- `Project` supplies the Cursor folder URI *and* the title fragment that tells
  one Cursor window from another.
- Monitors match on primary-flag + resolution first, then device name, then
  **position** — so a different screen still lands somewhere sensible, and the
  grid makes the geometry right rather than approximate.
- Desktops match by GUID, so renaming them in Windows is harmless.
- A region named `M1.free`, carrying literal `X/Y/Width/Height`, is a window
  that did **not** sit on the grid. Generate lists these on the way out. Either
  snap it and re-generate, or keep it — it's recorded faithfully either way.
- Regions describe the **visible** frame; restore measures each window's
  invisible border itself.
- Timing and the ignore list live in the scripts' own defaults, not in the
  config. Add a `Timing = @{ ... }` block only to override them.
- `Import-PowerShellDataFile` parses **data only** — a config can't execute code.

### Capturing: what you see is what you get

Generate captures the screen exactly as you've arranged it. Then:

- **An app it hasn't seen before** gets a question: `[y]` add it, `[n]` never
  ask again, `[Enter]` not this time. Added apps launch from the exe they were
  running from, with no arguments; Store apps are positioned but not launched.
- **Your answers live in `capture.psd1`** (`Add`, `Ignore`, `SkipDesktops`),
  shared by every machine using the folder. Plain text; edit it any time.
- **A scratch desktop** you never want captured: `Generate.ps1 -SkipDesktop Open`
  once. It's remembered, and that desktop is written as `IntentionallyEmpty`.
- Then review `layout.<COMPUTERNAME>.psd1`, delete any window lines you don't
  want, save. Done.

Apps needing special arguments (Chrome's profile, Cursor's folder) are built
into `$AppRules` in `Generate.ps1`, below.

### Adding an app by hand

Edit `$AppRules` near the top of `Generate.ps1`. One table, and
`-IncludeProcess` defaults from it.

```powershell
'code.exe' = @{ Key='vscode'; Policy='launch'; Scope='desktop'; Args=@('--new-window') }
```

| Field | Meaning |
|---|---|
| `Policy` | `launch` = create if missing then position; `place` = position only |
| `Scope` | `desktop` = per desktop; `global` = one for the session |
| `Skip` | known, but excluded from a baseline by default |
| `NoPosition` | positioned never; it moves itself |
| `PathGlob` | launch target when the running exe path is useless (self-extracting builds) |
| `PathGlob` (list) | candidates in order; Generate writes the first that matches on this machine |
| `GpuPreference` | 0/1/2 = auto/power saving/high performance, set in Windows Graphics Settings at launch |
| `TitleInclude` | regex; only windows whose title matches count |

## Why it switches desktops

New windows are always created on the **active** desktop, and Windows has no
supported way to move another process's window between desktops. So restore
steps to a desktop, launches there, positions, and moves on. A desktop already
correct is never visited.

Stepping is `Win+Ctrl+Left/Right` — synthesised keypresses, the same bytes your
keyboard sends — with each step confirmed before the next. Hence: hands off the
keyboard during `-Apply`.

The status panel follows you across desktops. That's allowed because the panel
belongs to our own process; it's the one case where `MoveWindowToDesktop` works.

## Known limits

- **Claude Desktop can't be launched.** Store-packaged, no stable exe path, so
  it's `Policy = 'place'` — positioned if running, never started.
- **Cursor needs `window.restoreWindows` set to `"none"`** in
  `%APPDATA%\Cursor\User\settings.json`, or it reopens its own windows onto
  whichever desktop is active *and* restore launches them.
- **Cursor overrides its own position.** Electron apps reassert saved bounds
  after the window appears, so restore waits and re-checks twice. That's why
  `-Apply` takes longer than it looks like it should.
- **Browser tabs aren't restored** — by choice. Chrome windows come back blank.
- **Elevated windows can't be positioned** by a non-elevated run; they log as
  `REFUSED`.
- **Display scaling is handled by DPI awareness.** The engine makes the process
  per-monitor DPI aware before it reads any screen, so screen sizes, window
  frames and moves all use real pixels. Without it, a 4K panel at 200% reads
  as 1920x1080 while windows report real pixels, and they get dropped as
  off-screen. Proven on the 4K laptop (XPS-C) and the 100% desktop (ATLAS).
- **Apps launch through a hidden PowerShell**, not as direct children.
  Electron apps (Cursor) attach to their parent's console; launched directly
  they'd log into the restore window and die when it was closed.
- Windows PowerShell 5.1. Run non-elevated.

## Current state, honestly

Proven: detection, config generation, dry run, rehearsal walk, desktop
switching, and launch + position + re-assert on a sandbox desktop. Grid regions
are proven to the extent that a generated config dry-runs with every window
reporting `ok` — the computed rectangles match where the windows actually are.
They have **not** been tested on a second machine.

**Not yet tested: a full cold start from nothing.** Every `-Apply` so far ran
against a machine that was already mostly correct. That's the test that matters.

Nothing here is version-controlled. `git init` would be worth it.
