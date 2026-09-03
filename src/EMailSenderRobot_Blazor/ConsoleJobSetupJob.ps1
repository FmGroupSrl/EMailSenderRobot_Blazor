# ============================================================================
#  ConsoleJobSetupJob.ps1
#  Crea (o rimuove) il task di Task Scheduler che esegue EMailSender.ConsoleJob
#  per un singolo tenant.
#
#  ORIGINE: questo script esisteva solo sul server di produzione in
#  C:\EMailSender\ e non era versionato. E' stato recuperato dalla macchina
#  DULEVO02-WEB e reso parametrico (cartella di installazione, cartella del
#  Task Scheduler, batch, intervallo, rimozione).
#
#  PERCHE' XML E NON New-ScheduledTaskTrigger: serve una ripetizione
#  "indefinita". Nel formato XML basta omettere <Duration> dentro
#  <Repetition>; con i cmdlet ScheduledTasks occorrerebbe passare una
#  RepetitionDuration finita (o [TimeSpan]::MaxValue, che su alcune build
#  fallisce). L'XML e' quindi la strada piu' deterministica.
#
#  USO:
#    .\ConsoleJobSetupJob.ps1 -TenantId "FMGroup"
#    .\ConsoleJobSetupJob.ps1 -TenantId "FMGroup" -Remove
# ============================================================================
[CmdletBinding()]
param(
    # Nome interno del tenant: deve coincidere con Companies[].Name
    # dell'appsettings.json, perche' viene passato al ConsoleJob come --company.
    [Parameter(Mandatory = $true)]
    [string] $TenantId,

    # Cartella di installazione del robot.
    [string] $InstallRoot = "C:\EMailSender",

    # Cartella dentro il Task Scheduler. Sui server EasyWebParts la
    # convenzione storica e' "\EasyWebParts"; su un server dedicato al solo
    # robot conviene "\EMailSender".
    [string] $TaskFolder = "\EasyWebParts",

    # Numero di mail elaborate per ogni esecuzione (argomento --batch).
    [int] $BatchSize = 10,

    # Intervallo di ripetizione in minuti.
    [int] $IntervalMinutes = 1,

    # Tempo massimo di esecuzione di una singola istanza.
    [int] $ExecutionTimeLimitMinutes = 5,

    # Rimuove il task invece di crearlo.
    [switch] $Remove
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Privilegi: la registrazione di un task che gira come SYSTEM richiede
# un token elevato.
# ---------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Questo script richiede privilegi di amministratore."
}

# ---------------------------------------------------------------------------
# Valori derivati
# ---------------------------------------------------------------------------
$taskName   = "EMailSenderJob for $TenantId"
$exePath    = Join-Path $InstallRoot "ConsoleJob\EMailSender.ConsoleJob.exe"
$workingDir = Join-Path $InstallRoot "ConsoleJob"
$arguments  = "--company $TenantId --batch $BatchSize"

# ---------------------------------------------------------------------------
# Connessione al servizio Task Scheduler via COM.
# ---------------------------------------------------------------------------
$scheduler = New-Object -ComObject Schedule.Service
$scheduler.Connect()

# ---------------------------------------------------------------------------
# RAMO 1 - Rimozione
# ---------------------------------------------------------------------------
if ($Remove) {

    Write-Host ""
    Write-Host "=== Rimozione task '$taskName' ===" -ForegroundColor Yellow

    try {
        $folder = $scheduler.GetFolder($TaskFolder)
        $folder.DeleteTask($taskName, 0)
        Write-Host "    Task rimosso da '$TaskFolder'." -ForegroundColor Green
    }
    catch {
        Write-Host "    Task non trovato in '$TaskFolder': niente da rimuovere." -ForegroundColor Cyan
    }

    Write-Host ""
    return
}

# ---------------------------------------------------------------------------
# RAMO 2 - Creazione / aggiornamento
# ---------------------------------------------------------------------------

