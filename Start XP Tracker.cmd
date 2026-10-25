@echo off
rem Opening this straight from inside the zip only extracts this one file, so check the rest are here.
for %%F in (XpTracker.ps1 TrackerCore.ps1 GameReader.ps1 PopupReader.ps1) do (
  if not exist "%~dp0%%F" (
    echo.
    echo  Wardogs XP Tracker can't start: %%F is missing from this folder.
    echo.
    echo  Extract the whole zip first: right-click it, choose "Extract All...",
    echo  then open the extracted folder and run Start XP Tracker.cmd from there.
    echo.
    pause
    exit /b 1
  )
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0XpTracker.ps1"
