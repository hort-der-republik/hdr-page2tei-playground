# Verarbeitungsregeln für `pagexml-to-tei.xsl`

Stand: 2026-09-23

Dies ist die lesbare Referenz für das, was das Stylesheet aktuell tut.
Änderungen/Ergänzungen bitte hier eintragen.

## 1. Grundstruktur

- Ein `<graphic>` (das ganze Digitalisat) direkt als Kind von `<facsimile>`.
- `<facsimile>` enthält die reine Bild-Geometrie: verschachtelte `<surface>` (für Regionen mit custom-type `surface`) und `<zone>` (für alle anderen Regionstypen).
- `<text><body>` spiegelt dieselbe Verschachtelung, aber mit der Transkription statt Koordinaten.
- Namespace-unabhängig: erkennt PAGE-Elemente über `local-name()`, egal ob eScriptorium (`.../2019-07-15`) oder Transkribus (`.../2013-07-15`) Export.

## 2. Surface-Erkennung und -Verschachtelung

- Regionen mit custom-type `surface` werden zu `<surface>`.
- Die äußerste surface heißt immer `base` (`@type="base"`). Erkennung in dieser Priorität:
  1. Region hat `cat:base`
  2. sonst, falls es nur eine surface-Region gibt: diese
  3. gibt es gar keine surface-Region im Dokument: eine synthetische Basis-Surface in Bildgröße wird erzeugt (`@type="base"`, ohne zugehörige Original-Region)
- Andere surfaces - ohne `cat:base` oder mit `cat:att` erhalten als `<div>` automatisch `@type="attached"` und  werden in die surface verschachtelt, die sie zu mindestens 95 % Flächenanteil enthält (kleinste passende); ohne passende surface: Kind der base-surface.

## 3. Zone-Verschachtelung (Regionen außer surface)

- Eine zone wird Kind der kleinsten anderen zone, die sie zu mindestens 95 % Flächenanteil enthält (Bounding-Box-Näherung: echte Polygonfläche ist in XSLT 1.0 nicht praktikabel, Bounding-Box reicht bei regionsgroßen Flächen aus).
- **Zusatzbedingung Polygon:** Zusätzlich zur 95-%-Bounding-Box-Regel muss der Mittelpunkt der Bounding-Box der Region im **echten Polygon** des Kandidaten (zone oder surface) liegen. Sonst würde eine schräge surface (deren Bounding-Box viel größer ist als das Polygon) Regionen am Rand fälschlich aufnehmen.
- Findet sich keine passende zone: Kind der kleinsten passenden surface.
- Findet sich gar nichts: Kind der base-surface (Fallback, damit nichts verloren geht).
- **Schutz gegen Zyklen:** eine Region kommt nur als Elternteil infrage, wenn sie mindestens so groß ist wie das Kind (bei exakt gleicher Fläche: `@id` als Tiebreak). Sonst könnten zwei fast gleich große Regionen sich gegenseitig als Elternteil wählen und beide würden nie gerendert.
- **Regel für metamarks:** wenn die zone metamark ist, wird sie nur dann zur Kindzone der kleinsten anderen, in der sie zu mindestens 95 % steckt, wenn sie nicht `@target` hat. Wenn sie `@target` hat, wird sie zum Kind der surface.

## 4. Zeilen-Zuordnung (welche TextRegion „besitzt“ eine Zeile)

- **Nicht** die PAGE-XML-Struktur wird vertraut (eine Zeile kann geometrisch in einer anderen Region liegen als der, in der sie in der Quelldatei steht).
- **Regel:** jede Zeile gehört zur kleinsten Region, deren Bounding-Box den **Mittelpunkt** der Zeilen-Bounding-Box enthält.
  - Eine wörtliche 95-%-Flächenregel wurde getestet und verworfen: PAGE-Regionen sind oft schräge Polygone, deren eigene Bounding-Box dadurch aufgebläht ist. Bei kleinen Zeilen fiel das so stark ins Gewicht, dass zusammenhängender Fließtext auseinandergerissen wurde. Der Mittelpunkt-Test ist robust dagegen.
