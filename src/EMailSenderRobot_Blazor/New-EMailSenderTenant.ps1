<#
.SYNOPSIS
    Predispone un tenant del robot: database, tabelle, permessi, riga SMTP,
    voci di configurazione nei due appsettings.json e task dello Scheduler.

.DESCRIPTION
    Automatizza l'intera sezione "Aggiunta di un nuovo tenant" della guida,
    che finora era una sequenza manuale di SQL + editing a mano di due file
    di configurazione. Lo script e' idempotente: si puo' rieseguire per
    aggiornare un tenant esistente.

    DUE LAYOUT DI DATABASE SUPPORTATI

    1) UN DB PER TENANT (default, convenzione EasyWebParts)
         -MainDbName  Ewp_<Tenant>_MainDb
         -LogDbName   Ewp_<Tenant>_LoggerDb
       Le 4 tabelle di configurazione stanno sul Main, la tabella "log" sul
       Log. L'uscita di un cliente si chiude con DROP DATABASE.

    2) UN DB UNICO DEL ROBOT (parametro -SharedDatabase)
         -MainDbName = -LogDbName = es. FMG_EmailSenderRobot
       Tutte e 5 le tabelle nello stesso database. Nulla nel codice lo
       vieta: "X_Main" e "X_Log" sono due chiavi di configurazione
       indipendenti e possono puntare allo stesso DB. In questo layout
       l'uscita di un cliente e' un DELETE ... WHERE Company = '<Tenant>'
       sulle 5 tabelle (piu' la cartella dei log su disco e gli allegati,
       che sono percorsi su filesystem, non blob).

    NOTA SUL PREFISSO DEL NOME DATABASE
    Il prefisso "Ewp_" e' solo una convenzione di naming di EasyWebParts:
    non e' cablato in nessun punto del codice, che usa unicamente le chiavi
    di configurazione "<Tenant>_Main" e "<Tenant>_Log". Con -DbPrefix ""
    (default) i database si chiamano <Tenant>_MainDb / <Tenant>_LoggerDb.

    NOTA SUL NUMERO DI TASK
    Il ciclo di spedizione non filtra per company: una singola esecuzione
    svuota la coda di tutti i tenant risolvendo la configurazione SMTP riga
    per riga. Con il layout 2 basta quindi UN task per tutti (si crea una
    volta sola con -CreateTask sul tenant di bootstrap, e per gli altri si
    omette). Con il layout 1 serve un task per tenant, perche' ognuno
    punta a un database diverso.

.EXAMPLE
    # Layout 1 - un DB per tenant, convenzione EWP
    .\New-EMailSenderTenant.ps1 -TenantName "Acme" -DisplayName "Acme Spa" `
        -DbPrefix "Ewp_" -CreateTask

.EXAMPLE
    # Layout 2 - DB unico del robot, un solo task
    .\New-EMailSenderTenant.ps1 -TenantName "FMG" -DisplayName "FM Group" `
        -SharedDatabase -MainDbName "FMG_EmailSenderRobot" -CreateTask

