@echo off
REM Media Copy Script Launcher (Windows Batch Version)
REM This provides a simple double-click interface

title Media Copy Script Launcher

echo.
echo ========================================
echo    MEDIA COPY SCRIPT LAUNCHER
echo              v2.0
echo ========================================
echo.

REM Check if PowerShell 7+ is installed
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo Using PowerShell 7+...
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MediaCopy.ps1"
) else (
    echo PowerShell 7+ not found. Trying Windows PowerShell...
    echo NOTE: This script requires PowerShell 7+
    echo Download from: https://github.com/PowerShell/PowerShell/releases
    echo.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MediaCopy.ps1"
)

echo.
pause
