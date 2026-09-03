<#
.SYNOPSIS
    Diagnostica di un'installazione di EMailSenderRobot.

.DESCRIPTION
    Verifica in un colpo solo tutto cio' che, mancando, produce il sintomo
    "le mail non partono" o "la Web UI non risponde", e che finora andava
    controllato a mano in sei posti diversi.

    Controlli eseguiti:
      - runtime ASP.NET Core 8
      - file eseguibili nelle due cartelle
      - i DUE appsettings.json, e la loro COERENZA reciproca
      - binding di Kestrel e porta effettivamente in ascolto
      - servizio Windows
      - task nel Task Scheduler ed esito dell'ultima esecuzione
      - connessione SQL, presenza delle 5 tabelle, riga SMTP del tenant
      - flag di blocco spedizione
      - cartella dei file di log e scrivibilita'

    Non modifica nulla: e' di sola lettura.

.EXAMPLE
    .\Test-EMailSenderInstall.ps1

.EXAMPLE
    .\Test-EMailSenderInstall.ps1 -TenantName "FMG"
#>
[CmdletBinding()]
param(
    # Cartella di installazione.
    [string] $InstallRoot = "C:\EMailSender",

    # Nome del servizio Windows.
    [string] $ServiceName = "EMailSenderWeb",

    # Limita i controlli SQL a un solo tenant. Se omesso, tutti quelli
    # presenti in appsettings.json.
    [string] $TenantName = "",

    # Cartelle del Task Scheduler in cui cercare i task.
    [string[]] $TaskFolders = @("\EMailSender", "\EasyWebParts")
)

$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Data

# Contatori di esito, usati nel riepilogo finale.
$script:okCount   = 0
$script:warnCount = 0
$script:errCount  = 0

<#
.SYNOPSIS
    Stampa una riga di esito con colore e aggiorna i contatori.
#>
function Write-Check {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("OK", "WARN", "ERR", "INFO")][string] $Level,
        [Parameter(Mandatory = $true)][string] $Message
    )

    switch ($Level) {
        "OK"   { Write-Host "  [OK]   $Message" -ForegroundColor Green;      $script:okCount++ }
        "WARN" { Write-Host "  [WARN] $Message" -ForegroundColor Yellow;     $script:warnCount++ }
        "ERR"  { Write-Host "  [ERR]  $Message" -ForegroundColor Red;        $script:errCount++ }
        "INFO" { Write-Host "         $Message" -ForegroundColor DarkGray }
    }
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Diagnostica EMailSenderRobot - $InstallRoot" -ForegroundColor Cyan
Write-Host " $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Runtime
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "1. Runtime .NET" -ForegroundColor Yellow
try {
    $runtimes = & dotnet --list-runtimes 2>$null
    $asp8 = @($runtimes | Where-Object { $_ -match "^Microsoft\.AspNetCore\.App 8\." })
    if ($asp8.Count -gt 0) {
        Write-Check OK "ASP.NET Core 8 presente ($($asp8.Count) versione/i)"
    }
    else {
        Write-Check ERR "ASP.NET Core 8 assente: la Web UI non puo' partire"
    }
}
catch {
    Write-Check ERR "comando 'dotnet' non disponibile"
}

# ---------------------------------------------------------------------------
# 2. File dell'applicazione
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "2. File dell'applicazione" -ForegroundColor Yellow

$webExe = Join-Path $InstallRoot "Web\EMailSender.Web.exe"
$jobExe = Join-Path $InstallRoot "ConsoleJob\EMailSender.ConsoleJob.exe"

foreach ($pair in @(@{ P = $webExe; L = "EMailSender.Web.exe" }, @{ P = $jobExe; L = "EMailSender.ConsoleJob.exe" })) {
    if (Test-Path $pair.P) {
        $ver = (Get-Item $pair.P).VersionInfo.FileVersion
        Write-Check OK "$($pair.L) presente (versione $ver)"
    }
    else {
        Write-Check ERR "$($pair.L) NON trovato in $($pair.P)"
    }
}

