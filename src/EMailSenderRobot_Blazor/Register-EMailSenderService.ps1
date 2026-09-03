<#
.SYNOPSIS
    Registra, aggiorna o rimuove il servizio Windows che ospita EMailSender.Web.

.DESCRIPTION
    La Web UI di EMailSender e' un'applicazione Blazor Server self-hosted
    (Kestrel) eseguibile come servizio Windows grazie a UseWindowsService()
    in EMailSender.Web/Program.cs. NON richiede IIS.

    Questo script sostituisce le chiamate a sc.exe che la guida riportava a
    mano, aggiungendo: controllo dei privilegi, idempotenza (se il servizio
    esiste viene riconfigurato, non duplicato), recovery automatico dopo un
    crash e regola firewall opzionale.

    ACCOUNT: il servizio gira come LocalSystem (NT AUTHORITY\SYSTEM), lo
    stesso account del ConsoleJob lanciato dal Task Scheduler. I permessi SQL
    vanno quindi concessi una volta sola a [NT AUTHORITY\SYSTEM].

    BINDING DI RETE: la porta NON si configura qui. Kestrel legge la chiave
    "Urls" dell'appsettings.json (es. "http://*:5000"); in assenza di quella
    chiave ascolta solo su loopback (127.0.0.1 e ::1) e nessuna regola
    firewall lo rendera' raggiungibile da rete. Install-EMailSender.ps1
    scrive la chiave nel template di configurazione.

.EXAMPLE
    .\Register-EMailSenderService.ps1

.EXAMPLE
    .\Register-EMailSenderService.ps1 -Port 5100

.EXAMPLE
    .\Register-EMailSenderService.ps1 -Remove
#>
[CmdletBinding()]
param(
    # Nome interno del servizio Windows.
    [string] $ServiceName = "EMailSenderWeb",

    # Nome visualizzato nella console Servizi.
    [string] $DisplayName = "EMailSender Web",

    # Cartella di installazione: da qui si deriva il percorso dell'eseguibile.
    [string] $InstallRoot = "C:\EMailSender",

    # Porta usata SOLO per la regola firewall (il binding sta in appsettings).
    [int] $Port = 5000,

    # Non crea la regola firewall in ingresso.
    [switch] $SkipFirewall,

    # Ferma e rimuove servizio e regola firewall.
    [switch] $Remove
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Verifica dei privilegi di amministratore.
# sc.exe e i cmdlet NetFirewall richiedono un token elevato: senza questo
# controllo lo script fallirebbe a meta', lasciando l'installazione
# in stato incoerente.
# ---------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Questo script richiede privilegi di amministratore. Aprire PowerShell con 'Esegui come amministratore'."
}

$binPath      = Join-Path $InstallRoot "Web\EMailSender.Web.exe"
$firewallRule = "EMailSender Web ($Port)"

# ---------------------------------------------------------------------------
# RAMO 1 - Rimozione
# ---------------------------------------------------------------------------
if ($Remove) {

    Write-Host ""
    Write-Host "=== Rimozione servizio $ServiceName ===" -ForegroundColor Yellow

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Host "    Il servizio non esiste: niente da rimuovere." -ForegroundColor Cyan
    }
    else {
        # Fermarlo prima di cancellarlo evita che resti in stato
        # "marked for deletion" fino al riavvio della macchina.
        if ($svc.Status -ne "Stopped") {
            Write-Host "    Stop in corso..." -ForegroundColor Cyan
            Stop-Service -Name $ServiceName -Force
            Start-Sleep -Seconds 2
        }
        & sc.exe delete $ServiceName | Out-Null
        Write-Host "    Servizio rimosso." -ForegroundColor Green
    }

    $rule = Get-NetFirewallRule -DisplayName $firewallRule -ErrorAction SilentlyContinue
    if ($null -ne $rule) {
        Remove-NetFirewallRule -DisplayName $firewallRule
        Write-Host "    Regola firewall rimossa." -ForegroundColor Green
    }

    Write-Host ""
    return
}

