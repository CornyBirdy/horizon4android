@echo off
rem Double-click after pressing Prepare in the Horizon launcher: packs the prepared files into
rem horizon-resources.zip on your Desktop for the phone (see make-phone-resources.ps1).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-phone-resources.ps1" %*
echo.
pause
