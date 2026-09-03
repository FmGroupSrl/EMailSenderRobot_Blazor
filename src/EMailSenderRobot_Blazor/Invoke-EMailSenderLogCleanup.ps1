<#
.SYNOPSIS
    Cancella i log vecchi di EMailSenderRobot: file su disco e righe su
    database, per tutti i tenant, da un unico punto.

.DESCRIPTION
    Un solo script e un solo task pianificato ripuliscono l'intera
    installazione. I tenant non si elencano a mano: vengono letti da
    appsettings.json, quindi un tenant aggiunto domani viene ripulito senza
    toccare nulla.

    Per ogni tenant configurato:
      - cancella da LogDirectory i file EMailSender_*.log piu' vecchi della
        soglia;
      - cancella dalla tabella "log" del database di quel tenant le righe piu'
        vecchie della soglia.

    Destinazioni duplicate: se piu' tenant condividono la stessa cartella o lo
    stesso database di log (layout a database unico del robot) la pulizia
    viene eseguita una volta sola, non una per tenant.

    NOTA — perche' serve, visto che il ConsoleJob gia' pulisce.
    FileLogger.Cleanup gira al termine di ogni esecuzione del job, ma solo se
    l'esecuzione arriva in fondo: un tenant con le spedizioni bloccate, o con
    una connection string errata, esce prima e non pulisce mai. Lo stesso vale
    per un tenant dismesso, che smette di girare lasciando i suoi file sul
    disco per sempre. E soprattutto: la tabella "log" sul database non e'
    ripulita da nessuno.

.PARAMETER RetentionDays
    Giorni di conservazione. Default 60, sia per i file sia per il database.
    Ignora deliberatamente il LogRetentionDays per tenant: questa e' la
    pulizia di sicurezza dell'installazione, e vale la stessa soglia per tutti.

.PARAMETER PurgeSentMailsOlderThanDays
    Se maggiore di zero, cancella anche dalla coda le mail gia' spedite piu'
    vecchie di N giorni. Disattivato per default: le mail spedite sono
    storico, non log, e vanno buttate solo per scelta esplicita.

.PARAMETER RegisterTask
    Invece di eseguire la pulizia, registra il task pianificato giornaliero
    che la esegue.

.EXAMPLE
    .\Invoke-EMailSenderLogCleanup.ps1

.EXAMPLE
    .\Invoke-EMailSenderLogCleanup.ps1 -RegisterTask -TaskFolder "\FMG_EmailRobot"

.EXAMPLE
    .\Invoke-EMailSenderLogCleanup.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Cartella di installazione del robot.
    [string] $InstallRoot = "C:\EMailSender",

    # Soglia di conservazione, in giorni, per file e righe di log.
    [int] $RetentionDays = 60,

    # Cancellazione opzionale delle mail gia' spedite (0 = disattivata).
    [int] $PurgeSentMailsOlderThanDays = 0,

    # Registra il task giornaliero invece di eseguire la pulizia.
    [switch] $RegisterTask,

    # Cartella del Task Scheduler in cui creare il task.
    [string] $TaskFolder = "\EMailSender",

    # Ora di esecuzione del task giornaliero (formato HH:mm).
    [string] $RunAt = "03:15",

    # Rimuove il task pianificato.
    [switch] $Remove
)

$ErrorActionPreference = "Stop"

# Funzioni condivise: privilegi, registrazione task, helper JSON.
. "$PSScriptRoot\EMailSenderCommon.ps1"

Assert-Administrator
Add-Type -AssemblyName System.Data

$taskName = "EMailSenderLogCleanup"

# ---------------------------------------------------------------------------
# RAMO 1 - Rimozione del task
# ---------------------------------------------------------------------------
if ($Remove) {
    Write-Host ""
    Write-Host "=== Rimozione task '$taskName' ===" -ForegroundColor Yellow

    if (Unregister-TaskIfPresent -TaskFolder $TaskFolder -TaskName $taskName) {
        Write-Host "    Task rimosso da '$TaskFolder'." -ForegroundColor Green
    }
    else {
        Write-Host "    Task non trovato in '$TaskFolder': niente da rimuovere." -ForegroundColor Cyan
    }

    Write-Host ""
    return
}

