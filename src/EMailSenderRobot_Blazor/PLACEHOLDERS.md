# Registro placeholder email

> **ATTENZIONE — file duplicato in due repository.**
> Questo file esiste identico in:
> - `C:\Sviluppo\FmGroupSrl\FMGroup.Mail\PLACEHOLDERS.md` (questo file)
> - `C:\Sviluppo\FmGroupSrl\EMailSenderRobot_Blazor\src\EMailSenderRobot_Blazor\PLACEHOLDERS.md`
>
> **Regola di sincronizzazione:** qualunque modifica fatta in una delle due copie (nuovo placeholder,
> modifica di uno esistente, rimozione) va replicata immediatamente anche nell'altra copia, nella
> stessa sessione di lavoro. Non lasciare le due copie disallineate.

## Scopo

Elenco unico di tutti i placeholder testuali usati nei template email (`ConfigEmailContent`:
`EmailHeader` / `EmailBody` / `EmailBodyRowRepeater` / `EmailFooter` / `EmailObject`), a prescindere
da quale progetto li definisce o li sostituisce. Serve a chi scrive/modifica un template (via
Email Editor di `EMailSenderRobot_Blazor`, o direttamente su DB) per sapere quali placeholder sono
disponibili in ciascun contesto, senza dover spulciare il codice sorgente dei vari consumer.

La colonna **Esempio** riporta un valore plausibile di sostituzione: serve sia come riferimento per
chi scrive un template (per capire il formato atteso, es. data `dd/MM/yyyy` vs numero), sia come
possibile fonte dati per un futuro miglioramento dell'anteprima dell'Email Editor, che oggi conosce
solo 4 placeholder generici e mostra grezzi tutti gli altri — vedi
`EMailSenderRobot_Blazor/src/EMailSenderRobot_Blazor/PLACEHOLDERS_PREVIEW_GAP.md`.

## Famiglie di placeholder

### 1. Placeholder testuali generici — formato `#NOME#`

Sostituiti lato applicativo con catene di `.Replace("#NOME#", valore)`. Non esiste un motore generico
di parsing: ogni consumer (EasyWebParts_Blazor, ecc.) implementa la propria sostituzione nel punto in
cui compone il corpo mail prima di chiamare `SendEmailAsync`/`AddNewEmailAsync`. Se un placeholder non
viene sostituito dal codice chiamante, resta visibile testualmente nel corpo mail inviato.

### 2. Placeholder immagine — formato `#IMG_{nomefile}_{width}_{height}_{ext}#`

Introdotto in `FMGroup.Mail` (`MailSender.ReplaceImagePlaceholdersAsync`, vedi
`EmailSender/MailSender.cs`). A differenza della famiglia 1, questo **ha un motore generico** dentro
la libreria condivisa: chi consuma FMGroup.Mail chiama esplicitamente
`ReplaceImagePlaceholdersAsync(body, imagesBasePath)` dopo aver ottenuto `EmailFullBody`/`EmailBody`,
prima dell'invio. Il placeholder viene sostituito con un tag `<img>` con l'immagine incorporata in
Base64 (data URI). `{nomefile}` non deve contenere underscore. Esempio: `#IMG_logo_200_80_png#` cerca
`logo.png` nella cartella passata come `imagesBasePath`. Se il file non esiste: warning nel log,
placeholder lasciato intatto (nessuna eccezione bloccante). Dettagli completi:
`FMGroup.Mail/handoff_image_placeholder_base64.md`.

## Placeholder comuni a più tipi di mail (credenziali)

| Placeholder | Significato | Esempio | Dove viene sostituito |
|---|---|---|---|
| `#USERNAME#` | Email/username dell'utente | `mario.rossi@cliente.it` | `RecuperaPassword.razor.cs:90`, `UserManagement.razor.cs:565`, `DemoPage.razor.cs:91` (EasyWebParts_Blazor) |
| `#PASSWORD#` | Password (in chiaro, generata o reimpostata) | `Xk9#mQ2vL` | Stessi 3 punti di cui sopra |

## Placeholder email ordine (`OrderManagementService.cs`, EasyWebParts_Blazor)

Definiti in `BuildOrderEmailBodyAsync` (`EasyWebParts_Blazor/Services/OrderManagementService.cs:1150-1231`).

### Corpo mail (`bodyTemplate`)