- **Toleranz-Ausnahme:** liegt der Mittelpunkt nur knapp (höchstens 20 px, Parameter `lineAssignTolerance`) neben der Box der strukturellen Elternregion und würde die Zeile sonst einer **größeren** Region zufallen, bleibt sie bei ihrer Elternregion. Die Toleranz gilt nur für die Elternregion, nicht für beliebige Regionen.
- Kein Treffer: Zeile bleibt bei ihrer strukturellen Elternregion aus der PAGE-XML.
- **Reihenfolge** der Zeilen innerhalb einer Region: sortiert nach (Index der ursprünglichen/strukturellen Elternregion, dann eigener Zeilen-Index). Der Zeilen-Index in `@custom` ist nur pro Region relativ (fängt in jeder Region wieder bei 0 an), daher reicht er allein nicht als globaler Sortierschlüssel.
- Für Zeilen selbst werden eigene `<zone>`-Elemente in `facsimile` angelegt, und zwar innerhalb der zone, der sie nach den Zeilenzuordnungsregeln zugeordnet werden.

## 5. Regionstyp → TEI-Element (im Fließtext)

- `surface` → `<div>` (facs-Verweis auf die surface), äußerste mit `@type="base"`
- `column-block` → immer `<div type="column-block">`
- `add-block` → immer `<div type="add-block">`
- `head` (ohne Kind-Zonen) mit cat:main oder cat:sub  → `<head type="[cat-value]">`; mit cat:cross → `<p rendition="#crosshead">`
- `annotation` **und** `metamark` → `<metamark>`, mit eigener xml:id (siehe Abschnitt 8)
- `gap` → leeres `<gap/>` (kein Text-Inhalt; in den bisherigen Daten haben gap-Regionen ohnehin nie eigenen Text); Attribut `reason` inkl. Wert übernehmen
- `add` → `<add>` (siehe unten)
- `fw` → `<fw>`
- `advertisement` → `<div type="advertisement">`
- `long-quote-p` → tei:p in tei:quote; rendition wird bei p ergänzt (Attribut plus Wert mit vorangehendem "#");
- `long-quote-lg` → tei:lg in tei:quote; rendition wird bei p ergänzt (Attribut plus Wert mit vorangehendem "#"). ACHTUNG: statt tei:lb werden hier öffnende/schließende tei:l verwendet. 
- `paragraph` (ev. mit `part` und anderen Attributen) → `<p>`, Attribute und Werte werden 1:1 übernommen, außer: `hand-medium`, das ignoriert wird; single-p-article – bei Wert "y" erhält das den p umfassende `<div>´ den `@type` "article".
- `paragraph-indent`– genauso wie `paragraph`, aber in der rendition wird automatisch "#indent" ergänzt (wenn das händisch auch ergänzt wird, Wert nur einmal setzen)
- `masthead` wird zu `<div type="masthead>`, darin die anderen Zonen genestet
- alles andere (ohne Typangabe u. ä.) → `<p>`

Zusätze:

- **Jede Zone MIT Kind-Zonen** wird zu `<div>` (auch wenn ihr eigener Typ sonst ein anderer wäre), sonst wäre Text direkt im div, was TEI nicht erlaubt; eigener Zeilentext (falls vorhanden) landet dann als `<p>` darin. AUSNAHME: wenn die Kind-Zone mit "long-quote" beginnt. Dann wird Zone selbst zu p, weil das verschachtelte quote darin in tei erlaubt ist.
- **`add` (Regionstyp):** validiert **nicht** gegen TEI (add ist als phrasenwertiges/Inline-Element gedacht, nicht als Block-Kind eines div) – das ist bekannt und akzeptiert, wird manuell nachkorrigiert. Der Inhalt steht kompakt in einer Zeile (kein Umbruch/Einrückung direkt nach dem Start- bzw. vor dem Endtag), nur echte `<lb/>` bei mehreren TextLines bleiben erhalten.
- **Alles andere → `<p>`:** kein `@type`-Attribut (TEI-All erlaubt das auf `<p>` nicht); der Regionstyp bleibt über `@facs` an der entsprechenden `<zone type="...">` im facsimile nachvollziehbar.
- **Generische Regel:** Regionen mit `structure{rendition:[Wert];}` → zusätzlich `@rendition="#[Wert]"` auf dem `<p>`.

**Geschwister-Regel:** TEI erlaubt in einem `<div>` **keine** Mischung von `<p>`/`<head>` und `<div>` als direkte Geschwister (Content-Model verlangt entweder nur divLike- oder nur Fließtext-Kinder). Kommen beide Arten unter demselben Elternteil vor, werden die `<p>`/`<head>`-Kinder zusätzlich in ein `<div>` gewickelt. `<metamark>`, `<gap>` und `<fw>` brauchen das nicht (dürfen direkt neben `<div>` stehen): `<fw>` wird also nie in ein eigenes `<div>` gewickelt.

