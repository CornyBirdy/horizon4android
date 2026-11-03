@echo off
rem Double-click after signing in to your Microsoft account in the Horizon launcher: writes
rem horizon-session.json on your Desktop for the phone (see make-phone-session.ps1).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-phone-session.ps1" %*
echo.
pause
