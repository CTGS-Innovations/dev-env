<#
    Dev environment layout -- GENERATED. Re-running the generator replaces it.

    Written : 2026-11-11 15:12:39
    Machine : ATLAS

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
    Machine    = 'ATLAS'
    CapturedAt = '2026-11-11T15:12:39.2530767-05:00'

    # Desktop to land on when restore finishes. 0 = stay where it ends.
    ReturnToDesktopIndex = 1

    # Matched on primary-flag and resolution, falling back to position, so
    # different hardware still lands somewhere sensible. Grid is how many
    # columns and rows the work area splits into.
    Monitors = @(
        @{ Key = 'M1'; Match = @{ Primary = $true; Width = 5120; Height = 1440 }; Grid = @{ Cols = 3; Rows = 1 }; FallbackDeviceName = '\\.\DISPLAY1' }
        @{ Key = 'M2'; Match = @{ Primary = $false; Width = 3440; Height = 1440 }; Grid = @{ Cols = 3; Rows = 1 }; FallbackDeviceName = '\\.\DISPLAY2' }
    )

    # Cells of the grid above, named. Restore computes the rectangle from
    # the live work area and measures each window's invisible border itself.
    Regions = @{
        'M1.left'          = @{ Monitor = 'M1'; Col = 1; Row = 1 }   # 7 window(s)
        'M1.center'        = @{ Monitor = 'M1'; Col = 2; Row = 1 }   # 7 window(s)
        'M1.free'          = @{ Monitor = 'M1'; X = 2369; Y = 546; Width = 382; Height = 301 }   # 1 window(s), off-grid
        'M2.left'          = @{ Monitor = 'M2'; Col = 1; Row = 1 }   # 7 window(s)
        'M2.center'        = @{ Monitor = 'M2'; Col = 2; Row = 1 }   # 1 window(s)
    }

    # Cursor folder URIs. Referenced from a window as Project = '<name>',
    # which also supplies the title fragment used to tell windows apart.
    Workspaces = @{
        'ai_survival'            = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a226465762d7461726469732d6c616e227d/ai_survival'
        'CLI'                    = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a225355504552434f444552227d/home/corey/projects/CLI'
        'MASTER_RESUME_BUILDER'  = 'file:///c%3A/CODE_LIBRARY/Code/MASTER_RESUME_BUILDER'
        'mvp-gauntlet'           = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a224d56502d434f44452d534552564552227d/home/corey/projects/mvp-gauntlet'
        'neeer'                  = 'vscode-remote://ssh-remote%2B192.168.1.245/home/corey/production/TripleELabs/neeer'
        'POKEMON'                = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a225355504552434f444552227d/home/corey/projects/POKEMON'
        'workspace'              = 'vscode-remote://ssh-remote%2B7b22686f73744e616d65223a223130302e3130342e34312e3435222c2275736572223a22726f6f74227d/workspace'
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
            PathGlob         = 'C:\Users\corey\Desktop\MVP-Echo.Toolbar.*.exe'
            Args             = @('--force_high_performance_gpu')
            GpuPreference    = 2
            # Note: Tray-anchored; it repositions itself, so position is left unmanaged.
        }
        tabby = @{
            Process          = 'Tabby.exe'
            Policy           = 'launch'
            Path             = 'C:\Program Files\Tabby\Tabby.exe'
            Args             = @()
        }
    }

    # A shape several desktops share. {project} is filled in per desktop.
    Layouts = @{
        standard = @(   # used by 6 desktop(s)
            @{ App = 'cursor';  Region = 'M1.left';         Project = '{project}' }
            @{ App = 'chrome';  Region = 'M1.center' }
            @{ App = 'chrome';  Region = 'M2.left' }
        )
    }

    Desktops = @(
        @{
            Index = 1
            Name  = 'Main'
            Id    = '{028EC8F2-CA5A-4F81-A3C8-F174298554C0}'
            Layout = 'standard'; Project = 'neeer'
        }
        @{
            Index = 2
            Name  = 'Gauntlet'
            Id    = '{820E7A20-3668-4572-9626-5821228AC7E7}'
            Layout = 'standard'; Project = 'mvp-gauntlet'
        }
        @{
            Index = 3
            Name  = 'MVP'
            Id    = '{E3331655-3A25-4F9C-99AB-A8E87276FA76}'
            Layout = 'standard'; Project = 'CLI'
        }
        @{
            Index = 4
            Name  = 'Quick Play'
            Id    = '{8CA58D67-93CB-4124-BFA7-53233A809193}'
            Layout = 'standard'; Project = 'ai_survival'
        }
        @{
            Index = 5
            Name  = '5090'
            Id    = '{2965CCF2-7A97-457F-B77D-D75A7A3048D6}'
            Windows = @(
                @{ App = 'cursor';  Region = 'M1.left';         Project = 'workspace' }
                @{ App = 'chrome';  Region = 'M1.center' }
                @{ App = 'chrome';  Region = 'M2.left' }
                @{ App = 'tabby';   Region = 'M2.center' }
            )
        }
        @{
            Index = 6
            Name  = 'Side Work'
            Id    = '{3D7FB046-937A-4FEB-BD8D-2EFEE1E82734}'
            Layout = 'standard'; Project = 'MASTER_RESUME_BUILDER'
        }
        @{
            Index = 7
            Name  = 'Gaming'
            Id    = '{CD1B367D-B09A-4D5A-BA1C-4977FBD39389}'
            Layout = 'standard'; Project = 'POKEMON'
        }
        @{
            Index = 8
            Name  = 'Open'
            Id    = '{D35E5075-7AC3-4A0F-BF82-59692B3D6DCF}'
            # Not captured (SkipDesktops in capture.psd1). Restore leaves it alone.
            IntentionallyEmpty = $true
        }
    )

    # One instance for the whole session, not per desktop.
    Global = @(
        @{ App = 'mvpecho'; Region = 'M1.free'; AllowHidden = $true; NoPosition = $true; Match = @{ TitleContains = 'MVP-Echo Toolbar' } }
    )
}
