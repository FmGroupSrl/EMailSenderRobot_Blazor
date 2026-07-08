# Limite noto: l'anteprima dell'Email Editor non conosce tutti i placeholder

## Cosa succede oggi

`Emaileditor.razor` (metodo `RefreshPreview`, righe 566-579) genera l'anteprima HTML mostrata mentre
si scrive un template sostituendo **solo 4 placeholder hardcoded nel codice**:

```csharp
var repeaterExample = ...
    .Replace("#PRODOTTO#", "Prodotto di esempio")
    .Replace("#QTY#", "1")
    .Replace("#PREZZO#", "€ 0,00");

var body = _editContent.EmailBody.Replace("#ELEMENTLIST#", repeaterExample);
```

Qualsiasi altro placeholder presente nel template — es. `#TOTALEORDINE#`, `#NEWPARTNO#`,
`#USERNAME#`, `#IMG_logo_200_80_png#` — **non viene sostituito** e compare grezzo, testuale,
nell'anteprima. Questo perché quei placeholder sono di dominio specifico del progetto consumer
(EasyWebParts_Blazor, ecc.) e l'Email Editor non ha né i dati reali né una lista di valori di
esempio per simularli.

## Perché è così (non è un bug, è un limite architetturale)

L'Email Editor edita solo la tabella `ConfigEmailContent` (i template grezzi), disaccoppiato dal
codice che li userà davvero — vedi la spiegazione del flusso in
`FMGroup.Mail/PLACEHOLDERS.md` (registro condiviso, copia identica di questo stesso file nella
cartella corrente). Non conosce a priori quali placeholder di dominio compariranno in un dato
template, perché quelli li introduce liberamente ogni progetto consumer nel proprio codice.

## Possibile miglioramento futuro (non implementato — fuori scope al 2026-07-07)

`PLACEHOLDERS.md` (stessa cartella) ora riporta una colonna **Esempio** con un valore plausibile per
ogni placeholder noto, incluso quelli di dominio (`#TOTALEORDINE#`, `#NEWPARTNO#`, `#USERNAME#`,
ecc.) che oggi l'Email Editor ignora. Un'evoluzione possibile di `RefreshPreview` sarebbe sostituire
**genericamente** ogni placeholder `#NOME#` trovato nel template con il relativo valore di esempio,
leggendo l'elenco da una fonte machine-readable equivalente a `PLACEHOLDERS.md` (oggi è solo markdown
discorsivo, andrebbe strutturato — es. JSON/dizionario — per essere consumato dal codice), invece
dei 3-4 `.Replace()` hardcoded attuali.

**Attenzione se si implementa:** quella fonte dati andrebbe comunque mantenuta sincronizzata con
`PLACEHOLDERS.md`/la sua copia in `FMGroup.Mail` (stesso principio di sincronizzazione manuale già
in vigore tra le due copie del registro) — o si introdurrebbe un terzo punto da tenere allineato.

## Cosa NON fare senza richiesta esplicita

Non implementare questo miglioramento autonomamente: è documentato qui come nota per una sessione
futura, non come task da eseguire ora.
