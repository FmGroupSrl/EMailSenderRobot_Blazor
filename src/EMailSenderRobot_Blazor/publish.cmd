@echo off
setlocal enabledelayedexpansion

:: ===========================================================================
::  publish.cmd - compila, pubblica e tagga una versione di EMailSenderRobot
::
::  ESEGUIBILE DA QUALSIASI DIRECTORY: il primo comando e' un pushd su %~dp0
::  (la cartella di questo file). In precedenza lo script usava percorsi
::  relativi alla directory corrente e, se lanciato da un'altra cartella,
::  falliva in modo silenzioso: le operazioni git venivano eseguite fuori dal
::  repository e le cartelle di output finivano in C:\publish.
::
::  ORDINE DELLE OPERAZIONI (cambiato il 2026-09-03):
::    1. controlli preliminari (repo pulito)
::    2. build e publish
::    3. copia degli script
::    4. SOLO SE TUTTO E' RIUSCITO: tag git e push
::  Prima il commit e il tag avvenivano PRIMA della build: una build fallita
::  lasciava un tag gia' spinto su codice che non compilava.
::
::  QUESTO SCRIPT NON COMMITTA PIU'. Il commit e' un atto deliberato e va
::  fatto con "git add <file>" espliciti (regola di TRACKPRJ-8: mai
::  "git add -A", che trascinerebbe handoff e file non tracciati). Se ci sono
::  modifiche pendenti lo script si ferma e lo dice.
:: ===========================================================================

pushd "%~dp0"

:: Radice del repository, ricavata dalla posizione di questo file.
set "REPO_ROOT=%~dp0..\.."
set "WEB_DIR=%REPO_ROOT%\publish\Web"
set "JOB_DIR=%REPO_ROOT%\publish\ConsoleJob"
set "PUB_DIR=%REPO_ROOT%\publish"

:: ---------------------------------------------------------------------------
:: Versione: 1.YY.MMDD.HHmm
:: Calcolata con PowerShell e non parsando %date%, che cambia formato con le
:: impostazioni internazionali della macchina e produrrebbe tag sbagliati.
:: ---------------------------------------------------------------------------
for /f %%v in ('powershell -NoProfile -Command "(Get-Date).ToString('1.yy.MMdd.HHmm')"') do set "VERSION=%%v"

echo.
echo === Versione: %VERSION% ===

:: ---------------------------------------------------------------------------
:: CONTROLLO 1 - siamo dentro un repository git?
:: ---------------------------------------------------------------------------
git -C "%REPO_ROOT%" rev-parse --git-dir >nul 2>&1
if errorlevel 1 (
    echo.
    echo [ERRORE] "%REPO_ROOT%" non e' un repository git.
    goto :FINE_ERRORE
)

:: ---------------------------------------------------------------------------
:: CONTROLLO 2 - working tree pulita.
:: Si pubblica solo codice gia' committato: altrimenti il tag punterebbe a uno
:: stato diverso da quello effettivamente compilato.
:: ---------------------------------------------------------------------------
set "DIRTY="
for /f "delims=" %%s in ('git -C "%REPO_ROOT%" status --porcelain') do set "DIRTY=1"

if defined DIRTY (
    echo.
    echo [ERRORE] Ci sono modifiche non committate:
    echo.
    git -C "%REPO_ROOT%" status --short
    echo.
    echo Committare prima di pubblicare, mettendo in stage i singoli file:
    echo     git add ^<file^>
    echo     git commit -m "..."
    goto :FINE_ERRORE
)

:: ---------------------------------------------------------------------------
:: Pulizia e creazione delle cartelle di output
:: ---------------------------------------------------------------------------
echo.
echo === Pulizia cartelle di output ===
if exist "%WEB_DIR%" rmdir /S /Q "%WEB_DIR%"
if exist "%JOB_DIR%" rmdir /S /Q "%JOB_DIR%"

