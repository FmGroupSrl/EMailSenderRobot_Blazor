@echo off
setlocal

set WEB_DIR=C:\EMailSender\Web
set JOB_DIR=C:\EMailSender\ConsoleJob

echo.
echo === Creazione cartelle ===
if not exist "%WEB_DIR%" mkdir "%WEB_DIR%"
if not exist "%JOB_DIR%" mkdir "%JOB_DIR%"

echo.
echo === Permessi cartella Web ===
icacls "%WEB_DIR%" /grant "NT AUTHORITY\SYSTEM:(OI)(CI)M" /T /Q
icacls "%WEB_DIR%" /grant "BUILTIN\Administrators:(OI)(CI)M" /T /Q

echo.
echo === Permessi cartella ConsoleJob ===
icacls "%JOB_DIR%" /grant "NT AUTHORITY\SYSTEM:(OI)(CI)M" /T /Q
icacls "%JOB_DIR%" /grant "BUILTIN\Administrators:(OI)(CI)M" /T /Q

echo.
echo === Backup appsettings.json ===
if exist "%WEB_DIR%\appsettings.json" (
    copy /Y "%WEB_DIR%\appsettings.json" "%WEB_DIR%\appsettings.json.bak"
    echo   Backup Web: appsettings.json.bak
) else (
    echo   Web: nessun appsettings.json esistente, nessun backup
)

if exist "%JOB_DIR%\appsettings.json" (
    copy /Y "%JOB_DIR%\appsettings.json" "%JOB_DIR%\appsettings.json.bak"
    echo   Backup ConsoleJob: appsettings.json.bak
) else (
    echo   ConsoleJob: nessun appsettings.json esistente, nessun backup
)

echo.
echo =========================================
echo  Cartelle create e permessi impostati.
echo  Backup appsettings.json eseguito.
echo.
echo  Copia ora i file:
echo    Web\        ->  %WEB_DIR%\
echo    ConsoleJob\ ->  %JOB_DIR%\
echo.
echo  ATTENZIONE: se hai gia' una configurazione
echo  attiva, NON sovrascrivere appsettings.json
echo  Il backup e' in appsettings.json.bak
echo =========================================
echo.
pause
endlocal