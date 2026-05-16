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
Copy-Item -Path "$PSScriptRoot\RestartServices.ps1" -Destination "$DST_BASE\RestartServices.ps1" -Force
Copy-Item -Path "$PSScriptRoot\StartServices.ps1"   -Destination "$DST_BASE\StartServices.ps1"   -Force
Copy-Item -Path "$PSScriptRoot\StopServices.ps1"    -Destination "$DST_BASE\StopServices.ps1"    -Force

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