## 6. Transkribus-Relationen

- Relationen vom Typ `article` oder `montage-element` gruppieren ihre Mitglieder (vom Regionstyp `paragraph`/`paragraph-*`/`long-quote-*`/`head`/`gap`; andere/ungültige Verweise werden stillschweigend ignoriert) zusätzlich in ein `<div type="article">` bzw. `<div type="montage-element">`, das an der Stelle des zuerst gelesenen Mitglieds im umgebenden div steht.
- Die Relation `block-order` (verknüpft nur column-blocks) wird bewusst **nicht** verwendet – passt nicht ins Muster, wirkt wie reine Lesereihenfolge-Metadaten, die über den readingOrder-Index schon abgedeckt ist.
- `multi-p-quote` – verbindet 2-n Regionen mit `long-quote` im Namen, die dann aber nicht in separate, sondern in ein gemeinsames `tei:quote` gepackt werden sollen. 

Achtung: Wenn sich `article` oder `montage-element`-Relationen über hierarchische Grenzen hinweg spannen – etwa `<div type="column-block">` – sie mit einer xml:id ausstatten sowie mit `@next`/`@prev`, wo die Elemente aufeinander verweisen.

- `has-parent` – überschreibt die bisherige Zuordnung einer Region zu einer Elternregion (in body und in facsimile) und gibt stattdessen explizit an, in welche Region eine andere genestet werden soll (child > `has-parent` > parent)

## 7. Text-Annotationen innerhalb einer Zeile

Zeichenbasierte Blöcke in `@custom` von `<TextLine>` (offset/length relativ zum Zeilentext, z. B. `spacing {offset:5; length:10;}`).

### Einfache Abbildungen

- `spacing` → `<hi rend="letter-spacing">`
- `hi-spacing` → `<hi rend="letter-spacing">`
- `bold` → `<hi rend="bold">`
- `hi-bold` → `<hi rend="bold">`
- `hi-underline` → `<hi rend="underline">`
- `mod-underline` → `<mod rend="underline">` (siehe Hinweis unten)
- `del` (mit type) → `<del type="...">`
- `deselection` (ev. mit id und next) → `<del type="deselection">` 
- `mod` → `<mod rend="...">` (rend aus dem Block, wenn angegeben, sonst Default `underline`)
- `seg` (mit type) → `<seg type="...">`
- `gap` (mit reason/extent) → `<gap reason="..." extent="...">`
- `gap-cut` → `<gap reason="cut" extent="[Zahl der "#" im gap]"/>`
- `gap-ill` → `<gap reason="illegible" extent="[Zahl der "#" im gap]"/>`
  - Achtung: wenn in Ausdehnung identisch mit `del`, dann immer innerhalb des `del`.
- `add` (mit place) → `<add place="...">`
- `sic` (mit correction) → `<choice><sic>[Textknoten]</sic><corr>[Wert aus correction]</corr></choice>`
- `metamark` (mit function) → `<metamark function="...">`
- `head-run-in` → `<seg type="head-run-in">`
- `unclear` (mit reason/cert) → `<unclear reason="..." cert="...">`

### `seg-transposition`

→ `<seg type="transposition">`; Attribute `corresp` und `new-order`: Nach dem letzten der aufeinander über `corresp` verweisenden seg kommt ein `transposition`-Element, darin `listTranspose` und darin pointer (`ptr`) mit `@target`, die auf die seg-ids zeigen. Anordnung der `ptr` nach Wert in `new-order`. Wenn eines der Attribute/Werte fehlt (seg-transposition ohne `corresp` oder `new-order`): kein `listTranspose` bauen.

### `undo`

Wird zu zwei Elementen, die vor und nach dem Inhalt des Textknotens des ursprünglichen undo zu stehen kommen.

- Anfang: leeres Element `<undo spanTo="[id]">`
- Ende: `<anchor type="undo" xml:id="[id]">`
- `id` wird generiert wie in Abschnitt 8.
- Das Attribut `rend` wird zu `@rend`, `target` zu `@target`, Wert jeweils identisch; in `target` steht eine Behelfs-ID, die nach Abschnitt 8 ersetzt wird, hier und im Ausgangs-Element.

### `metamark-add` mit `add-id`

→ `<metamark function="addition"/>` + `<add>`-Element. Das `add` wird aus der in `add-id` referenzierten Region `add` gebaut, wobei die Zeilen-`facs` und die Regions-`facs` mit übernommen werden.

### `metamark` mit `function="insertion"`

