<#
.SYNOPSIS
    Prima installazione completa di EMailSenderRobot su un server.

.DESCRIPTION
    Sostituisce il vecchio FirstInstall.cmd (rimosso), che si limitava a creare
    le due cartelle e i permessi, lasciando all'operatore la copia dei file, la
    creazione dei file di configurazione e la registrazione del servizio.

    Sequenza eseguita:
      1. verifica prerequisiti (privilegi, runtime ASP.NET Core 8)
      2. creazione cartelle e permessi
      3. copia dei file pubblicati (mai gli appsettings*.json)
      4. creazione dei DUE appsettings.json da template, se assenti
      5. copia degli script di gestione nella cartella di installazione
      6. registrazione del servizio Windows + firewall
      7. avvio del servizio

    Va eseguito dalla cartella di publish (quella che contiene Web\ e
    ConsoleJob\). E' idempotente: rieseguendolo non si perde nulla, perche'
    i file di configurazione esistenti non vengono mai sovrascritti.

    NON serve IIS: la Web UI e' self-hosted con Kestrel e gira come servizio
    Windows. L'app pool IIS che si trova sui server EasyWebParts appartiene
    all'applicazione consumer (il portale che accoda le mail), non al robot.

    DOPO L'INSTALLAZIONE il robot non spedisce ancora nulla: serve almeno un
    tenant, che si predispone con New-EMailSenderTenant.ps1.

.PARAMETER Urls
    Binding di Kestrel scritto nell'appsettings.json della Web UI.
    Default "http://localhost:5000": la UI risponde solo dalla macchina.
    Per l'accesso da rete usare "http://*:5000" (e allora serve la regola
    firewall, che lo script crea automaticamente in quel caso).

.EXAMPLE
    .\Install-EMailSender.ps1

.EXAMPLE
    .\Install-EMailSender.ps1 -Urls "http://*:5000"

.EXAMPLE
    .\Install-EMailSender.ps1 -InstallRoot "D:\EMailSender" -NoStart
#>
[CmdletBinding()]
param(
    # Cartella di destinazione dell'installazione.
    [string] $InstallRoot = "C:\EMailSender",

    # Cartella di origine: per default quella dello script (la publish).
    [string] $SourceRoot = $PSScriptRoot,

    # Nome e descrizione del servizio Windows.
    [string] $ServiceName = "EMailSenderWeb",
    [string] $DisplayName = "EMailSender Web",

    # Binding HTTP di Kestrel (vedi note nel blocco .PARAMETER).
    [string] $Urls = "http://localhost:5000",

    # Account con cui girano servizio e job: riceve i permessi sulle cartelle.
    [string] $ServiceAccount = "NT AUTHORITY\SYSTEM",

    # Non registra/avvia il servizio (solo file e configurazione).
    [switch] $SkipService,

    # Non avvia il servizio alla fine.
    [switch] $NoStart
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# PASSO 1 - Prerequisiti
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 1. Prerequisiti ===" -ForegroundColor Yellow

# 1a. Privilegi di amministratore.
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Questo script richiede privilegi di amministratore. Aprire PowerShell con 'Esegui come amministratore'."
}
Write-Host "    Privilegi di amministratore: OK" -ForegroundColor Green

# 1b. Cartelle di origine.
$srcWeb = Join-Path $SourceRoot "Web"
$srcJob = Join-Path $SourceRoot "ConsoleJob"

if (-not (Test-Path $srcWeb)) { throw "Cartella di origine non trovata: $srcWeb. Eseguire lo script dalla cartella di publish." }
if (-not (Test-Path $srcJob)) { throw "Cartella di origine non trovata: $srcJob. Eseguire lo script dalla cartella di publish." }
Write-Host "    Cartelle di origine: OK" -ForegroundColor Green

# 1c. Runtime .NET.
# Il publish e' framework-dependent: serve il runtime ASP.NET Core 8 (che
# include anche il runtime base). Il solo "Microsoft.NETCore.App" non basta:
# la Web UI non parte e il servizio termina subito con errore 1067.
$aspNet8Found = $false
try {
    $runtimes = & dotnet --list-runtimes 2>$null
    $aspNet8Found = @($runtimes | Where-Object { $_ -match "^Microsoft\.AspNetCore\.App 8\." }).Count -gt 0
}
catch {
    throw "Comando 'dotnet' non disponibile. Installare 'ASP.NET Core 8 Runtime (Hosting Bundle o Runtime)' e riprovare."
}

if (-not $aspNet8Found) {
    throw "Runtime 'Microsoft.AspNetCore.App 8.x' non presente. Installarlo (dotnet-hosting-8.x-win.exe oppure aspnetcore-runtime-8.x-win-x64.exe) e riprovare."
}
Write-Host "    Runtime ASP.NET Core 8: OK" -ForegroundColor Green