.EXAMPLE
    # Aggiunta di un cliente allo stesso DB unico: nessun task nuovo
    .\New-EMailSenderTenant.ps1 -TenantName "Acme" -DisplayName "Acme Spa" `
        -SharedDatabase -MainDbName "FMG_EmailSenderRobot"
#>
[CmdletBinding()]
param(
    # Nome interno del tenant: deve coincidere con il valore passato come
    # --company al ConsoleJob e con il prefisso delle due connection string.
    # Non e' dichiarato Mandatory di proposito: il prompt nativo di PowerShell
    # non convalida nulla e su una risposta vuota interrompe lo script con un
    # errore di binding. Se manca lo chiede il blocco piu' sotto, che
    # convalida la risposta e la ripete finche' non e' accettabile.
    [string] $TenantName = "",

    # Nome mostrato nella Web UI.
    [string] $DisplayName = "",

    # Istanza SQL Server. Se omesso, lo script rileva le istanze presenti sulla
    # macchina e chiede quale usare: nessun default silenzioso, perche'
    # indovinare l'istanza sbagliata significa creare i database sul motore
    # sbagliato e accorgersene molto piu' tardi.
    [string] $SqlInstance = "",

    # Prefisso dei nomi database: identifica il progetto/prodotto proprietario
    # ("EWP_" per EasyWebParts, "FMG_" per i progetti interni). Se omesso viene
    # chiesto, perche' un database senza prefisso non si capisce a chi
    # appartenga quando l'istanza ne ospita decine.
    [string] $DbPrefix = "",

    # Nomi database espliciti: se omessi vengono derivati da prefisso+tenant.
    [string] $MainDbName = "",
    [string] $LogDbName  = "",

    # Un solo database per tutto il robot (tabelle di config + log insieme).
    [switch] $SharedDatabase,

    # Cartella dei file di log del ConsoleJob per questo tenant.
    [string] $LogDirectory = "",

    # Parametri applicativi del tenant.
    [int] $BatchSize        = 10,
    [int] $MaxRetryCount    = 2,
    [int] $LogRetentionDays = 30,

    # Parametri SMTP: se -SmtpServer e' valorizzato viene creata/aggiornata
    # la riga in ConfigEmailServer. Altrimenti si configura dalla Web UI.
    [string] $SmtpServer      = "",
    [int]    $SmtpPort        = 25,
    [string] $SmtpSender      = "",
    [string] $SmtpSenderAlias = "",

    # Cartella di installazione del robot.
    [string] $InstallRoot = "C:\EMailSender",

    # Account di servizio a cui concedere i permessi sui database.
    [string] $ServiceAccount = "NT AUTHORITY\SYSTEM",

    # Crea anche il task nel Task Scheduler (richiama ConsoleJobSetupJob.ps1).
    [switch] $CreateTask,

    # Cartella del Task Scheduler usata da -CreateTask.
    [string] $TaskFolder = "\EMailSender",

    # Salta la parte SQL: aggiorna solo i file di configurazione.
    [switch] $SkipDatabase
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Privilegi: servono per ALTER su SQL (a seconda dell'istanza), per ACL sulla
# cartella di log e per la creazione del task.
# ---------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Questo script richiede privilegi di amministratore."
}

# System.Data contiene SqlClient: si usa quello invece di sqlcmd.exe o del
# modulo SqlServer, che su un server appena installato spesso non ci sono.
Add-Type -AssemblyName System.Data

# ---------------------------------------------------------------------------
# INPUT INTERATTIVO
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Chiede un valore all'operatore, tollerando gli host non interattivi.
.DESCRIPTION
    Read-Host solleva un'eccezione quando PowerShell gira in modalita' non
    interattiva (job pianificati, esecuzioni automatizzate, alcune console
    integrate). Senza questa protezione lo script si interromperebbe a meta'
    anche quando tutti i parametri necessari sono stati passati da riga di
    comando e la domanda era solo una conferma.

    In quel caso: se la risposta ha un default lo si usa senza chiedere, se e'
    obbligatoria si fallisce con un messaggio che dice quale parametro passare.
#>
function Read-Answer {
    param(
        [Parameter(Mandatory = $true)][string] $Prompt,
        [string] $Default = "",
        [switch] $Mandatory,
        [string] $ParameterHint = ""
    )

    try {
        $answer = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer.Trim()
    }
    catch {
        if ($Mandatory) {
            throw "Host non interattivo: impossibile chiedere '$Prompt'. Passare il valore da riga di comando$(if ($ParameterHint) { " con $ParameterHint" })."
        }

        Write-Host "    (host non interattivo: uso il valore predefinito '$Default')" -ForegroundColor DarkGray
        return $Default
    }
}

# ---------------------------------------------------------------------------
# NOME DEL TENANT
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Convalida il nome di un tenant, spiegando il motivo di ogni rifiuto.
.DESCRIPTION
    Il limite di 15 caratteri non e' arbitrario: la colonna Company di
    ConfigEmailContent e ConfigEmailAddress e' NVARCHAR(15). Un nome piu'
    lungo verrebbe troncato in scrittura e non corrisponderebbe piu' a
    Companies[].Name, facendo sparire i template senza alcun errore.
    Gli spazi sono esclusi perche' il nome viaggia come argomento --company
    sulla riga di comando del task.
#>
function Test-TenantNameValid {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Host "    Il nome del tenant e' obbligatorio." -ForegroundColor Red
        return $false
    }

    if ($Name -match '\s') {
        Write-Host "    Il nome del tenant non puo' contenere spazi (viaggia come argomento --company)." -ForegroundColor Red
        return $false
    }

    if ($Name.Length -gt 15) {
        Write-Host "    Massimo 15 caratteri: la colonna Company di ConfigEmailContent e' NVARCHAR(15)." -ForegroundColor Red
        Write-Host "    Un nome piu' lungo verrebbe troncato e i template non verrebbero piu' trovati." -ForegroundColor Red
        return $false
    }

    if ($Name -notmatch '^[A-Za-z0-9_.-]+$') {
        Write-Host "    Usare solo lettere, numeri, underscore, punto e trattino." -ForegroundColor Red
        return $false
    }

    return $true
}

if ([string]::IsNullOrWhiteSpace($TenantName)) {

    Write-Host ""
    Write-Host "=== Tenant ===" -ForegroundColor Yellow
    Write-Host "    Codice interno del tenant: e' l'identita' di spedizione del robot." -ForegroundColor Cyan
    Write-Host "    Viene usato in Companies[].Name, come prefisso delle connection string" -ForegroundColor DarkGray
    Write-Host "    (<Tenant>_Main / <Tenant>_Log), come argomento --company del task e nella" -ForegroundColor DarkGray
    Write-Host "    colonna Company delle tabelle. Non e' il nome del database." -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $TenantName = Read-Answer -Prompt "    Nome del tenant (es. FMGROUP)" -Mandatory -ParameterHint "-TenantName"
        if (Test-TenantNameValid -Name $TenantName) { break }
    }
}
else {
    # Convalida anche il valore passato da riga di comando: le stesse regole
    # valgono comunque, e fallire adesso e' meglio che scoprirlo a database
    # creati.
    if (-not (Test-TenantNameValid -Name $TenantName)) {
        throw "Nome tenant non valido: '$TenantName'."
    }
}

# ---------------------------------------------------------------------------
# ISTANZA SQL SERVER
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Elenca le istanze SQL Server locali nel formato usato nelle connection string.
.DESCRIPTION
    Legge il registro di sistema, che e' la fonte piu' affidabile: elenca anche
    le istanze installate ma con il servizio fermo, che l'elenco dei servizi in
    esecuzione non mostrerebbe.
    L'istanza predefinita (MSSQLSERVER) si indirizza con ".", le istanze
    nominate con ".\NOME".
#>
function Get-LocalSqlInstances {
    $instances = @()
    $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"

    try {
        if (Test-Path $regPath) {
            $props = Get-ItemProperty -Path $regPath
            foreach ($p in $props.PSObject.Properties) {
                # Si scartano le proprieta' di servizio di PowerShell
                # (PSPath, PSParentPath, PSChildName, PSDrive, PSProvider).
                if ($p.Name -like "PS*") { continue }

                if ($p.Name -eq "MSSQLSERVER") { $instances += "." }
                else                           { $instances += ".\$($p.Name)" }
            }
        }
    }
    catch {
        # Registro non leggibile: si prosegue con l'elenco vuoto e si chiede
        # comunque all'operatore.
    }

    return $instances
}

<#
.SYNOPSIS
    Restituisce lo stato del servizio Windows di un'istanza SQL.
.DESCRIPTION
    Un'istanza installata ma con il servizio fermo e' la causa piu' frequente
    di "connessione fallita": mostrarlo nell'elenco evita di cercare altrove.
    Il servizio dell'istanza predefinita si chiama MSSQLSERVER, quello delle
    istanze nominate MSSQL$NOME.
#>
function Get-SqlServiceState {
    param([Parameter(Mandatory = $true)][string] $Instance)

    if ($Instance -eq ".") { $svcName = "MSSQLSERVER" }
    else                   { $svcName = "MSSQL`$" + $Instance.Substring(2) }

    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return "stato sconosciuto" }
    return [string] $svc.Status
}