Analog zu `metamark-add`: das in `target` referenzierte Element wird hier eingefügt.

- **Ketten:** ein metamark mit function insertion verweist auf die id eines zweiten metamark function insertion, das auf die id eines add verweist. In diesem Fall ist das add an der Position des **ersten**, nicht des mittleren metamarks in der Kette einzufügen.
- **Ausnahme dokumentübergreifender Verweis:** enthält ein Wert in `target` den Teilstring `.xml#` (z. B. `target:0003_406.xml#add-0003-0004`), ist das ein bereits fertiger Verweis auf ein Element in einer **anderen** Datei.
  - Er wird **nicht** als Behelfs-ID behandelt und nicht ersetzt, nichts wird eingesogen.
  - Die metamark bleibt als `<metamark function="insertion" target="0003_406.xml#add-0003-0004"/>` stehen, sonst alles wie gewohnt.
  - Mehrere durch `\u0020` getrennte Werte: jeder Wert mit `.xml#` bleibt unverändert, die übrigen werden normal als Behelfs-IDs ersetzt.

### `subst`

→ `<subst>`, automatisch erkannt als Container, wenn ein del- und ein add-Block innerhalb derselben Zeichenspanne liegen (Standard-TEI-Muster für Streichung+Ersetzung: `<subst><del>..</del><add>..</add></subst>`).

Zusatzregel: wenn ein `add` und ein anderes Element als `del` dieselben Zeichen beinhalten (also vom Inhalt her identisch sind), ist immer das `add` das äußere.

### `subst` mit child `del`, ohne child `add`, dafür mit Attribut `add-id`

Wie normales `subst`, bloß wird als `add` die Region `add` hereingeholt, die den entsprechenden Wert im Attribut `id` hat. `facs`-Wert der add-Region und Zeile sollen mit übernommen werden.

### `subst-del` mit Attributen `add-id` und `del-id`

Wie normales `subst`, bloß wird als `add` die Region `add` hereingeholt, die den entsprechenden Wert im Attribut `id` hat. `facs`-Wert der add-Region und Zeile sollen mit übernommen werden; `del` kriegt `del-id` als xml:id.

### Verschachtelung

Blöcke können sich überlappen/verschachteln (z. B. ein `del` innerhalb eines `seg-transposition`, oder `del`+`add` gemeinsam unter `subst`, oder mehrere `metamark` auf einer Zeile). Das wird als Baum über Zeichenbereiche behandelt: die kleinste andere Angabe, die einen Bereich vollständig umschließt, wird dessen Elternelement; Geschwister werden nach Offset sortiert mit dazwischenliegendem Klartext ausgegeben.

### Mehrzeilige Läufe

`continued:true` an einer **obersten** (nicht verschachtelten) Angabe heißt, der Lauf reicht über das Zeilenende hinaus und wird auf der nächsten Zeile (dort beginnend bei `offset:0`) fortgesetzt. Das wird zu **einem** durchgehenden Inline-Element, das `<lb/>` als Kind enthält (nicht mehrere separate Elemente).

### Bekannte Datenlücke (kein Code-Fehler)

Wenn die del/add-Kinder eines `subst` nicht die ganze deklarierte subst-Spanne abdecken, landet der Rest als nackter Text direkt in `<subst>`, was TEI dort verbietet. Muss im Einzelfall manuell nachkorrigiert werden.

## 7a. Textstring-Transformationen

### Metamarks

Die beiden metamarks dürfen sich in ihrer function nicht widersprechen (sondern z. B. die eine hat keinen Wert).

- `#del` → `<metamark function="deletion">`, darin ein `<g ref="#deleatur"/>` (die CharDecl dafür wird noch nachgereicht)
- `#ker` → `<metamark function="kerning">`, darin ein `<g ref="#kerning"/>`
- `#lSpc` → `<metamark function="line-spacing">`, darin ein `<g ref="#line-spacing"/>`
- `#rel` → `<metamark function="relocation">`, darin ein `<g ref="#relocation"/>`
- `#trans` → `<metamark function="transposition">`, darin ein `<g ref="#transposition"/>`
- `|` → wenn es nicht onlychild eines als Textannotation angelegten metamark ist: `<metamark function="intervention">`, darin ein `<g ref="#intervention"/>`; ansonsten einfach nur `<g ref="#intervention"/>`.

### Metamark-Grundregel

