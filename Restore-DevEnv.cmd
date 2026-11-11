@echo off
rem DEV-ENV launcher for ATLAS -- written by Generate.ps1 2026-11-11 15:08
rem Restores your virtual desktops. Keep hands off the keyboard while it runs.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore.ps1" -Apply %*
if errorlevel 1 pause
