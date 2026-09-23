@echo off
rem Spousti MediaTool GUI - staci dvojklik na tento soubor.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0media-tool-gui.ps1"
