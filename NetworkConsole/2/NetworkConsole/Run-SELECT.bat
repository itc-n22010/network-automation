@echo off
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"

set "COMMAND_DIR=%~dp0commands"

:MENU

cls

echo ========================================
echo  Network Console
echo  SELECT COMMAND
echo ========================================
echo.
echo Command files:
echo ----------------------------------------

set /a COUNT=0

for /f "delims=" %%F in ('dir /b /a-d /on "%COMMAND_DIR%\*.txt" 2^>nul') do (
    set /a COUNT+=1
    set "FILE_!COUNT!=%%F"
    echo   !COUNT!. %%F
)

echo ----------------------------------------
echo.

if !COUNT! EQU 0 (
    exit /b 1
)

echo 0. Exit
echo.

set /p "SELECT=Select number: "

if "!SELECT!"=="0" (
    exit /b 0
)

set "SELECTED=!FILE_%SELECT%!"

if "!SELECTED!"=="" (
    goto MENU
)

cls

echo ========================================
echo  Network Console
echo  SELECTED COMMAND
echo ========================================
echo.
echo Selected:
echo   !SELECTED!
echo.
echo ========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%~dp0network_console_auto.ps1" ^
    "%COMMAND_DIR%\!SELECTED!"

exit /b !ERRORLEVEL!
