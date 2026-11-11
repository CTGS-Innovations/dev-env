# What Generate.ps1 captures beyond its built-in apps. Shared by every
# machine using this folder. Edit freely; Generate also updates it when
# you answer its questions.
@{
    # Apps you said yes to: captured and launched like the built-in ones.
    Add          = @('Tabby.exe')

    # Apps you said no to: never captured, never asked about again.
    Ignore       = @('Acrobat.exe')

    # Desktops (by name) never captured. Restore leaves them alone.
    SkipDesktops = @('Open')
}
