<#
.SYNOPSIS
    Installazione completa di EMailSenderRobot in un solo comando: chiede tutto
    all'inizio, riepiloga, chiede una conferma sola e poi esegue.

.DESCRIPTION
    E' l'unico script da lanciare su una macchina nuova. Orchestra, nell'ordine:

        1. Install-EMailSender.ps1        file, permessi, servizio, firewall
        2. New-EMailSenderTenant.ps1      database, tabelle, permessi, config
        3. ConsoleJobSetupJob.ps1         task di spedizione (ogni minuto)
        4. Test-EMailSenderInstall.ps1    verifica finale

    La pulizia dei log non ha un task proprio: la fa il ConsoleJob una volta al
    giorno, su file e database insieme, con la soglia del tenant.

    Le domande stanno TUTTE all'inizio: una volta risposto si puo' andare via.
    Gli script chiamati ricevono ogni valore come parametro, quindi nessuno di
    loro fa altre domande a meta' strada.

    I due task finiscono nella stessa cartella del Task Scheduler, chiamata
    <Prefisso>EmailRobot (es. FMG_EmailRobot): il robot si presenta come una
    voce sola, non come task sparsi.

    Lo script e' idempotente: si puo' rieseguire per aggiungere un tenant o per
    riparare un'installazione. Non sovrascrive mai un appsettings.json
    esistente e non tocca i database gia' popolati.

.EXAMPLE
    .\Setup-EMailSender.ps1

