<#
.SYNOPSIS
    Funzioni condivise dagli script di installazione di EMailSenderRobot.

.DESCRIPTION
    Questo file non si esegue da solo: viene incluso con il dot-sourcing dagli
    altri script della cartella.

        . "$PSScriptRoot\EMailSenderCommon.ps1"

    Contiene le domande interattive e le convalide che devono comportarsi allo
    stesso identico modo ovunque vengano poste — dal setup completo o dai
    singoli script — perche' una domanda che si comporta in due modi diversi a
    seconda di chi la fa e' peggio di una domanda in piu'.
#>

# ---------------------------------------------------------------------------
# PRIVILEGI
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Interrompe l'esecuzione se il processo non e' elevato.
.DESCRIPTION
    sc.exe, icacls, Task Scheduler e le CREATE DATABASE richiedono un token
    elevato: senza questo controllo gli script fallirebbero a meta', lasciando
    l'installazione in uno stato incoerente e difficile da diagnosticare.
#>
function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Questo script richiede privilegi di amministratore. Aprire PowerShell con 'Esegui come amministratore'."
    }
}

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
    anche quando tutti i parametri necessari erano gia' stati passati da riga
    di comando e la domanda era solo una conferma.

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

<#
.SYNOPSIS
    Pone una domanda si/no restituendo un booleano.
#>
function Read-Confirmation {
    param(
        [Parameter(Mandatory = $true)][string] $Prompt,
        [bool] $Default = $true
    )

    $hint = if ($Default) { "[S/n]" } else { "[s/N]" }
    $def  = if ($Default) { "S" } else { "N" }

    $answer = Read-Answer -Prompt "$Prompt $hint" -Default $def
    return ($answer -match '^[sSyY]')
}

# ---------------------------------------------------------------------------
# ISTANZE SQL SERVER
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
                # Si scartano le proprieta' di servizio di PowerShell.
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
    Solleva un'eccezione se l'istanza non e' raggiungibile: meglio fallire
    subito, con un messaggio comprensibile, che alla prima CREATE DATABASE.
#>
function Test-SqlInstance {
    param([Parameter(Mandatory = $true)][string] $Instance)

    Add-Type -AssemblyName System.Data

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

<#
.SYNOPSIS
    Chiede quale istanza SQL usare e ne verifica la raggiungibilita'.
.DESCRIPTION
    Comportamento differenziato per numero di istanze rilevate:
      - nessuna : si chiede il nome, tipico caso di SQL su un'altra macchina;
      - una     : viene proposta come default, l'invio la accetta;
      - piu' di una: menu numerato SENZA default. Con piu' motori sulla stessa
        macchina l'ordine dell'elenco e' arbitrario e un invio dato per
        abitudine creerebbe i database su quello sbagliato.
.PARAMETER SkipTest
    Salta la verifica di connessione (usato quando il database non va toccato).
#>
function Resolve-SqlInstance {
    param(
        [switch] $SkipTest
    )

    Write-Host ""
    Write-Host "=== Istanza SQL Server ===" -ForegroundColor Yellow

    $found    = @(Get-LocalSqlInstances)
    $instance = ""

    if ($found.Count -eq 0) {
        Write-Host "    Nessuna istanza locale rilevata." -ForegroundColor Cyan
        Write-Host "    Se SQL Server e' su un'altra macchina indicare NOMESERVER o NOMESERVER\ISTANZA." -ForegroundColor Cyan
        Write-Host ""
        $instance = Read-Answer -Prompt "    Istanza da usare [.\SQLEXPRESS]" -Default ".\SQLEXPRESS"
    }
    elseif ($found.Count -eq 1) {
        $only = $found[0]
        Write-Host "    Istanza rilevata su questa macchina:" -ForegroundColor Cyan
        Write-Host ("      {0,-24} [{1}]" -f $only, (Get-SqlServiceState -Instance $only))
        Write-Host ""
        $instance = Read-Answer -Prompt "    Istanza da usare [$only]" -Default $only
    }
    else {
        Write-Host "    Rilevate $($found.Count) istanze su questa macchina:" -ForegroundColor Cyan
        for ($n = 0; $n -lt $found.Count; $n++) {
            $label = $found[$n]
            $extra = ""
            if ($label -eq ".") { $extra = "  (istanza predefinita)" }
            Write-Host ("      [{0}] {1,-24} [{2}]{3}" -f ($n + 1), $label, (Get-SqlServiceState -Instance $label), $extra)
        }

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
                    $instance = $found[$index - 1]
                    break
                }

                if ($index -eq $otherIndex) {
                    $instance = Read-Answer -Prompt "    Nome dell'istanza (es. NOMESERVER\ISTANZA)" -Mandatory -ParameterHint "-SqlInstance"
                    if (-not [string]::IsNullOrWhiteSpace($instance)) { break }
                    Write-Host "    Risposta obbligatoria." -ForegroundColor Red
                    continue
                }
            }

            Write-Host "    Risposta non valida: indicare un valore da 1 a $otherIndex." -ForegroundColor Red
        }
    }

    Write-Host "    Istanza scelta: $instance" -ForegroundColor Cyan

    # Verifica di raggiungibilita', con possibilita' di correggere.
    if (-not $SkipTest) {
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                $serverInfo = Test-SqlInstance -Instance $instance
                Write-Host "    Connessione riuscita ($serverInfo)." -ForegroundColor Green
                break
            }
            catch {
                Write-Host "    Connessione fallita a '$instance': $($_.Exception.Message)" -ForegroundColor Red

                if ($attempt -ge 3) {
                    throw "Istanza SQL '$instance' non raggiungibile. Verificare nome, servizio avviato, e per istanze remote che TCP/IP e SQL Browser siano attivi."
                }

                $instance = Read-Answer -Prompt "    Riprovare con quale istanza?" -Mandatory -ParameterHint "-SqlInstance"
            }
        }
    }

    return $instance
}

