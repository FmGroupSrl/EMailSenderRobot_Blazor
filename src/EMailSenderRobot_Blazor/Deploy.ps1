# Deploy.ps1
# Ferma il servizio, copia i file pubblicati nelle directory di destinazione
# escludendo appsettings.json, poi riavvia il servizio.
# Da mettere nella directory di publish insieme alle cartelle Web e ConsoleJob.

$SRC_WEB = "$PSScriptRoot\Web"
$SRC_JOB = "$PSScriptRoot\ConsoleJob"
$DST_WEB = "C:\EMailSender\Web"
$DST_JOB = "C:\EMailSender\ConsoleJob"
$DST_BASE = "C:\EMailSender"
$SERVICE  = "EMailSenderWeb"

Write-Host ""
Write-Host "=== Stop $SERVICE ===" -ForegroundColor Yellow

# Se il servizio non esiste ancora (macchina nuova) si esce subito: Deploy.ps1
# aggiorna un'installazione esistente, la prima installazione la fa
# Install-EMailSender.ps1. Senza questo controllo lo script proseguiva e
# falliva piu' avanti con un errore poco chiaro su Get-Service.
$svc = Get-Service -Name $SERVICE -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    Write-Host "    Servizio '$SERVICE' non registrato su questa macchina." -ForegroundColor Red
    Write-Host "    Per la PRIMA installazione usare: .\Install-EMailSender.ps1" -ForegroundColor Yellow
    Write-Host ""
    return
}

Stop-Service -Name $SERVICE -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host "    Stato: $((Get-Service -Name $SERVICE).Status)" -ForegroundColor Cyan

Write-Host ""
Write-Host "=== Copia Web ===" -ForegroundColor Yellow
Get-ChildItem -Path $SRC_WEB -Recurse | Where-Object {
    $_.Name -notlike "appsettings*.json"
} | ForEach-Object {
    $dest = $_.FullName.Replace($SRC_WEB, $DST_WEB)
    if ($_.PSIsContainer) {
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
    } else {
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
}
Write-Host "    Fatto." -ForegroundColor Cyan

Write-Host ""
Write-Host "=== Copia ConsoleJob ===" -ForegroundColor Yellow
Get-ChildItem -Path $SRC_JOB -Recurse | Where-Object {
    $_.Name -notlike "appsettings*.json"
} | ForEach-Object {
    $dest = $_.FullName.Replace($SRC_JOB, $DST_JOB)
    if ($_.PSIsContainer) {
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
    } else {
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
}
Write-Host "    Fatto." -ForegroundColor Cyan

Write-Host ""
Write-Host "=== Copia script PowerShell in C:\EMailSender ===" -ForegroundColor Yellow

# Tutti gli script di gestione vengono riallineati ad ogni deploy, cosi' la
# cartella di installazione contiene sempre la versione corrente. I file
# assenti nella publish vengono semplicemente saltati.
$SCRIPTS = @(
    "EMailSenderCommon.ps1",
    "Setup-EMailSender.ps1",
    "RestartServices.ps1",
    "StartServices.ps1",
    "StopServices.ps1",
    "ConsoleJobSetupJob.ps1",
    "New-EMailSenderTenant.ps1",
    "Migrate-EMailSenderData.ps1",
    "Register-EMailSenderService.ps1",
    "Install-EMailSender.ps1",
    "Test-EMailSenderInstall.ps1"
)

foreach ($s in $SCRIPTS) {
    $src = Join-Path $PSScriptRoot $s
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $DST_BASE $s) -Force
        Write-Host "    $s" -ForegroundColor Cyan
    }
}

Write-Host "    Fatto." -ForegroundColor Cyan

Write-Host "=== Copia script ReadMe.md in C:\EMailSender ===" -ForegroundColor Yellow
Copy-Item -Path "$PSScriptRoot\ReadMe.md"    -Destination "$DST_BASE\ReadMe.md"    -Force

Write-Host "    Fatto." -ForegroundColor Cyan

Write-Host ""
Write-Host "=== Start $SERVICE ===" -ForegroundColor Yellow
Start-Sleep -Seconds 3
try {
    Start-Service -Name $SERVICE
    Start-Sleep -Seconds 3
    Write-Host "    Stato: $((Get-Service -Name $SERVICE).Status)" -ForegroundColor Cyan
}
catch {
    Write-Host "    ERRORE avvio servizio: $_" -ForegroundColor Red
    Write-Host "    Verificare i log di Windows Event Viewer." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Deploy completato ===" -ForegroundColor Green
Write-Host ""