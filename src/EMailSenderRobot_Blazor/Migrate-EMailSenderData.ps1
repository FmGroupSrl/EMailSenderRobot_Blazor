<#
.SYNOPSIS
    Migra i dati del robot da un database di origine a uno di destinazione.

.DESCRIPTION
    Copia le 5 tabelle del robot (4 di configurazione/coda + la tabella log)
    da un'installazione all'altra. Serve in tre situazioni reali:

    1) DATABASE CREATI CON I NOMI SBAGLIATI
       Il caso che ha originato questo script: su una macchina nuova erano
       nati "FMGROUP_MainDb" / "FMGROUP_LoggerDb" invece di
       "FMG_FMGROUP_Mail" / "FMG_FMGROUP_MailLog". Rinominare un database non
       basta quando la configurazione punta gia' altrove: si ricrea lo schema
       con i nomi giusti e si portano dentro i dati.

    2) CONSOLIDAMENTO DA "UN DB PER TENANT" A "DB UNICO DEL ROBOT"
       Si esegue una volta per ogni tenant, con -Company, indicando sempre lo
       stesso database di destinazione. Le righe dei vari tenant convivono
       perche' tutte e 5 le tabelle hanno la colonna Company.

    3) TRASLOCO SU UN'ALTRA MACCHINA O ISTANZA
       Origine e destinazione possono stare su istanze SQL diverse: i dati
       passano dal client, non serve linked server ne' backup/restore.

    NON DISTRUTTIVO
    Lo script non cancella, non svuota e non modifica in alcun modo il
    database di origine: si limita a leggerlo. Anche sulla destinazione non
    cancella mai nulla - al massimo aggiorna righe di configurazione, e solo
    se glielo si chiede con -Overwrite.

    IDEMPOTENTE
    Si puo' rieseguire: le righe gia' presenti sulla destinazione vengono
    riconosciute per chiave logica e saltate. Questo permette di fare una
    prima passata a robot acceso e una seconda passata a robot fermo per
    recuperare il poco arrivato nel frattempo.

    COME AVVIENE LA COPIA
    Ogni tabella viene letta dall'origine, scritta in una tabella temporanea
    sulla destinazione con SqlBulkCopy, e da li' travasata con un unico
    INSERT ... SELECT ... WHERE NOT EXISTS. E' un percorso solo, valido sia
    quando le due istanze coincidono sia quando sono separate, e lascia al
    server il confronto delle chiavi invece di farlo riga per riga dal client.

    Le colonne non sono cablate: vengono lette da sys.columns su entrambi i
    lati e se ne usa l'intersezione, escludendo le IDENTITY. Cosi' un database
    di origine creato a mano, con qualche colonna in meno o in piu', non fa
    fallire la migrazione - le colonne mancanti prendono il valore di default
    della destinazione.

    PREREQUISITO SULLA DESTINAZIONE
    Le tabelle devono gia' esistere. Si creano con:

        .\New-EMailSenderTenant.ps1 -TenantName "<Tenant>" -DbPrefix "<Pfx>" `
            -SqlInstance "<Istanza>" -DatabaseOnly

    Se mancano, lo script si ferma prima di copiare qualsiasi cosa e stampa
    esattamente questo comando.

.EXAMPLE
    # Simulazione: dice cosa farebbe, senza scrivere niente
    .\Migrate-EMailSenderData.ps1 -SqlInstance ".\SQLEXPRESS" `
        -SourceMainDb "FMGROUP_MainDb"  -SourceLogDb "FMGROUP_LoggerDb" `
        -TargetMainDb "FMG_FMGROUP_Mail" -TargetLogDb "FMG_FMGROUP_MailLog" `
        -DryRun

.EXAMPLE
    # Migrazione vera, log storico incluso
    .\Migrate-EMailSenderData.ps1 -SqlInstance ".\SQLEXPRESS" `
        -SourceMainDb "FMGROUP_MainDb"  -SourceLogDb "FMGROUP_LoggerDb" `
        -TargetMainDb "FMG_FMGROUP_Mail" -TargetLogDb "FMG_FMGROUP_MailLog" `
        -IncludeLog

.EXAMPLE
    # Consolidamento di un tenant nel database unico del robot,
    # sovrascrivendo la configurazione eventualmente gia' presente
    .\Migrate-EMailSenderData.ps1 -SqlInstance ".\SQLEXPRESS" `
        -SourceMainDb "EWP_Acme_Mail" -SourceLogDb "EWP_Acme_MailLog" `
        -TargetMainDb "FMG_EMailSenderRobot" -SharedTarget `
        -Company "Acme" -Overwrite

