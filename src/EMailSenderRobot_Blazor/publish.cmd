@echo off
setlocal

set WEB_DIR=..\..\publish\Web
set JOB_DIR=..\..\publish\ConsoleJob

:: ---------------------------------------------------------------------------
:: Versione automatica da data/ora: 1.0.YYYYMMDD.HHmm
:: ---------------------------------------------------------------------------
for /f "tokens=1-3 delims=/" %%a in ("%date%") do (
    set _day=%%a
    set _month=%%b
    set _year=%%c
)
for /f "tokens=1-2 delims=:" %%a in ("%time: =0%") do (
    set _hour=%%a
    set _min=%%b
)
set VERSION=1.0.%_year:~2,2%%_month%.%_day%%_hour%
echo.
echo === Versione: %VERSION% ===

:: ---------------------------------------------------------------------------
:: Commit Git automatico
:: ---------------------------------------------------------------------------
echo.
echo === Git: commit e tag ===
cd ..\..
git add -A
git commit -m "publish %VERSION%"
git tag %VERSION%
git push
git push origin %VERSION%
cd src\EMailSenderRobot_Blazor

:: ---------------------------------------------------------------------------
:: Pulizia e creazione cartelle di output
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
:: Publish con iniezione versione
:: ---------------------------------------------------------------------------
echo.
echo === Publish EMailSender.Web ===
dotnet publish EMailSender.Web\EMailSender.Web.csproj ^
    -c Release -o "%WEB_DIR%" ^
    /p:Version=%VERSION%

echo.
echo === Publish EMailSender.ConsoleJob ===
dotnet publish EMailSender.ConsoleJob\EMailSender.ConsoleJob.csproj ^
    -c Release -o "%JOB_DIR%" ^
    /p:Version=%VERSION%

echo.
echo === Copia Deploy.ps1 in publish ===
copy /Y "%~dp0Deploy.ps1" "%~dp0..\..\publish\Deploy.ps1"

echo === Copia FirstInstall.ps1 in publish ===
copy /Y "%~dp0FirstInstall.cmd" "%~dp0..\..\publish\FirstInstall.cmd"

echo === Copia RestartServices.ps1 in publish ===
copy /Y "%~dp0RestartServices.ps1" "%~dp0..\..\publish\RestartServices.ps1"

echo === Copia StartServices.ps1 in publish ===
copy /Y "%~dp0StartServices.ps1" "%~dp0..\..\publish\StartServices.ps1"

echo === Copia StopServices.ps1 in publish ===
copy /Y "%~dp0StopServices.ps1" "%~dp0..\..\publish\StopServices.ps1"

echo === Copia ReadMe.md in publish ===
copy /Y "%~dp0ReadMe.md" "%~dp0..\..\publish\ReadMe.md"


echo.
echo =========================================
echo  Versione pubblicata: %VERSION%
echo  Tag Git:             %VERSION%
echo.
echo  Ora crea uno zip con:
echo    install.cmd  (dalla root del repo)
echo    publish\Web\
echo    publish\ConsoleJob\
echo =========================================
echo.
pause
endlocal