# ---------------------------------------------------------------------------
# RAMO 2 - Creazione / aggiornamento
# ---------------------------------------------------------------------------

# Registrare un servizio con binPath inesistente produce all'avvio un
# errore 2 molto piu' difficile da diagnosticare: meglio fermarsi subito.
if (-not (Test-Path $binPath)) {
    throw "Eseguibile non trovato: $binPath. Eseguire prima Install-EMailSender.ps1 (o copiare i file pubblicati)."
}

Write-Host ""
Write-Host "=== Servizio Windows $ServiceName ===" -ForegroundColor Yellow

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($null -eq $existing) {
    # Creazione. Attenzione alla sintassi di sc.exe: lo spazio DOPO il segno
    # "=" e' obbligatorio ed e' parte della sintassi, non un errore.
    Write-Host "    Creazione del servizio..." -ForegroundColor Cyan
    & sc.exe create $ServiceName binPath= "`"$binPath`"" start= auto obj= "LocalSystem" DisplayName= "$DisplayName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe create ha restituito exit code $LASTEXITCODE" }
}
else {
    # Aggiornamento: utile quando cambia la cartella di installazione.
    Write-Host "    Il servizio esiste: aggiornamento della configurazione..." -ForegroundColor Cyan
    if ($existing.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force
        Start-Sleep -Seconds 2
    }
    & sc.exe config $ServiceName binPath= "`"$binPath`"" start= auto obj= "LocalSystem" DisplayName= "$DisplayName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config ha restituito exit code $LASTEXITCODE" }
}

# Descrizione visibile nella console Servizi.
& sc.exe description $ServiceName "Interfaccia web di configurazione e monitoraggio di EMailSenderRobot." | Out-Null

# ---------------------------------------------------------------------------
# Recovery automatico: dopo una terminazione anomala il servizio viene
# riavviato (60s, 60s, poi 120s) e il contatore dei fallimenti si azzera
# dopo 24 ore. Senza questa impostazione un crash lascia la Web UI giu'
# fino all'intervento manuale.
# ---------------------------------------------------------------------------
& sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/120000 | Out-Null

Write-Host "    Configurato: avvio automatico, account LocalSystem, recovery attivo." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Regola firewall in ingresso.
# Serve solo per l'accesso da altre macchine ed e' inutile se in
# appsettings.json manca la chiave "Urls" con un binding non-loopback.
# ---------------------------------------------------------------------------
if (-not $SkipFirewall) {
    Write-Host ""
    Write-Host "=== Firewall (porta $Port/TCP) ===" -ForegroundColor Yellow

    $rule = Get-NetFirewallRule -DisplayName $firewallRule -ErrorAction SilentlyContinue
    if ($null -eq $rule) {
        New-NetFirewallRule -DisplayName $firewallRule `
                            -Direction Inbound -Action Allow `
                            -Protocol TCP -LocalPort $Port `
                            -Profile Any | Out-Null
        Write-Host "    Regola creata." -ForegroundColor Green
    }
    else {
        Write-Host "    Regola gia' presente." -ForegroundColor Cyan
    }

    # Promemoria: verifica che il binding sia effettivamente aperto.
    $webSettings = Join-Path $InstallRoot "Web\appsettings.json"
    if (Test-Path $webSettings) {
        $cfg = Get-Content $webSettings -Raw | ConvertFrom-Json
        if (-not $cfg.Urls) {
            Write-Warning "In $webSettings manca la chiave 'Urls': Kestrel ascoltera' solo su loopback e la regola firewall non bastera'. Aggiungere ad esempio  `"Urls`": `"http://*:$Port`"  e riavviare il servizio."
        }
    }
}

Write-Host ""
Write-Host "Servizio pronto. Avvio con: Start-Service -Name $ServiceName" -ForegroundColor Green
Write-Host ""