.EXAMPLE
    # Trasloco da un'altra macchina, con rinomina del tenant
    .\Migrate-EMailSenderData.ps1 `
        -SourceSqlInstance "VECCHIOSRV\SQLEXPRESS" -SourceMainDb "Ewp_Acme_MainDb" `
        -SqlInstance ".\SQLEXPRESS" -TargetMainDb "FMG_ACME_Mail" `
        -Company "Acme" -NewCompany "ACME"

.NOTES
    Il verbo "Migrate" non e' fra quelli approvati di PowerShell (sarebbe
    "Copy"): e' stato preferito comunque perche' e' la parola con cui questa
    operazione viene cercata. Trattandosi di uno script e non di un modulo,
    non produce alcun warning.
#>
[CmdletBinding()]
param(
    # Istanza SQL della DESTINAZIONE. Se omessa viene chiesta.
    [string] $SqlInstance = "",

    # Istanza SQL dell'ORIGINE. Se omessa si assume la stessa della
    # destinazione, che e' il caso piu' frequente (rinomina di database
    # sbagliati, consolidamento sullo stesso motore).
    [string] $SourceSqlInstance = "",

    # Database di origine. -SourceMainDb e' obbligatorio; se -SourceLogDb e'
    # omesso si assume che l'origine tenga anche il log nel database
    # principale (layout a database unico).
    [Parameter(Mandatory = $true)]
    [string] $SourceMainDb,
    [string] $SourceLogDb = "",

    # Database di destinazione, stessa logica dell'origine.
    [Parameter(Mandatory = $true)]
    [string] $TargetMainDb,
    [string] $TargetLogDb = "",

    # Scorciatoia leggibile per "la destinazione tiene tutto in un database
    # solo": equivale a passare -TargetLogDb uguale a -TargetMainDb.
    [switch] $SharedTarget,

    # Migra solo le righe di questo tenant. Se omesso migra tutti i tenant
    # presenti nell'origine.
    [string] $Company = "",

    # Rinomina il tenant durante la copia: le righe di -Company vengono
    # scritte con questo nome. Richiede -Company, perche' rinominare
    # indiscriminatamente tutti i tenant in uno solo li fonderebbe.
    [string] $NewCompany = "",

    # Cosa fare della coda ConfigEmailJobSchedule:
    #   Pending (default) solo le mail non ancora spedite e senza errore,
    #                     cioe' il lavoro che il robot deve ancora fare;
    #   All               anche lo storico delle mail gia' spedite;
    #   None              niente coda, solo la configurazione.
    [ValidateSet("Pending", "All", "None")]
    [string] $QueueScope = "Pending",

    # Copia anche la tabella log. Esclusa per default: e' la piu' grande,
    # e' soggetta a retention automatica e quasi mai serve nel database nuovo.
    [switch] $IncludeLog,

    # Sulle tabelle di configurazione aggiorna le righe gia' presenti sulla
    # destinazione invece di saltarle. Senza questo interruttore vince il
    # dato gia' presente; con questo vince l'origine.
    # Non ha effetto sulla coda e sul log, dove non ha senso riscrivere.
    [switch] $Overwrite,

    # Simulazione: legge, calcola quante righe verrebbero inserite e le
    # stampa, senza scrivere nulla. Il conteggio e' quello vero, non una
    # stima: le righe vengono davvero portate in tabella temporanea e
    # confrontate con la destinazione, solo l'INSERT finale non viene fatto.
    [switch] $DryRun,

    # Salta la richiesta di conferma prima di scrivere.
    [switch] $Force
)

$ErrorActionPreference = "Stop"

# Funzioni condivise con gli altri script della cartella: la scelta
# dell'istanza SQL deve comportarsi qui esattamente come nel setup.
. "$PSScriptRoot\EMailSenderCommon.ps1"

# ---------------------------------------------------------------------------
# HELPER DI ACCESSO AI DATI
# Stessa forma degli helper di New-EMailSenderTenant.ps1: System.Data.SqlClient
# puro, nessuna dipendenza da sqlcmd o dal modulo SqlServer, che su una
# macchina appena installata non ci sono.
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Costruisce la connection string per un database su una data istanza.
#>
function New-ConnectionString {
    param(
        [Parameter(Mandatory = $true)][string] $Instance,
        [string] $Database = ""
    )

    $cs = "data source=$Instance;Integrated Security=SSPI;Connection Timeout=30;TrustServerCertificate=True"
    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        $cs += ";Database=$Database"
    }
    return $cs
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
        $cmd.CommandText    = $Sql
        $cmd.CommandTimeout = 120
        return $cmd.ExecuteScalar()
    }
    finally {
        $cn.Close()
    }
}

<#
.SYNOPSIS
    Esegue una query e restituisce il risultato come DataTable.
#>
function Get-SqlDataTable {
    param(
        [Parameter(Mandatory = $true)][string] $ConnectionString,
        [Parameter(Mandatory = $true)][string] $Sql
    )

    $cn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText    = $Sql
        # Le tabelle di log possono essere grandi: timeout generoso.
        $cmd.CommandTimeout = 600

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $table   = New-Object System.Data.DataTable
        [void] $adapter.Fill($table)
        return ,$table
    }
    finally {
        $cn.Close()
    }
}

<#
.SYNOPSIS
    Elenca le colonne di una tabella, escludendo quelle IDENTITY.
.DESCRIPTION
    Le IDENTITY vanno escluse per forza: EmailId sulla coda e Id sul log sono
    generate dal server e, se la destinazione ha gia' righe, i valori
    dell'origine collidono. Le mail migrate ricevono quindi un EmailId nuovo,
    il che e' innocuo perche' nessuna delle altre tabelle vi fa riferimento
    (non esistono chiavi esterne fra le 5 tabelle).

    Restituisce un array vuoto se la tabella non esiste: e' il modo con cui
    il chiamante distingue "tabella assente" da "tabella vuota".
#>
function Get-TableColumns {
    param(
        [Parameter(Mandatory = $true)][string] $ConnectionString,
        [Parameter(Mandatory = $true)][string] $TableName
    )

    $sql = @"
SELECT c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(N'[dbo].[$TableName]')
  AND c.is_identity = 0
  AND c.is_computed = 0
ORDER BY c.column_id;
"@

    $table = Get-SqlDataTable -ConnectionString $ConnectionString -Sql $sql
    return @($table.Rows | ForEach-Object { $_["name"] })
}

<#
.SYNOPSIS
    Racchiude un elenco di nomi colonna fra parentesi quadre.
#>
function Format-ColumnList {
    param(
        [Parameter(Mandatory = $true)][string[]] $Columns,
        [string] $Prefix = ""
    )

    $p = ""
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) { $p = "$Prefix." }
    return (($Columns | ForEach-Object { "$p[$_]" }) -join ", ")
}

<#
.SYNOPSIS
    Rende una stringa sicura dentro un letterale SQL.
#>
function Protect-SqlLiteral {
    param([string] $Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace("'", "''")
}

# ---------------------------------------------------------------------------
# DESCRIZIONE DELLE TABELLE DA MIGRARE
#
# Per ognuna serve sapere: su quale dei due database vive, qual e' la chiave
# logica con cui riconoscere una riga gia' presente, e se la configurazione
# puo' essere sovrascritta con -Overwrite.
#
# La chiave logica non e' quasi mai la chiave primaria: ConfigEmailContent e
# ConfigEmailAddress non ne hanno affatto (sono tabelle storiche senza PK), e
# sulla coda la PK e' un IDENTITY che per definizione non sopravvive alla
# copia. Si confronta quindi cio' che identifica davvero una riga per il
# robot.
# ---------------------------------------------------------------------------
$script:Tables = @(
    @{
        Name      = "ConfigEmailServer"
        Database  = "Main"
        # Una riga per tenant: il tenant e' la chiave.
        KeyColumns = @("company")
        Updatable  = $true
        Description = "parametri SMTP e flag di blocco spedizioni"
    },
    @{
        Name      = "ConfigEmailContent"
        Database  = "Main"
        # Testo della mail per tipo e lingua.
        KeyColumns = @("Company", "Type", "Language")
        Updatable  = $true
        Description = "testi delle mail (multilingua)"
    },
    @{
        Name      = "ConfigEmailAddress"
        Database  = "Main"
        # Destinatari per tipo di mail.
        KeyColumns = @("Company", "Type")
        Updatable  = $true
        Description = "destinatari per tipo di mail"
    },
    @{
        Name      = "ConfigEmailJobSchedule"
        Database  = "Main"
        # Nessuna vera chiave naturale: si usa la combinazione che nella
        # pratica identifica una spedizione, per non duplicare le mail se lo
        # script viene rieseguito.
        KeyColumns = @("Company", "JobReference", "EmailType", "EmailTo", "CreationTimeStamp")
        Updatable  = $false
        Description = "coda delle mail"
    },
    @{
        Name      = "log"
        Database  = "Log"
        # Il log non si confronta riga per riga (sarebbe costoso su tabelle da
        # milioni di righe): si migra solo cio' che e' piu' recente dell'ultima
        # riga gia' presente sulla destinazione. Vedi Get-SourceFilter.
        KeyColumns = @()
        Updatable  = $false
        Description = "storico operazioni"
    }
)

# ---------------------------------------------------------------------------
# COSTRUZIONE DEI FILTRI DI LETTURA
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Costruisce la clausola WHERE con cui leggere una tabella dall'origine.
.DESCRIPTION
    Mette insieme tre filtri indipendenti:
      - il tenant, se e' stato chiesto -Company;
      - lo stato della coda, secondo -QueueScope;
      - per il log, il taglio temporale che evita di ricopiare cio' che sulla
        destinazione c'e' gia'.
#>
function Get-SourceFilter {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Table,
        [string] $TargetLogWatermark = ""
    )

    $conditions = @()

    # Filtro per tenant. Tutte e 5 le tabelle hanno la colonna Company
    # (minuscola su ConfigEmailServer e log, ma SQL Server non distingue).
    if (-not [string]::IsNullOrWhiteSpace($Company)) {
        $conditions += "[Company] = N'$(Protect-SqlLiteral $Company)'"
    }

    # Ambito della coda.
    if ($Table.Name -eq "ConfigEmailJobSchedule") {
        switch ($QueueScope) {
            "Pending" {
                # Il lavoro ancora da fare: non spedito e non in errore.
                # Le mail in errore restano indietro di proposito - se il
                # motivo dell'errore era la configurazione vecchia, e'
                # sbagliato riproporle alla cieca sul robot nuovo.
                $conditions += "[SentTimeStamp] IS NULL"
                $conditions += "ISNULL([IsError], 'N') <> 'S'"
            }
            "All"  { }
            "None" { $conditions += "1 = 0" }
        }
    }

    # Taglio temporale del log.
    if ($Table.Name -eq "log" -and -not [string]::IsNullOrWhiteSpace($TargetLogWatermark)) {
        $conditions += "[TimeStamp] > CONVERT(DATETIME, N'$TargetLogWatermark', 126)"
    }

    if ($conditions.Count -eq 0) { return "" }
    return " WHERE " + ($conditions -join " AND ")
}

<#
.SYNOPSIS
    Legge dalla destinazione il TimeStamp dell'ultima riga di log presente.
.DESCRIPTION
    E' il "livello dell'acqua" da cui ripartire. Senza questo, una seconda
    esecuzione ricopierebbe tutto il log da capo: confrontare riga per riga
    una tabella di log e' troppo costoso, il tempo e' un discriminante
    sufficiente.
#>
function Get-LogWatermark {
    param(
        [Parameter(Mandatory = $true)][string] $ConnectionString
    )

    $where = ""
    if (-not [string]::IsNullOrWhiteSpace($Company)) {
        # Il watermark va calcolato sul tenant di destinazione, che con
        # -NewCompany ha un nome diverso da quello di origine.
        $target = $Company
        if (-not [string]::IsNullOrWhiteSpace($NewCompany)) { $target = $NewCompany }
        $where = " WHERE [company] = N'$(Protect-SqlLiteral $target)'"
    }

    $value = Invoke-SqlScalar -ConnectionString $ConnectionString `
                              -Sql "SELECT MAX([TimeStamp]) FROM [dbo].[log]$where"

    if ($null -eq $value -or $value -is [DBNull]) { return "" }
    return ([datetime]$value).ToString("yyyy-MM-ddTHH:mm:ss.fff")
}

