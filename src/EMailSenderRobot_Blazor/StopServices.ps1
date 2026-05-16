# StopServices.ps1
# Ferma i servizi di EMailSenderRobot prima di un aggiornamento

Write-Host "=== Stop EMailSenderWeb ===" -ForegroundColor Yellow
Stop-Service -Name "EMailSenderWeb" -Force
Write-Host "    Stato: $((Get-Service -Name 'EMailSenderWeb').Status)" -ForegroundColor Cyan