# ---------------------------------------------------------------------------
# 3. File di configurazione e loro coerenza
# La configurazione vive in due copie indipendenti: la Web UI scrive solo
# sulla propria, quindi la divergenza tra le due e' il guasto piu' frequente.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "3. Configurazione" -ForegroundColor Yellow

$webSettingsPath = Join-Path $InstallRoot "Web\appsettings.json"
$jobSettingsPath = Join-Path $InstallRoot "ConsoleJob\appsettings.json"

$webCfg = $null
$jobCfg = $null

foreach ($pair in @(@{ P = $webSettingsPath; L = "Web" }, @{ P = $jobSettingsPath; L = "ConsoleJob" })) {
    if (-not (Test-Path $pair.P)) {
        Write-Check ERR "$($pair.L): appsettings.json assente ($($pair.P))"
        continue
    }
    try {
        $parsed = Get-Content $pair.P -Raw | ConvertFrom-Json
        Write-Check OK "$($pair.L): appsettings.json presente e valido"
        if ($pair.L -eq "Web") { $webCfg = $parsed } else { $jobCfg = $parsed }
    }
    catch {
        Write-Check ERR "$($pair.L): appsettings.json non e' JSON valido - $($_.Exception.Message)"
    }
}

# Confronto dei tenant configurati nelle due copie.
if ($null -ne $webCfg -and $null -ne $jobCfg) {
    $webTenants = @()
    $jobTenants = @()
    if ($webCfg.Companies) { $webTenants = @($webCfg.Companies | ForEach-Object { $_.Name }) }
    if ($jobCfg.Companies) { $jobTenants = @($jobCfg.Companies | ForEach-Object { $_.Name }) }

    $onlyWeb = @($webTenants | Where-Object { $jobTenants -notcontains $_ })
    $onlyJob = @($jobTenants | Where-Object { $webTenants -notcontains $_ })

    if ($onlyWeb.Count -eq 0 -and $onlyJob.Count -eq 0) {
        Write-Check OK "tenant allineati tra Web e ConsoleJob: $($webTenants -join ', ')"
    }
    else {
        if ($onlyWeb.Count -gt 0) {
            Write-Check ERR "tenant presenti solo nella Web UI (il job non li spedira'): $($onlyWeb -join ', ')"
        }
        if ($onlyJob.Count -gt 0) {
            Write-Check WARN "tenant presenti solo nel ConsoleJob (invisibili nella UI): $($onlyJob -join ', ')"
        }
    }

    # Confronto delle connection string: divergenze qui fanno leggere alla UI
    # un database diverso da quello su cui spedisce il job.
    foreach ($t in @($webTenants | Where-Object { $jobTenants -contains $_ })) {
        foreach ($suffix in @("Main", "Log")) {
            $key = "$($t)_$suffix"
            $a = $webCfg.ConnectionStrings.$key
            $b = $jobCfg.ConnectionStrings.$key
            if ($a -ne $b) {
                Write-Check ERR "connection string '$key' diversa tra Web e ConsoleJob"
            }
        }
    }

    # Chiavi la cui assenza produce il banner giallo nella Web UI.
    if (-not $webCfg.DefaultTenants -or @($webCfg.DefaultTenants).Count -eq 0) {
        Write-Check WARN "Web: 'DefaultTenants' assente o vuoto (banner di warning nella UI)"
    }

    # Sezione realmente letta dal ConsoleJob (Program.cs:27-30).
    if (-not $jobCfg.EmailJob) {
        Write-Check WARN "ConsoleJob: sezione 'EmailJob' assente: MaxRetryCount usa il default 2 e Companies[].MaxRetryCount viene ignorato"
    }
}

# ---------------------------------------------------------------------------
# 4. Binding di rete
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "4. Binding della Web UI" -ForegroundColor Yellow