# ---------------------------------------------------------------------------
# MIGRAZIONE DI UNA SINGOLA TABELLA
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Copia una tabella dall'origine alla destinazione.
.DESCRIPTION
    Il percorso e' sempre lo stesso, che le due istanze coincidano o no:

      1. si calcolano le colonne comuni ai due lati (senza IDENTITY);
      2. si leggono le righe dall'origine, filtrate;
      3. si crea una tabella temporanea sulla destinazione con SELECT TOP 0,
         cosi' i tipi sono per costruzione identici a quelli di arrivo;
      4. SqlBulkCopy riversa le righe nella temporanea;
      5. un UPDATE (solo con -Overwrite) e un INSERT ... WHERE NOT EXISTS
         travasano dalla temporanea alla tabella vera.

    La tabella temporanea e' locale (#) e vive dentro la connessione aperta
    qui: se lo script muore a meta', il server la elimina da solo.

    Restituisce un hashtable con i conteggi, per il riepilogo finale.
#>
function Copy-Table {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Table,
        [Parameter(Mandatory = $true)][string]    $SourceConn,
        [Parameter(Mandatory = $true)][string]    $TargetConn
    )

    $name   = $Table.Name
    $result = @{ Table = $name; Read = 0; Inserted = 0; Updated = 0; Skipped = 0; Note = "" }

    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Yellow
    Write-Host "    $($Table.Description)" -ForegroundColor DarkGray

    # --- 1. Colonne comuni ------------------------------------------------
    # @() perche' una tabella con una sola colonna tornerebbe come stringa
    # singola e .Count darebbe la lunghezza del nome invece di 1.
    $sourceCols = @(Get-TableColumns -ConnectionString $SourceConn -TableName $name)
    $targetCols = @(Get-TableColumns -ConnectionString $TargetConn -TableName $name)

    if ($sourceCols.Count -eq 0) {
        Write-Host "    Tabella assente nell'origine: niente da migrare." -ForegroundColor Cyan
        $result.Note = "assente nell'origine"
        return $result
    }

    # Intersezione preservando l'ordine della destinazione.
    $columns = @($targetCols | Where-Object { $sourceCols -contains $_ })

    if ($columns.Count -eq 0) {
        throw "Nessuna colonna in comune fra origine e destinazione per la tabella [$name]."
    }

    # Le colonne presenti da una parte sola non sono un errore, ma vanno
    # dette: sono la spia di uno schema disallineato.
    $onlySource = @($sourceCols | Where-Object { $targetCols -notcontains $_ })
    $onlyTarget = @($targetCols | Where-Object { $sourceCols -notcontains $_ })

    if ($onlySource.Count -gt 0) {
        Write-Host "    Colonne solo nell'origine, non migrate: $($onlySource -join ', ')" -ForegroundColor Yellow
    }
    if ($onlyTarget.Count -gt 0) {
        Write-Host "    Colonne solo nella destinazione, resteranno al default: $($onlyTarget -join ', ')" -ForegroundColor Yellow
    }

    # --- 2. Lettura dall'origine ------------------------------------------
    # Il watermark serve solo al log e va calcolato prima del filtro.
    $watermark = ""
    if ($name -eq "log") {
        $watermark = Get-LogWatermark -ConnectionString $TargetConn
        if (-not [string]::IsNullOrWhiteSpace($watermark)) {
            Write-Host "    Sulla destinazione il log arriva al ${watermark}: si copia solo il piu' recente." -ForegroundColor Cyan
        }
    }

    $where     = Get-SourceFilter -Table $Table -TargetLogWatermark $watermark
    $colList   = Format-ColumnList -Columns $columns
    $selectSql = "SELECT $colList FROM [dbo].[$name]$where"

    $data = Get-SqlDataTable -ConnectionString $SourceConn -Sql $selectSql
    $result.Read = $data.Rows.Count

    Write-Host "    Righe lette dall'origine: $($data.Rows.Count)"

    if ($data.Rows.Count -eq 0) {
        Write-Host "    Niente da copiare." -ForegroundColor Cyan
        return $result
    }

    # --- 2-bis. Rinomina del tenant ---------------------------------------
    # Si fa qui, sul DataTable in memoria, prima che i dati tocchino il
    # server: cosi' tutto il resto del percorso (chiavi comprese) lavora gia'
    # sul nome nuovo e non serve tradurlo in due punti diversi.
    if (-not [string]::IsNullOrWhiteSpace($NewCompany)) {
        $companyCol = @($columns | Where-Object { $_ -ieq "Company" })[0]
        if ($companyCol) {
            foreach ($row in $data.Rows) {
                $row[$companyCol] = $NewCompany
            }
            Write-Host "    Tenant rinominato in scrittura: '$Company' -> '$NewCompany'" -ForegroundColor Cyan
        }
    }

    # --- 3-5. Staging e travaso -------------------------------------------
    # Una sola connessione per tutto il blocco: la tabella temporanea locale
    # esiste solo dentro questa connessione.
    $cn = New-Object System.Data.SqlClient.SqlConnection($TargetConn)
    try {
        $cn.Open()

        $stagingName = "#stg_$name"

        # SELECT TOP 0 ... INTO replica i tipi esatti della destinazione senza
        # doverli dedurre: nessun rischio di troncamenti da tipo sbagliato.
        # Le IDENTITY sono gia' fuori dall'elenco colonne, quindi la
        # temporanea non ne eredita.
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = "SELECT TOP 0 $colList INTO [$stagingName] FROM [dbo].[$name]"
        $cmd.CommandTimeout = 120
        [void] $cmd.ExecuteNonQuery()

        # Riversamento in blocco nella temporanea.
        $bulk = New-Object System.Data.SqlClient.SqlBulkCopy($cn)
        try {
            $bulk.DestinationTableName = $stagingName
            $bulk.BulkCopyTimeout      = 600
            $bulk.BatchSize            = 5000

            # Mapping esplicito per nome: senza, SqlBulkCopy va per posizione
            # e basterebbe un ordine diverso per scrivere i dati nella colonna
            # sbagliata senza alcun errore.
            foreach ($c in $columns) {
                [void] $bulk.ColumnMappings.Add($c, $c)
            }

            $bulk.WriteToServer($data)
        }
        finally {
            $bulk.Close()
        }

        # Condizione di corrispondenza fra staging e tabella di arrivo.
        # ISNULL su entrambi i lati perche' in SQL NULL <> NULL: senza,
        # una riga con Type NULL non verrebbe mai riconosciuta come gia'
        # presente e si duplicherebbe a ogni esecuzione.
        $matchCondition = ""
        if ($Table.KeyColumns.Count -gt 0) {
            $parts = foreach ($k in $Table.KeyColumns) {
                # Il confronto va fatto solo sulle chiavi effettivamente
                # migrate: se una colonna chiave non esiste da una delle due
                # parti, si esclude dal confronto invece di fallire.
                if ($columns -icontains $k) {
                    "ISNULL(t.[$k], '') = ISNULL(s.[$k], '')"
                }
            }
            $parts = @($parts | Where-Object { $_ })
            if ($parts.Count -gt 0) { $matchCondition = ($parts -join " AND ") }
        }

        # --- UPDATE delle righe gia' presenti (solo -Overwrite) -----------
        if ($Overwrite -and $Table.Updatable -and $matchCondition) {
            # Si aggiornano tutte le colonne tranne quelle di chiave, che per
            # definizione coincidono gia'.
            $setCols = @($columns | Where-Object { $Table.KeyColumns -inotcontains $_ })

            if ($setCols.Count -gt 0) {
                $setList = ($setCols | ForEach-Object { "t.[$_] = s.[$_]" }) -join ", "

                $updateSql = @"
UPDATE t SET $setList
FROM [dbo].[$name] t
INNER JOIN [$stagingName] s ON $matchCondition;
SELECT @@ROWCOUNT;
"@
                if ($DryRun) {
                    $countSql = @"
SELECT COUNT(*) FROM [dbo].[$name] t
INNER JOIN [$stagingName] s ON $matchCondition;
"@
                    $cmd = $cn.CreateCommand()
                    $cmd.CommandText    = $countSql
                    $cmd.CommandTimeout = 300
                    $result.Updated = [int] $cmd.ExecuteScalar()
                }
                else {
                    $cmd = $cn.CreateCommand()
                    $cmd.CommandText    = $updateSql
                    $cmd.CommandTimeout = 600
                    $result.Updated = [int] $cmd.ExecuteScalar()
                }
            }
        }

        # --- INSERT delle righe nuove -------------------------------------
        $notExists = ""
        if ($matchCondition) {
            $notExists = @"
 WHERE NOT EXISTS (
    SELECT 1 FROM [dbo].[$name] t WHERE $matchCondition
)
"@
        }

        $insertSql = @"
INSERT INTO [dbo].[$name] ($colList)
SELECT $(Format-ColumnList -Columns $columns -Prefix 's')
FROM [$stagingName] s$notExists;
SELECT @@ROWCOUNT;
"@

        if ($DryRun) {
            # Stesso identico WHERE dell'INSERT, ma si conta soltanto: il
            # numero che esce e' quello che uscirebbe davvero.
            $countSql = @"
SELECT COUNT(*) FROM [$stagingName] s$notExists;
"@
            $cmd = $cn.CreateCommand()
            $cmd.CommandText    = $countSql
            $cmd.CommandTimeout = 300
            $result.Inserted = [int] $cmd.ExecuteScalar()
        }
        else {
            $cmd = $cn.CreateCommand()
            $cmd.CommandText    = $insertSql
            $cmd.CommandTimeout = 600
            $result.Inserted = [int] $cmd.ExecuteScalar()
        }

        $result.Skipped = $result.Read - $result.Inserted
        if ($Overwrite) { $result.Skipped = $result.Read - $result.Inserted - $result.Updated }
        if ($result.Skipped -lt 0) { $result.Skipped = 0 }

        # Pulizia esplicita, anche se la chiusura della connessione basterebbe.
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = "DROP TABLE [$stagingName]"
        [void] $cmd.ExecuteNonQuery()
    }
    finally {
        $cn.Close()
    }

    $verb = if ($DryRun) { "Da inserire" } else { "Inserite" }
    Write-Host "    $verb : $($result.Inserted)" -ForegroundColor Green
    if ($Overwrite -and $Table.Updatable) {
        $verbU = if ($DryRun) { "Da aggiornare" } else { "Aggiornate" }
        Write-Host "    $verbU : $($result.Updated)" -ForegroundColor Green
    }
    if ($result.Skipped -gt 0) {
        Write-Host "    Gia' presenti, saltate: $($result.Skipped)" -ForegroundColor Cyan
    }

    return $result
}

