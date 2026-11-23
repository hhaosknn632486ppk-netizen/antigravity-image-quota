: << 'CMDBLOCK'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hook.ps1" %*
exit /b %errorlevel%
CMDBLOCK
exec python3 "$(dirname "$0")/hook.py" "$@"