if ($null -ne $webCfg) {
    if ($webCfg.Urls) {
        Write-Check OK "chiave 'Urls' = $($webCfg.Urls)"
    }
    else {
        Write-Check WARN "chiave 'Urls' assente: Kestrel ascolta solo su loopback (127.0.0.1 e ::1), nessuna regola firewall puo' aprirla"
    }
}

$proc = Get-Process -Name "EMailSender.Web" -ErrorAction SilentlyContinue
if ($null -ne $proc) {
    $listen = Get-NetTCPConnection -State Listen -OwningProcess $proc.Id -ErrorAction SilentlyContinue
    if ($null -ne $listen) {
        foreach ($l in $listen) {
            Write-Check INFO "in ascolto su $($l.LocalAddress):$($l.LocalPort)"
        }
        $external = @($listen | Where-Object { $_.LocalAddress -notin @("127.0.0.1", "::1") })
        if ($external.Count -gt 0) {
            Write-Check OK "raggiungibile da rete"
        }
        else {
            Write-Check INFO "raggiungibile solo da questa macchina (http://localhost:$($listen[0].LocalPort)/)"
        }
    }
}
else {
    Write-Check INFO "processo EMailSender.Web non in esecuzione: binding non verificabile"
}

# ---------------------------------------------------------------------------
# 5. Servizio Windows
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "5. Servizio Windows" -ForegroundColor Yellow

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    Write-Check ERR "servizio '$ServiceName' non registrato (usare Register-EMailSenderService.ps1)"
}
else {
    if ($svc.Status -eq "Running") {
        Write-Check OK "servizio '$ServiceName' in esecuzione"
    }
    else {
        Write-Check ERR "servizio '$ServiceName' presente ma in stato $($svc.Status)"
    }

    # Avvio automatico e account: due dimenticanze classiche dopo un riavvio.
    $wmi = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if ($null -ne $wmi) {
        if ($wmi.StartMode -ne "Auto") {
            Write-Check WARN "avvio impostato su '$($wmi.StartMode)': dopo un riavvio del server la UI resta giu'"
        }
        Write-Check INFO "account: $($wmi.StartName)"
    }
}

# ---------------------------------------------------------------------------
# 6. Task Scheduler
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "6. Task Scheduler" -ForegroundColor Yellow

# Si cercano i task per NOME in tutto il Task Scheduler, non per cartella: la
# cartella dipende dal prefisso scelto all'installazione (es. \FMG_EmailRobot)
# e cercarla per nome fisso darebbe falsi allarmi.
$allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
              Where-Object { $_.TaskName -like "EMailSender*" })

$found   = @($allTasks | Where-Object { $_.TaskName -like "EMailSenderJob*" })
$cleanup = @($allTasks | Where-Object { $_.TaskName -like "*LogCleanup*" })

# Task di pulizia: la sua assenza non blocca le spedizioni, ma da quando la
# pulizia non avviene piu' dentro il ConsoleJob e' l'unico che cancella i log
# vecchi, su disco e sul database.
if ($cleanup.Count -eq 0) {
    Write-Check WARN "task di pulizia log assente: i log non vengono piu' cancellati da nessuno (crearlo con Invoke-EMailSenderLogCleanup.ps1 -RegisterTask)"
}
else {
    foreach ($c in $cleanup) {
        Write-Check OK "$($c.TaskPath)$($c.TaskName) [$($c.State)]"
    }
}

