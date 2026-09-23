@echo off
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"

set "COMMAND_DIR=%~dp0commands"

set /a TOTAL=0
set /a SUCCESS=0
set /a FAILED=0

for /f "delims=" %%F in ('dir /b /a-d /on "%COMMAND_DIR%\*.txt" 2^>nul') do (
    set /a TOTAL+=1
)

if !TOTAL! EQU 0 (
    exit /b 1
)

for /f "delims=" %%F in ('dir /b /a-d /on "%COMMAND_DIR%\*.txt" 2^>nul') do (

    powershell.exe -NoProfile -ExecutionPolicy Bypass ^
        -File "%~dp0network_console_auto.ps1" ^
        "%COMMAND_DIR%\%%F"

    if !ERRORLEVEL! EQU 0 (
        set /a SUCCESS+=1
    ) else (
        set /a FAILED+=1
    )
)

exit /b !FAILED!
