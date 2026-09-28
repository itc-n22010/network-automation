@echo off
setlocal EnableExtensions

cd /d "%~dp0"

echo ==========================================
echo CiscoAutoConfig
echo ==========================================
echo.
echo Detecting the connected Cisco console and applying its matched configuration.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-CiscoAutoConfig.ps1" -Selection All
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo Operation failed. Check the logs and results folders.
) else (
    echo Operation completed. Check the logs and results folders.
)
echo.
pause
endlocal & exit /b %EXIT_CODE%