# ---------------------------------------------------------------------------
# PASSO 2 - Cartelle e permessi
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 2. Cartelle e permessi ===" -ForegroundColor Yellow

$dstWeb = Join-Path $InstallRoot "Web"
$dstJob = Join-Path $InstallRoot "ConsoleJob"

foreach ($dir in @($InstallRoot, $dstWeb, $dstJob)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "    Creata: $dir" -ForegroundColor Green
    }
    else {
        Write-Host "    Gia' presente: $dir" -ForegroundColor Cyan
    }
}

# Permessi di modifica per l'account di servizio e per gli amministratori.
# (OI)(CI)M = oggetti e contenitori ereditano il permesso Modify.
foreach ($dir in @($dstWeb, $dstJob)) {
    & icacls "$dir" /grant "$($ServiceAccount):(OI)(CI)M" /T /Q | Out-Null
    & icacls "$dir" /grant "BUILTIN\Administrators:(OI)(CI)M" /T /Q | Out-Null
}
Write-Host "    Permessi concessi a [$ServiceAccount] e agli amministratori." -ForegroundColor Green

# ---------------------------------------------------------------------------
# PASSO 3 - Copia dei file pubblicati
# Gli appsettings*.json sono esclusi: sono l'unico stato non ricostruibile
# dell'installazione e vengono gestiti al passo 4.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 3. Copia dei file ===" -ForegroundColor Yellow

# Se il servizio esiste ed e' attivo va fermato, altrimenti i .dll sono
# bloccati e la copia falliva a meta'.
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -ne $svc -and $svc.Status -ne "Stopped") {
    Write-Host "    Il servizio e' in esecuzione: stop temporaneo..." -ForegroundColor Cyan
    Stop-Service -Name $ServiceName -Force
    Start-Sleep -Seconds 2
}

<#
.SYNOPSIS
    Copia ricorsivamente una cartella escludendo i file di configurazione.
#>
function Copy-PublishFolder {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    Get-ChildItem -Path $Source -Recurse | Where-Object {
        $_.Name -notlike "appsettings*.json"
    } | ForEach-Object {
        $dest = $_.FullName.Replace($Source, $Destination)
        if ($_.PSIsContainer) {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        }
        else {
            Copy-Item -Path $_.FullName -Destination $dest -Force
        }
    }
}

Copy-PublishFolder -Source $srcWeb -Destination $dstWeb
Write-Host "    Web -> $dstWeb" -ForegroundColor Green
Copy-PublishFolder -Source $srcJob -Destination $dstJob
Write-Host "    ConsoleJob -> $dstJob" -ForegroundColor Green

# ---------------------------------------------------------------------------
# PASSO 4 - File di configurazione
#
# Il publish NON produce un appsettings.json utilizzabile:
#   - EMailSender.Web.csproj marca appsettings.json come
#     CopyToPublishDirectory=Never e pubblica solo appsettings.Production.json,
#     che contiene ConnectionStrings vuote e Companies vuoto;
#   - EMailSender.ConsoleJob non ha alcun appsettings.json nel progetto, ma
#     Program.cs lo carica con optional:false: senza il file il job termina
#     immediatamente con un'eccezione.
# Inoltre ConfigService legge e riscrive SEMPRE il file "appsettings.json"
# (nome fisso, EMailSender.Web/Program.cs:15), quindi e' quello il file che
# deve esistere: appsettings.Production.json da solo non basta.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 4. File di configurazione ===" -ForegroundColor Yellow

$webSettings = Join-Path $dstWeb "appsettings.json"
$jobSettings = Join-Path $dstJob "appsettings.json"

# Template della Web UI. La chiave "Urls" e' l'unico modo per cambiare il
# binding di Kestrel: in sua assenza si ascolta solo su loopback.
$webTemplate = @"
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "Urls": "$Urls",
  "IsBlocked": false,
  "ConnectionStrings": {},
  "Companies": [],
  "DefaultTenants": [ "Development", "FMGroup" ]
}
"@

# Template del ConsoleJob. La sezione "EmailJob" e' letta davvero da
# Program.cs:27-30 (MaxRetryCount e DefaultCompany) ed era assente sia dalla
# guida sia dalle configurazioni esistenti.
$jobTemplate = @"
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "EmailJob": {
    "MaxRetryCount": 2,
    "DefaultCompany": ""
  },
  "ConnectionStrings": {},
  "Companies": []
}
"@