# L'eseguibile deve esistere, altrimenti il task viene creato ma ogni
# esecuzione termina con esito 0x80070002 (file non trovato), errore che
# nella cronologia del Task Scheduler e' poco parlante.
if (-not (Test-Path $exePath)) {
    throw "Eseguibile non trovato: $exePath. Eseguire prima Install-EMailSender.ps1."
}

# Verifica che il tenant esista davvero nell'appsettings.json del ConsoleJob:
# se manca, il job parte, non trova la connection string e si limita a
# scrivere un errore nel file di log ad ogni minuto.
$jobSettings = Join-Path $workingDir "appsettings.json"
if (Test-Path $jobSettings) {
    $cfg = Get-Content $jobSettings -Raw | ConvertFrom-Json
    $known = @()
    if ($cfg.Companies) { $known = @($cfg.Companies | ForEach-Object { $_.Name }) }
    if ($known -notcontains $TenantId) {
        Write-Warning "Il tenant '$TenantId' non e' presente in $jobSettings (tenant configurati: $($known -join ', ')). Il task verra' creato comunque, ma il job non spedira' nulla finche' la configurazione non viene completata con New-EMailSenderTenant.ps1."
    }
}
else {
    Write-Warning "File di configurazione non trovato: $jobSettings. Il ConsoleJob lo carica con optional:false e terminerebbe con un'eccezione."
}

# --- Crea la cartella nel Task Scheduler se non esiste -------------------
try {
    $folder = $scheduler.GetFolder($TaskFolder)
}
catch {
    # GetFolder solleva un'eccezione se la cartella non c'e': la si crea
    # partendo dalla radice. Si gestisce un solo livello di annidamento,
    # che e' quanto serve ("\EasyWebParts", "\EMailSender").
    $root = $scheduler.GetFolder("\")
    $root.CreateFolder($TaskFolder.TrimStart("\")) | Out-Null
    $folder = $scheduler.GetFolder($TaskFolder)
    Write-Host "Cartella '$TaskFolder' creata nel Task Scheduler." -ForegroundColor Cyan
}

# --- Definizione del task in XML ----------------------------------------
# Note sui valori scelti:
#   StartBoundary 2000-01-01  -> data nel passato: il trigger e' subito attivo
#   Repetition senza Duration -> ripetizione indefinita
#   UserId S-1-5-18           -> SID di NT AUTHORITY\SYSTEM (indipendente
#                                dalla lingua del sistema operativo)
#   MultipleInstancesPolicy   -> IgnoreNew: se un'esecuzione e' ancora in
#                                corso la successiva viene saltata, cosi'
#                                la stessa mail non viene presa due volte
$interval  = "PT{0}M" -f $IntervalMinutes
$timeLimit = "PT{0}M" -f $ExecutionTimeLimitMinutes

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Spedizione email per tenant $TenantId</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>$interval</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2000-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
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
    <ExecutionTimeLimit>$timeLimit</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Actions>
    <Exec>
      <Command>$exePath</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$workingDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

# --- Registrazione ------------------------------------------------------
# RegisterTask(nome, xml, flags, utente, password, logonType)
#   flags     = 6  -> TASK_CREATE_OR_UPDATE (idempotente)
#   logonType = 5  -> TASK_LOGON_SERVICE_ACCOUNT (nessuna password)
try {
    $folder.RegisterTask($taskName, $xml, 6, $null, $null, 5) | Out-Null

    Write-Host ""
    Write-Host "Task creato/aggiornato con successo:" -ForegroundColor Green
    Write-Host "  Cartella : $TaskFolder"
    Write-Host "  Nome     : $taskName"
    Write-Host "  Comando  : $exePath $arguments"
    Write-Host "  Trigger  : ogni $IntervalMinutes minuto/i, indefinitamente"
    Write-Host "  Account  : SYSTEM (S-1-5-18), privilegi elevati"
    Write-Host ""
}
catch {
    Write-Host "ERRORE durante la creazione del task: $_" -ForegroundColor Red
    throw
}
