# EMailSenderRobot_Blazor — Guida di installazione e configurazione

> Versione: settembre 2026 | Target: Windows Server 2019+, SQL Server (anche Express), .NET 8

---

## Changelog

| Data | Modifica |
|---|---|
| Settembre 2026 | **Blocco spedizioni per singolo tenant**: `IsDeliveryBlocked` viene ora verificato anche sulla company di ogni mail, non solo su quella passata con `--company`. Le mail dei tenant bloccati restano in coda senza consumare tentativi. Nuovo metodo `EmailRepository.MarkJobUnscheduled`. Comportamento invariato con un database per tenant |
| Settembre 2026 | Corretto `appsettings.Development.json`: le chiavi di configurazione erano annidate dentro `Logging` e non venivano lette |
| Settembre 2026 | **Revisione completa della guida per l'installazione su una macchina nuova.** Aggiunti: prerequisiti, layout dei database (DB per tenant *oppure* DB unico del robot), binding di rete di Kestrel, sezione `EmailJob`, dismissione di un tenant, appendice IIS, elenco delle discrepanze note tra codice e documentazione |
| Settembre 2026 | Nuovi script: `Install-EMailSender.ps1` (installazione completa), `New-EMailSenderTenant.ps1` (tenant end-to-end: DB, tabelle, permessi, SMTP, config, task), `Register-EMailSenderService.ps1` (servizio Windows + firewall), `Test-EMailSenderInstall.ps1` (diagnostica). `ConsoleJobSetupJob.ps1` è stato recuperato dal server e messo sotto versionamento |
| Maggio 2026 | Aggiunto campo `Language` in `ConfigEmailContent` — supporto multilingua con fallback automatico (lingua richiesta → EN → IT) |
| Maggio 2026 | Aggiunto `DefaultTenants` in `appsettings.json` — tenant speciali (Development, FMGroup) che ricevono copia vuota di ogni nuovo tipo mail |
| Maggio 2026 | Aggiunto `Deploy.ps1` per deploy automatico — ferma servizio, copia file (esclusi appsettings), riavvia |
| Maggio 2026 | Aggiunti script PS: `RestartServices.ps1`, `StartServices.ps1`, `StopServices.ps1` |
| Maggio 2026 | `publish.cmd` aggiornato — versione automatica, commit/tag Git, copia script PS in publish |

---

## Indice

