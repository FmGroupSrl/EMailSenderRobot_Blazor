# EMailSenderRobot_Blazor — Guida di installazione e configurazione

> Versione: maggio 2026 | Target: Windows Server 2019, SQL Server Express, .NET 8

---

## Changelog

| Data | Modifica |
|---|---|
| Maggio 2026 | Aggiunto campo `Language` in `ConfigEmailContent` — supporto multilingua con fallback automatico (lingua richiesta → EN → IT) |
| Maggio 2026 | Aggiunto `DefaultTenants` in `appsettings.json` — tenant speciali (Development, FMGroup) che ricevono copia vuota di ogni nuovo tipo mail |
| Maggio 2026 | Aggiunto `Deploy.ps1` per deploy automatico — ferma servizio, copia file (esclusi appsettings), riavvia |
| Maggio 2026 | Aggiunti script PS: `RestartServices.ps1`, `StartServices.ps1`, `StopServices.ps1` |
| Maggio 2026 | `publish.cmd` aggiornato — versione automatica, commit/tag Git, copia script PS in publish |

---

## Indice

1. [Struttura della soluzione](#1-struttura-della-soluzione)
2. [Preparazione del database](#2-preparazione-del-database)
3. [Installazione sul server](#3-installazione-sul-server)
4. [Pubblicazione e deploy](#4-pubblicazione-e-deploy)
5. [Configurazione appsettings.json](#5-configurazione-appsettingsjson)
6. [Configurazione SMTP](#6-configurazione-smtp)
7. [Task Scheduler — ConsoleJob](#7-task-scheduler--consolejob)
8. [Avvio EMailSender.Web](#8-avvio-emailsenderweb)
9. [Aggiunta di un nuovo tenant](#9-aggiunta-di-un-nuovo-tenant)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Struttura della soluzione

```
C:\EMailSender\
├── Web\                  ← EMailSender.Web (Blazor Server)
├── ConsoleJob\           ← EMailSender.ConsoleJob (spedizione mail)
├── RestartServices.ps1   ← Ferma e riavvia EMailSenderWeb
├── StartServices.ps1     ← Avvia EMailSenderWeb
└── StopServices.ps1      ← Ferma EMailSenderWeb
```

---

## 2. Preparazione del database

### 2.1 Database principale (es. `Ewp_TenantName_MainDb`)

```sql
-- Coda mail
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

-- Configurazione SMTP
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

-- Contenuto mail (introdotta maggio 2026)
-- Chiave logica: Company + Type + Language
-- Language: codice ISO 639-1 (IT, EN, DE, FR, ES)
-- Fallback automatico: lingua richiesta → EN → IT
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

-- Indirizzi mail (introdotta maggio 2026)
-- Chiave logica: Company + Type
-- EmailTO = 'Utente Specifico' se il destinatario viene passato dal codice chiamante
CREATE TABLE ConfigEmailAddress (
    Company     NVARCHAR(15)   NULL,
    Type        NVARCHAR(512)  NULL,
    EmailTO     NVARCHAR(512)  NULL,
    EmailCC     NVARCHAR(512)  NULL,
    EmailCCN    NVARCHAR(512)  NULL,
    Description NVARCHAR(512)  NULL
);
```

> `IsDeliveryBlocked = 'S'` blocca le spedizioni per il tenant — gestibile dalla pagina **Tenant Setup** della Web UI.

> `EmailBodyRowRepeater` è un template HTML di una singola riga (es. `<tr>`) con placeholder `#CAMPO#`. Il codice applicativo lo espande in loop e sostituisce il placeholder `#ELEMENTLIST#` nel corpo mail.

### 2.2 Database di log (es. `Ewp_TenantName_LoggerDb`)

```sql
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
```

### 2.3 Permessi SQL per Task Scheduler e servizio Web

Il ConsoleJob gira come `NT AUTHORITY\SYSTEM`. Eseguire su entrambi i DB:

```sql
USE Ewp_TenantName_MainDb;
CREATE USER [NT AUTHORITY\SYSTEM] FOR LOGIN [NT AUTHORITY\SYSTEM];
ALTER ROLE db_datareader ADD MEMBER [NT AUTHORITY\SYSTEM];
ALTER ROLE db_datawriter ADD MEMBER [NT AUTHORITY\SYSTEM];

USE Ewp_TenantName_LoggerDb;
CREATE USER [NT AUTHORITY\SYSTEM] FOR LOGIN [NT AUTHORITY\SYSTEM];
ALTER ROLE db_datareader ADD MEMBER [NT AUTHORITY\SYSTEM];
ALTER ROLE db_datawriter ADD MEMBER [NT AUTHORITY\SYSTEM];
```

> Se il login non esiste a livello server:
> ```sql
> CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
> ```

---

## 3. Installazione sul server

### 3.1 Primo deploy

1. Copiare sul server la cartella `publish\` completa
2. Eseguire `install.cmd` come amministratore — crea `C:\EMailSender\Web\` e `C:\EMailSender\ConsoleJob\`, imposta i permessi
3. Copiare manualmente i file da `publish\Web\` e `publish\ConsoleJob\` nelle rispettive cartelle
4. Configurare `appsettings.json` in entrambe le cartelle
5. Registrare il servizio Windows `EMailSenderWeb`
6. Avviare con `StartServices.ps1`

### 3.2 Script di supporto

| Script | Descrizione |
|---|---|
| `install.cmd` | Prima installazione: crea cartelle e imposta permessi |
| `Deploy.ps1` | Aggiornamento: ferma servizio, copia file, riavvia |
| `RunDeploy.cmd` | Lancia `Deploy.ps1` come amministratore con un doppio click |
| `RestartServices.ps1` | Ferma e riavvia il servizio `EMailSenderWeb` |
| `StartServices.ps1` | Avvia il servizio `EMailSenderWeb` |
| `StopServices.ps1` | Ferma il servizio `EMailSenderWeb` |

Tutti vanno eseguiti come amministratore su `DULEVO02-WEB`.

---

## 4. Pubblicazione e deploy

### 4.1 Pubblicazione (in sviluppo)

Dalla cartella `src\EMailSenderRobot_Blazor\` eseguire `publish.cmd`.

Il comando:
- Compila `EMailSender.Web` e `EMailSender.ConsoleJob` in Release
- Pubblica i file in `publish\Web\` e `publish\ConsoleJob\`
- Assegna versione automatica `1.0.YYMMDD.HHmm`
- Esegue commit e tag Git automatici
- Copia `Deploy.ps1` e gli script PS nella cartella `publish\`

### 4.2 Deploy sul server

1. Copiare la cartella `publish\` sul server (o usare cartella di rete)
2. Eseguire `Deploy.ps1` come amministratore (o `RunDeploy.cmd` con doppio click)

`Deploy.ps1`:
- Ferma il servizio `EMailSenderWeb`
- Copia tutti i file da `publish\Web\` → `C:\EMailSender\Web\` e `publish\ConsoleJob\` → `C:\EMailSender\ConsoleJob\`
- **Non sovrascrive mai** nessun file `appsettings*.json`
- Copia `RestartServices.ps1`, `StartServices.ps1`, `StopServices.ps1` in `C:\EMailSender\`
- Riavvia `EMailSenderWeb`

---

## 5. Configurazione appsettings.json

Il file si trova in **due copie indipendenti**:
- `C:\EMailSender\Web\appsettings.json`
- `C:\EMailSender\ConsoleJob\appsettings.json`

Struttura:

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "ConnectionStrings": {
    "TenantName_Main": "data source=.\\SQLEXPRESS;Integrated Security=SSPI;Connection Timeout=60;Database=Ewp_TenantName_MainDb;TrustServerCertificate=True",
    "TenantName_Log":  "data source=.\\SQLEXPRESS;Integrated Security=SSPI;Connection Timeout=60;Database=Ewp_TenantName_LoggerDb;TrustServerCertificate=True"
  },
  "Companies": [
    {
      "Name": "TenantName",
      "DisplayName": "Tenant Description",
      "BatchSize": 10,
      "MaxRetryCount": 2,
      "LogRetentionDays": 30,
      "LogDirectory": "C:\\TenantDataDirectory\\Log",
      "BackupCompany": "",
      "BackupEmailType": "",
      "SqlConfigTableServer": "ConfigEmailServer"
    }
  ],
  "DefaultTenants": ["Development", "FMGroup"]
}
```

| Campo | Descrizione |
|---|---|
| `{Name}_Main` | Connection string al DB principale del tenant |
| `{Name}_Log` | Connection string al DB di log del tenant |
| `Name` | Codice interno tenant — deve corrispondere al prefisso delle ConnectionStrings |
| `DisplayName` | Nome visualizzato nella UI |
| `BatchSize` | Mail elaborate per ogni esecuzione del ConsoleJob |
| `MaxRetryCount` | Tentativi massimi prima di annullare una mail |
| `LogRetentionDays` | Giorni di conservazione dei file di log su disco |
| `LogDirectory` | Cartella dove il ConsoleJob scrive i file `.log` |
| `SqlConfigTableServer` | Nome della tabella SMTP sul DB (default: `ConfigEmailServer`) |
| `DefaultTenants` | Tenant speciali (sviluppo e SA) — ricevono automaticamente copia vuota di ogni nuovo tipo mail creato |

> `TrustServerCertificate=True` è obbligatorio per SQL Server Express in rete locale.

> Dopo aver modificato il file dalla Web UI, copiarlo manualmente anche in `C:\EMailSender\ConsoleJob\appsettings.json`.

> All'avvio la Web UI verifica la completezza della configurazione e mostra un banner di avviso per ogni chiave mancante.

---

## 6. Configurazione SMTP

I parametri SMTP si configurano dalla Web UI (pagina **Config SMTP**) oppure direttamente via SQL:

```sql
INSERT INTO ConfigEmailServer
    (company, Smtp_Server, Smtp_Port, Smtp_Ssl, Smtp_StartTls,
     Smtp_Auth, Smtp_User, Smtp_Password, Smtp_Sender, Smtp_SenderAlias,
     IsDeliveryBlocked)
VALUES
    ('TenantName',
     'tenant-domain.mail.protection.outlook.com', 25,
     'N', 'N', 'N', '', '',
     'noreply@tenant-domain.com', 'Tenant Description',
     'N');
```

> **Office 365 relay anonimo**: `Smtp_Auth=N`, porta 25, nessun SSL/TLS. Il DKIM viene firmato direttamente da Office 365.

---

## 7. Task Scheduler — ConsoleJob

Usare lo script `ConsoleJobSetupJob.ps1` dalla cartella di installazione:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\ConsoleJobSetupJob.ps1 -TenantId "TenantName"
```

In alternativa manualmente:

- **Cartella Task Scheduler**: `\EasyWebParts`
- **Nome**: `EMailSenderJob for TenantName`
- **Esegui come**: `SYSTEM` con privilegi elevati
- **Trigger**: ogni 1 minuto, ripeti indefinitamente
- **Programma**: `C:\EMailSender\ConsoleJob\EMailSender.ConsoleJob.exe`
- **Argomenti**: `--company TenantName --batch 10`
- **Avvia in**: `C:\EMailSender\ConsoleJob\`

---

## 8. Avvio EMailSender.Web

### Servizio Windows — consigliato per produzione

```powershell
sc.exe create EMailSenderWeb binPath="C:\EMailSender\Web\EMailSender.Web.exe" start=auto DisplayName="EMailSender Web"
sc.exe start EMailSenderWeb
```

Per rimuovere:

```powershell
sc.exe stop EMailSenderWeb
sc.exe delete EMailSenderWeb
```

La Web UI è raggiungibile su `http://localhost:5000`. Per accesso da rete:

```
netsh advfirewall firewall add rule name="EMailSender Web" protocol=TCP dir=in localport=5000 action=allow
```

---

## 9. Aggiunta di un nuovo tenant

1. Creare i DB e le tabelle (vedi sezione 2)
2. Assegnare i permessi SQL a `NT AUTHORITY\SYSTEM` (vedi sezione 2.3)
3. Aprire la Web UI → pagina **Impostazioni Tenant** → **+ Nuovo tenant**
4. Compilare i campi e inserire le Connection Strings
5. Copiare `appsettings.json` aggiornato in `C:\EMailSender\ConsoleJob\`
6. Configurare SMTP dalla pagina **Config SMTP**
7. Creare il task in Task Scheduler con `ConsoleJobSetupJob.ps1 -TenantId "NuovoTenant"`

---

## 10. Troubleshooting

### Mail non spedite

1. Verificare `IsDeliveryBlocked` su `ConfigEmailServer` — deve essere `'N'`
2. Controllare il log file in `LogDirectory`
3. Controllare la tabella `log` nel DB di log
4. Dal Task Scheduler: **Cronologia** del task per vedere uscite/errori
5. Dalla Web UI: pagina **Monitor mail** → colonna Stato e messaggio errore

### Errore connessione SQL

- Verificare `TrustServerCertificate=True` nella connection string
- Verificare i permessi per `NT AUTHORITY\SYSTEM` (sezione 2.3)
- Testare la stringa con SSMS dallo stesso server

### Errore SMTP

- Usare il pulsante **Test invio mail** nella pagina **Config SMTP**
- Verificare che il relay Office 365 accetti connessioni dalla IP del server
- Porta 25 non autenticata richiede che l'IP del server sia whitelistato in Exchange Online

### Web UI non risponde

- Verificare che il servizio sia in esecuzione: `sc.exe query EMailSenderWeb`
- Riavviare il servizio con `RestartServices.ps1`
- Controllare Event Viewer → Registri di Windows → Applicazione per errori di avvio

### File di log non scritti

- Verificare che `LogDirectory` esista
- Verificare che `NT AUTHORITY\SYSTEM` abbia permessi di scrittura sulla cartella

### Banner warning configurazione

All'avvio la Web UI verifica automaticamente la configurazione. Se compare un banner giallo verificare:
- `DefaultTenants` presente in `appsettings.json`
- Per ogni tenant: entrambe le connection string presenti
- Per ogni tenant: `DisplayName` e `LogDirectory` valorizzati

---

*Fine guida*