# ---------------------------------------------------------------------------
# CONVALIDA DEI PARAMETRI
# ---------------------------------------------------------------------------

# La rinomina senza un tenant selezionato fonderebbe tutti i tenant in uno.
if (-not [string]::IsNullOrWhiteSpace($NewCompany) -and [string]::IsNullOrWhiteSpace($Company)) {
    throw "-NewCompany richiede -Company: senza, tutti i tenant dell'origine verrebbero fusi in uno solo."
}

# Il nome del tenant di arrivo deve rispettare gli stessi vincoli imposti
# altrove (NVARCHAR(15), niente spazi), altrimenti la migrazione riesce e il
# robot poi non trova la configurazione.
# Test-TenantNameValid stampa da se' il motivo dello scarto, in rosso: qui
# basta interrompere.
if (-not [string]::IsNullOrWhiteSpace($NewCompany)) {
    if (-not (Test-TenantNameValid -Name $NewCompany)) {
        throw "-NewCompany '$NewCompany' non e' un nome di tenant valido."
    }
}

# Destinazione a database unico.
if ($SharedTarget) {
    if (-not [string]::IsNullOrWhiteSpace($TargetLogDb) -and $TargetLogDb -ne $TargetMainDb) {
        throw "-SharedTarget e -TargetLogDb '$TargetLogDb' sono in contraddizione: con il database unico il log sta in [$TargetMainDb]."
    }
    $TargetLogDb = $TargetMainDb
}

