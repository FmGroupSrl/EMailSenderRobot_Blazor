# ReStartServices.ps1
# Avvia i servizi di EMailSenderRobot dopo un aggiornamento

Write-Host "=== Stop EMailSenderWeb ===" -ForegroundColor Yellow
Stop-Service -Name "EMailSenderWeb" -Force
Write-Host "    Stato: $((Get-Service -Name 'EMailSenderWeb').Status)" -ForegroundColor Cyan

Write-Host "=== Start EMailSenderWeb ===" -ForegroundColor Yellow
Start-Service -Name "EMailSenderWeb"
Write-Host "    Stato: $((Get-Service -Name 'EMailSenderWeb').Status)" -ForegroundColor Cyan