# ---------------------------------------------------------------------------
# PREFISSO E NOMI
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Chiede il prefisso da anteporre ai nomi dei database e alla cartella dei task.
.DESCRIPTION
    Il prefisso dice a quale progetto/prodotto appartengono gli oggetti creati:
    su un'istanza che ospita decine di database e' l'unico modo per capirlo a
    colpo d'occhio.
#>
function Resolve-DbPrefix {

    Write-Host ""
    Write-Host "=== Prefisso ===" -ForegroundColor Yellow
    Write-Host "    Identifica il progetto/prodotto proprietario dei database" -ForegroundColor Cyan
    Write-Host "    e della cartella dei task pianificati:" -ForegroundColor Cyan
    Write-Host "      [1] EWP_    prodotto EasyWebParts"
    Write-Host "      [2] FMG_    progetti interni FMGroup"
    Write-Host "      [3] Altro prefisso"
    Write-Host "      [4] Nessun prefisso"
    Write-Host ""

    while ($true) {

        # In assenza di interazione si ripiega su "nessun prefisso", l'unica
        # scelta neutra.
        $answer = Read-Answer -Prompt "    Prefisso (1-4)" -Default "4"

        if ($answer -eq "1") { return "EWP_" }
        if ($answer -eq "2") { return "FMG_" }
        if ($answer -eq "4") { return "" }

        if ($answer -eq "3") {
            return Read-Answer -Prompt "    Prefisso da usare, underscore finale incluso (es. ABC_)" -Default ""
        }

        Write-Host "    Risposta non valida: indicare un valore da 1 a 4." -ForegroundColor Red
    }
}

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

<#
.SYNOPSIS
    Chiede il nome del tenant e lo convalida.
#>
function Resolve-TenantName {

    Write-Host ""
    Write-Host "=== Tenant ===" -ForegroundColor Yellow
    Write-Host "    Codice interno del tenant: e' l'identita' di spedizione del robot." -ForegroundColor Cyan
    Write-Host "    Viene usato in Companies[].Name, come prefisso delle connection string" -ForegroundColor DarkGray
    Write-Host "    (<Tenant>_Main / <Tenant>_Log), come argomento --company del task e nella" -ForegroundColor DarkGray
    Write-Host "    colonna Company delle tabelle. Non e' il nome del database." -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $name = Read-Answer -Prompt "    Nome del tenant (es. FMGROUP)" -Mandatory -ParameterHint "-TenantName"
        if (Test-TenantNameValid -Name $name) { return $name }
    }
}

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# TASK SCHEDULER
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Registra un task nel Task Scheduler a partire dalla sua definizione XML.
.DESCRIPTION
    Si usa l'XML invece dei cmdlet ScheduledTasks perche' serve una ripetizione
    indefinita: nel formato XML basta omettere <Duration> dentro <Repetition>,
    mentre con i cmdlet occorrerebbe passare una durata finita.
    La cartella viene creata se non esiste. RegisterTask con flag 6
    (TASK_CREATE_OR_UPDATE) rende l'operazione idempotente; il logon type 5
    (TASK_LOGON_SERVICE_ACCOUNT) esegue come SYSTEM senza password.
#>
function Register-TaskFromXml {
    param(
        [Parameter(Mandatory = $true)][string] $TaskFolder,
        [Parameter(Mandatory = $true)][string] $TaskName,
        [Parameter(Mandatory = $true)][string] $Xml
    )

    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()

    try {
        $folder = $scheduler.GetFolder($TaskFolder)
    }
    catch {
        # GetFolder solleva un'eccezione se la cartella non esiste: la si crea
        # partendo dalla radice. Si gestisce un solo livello di annidamento,
        # che e' quanto serve.
        $root = $scheduler.GetFolder("\")
        $root.CreateFolder($TaskFolder.TrimStart("\")) | Out-Null
        $folder = $scheduler.GetFolder($TaskFolder)
        Write-Host "    Cartella '$TaskFolder' creata nel Task Scheduler." -ForegroundColor Cyan
    }

    $folder.RegisterTask($TaskName, $Xml, 6, $null, $null, 5) | Out-Null
}

<#
.SYNOPSIS
    Rimuove un task, senza errore se non esiste.
#>
function Unregister-TaskIfPresent {
    param(
        [Parameter(Mandatory = $true)][string] $TaskFolder,
        [Parameter(Mandatory = $true)][string] $TaskName
    )

    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()

    try {
        $folder = $scheduler.GetFolder($TaskFolder)
        $folder.DeleteTask($TaskName, 0)
        return $true
    }
    catch {
        return $false
    }
}
