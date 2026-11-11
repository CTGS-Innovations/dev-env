@echo off
rem DEV-ENV restore -- written by Generate.ps1 on ATLAS, 2026-11-11 15:26
rem Puts your virtual desktops back. Hands off the keyboard while it runs.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore.ps1" -ManifestPath "%~dp0layout.%COMPUTERNAME%.psd1" -Apply %*
if errorlevel 1 pause