1. [Architettura in due minuti](#1-architettura-in-due-minuti)
2. [Prerequisiti](#2-prerequisiti)
3. [Installazione passo passo](#3-installazione-passo-passo)
4. [Struttura della soluzione](#4-struttura-della-soluzione)
5. [Layout dei database](#5-layout-dei-database)
6. [Preparazione del database](#6-preparazione-del-database)
7. [Configurazione appsettings.json](#7-configurazione-appsettingsjson)
8. [Servizio Windows e binding di rete](#8-servizio-windows-e-binding-di-rete)
9. [Task Scheduler — ConsoleJob](#9-task-scheduler--consolejob)
10. [Configurazione SMTP](#10-configurazione-smtp)
11. [Aggiunta di un nuovo tenant](#11-aggiunta-di-un-nuovo-tenant)
12. [Dismissione di un tenant](#12-dismissione-di-un-tenant)
13. [Pubblicazione e deploy](#13-pubblicazione-e-deploy)
14. [Diagnostica](#14-diagnostica)
15. [Troubleshooting](#15-troubleshooting)
16. [Discrepanze note tra codice e configurazione](#16-discrepanze-note-tra-codice-e-configurazione)
17. [Appendice A — IIS](#appendice-a--iis)
18. [Appendice B — riferimento degli script](#appendice-b--riferimento-degli-script)

---

## 1. Architettura in due minuti

Il robot è composto da **due eseguibili** che condividono lo stesso database e la stessa configurazione, e non si parlano tra loro:

| Componente | Cos'è | Come gira |
|---|---|---|
| `EMailSender.Web` | Web UI Blazor Server: configurazione tenant, editor mail, monitor coda, log | **Servizio Windows** (Kestrel self-hosted). **Non richiede IIS** |
| `EMailSender.ConsoleJob` | Svuota la coda e spedisce via SMTP. Parte, lavora un batch, esce | **Task del Task Scheduler**, ogni minuto, come `SYSTEM` |

Chi produce le mail è un'**applicazione esterna** (il consumer: EasyWebParts, l'app FMGroup, ...) che scrive righe in `ConfigEmailJobSchedule`. Il robot non conosce il consumer: il contratto tra i due è la tabella di coda.

> ⚠️ **Il robot non elabora il corpo della mail: lo spedisce esattamente com'è.** Nessuna sostituzione di placeholder, nessun montaggio di header e footer, nessuna espansione di righe. Tutto questo è responsabilità dell'applicazione consumer.
>
> **Se devi collegare una tua applicazione al robot, la guida è [`INTEGRATION.md`](INTEGRATION.md)**: contratto della coda, uso della libreria `FMGroup.Mail`, quali placeholder sono sostituiti automaticamente e quali no, trappole note e checklist di integrazione.

**Multi-tenant**: una sola installazione serve N tenant. Ogni tenant è una voce in `Companies[]` più una coppia di connection string. Ciò che si moltiplica per tenant non è l'installazione, ma — secondo il layout scelto — il database e/o il task nello Scheduler.

---

## 2. Prerequisiti

Da verificare **prima** di copiare i file. `Install-EMailSender.ps1` controlla automaticamente i punti 1 e 2 e si ferma se mancano.

1. **ASP.NET Core 8 Runtime** — non basta il runtime .NET base. Verifica:
   ```powershell
   dotnet --list-runtimes | Select-String "AspNetCore.App 8"
   ```
   Se manca, installare `aspnetcore-runtime-8.x-win-x64.exe` (oppure il *Hosting Bundle* se sulla macchina serve anche IIS). Senza questo il servizio parte e muore subito con **errore 1067**.

2. **Privilegi di amministratore** — servono per `sc.exe`, `icacls`, Task Scheduler e firewall.

3. **SQL Server raggiungibile** (anche Express). Se l'istanza è su un'altra macchina: protocollo **TCP/IP abilitato** in SQL Server Configuration Manager e servizio **SQL Browser** avviato per le istanze nominate.

4. **Permessi SQL per l'account di servizio.** Entrambi i componenti girano come `NT AUTHORITY\SYSTEM`: è quello l'account da autorizzare sui database, non l'utente interattivo. Li concede `New-EMailSenderTenant.ps1`.

5. **Relay SMTP** raggiungibile dalla macchina. Con Office 365 in relay anonimo l'IP pubblico del server deve essere in whitelist su Exchange Online.

> **Nota sulla versione del runtime**: il publish è *framework-dependent*, quindi il runtime 8.x deve stare sulla macchina di destinazione. Non è self-contained.

---

## 3. Installazione passo passo

> ### La via rapida: un solo comando
>
> ```powershell
> # PowerShell come amministratore, dalla cartella publish
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> Get-ChildItem -Recurse | Unblock-File
>
> .\Setup-EMailSender.ps1
> ```
>
> `Setup-EMailSender.ps1` **fa tutto**: chiede i parametri all'inizio (cartella, accesso alla UI, prefisso, tenant, istanza SQL, layout dei database, SMTP), mostra un riepilogo, chiede **una sola conferma** e poi esegue installazione, tenant, i due task pianificati, riavvio del servizio e verifica finale. Dopo la conferma non fa altre domande.
>
> Il resto di questa sezione è la stessa cosa passo per passo, utile per capire cosa succede o per riprendere da un punto preciso quando qualcosa va storto.

> Questa sezione è scritta per essere seguita **alla lettera**, senza sapere nulla del progetto. Un'installazione si fa una volta ogni tanto: qui non si dà per scontato niente. Tempo richiesto: circa 20 minuti.
>
> Ogni passo dice **cosa fare**, **cosa devi vedere** se è andato bene e **cosa fare se non va**.

Prima di cominciare, decidi due cose (se non sai, usa i valori suggeriti):

| Devi decidere | Valore suggerito | Dove serve |
|---|---|---|
| Nome del tenant (codice breve, senza spazi e accenti) | `FMG` | passo 6 |
| Nome del database | `FMG_EmailSenderRobot` | passo 6 |

---

### Passo 1 — Controlla che ci sia il runtime .NET 8

Sul server, apri PowerShell (basta normale, non serve amministratore) e incolla:

```powershell
dotnet --list-runtimes | Select-String "AspNetCore.App 8"
```

✅ **Devi vedere** almeno una riga tipo `Microsoft.AspNetCore.App 8.0.30 [C:\Program Files\dotnet\shared\...]`.

❌ **Se non vedi niente** (o "dotnet non è riconosciuto"), scarica e installa **ASP.NET Core Runtime 8 — Hosting Bundle** da <https://dotnet.microsoft.com/download/dotnet/8.0> (sezione *Run server apps*, file `dotnet-hosting-8.x.x-win.exe`). Poi **riavvia il server** e ripeti questo passo.

> Senza questo, più avanti il servizio si installerà ma non partirà (errore 1067).

---

### Passo 2 — Controlla che ci sia SQL Server

```powershell
Get-Service | Where-Object { $_.Name -like "MSSQL*" } | Select-Object Name, Status
```

✅ **Devi vedere** almeno un servizio in stato `Running`, per esempio `MSSQL$SQLEXPRESS`.

📝 Al passo 6 lo script **rileva da solo le istanze presenti e ti chiede quale usare**, quindi non devi ricordartela. Per riconoscerla nell'elenco:
- `MSSQL$SQLEXPRESS` → l'istanza si scrive `.\SQLEXPRESS`
- `MSSQLSERVER` → l'istanza si scrive `.` (solo un punto)
- SQL su un'altra macchina → si scrive `NOMESERVER` oppure `NOMESERVER\ISTANZA`

❌ **Se non c'è nessun servizio SQL**, installa SQL Server Express da <https://www.microsoft.com/sql-server/sql-server-downloads> (scegli *Basic*), poi riprendi da qui.

---

### Passo 3 — Copia la cartella sul server

Copia l'intera cartella `publish\` (quella che contiene `Web\`, `ConsoleJob\` e i file `.ps1`) in una cartella temporanea del server, per esempio `C:\Temp\publish\`.

✅ **Devi vedere** dentro `C:\Temp\publish\` almeno: la cartella `Web`, la cartella `ConsoleJob`, e i file `Install-EMailSender.ps1`, `New-EMailSenderTenant.ps1`, `Test-EMailSenderInstall.ps1`, `ConsoleJobSetupJob.ps1`.

> Non copiare in `C:\EMailSender`: quella cartella la crea l'installazione. `C:\Temp\publish` è solo il punto di partenza.

---

### Passo 4 — Apri PowerShell **come amministratore** e sblocca i file

Tasto destro sul pulsante Start → **Windows PowerShell (amministratore)** → Sì.

✅ **Devi vedere** che il titolo della finestra comincia con **Amministratore:**. Se non c'è, chiudi e rifai: senza questo i passi seguenti falliscono.

Ora incolla queste tre righe, una alla volta:

```powershell
cd C:\Temp\publish
Get-ChildItem -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

> La seconda riga toglie il "marchio di file scaricato da rete" che Windows mette e che altrimenti blocca gli script. La terza permette di eseguire script solo in **questa** finestra: chiudendola, tutto torna come prima.

---

### Passo 5 — Installa

Una riga sola:

```powershell
.\Install-EMailSender.ps1
```

✅ **Devi vedere** una sequenza di passi da `=== 1. Prerequisiti ===` a `=== 7. Avvio del servizio ===` con scritte verdi, e alla fine il riquadro `Installazione completata in C:\EMailSender`.

Se ti serve che la pagina web sia raggiungibile **da altri PC** e non solo dal server, usa invece questa riga (prima leggi l'avvertenza in §8.2 sull'assenza di password):

```powershell
.\Install-EMailSender.ps1 -Urls "http://*:5000"
```

❌ **Se si ferma con un errore rosso**, il messaggio dice cosa manca (di solito è il passo 1 o i privilegi di amministratore). Risolvi e rilancia la stessa riga: rieseguire lo script è sicuro, non rompe niente.

---

### Passo 6 — Crea il tenant (database + tabelle + configurazione + attività pianificata)

Sostituisci solo i valori tra virgolette con quelli che hai deciso all'inizio, e incolla **tutto insieme** (sono due righe che formano un comando solo; il backtick a fine riga significa "il comando continua"):

```powershell
.\New-EMailSenderTenant.ps1 -TenantName "FMG" -DisplayName "FM Group" `
    -SharedDatabase -MainDbName "FMG_EmailSenderRobot" -CreateTask
```

✅ **Prima cosa, ti chiede l'istanza SQL**, mostrando quelle che ha trovato sulla macchina con il relativo stato del servizio:

```
=== Istanza SQL Server ===
    Istanze rilevate su questa macchina:
      .\SQLEXPRESS         [Running]

    Istanza da usare [.\SQLEXPRESS]:
```

Premi invio per accettare quella proposta, oppure scrivine un'altra.

**Se sulla macchina ci sono più istanze**, non viene proposto nessun default e la scelta è obbligatoria, per numero o per nome:

```
    Rilevate 3 istanze su questa macchina:
      [1] .                        [Running]  (istanza predefinita)
      [2] .\SQLEXPRESS             [Running]
      [3] .\SQL2019                [Stopped]

    Nessuna scelta predefinita: indicare quale usare.

    Istanza da usare (1-3 oppure nome):
```

È voluto: con più motori sulla stessa macchina, un invio dato per abitudine creerebbe i database su quello sbagliato. Puoi rispondere con il numero, oppure scrivere un nome che non è in elenco — per esempio un server remoto, che il rilevamento locale non vede.

In tutti i casi lo script prova subito la connessione e ti dice versione ed edizione del server: se sbagli, te lo dice **prima** di creare qualsiasi cosa e puoi correggere senza rilanciare tutto.

✅ Poi **devi vedere** i passi da `=== 1. Database ===` a `=== 7. Task Scheduler ===`, e alla fine `Tenant 'FMG' predisposto.`

> Se l'istanza la sai già e vuoi evitare la domanda (o stai automatizzando), passala con `-SqlInstance ".\SQLEXPRESS"`: in quel caso un errore di connessione interrompe subito lo script invece di richiedere il valore.

Cosa ha fatto, in parole semplici: ha creato il database, ci ha messo dentro le 5 tabelle, ha dato i permessi a Windows per leggerle e scriverle, ha creato la cartella dei log, ha scritto la configurazione nei due file che servono, e ha creato l'attività pianificata che ogni minuto controlla se ci sono mail da mandare.

❌ **Se la connessione fallisce**, lo script te lo dice e ti lascia riprovare con un'altra istanza (fino a tre tentativi). Le cause tipiche: servizio SQL fermo (lo vedi nell'elenco, stato diverso da `Running`), nome sbagliato, oppure — per un SQL su un'altra macchina — TCP/IP disabilitato o servizio SQL Browser non avviato.

---

### Passo 7 — Riavvia il servizio e apri la pagina web

```powershell
Restart-Service EMailSenderWeb
Start-Process "http://localhost:5000"
```

✅ **Devi vedere** aprirsi il browser con l'interfaccia **EMailSender** e, nel menu in alto, le voci Monitor, Log, Email Editor, Impostazioni Tenant, Config SMTP. Il tenant che hai creato deve comparire nell'elenco.

❌ **Se il browser dice che non riesce a connettersi**, il servizio non è partito: vai a §15 → *Il servizio non parte*.

---

### Passo 8 — Inserisci i dati del server di posta

Nella pagina web: **Config SMTP** → seleziona il tenant → compila:

| Campo | Cosa mettere | Esempio |
|---|---|---|
| Smtp Server | l'indirizzo del server di posta in uscita | `fmgsrl-com.mail.protection.outlook.com` |
| Porta | quasi sempre 25 | `25` |
| SSL / StartTls / Auth | lasciali su No con il relay Office 365 | No, No, No |
| Mittente | l'indirizzo da cui partono le mail | `noreply@fmgsrl.com` |
| Alias mittente | il nome che vede il destinatario | `FM Group` |

Salva, poi usa il pulsante **Test invio mail**.

✅ **Devi vedere** un messaggio di esito positivo e ricevere la mail di prova.

❌ **Se dà errore**, vai a §15 → *Errore SMTP*. Il caso più comune con Office 365 è l'IP del server non abilitato al relay.

---

### Passo 9 — Verifica finale

```powershell
cd C:\EMailSender
.\Test-EMailSenderInstall.ps1
```

✅ **Devi vedere** un elenco di righe `[OK]` verdi e in fondo `Esito: N OK, 0 warning, 0 errori`.

Qualche `[WARN]` giallo è tollerabile (te lo spiega la riga stessa). Ogni `[ERR]` rosso va risolto: la riga dice esattamente cosa manca.

---

### Fatto. Riepilogo di cosa hai adesso

- Un servizio Windows **EMailSenderWeb** che parte da solo ad ogni riavvio del server e ospita la pagina web su `http://localhost:5000`
- Un'attività pianificata che ogni minuto spedisce le mail in coda
- Un database con le 5 tabelle
- Due file di configurazione allineati tra loro

**Da qui in avanti**: per aggiungere un altro tenant vedi §11, per aggiornare il software a una nuova versione vedi §13.3 (si usa `Deploy.ps1`, non si rifà l'installazione).

> **Se qualcosa non funziona più tra sei mesi**: il primo comando da lanciare è sempre `C:\EMailSender\Test-EMailSenderInstall.ps1`. Dice da solo cos'è cambiato.

---

## 4. Struttura della soluzione

Sul server, dopo l'installazione:

```
C:\EMailSender\
├── Web\                          ← EMailSender.Web (servizio Windows)
│   └── appsettings.json          ← configurazione della Web UI
├── ConsoleJob\                   ← EMailSender.ConsoleJob (task)
│   └── appsettings.json          ← SECONDA copia della configurazione
├── Install-EMailSender.ps1       ← installazione completa
├── New-EMailSenderTenant.ps1     ← predisposizione di un tenant
├── Register-EMailSenderService.ps1 ← crea/aggiorna/rimuove il servizio
├── ConsoleJobSetupJob.ps1        ← crea/rimuove il task di un tenant
├── Test-EMailSenderInstall.ps1   ← diagnostica
├── StartServices.ps1             ← avvia EMailSenderWeb
├── StopServices.ps1              ← ferma EMailSenderWeb
├── RestartServices.ps1           ← ferma e riavvia EMailSenderWeb
└── ReadMe.md                     ← questa guida
```

> Le **due** copie di `appsettings.json` sono indipendenti e il deploy non le sovrascrive mai. La Web UI scrive solo sulla propria: la divergenza tra le due è il guasto più frequente dell'installazione. `New-EMailSenderTenant.ps1` le aggiorna entrambe, `Test-EMailSenderInstall.ps1` ne verifica la coerenza.

---

## 5. Layout dei database

Due modelli, entrambi supportati **senza modifiche al codice**. La scelta va fatta prima di creare i database.

> **Il database del robot è sempre un database a sé**, distinto da quello applicativo del tenant. Nelle installazioni storiche le 5 tabelle vivono dentro il database principale dell'applicazione (`Ewp_DemoCompany_MainDb`): non farlo più. Separarlo rende i template copiabili fra ambienti, il backup indipendente dai dati del cliente e il robot installabile ovunque senza dipendere da un'applicazione.

### 5.1 Un database per tenant

```
<Prefisso><Tenant>_Mail      → 4 tabelle di configurazione e coda
<Prefisso><Tenant>_MailLog   → tabella log
```

Esempio: `EWP_EasyLift_Mail` e `EWP_EasyLift_MailLog`.

Il **prefisso** dice a quale progetto/prodotto appartengono i database (`EWP_` per EasyWebParts, `FMG_` per i progetti interni) e viene chiesto dallo script. Il suffisso è `_Mail`, non `_Main`: `_Main` è il database **applicativo** del tenant, che con il robot non c'entra.

- Isolamento totale tra clienti: la dismissione è un `DROP DATABASE`, il restore di un cliente non tocca gli altri.
- Serve **un task per tenant**, perché ognuno punta a un database diverso.
- È il modello in produzione su EasyWebParts.

### 5.2 Un database unico per il robot

```
<Prefisso>EMailSenderRobot     → tutte e 5 le tabelle, tutti i tenant
```

Esempio: `FMG_EMailSenderRobot`. Qui il nome **non contiene il tenant**, di proposito: i clienti aggiunti in seguito finirebbero in un database che porta il nome del primo.

Le chiavi `<Tenant>_Main` e `<Tenant>_Log` sono due voci di configurazione indipendenti: **nulla vieta di farle puntare allo stesso database**. Le 5 tabelle non collidono e sono già multi-tenant per schema (colonna `Company`/`company` nella chiave logica; in `ConfigEmailServer` è addirittura la chiave primaria).

- Gestione più semplice: un database, un backup, **un solo task per tutti i tenant** (vedi §9.2).
- La dismissione di un cliente è un `DELETE ... WHERE Company = '<Tenant>'` sulle 5 tabelle (vedi §12).
- Il blocco delle spedizioni resta **selettivo per cliente**: `IsDeliveryBlocked` viene verificato su ogni singola mail, non solo all'avvio del job (vedi §16.2).
- **Unico vincolo**: in questo layout serve **un solo task**. Più task concorrenti sulla stessa coda producono invii duplicati — vedi §9.2 e §16.1.

### 5.3 Il prefisso del nome database non è cablato

Il prefisso `Ewp_` è **solo una convenzione di naming di EasyWebParts**. Il codice non lo conosce: usa unicamente le *chiavi* di configurazione `<Tenant>_Main` e `<Tenant>_Log` (`ConsoleJob/Program.cs`, `ConfigService.SaveCompany`), e il nome del database vive solo dentro la connection string. I database si possono chiamare come si vuole.

L'unico vincolo reale: **`Companies[].Name` deve coincidere esattamente con il prefisso delle due chiavi di connection string** e con il valore passato a `--company`.

---

## 6. Preparazione del database

Normalmente non serve eseguire SQL a mano: `New-EMailSenderTenant.ps1` crea database, tabelle, indici e permessi in modo idempotente. Questa sezione documenta lo schema di riferimento.

### 6.1 Creazione del database

```sql
CREATE DATABASE [FMG_EmailSenderRobot];
```

### 6.2 Tabelle di configurazione e coda (database principale)

```sql
-- Coda mail: qui scrive l'applicazione consumer, da qui legge il ConsoleJob
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

-- Indice a supporto del prelievo del batch
CREATE INDEX IX_ConfigEmailJobSchedule_Pending
    ON ConfigEmailJobSchedule (IsScheduled, SentTimeStamp, IsError, EmailId)
    INCLUDE (Company);

-- Configurazione SMTP: una riga per tenant
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

-- Contenuto mail. Chiave logica: Company + Type + Language
-- Language: codice ISO 639-1 (IT, EN, DE, FR, ES)
-- Fallback automatico in lettura: lingua richiesta → EN → IT
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

-- Indirizzi mail. Chiave logica: Company + Type
-- EmailTO = 'Utente Specifico' se il destinatario arriva dal codice chiamante
CREATE TABLE ConfigEmailAddress (
    Company     NVARCHAR(15)   NULL,
    Type        NVARCHAR(512)  NULL,
    EmailTO     NVARCHAR(512)  NULL,
    EmailCC     NVARCHAR(512)  NULL,
    EmailCCN    NVARCHAR(512)  NULL,
    Description NVARCHAR(512)  NULL
);
```

> `IsDeliveryBlocked = 'S'` blocca le spedizioni del tenant. È **l'unico flag di blocco effettivamente letto dal ConsoleJob** (vedi §16.2). Si gestisce dalla pagina **Impostazioni Tenant** della Web UI.

> `EmailBodyRowRepeater` è un template HTML di una singola riga (es. `<tr>`) con placeholder `#CAMPO#`. Il codice applicativo lo espande in loop e sostituisce il placeholder `#ELEMENTLIST#` nel corpo mail.

> Elenco completo dei placeholder disponibili (per tipo di mail e progetto consumer): vedi `PLACEHOLDERS.md` in questa stessa cartella. **Copia duplicata e sincronizzata manualmente** con `FMGroup.Mail/PLACEHOLDERS.md` — aggiornare entrambe le copie ad ogni modifica.

> **Limite noto dell'anteprima nell'Email Editor:** sostituisce solo 4 placeholder generici hardcoded (`#PRODOTTO#`, `#QTY#`, `#PREZZO#`, `#ELEMENTLIST#`) — i placeholder di dominio specifico (es. `#TOTALEORDINE#`, `#USERNAME#`, `#IMG_...#`) compaiono grezzi in anteprima. Dettagli: `PLACEHOLDERS_PREVIEW_GAP.md`.

### 6.3 Tabella di log (database di log)

Nel layout a database unico va creata nello stesso database delle altre.

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

CREATE INDEX IX_log_company_ts ON log (company, [TimeStamp] DESC);
```

### 6.4 Permessi SQL

Entrambi i componenti girano come `NT AUTHORITY\SYSTEM`. Su **ogni** database usato:

```sql
USE [FMG_EmailSenderRobot];
CREATE USER [NT AUTHORITY\SYSTEM] FOR LOGIN [NT AUTHORITY\SYSTEM];
ALTER ROLE db_datareader ADD MEMBER [NT AUTHORITY\SYSTEM];
ALTER ROLE db_datawriter ADD MEMBER [NT AUTHORITY\SYSTEM];
```

Se il login non esiste a livello di istanza:

```sql
CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
```

> Con SQL Server su una **macchina diversa** da quella del robot, `NT AUTHORITY\SYSTEM` non è utilizzabile: l'accesso in rete va fatto con l'account computer (`DOMINIO\NOMEMACCHINA$`) oppure con autenticazione SQL, mettendo utente e password nella connection string.

---

## 7. Configurazione appsettings.json

### 7.1 Dove sta e chi la scrive

Il file esiste in **due copie indipendenti**:

- `C:\EMailSender\Web\appsettings.json` — letta *e riscritta* dalla Web UI
- `C:\EMailSender\ConsoleJob\appsettings.json` — letta dal job ad ogni esecuzione

Fatti da conoscere, tutti verificati sul codice:

- **Il publish non produce un `appsettings.json` utilizzabile.** `EMailSender.Web.csproj` marca `appsettings.json` come `CopyToPublishDirectory=Never` e pubblica solo `appsettings.Production.json`, che ha `ConnectionStrings` e `Companies` vuoti. Il progetto `EMailSender.ConsoleJob` **non contiene alcun `appsettings.json`**, e `Program.cs` lo carica con `optional: false`: se il file manca, il job termina con un'eccezione ad ogni esecuzione. I due file vanno quindi creati sul server — lo fa `Install-EMailSender.ps1`.
- **Il nome del file è fisso.** `ConfigService` legge e riscrive sempre `appsettings.json` (`Web/Program.cs`), non il file dell'environment: un `appsettings.Production.json` da solo non basta e non viene mai aggiornato dalla UI.
- Se nella cartella `Web\` resta un `appsettings.Production.json`, `IConfiguration` lo unisce ad `appsettings.json` (l'environment di un servizio Windows è `Production`). Non è dannoso, ma in diagnosi confonde: meglio rimuoverlo.
- **La Web UI non rilegge la configurazione a caldo** per le chiavi di avvio: dopo modifiche fatte a mano, riavviare il servizio.

### 7.2 appsettings.json della Web UI

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "Urls": "http://localhost:5000",
  "IsBlocked": false,
  "ConnectionStrings": {
    "FMG_Main": "data source=.\\SQLEXPRESS;Integrated Security=SSPI;Connection Timeout=60;Database=FMG_EmailSenderRobot;TrustServerCertificate=True",
    "FMG_Log":  "data source=.\\SQLEXPRESS;Integrated Security=SSPI;Connection Timeout=60;Database=FMG_EmailSenderRobot;TrustServerCertificate=True"
  },
  "Companies": [
    {
      "Name": "FMG",
      "DisplayName": "FM Group",
      "BatchSize": 10,
      "MaxRetryCount": 2,
      "LogDirectory": "C:\\EMailSenderData\\FMG\\Log",
      "BackupCompany": "",
      "BackupEmailType": "",
      "SqlConfigTableServer": "ConfigEmailServer",
      "SemaphoreFilePath": ""
    }
  ],
  "DefaultTenants": [ "Development", "FMGroup" ]
}
```

### 7.3 appsettings.json del ConsoleJob

Stesse `ConnectionStrings` e stesso `Companies` della Web UI, **più** la sezione `EmailJob`, che è letta solo qui:

```json
{
  "EmailJob": {
    "MaxRetryCount": 2,
    "DefaultCompany": ""
  }
}
```

### 7.4 Riferimento dei campi

| Campo | Letto da | Descrizione |
|---|---|---|
| `Urls` | Web | Binding di Kestrel. **Assente = solo loopback** (vedi §8) |
| `{Name}_Main` | Web + Job | Connection string al DB di configurazione e coda |
| `{Name}_Log` | Web + Job | Connection string al DB di log. Può puntare allo stesso database di `_Main` |
| `Name` | Web + Job | Codice interno del tenant: deve coincidere col prefisso delle connection string e con `--company` |
| `DisplayName` | Web | Nome visualizzato nella UI |
| `BatchSize` | Job | Mail elaborate per esecuzione. Sovrascrivibile con `--batch` |
| `MaxRetryCount` | *nessuno* | **Ignorato dal job**, che usa `EmailJob:MaxRetryCount` (vedi §16.3) |
| ~~`LogRetentionDays`~~ | *rimosso* | La conservazione non è più per tenant: la decide il task giornaliero di pulizia (60 giorni, file e database) |
| `LogDirectory` | Job | Cartella dei file di log. Se vuoto: `<cartella exe>\Logs` |
| `SqlConfigTableServer` | Web + Job | Nome della tabella SMTP (default `ConfigEmailServer`) |
| `SemaphoreFilePath` | *nessuno* | **Non letto da nessun componente** (vedi §16.2) |
| `IsBlocked` | *nessuno* | Toggle globale scritto dalla UI ma **non letto dal job** (vedi §16.2) |
| `DefaultTenants` | Web | Tenant che ricevono copia vuota di ogni nuovo tipo mail creato |
| `EmailJob:MaxRetryCount` | Job | Tentativi massimi prima di annullare una mail |
| `EmailJob:DefaultCompany` | Job | Tenant usato se manca `--company` |

> `TrustServerCertificate=True` è di fatto obbligatorio con SQL Server Express in rete locale.

---

## 8. Servizio Windows e binding di rete

### 8.1 Registrazione

```powershell
.\Register-EMailSenderService.ps1
```

Lo script è idempotente (se il servizio esiste lo riconfigura), lo registra come `LocalSystem` con avvio automatico e imposta il **recovery automatico** dopo un crash. Per rimuoverlo:

```powershell
.\Register-EMailSenderService.ps1 -Remove
```

Equivalente manuale:

```powershell
sc.exe create EMailSenderWeb binPath= "C:\EMailSender\Web\EMailSender.Web.exe" start= auto obj= LocalSystem DisplayName= "EMailSender Web"
sc.exe start EMailSenderWeb
```

### 8.2 Il binding è la parte che si dimentica

Senza la chiave `Urls` in `appsettings.json`, Kestrel ascolta **solo su loopback**: `127.0.0.1:5000` e `[::1]:5000`. La UI risponde su `http://localhost:5000/` dalla macchina stessa e **nessuna regola firewall la rende raggiungibile da fuori** — è la configurazione in essere sui server attuali, dove la UI si usa in locale via desktop remoto.

Per l'accesso da rete servono **due** cose:

```jsonc
// 1. in C:\EMailSender\Web\appsettings.json
"Urls": "http://*:5000"
```

```powershell
# 2. regola firewall (la crea Register-EMailSenderService.ps1 se il binding non è loopback)
New-NetFirewallRule -DisplayName "EMailSender Web (5000)" -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 5000 -Profile Any
```

Dopo la modifica: `Restart-Service EMailSenderWeb`. Verifica di cosa sta effettivamente ascoltando:

```powershell
Get-NetTCPConnection -State Listen -OwningProcess (Get-Process EMailSender.Web).Id |
    Select-Object LocalAddress, LocalPort
```

> La Web UI **non ha autenticazione**: esporla in rete significa dare a chiunque la raggiunga l'accesso a configurazioni SMTP e contenuti mail. Esporla solo su rete interna, o tenerla su loopback e raggiungerla via desktop remoto (è la scelta attuale).

---

## 9. Task Scheduler — ConsoleJob

### 9.1 Creazione

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\ConsoleJobSetupJob.ps1 -TenantId "FMG"
```

Lo script è idempotente e accetta `-InstallRoot`, `-TaskFolder`, `-BatchSize`, `-IntervalMinutes`, `-Remove`. Caratteristiche del task creato:

| Proprietà | Valore |
|---|---|
| Cartella | `\EMailSender` (default dello script) — sui server EasyWebParts la convenzione storica è `\EasyWebParts` |
| Nome | `EMailSenderJob for <Tenant>` |
| Esegui come | `SYSTEM` (SID `S-1-5-18`), privilegi elevati |
| Trigger | ogni 1 minuto, ripetizione **illimitata** |
| Programma | `C:\EMailSender\ConsoleJob\EMailSender.ConsoleJob.exe` |
| Argomenti | `--company <Tenant> --batch 10` |
| Avvia in | `C:\EMailSender\ConsoleJob\` |
| Istanze multiple | `IgnoreNew` — se un'esecuzione è in corso la successiva viene saltata |

> `IgnoreNew` è la protezione contro il doppio invio: `MarkJobsAsScheduled` e `GetScheduledJobs` sono due statement separati senza transazione, quindi due esecuzioni sovrapposte dello **stesso** task potrebbero prendere le stesse righe. Non toccare questa impostazione.

### 9.2 Quanti task servono

| Layout | Task necessari |
|---|---|
| Un DB per tenant | **Uno per tenant**: ognuno punta a un database diverso |
| DB unico del robot | **Uno solo per tutti.** Il ciclo di spedizione non filtra per company: una singola esecuzione svuota la coda di tutti i tenant risolvendo la configurazione SMTP riga per riga (`GetServerConfig(job.Company)`). `--company` serve solo a risolvere connection string, batch e cartella di log |

> Nel layout a DB unico **non** creare un task per tenant: più task concorrenti sulla stessa coda senza filtro per company producono invii duplicati e aggirano il blocco spedizioni degli altri tenant. Vedi §16.1.

---

## 10. Configurazione SMTP

Dalla Web UI (pagina **Config SMTP**), oppure via SQL:

```sql
INSERT INTO ConfigEmailServer
    (company, Smtp_Server, Smtp_Port, Smtp_Ssl, Smtp_StartTls,
     Smtp_Auth, Smtp_User, Smtp_Password, Smtp_Sender, Smtp_SenderAlias,
     IsDeliveryBlocked)
VALUES
    ('FMG',
     'fmgsrl-com.mail.protection.outlook.com', 25,
     'N', 'N', 'N', '', '',
     'noreply@fmgsrl.com', 'FM Group',
     'N');
```

> **Senza la riga in `ConfigEmailServer` ogni mail del tenant va in errore** con "Config SMTP non trovata": è la prima cosa da controllare quando un tenant nuovo non spedisce.

> **Office 365 relay anonimo**: `Smtp_Auth='N'`, porta 25, nessun SSL/TLS. Il DKIM lo firma Office 365. Richiede l'IP del server in whitelist su Exchange Online.

---

## 11. Aggiunta di un nuovo tenant

Con lo script (fa tutto, è idempotente):

```powershell
# Layout a DB unico: nessun task nuovo, quello esistente serve anche questo tenant
.\New-EMailSenderTenant.ps1 -TenantName "Acme" -DisplayName "Acme Spa" `
    -SharedDatabase -MainDbName "FMG_EMailSenderRobot"

# Layout a DB per tenant: serve anche il task.
# Senza -DbPrefix e senza -MainDbName lo script chiede il prefisso e mostra i
# nomi che userebbe (EWP_Acme_Mail / EWP_Acme_MailLog) chiedendo conferma.
.\New-EMailSenderTenant.ps1 -TenantName "Acme" -DisplayName "Acme Spa" -CreateTask
```

Cosa fa, nell'ordine: crea i database mancanti → crea le 5 tabelle e gli indici → concede login/utente/ruoli a `NT AUTHORITY\SYSTEM` → inserisce la riga in `ConfigEmailServer` se manca → crea la cartella di log con i permessi di scrittura → aggiorna **entrambi** gli `appsettings.json` (con backup datato) → crea il task se richiesto.

Restano a carico dell'operatore: i parametri SMTP (se non passati allo script) e il riavvio del servizio Web.

Sequenza manuale equivalente, se serve farla a mano: §6.1 → §6.2 → §6.3 → §6.4 → §7 su **entrambi** i file → §10 → §9.

---

## 12. Dismissione di un tenant

Cosa va rimosso dipende dal layout, ma **quattro passi sono comuni**:

1. Rimuovere il task: `.\ConsoleJobSetupJob.ps1 -TenantId "Acme" -Remove`
2. Rimuovere il tenant dalla Web UI (pagina **Impostazioni Tenant**): elimina la voce `Companies[]` e le due connection string dal solo `appsettings.json` della Web
3. Riportare la stessa rimozione su `C:\EMailSender\ConsoleJob\appsettings.json`
4. Eliminare la cartella dei file di log (`LogDirectory`) e gli allegati: `EmailAttachments` contiene **percorsi su disco**, non blob, quindi i file restano sul filesystem

Poi, sui dati:

**Layout a DB per tenant**

```sql
DROP DATABASE [EWP_Acme_Mail];
DROP DATABASE [EWP_Acme_MailLog];
```

**Layout a DB unico**

```sql
USE [FMG_EmailSenderRobot];
DELETE FROM ConfigEmailJobSchedule WHERE Company = 'Acme';
DELETE FROM ConfigEmailContent     WHERE Company = 'Acme';
DELETE FROM ConfigEmailAddress     WHERE Company = 'Acme';
DELETE FROM ConfigEmailServer      WHERE company = 'Acme';
DELETE FROM log                    WHERE company = 'Acme';
```

> Differenza pratica tra i due: il `DROP` è atomico e verificabile, e permette il **restore di un singolo cliente** senza toccare gli altri. Con il database unico un ripristino selettivo diventa un'operazione chirurgica sulle 5 tabelle.

---

## 13. Pubblicazione e deploy

### 13.1 Pubblicazione (macchina di sviluppo)

Dalla cartella `src\EMailSenderRobot_Blazor\` eseguire `publish.cmd`. Il comando compila in Release, pubblica in `publish\Web\` e `publish\ConsoleJob\`, assegna la versione automatica `1.YY.MMDD.HHmm`, esegue commit e tag Git e copia in `publish\` gli script di installazione e questa guida.

### 13.2 Primo deploy su una macchina nuova

Vedi §3: si copia la cartella `publish\` sul server e si esegue `Install-EMailSender.ps1`.

### 13.3 Aggiornamento di un'installazione esistente

1. Copiare la cartella `publish\` sul server (o usare una cartella di rete)
2. Eseguire `Deploy.ps1` come amministratore

`Deploy.ps1` ferma il servizio, copia i file da `publish\Web\` e `publish\ConsoleJob\` nelle rispettive cartelle **senza sovrascrivere alcun `appsettings*.json`**, aggiorna gli script di gestione e la guida in `C:\EMailSender\`, poi riavvia il servizio.

> `Deploy.ps1` è per gli **aggiornamenti**: presuppone che il servizio esista già. Su una macchina nuova va usato `Install-EMailSender.ps1`.

---

## 14. Diagnostica

```powershell
.\Test-EMailSenderInstall.ps1                       # tutti i tenant
.\Test-EMailSenderInstall.ps1 -TenantName "FMG"     # un tenant solo
```

Di sola lettura. Verifica in un colpo solo: runtime, eseguibili e loro versione, validità e **coerenza reciproca dei due `appsettings.json`**, binding e porte in ascolto, stato e modalità di avvio del servizio, task presenti ed esito dell'ultima esecuzione, connessione SQL, presenza delle 5 tabelle, riga SMTP, flag di blocco, stato della coda, scrivibilità della cartella di log e data dell'ultimo file scritto. Esce con codice 1 se trova errori.

---

## 15. Troubleshooting

### Le mail non partono

Nell'ordine:

1. `.\Test-EMailSenderInstall.ps1` — copre i punti seguenti automaticamente
2. `IsDeliveryBlocked` su `ConfigEmailServer` deve essere `'N'`
3. Il tenant esiste in **entrambi** gli `appsettings.json`? Se sta solo in quello della Web UI, il job non lo vede
4. Esiste la riga in `ConfigEmailServer` per quella company?
5. Il task è presente, abilitato, e l'ultima esecuzione è finita con `0x0`? (Task Scheduler → **Cronologia**; se disattivata, attivarla)
6. File di log in `LogDirectory` e tabella `log` sul DB
7. Web UI → **Monitor mail**: colonna Stato e messaggio di errore

### Il servizio non parte (errore 1067)

Quasi sempre manca il **runtime ASP.NET Core 8** (il runtime .NET base non basta), oppure `appsettings.json` non è JSON valido. Verificare con `dotnet --list-runtimes` e nel Visualizzatore eventi → Registri di Windows → Applicazione.

### La Web UI risponde in locale ma non da rete

Manca la chiave `Urls` in `appsettings.json`: Kestrel è in ascolto solo su loopback e la regola firewall da sola non serve. Vedi §8.2.

### Il ConsoleJob termina subito senza scrivere nulla

- Manca `appsettings.json` nella cartella `ConsoleJob\`: viene caricato con `optional: false`, quindi il processo muore prima di poter loggare
- Oppure manca la connection string `<Tenant>_Main` / `<Tenant>_Log`: in questo caso l'errore è nel file di log
- Oppure `IsDeliveryBlocked='S'`: uscita immediata con un avviso nel file di log

### Errore di connessione SQL

- `TrustServerCertificate=True` presente nella connection string?
- Permessi di `NT AUTHORITY\SYSTEM` sui database (§6.4)?
- Istanza su un'altra macchina: TCP/IP abilitato, SQL Browser avviato, e `SYSTEM` non è utilizzabile in rete (§6.4)
- Provare la stringa con SSMS *dallo stesso server*

### Errore SMTP

- Pulsante **Test invio mail** nella pagina **Config SMTP**
- Il relay accetta connessioni dall'IP del server? Con Office 365 e porta 25 non autenticata l'IP deve essere in whitelist su Exchange Online

### La Web UI non risponde

```powershell
sc.exe query EMailSenderWeb        # stato
.\RestartServices.ps1              # riavvio
```
Poi Visualizzatore eventi → Registri di Windows → Applicazione.

### I file di log non vengono scritti

`LogDirectory` esiste e `NT AUTHORITY\SYSTEM` ha permesso di scrittura? `FileLogger` **ingoia gli errori di scrittura in silenzio** (try/catch senza rilancio), quindi un problema di ACL non lascia alcuna traccia. `Test-EMailSenderInstall.ps1` fa una prova di scrittura reale.

### Banner giallo di warning nella Web UI

All'avvio la UI valida la configurazione. Verificare: `DefaultTenants` presente e non vuoto, e per ogni tenant `DisplayName`, `LogDirectory` e le due connection string valorizzate.

### Modifiche fatte dalla Web UI che "non prendono"

La UI scrive solo su `C:\EMailSender\Web\appsettings.json`. Ogni modifica a tenant e connection string va riportata a mano sulla copia del ConsoleJob (o rieseguito `New-EMailSenderTenant.ps1`, che aggiorna entrambe).

---

## 16. Discrepanze note tra codice e configurazione

Rilevate a settembre 2026 leggendo il codice. Non sono bug bloccanti nella configurazione attuale (un tenant per database, un task per tenant), ma vanno conosciute prima di cambiare layout.

### 16.1 Il ciclo di spedizione non filtra per company

`EmailRepository.MarkJobsAsScheduled` e `EmailRepository.GetScheduledJobs` prendono le righe della coda **senza `WHERE Company`**. Il mittente viene poi risolto riga per riga, quindi con un solo task il comportamento è corretto e desiderabile (una passata svuota la coda di tutti).

Diventa un problema solo con **DB condiviso + più task attivi insieme**: il task di un tenant preleva anche le righe degli altri, e soprattutto si crea un rischio di **doppio invio** (un task marca le righe, un altro le legge tutte prima che il primo le abbia spedite). Il blocco delle spedizioni, invece, non è più aggirabile: da settembre 2026 è verificato per singola mail (§16.2).

Rimedio, se un giorno servisse davvero quella combinazione: aggiungere il filtro per company alle due query. Finché si usa **un solo task** non serve.

### 16.2 Due dei tre meccanismi di blocco non sono collegati

| Meccanismo | Dove | Letto dal ConsoleJob |
|---|---|---|
| `ConfigEmailServer.IsDeliveryBlocked` | DB, per tenant | **Sì**, in due punti: all'avvio per la company di `--company`, e su **ogni singola mail** per la company della riga |
| `IsBlocked` | `appsettings.json`, toggle globale nella UI | **No** — scritto da `ConfigService.SetBlocked`, mai letto |
| `SemaphoreFilePath` / `IsSemaphoreRed` | `appsettings.json`, per tenant | **No** — proprietà calcolata, nessun consumer |

Il solo blocco funzionante è quindi il primo, ed è quello gestito dalla pagina **Impostazioni Tenant**. Funziona su due livelli:

- **interruttore generale** — se è bloccata la company passata con `--company`, il job esce subito senza elaborare nulla;
- **blocco del singolo cliente** — le mail dei tenant bloccati vengono saltate una per una e restano in coda **senza consumare un tentativo**, così ripartono da sole quando il blocco viene tolto.

> Il controllo per singola mail è stato aggiunto a settembre 2026 (`ConsoleJob/Program.cs`, `ProcessJob`). Non ha alcun costo: `IsDeliveryBlocked` è già caricato da `GetServerConfig`, che viene comunque chiamata per ogni riga. Con un database per tenant il comportamento è identico a prima.
>
> Gli altri due meccanismi restano scollegati: il toggle globale nella UI e `SemaphoreFilePath` **non fermano le spedizioni**. Per bloccare tutto, usare il flag del tenant.

### 16.3 `Companies[].MaxRetryCount` è ignorato

Il ConsoleJob legge il limite dei tentativi da `EmailJob:MaxRetryCount` (default 2 se la sezione manca, come nelle configurazioni attuali). Il campo per tenant è modificabile dalla Web UI ma non ha effetto. Da tenere presente quando si vuole un numero di tentativi diverso per cliente.

### 16.4 `appsettings.Development.json` aveva le chiavi annidate nel posto sbagliato — corretto

Nel progetto `EMailSender.Web`, `ConnectionStrings`, `Companies` e `DefaultTenants` stavano **dentro** la sezione `Logging`, quindi in Development non venivano lette. Corretto a settembre 2026. Riguardava solo lo sviluppo, non le installazioni.

---

## Appendice A — IIS

### A.1 Il robot non richiede IIS

`EMailSender.Web` è self-hosted con Kestrel e gira come servizio Windows. Sui server EasyWebParts IIS è presente, ma l'app pool che si trova lì (`No Managed Code` + `AspNetCoreModuleV2`) appartiene all'**applicazione consumer** — il portale Blazor che accoda le mail — non al robot.

### A.2 Pool e sito dell'applicazione consumer

Pattern in uso in produzione per un'app ASP.NET Core / Blazor Server hostata in IIS, da replicare per l'app che alimenta la coda:

```powershell
Import-Module WebAdministration

# App pool: "No Managed Code" (il CLR di IIS non serve, ci pensa ANCM)
New-WebAppPool -Name "MioApp_Pool"
Set-ItemProperty IIS:\AppPools\MioApp_Pool -Name managedRuntimeVersion -Value ""
Set-ItemProperty IIS:\AppPools\MioApp_Pool -Name managedPipelineMode  -Value "Integrated"

# Sito
New-Website -Name "MioApp" -PhysicalPath "C:\WWWProduction\MioApp" `
            -ApplicationPool "MioApp_Pool" -HostHeader "app.dominio.it" -Port 80

# Permessi per l'identità del pool
icacls "C:\WWWProduction\MioApp" /grant "IIS AppPool\MioApp_Pool:(OI)(CI)M" /T /Q
```

Con `web.config` generato dal publish:

```xml
<handlers>
  <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
</handlers>
<aspNetCore processPath="dotnet" arguments=".\MiaApp.dll" hostingModel="inprocess" />
```

Prerequisito: **ASP.NET Core Hosting Bundle** installato (fornisce `AspNetCoreModuleV2`), non il solo runtime.

### A.3 Ospitare la Web UI del robot sotto IIS (opzionale)

Tecnicamente possibile — è un'app ASP.NET Core come le altre — ma **non è il percorso supportato** da questi script e non porta vantaggi: il servizio Windows dà già avvio automatico e recovery. Se si scegliesse questa strada: rimuovere il servizio (`Register-EMailSenderService.ps1 -Remove`), creare pool `No Managed Code` e applicazione su `C:\EMailSender\Web`, scrivere un `web.config` con ANCM `hostingModel="inprocess"` e concedere all'identità del pool i permessi sui database **e la scrittura su `appsettings.json`** (la UI riscrive quel file). L'account cambia: i permessi SQL concessi a `NT AUTHORITY\SYSTEM` non valgono più per la UI.

---

## Appendice B — riferimento degli script

Tutti da eseguire **come amministratore**. Sono idempotenti: rieseguirli è sicuro.

| Script | Quando si usa | Cosa fa |
|---|---|---|
| **`Setup-EMailSender.ps1`** | **Installazione completa su macchina nuova** | Chiede tutto all'inizio, riepiloga, una conferma sola, poi esegue tutti gli script qui sotto nell'ordine giusto |
| `Invoke-EMailSenderLogCleanup.ps1` | Pulizia log, e creazione del suo task | Cancella file di log e righe della tabella `log` oltre 60 giorni, **per tutti i tenant da un unico punto**. Con `-RegisterTask` crea il task giornaliero |
| `EMailSenderCommon.ps1` | Mai da solo | Funzioni condivise (domande, convalide, registrazione task). Deve stare accanto agli altri script |
| `Install-EMailSender.ps1` | Prima installazione su macchina nuova | Prerequisiti, cartelle, permessi, copia file, crea i due `appsettings.json`, servizio, firewall, avvio |
| `New-EMailSenderTenant.ps1` | Nuovo tenant, o modifica di uno esistente | Database, 5 tabelle, indici, permessi SQL, riga SMTP, cartella log, **entrambi** gli `appsettings.json`, task opzionale |
| `Register-EMailSenderService.ps1` | Servizio da creare, spostare o rimuovere | `sc.exe create/config`, recovery automatico, regola firewall. `-Remove` per disinstallare |
| `ConsoleJobSetupJob.ps1` | Task di un tenant | Crea/aggiorna il task come `SYSTEM`, ripetizione illimitata. `-Remove` per rimuoverlo |
| `Test-EMailSenderInstall.ps1` | Verifica e diagnosi | Solo lettura: 9 famiglie di controlli, exit code 1 su errori |
| `Deploy.ps1` | Aggiornamento di un'installazione esistente | Stop servizio, copia file (mai gli appsettings), aggiorna script e guida, start |
| `StartServices.ps1` / `StopServices.ps1` / `RestartServices.ps1` | Gestione quotidiana | Avvio / arresto / riavvio di `EMailSenderWeb` |

Ogni script documenta i propri parametri:

```powershell
Get-Help .\New-EMailSenderTenant.ps1 -Detailed
```

---

*Fine guida*
