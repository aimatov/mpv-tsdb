@echo off
setlocal
set "TSDB_MPV=D:\mpv\mpv.exe"
if exist "%~dp0mpv.exe" set "TSDB_MPV=%~dp0mpv.exe"
if not exist "%TSDB_MPV%" (
 echo No se encontro mpv. Edita TSDB_MPV en este archivo con su ruta.
 pause
 exit /b 1
)
if not exist "%~dp0config\script-opts" mkdir "%~dp0config\script-opts"
"%TSDB_MPV%" --config-dir="%~dp0config" --idle=yes --force-window=yes --load-scripts=no --script="%~dp0tsdb.lua"