<#
.SYNOPSIS
    Apre una connessione di prova e restituisce la descrizione dell'istanza.
.DESCRIPTION
    Solleva un'eccezione se l'istanza non e' raggiungibile: meglio fallire qui,
    con un messaggio comprensibile, che alla prima CREATE DATABASE.
#>
function Test-SqlInstance {
    param([Parameter(Mandatory = $true)][string] $Instance)

    $cs = "data source=$Instance;Integrated Security=SSPI;Connection Timeout=10;TrustServerCertificate=True"
    $cn = New-Object System.Data.SqlClient.SqlConnection($cs)
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = "SELECT CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) + N' - ' + CONVERT(nvarchar(128), SERVERPROPERTY('Edition'))"
        return [string] $cmd.ExecuteScalar()
    }
    finally {
        $cn.Close()
    }
}

# Se l'istanza non e' stata passata come parametro, la si chiede proponendo
# quelle rilevate sulla macchina.
$instanceWasGiven = $PSBoundParameters.ContainsKey('SqlInstance')

if ([string]::IsNullOrWhiteSpace($SqlInstance)) {

    Write-Host ""
    Write-Host "=== Istanza SQL Server ===" -ForegroundColor Yellow

    $found = @(Get-LocalSqlInstances)

    if ($found.Count -eq 0) {

        # --- Nessuna istanza locale -------------------------------------
        # Caso normale quando SQL Server sta su un'altra macchina.
        Write-Host "    Nessuna istanza locale rilevata." -ForegroundColor Cyan
        Write-Host "    Se SQL Server e' su un'altra macchina indicare NOMESERVER o NOMESERVER\ISTANZA." -ForegroundColor Cyan
        Write-Host ""

        $SqlInstance = Read-Answer -Prompt "    Istanza da usare [.\SQLEXPRESS]" -Default ".\SQLEXPRESS"
    }
    elseif ($found.Count -eq 1) {

        # --- Una sola istanza -------------------------------------------
        # Si puo' proporre come default senza rischi: non c'e' alternativa
        # locale da confondere.
        $only = $found[0]
        Write-Host "    Istanza rilevata su questa macchina:" -ForegroundColor Cyan
        Write-Host ("      {0,-24} [{1}]" -f $only, (Get-SqlServiceState -Instance $only))
        Write-Host ""

        $SqlInstance = Read-Answer -Prompt "    Istanza da usare [$only]" -Default $only
    }
    else {

        # --- Piu' istanze: scelta obbligatoria, nessun default -----------
        # Con piu' motori sulla stessa macchina proporre un default sarebbe
        # pericoloso: un invio dato per abitudine creerebbe i database su
        # quello sbagliato, e l'errore verrebbe fuori molto piu' tardi.
        # Si pretende quindi una scelta esplicita, per numero o per nome.
        Write-Host "    Rilevate $($found.Count) istanze su questa macchina:" -ForegroundColor Cyan
        for ($n = 0; $n -lt $found.Count; $n++) {
            $label = $found[$n]
            $extra = ""
            if ($label -eq ".") { $extra = "  (istanza predefinita)" }
            Write-Host ("      [{0}] {1,-24} [{2}]{3}" -f ($n + 1), $label, (Get-SqlServiceState -Instance $label), $extra)
        }

        # Ultima voce del menu: un'istanza che il rilevamento locale non vede,
        # tipicamente su un altro server. Resta una scelta numerata come le
        # altre, il nome viene chiesto dopo.
        $otherIndex = $found.Count + 1
        Write-Host ("      [{0}] Altra istanza (server remoto o non in elenco)" -f $otherIndex)

        Write-Host ""
        Write-Host "    Nessuna scelta predefinita: indicare quale usare." -ForegroundColor Yellow

        while ($true) {
            Write-Host ""
            $answer = Read-Answer -Prompt "    Istanza da usare (1-$otherIndex)" -Mandatory -ParameterHint "-SqlInstance"

            $index = 0
            if ([int]::TryParse($answer, [ref] $index)) {

                if ($index -ge 1 -and $index -le $found.Count) {
                    $SqlInstance = $found[$index - 1]
                    break
                }

                if ($index -eq $otherIndex) {
                    $SqlInstance = Read-Answer -Prompt "    Nome dell'istanza (es. NOMESERVER\ISTANZA)" -Mandatory -ParameterHint "-SqlInstance"
                    if (-not [string]::IsNullOrWhiteSpace($SqlInstance)) { break }
                    Write-Host "    Risposta obbligatoria." -ForegroundColor Red
                    continue
                }
            }

            Write-Host "    Risposta non valida: indicare un valore da 1 a $otherIndex." -ForegroundColor Red
        }
    }

    Write-Host "    Istanza scelta: $SqlInstance" -ForegroundColor Cyan
}

