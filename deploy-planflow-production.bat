@echo off
setlocal
chcp 65001 >nul

rem One-click production release entry point.
rem The PowerShell script keeps the fail-closed production checks, bumps the
rem version, builds the map-safe AAB, and uploads only after explicit confirm.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\deploy-play-production.ps1" -ConfirmProductionRollout
exit /b %ERRORLEVEL%
