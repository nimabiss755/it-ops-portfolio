@echo off
setlocal
title Remove admin membership and disable local account olduser

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove-LocalAdministrators.ps1" -Confirm:$false
if not "%errorlevel%"=="0" (
    echo.
    echo The operation failed. Review the error above.
    pause
)

endlocal