# Verifica di raggiungibilita'. Se l'istanza e' stata chiesta interattivamente
# si concede di correggerla senza rilanciare tutto lo script; se invece era un
# parametro esplicito si fallisce subito, per non bloccare usi automatizzati.
if (-not $SkipDatabase) {

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $serverInfo = Test-SqlInstance -Instance $SqlInstance
            Write-Host "    Connessione riuscita a '$SqlInstance' ($serverInfo)." -ForegroundColor Green
            break
        }
        catch {
            Write-Host "    Connessione fallita a '$SqlInstance': $($_.Exception.Message)" -ForegroundColor Red

            if ($instanceWasGiven -or $attempt -ge 3) {
                throw "Istanza SQL '$SqlInstance' non raggiungibile. Verificare nome, servizio avviato, e per istanze remote che TCP/IP e SQL Browser siano attivi."
            }

            $retry = Read-Answer -Prompt "    Riprovare con quale istanza? (invio per annullare)" -Mandatory -ParameterHint "-SqlInstance"
            if ([string]::IsNullOrWhiteSpace($retry)) {
                throw "Operazione annullata: nessuna istanza SQL valida."
            }
            $SqlInstance = $retry.Trim()
        }
    }
}

# ---------------------------------------------------------------------------
# Normalizzazione dei parametri derivati
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName = $TenantName }