# Default dei database di log: se non detto, si assume che il log stia nel
# database principale, cioe' il layout condiviso.
if ([string]::IsNullOrWhiteSpace($SourceLogDb)) { $SourceLogDb = $SourceMainDb }
if ([string]::IsNullOrWhiteSpace($TargetLogDb)) { $TargetLogDb = $TargetMainDb }

# ---------------------------------------------------------------------------
# ISTANZE SQL
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Migrazione dati EMailSenderRobot" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# Destinazione: se non passata si usa la stessa procedura di scelta degli
# altri script, che elenca le istanze e non propone default arbitrari.
if ([string]::IsNullOrWhiteSpace($SqlInstance)) {
    Write-Host ""
    Write-Host " Istanza di DESTINAZIONE" -ForegroundColor Yellow
    $SqlInstance = Resolve-SqlInstance
}

# Origine: se non passata si assume la stessa della destinazione. E' il caso
# piu' comune e chiederlo due volte sarebbe solo rumore.
if ([string]::IsNullOrWhiteSpace($SourceSqlInstance)) {
    $SourceSqlInstance = $SqlInstance
}

$sourceMainConn = New-ConnectionString -Instance $SourceSqlInstance -Database $SourceMainDb
$sourceLogConn  = New-ConnectionString -Instance $SourceSqlInstance -Database $SourceLogDb
$targetMainConn = New-ConnectionString -Instance $SqlInstance       -Database $TargetMainDb
$targetLogConn  = New-ConnectionString -Instance $SqlInstance       -Database $TargetLogDb