echo.
echo === Creazione cartelle di output ===
if not exist "%WEB_DIR%" mkdir "%WEB_DIR%"
if not exist "%JOB_DIR%" mkdir "%JOB_DIR%"

:: ---------------------------------------------------------------------------
:: Publish con iniezione della versione.
:: L'esito viene controllato: senza questo, una build fallita proseguiva fino
:: al tag lasciando in publish i binari della versione precedente.
:: ---------------------------------------------------------------------------
echo.
echo === Publish EMailSender.Web ===
dotnet publish "%~dp0EMailSender.Web\EMailSender.Web.csproj" ^
    -c Release -o "%WEB_DIR%" ^
    /p:Version=%VERSION%
if errorlevel 1 (
    echo.
    echo [ERRORE] Publish di EMailSender.Web fallito: nessun tag creato.
    goto :FINE_ERRORE
)

echo.
echo === Publish EMailSender.ConsoleJob ===
dotnet publish "%~dp0EMailSender.ConsoleJob\EMailSender.ConsoleJob.csproj" ^
    -c Release -o "%JOB_DIR%" ^
    /p:Version=%VERSION%
if errorlevel 1 (
    echo.
    echo [ERRORE] Publish di EMailSender.ConsoleJob fallito: nessun tag creato.
    goto :FINE_ERRORE
)

:: ---------------------------------------------------------------------------
:: Copia degli script di installazione e della documentazione.
:: Devono stare accanto a Web\ e ConsoleJob\: Install-EMailSender.ps1 li cerca
:: nella propria cartella.
:: ---------------------------------------------------------------------------
echo.
echo === Copia script e documentazione in publish ===

for %%F in (
    Deploy.ps1
    EMailSenderCommon.ps1
    Setup-EMailSender.ps1
    Invoke-EMailSenderLogCleanup.ps1
    Install-EMailSender.ps1
    Register-EMailSenderService.ps1
    New-EMailSenderTenant.ps1
    ConsoleJobSetupJob.ps1
    Test-EMailSenderInstall.ps1
    RestartServices.ps1
    StartServices.ps1
    StopServices.ps1
    ReadMe.md
    INTEGRATION.md
    PLACEHOLDERS.md
) do (
    copy /Y "%~dp0%%F" "%PUB_DIR%\%%F" >nul
    if errorlevel 1 (
        echo   [ATTENZIONE] copia fallita: %%F
    ) else (
        echo   %%F
    )
)

:: ---------------------------------------------------------------------------
:: Tag e push - solo ora che build e copie sono riuscite.
:: ---------------------------------------------------------------------------
echo.
echo === Git: tag e push ===

git -C "%REPO_ROOT%" tag %VERSION%
if errorlevel 1 (
    echo   [ATTENZIONE] tag %VERSION% non creato (esiste gia'?)
) else (
    echo   Tag %VERSION% creato.
)

git -C "%REPO_ROOT%" push
if errorlevel 1 echo   [ATTENZIONE] push dei commit fallito.

git -C "%REPO_ROOT%" push origin %VERSION%
if errorlevel 1 echo   [ATTENZIONE] push del tag fallito.

:: ---------------------------------------------------------------------------
:: Riepilogo
:: ---------------------------------------------------------------------------
echo.
echo =========================================
echo  Versione pubblicata: %VERSION%
echo  Tag Git:             %VERSION%
echo  Output:              %PUB_DIR%
echo.
echo  Per il deploy: zippare l'INTERA cartella publish\
echo  (contiene Web\, ConsoleJob\, gli script .ps1 e la documentazione)
echo.
echo  Sul server:
echo    prima installazione  -^> Install-EMailSender.ps1
echo    aggiornamento        -^> Deploy.ps1
echo =========================================
echo.
popd
endlocal
pause
exit /b 0

:FINE_ERRORE
echo.
echo === Pubblicazione INTERROTTA: nulla e' stato taggato ne' spinto ===
echo.
popd
endlocal
pause
exit /b 1
