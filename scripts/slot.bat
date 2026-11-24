@echo off
chcp 936 >nul
setlocal
cd /d "%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Slot-BrowseKit.ps1" %*
exit /b %errorlevel%