foreach ($item in @(
        @{ Path = $webSettings; Body = $webTemplate; Label = "Web" },
        @{ Path = $jobSettings; Body = $jobTemplate; Label = "ConsoleJob" })) {

    if (Test-Path $item.Path) {
        # Mai sovrascrivere una configurazione esistente.
        Write-Host "    $($item.Label): appsettings.json gia' presente, non toccato." -ForegroundColor Cyan
    }
    else {
        Set-Content -Path $item.Path -Value $item.Body -Encoding UTF8
        Write-Host "    $($item.Label): appsettings.json creato da template." -ForegroundColor Green
    }
}

# Se il publish ha portato un appsettings.Production.json lo si segnala:
# viene comunque unito alla configurazione dalla Web UI (Environment
# Production di default per un servizio Windows) e con Companies vuoto
# puo' confondere in fase di diagnosi.
$prodLeftover = Join-Path $dstWeb "appsettings.Production.json"
if (Test-Path $prodLeftover) {
    Write-Warning "Presente ${prodLeftover}: viene letto da IConfiguration in aggiunta ad appsettings.json. Se non serve, rimuoverlo per evitare ambiguita'."
}

# ---------------------------------------------------------------------------
# PASSO 5 - Script di gestione nella cartella di installazione
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 5. Script di gestione ===" -ForegroundColor Yellow

$supportScripts = @(
    "EMailSenderCommon.ps1",
    "Setup-EMailSender.ps1",
    "StartServices.ps1",
    "StopServices.ps1",
    "RestartServices.ps1",
    "ConsoleJobSetupJob.ps1",
    "New-EMailSenderTenant.ps1",
    "Register-EMailSenderService.ps1",
    "Invoke-EMailSenderLogCleanup.ps1",
    "Test-EMailSenderInstall.ps1",
    "ReadMe.md",
    "INTEGRATION.md",
    "PLACEHOLDERS.md"
)

foreach ($name in $supportScripts) {
    $src = Join-Path $SourceRoot $name
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $InstallRoot $name) -Force
        Write-Host "    Copiato: $name" -ForegroundColor Green
    }
    else {
        Write-Host "    Assente nella publish (ignorato): $name" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# PASSO 6 - Servizio Windows e firewall
# ---------------------------------------------------------------------------
if ($SkipService) {
    Write-Host ""
    Write-Host "=== 6. Servizio: saltato (-SkipService) ===" -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "=== 6. Servizio Windows ===" -ForegroundColor Yellow

    # Porta e necessita' di firewall si deducono dal binding richiesto:
    # su un binding di sola loopback la regola firewall e' inutile.
    $port = 5000
    if ($Urls -match ":(\d+)") { $port = [int] $Matches[1] }

    $isLoopbackOnly = ($Urls -match "localhost") -or ($Urls -match "127\.0\.0\.1")

    $registerScript = Join-Path $SourceRoot "Register-EMailSenderService.ps1"
    if (-not (Test-Path $registerScript)) {
        throw "Register-EMailSenderService.ps1 non trovato in $SourceRoot."
    }

    if ($isLoopbackOnly) {
        & $registerScript -ServiceName $ServiceName -DisplayName $DisplayName `
                          -InstallRoot $InstallRoot -Port $port -SkipFirewall
        Write-Host "    Binding di sola loopback ($Urls): nessuna regola firewall creata." -ForegroundColor Cyan
    }
    else {
        & $registerScript -ServiceName $ServiceName -DisplayName $DisplayName `
                          -InstallRoot $InstallRoot -Port $port
    }

    # -----------------------------------------------------------------------
    # PASSO 7 - Avvio
    # -----------------------------------------------------------------------
    if (-not $NoStart) {
        Write-Host ""
        Write-Host "=== 7. Avvio del servizio ===" -ForegroundColor Yellow
        try {
            Start-Service -Name $ServiceName
            Start-Sleep -Seconds 3
            $st = (Get-Service -Name $ServiceName).Status
            Write-Host "    Stato: $st" -ForegroundColor Cyan
        }
        catch {
            Write-Host "    ERRORE all'avvio: $_" -ForegroundColor Red
            Write-Host "    Controllare Visualizzatore eventi -> Registri di Windows -> Applicazione." -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# Riepilogo
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host " Installazione completata in $InstallRoot" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host " Il robot NON spedisce ancora: serve almeno un tenant."
Write-Host ""
Write-Host " Passi successivi:"
Write-Host "   1. Predisporre il tenant (DB, tabelle, permessi, config, task):"
Write-Host "        .\New-EMailSenderTenant.ps1 -TenantName ""FMG"" -DisplayName ""FM Group"" -CreateTask"
Write-Host "   2. Completare i parametri SMTP dalla Web UI ($Urls)"
Write-Host "   3. Verificare l'installazione:"
Write-Host "        .\Test-EMailSenderInstall.ps1"
Write-Host ""
