@echo off
setlocal
if /i "%~1"=="--self-test" (
    echo Launcher self-test OK
    exit /b 0
)
fltmc >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%ComSpec%' -ArgumentList '/d /c ""%~f0""' -Verb RunAs"
    exit /b
)
pushd "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0新机自动化安装.ps1"
set "ScriptExitCode=%errorlevel%"
echo.
if not "%ScriptExitCode%"=="0" echo Script failed. Exit code: %ScriptExitCode%
pause
popd
exit /b %ScriptExitCode%
