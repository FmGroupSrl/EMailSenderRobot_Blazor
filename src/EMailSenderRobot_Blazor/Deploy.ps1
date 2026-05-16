# Deploy.ps1
# Ferma il servizio, copia i file pubblicati nelle directory di destinazione
# escludendo appsettings.json, poi riavvia il servizio.
# Da mettere nella directory di publish insieme alle cartelle Web e ConsoleJob.

$SRC_WEB = "$PSScriptRoot\Web"
$SRC_JOB = "$PSScriptRoot\ConsoleJob"
$DST_WEB = "C:\EMailSender\Web"
$DST_JOB = "C:\EMailSender\ConsoleJob"
$SERVICE  = "EMailSenderWeb"

Write-Host ""
Write-Host "=== Stop $SERVICE ===" -ForegroundColor Yellow
Stop-Service -Name $SERVICE -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host "    Stato: $((Get-Service -Name $SERVICE).Status)" -ForegroundColor Cyan

Write-Host ""
Write-Host "=== Copia Web ===" -ForegroundColor Yellow
Get-ChildItem -Path $SRC_WEB -Recurse | Where-Object {
    $_.Name -ne "appsettings.json"
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
    $_.Name -ne "appsettings.json"
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
Write-Host "=== Start $SERVICE ===" -ForegroundColor Yellow
Start-Service -Name $SERVICE
Start-Sleep -Seconds 2
Write-Host "    Stato: $((Get-Service -Name $SERVICE).Status)" -ForegroundColor Cyan

Write-Host ""
Write-Host "=== Deploy completato ===" -ForegroundColor Green
Write-Host ""