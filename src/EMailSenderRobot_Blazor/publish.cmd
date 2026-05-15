@echo off
setlocal

set WEB_DIR=..\..\publish\Web
set JOB_DIR=..\..\publish\ConsoleJob

echo.
echo === Creazione cartelle di output ===
if not exist "%WEB_DIR%" mkdir "%WEB_DIR%"
if not exist "%JOB_DIR%" mkdir "%JOB_DIR%"

echo === Pulizia cartelle di output ===
if exist "%WEB_DIR%" rmdir /S /Q "%WEB_DIR%"
if exist "%JOB_DIR%" rmdir /S /Q "%JOB_DIR%"

echo.
echo === Publish EMailSender.Web ===
dotnet publish EMailSender.Web\EMailSender.Web.csproj ^
    -c Release -o "%WEB_DIR%"

echo.
echo === Publish EMailSender.ConsoleJob ===
dotnet publish EMailSender.ConsoleJob\EMailSender.ConsoleJob.csproj ^
    -c Release -o "%JOB_DIR%"

echo.
echo =========================================
echo  Fatto. Ora crea uno zip con:
echo    install.cmd  (dalla root del repo)
echo    publish\Web\
echo    publish\ConsoleJob\
echo =========================================
echo.
pause
endlocal