# ---------------------------------------------------------------------------
# VERIFICHE PRELIMINARI
# Si controlla tutto prima di scrivere qualsiasi cosa: una migrazione che
# fallisce a meta' lascia uno stato che nessuno sa piu' interpretare.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== Verifiche preliminari ===" -ForegroundColor Yellow

# Esistenza dei quattro database.
foreach ($db in @(
    @{ Instance = $SourceSqlInstance; Name = $SourceMainDb; Role = "origine (principale)" },
    @{ Instance = $SourceSqlInstance; Name = $SourceLogDb;  Role = "origine (log)" },
    @{ Instance = $SqlInstance;       Name = $TargetMainDb; Role = "destinazione (principale)" },
    @{ Instance = $SqlInstance;       Name = $TargetLogDb;  Role = "destinazione (log)" }
)) {
    $masterConn = New-ConnectionString -Instance $db.Instance
    $exists = Invoke-SqlScalar -ConnectionString $masterConn `
        -Sql "SELECT COUNT(*) FROM sys.databases WHERE name = N'$(Protect-SqlLiteral $db.Name)'"

    if ([int] $exists -eq 0) {
        throw "Database [$($db.Name)] non trovato sull'istanza [$($db.Instance)] - $($db.Role)."
    }
    Write-Host "    [$($db.Name)] trovato su [$($db.Instance)] - $($db.Role)." -ForegroundColor Green
}

# Origine e destinazione coincidenti: sarebbe un ciclo su se stesso.
if ($SourceSqlInstance -eq $SqlInstance -and $SourceMainDb -eq $TargetMainDb) {
    throw "Origine e destinazione sono lo stesso database [$SourceMainDb] sulla stessa istanza."
}

# Confronto delle regole di confronto (collation).
#
# La migrazione funziona comunque, perche' la copia passa dal client e non da
# una JOIN fra i due database: e' proprio il caso in cui SQL Server
# solleverebbe "Non e' possibile risolvere il conflitto tra le regole di
# confronto". Va pero' detto, perche' una collation diversa cambia il modo in
# cui la destinazione ordina e confronta il testo - per esempio se maiuscole e
# accenti contino nei confronti. Succede regolarmente migrando da
# installazioni storiche: i database vecchi hanno la collation scelta
# all'epoca, quelli nuovi ereditano quella dell'istanza.
#
# Si legge la collation di una COLONNA e non quella del database: e' il dato
# che determina davvero il comportamento dei confronti (una colonna puo'
# averne una propria, diversa da quella del database), ed e' sempre
# valorizzato, mentre sys.databases.collation_name puo' tornare NULL.
$collationSql = @"
SELECT TOP 1 c.collation_name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(N'[dbo].[ConfigEmailContent]')
  AND c.collation_name IS NOT NULL;
"@

$srcCollation = Invoke-SqlScalar -ConnectionString $sourceMainConn -Sql $collationSql
$tgtCollation = Invoke-SqlScalar -ConnectionString $targetMainConn -Sql $collationSql

if ([string]::IsNullOrWhiteSpace([string] $srcCollation) -or [string]::IsNullOrWhiteSpace([string] $tgtCollation)) {
    # Non determinabile: si tace, invece di rassicurare a vuoto.
    Write-Host "    Regole di confronto non determinabili: controllo saltato." -ForegroundColor DarkGray
}
elseif ($srcCollation -ne $tgtCollation) {
    Write-Host ""
    Write-Host "    Attenzione: i due database hanno regole di confronto diverse." -ForegroundColor Yellow
    Write-Host "      origine      [$SourceMainDb] : $srcCollation" -ForegroundColor Yellow
    Write-Host "      destinazione [$TargetMainDb] : $tgtCollation" -ForegroundColor Yellow
    Write-Host "    I dati arrivano comunque integri, ma sulla destinazione" -ForegroundColor Yellow
    Write-Host "    ordinamenti e confronti di testo possono comportarsi" -ForegroundColor Yellow
    Write-Host "    diversamente da prima." -ForegroundColor Yellow
    Write-Host ""
}
else {
    Write-Host "    Regole di confronto allineate ($tgtCollation)." -ForegroundColor Green
}

# Tabelle sulla destinazione: devono esistere gia'.
$missing = @()
foreach ($t in $script:Tables) {
    $conn = if ($t.Database -eq "Log") { $targetLogConn } else { $targetMainConn }
    $cols = @(Get-TableColumns -ConnectionString $conn -TableName $t.Name)
    if ($cols.Count -eq 0) { $missing += $t.Name }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host " Tabelle mancanti sulla destinazione: $($missing -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host " Crearle prima con:" -ForegroundColor Yellow
    Write-Host "   .\New-EMailSenderTenant.ps1 -TenantName `"<Tenant>`" -DbPrefix `"<Prefisso>`" ``" -ForegroundColor Yellow
    Write-Host "       -SqlInstance `"$SqlInstance`" -DatabaseOnly" -ForegroundColor Yellow
    Write-Host ""
    throw "Schema di destinazione incompleto: migrazione non avviata."
}
Write-Host "    Tutte e $($script:Tables.Count) le tabelle sono presenti sulla destinazione." -ForegroundColor Green

# ---------------------------------------------------------------------------
# RIEPILOGO E CONFERMA
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== Riepilogo ===" -ForegroundColor Yellow
Write-Host " Origine       : [$SourceMainDb] + [$SourceLogDb] su $SourceSqlInstance"
Write-Host " Destinazione  : [$TargetMainDb] + [$TargetLogDb] su $SqlInstance"

if ([string]::IsNullOrWhiteSpace($Company)) {
    Write-Host " Tenant        : tutti quelli presenti nell'origine"
}
else {
    $tenantLine = " Tenant        : $Company"
    if (-not [string]::IsNullOrWhiteSpace($NewCompany)) { $tenantLine += "  ->  $NewCompany" }
    Write-Host $tenantLine
}

$queueLabel = switch ($QueueScope) {
    "Pending" { "solo le mail non ancora spedite" }
    "All"     { "tutta la coda, storico compreso" }
    "None"    { "esclusa" }
}
Write-Host " Coda          : $queueLabel"

$logLabel = if ($IncludeLog) { "incluso" } else { "escluso (usare -IncludeLog per copiarlo)" }
Write-Host " Log           : $logLabel"

$cfgLabel = if ($Overwrite) { "sovrascritta dai dati di origine" } else { "lasciata com'e' (usare -Overwrite per sostituirla)" }
Write-Host " Config esist. : $cfgLabel"

if ($DryRun) {
    Write-Host ""
    Write-Host " SIMULAZIONE: non verra' scritto nulla." -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host " L'origine non viene modificata in alcun modo." -ForegroundColor DarkGray
    Write-Host " Consigliato comunque un backup di [$TargetMainDb] prima di procedere." -ForegroundColor DarkGray

    if (-not $Force) {
        if (-not (Read-Confirmation -Prompt " Procedere con la migrazione?")) {
            Write-Host ""
            Write-Host " Annullato: non e' stato scritto nulla." -ForegroundColor Cyan
            return
        }
    }
}

# ---------------------------------------------------------------------------
# MIGRAZIONE
# ---------------------------------------------------------------------------

$results = @()

foreach ($t in $script:Tables) {

    # Il log si copia solo se richiesto esplicitamente.
    if ($t.Name -eq "log" -and -not $IncludeLog) {
        Write-Host ""
        Write-Host "=== log ===" -ForegroundColor Yellow
        Write-Host "    Saltata: usare -IncludeLog per migrare anche lo storico." -ForegroundColor Cyan
        $results += @{ Table = "log"; Read = 0; Inserted = 0; Updated = 0; Skipped = 0; Note = "saltata" }
        continue
    }

    # La coda si puo' escludere del tutto.
    if ($t.Name -eq "ConfigEmailJobSchedule" -and $QueueScope -eq "None") {
        Write-Host ""
        Write-Host "=== ConfigEmailJobSchedule ===" -ForegroundColor Yellow
        Write-Host "    Saltata: -QueueScope None." -ForegroundColor Cyan
        $results += @{ Table = $t.Name; Read = 0; Inserted = 0; Updated = 0; Skipped = 0; Note = "saltata" }
        continue
    }

    $srcConn = if ($t.Database -eq "Log") { $sourceLogConn } else { $sourceMainConn }
    $tgtConn = if ($t.Database -eq "Log") { $targetLogConn } else { $targetMainConn }

    $results += Copy-Table -Table $t -SourceConn $srcConn -TargetConn $tgtConn
}

# ---------------------------------------------------------------------------
# RIEPILOGO FINALE
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host $(if ($DryRun) { " SIMULAZIONE COMPLETATA" } else { " MIGRAZIONE COMPLETATA" }) -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("   {0,-26} {1,8} {2,10} {3,10} {4,8}" -f "Tabella", "Lette", "Inserite", "Aggiorn.", "Saltate")
Write-Host ("   {0,-26} {1,8} {2,10} {3,10} {4,8}" -f "-------", "-----", "--------", "--------", "-------")

foreach ($r in $results) {
    $note = ""
    if (-not [string]::IsNullOrWhiteSpace($r.Note)) { $note = "  ($($r.Note))" }
    Write-Host ("   {0,-26} {1,8} {2,10} {3,10} {4,8}{5}" -f `
        $r.Table, $r.Read, $r.Inserted, $r.Updated, $r.Skipped, $note)
}

