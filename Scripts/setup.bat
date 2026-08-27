@echo off
setlocal

echo Running config-driven multi-folder PVdata sync test...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Upload-PVData.ps1"
echo.
echo If the script completed successfully, review your log file path in folder-mappings.json.
pause
