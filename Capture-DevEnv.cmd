@echo off
rem DEV-ENV capture -- written by Generate.ps1 on ATLAS, 2026-11-11 15:26
rem Captures your desktops exactly as they are now, asks about any app it
rem has not seen before, then opens the layout so you can review it.
rem The previous layout is kept in _archive\.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Generate.ps1" -Force -NoLauncher %*
if errorlevel 1 ( pause & exit /b 1 )
echo.
echo Next: review the layout. Delete any window lines you do not want, then save.
pause
start "" notepad "%~dp0layout.%COMPUTERNAME%.psd1"
