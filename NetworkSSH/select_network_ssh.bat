@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0select_network_ssh.ps1"
if errorlevel 1 pause
endlocal