| Placeholder | Significato | Esempio |
|---|---|---|
| `#ORDERTYPE#` | Descrizione tipo ordine | `Ordine Standard` |
| `#WEBORDER#` | Numero ordine web | `WEB-2026-004532` |
| `#NUMORDCLI#` | Numero ordine cliente | `PO-2026-00871` |
| `#TIMESTAMP#` | Data creazione ordine (`dd/MM/yyyy`) | `07/07/2026` |
| `#DATARICEZIONEMERCE#` | Data prevista ricezione merce | `15/07/2026` |
| `#TIPOCONSEGNA#` | Modalità di consegna | `Corriere espresso` |
| `#TIPOORDINE#` | Tipo ordine (raw) | `Standard` |
| `#NOTE#` | Note ordine (attenzione: stesso nome usato anche nel repeater riga, vedi sotto — significato diverso a seconda del template in cui compare) | `Consegna urgente, contattare prima della spedizione` |
| `#COMPANY#` | Codice cliente | `CL00123` |
| `#COMPANYDESCR#` | Ragione sociale cliente | `Rossi Ricambi Srl` |
| `#MITTENTEDESCR#` | Nome visualizzato del mittente | `Ufficio Commerciale FMGroup` |
| `#MITTENTEEMAIL#` | Email del mittente | `commerciale@fmgsrl.com` |
| `#FRAGSOC#` / `#FINDIRIZZO#` / `#FCAP#` / `#FCITTA#` / `#FPROV#` / `#FSTATO#` | Indirizzo di fatturazione (ragione sociale, indirizzo, CAP, città, provincia, stato) | `Rossi Ricambi Srl` / `Via Roma 12` / `41100` / `Modena` / `MO` / `Italia` |
| `#DCODICE#` | Codice destinazione | `DEST001` |
| `#DRAGSOC#` / `#DINDIRIZZO#` / `#DCAP#` / `#DCITTA#` / `#DPROV#` / `#DSTATO#` | Indirizzo di spedizione (ragione sociale, indirizzo, CAP, città, provincia, stato) | `Rossi Ricambi Srl - Magazzino` / `Via Industria 45` / `41122` / `Modena` / `MO` / `Italia` |
| `#COMPLETEDELIVERYDESCRIPTION#` | "Consegna completa" / "Consegna parziale ammessa" | `Consegna completa` |
| `#DELIVERYMETHODCODE#` | Codice Incoterms | `DAP` |
| `#DELIVERYMETHODDESCRIPTION#` | Descrizione metodo di consegna | `Reso franco destino` |
| `#CUSTOMERCARRIER#` | Corriere cliente | `DHL Express` |
| `#CUSTOMERCARRIERACCOUNT#` | Account corriere cliente | `DHL-998877` |
| `#SERVICELEVEL#` | Descrizione livello di servizio | `Standard 24/48h` |
| `#ELEMENTLIST#` | Righe prodotto espanse (vedi repeater sotto) — stesso nome/ruolo del placeholder generico usato dal motore di `EMailSenderRobot_Blazor` | *(HTML composto dal repeater, non un valore semplice — vedi sezione repeater)* |
| `#TOTALEORDINE#` | Totale ordine formattato (`N2`) | `1.245,90` |
| `#NOTECOLUMN_HIDDEN#` | CSS per nascondere la colonna Note in tabella se nessuna riga ha note (compare sia nel body sia nel repeater) | *(stringa vuota, o CSS tipo `display:none` — è un flag di stato, non testo per l'utente)* |
| `#OLDPARTNOCOLUMN_HIDDEN#` | CSS per nascondere la colonna Codice sostitutivo se nessuna riga ne ha uno (compare sia nel body sia nel repeater) | *(idem sopra)* |

### Oggetto mail (`subjectTemplate`)

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WEBORDER#` | Numero ordine web | `WEB-2026-004532` |
| `#ORDERTYPE#` | Descrizione tipo ordine | `Ordine Standard` |

### Riga prodotto (`EmailBodyRowRepeater` — `rowTemplate`)

| Placeholder | Significato | Esempio |
|---|---|---|
| `#NEWPARTNO#` | Codice ricambio attuale | `RC-4521-B` |
| `#OLDPARTNO#` | Codice ricambio sostituito (se presente) | `RC-4521-A` |
| `#PARTNODISPLAY#` | Cella HTML già composta: codice vecchio barrato (se presente) + codice nuovo in grassetto | *(HTML già composto, non un valore semplice)* |
| `#DESCRIPTION#` | Descrizione tecnica del ricambio | `Guarnizione testata cilindro` |
| `#ROWQUANTITY#` | Quantità riga | `2` |
| `#ROWUNITPRICE#` | Prezzo unitario (`N2`) | `45,50` |
| `#ROWTOTPRICE#` | Prezzo totale riga (`N2`) | `91,00` |
| `#NOTE#` | Note riga (SN + note libere, con `<br />` se entrambe presenti) — significato diverso da `#NOTE#` nel body | `SN: 00234455` |
| `#NOTECOLUMN_HIDDEN#` | Vedi sopra | *(vedi sopra)* |
| `#OLDPARTNOCOLUMN_HIDDEN#` | Vedi sopra | *(vedi sopra)* |

## Placeholder email pratica di garanzia (EasyWebParts_Blazor)

> ⚠️ **PREVISTI, NON ANCORA IMPLEMENTATI.** La mail della pratica di garanzia è la Fase 5 di
> TRACKPRJ-159: oggi l'invio cambia solo lo stato della pratica e non manda niente a nessuno.
> Questo elenco è stato scritto **prima** del codice, il 18/08/2026, di proposito: i campi della
> pratica sono nati in fasi diverse e distanti fra loro, e senza un elenco preso in carico ora il
> rischio concreto è che alla Fase 5 metà di essi non arrivi in mail — senza che nessuno se ne
> accorga, perché un placeholder mai scritto in un template non lascia traccia.
>
> Chi implementa la Fase 5 usi questi nomi, e **tolga questo avviso** quando il codice esiste.

### ⚠️ Tutti i placeholder delle garanzie hanno il prefisso `WAR_`

Decisione dell'utente (18/08/2026): *«quelli delle garanzie sono specifici delle garanzie, anche se
sembrano uguali ad altri, gestiamoli separati»*.

Vale **anche** per i concetti che negli ordini esistono già con lo stesso significato — il cliente,
l'indirizzo di spedizione, il vettore. Riusare `#COMPANYDESCR#` in due mail diverse sembra
un'economia, ma lega insieme due template che devono poter evolvere separatamente: il giorno che
l'ordine cambia il significato di un campo, la mail di garanzia se lo ritrova cambiato sotto senza
che nessuno l'abbia deciso. Il prefisso rende anche evidente, a chi apre un template, a quale mail
appartiene ciò che sta leggendo.

Unica eccezione: `#PORTALURL#`, che è di sistema e non di dominio — vale per tutte le mail del
portale.

### Corpo mail (`bodyTemplate`)

**Identità della pratica**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_NUMBER#` | Numero pratica (anno/progressivo) | `2026/0007` |
| `#WAR_TYPE#` | Descrizione tipo pratica | `Garanzia macchina` |
| `#WAR_STATUS#` | Descrizione stato | `Inviata` |
| `#WAR_CREATIONDATE#` | Data creazione (`dd/MM/yyyy`) | `18/08/2026` |
| `#WAR_SENTDATE#` | Data invio (`dd/MM/yyyy`) | `18/08/2026` |
| `#WAR_USEREMAIL#` | Email di chi ha compilato la pratica | `officina@rossiricambi.it` |
| `#WAR_DEALERCODE#` | Codice del CA che apre la pratica | `CL00123` |
| `#WAR_DEALERNAME#` | Ragione sociale del CA | `Rossi Ricambi Srl` |

**Sezione 1 — macchina e circostanze**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_SERIALNO#` | Matricola della macchina | `SN00234455` |
| `#WAR_MODEL#` | Descrizione modello (snapshot) | `Spazzatrice 5000 EVO` |
| `#WAR_WORKSHOPREPORT#` | Numero report interno d'officina | `RAP-2026-118` |
| `#WAR_DETECTMOMENT#` | Momento del rilievo, già tradotto | `Dopo la consegna` |
| `#WAR_DETECTDATE#` | Data del rilievo (`dd/MM/yyyy`) | `03/08/2026` |
| `#WAR_REPAIRDATE#` | Data della riparazione (`dd/MM/yyyy`) — ⚠️ diversa dalla precedente: si rileva il 3 e si ripara il 12 | `12/08/2026` |

**Sezione 3 — guasto e classificazione**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_DEFECT#` | Difetto riscontrato | `Perdita di olio dal gruppo di sollevamento` |
| `#WAR_CAUSE#` | Possibile causa ipotizzata | `Guarnizione del cilindro deteriorata` |
| `#WAR_CORRECTION#` | Correzione applicata — è ciò che il costruttore legge per decidere se riconoscere la garanzia | `Sostituita guarnizione e rabboccato l'impianto` |
| `#WAR_REQUESTS#` | Richieste e suggerimenti al costruttore | `Si chiede accredito del ricambio` |
| `#WAR_COMPLAINTCODE#` / `#WAR_COMPLAINTDESC#` | Tipo di reclamo: codice e descrizione tradotta | `LEAK` / `Perdita di liquidi` |
| `#WAR_LOCATIONCODE#` / `#WAR_LOCATIONDESC#` | Posizione del guasto | `HYDRAU` / `Impianto idraulico` |
| `#WAR_FAILURECODE#` / `#WAR_FAILUREDESC#` | Natura del guasto | `BREAK` / `Rottura` |

⚠️ Codice **e** descrizione, entrambi: chi lavora la pratica ragiona per codice, chi la legge ha
bisogno del testo. Le descrizioni sono quelle censite dal tenant, quindi vanno risolte nella lingua
del **destinatario** e non in quella di chi ha compilato.

**Sezione 4 — contatto di riferimento**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_CONTACTLASTNAME#` / `#WAR_CONTACTFIRSTNAME#` | Cognome e nome | `Bianchi` / `Luca` |
| `#WAR_CONTACTPHONE#` | Telefono | `059 123456` |
| `#WAR_CONTACTEMAIL#` | Email | `l.bianchi@rossiricambi.it` |

⚠️ Il fax **non c'è**: è stato eliminato dal modulo il 18/08/2026.

**Sezione 5 — cliente finale (proprietario della macchina)**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_CUSTNAME#` | Ragione sociale | `Comune di Modena` |
| `#WAR_CUSTVAT#` / `#WAR_CUSTFISCAL#` | Partita IVA e codice fiscale | `IT01234567890` / `01234567890` |
| `#WAR_CUSTADDRESS#` / `#WAR_CUSTZIP#` / `#WAR_CUSTCITY#` / `#WAR_CUSTPROVINCE#` / `#WAR_CUSTCOUNTRY#` | Indirizzo completo | `Via Roma 1` / `41100` / `Modena` / `MO` / `Italia` |
| `#WAR_CUSTEMAIL#` / `#WAR_CUSTPHONE#` | Contatti | `mezzi@comune.modena.it` / `059 999888` |

⚠️ L'intera sezione può essere **spenta dal tenant** (TRACKPRJ-170): il template deve reggere il
caso in cui questi placeholder siano tutti vuoti, senza lasciare a video etichette orfane.

**Sezione 7 — spedizione dei pezzi**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_DESTCODE#` | Codice destinazione | `DEST001` |
| `#WAR_DESTNAME#` / `#WAR_DESTADDRESS#` / `#WAR_DESTZIP#` / `#WAR_DESTCITY#` / `#WAR_DESTPROVINCE#` / `#WAR_DESTCOUNTRY#` | Indirizzo di rientro dei pezzi | `Rossi Ricambi - Magazzino` / `Via Industria 45` / `41122` / `Modena` / `MO` / `Italia` |
| `#WAR_DESTEMAIL#` / `#WAR_DESTPHONE#` | Contatti della destinazione | `magazzino@rossiricambi.it` / `059 111222` |
| `#WAR_CARRIER#` / `#WAR_CARRIERACCOUNT#` | Vettore e conto del cliente presso il vettore | `DHL Express` / `DHL-998877` |
| `#WAR_SERVICELEVEL#` | Livello di servizio | `Standard 24/48h` |
| `#WAR_DELIVERYMETHOD#` | Metodo di consegna | `Reso franco destino` |

**Elenchi e totali**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_METERLIST#` | Letture dei contatori, espanse dal repeater | *(HTML composto — vedi repeater)* |
| `#WAR_PARTLIST#` | Pezzi reclamati, espansi dal repeater | *(idem)* |
| `#WAR_EXPENSELIST#` | Spese officina, espanse dal repeater | *(idem)* |
| `#WAR_ATTACHMENTLIST#` | Elenco degli allegati | *(idem)* |
| `#WAR_EXPENSETOTAL#` | Totale spese officina, già formattato con la valuta | `€ 245,50` |
| `#WAR_ATTACHMENTCOUNT#` | Quanti file sono allegati | `4` |

⚠️ **Quattro elenchi distinti, non un `#ELEMENTLIST#` solo** come negli ordini: una pratica di
garanzia ha quattro tabelle diverse per natura, e comprimerle in un unico segnaposto costringerebbe
il codice a comporre l'intero blocco HTML, togliendo a chi scrive il template ogni controllo su
dove metterle e con che aspetto.

### Oggetto mail (`subjectTemplate`)

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_NUMBER#` | Numero pratica | `2026/0007` |
| `#WAR_TYPE#` | Descrizione tipo pratica | `Garanzia macchina` |
| `#WAR_SERIALNO#` | Matricola | `SN00234455` |
| `#WAR_DEALERNAME#` | Ragione sociale del CA | `Rossi Ricambi Srl` |

### Righe degli elenchi (`EmailBodyRowRepeater`)

Un repeater per ciascuno dei quattro elenchi. I nomi sono distinti anche fra loro: se due elenchi
condividessero un placeholder, chi scrive il template non potrebbe dare formati diversi alle due
tabelle.

**Contatori (`#WAR_METERLIST#`)**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_METERNAME#` | Descrizione del contatore, come censita dal tenant | `Ore di funzionamento` |
| `#WAR_METERVALUE#` | Lettura, coi decimali della sua unità | `1250` |
| `#WAR_METERUNIT#` | Simbolo dell'unità | `h` |
| `#WAR_METERABSENT#` | Testo se il contatore è dichiarato assente | `Contatore assente` |

**Pezzi reclamati (`#WAR_PARTLIST#`)**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_PARTNO#` | Codice ricambio | `RC-4521-B` |
| `#WAR_PARTDESCRIPTION#` | Descrizione | `Guarnizione testata cilindro` |
| `#WAR_PARTQUANTITY#` | Quantità reclamata | `2` |
| `#WAR_PARTORIGIN#` | Provenienza della riga (listino, catalogo, manuale) | `Catalogo` |

**Spese officina (`#WAR_EXPENSELIST#`)**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_EXPENSEDESCRIPTION#` | Descrizione della voce (snapshot) | `Ore uomo` |
| `#WAR_EXPENSEQUANTITY#` | Quantità, coi decimali dell'unità | `2,25` |
| `#WAR_EXPENSEUNIT#` | Unità | `h` |
| `#WAR_EXPENSEUNITPRICE#` | Valore unitario applicato | `45,00` |
| `#WAR_EXPENSEROWTOTAL#` | Totale riga | `101,25` |

**Allegati (`#WAR_ATTACHMENTLIST#`)**

| Placeholder | Significato | Esempio |
|---|---|---|
| `#WAR_ATTACHMENTNAME#` | Nome originale del file | `foto-guasto-01.jpg` |
| `#WAR_ATTACHMENTCATEGORY#` | Famiglia: documento oppure media | `Foto e video` |
| `#WAR_ATTACHMENTSIZE#` | Dimensione leggibile | `3,2 MB` |

## Placeholder generico del motore repeater (`EMailSenderRobot_Blazor`)

Il campo `EmailBodyRowRepeater` in `ConfigEmailContent` è un template di singola riga con placeholder
liberi a scelta di chi scrive il template (non un set fisso) — il codice applicativo che espande il
repeater decide quali nomi usare e li sostituisce prima di iniettare il risultato in `#ELEMENTLIST#`
nel corpo mail. Nell'anteprima dell'Email Editor (`Emaileditor.razor:573-577`) vengono usati come
esempio generico `#PRODOTTO#`, `#QTY#`, `#PREZZO#`, ma sono solo placeholder dimostrativi per
l'anteprima — non un contratto fisso: il set reale dipende dal codice del consumer (vedi ad es. i
placeholder riga di `OrderManagementService.cs` sopra, che sono diversi).

| Placeholder | Significato | Esempio |
|---|---|---|
| `#PRODOTTO#` | Nome prodotto (esempio generico, usato solo nella preview) | `Prodotto di esempio` |
| `#QTY#` | Quantità (esempio generico, usato solo nella preview) | `1` |
| `#PREZZO#` | Prezzo (esempio generico, usato solo nella preview) | `€ 0,00` |

## Come aggiungere un nuovo placeholder

1. Implementarlo/sostituirlo nel codice del consumer (o nel motore `FMGroup.Mail`, se generico).
2. Aggiungerlo a questo file, nella sezione pertinente (o crearne una nuova se è un nuovo consumer),
   con un esempio di valore plausibile nella colonna Esempio.
3. **Aggiornare anche l'altra copia del file** (vedi avviso in cima).
