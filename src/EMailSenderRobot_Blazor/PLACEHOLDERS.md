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