Wenn eine metamark nichts als ein `lb` und eine weitere metamark enthält, und sich die beiden metamarks in ihren Attributwerten nicht widersprechen (sondern nur ergänzen), dann wird nur die äußere metamark gebaut, diese aber mit den Attributen von beiden ausgestattet. Das `lb` wird dann direkt vor das in der metamark gebildete `g` gesetzt.

## 8. Element-IDs

**Jedes `<metamark>`** (aus Regionstyp `annotation` oder `metamark`) bekommt eine eigene xml:id:

- `metamark` + vierstellige Seitenzahl (aus dem Dateinamen: der Teil nach dem letzten `_`, auf mindestens 4 Stellen mit führenden Nullen aufgefüllt) + vierstellige laufende Nummer (in globaler Lesereihenfolge über den readingOrder-Index aller annotation/metamark-Regionen der Seite), immer durch `-` getrennt.
- Beispiel: `metamark-0108-0001`, `metamark-0108-0002`, …


**Jedes `<add>`** aus Regionstyp erhält eine eigene xml:id nach demselben Muster, Beispiel: `add-0108-0001`, `add-0108-0002`, …

**Behelfs-IDs** (kommen als Wert von Attribut `id` mit) werden nach demselben Muster ausgetauscht, sowohl dort, wo sie in xml:id stehen sollen, als auch dort, wo sie in anderen Attributen stehen (`target`, `corresp`, `next`, `prev` …). In manchen Attributen (`target`) können mehrere, durch Leerzeichen getrennte Behelfs-IDs stehen.

Behelfs-IDs können auch an Zeilen-Blöcken deklariert sein (`add`, `del`, `mod`/`mod-underline`, `seg`, `hi`-Typen, `unclear`, `metamark`, `subst-del` als `del-id`). Der Präfix ist der erzeugte Elementname (`del-0406-0001`, `mod-0406-0002`, …), die laufende Nummer zählt je Präfix in Dokumentreihenfolge. Trägt ein `continued:true`-Lauf dieselbe `id` auf mehreren Zeilenstücken, bekommt nur das erste Stück die `xml:id`.

**Ausnahme dokumentübergreifende ID:** enthält ein Wert von `id` den Teilstring `.xml#` (z. B. `id:0003_406.xml#add-0003-0004` auf einer Region `add-block`), ist das **keine** Behelfs-ID.

- Es wird nichts generiert und kein Zähler verbraucht; als xml:id wird einfach der Teil nach `#` übernommen (hier: `xml:id="add-0003-0004"`).
- So kann eine andere Datei per `target="0003_406.xml#add-0003-0004"` (siehe metamark insertion) genau auf dieses Element verweisen.
- Gilt für `id` auf Regionen (add-block, add, metamark, paragraph, …) und auf Zeilen-Blöcken (add `id`, subst-del `del-id`).
- Die Eindeutigkeit der xml:id (und dass sie nicht mit generierten IDs wie `add-0003-0004` kollidiert) liegt in der Verantwortung der Eingabe.

## 9. Formatierung

- Die Einrückungseinheit der manuellen Einrückung ist der Parameter `indentUnit` (Standard: 3 Leerzeichen wie bei Saxon/Oxygen; für `xsltproc` zwei Leerzeichen übergeben), damit `<lb/>`-Zeilen und automatisch eingerückte Tags bündig stehen.
- Einrückung wird manuell erzeugt (der Serialisierer indentiert bei gemischtem Inhalt/Text nicht automatisch): jedes `<lb/>` steht auf einer eigenen, zur Baumtiefe passend eingerückten Zeile.
- Ausnahme: `<add>` steht kompakt in einer Zeile (siehe Abschnitt 5), nur echte `<lb/>` zwischen mehreren TextLines bleiben als Markup erhalten, ohne Zeilenumbruch/Einrückung drumherum.

## 10. Bekannte, akzeptierte Validierungslücken

Gegen `tei_all.rng` geprüft (jing). Diese Fälle validieren **nicht**, sind aber bewusst so gewünscht bzw. Datenlücken, keine Stylesheet-Fehler:

- `<add>` als Regionstyp direkt im `<div>` (add ist phrasenwertig, kein Block-Kind) – manuell nachzukorrigieren
- `<subst>`, dessen add/del-Kinder die deklarierte Spanne nicht komplett abdecken (siehe Abschnitt 7) – Datenlücke im Export

## 11. Batch-Verarbeitung

`transform-all.sh` transformiert alle `.xml`-Dateien aus `./page-xml` nach `./tei-xml` (gleicher Dateiname), legt `./tei-xml` bei Bedarf an.