# ---------------------------------------------------------------------------
# PREFISSO DEI NOMI DATABASE
# Chiesto se non passato: serve a dire di quale progetto/prodotto sono i
# database, sulle istanze che ne ospitano molti.
# ---------------------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('DbPrefix')) {

    Write-Host ""
    Write-Host "=== Prefisso dei nomi database ===" -ForegroundColor Yellow
    Write-Host "    Identifica il progetto/prodotto proprietario dei database:" -ForegroundColor Cyan
    Write-Host "      [1] EWP_    prodotto EasyWebParts"
    Write-Host "      [2] FMG_    progetti interni FMGroup"
    Write-Host "      [3] Altro prefisso"
    Write-Host "      [4] Nessun prefisso"
    Write-Host ""

    # Si insiste finche' la risposta non e' una delle quattro previste: un
    # prefisso sbagliato si paga rinominando database gia' popolati.
    while ($true) {

        # In assenza di interazione (esecuzione automatizzata) si ripiega su
        # "nessun prefisso", che e' l'unica scelta neutra.
        $answer = Read-Answer -Prompt "    Prefisso (1-4)" -Default "4"

        if ($answer -eq "1") { $DbPrefix = "EWP_"; break }
        if ($answer -eq "2") { $DbPrefix = "FMG_"; break }
        if ($answer -eq "4") { $DbPrefix = "";     break }

        if ($answer -eq "3") {
            $DbPrefix = Read-Answer -Prompt "    Prefisso da usare, underscore finale incluso (es. ABC_)" -Default ""
            break
        }

        Write-Host "    Risposta non valida: indicare un valore da 1 a 4." -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# NOMI DEI DATABASE
#
# Il suffisso e' "_Mail" / "_MailLog", non "_Main" / "_LoggerDb": le tabelle
# del robot stanno in un database PROPRIO, distinto dal database applicativo
# del tenant. Chiamarlo "_Main" farebbe pensare al database principale
# dell'applicazione, che e' esattamente quello da cui si vuole separarlo.
# ---------------------------------------------------------------------------
$namesWereDerived = $false

if ([string]::IsNullOrWhiteSpace($MainDbName)) {

    if ($SharedDatabase) {
        # Database unico del robot, condiviso da tutti i tenant: il nome NON
        # contiene il tenant, che sarebbe fuorviante — i clienti aggiunti dopo
        # finirebbero in un database che porta il nome del primo.
        $MainDbName = "{0}EMailSenderRobot" -f $DbPrefix
    }
    else {
        # Un database per tenant: il tenant nel nome ci vuole, e il ruolo e'
        # "Mail", non "Main", perche' questo database appartiene al robot e
        # non all'applicazione del tenant.
        $MainDbName = "{0}{1}_Mail" -f $DbPrefix, $TenantName
    }

    $namesWereDerived = $true
}

if ($SharedDatabase) {
    # Layout a database unico: le 5 tabelle, log compreso, stanno insieme.
    $LogDbName = $MainDbName
}
elseif ([string]::IsNullOrWhiteSpace($LogDbName)) {
    $LogDbName = "{0}{1}_MailLog" -f $DbPrefix, $TenantName
    $namesWereDerived = $true
}

# ---------------------------------------------------------------------------
# Conferma dei nomi ricavati automaticamente.
# Rinominare un database dopo averlo popolato costa molto piu' che rispondere
# a una domanda adesso: si mostra cosa verrebbe creato e si chiede conferma.
# ---------------------------------------------------------------------------
if ($namesWereDerived) {

    Write-Host ""
    Write-Host "=== Nomi dei database ===" -ForegroundColor Yellow
    if ($SharedDatabase) {
        Write-Host "    Database unico (tutte e 5 le tabelle): $MainDbName" -ForegroundColor Cyan
    }
    else {
        Write-Host "    Configurazione e coda : $MainDbName" -ForegroundColor Cyan
        Write-Host "    Log                   : $LogDbName" -ForegroundColor Cyan
    }

    Write-Host ""
    $confirm = Read-Answer -Prompt "    Confermi questi nomi? [S/n]" -Default "S"

    if ($confirm -match '^[nN]') {
        $newMain = Read-Answer -Prompt "    Nome del database principale [$MainDbName]" -Default $MainDbName
        if (-not [string]::IsNullOrWhiteSpace($newMain)) { $MainDbName = $newMain }

        if ($SharedDatabase) {
            $LogDbName = $MainDbName
        }
        else {
            $newLog = Read-Answer -Prompt "    Nome del database di log [$LogDbName]" -Default $LogDbName
            if (-not [string]::IsNullOrWhiteSpace($newLog)) { $LogDbName = $newLog }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Join-Path "C:\EMailSenderData" (Join-Path $TenantName "Log")
}

# Connection string di servizio (senza database) per le operazioni a livello
# di istanza, e le due connection string che finiranno negli appsettings.
$masterConn  = "data source=$SqlInstance;Integrated Security=SSPI;Connection Timeout=30;TrustServerCertificate=True"
$connStrMain = "data source=$SqlInstance;Integrated Security=SSPI;Connection Timeout=60;Database=$MainDbName;TrustServerCertificate=True"
$connStrLog  = "data source=$SqlInstance;Integrated Security=SSPI;Connection Timeout=60;Database=$LogDbName;TrustServerCertificate=True"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Yellow
Write-Host " Tenant        : $TenantName ($DisplayName)"
Write-Host " Istanza SQL   : $SqlInstance"
Write-Host " DB principale : $MainDbName"
if ($SharedDatabase) {
    Write-Host " DB log        : $LogDbName  (DB UNICO condiviso)" -ForegroundColor Cyan
} else {
    Write-Host " DB log        : $LogDbName"
}
Write-Host " Cartella log  : $LogDirectory"
Write-Host "=========================================================" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# HELPER SQL
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Esegue uno statement non-query su una connection string data.
#>
function Invoke-Sql {
    param(
        [Parameter(Mandatory = $true)][string] $ConnectionString,
        [Parameter(Mandatory = $true)][string] $Sql
    )

    $cn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 120
        [void] $cmd.ExecuteNonQuery()
    }
    finally {
        $cn.Close()
    }
}

<#
.SYNOPSIS
    Esegue una query scalare e restituisce il primo valore.
#>
function Invoke-SqlScalar {
    param(
        [Parameter(Mandatory = $true)][string] $ConnectionString,
        [Parameter(Mandatory = $true)][string] $Sql
    )

    $cn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 120
        return $cmd.ExecuteScalar()
    }
    finally {
        $cn.Close()
    }
}

# ---------------------------------------------------------------------------
# PASSO 1 - Database
# ---------------------------------------------------------------------------
if (-not $SkipDatabase) {

    Write-Host ""
    Write-Host "=== 1. Database ===" -ForegroundColor Yellow

    # Elenco dei database da creare: nel layout condiviso e' uno solo.
    $dbList = @($MainDbName)
    if ($LogDbName -ne $MainDbName) { $dbList += $LogDbName }

    foreach ($db in $dbList) {
        # QUOTENAME evita problemi con nomi che contengono caratteri speciali.
        $exists = Invoke-SqlScalar -ConnectionString $masterConn `
                    -Sql "SELECT DB_ID(N'$db')"
        if ($null -eq $exists -or $exists -is [DBNull]) {
            Invoke-Sql -ConnectionString $masterConn -Sql "CREATE DATABASE [$db]"
            Write-Host "    Creato database [$db]." -ForegroundColor Green
        }
        else {
            Write-Host "    Database [$db] gia' presente." -ForegroundColor Cyan
        }
    }

    # -----------------------------------------------------------------------
    # PASSO 2 - Tabelle di configurazione e coda (sul DB principale)
    # Gli statement sono idempotenti: si possono rieseguire senza errori.
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== 2. Tabelle ===" -ForegroundColor Yellow

    $ddlMain = @"
-- Coda delle mail da spedire.
IF OBJECT_ID(N'ConfigEmailJobSchedule', N'U') IS NULL
CREATE TABLE ConfigEmailJobSchedule (
    EmailId           INT IDENTITY PRIMARY KEY,
    Company           NVARCHAR(50)   NOT NULL,
    JobReference      NVARCHAR(100)  NOT NULL DEFAULT '',
    EmailType         NVARCHAR(50)   NOT NULL DEFAULT '',
    EmailBodyIsHtml   NCHAR(1)       NOT NULL DEFAULT 'N',
    EmailObject       NVARCHAR(500)  NOT NULL DEFAULT '',
    EmailBody         NVARCHAR(MAX)  NOT NULL DEFAULT '',
    EmailTo           NVARCHAR(500)  NOT NULL DEFAULT '',
    EmailCC           NVARCHAR(500)  NOT NULL DEFAULT '',
    EmailCCN          NVARCHAR(500)  NOT NULL DEFAULT '',
    EmailAttachments  NVARCHAR(1000) NOT NULL DEFAULT '',
    CreationTimeStamp DATETIME       NULL,
    SentTimeStamp     DATETIME       NULL,
    IsError           NCHAR(1)       NOT NULL DEFAULT 'N',
    ErrorMessage      NVARCHAR(MAX)  NOT NULL DEFAULT '',
    RetryCount        INT            NOT NULL DEFAULT 0,
    IsScheduled       NCHAR(1)       NOT NULL DEFAULT 'N'
);

-- Indice a supporto della query di prelievo del batch
-- (SentTimeStamp IS NULL AND IsScheduled = 'N' ORDER BY IsError DESC, EmailId).
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = N'IX_ConfigEmailJobSchedule_Pending'
                  AND object_id = OBJECT_ID(N'ConfigEmailJobSchedule'))
CREATE INDEX IX_ConfigEmailJobSchedule_Pending
    ON ConfigEmailJobSchedule (IsScheduled, SentTimeStamp, IsError, EmailId)
    INCLUDE (Company);

-- Parametri del server SMTP, una riga per tenant.
-- IsDeliveryBlocked = 'S' blocca le spedizioni (unico flag di blocco
-- effettivamente letto dal ConsoleJob).
IF OBJECT_ID(N'ConfigEmailServer', N'U') IS NULL
CREATE TABLE ConfigEmailServer (
    company           NVARCHAR(50)   PRIMARY KEY,
    Smtp_Server       NVARCHAR(200)  NOT NULL DEFAULT '',
    Smtp_Port         INT            NOT NULL DEFAULT 25,
    Smtp_Ssl          NCHAR(1)       NOT NULL DEFAULT 'N',
    Smtp_StartTls     NCHAR(1)       NOT NULL DEFAULT 'N',
    Smtp_Auth         NCHAR(1)       NOT NULL DEFAULT 'N',
    Smtp_User         NVARCHAR(200)  NOT NULL DEFAULT '',
    Smtp_Password     NVARCHAR(200)  NOT NULL DEFAULT '',
    Smtp_Sender       NVARCHAR(200)  NOT NULL DEFAULT '',
    Smtp_SenderAlias  NVARCHAR(200)  NOT NULL DEFAULT '',
    IsDeliveryBlocked NCHAR(1)       NOT NULL DEFAULT 'N'
);

-- Contenuto delle mail. Chiave logica: Company + Type + Language.
IF OBJECT_ID(N'ConfigEmailContent', N'U') IS NULL
CREATE TABLE ConfigEmailContent (
    Company              NVARCHAR(15)   NULL,
    Type                 NVARCHAR(512)  NULL,
    Language             NVARCHAR(5)    NOT NULL DEFAULT 'IT',
    EmailHeader          NVARCHAR(MAX)  NULL,
    EmailBody            NVARCHAR(MAX)  NULL,
    EmailBodyRowRepeater NVARCHAR(MAX)  NULL,
    EmailFooter          NVARCHAR(MAX)  NULL,
    EmailObject          NVARCHAR(MAX)  NULL,
    EmailIsHtml          NCHAR(1)       NULL
);

-- Destinatari per tipo di mail. Chiave logica: Company + Type.
IF OBJECT_ID(N'ConfigEmailAddress', N'U') IS NULL
CREATE TABLE ConfigEmailAddress (
    Company     NVARCHAR(15)   NULL,
    Type        NVARCHAR(512)  NULL,
    EmailTO     NVARCHAR(512)  NULL,
    EmailCC     NVARCHAR(512)  NULL,
    EmailCCN    NVARCHAR(512)  NULL,
    Description NVARCHAR(512)  NULL
);
"@

    Invoke-Sql -ConnectionString $connStrMain -Sql $ddlMain
    Write-Host "    Tabelle di configurazione e coda verificate su [$MainDbName]." -ForegroundColor Green

    # Tabella di log: sul DB di log, che nel layout condiviso e' lo stesso.
    $ddlLog = @"
IF OBJECT_ID(N'log', N'U') IS NULL
CREATE TABLE log (
    Id         BIGINT IDENTITY PRIMARY KEY,
    TimeStamp  DATETIME       NULL DEFAULT GETDATE(),
    company    NVARCHAR(50)   NOT NULL DEFAULT '',
    data       NVARCHAR(10)   NOT NULL DEFAULT '',
    ora        NVARCHAR(8)    NOT NULL DEFAULT '',
    tipo       NVARCHAR(50)   NOT NULL DEFAULT '',
    operazione NVARCHAR(100)  NOT NULL DEFAULT '',
    descr      NVARCHAR(MAX)  NULL
);

-- Indice per la pagina Log della Web UI, che filtra per company.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = N'IX_log_company_ts'
                  AND object_id = OBJECT_ID(N'log'))
CREATE INDEX IX_log_company_ts ON log (company, [TimeStamp] DESC);
"@

    Invoke-Sql -ConnectionString $connStrLog -Sql $ddlLog
    Write-Host "    Tabella log verificata su [$LogDbName]." -ForegroundColor Green

    # -----------------------------------------------------------------------
    # PASSO 3 - Permessi per l'account di servizio
    # Servono su entrambi i database: il ConsoleJob gira come SYSTEM dal Task
    # Scheduler e la Web UI come LocalSystem.
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== 3. Permessi SQL per [$ServiceAccount] ===" -ForegroundColor Yellow

    # Login a livello di istanza.
    $loginSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$ServiceAccount')
    CREATE LOGIN [$ServiceAccount] FROM WINDOWS;
"@
    Invoke-Sql -ConnectionString $masterConn -Sql $loginSql

    # Utente e ruoli su ciascun database.
    $grantSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$ServiceAccount')
    CREATE USER [$ServiceAccount] FOR LOGIN [$ServiceAccount];
ALTER ROLE db_datareader ADD MEMBER [$ServiceAccount];
ALTER ROLE db_datawriter ADD MEMBER [$ServiceAccount];
"@

    foreach ($cs in @($connStrMain, $connStrLog)) {
        Invoke-Sql -ConnectionString $cs -Sql $grantSql
    }
    Write-Host "    Login, utente e ruoli db_datareader/db_datawriter concessi." -ForegroundColor Green

    # -----------------------------------------------------------------------
    # PASSO 4 - Riga SMTP del tenant
    # Senza questa riga ogni mail del tenant finisce in errore con
    # "Config SMTP non trovata" (Program.cs, ProcessJob).
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== 4. Riga ConfigEmailServer ===" -ForegroundColor Yellow

    $smtpServerEsc = $SmtpServer.Replace("'", "''")
    $smtpSenderEsc = $SmtpSender.Replace("'", "''")
    $smtpAliasEsc  = $SmtpSenderAlias.Replace("'", "''")
    $tenantEsc     = $TenantName.Replace("'", "''")

    # Si inserisce solo se manca: una riesecuzione non sovrascrive parametri
    # gia' messi a punto dalla Web UI.
    $smtpSql = @"
IF NOT EXISTS (SELECT 1 FROM ConfigEmailServer WHERE company = N'$tenantEsc')
INSERT INTO ConfigEmailServer
    (company, Smtp_Server, Smtp_Port, Smtp_Ssl, Smtp_StartTls, Smtp_Auth,
     Smtp_User, Smtp_Password, Smtp_Sender, Smtp_SenderAlias, IsDeliveryBlocked)
VALUES
    (N'$tenantEsc', N'$smtpServerEsc', $SmtpPort, 'N', 'N', 'N',
     '', '', N'$smtpSenderEsc', N'$smtpAliasEsc', 'N');
"@

    Invoke-Sql -ConnectionString $connStrMain -Sql $smtpSql

    if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
        Write-Host "    Riga creata con parametri vuoti: completare dalla pagina Config SMTP." -ForegroundColor Cyan
    }
    else {
        Write-Host "    Riga presente per '$TenantName' (server: $SmtpServer)." -ForegroundColor Green
    }
}
else {
    Write-Host ""
    Write-Host "=== 1-4. Parte SQL saltata (-SkipDatabase) ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# PASSO 5 - Cartella dei file di log
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 5. Cartella di log ===" -ForegroundColor Yellow

if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    Write-Host "    Creata: $LogDirectory" -ForegroundColor Green
}
else {
    Write-Host "    Gia' presente: $LogDirectory" -ForegroundColor Cyan
}

# Permessi di scrittura per l'account di servizio: senza questi il FileLogger
# ingoia l'errore in silenzio (il try/catch di FileLogger.Write) e i file
# di log non compaiono mai.
& icacls "$LogDirectory" /grant "$($ServiceAccount):(OI)(CI)M" /T /Q | Out-Null
Write-Host "    Permessi di modifica concessi a [$ServiceAccount]." -ForegroundColor Green

# ---------------------------------------------------------------------------
# PASSO 6 - Aggiornamento dei due appsettings.json
#
# La configurazione vive in DUE copie indipendenti (Web e ConsoleJob) che il
# Deploy non sovrascrive mai. Aggiornarne una sola e' l'errore piu' comune:
# la Web UI mostra il tenant ma il job non spedisce (o viceversa).
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== 6. File di configurazione ===" -ForegroundColor Yellow

<#
.SYNOPSIS
    Verifica se un oggetto JSON possiede una proprieta' con il nome indicato.
.DESCRIPTION
    Non si usa $obj.PSObject.Properties.Name.Contains(...): su un oggetto
    ancora privo di proprieta' (il caso di un appsettings.json creato da zero)
    la collezione Name vale $null e la chiamata a Contains fallisce con
    "Impossibile chiamare un metodo su un'espressione con valore null".
    L'indicizzazione di Properties, invece, restituisce $null senza errori.
#>
function Test-JsonProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

<#
.SYNOPSIS
    Aggiunge o aggiorna un tenant e le sue connection string in un appsettings.json.
.DESCRIPTION
    Preserva tutte le chiavi non gestite dallo script (Logging, Urls,
    DefaultTenants, EmailJob, ...) perche' lavora sull'oggetto JSON esistente.
    Crea il file da zero se non esiste.
#>
function Update-AppSettings {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Tenant,
        [Parameter(Mandatory = $true)][string] $Display,
        [Parameter(Mandatory = $true)][string] $ConnMain,
        [Parameter(Mandatory = $true)][string] $ConnLog,
        [Parameter(Mandatory = $true)][string] $LogDir,
        [Parameter(Mandatory = $true)][int]    $Batch,
        [Parameter(Mandatory = $true)][int]    $MaxRetry,
        [Parameter(Mandatory = $true)][int]    $Retention
    )

    # La cartella di destinazione puo' non esistere se questo script viene
    # eseguito prima di Install-EMailSender.ps1. Si crea e si avvisa: la
    # configurazione scritta ora resta valida, perche' l'installazione non
    # sovrascrive mai un appsettings.json esistente.
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Write-Warning "Cartella '$parent' creata. Sembra che Install-EMailSender.ps1 non sia ancora stato eseguito: ricordarsi di farlo, altrimenti mancano gli eseguibili e il servizio."
    }

    if (Test-Path $Path) {
        # Backup datato prima di ogni modifica: la configurazione e' l'unico
        # stato non ricostruibile dell'installazione.
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        Copy-Item $Path "$Path.$stamp.bak" -Force

        $json = Get-Content $Path -Raw | ConvertFrom-Json
    }
    else {
        Write-Host "      File assente, viene creato: $Path" -ForegroundColor Cyan

        # Si parte da una configurazione minima gia' completa delle chiavi che
        # gli altri componenti si aspettano, invece che da un oggetto vuoto:
        # "Logging" per entrambi, e "EmailJob" per il ConsoleJob, che e' la
        # sezione da cui legge davvero MaxRetryCount.
        $json = [PSCustomObject]@{
            Logging = [PSCustomObject]@{
                LogLevel = [PSCustomObject]@{
                    "Default"              = "Information"
                    "Microsoft.AspNetCore" = "Warning"
                }
            }
        }

        if ($Path -like "*ConsoleJob*") {
            $json | Add-Member -MemberType NoteProperty -Name "EmailJob" -Value ([PSCustomObject]@{
                MaxRetryCount  = $MaxRetry
                DefaultCompany = ""
            })
        }
        else {
            # Binding di Kestrel: senza questa chiave la Web UI ascolta solo
            # su loopback. Si scrive il default conservativo.
            $json | Add-Member -MemberType NoteProperty -Name "Urls" -Value "http://localhost:5000"
            $json | Add-Member -MemberType NoteProperty -Name "IsBlocked" -Value $false
        }
    }

    # --- ConnectionStrings ---------------------------------------------
    if (-not (Test-JsonProperty -Object $json -Name "ConnectionStrings")) {
        $json | Add-Member -MemberType NoteProperty -Name "ConnectionStrings" -Value ([PSCustomObject]@{})
    }
    $cs = $json.ConnectionStrings
    foreach ($pair in @(@{ K = "$($Tenant)_Main"; V = $ConnMain }, @{ K = "$($Tenant)_Log"; V = $ConnLog })) {
        if (Test-JsonProperty -Object $cs -Name $pair.K) {
            $cs.($pair.K) = $pair.V
        }
        else {
            $cs | Add-Member -MemberType NoteProperty -Name $pair.K -Value $pair.V
        }
    }

    # --- Companies -----------------------------------------------------
    # Voce del tenant. I campi rispecchiano CompanySettings di EmailModels.cs;
    # IsSemaphoreRed non si scrive perche' e' una proprieta' calcolata.
    $entry = [PSCustomObject]@{
        Name                 = $Tenant
        DisplayName          = $Display
        BatchSize            = $Batch
        MaxRetryCount        = $MaxRetry
        LogRetentionDays     = $Retention
        LogDirectory         = $LogDir
        BackupCompany        = ""
        BackupEmailType      = ""
        SqlConfigTableServer = "ConfigEmailServer"
        SemaphoreFilePath    = ""
    }

    if (-not (Test-JsonProperty -Object $json -Name "Companies")) {
        $json | Add-Member -MemberType NoteProperty -Name "Companies" -Value @()
    }

    # Si ricostruisce l'array tenendo gli altri tenant e sostituendo il nostro.
    $others = @()
    if ($json.Companies) {
        $others = @($json.Companies | Where-Object { $_.Name -ne $Tenant })
    }
    $json.Companies = @($others + $entry)

    # --- DefaultTenants ------------------------------------------------
    # Chiave letta da ConfigService.GetDefaultTenants: la sua assenza fa
    # comparire il banner giallo di warning nella Web UI.
    if (-not (Test-JsonProperty -Object $json -Name "DefaultTenants")) {
        $json | Add-Member -MemberType NoteProperty -Name "DefaultTenants" -Value @("Development", "FMGroup")
    }

    # --- Scrittura ------------------------------------------------------
    # -Depth 10 e' necessario: con il default (2) l'array Companies verrebbe
    # serializzato come stringhe di tipo .NET invece che come oggetti JSON.
    #
    # Si scrive con WriteAllText e UTF8 SENZA BOM invece che con
    # Set-Content -Encoding UTF8, che in PowerShell 5.1 il BOM lo mette: e' la
    # stessa codifica usata da ConfigService quando la Web UI risalva il file,
    # cosi' le due scritture non si alternano cambiando i primi byte.
    $text = $json | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$webSettings = Join-Path $InstallRoot "Web\appsettings.json"
$jobSettings = Join-Path $InstallRoot "ConsoleJob\appsettings.json"

foreach ($target in @($webSettings, $jobSettings)) {
    Update-AppSettings -Path $target -Tenant $TenantName -Display $DisplayName `
        -ConnMain $connStrMain -ConnLog $connStrLog -LogDir $LogDirectory `
        -Batch $BatchSize -MaxRetry $MaxRetryCount -Retention $LogRetentionDays
    Write-Host "    Aggiornato: $target" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# PASSO 7 - Task dello Scheduler (opzionale)
# ---------------------------------------------------------------------------
if ($CreateTask) {
    Write-Host ""
    Write-Host "=== 7. Task Scheduler ===" -ForegroundColor Yellow

    $taskScript = Join-Path $PSScriptRoot "ConsoleJobSetupJob.ps1"
    if (-not (Test-Path $taskScript)) {
        Write-Warning "ConsoleJobSetupJob.ps1 non trovato in ${PSScriptRoot}: task non creato."
    }
    else {
        & $taskScript -TenantId $TenantName -InstallRoot $InstallRoot `
                      -TaskFolder $TaskFolder -BatchSize $BatchSize
    }
}
else {
    Write-Host ""
    Write-Host "=== 7. Task Scheduler: non richiesto (-CreateTask assente) ===" -ForegroundColor Cyan
    if ($SharedDatabase) {
        Write-Host "    Layout a DB unico: se un task per un altro tenant esiste gia'," -ForegroundColor Cyan
        Write-Host "    svuota anche la coda di questo tenant. Nessun task aggiuntivo serve." -ForegroundColor Cyan
    }
}

# ---------------------------------------------------------------------------
# Riepilogo e passi residui a carico dell'operatore
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host " Tenant '$TenantName' predisposto." -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host " Da completare a mano:"
if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
    Write-Host "   - parametri SMTP dalla pagina Config SMTP della Web UI"
}
Write-Host "   - riavvio del servizio Web per rileggere la configurazione:"
Write-Host "       Restart-Service EMailSenderWeb"
Write-Host "   - verifica complessiva:  .\Test-EMailSenderInstall.ps1 -TenantName $TenantName"
Write-Host ""
