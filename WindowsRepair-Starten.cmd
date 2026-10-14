@echo off
setlocal
set "SCRIPT=%~dp0WindowsRepair.ps1"
if not exist "%SCRIPT%" (
  echo Fehler: WindowsRepair.ps1 muss im gleichen Ordner liegen.
  pause
  exit /b 1
)
rem ExecutionPolicy gilt NUR fuer diesen PowerShell-Prozess, nicht global.
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 (
  echo PowerShell wurde mit einem Fehler beendet.
  pause
)
endlocal
