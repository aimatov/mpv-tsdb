@echo off
setlocal
if not exist "%~dp0config\script-opts" mkdir "%~dp0config\script-opts"
if not exist "%~dp0config\script-opts\tsdb.conf" copy /Y "%~dp0tsdb.conf.example" "%~dp0config\script-opts\tsdb.conf" >nul
echo Escribe tu clave despues de api_key=, guarda y cierra el Bloc de notas.
echo Luego ejecuta PROBAR_TSDB.cmd. La clave solo se guarda en esta carpeta local.
start /wait "" notepad.exe "%~dp0config\script-opts\tsdb.conf"