# ---------------------------------------------------------------------------
# RAMO 2 - Registrazione del task giornaliero
# ---------------------------------------------------------------------------
if ($RegisterTask) {

    Write-Host ""
    Write-Host "=== Task di pulizia log ===" -ForegroundColor Yellow

    # Il task rilancia questo stesso script, che sul server vive nella
    # cartella di installazione.
    $scriptOnServer = Join-Path $InstallRoot "Invoke-EMailSenderLogCleanup.ps1"
    if (-not (Test-Path $scriptOnServer)) {
        Write-Warning "Lo script non e' ancora in '$InstallRoot': il task verra' creato comunque, ma fallira' finche' il file non viene copiato (lo fa Install-EMailSender.ps1 o Deploy.ps1)."
    }

    # -NoProfile e -ExecutionPolicy Bypass rendono l'esecuzione indipendente
    # dai criteri e dal profilo dell'account di servizio.
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptOnServer`" -InstallRoot `"$InstallRoot`" -RetentionDays $RetentionDays"
    if ($PurgeSentMailsOlderThanDays -gt 0) {
        $arguments += " -PurgeSentMailsOlderThanDays $PurgeSentMailsOlderThanDays"
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Pulizia log EMailSenderRobot: file su disco e tabella log, oltre $RetentionDays giorni, per tutti i tenant.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2000-01-01T$($RunAt):00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$InstallRoot</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    Register-TaskFromXml -TaskFolder $TaskFolder -TaskName $taskName -Xml $xml

    Write-Host "    Task creato/aggiornato:" -ForegroundColor Green
    Write-Host "      Cartella      : $TaskFolder"
    Write-Host "      Nome          : $taskName"
    Write-Host "      Esecuzione    : ogni giorno alle $RunAt, come SYSTEM"
    Write-Host "      Conservazione : $RetentionDays giorni (file e database)"
    Write-Host ""
    return
}

# ---------------------------------------------------------------------------
# RAMO 3 - Esecuzione della pulizia
# ---------------------------------------------------------------------------

$cutoff = (Get-Date).AddDays(-$RetentionDays)

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Pulizia log EMailSenderRobot" -ForegroundColor Cyan
Write-Host " Soglia: $RetentionDays giorni (tutto cio' che precede $($cutoff.ToString('dd/MM/yyyy HH:mm')))" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# --- Lettura della configurazione ------------------------------------------
# Si legge la copia del ConsoleJob: e' quella che descrive cio' che gira
# davvero. Se manca si ripiega su quella della Web UI.
$settingsPath = Join-Path $InstallRoot "ConsoleJob\appsettings.json"
if (-not (Test-Path $settingsPath)) {
    $settingsPath = Join-Path $InstallRoot "Web\appsettings.json"
}
if (-not (Test-Path $settingsPath)) {
    throw "Nessun appsettings.json trovato sotto '$InstallRoot': impossibile sapere quali tenant ripulire."
}

$cfg = Get-Content $settingsPath -Raw | ConvertFrom-Json
$tenants = @()
if ($cfg.Companies) { $tenants = @($cfg.Companies) }

if ($tenants.Count -eq 0) {
    Write-Host "Nessun tenant configurato in ${settingsPath}: niente da fare." -ForegroundColor Yellow
    return
}

Write-Host "Configurazione letta da: $settingsPath" -ForegroundColor DarkGray
Write-Host "Tenant configurati: $(($tenants | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor DarkGray

# Elenchi delle destinazioni gia' trattate: piu' tenant possono condividere la
# stessa cartella o lo stesso database, e la pulizia va fatta una volta sola.
$doneFolders   = @()
$doneDatabases = @()

$totalFiles = 0
$totalRows  = 0
$totalMails = 0

foreach ($t in $tenants) {

    Write-Host ""
    Write-Host "--- Tenant '$($t.Name)' ---" -ForegroundColor White

    # --- FILE SU DISCO -----------------------------------------------------
    $logDir = $t.LogDirectory
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        # Ripiego del ConsoleJob quando LogDirectory non e' valorizzato.
        $logDir = Join-Path $InstallRoot "ConsoleJob\Logs"
    }

    if ($doneFolders -contains $logDir.ToLower()) {
        Write-Host "    File   : cartella gia' ripulita per un altro tenant." -ForegroundColor DarkGray
    }
    elseif (-not (Test-Path $logDir)) {
        Write-Host "    File   : cartella inesistente ($logDir)." -ForegroundColor DarkGray
    }
    else {
        $doneFolders += $logDir.ToLower()

        $old = @(Get-ChildItem -Path $logDir -Filter "EMailSender_*.log" -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -lt $cutoff })

        if ($old.Count -eq 0) {
            Write-Host "    File   : nessun file da cancellare in $logDir." -ForegroundColor Green
        }
        else {
            $bytes = ($old | Measure-Object -Property Length -Sum).Sum
            foreach ($f in $old) {
                if ($PSCmdlet.ShouldProcess($f.FullName, "Elimina file di log")) {
                    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            $totalFiles += $old.Count
            Write-Host ("    File   : cancellati {0} file ({1:N1} MB) in {2}." -f $old.Count, ($bytes / 1MB), $logDir) -ForegroundColor Green
        }
    }

    # --- RIGHE SUL DATABASE ------------------------------------------------
    $csLog = $cfg.ConnectionStrings."$($t.Name)_Log"
    if ([string]::IsNullOrWhiteSpace($csLog)) {
        Write-Host "    Database: connection string '$($t.Name)_Log' assente, saltato." -ForegroundColor Yellow
    }
    else {
        # La chiave di deduplica e' la connection string: due tenant che
        # puntano allo stesso database di log vanno ripuliti una volta sola.
        $dbKey = $csLog.ToLower()

        if ($doneDatabases -contains $dbKey) {
            Write-Host "    Database: gia' ripulito per un altro tenant (stesso database)." -ForegroundColor DarkGray
        }
        else {
            $doneDatabases += $dbKey

            try {
                $cn = New-Object System.Data.SqlClient.SqlConnection($csLog)
                $cn.Open()
                try {
                    $dbName = $null
                    $cmdName = $cn.CreateCommand()
                    $cmdName.CommandText = "SELECT DB_NAME()"
                    $dbName = [string] $cmdName.ExecuteScalar()

                    if ($PSCmdlet.ShouldProcess($dbName, "Elimina righe di log oltre $RetentionDays giorni")) {

                        # Si cancella a blocchi: una DELETE unica su una tabella
                        # molto grande terrebbe un lock lungo e farebbe crescere
                        # il log delle transazioni.
                        $deleted = 0
                        while ($true) {
                            $cmd = $cn.CreateCommand()
                            $cmd.CommandTimeout = 300
                            $cmd.CommandText = "DELETE TOP (5000) FROM log WHERE [TimeStamp] IS NOT NULL AND [TimeStamp] < @cutoff"
                            [void] $cmd.Parameters.Add("@cutoff", [System.Data.SqlDbType]::DateTime)
                            $cmd.Parameters["@cutoff"].Value = $cutoff

                            $n = $cmd.ExecuteNonQuery()
                            $deleted += $n
                            if ($n -lt 5000) { break }
                        }

                        $totalRows += $deleted
                        Write-Host "    Database: cancellate $deleted righe dalla tabella log di [$dbName]." -ForegroundColor Green
                    }
                }
                finally {
                    $cn.Close()
                }
            }
            catch {
                Write-Host "    Database: pulizia non riuscita - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # --- MAIL GIA' SPEDITE (opzionale) -------------------------------------
    if ($PurgeSentMailsOlderThanDays -gt 0) {

        $csMain = $cfg.ConnectionStrings."$($t.Name)_Main"
        if ([string]::IsNullOrWhiteSpace($csMain)) {
            Write-Host "    Coda    : connection string '$($t.Name)_Main' assente, saltata." -ForegroundColor Yellow
        }
        else {
            $mailCutoff = (Get-Date).AddDays(-$PurgeSentMailsOlderThanDays)
            try {
                $cn = New-Object System.Data.SqlClient.SqlConnection($csMain)
                $cn.Open()
                try {
                    if ($PSCmdlet.ShouldProcess($t.Name, "Elimina mail spedite oltre $PurgeSentMailsOlderThanDays giorni")) {

                        # Si cancellano SOLO le mail effettivamente spedite e
                        # solo quelle di questo tenant: gli errori e le mail in
                        # coda restano, perche' sono ancora lavorabili.
                        $deleted = 0
                        while ($true) {
                            $cmd = $cn.CreateCommand()
                            $cmd.CommandTimeout = 300
                            $cmd.CommandText = "DELETE TOP (5000) FROM ConfigEmailJobSchedule WHERE Company = @company AND SentTimeStamp IS NOT NULL AND SentTimeStamp < @cutoff"
                            [void] $cmd.Parameters.Add("@company", [System.Data.SqlDbType]::NVarChar)
                            $cmd.Parameters["@company"].Value = $t.Name
                            [void] $cmd.Parameters.Add("@cutoff", [System.Data.SqlDbType]::DateTime)
                            $cmd.Parameters["@cutoff"].Value = $mailCutoff

                            $n = $cmd.ExecuteNonQuery()
                            $deleted += $n
                            if ($n -lt 5000) { break }
                        }

                        $totalMails += $deleted
                        Write-Host "    Coda    : cancellate $deleted mail spedite oltre $PurgeSentMailsOlderThanDays giorni." -ForegroundColor Green
                    }
                }
                finally {
                    $cn.Close()
                }
            }
            catch {
                Write-Host "    Coda    : pulizia non riuscita - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Riepilogo, anche su file: il task gira di notte e nessuno guarda la console.
# ---------------------------------------------------------------------------
$summary = "Pulizia completata: $totalFiles file, $totalRows righe di log" + $(if ($PurgeSentMailsOlderThanDays -gt 0) { ", $totalMails mail spedite" } else { "" }) + " (soglia $RetentionDays giorni)."

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host " $summary" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""

try {
    $maintDir = Join-Path $InstallRoot "Logs"
    if (-not (Test-Path $maintDir)) { New-Item -ItemType Directory -Path $maintDir -Force | Out-Null }

    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $summary
    Add-Content -Path (Join-Path $maintDir "Cleanup_$(Get-Date -Format 'yyyyMM').log") -Value $line

    # Anche il proprio log si autopulisce, altrimenti sarebbe l'unico file a
    # crescere indefinitamente.
    Get-ChildItem -Path $maintDir -Filter "Cleanup_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
catch {
    # Il riepilogo su file non e' essenziale: non deve far fallire la pulizia.
}