if ($found.Count -eq 0) {
    Write-Check ERR "nessun task 'EMailSenderJob*' trovato nel Task Scheduler"
}
else {
    foreach ($t in $found) {
        $info = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction SilentlyContinue
        $action = @($t.Actions)[0]
        $label = "$($t.TaskPath)$($t.TaskName) [$($t.State)]"

        if ($t.State -eq "Disabled") {
            Write-Check ERR "$label - task DISABILITATO"
        }
        else {
            Write-Check OK $label
        }
        Write-Check INFO "comando: $($action.Execute) $($action.Arguments)"

        if ($null -ne $info) {
            Write-Check INFO "ultima esecuzione: $($info.LastRunTime) - esito: 0x$('{0:X}' -f $info.LastTaskResult)"
            # 0 = riuscito; 0x41303 = mai eseguito.
            if ($info.LastTaskResult -ne 0 -and $info.LastTaskResult -ne 267011) {
                Write-Check WARN "l'ultima esecuzione non e' terminata con successo"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Database, tabelle, SMTP, blocco spedizione
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "7. Database" -ForegroundColor Yellow

<#
.SYNOPSIS
    Esegue una query scalare restituendo $null in caso di errore di connessione.
#>
function Get-SqlScalarSafe {
    param(
        [Parameter(Mandatory = $true)][string] $ConnectionString,
        [Parameter(Mandatory = $true)][string] $Sql
    )

    $cn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 30
        return $cmd.ExecuteScalar()
    }
    catch {
        throw
    }
    finally {
        $cn.Close()
    }
}

if ($null -eq $jobCfg) {
    Write-Check WARN "configurazione del ConsoleJob non leggibile: controlli SQL saltati"
}
else {
    $tenants = @()
    if ($jobCfg.Companies) { $tenants = @($jobCfg.Companies) }
    if (-not [string]::IsNullOrWhiteSpace($TenantName)) {
        $tenants = @($tenants | Where-Object { $_.Name -eq $TenantName })
        if ($tenants.Count -eq 0) {
            Write-Check ERR "tenant '$TenantName' non presente in $jobSettingsPath"
        }
    }

    if ($tenants.Count -eq 0 -and [string]::IsNullOrWhiteSpace($TenantName)) {
        Write-Check ERR "nessun tenant configurato: il robot non ha nulla da spedire"
    }

    foreach ($t in $tenants) {

        Write-Host ""
        Write-Host "   Tenant '$($t.Name)' ($($t.DisplayName))" -ForegroundColor White

        $csMain = $jobCfg.ConnectionStrings."$($t.Name)_Main"
        $csLog  = $jobCfg.ConnectionStrings."$($t.Name)_Log"

        if ([string]::IsNullOrWhiteSpace($csMain)) {
            Write-Check ERR "connection string '$($t.Name)_Main' assente"
            continue
        }
        if ([string]::IsNullOrWhiteSpace($csLog)) {
            Write-Check ERR "connection string '$($t.Name)_Log' assente"
        }

        # --- Connessione e tabelle sul DB principale ---
        try {
            $dbName = Get-SqlScalarSafe -ConnectionString $csMain -Sql "SELECT DB_NAME()"
            Write-Check OK "connessione al DB principale riuscita ($dbName)"

            foreach ($tbl in @("ConfigEmailJobSchedule", "ConfigEmailServer", "ConfigEmailContent", "ConfigEmailAddress")) {
                $exists = Get-SqlScalarSafe -ConnectionString $csMain -Sql "SELECT OBJECT_ID(N'$tbl', N'U')"
                if ($null -eq $exists -or $exists -is [DBNull]) {
                    Write-Check ERR "tabella '$tbl' assente su [$dbName]"
                }
                else {
                    Write-Check OK "tabella '$tbl' presente"
                }
            }

            # Riga SMTP: senza di questa ogni mail va in errore.
            $tenantEsc = $t.Name.Replace("'", "''")
            $smtpTable = "ConfigEmailServer"
            if ($t.SqlConfigTableServer) { $smtpTable = $t.SqlConfigTableServer }

            $smtpRow = Get-SqlScalarSafe -ConnectionString $csMain `
                -Sql "SELECT Smtp_Server FROM $smtpTable WHERE company = N'$tenantEsc'"

            if ($null -eq $smtpRow -or $smtpRow -is [DBNull]) {
                Write-Check ERR "nessuna riga in $smtpTable per company '$($t.Name)': ogni mail finira' in errore"
            }
            elseif ([string]::IsNullOrWhiteSpace([string] $smtpRow)) {
                Write-Check WARN "riga SMTP presente ma Smtp_Server vuoto: completare dalla pagina Config SMTP"
            }
            else {
                Write-Check OK "SMTP configurato: $smtpRow"
            }

            # Flag di blocco: unico meccanismo di blocco letto dal job.
            $blocked = Get-SqlScalarSafe -ConnectionString $csMain `
                -Sql "SELECT IsDeliveryBlocked FROM $smtpTable WHERE company = N'$tenantEsc'"
            if ("$blocked".Trim() -eq "S") {
                Write-Check WARN "IsDeliveryBlocked = 'S': spedizioni BLOCCATE per questo tenant"
            }

            # Fotografia della coda.
            $pending = Get-SqlScalarSafe -ConnectionString $csMain `
                -Sql "SELECT COUNT(*) FROM ConfigEmailJobSchedule WHERE SentTimeStamp IS NULL AND IsError <> 'A'"
            $errors = Get-SqlScalarSafe -ConnectionString $csMain `
                -Sql "SELECT COUNT(*) FROM ConfigEmailJobSchedule WHERE IsError = 'S'"
            Write-Check INFO "coda: $pending da spedire, $errors in errore"
        }
        catch {
            Write-Check ERR "DB principale non raggiungibile: $($_.Exception.Message)"
        }

        # --- Tabella di log ---
        if (-not [string]::IsNullOrWhiteSpace($csLog)) {
            try {
                $logDb = Get-SqlScalarSafe -ConnectionString $csLog -Sql "SELECT DB_NAME()"
                $exists = Get-SqlScalarSafe -ConnectionString $csLog -Sql "SELECT OBJECT_ID(N'log', N'U')"
                if ($null -eq $exists -or $exists -is [DBNull]) {
                    Write-Check ERR "tabella 'log' assente su [$logDb]"
                }
                else {
                    Write-Check OK "tabella 'log' presente su [$logDb]"
                }
            }
            catch {
                Write-Check ERR "DB di log non raggiungibile: $($_.Exception.Message)"
            }
        }

        # --- Cartella dei file di log ---
        if ([string]::IsNullOrWhiteSpace($t.LogDirectory)) {
            Write-Check WARN "'LogDirectory' non valorizzato: il job usa <cartella exe>\Logs"
        }
        elseif (-not (Test-Path $t.LogDirectory)) {
            Write-Check WARN "cartella di log inesistente: $($t.LogDirectory)"
        }
        else {
            # Prova di scrittura reale: FileLogger ingoia gli errori in
            # silenzio, quindi un problema di ACL non lascia traccia.
            $probe = Join-Path $t.LogDirectory ".write_probe_$([guid]::NewGuid().ToString('N')).tmp"
            try {
                Set-Content -Path $probe -Value "probe" -ErrorAction Stop
                Remove-Item $probe -Force
                Write-Check OK "cartella di log scrivibile: $($t.LogDirectory)"
            }
            catch {
                Write-Check ERR "cartella di log NON scrivibile: $($t.LogDirectory)"
            }

            # Ultimo file di log prodotto: dice se il job sta girando davvero.
            $last = Get-ChildItem -Path $t.LogDirectory -Filter "EMailSender_*.log" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -ne $last) {
                Write-Check INFO "ultimo log: $($last.Name) ($($last.LastWriteTime))"
            }
            else {
                Write-Check WARN "nessun file EMailSender_*.log presente: il job non ha mai scritto"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Riepilogo
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Esito: $($script:okCount) OK, $($script:warnCount) warning, $($script:errCount) errori" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

if ($script:errCount -gt 0) { exit 1 }
