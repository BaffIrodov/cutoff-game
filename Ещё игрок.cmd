@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-Local.ps1" -ClientOnly -Name "Player 2"
if errorlevel 1 pause