.EXAMPLE
    # Senza domande, tutto da riga di comando
    .\Setup-EMailSender.ps1 -TenantName "FMGROUP" -DisplayName "FM Group" `
        -DbPrefix "FMG_" -SqlInstance ".\SQLEXPRESS" -SharedDatabase -Unattended
#>
[CmdletBinding()]
param(
    [string] $InstallRoot   = "C:\EMailSender",
    [string] $TenantName    = "",
    [string] $DisplayName   = "",
    [string] $DbPrefix      = "",
    [string] $SqlInstance   = "",
    [string] $MainDbName    = "",
    [string] $LogDbName     = "",
    [switch] $SharedDatabase,
    [string] $LogDirectory  = "",
    [string] $Urls          = "",
    [int]    $RetentionDays = 60,

    # Parametri SMTP, opzionali: se omessi si configurano dalla Web UI.
    [string] $SmtpServer      = "",
    [int]    $SmtpPort        = 25,
    [string] $SmtpSender      = "",
    [string] $SmtpSenderAlias = "",

    # Non chiede nulla: usa i parametri passati e i default.
    [switch] $Unattended
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\EMailSenderCommon.ps1"

Assert-Administrator

# Verifica dei file necessari prima di iniziare a fare domande: scoprire a
# meta' installazione che manca uno script e' il modo peggiore di fallire.
$required = @(
    "Install-EMailSender.ps1",
    "New-EMailSenderTenant.ps1",
    "ConsoleJobSetupJob.ps1",
    "Test-EMailSenderInstall.ps1",
    "Register-EMailSenderService.ps1"
)
foreach ($r in $required) {
    if (-not (Test-Path (Join-Path $PSScriptRoot $r))) {
        throw "File mancante nella cartella di publish: $r. Copiare l'intera cartella publish\, non i singoli file."
    }
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " EMailSenderRobot - installazione guidata" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Tutte le domande sono all'inizio. Dopo la conferma finale" -ForegroundColor DarkGray
Write-Host " l'installazione procede senza altre interruzioni." -ForegroundColor DarkGray

# ===========================================================================
# FASE 1 - DOMANDE
# ===========================================================================

# --- Cartella di installazione ---------------------------------------------
if (-not $Unattended -and -not $PSBoundParameters.ContainsKey('InstallRoot')) {
    Write-Host ""
    Write-Host "=== Cartella di installazione ===" -ForegroundColor Yellow
    $InstallRoot = Read-Answer -Prompt "    Cartella [$InstallRoot]" -Default $InstallRoot
}

# --- Accesso alla Web UI ----------------------------------------------------
# Il binding non e' un dettaglio: senza la chiave Urls, Kestrel ascolta solo su
# loopback e nessuna regola firewall lo rende raggiungibile da fuori.
if ([string]::IsNullOrWhiteSpace($Urls)) {
    if ($Unattended) {
        $Urls = "http://localhost:5000"
    }
    else {
        Write-Host ""
        Write-Host "=== Accesso alla pagina web ===" -ForegroundColor Yellow
        Write-Host "    La Web UI non ha autenticazione: esporla in rete significa dare a" -ForegroundColor DarkGray
        Write-Host "    chiunque la raggiunga l'accesso a configurazioni SMTP e contenuti mail." -ForegroundColor DarkGray
        Write-Host "      [1] Solo da questa macchina  (http://localhost:5000)"
        Write-Host "      [2] Anche da altri PC        (http://*:5000, con regola firewall)"
        Write-Host ""

        while ($true) {
            $answer = Read-Answer -Prompt "    Accesso (1-2)" -Default "1"
            if ($answer -eq "1") { $Urls = "http://localhost:5000"; break }
            if ($answer -eq "2") { $Urls = "http://*:5000";         break }
            Write-Host "    Risposta non valida: indicare 1 o 2." -ForegroundColor Red
        }
    }
}

# --- Prefisso ---------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('DbPrefix') -and -not $Unattended) {
    $DbPrefix = Resolve-DbPrefix
}

# --- Tenant -----------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($TenantName)) {
    if ($Unattended) { throw "In modalita' -Unattended il parametro -TenantName e' obbligatorio." }
    $TenantName = Resolve-TenantName
}
else {
    if (-not (Test-TenantNameValid -Name $TenantName)) { throw "Nome tenant non valido: '$TenantName'." }
}

if ([string]::IsNullOrWhiteSpace($DisplayName)) {
    if ($Unattended) { $DisplayName = $TenantName }
    else {
        Write-Host ""
        $DisplayName = Read-Answer -Prompt "    Descrizione del tenant [$TenantName]" -Default $TenantName
    }
}

# --- Istanza SQL ------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SqlInstance)) {
    if ($Unattended) { throw "In modalita' -Unattended il parametro -SqlInstance e' obbligatorio." }
    $SqlInstance = Resolve-SqlInstance
}

# --- Layout dei database ----------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('SharedDatabase') -and -not $Unattended) {

    Write-Host ""
    Write-Host "=== Layout dei database ===" -ForegroundColor Yellow
    Write-Host "      [1] Un database unico per il robot, condiviso da tutti i tenant"
    Write-Host "          Piu' semplice da gestire: un backup solo, un solo task di"
    Write-Host "          spedizione anche aggiungendo altri tenant."
    Write-Host "      [2] Un database per tenant"
    Write-Host "          Isolamento totale: la dismissione di un cliente e' un DROP"
    Write-Host "          DATABASE e il restore non tocca gli altri."
    Write-Host ""

    while ($true) {
        $answer = Read-Answer -Prompt "    Layout (1-2)" -Default "1"
        if ($answer -eq "1") { $SharedDatabase = $true;  break }
        if ($answer -eq "2") { $SharedDatabase = $false; break }
        Write-Host "    Risposta non valida: indicare 1 o 2." -ForegroundColor Red
    }
}

# --- Nomi dei database ------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($MainDbName)) {
    if ($SharedDatabase) {
        # Nessun tenant nel nome: i clienti aggiunti dopo finirebbero in un
        # database che porta il nome del primo.
        $MainDbName = "{0}EMailSenderRobot" -f $DbPrefix
    }
    else {
        # Suffisso "_Mail", non "_Main": questo database appartiene al robot,
        # non all'applicazione del tenant.
        $MainDbName = "{0}{1}_Mail" -f $DbPrefix, $TenantName
    }
}

if ($SharedDatabase) { $LogDbName = $MainDbName }
elseif ([string]::IsNullOrWhiteSpace($LogDbName)) {
    $LogDbName = "{0}{1}_MailLog" -f $DbPrefix, $TenantName
}

# --- Cartella dei log -------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Join-Path "C:\EMailSenderData" (Join-Path $TenantName "Log")
}

# --- Parametri SMTP ---------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SmtpServer) -and -not $Unattended) {

    Write-Host ""
    Write-Host "=== Server di posta in uscita ===" -ForegroundColor Yellow
    Write-Host "    Si possono lasciare vuoti e compilarli dopo dalla pagina Config SMTP." -ForegroundColor DarkGray
    Write-Host ""

    $SmtpServer = Read-Answer -Prompt "    Server SMTP (invio per saltare)" -Default ""

    if (-not [string]::IsNullOrWhiteSpace($SmtpServer)) {
        $portAnswer      = Read-Answer -Prompt "    Porta [25]" -Default "25"
        $parsedPort      = 25
        if ([int]::TryParse($portAnswer, [ref] $parsedPort)) { $SmtpPort = $parsedPort }

        $SmtpSender      = Read-Answer -Prompt "    Indirizzo mittente (es. noreply@fmgsrl.com)" -Default ""
        $SmtpSenderAlias = Read-Answer -Prompt "    Nome mittente visualizzato [$DisplayName]" -Default $DisplayName
    }
}

# --- Cartella dei task ------------------------------------------------------
# Entrambi i task del robot stanno insieme, sotto un'unica voce riconoscibile.
$taskFolder = "\{0}EmailRobot" -f $DbPrefix

# ===========================================================================
# RIEPILOGO E CONFERMA UNICA
# ===========================================================================
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host " RIEPILOGO" -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host ("  Cartella installazione : {0}" -f $InstallRoot)
Write-Host ("  Accesso Web UI         : {0}" -f $Urls)
Write-Host ("  Tenant                 : {0} ({1})" -f $TenantName, $DisplayName)
Write-Host ("  Istanza SQL            : {0}" -f $SqlInstance)
if ($SharedDatabase) {
    Write-Host ("  Database               : {0}   (unico, tutte e 5 le tabelle)" -f $MainDbName)
}
else {
    Write-Host ("  Database configurazione: {0}" -f $MainDbName)
    Write-Host ("  Database log           : {0}" -f $LogDbName)
}
Write-Host ("  Cartella log su disco  : {0}" -f $LogDirectory)
Write-Host ("  Cartella task          : {0}" -f $taskFolder)
Write-Host ("  Conservazione log      : {0} giorni (file e database), pulizia giornaliera dal job" -f $RetentionDays)
if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
    Write-Host  "  SMTP                   : da configurare dalla Web UI"
}
else {
    Write-Host ("  SMTP                   : {0}:{1}, mittente {2}" -f $SmtpServer, $SmtpPort, $SmtpSender)
}
Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host ""

if (-not $Unattended) {
    if (-not (Read-Confirmation -Prompt "  Procedo con l'installazione?" -Default $true)) {
        Write-Host ""
        Write-Host "Annullato: non e' stato modificato nulla." -ForegroundColor Cyan
        Write-Host ""
        return
    }
}

# ===========================================================================
# FASE 2 - ESECUZIONE
# ===========================================================================

$step = 0
function Write-Step {
    param([string] $Text)
    $script:step++
    Write-Host ""
    Write-Host "#########################################################" -ForegroundColor Magenta
    Write-Host "# PASSO $script:step - $Text" -ForegroundColor Magenta
    Write-Host "#########################################################" -ForegroundColor Magenta
}

# --- 1. Installazione dei file e del servizio -------------------------------
Write-Step "Installazione file, servizio e firewall"
& (Join-Path $PSScriptRoot "Install-EMailSender.ps1") `
    -InstallRoot $InstallRoot -Urls $Urls