# Somma esplicita invece di Measure-Object: su PowerShell 5.1 le chiavi di un
# hashtable non sono proprieta' dell'oggetto, e -Property Inserted fallirebbe
# con "Impossibile trovare la proprieta'".
$totalInserted = 0
$totalUpdated  = 0
foreach ($r in $results) {
    $totalInserted += [int] $r.Inserted
    $totalUpdated  += [int] $r.Updated
}

Write-Host ""
if ($DryRun) {
    Write-Host " Verrebbero inserite $totalInserted righe e aggiornate $totalUpdated." -ForegroundColor Cyan
    Write-Host " Rilanciare senza -DryRun per eseguire davvero." -ForegroundColor Cyan
}
else {
    Write-Host " Inserite $totalInserted righe, aggiornate $totalUpdated." -ForegroundColor Green
    Write-Host ""
    Write-Host " Passi successivi:" -ForegroundColor Yellow
    Write-Host "   1. Verificare l'installazione:  .\Test-EMailSenderInstall.ps1"
    Write-Host "   2. Controllare dalla Web UI che il tenant veda la sua configurazione."
    Write-Host "   3. Solo dopo la verifica, mettere offline i database di origine."
    Write-Host ""
    Write-Host " I database di origine non sono stati toccati: restano disponibili" -ForegroundColor DarkGray
    Write-Host " come copia di sicurezza finche' non si decide di eliminarli." -ForegroundColor DarkGray
}
Write-Host ""
