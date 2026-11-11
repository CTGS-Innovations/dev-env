<#
    Dev environment layout -- GENERATED. Re-running the generator replaces it.

    Written : 2026-11-10 23:28:33
    Machine : XPS-C

    Read it top-down:
      Monitors    each screen, and the grid its work area divides into
      Regions     a named span of grid cells -- no pixels
      Workspaces  a Cursor folder URI, named once by project
      Apps        how to launch each thing
      Layouts     a window shape that several desktops share
      Desktops    which layout, which project, which desktop

    Regions are cell spans of the work area rather than stored rectangles,
    so this file carries no screen-size assumptions: the same region name
    resolves to the right rectangle on a different monitor, and on a laptop.

    Policy  launch = create if missing, then position
            place  = position only, never launch
#>
@{

    Version    = 4
    Machine    = 'XPS-C'
    CapturedAt = '2026-11-10T23:28:33.1232713-05:00'

    # Desktop to land on when restore finishes. 0 = stay where it ends.
    ReturnToDesktopIndex = 1

    # Matched on primary-flag and resolution, falling back to position, so
    # different hardware still lands somewhere sensible. Grid is how many
    # columns and rows the work area splits into.
    Monitors = @(
        @{ Key = 'M1'; Match = @{ Primary = $true; Width = 3840; Height = 2160 }; Grid = @{ Cols = 1; Rows = 1 }; FallbackDeviceName = '\\.\DISPLAY1' }
    )

    # Cells of the grid above, named. Restore computes the rectangle from
    # the live work area and measures each window's invisible border itself.
    Regions = @{
        'M1.full'          = @{ Monitor = 'M1'; Col = 1; Row = 1 }   # 14 window(s)
        'M1.free'          = @{ Monitor = 'M1'; X = 2933; Y = 1440; Width = 762; Height = 618 }   # 1 window(s), off-grid
    }

    # Cursor folder URIs. Referenced from a window as Project = '<name>',
    # which also supplies the title fragment used to tell windows apart.
    Workspaces = @{
        'ai_survival'            = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a227461726469732d6465762d6c616e5f3139322e3136382e312e3337227d/ai_survival'
        'CLI'                    = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a227375706572636f6465722d6c616e5f3139322e3136382e312e323435227d/home/corey/projects/CLI'
        'DEV-ENV'                = 'file:///c%3A/CODE/DEV-ENV'
        'mvp-gauntlet'           = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a226d76702d6c616e5f3139322e3136382e312e3534227d/home/corey/projects/mvp-gauntlet'
        'neeer'                  = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a227375706572636f6465722d6c616e5f3139322e3136382e312e323435227d/home/corey/production/TripleELabs/neeer'
        'POKEMON'                = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a227375706572636f6465722d6c616e5f3139322e3136382e312e323435227d/home/corey/projects/POKEMON'
        'workspace'              = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a226465762d63612d7562756e74752d35303930222c2275736572223a22726f6f74227d/workspace'
    }

    Apps = @{
        chrome = @{
            Process          = 'chrome.exe'
            Policy           = 'launch'
            Path             = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            Args             = @('--profile-directory=Default', '--new-window', 'about:blank')
        }
        cursor = @{
            Process          = 'Cursor.exe'
            Policy           = 'launch'
            Path             = 'C:\Program Files\cursor\Cursor.exe'
            Args             = @('--new-window', '--folder-uri', '{uri}')
            LaunchTimeoutSec = 45
        }
        mvpecho = @{
            Process          = 'MVP-Echo Toolbar.exe'
            Policy           = 'launch'
            PathGlob         = 'C:\Users\corey\Desktop\echo\MVP-Echo Toolbar *.exe'
            Args             = @('--force_high_performance_gpu')
            GpuPreference    = 2
            # Note: Tray-anchored; it repositions itself, so position is left unmanaged.
        }
    }

    # A shape several desktops share. {project} is filled in per desktop.
    Layouts = @{
        standard = @(   # used by 7 desktop(s)
            @{ App = 'chrome';  Region = 'M1.full' }
            @{ App = 'cursor';  Region = 'M1.full';         Project = '{project}' }
        )
    }

    Desktops = @(
        @{
            Index = 1
            Name  = 'Main'
            Id    = '{FA51BF88-DE8A-49F5-AA08-6D93F8A08C2C}'
            Layout = 'standard'; Project = 'neeer'
        }
        @{
            Index = 2
            Name  = 'Gauntlet'
            Id    = '{529C91FE-C011-42AB-AC87-31E7EAD59471}'
            Layout = 'standard'; Project = 'mvp-gauntlet'
        }
        @{
            Index = 3
            Name  = 'MVP'
            Id    = '{FFBBFCDE-8E8B-41B6-83E1-6C4B20F4088F}'
            Layout = 'standard'; Project = 'CLI'
        }
        @{
            Index = 4
            Name  = 'Quick Play'
            Id    = '{EC4C343A-863A-43F5-912B-96CE5C4156D2}'
            Layout = 'standard'; Project = 'DEV-ENV'
        }
        @{
            Index = 5
            Name  = '5090'
            Id    = '{84867E33-47FE-45AD-9FF7-3A4CA49D484A}'
            Layout = 'standard'; Project = 'workspace'
        }
        @{
            Index = 6
            Name  = 'Side Work'
            Id    = '{4642F102-667D-4285-A441-DBD6E2FAD77A}'
            Layout = 'standard'; Project = 'ai_survival'
        }
        @{
            Index = 7
            Name  = 'Gaming'
            Id    = '{9DD66BAD-E69E-4F1B-BDE5-328A93DC5C2B}'
            Layout = 'standard'; Project = 'POKEMON'
        }
        @{
            Index = 8
            Name  = 'Open'
            Id    = '{09677F9D-DF1F-423D-862B-FB06DAC71708}'
            # Empty when captured. Restore never fills it or reports drift.
            IntentionallyEmpty = $true
        }
    )

    # One instance for the whole session, not per desktop.
    Global = @(
        @{ App = 'mvpecho'; Region = 'M1.free'; AllowHidden = $true; NoPosition = $true; Match = @{ TitleContains = 'MVP-Echo Toolbar' } }
    )
}
