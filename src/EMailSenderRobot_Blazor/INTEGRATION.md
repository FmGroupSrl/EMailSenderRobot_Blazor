# Guida per l'applicazione che usa il robot (consumer)

> Per chi deve far spedire mail a **EMailSenderRobot** da una propria applicazione — portale, gestionale, servizio.
> Documento gemello del `ReadMe.md`, che descrive invece l'installazione del robot.
>
> Ultimo aggiornamento: settembre 2026.

---

## Indice

1. [Il contratto in una riga](#1-il-contratto-in-una-riga)
2. [Due modi di accodare](#2-due-modi-di-accodare)
3. [Configurazione dell'applicazione consumer](#3-configurazione-dellapplicazione-consumer)
4. [Il flusso completo, con codice](#4-il-flusso-completo-con-codice)
5. [Placeholder: chi sostituisce cosa](#5-placeholder-chi-sostituisce-cosa)
6. [Righe ripetute — il repeater e `#ELEMENTLIST#`](#6-righe-ripetute--il-repeater-e-elementlist)
7. [Immagini nel corpo mail](#7-immagini-nel-corpo-mail)
8. [Multilingua](#8-multilingua)
9. [Allegati](#9-allegati)
10. [Trappole note](#10-trappole-note)
11. [Checklist di integrazione](#11-checklist-di-integrazione)
12. [Riferimenti](#12-riferimenti)

---

## 1. Il contratto in una riga

**L'applicazione consumer scrive una riga in `ConfigEmailJobSchedule` con il corpo mail già finito. Il robot la prende e la spedisce.**

Tutto il resto discende da qui. In particolare:

> ⚠️ **Il robot non elabora il corpo della mail. Lo spedisce esattamente com'è.**
> Nessuna sostituzione di placeholder, nessuna espansione di righe, nessun montaggio di header e footer. Se nel corpo resta scritto `#TOTALEORDINE#`, il cliente riceve una mail con scritto `#TOTALEORDINE#`.

Chi compone la mail è **sempre** l'applicazione consumer. Il robot si occupa di: leggere la coda, risolvere i parametri SMTP del tenant, spedire, gestire i tentativi, registrare l'esito.

**Divisione delle responsabilità:**

| Fase | Chi la fa |
|---|---|
| Definire i template (`ConfigEmailContent`) | L'operatore, dall'**Email Editor** della Web UI del robot |
| Definire i destinatari fissi (`ConfigEmailAddress`) | L'operatore, dalla Web UI |
| Leggere template e destinatari dal DB | Il consumer (via `FMGroup.Mail`) |
| **Sostituire i placeholder con i dati veri** | **Il consumer** |
| Comporre header + body + footer | Il consumer |
| Accodare la mail | Il consumer (via `FMGroup.Mail`) |
| Leggere la coda, spedire, ritentare, loggare | Il robot |

---

## 2. Due modi di accodare

### 2.1 Con `FMGroup.Mail` — consigliato

Libreria condivisa .NET 8 che incapsula lettura dei template, fallback di lingua, lettura destinatari e accodamento.

- Sorgenti: `C:\Sviluppo\FmGroupSrl\FMGroup.Mail`
- Pacchetto NuGet già prodotto: `FMGroup.Mail\nupkg\FMGroup.Mail.<versione>.nupkg`
- È la strada usata da EasyWebParts Blazor

### 2.2 Con una `INSERT` diretta

Legittima se l'applicazione non è .NET (o è .NET Framework legacy). Il contratto è la tabella: basta scrivere la riga con i campi corretti.

```sql
INSERT INTO ConfigEmailJobSchedule
    (Company, JobReference, EmailType, EmailBodyIsHtml,
     EmailObject, EmailBody, EmailTo, EmailCC, EmailCCN,
     EmailAttachments, CreationTimeStamp, IsError, RetryCount, IsScheduled)
VALUES
    ('FMG', 'ORD-2026-00871', 'OrderConfirm', 'S',
     'Conferma ordine WEB-2026-004532',
     '<html>... corpo GIÀ COMPLETO, senza placeholder residui ...</html>',
     'cliente@dominio.it', '', 'archivio@fmgsrl.com',
     '', GETDATE(), 'N', 0, 'N');
```

**Campi obbligatori e non negoziabili:**

| Campo | Valore | Perché |
|---|---|---|
| `Company` | il tenant, es. `FMG` | Il robot ci risolve i parametri SMTP: se non c'è una riga corrispondente in `ConfigEmailServer`, la mail va in errore |
| `IsScheduled` | `'N'` | Con `'S'` la mail verrebbe considerata già presa in carico |
| `IsError` | `'N'` | Con `'A'` è considerata annullata e non parte più |
| `SentTimeStamp` | `NULL` | Valorizzato = già spedita |
| `EmailBodyIsHtml` | `'S'` o `'N'` | Determina il content-type |
| `EmailTo` | almeno un indirizzo | Separatore `;` o `,` |

> `RetryCount` a 0 e `CreationTimeStamp` a `GETDATE()`: non sono usati per la selezione ma servono al monitor e alla logica dei tentativi.

---

## 3. Configurazione dell'applicazione consumer

### 3.1 appsettings.json del consumer

```jsonc
{
  "MailSenderSettings": {
    // Punta al DATABASE DEL ROBOT (quello con ConfigEmailJobSchedule).
    // Può essere lo stesso database dell'applicazione oppure uno separato.
    "ConnectionString": "data source=.\\SQLEXPRESS;Integrated Security=SSPI;Database=FMG_EmailSenderRobot;TrustServerCertificate=True",

    // Cartella dove la libreria scrive i log di errore.
    "ErrorLogPath": "C:\\FMGroupData\\Log"
  }
}
```

> Il nome della sezione **`MailSenderSettings`** non è casuale: è quello che `EmailDbContext` cerca come fallback se il `DbContext` non riceve opzioni dalla DI. Un messaggio di errore della libreria cita una sezione `MailSender` — è impreciso, la sezione corretta è `MailSenderSettings`.

### 3.2 Registrazione nella DI

La libreria **non espone** un metodo di estensione `AddMailSender()`: le tre registrazioni vanno fatte a mano.

```csharp
// Program.cs dell'applicazione consumer

// 1. Le impostazioni, lette dalla sezione MailSenderSettings
builder.Services.Configure<MailSenderSettings>(
    builder.Configuration.GetSection("MailSenderSettings"));

// 2. Il DbContext sul database del robot
builder.Services.AddDbContext<EmailDbContext>(opt =>
    opt.UseSqlServer(builder.Configuration["MailSenderSettings:ConnectionString"]));

// 3. Il servizio vero e proprio
builder.Services.AddScoped<IMailSender, MailSender>();
```

> Il costruttore di `MailSender` **solleva `InvalidOperationException`** se `ConnectionString` è vuota: un errore di configurazione si manifesta subito, non alla prima mail.

### 3.3 Cosa deve esistere sul robot prima che il consumer funzioni

1. Il tenant configurato nel robot (`Companies[]` + connection string) — vedi `ReadMe.md` §11
2. La riga in `ConfigEmailServer` per quel tenant, con i parametri SMTP
3. Un record in `ConfigEmailContent` per ogni coppia **tipo mail + lingua** che il consumer richiederà
4. Un record in `ConfigEmailAddress` per ogni tipo mail, se i destinatari sono fissi
5. Il task nello Scheduler attivo

> Punti 3 e 4 si creano dall'**Email Editor** della Web UI. Se il consumer chiede un `EmailType` che non esiste a DB, `SetEmailTextAsync` non trova nulla e la mail parte vuota o non parte affatto.

---

## 4. Il flusso completo, con codice

```csharp
// Iniettato dalla DI
private readonly IMailSender _mail;

public async Task InviaConfermaOrdineAsync(Ordine ordine, string lingua)
{
    // --- 1. Identità della mail -------------------------------------------
    // Company: il tenant. EmailType: la chiave del template a DB.
    _mail.Company   = "FMG";
    _mail.EmailType = "OrderConfirm";
    _mail.Language  = lingua;          // "IT", "EN", "DE", ...

    // --- 2. Lettura da DB di template, destinatari e parametri SMTP -------
    // ATTENZIONE alle convenzioni di ritorno incoerenti (vedi §10.1):
    // il modo sicuro è ignorare il valore restituito e controllare IsError.
    await _mail.SetAllsAsync();
    if (_mail.IsError)
        throw new InvalidOperationException($"Configurazione mail non trovata: {_mail.GetMsgError}");

    // Dopo questa chiamata sono valorizzati:
    //   EmailObject, EmailHeader, EmailBody, EmailFooter,
    //   EmailBodyRowRepeater, EmailIsHtml, TO/CC/BCC

    // --- 3. Sostituzione dei placeholder: QUESTA PARTE È TUA --------------
    var oggetto = _mail.EmailObject
        .Replace("#WEBORDER#", ordine.NumeroWeb)
        .Replace("#ORDERTYPE#", ordine.TipoDescrizione);

    var corpo = _mail.EmailBody
        .Replace("#COMPANYDESCR#", ordine.RagioneSociale)
        .Replace("#WEBORDER#",     ordine.NumeroWeb)
        .Replace("#TIMESTAMP#",    ordine.Data.ToString("dd/MM/yyyy"))
        .Replace("#TOTALEORDINE#", ordine.Totale.ToString("N2"));

    // --- 4. Righe ripetute (se il template le prevede) --------------------
    var righe = new System.Text.StringBuilder();
    foreach (var r in ordine.Righe)
    {
        righe.Append(_mail.EmailBodyRowRepeater
            .Replace("#NEWPARTNO#",    r.Codice)
            .Replace("#DESCRIPTION#",  r.Descrizione)
            .Replace("#ROWQUANTITY#",  r.Quantita.ToString())
            .Replace("#ROWTOTPRICE#",  r.Totale.ToString("N2")));
    }
    corpo = corpo.Replace("#ELEMENTLIST#", righe.ToString());

    // --- 5. Montaggio del corpo definitivo --------------------------------
    // Header e footer non vengono uniti da nessuno: lo fai tu.
    var corpoCompleto = _mail.EmailHeader + corpo + _mail.EmailFooter;

    // --- 6. Immagini incorporate (facoltativo) ----------------------------
    corpoCompleto = await _mail.ReplaceImagePlaceholdersAsync(
                        corpoCompleto, @"C:\FMGroupData\MailImages");

    // --- 7. Destinatario ---------------------------------------------------
    // Se il template prevede EmailTO = 'Utente Specifico', l'indirizzo lo
    // decide il codice chiamante; altrimenti TO arriva già da DB.
    _mail.TO = new[] { ordine.EmailCliente };

    // --- 8. Accodamento ----------------------------------------------------
    // Si usa l'overload LUNGO passando esplicitamente oggetto e corpo:
    // gli overload corti accodano EmailBody, ignorando il corpo composto.
    var errore = await _mail.AddNewEmailAsync(
        _mail.Company,
        ordine.NumeroWeb,          // JobReference: la tua chiave di ricerca nel monitor
        _mail.EmailType,
        "S",                       // EmailBodyIsHtml
        oggetto,
        corpoCompleto,
        string.Join(";", _mail.TO),
        string.Join(";", _mail.CC),
        string.Join(";", _mail.BCC),
        "");                       // allegati: percorsi separati da ';'

    if (errore)                    // true = ERRORE, vedi §10.1
        throw new InvalidOperationException($"Accodamento fallito: {_mail.GetMsgError}");
}
```

Da qui in poi è il robot a lavorare: entro un minuto il task preleva la riga e la spedisce.

> **`JobReference` è il campo più utile che ci sia**: valorizzalo sempre con la tua chiave di dominio (numero ordine, id pratica, ...). È ciò che permette, dal Monitor della Web UI, di rispondere alla domanda "la mail dell'ordine X è partita?".

---

## 5. Placeholder: chi sostituisce cosa

**Il punto centrale di questa guida.** L'elenco completo dei nomi è in [`PLACEHOLDERS.md`](PLACEHOLDERS.md); qui c'è la cosa che quel documento non dice a colpo d'occhio: **chi** li sostituisce.

| Famiglia | Formato | Sostituito automaticamente? | Da chi |
|---|---|---|---|
| Immagini incorporate | `#IMG_{nome}_{w}_{h}_{ext}#` | **Sì**, ma solo se chiami tu il metodo | `FMGroup.Mail.ReplaceImagePlaceholdersAsync(body, path)` |
| Righe ripetute | `#ELEMENTLIST#` | **No** | Il consumer, espandendo `EmailBodyRowRepeater` |
| Tutti i placeholder testuali | `#NOME#` | **No** | Il consumer, con `.Replace()` |

Non esiste un motore generico di sostituzione testuale, né nella libreria né nel robot: **ogni consumer implementa le proprie `.Replace()`**. Un placeholder che nessuno sostituisce arriva al destinatario così com'è scritto, e non lascia alcuna traccia negli errori.

### 5.1 Conseguenze pratiche per un nuovo progetto

1. **Parti dall'elenco, non dal codice.** Prima di scrivere il template, apri `PLACEHOLDERS.md` e scegli i nomi da lì: se un placeholder esiste già con un certo nome in un altro consumer, riusa quel nome invece di inventarne uno nuovo.
2. **Registra i tuoi placeholder nuovi** in `PLACEHOLDERS.md` — che esiste in **due copie da tenere allineate a mano** (questo repo e `FMGroup.Mail`). Un placeholder non registrato è invisibile a chi scriverà i template fra un anno.
3. **Attento ai nomi ambigui.** `#NOTE#` significa cose diverse nel corpo e nel repeater riga; `#COMPANY#` è il *codice cliente* nella mail ordine, mentre `Company` nella coda è il *tenant*. Non sono la stessa cosa.
4. **Verifica prima di andare in produzione**: manda una mail di prova a te stesso e cerca il carattere `#` nel testo ricevuto. Se ne trovi, hai un placeholder scoperto.

### 5.2 L'anteprima dell'Email Editor non è affidabile

L'anteprima della Web UI sostituisce solo 4 placeholder generici cablati (`#PRODOTTO#`, `#QTY#`, `#PREZZO#`, `#ELEMENTLIST#`). Tutti gli altri — inclusi tutti i tuoi — compaiono grezzi **anche quando il codice li sostituirebbe correttamente**. Non è un errore del template. Dettagli: [`PLACEHOLDERS_PREVIEW_GAP.md`](PLACEHOLDERS_PREVIEW_GAP.md).

---

## 6. Righe ripetute — il repeater e `#ELEMENTLIST#`

Il meccanismo per le mail con una tabella di righe (ordini, elenchi di documenti).

- Il campo `EmailBodyRowRepeater` di `ConfigEmailContent` contiene **il template di una riga sola**, tipicamente un `<tr>...</tr>` con i suoi placeholder.
- Il corpo mail contiene il segnaposto `#ELEMENTLIST#` nel punto in cui va l'elenco.
- Il consumer cicla sui dati, produce N copie del repeater sostituendo i placeholder di riga, le concatena e sostituisce il risultato dentro `#ELEMENTLIST#`.

Esempio di repeater:

```html
<tr>
  <td>#NEWPARTNO#</td>
  <td>#DESCRIPTION#</td>
  <td style="text-align:right">#ROWQUANTITY#</td>
  <td style="text-align:right">#ROWTOTPRICE#</td>
</tr>
```

> Il codice che espande il repeater sta **solo** nel consumer (in EasyWebParts è `OrderManagementService.BuildOrderEmailBodyAsync`). La libreria si limita a esporre `EmailBodyRowRepeater` come proprietà.

---

## 7. Immagini nel corpo mail

L'unico motore di sostituzione automatica disponibile. Serve perché i client di posta (Outlook, Gmail) bloccano per default le immagini caricate da URL esterni.

```csharp
corpo = await _mail.ReplaceImagePlaceholdersAsync(corpo, @"C:\FMGroupData\MailImages");
```

- Formato: `#IMG_{nomefile}_{larghezza}_{altezza}_{estensione}#`
- Esempio: `#IMG_logo_200_80_png#` cerca `logo.png` nella cartella indicata e lo incorpora in Base64 come data URI
- **Il nome file non deve contenere underscore** (renderebbe ambiguo il parsing)
- Larghezza e altezza diventano attributi HTML: **non ridimensionano il file**, che viene incorporato così com'è. Usa immagini già della dimensione giusta, o le mail diventano pesanti
- Se il file non esiste: warning nel log, placeholder lasciato intatto, nessuna eccezione

> Il Base64 gonfia il corpo di circa il 33%: per loghi va benissimo, per fotografie no. La cartella immagini dev'essere leggibile dall'account dell'applicazione consumer, non da quello del robot: la sostituzione avviene **prima** dell'accodamento.

---

## 8. Multilingua

`ConfigEmailContent` ha chiave logica **Company + Type + Language**. Impostando `_mail.Language` prima di `SetEmailTextAsync`/`SetAllsAsync`, la libreria applica una catena di fallback:

```
lingua richiesta  →  EN  →  IT  →  niente
```

Se non trova nemmeno IT, il testo resta vuoto: la mail parte senza corpo. Conviene garantire che esista **almeno la versione IT** di ogni tipo mail.

> Il fallback è implementato due volte, in modo indipendente: in `FMGroup.Mail.SetEmailTextAsync` e in `EmailRepository.GetEmailContentWithFallback` del robot (usato dall'Email Editor). Le due catene oggi coincidono.

---

## 9. Allegati

Il campo `EmailAttachments` contiene **percorsi di file su disco separati da `;`**, non contenuti binari.

Conseguenze da tenere presenti:

- Il file deve essere raggiungibile **dall'account del robot** (`NT AUTHORITY\SYSTEM`) al momento della spedizione, che avviene fino a un minuto dopo l'accodamento. Un file in una cartella temporanea cancellata subito dopo non arriverà mai
- Se il percorso è una share di rete, `SYSTEM` in genere **non** ci accede: usare un percorso locale
- I file **non vengono cancellati** dopo l'invio: la pulizia è a carico del consumer
- Alla dismissione di un tenant vanno rimossi a mano (vedi `ReadMe.md` §12)

---

## 10. Trappole note

Raccolte leggendo il codice: nessuna di queste è documentata altrove.

### 10.1 Le convenzioni di ritorno sono incoerenti

Nella stessa classe `MailSender` convivono due convenzioni opposte:

| Metodo | Cosa significa `true` |
|---|---|
| `SetAllsAsync` | **OK** |
| `SetEmailAddressesAsync` | **OK** |
| `SetEmailTextAsync` | **OK** |
| `SetServerDetailsAsync` | **ERRORE** |
| `AddNewEmailAsync` | **ERRORE** |
| `SendEmailAsync` | **ERRORE** |

> **Regola pratica: non fidarti del valore restituito, controlla la proprietà `IsError`** dopo ogni chiamata. È valorizzata coerentemente da tutti i metodi. Il messaggio è in `GetMsgError`.

### 10.2 Gli overload corti di `AddNewEmailAsync` ignorano il corpo composto

`AddNewEmailAsync(company, jobRef, isHtml, attachments)` e la variante con `emailType` accodano il contenuto della proprietà **`EmailBody`**, non di `EmailFullBody`. Se hai composto header+body+footer in una variabile locale o in `EmailFullBody`, con questi overload **accodi il template grezzo**, con i placeholder ancora dentro.

> Usa sempre l'**overload lungo**, passando esplicitamente oggetto e corpo definitivi. In alternativa assegna il corpo finito a `EmailBody` prima di chiamare gli overload corti.

### 10.3 Non chiamare `SendEmailAsync` né `GetMailContentAsync` da un consumer

`FMGroup.Mail` contiene anche il codice per spedire direttamente e per prelevare dalla coda (`GetMailContentAsync` marca la riga con `IsScheduled='S'`): è l'eredità di quando non esisteva il robot.

Un consumer che li usa entra in **conflitto con il ConsoleJob**, che sta facendo la stessa cosa sulla stessa tabella: nel migliore dei casi la mail parte due volte. Da un'applicazione consumer si usa **solo `AddNewEmailAsync`**.

Eccezione ragionevole: un pulsante "invia mail di prova" in una pagina di configurazione, che deve dare esito immediato.

### 10.4 Nessuno controlla che il tenant esista

Se accodi con una `Company` che il robot non conosce, la riga resta in coda per sempre: nessun errore, nessun log, semplicemente nessun task che la guarda. Il valore di `Company` va tenuto allineato con `Companies[].Name` della configurazione del robot.

### 10.5 Il corpo mail ha un limite pratico

`EmailBody` è `NVARCHAR(MAX)`, ma `EmailObject` è `NVARCHAR(500)` e `EmailTo`/`EmailCC`/`EmailCCN` sono `NVARCHAR(500)`: un elenco lungo di destinatari in copia viene **troncato in silenzio** dall'`INSERT`. `EmailAttachments` è `NVARCHAR(1000)`.

### 10.6 La coda non ha una data di programmazione

Non esiste un campo "spedisci dopo il". Tutto ciò che viene accodato parte alla prima esecuzione utile del task. Per differire l'invio, il consumer deve accodare al momento giusto (`IsScheduled` non serve a questo: è lo stato di presa in carico del robot).

---

## 11. Checklist di integrazione

Da percorrere quando si collega una **nuova** applicazione al robot.

**Lato robot**
- [ ] Tenant creato (`New-EMailSenderTenant.ps1`) e visibile nella Web UI
- [ ] Riga in `ConfigEmailServer` con SMTP funzionante (testato con **Test invio mail**)
- [ ] Un record in `ConfigEmailContent` per ogni tipo mail **e ogni lingua** previsti, almeno in IT
- [ ] Un record in `ConfigEmailAddress` per ogni tipo mail con destinatari fissi
- [ ] Task attivo nello Scheduler
- [ ] `Test-EMailSenderInstall.ps1` senza errori

**Lato applicazione consumer**
- [ ] Riferimento a `FMGroup.Mail` (NuGet) oppure `INSERT` diretta documentata
- [ ] `MailSenderSettings:ConnectionString` che punta al database del robot
- [ ] Registrazioni DI: `Configure<MailSenderSettings>`, `AddDbContext<EmailDbContext>`, `AddScoped<IMailSender, MailSender>`
- [ ] `Company` allineato al nome del tenant sul robot
- [ ] `JobReference` valorizzato con una chiave di dominio significativa
- [ ] Esito controllato con `IsError`, non con il valore di ritorno
- [ ] Overload **lungo** di `AddNewEmailAsync`
- [ ] Placeholder nuovi registrati in **entrambe** le copie di `PLACEHOLDERS.md`
- [ ] Mail di prova ricevuta e verificata: **nessun `#` residuo nel testo**
- [ ] Percorsi degli allegati leggibili da `NT AUTHORITY\SYSTEM` e persistenti

---

## 12. Riferimenti

| Cosa | Dove |
|---|---|
| Installazione e gestione del robot | `ReadMe.md` (questo repo) |
| Elenco dei placeholder esistenti | `PLACEHOLDERS.md` (questo repo, copia gemella in `FMGroup.Mail`) |
| Limiti dell'anteprima dell'Email Editor | `PLACEHOLDERS_PREVIEW_GAP.md` (questo repo) |
| Dettagli del motore immagini Base64 | `FMGroup.Mail\handoff_image_placeholder_base64.md` |
| Sorgenti della libreria | `C:\Sviluppo\FmGroupSrl\FMGroup.Mail` |
| Pacchetto NuGet | `C:\Sviluppo\FmGroupSrl\FMGroup.Mail\nupkg\` |
| Esempio reale di consumer | `EasyWebParts_Blazor\Services\OrderManagementService.cs`, metodo `BuildOrderEmailBodyAsync` |
| Contratto della coda (schema tabelle) | `ReadMe.md` §6 |

---

*Fine guida*