# --- 2. Tenant --------------------------------------------------------------
Write-Step "Database, tabelle e configurazione del tenant"
$tenantArgs = @{
    TenantName       = $TenantName
    DisplayName      = $DisplayName
    SqlInstance      = $SqlInstance
    DbPrefix         = $DbPrefix
    MainDbName       = $MainDbName
    LogDbName        = $LogDbName
    LogDirectory     = $LogDirectory
    LogRetentionDays = $RetentionDays
    InstallRoot      = $InstallRoot
}
if ($SharedDatabase) { $tenantArgs["SharedDatabase"] = $true }
if (-not [string]::IsNullOrWhiteSpace($SmtpServer)) {
    $tenantArgs["SmtpServer"]      = $SmtpServer
    $tenantArgs["SmtpPort"]        = $SmtpPort
    $tenantArgs["SmtpSender"]      = $SmtpSender
    $tenantArgs["SmtpSenderAlias"] = $SmtpSenderAlias
}

& (Join-Path $PSScriptRoot "New-EMailSenderTenant.ps1") @tenantArgs

# --- 3. Task di spedizione --------------------------------------------------
Write-Step "Task di spedizione (ogni minuto)"
& (Join-Path $PSScriptRoot "ConsoleJobSetupJob.ps1") `
    -TenantId $TenantName -InstallRoot $InstallRoot -TaskFolder $taskFolder

# --- 4. Riavvio del servizio ------------------------------------------------
# Il servizio e' partito prima che la configurazione del tenant esistesse: va
# riavviato perche' la rilegga.
Write-Step "Riavvio del servizio"
try {
    Restart-Service -Name "EMailSenderWeb" -Force
    Start-Sleep -Seconds 3
    Write-Host "    Stato: $((Get-Service -Name 'EMailSenderWeb').Status)" -ForegroundColor Cyan
}
catch {
    Write-Host "    Riavvio non riuscito: $_" -ForegroundColor Red
}

# --- 5. Verifica ------------------------------------------------------------
Write-Step "Verifica dell'installazione"
& (Join-Path $PSScriptRoot "Test-EMailSenderInstall.ps1") `
    -InstallRoot $InstallRoot -TenantName $TenantName

# ===========================================================================
# CHIUSURA
# ===========================================================================
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host " Installazione completata." -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host " Pagina web:  $($Urls -replace '\*', 'localhost')"
Write-Host ""

if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
    Write-Host " Resta da fare:" -ForegroundColor Yellow
    Write-Host "   1. parametri SMTP dalla pagina Config SMTP"
    Write-Host "   2. pulsante 'Test invio mail' per la prova"
}
else {
    Write-Host " Resta da fare: la prova con il pulsante 'Test invio mail'" -ForegroundColor Yellow
    Write-Host " nella pagina Config SMTP."
}

Write-Host ""
Write-Host " I due task del robot sono in Utilita' di pianificazione, cartella $taskFolder" -ForegroundColor DarkGray
Write-Host " Diagnosi in qualsiasi momento: $InstallRoot\Test-EMailSenderInstall.ps1" -ForegroundColor DarkGray
Write-Host ""
