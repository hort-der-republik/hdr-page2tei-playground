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
- Der `cat`-Wert der Region (z. B. `base`, `attached`) steht nirgendwo in der Ausgabe und dient nur zur Erkennung der base-surface und damit der Verschachtelung (siehe unten). `@type` an `<surface>` (in `facsimile`) und `<div>` (in `text/body`) kommt allein aus `subcat`, `@source` an `<surface>` aus `source` (siehe Abschnitt 5). Ohne `subcat` wird kein `@type` angelegt.
- Die äußerste surface heißt immer `base`. Erkennung in dieser Priorität:
  1. Region hat `cat:base`
  2. sonst, falls es nur eine surface-Region gibt: diese
  3. gibt es gar keine surface-Region im Dokument: eine synthetische Basis-Surface in Bildgröße wird erzeugt (ohne zugehörige Original-Region, ohne `@type`)
- Alle anderen surfaces werden in die surface verschachtelt, die sie zu mindestens 95 % Flächenanteil enthält (kleinste passende); ohne passende surface: Kind der base-surface.

## 3. Zone-Verschachtelung (Regionen außer surface)

- Eine zone wird Kind der kleinsten anderen zone, die sie zu mindestens 95 % Flächenanteil enthält (Bounding-Box-Näherung: echte Polygonfläche ist in XSLT 1.0 nicht praktikabel, Bounding-Box reicht bei regionsgroßen Flächen aus).
- **Zusatzbedingung Polygon:** Zusätzlich zur 95-%-Bounding-Box-Regel muss der Mittelpunkt der Bounding-Box der Region im **echten Polygon** des Kandidaten (zone oder surface) liegen. Sonst würde eine schräge surface (deren Bounding-Box viel größer ist als das Polygon) Regionen am Rand fälschlich aufnehmen.
- Findet sich keine passende zone: Kind der kleinsten passenden surface.
- Findet sich gar nichts: Kind der base-surface (Fallback, damit nichts verloren geht).
- **Schutz gegen Zyklen:** eine Region kommt nur als Elternteil infrage, wenn sie mindestens so groß ist wie das Kind (bei exakt gleicher Fläche: `@id` als Tiebreak). Sonst könnten zwei fast gleich große Regionen sich gegenseitig als Elternteil wählen und beide würden nie gerendert.
- **Regel für metamarks:** wenn die zone metamark ist, wird sie nur dann zur Kindzone der kleinsten anderen, in der sie zu mindestens 95 % steckt, wenn sie nicht `@target` hat. Wenn sie `@target` hat, wird sie zum Kind der surface.

## 4. Zeilen-Zuordnung (welche TextRegion „besitzt“ eine Zeile)

- Wenn eine Region das Attribut "fixed-lines" mit Wert "y" hat, bleiben die Zeilen in der Region dem aus dieser Region erstellten Element zugeordnet, im `<facsimile>` sowie im `<text>`. 

In allen anderen Fällen gilt:
- **Nicht** die PAGE-XML-Struktur wird vertraut (eine Zeile kann geometrisch in einer anderen Region liegen als der, in der sie in der Quelldatei steht).
- **Regel:** jede Zeile gehört zur kleinsten Region, deren Bounding-Box den **Mittelpunkt** der Zeilen-Bounding-Box enthält.
  - Eine wörtliche 95-%-Flächenregel wurde getestet und verworfen: PAGE-Regionen sind oft schräge Polygone, deren eigene Bounding-Box dadurch aufgebläht ist. Bei kleinen Zeilen fiel das so stark ins Gewicht, dass zusammenhängender Fließtext auseinandergerissen wurde. Der Mittelpunkt-Test ist robust dagegen.
- **Zusatzbedingung Polygon:** Eine Region, die nicht die strukturelle Elternregion der Zeile ist, zählt nur, wenn der Mittelpunkt auch im **echten Polygon** der Region liegt (nicht nur in ihrer Bounding-Box). Sonst „klaut“ eine Region mit gezackter/schräger Form, deren Bounding-Box viel zu groß ist, Zeilen aus ihrer Umgebung.
- **Toleranz-Ausnahme:** liegt der Mittelpunkt nur knapp (höchstens 20 px, Parameter `lineAssignTolerance`) neben der Box der strukturellen Elternregion und würde die Zeile sonst einer **größeren** Region zufallen, bleibt sie bei ihrer Elternregion. Die Toleranz gilt nur für die Elternregion, nicht für beliebige Regionen.
- Kein Treffer: Zeile bleibt bei ihrer strukturellen Elternregion aus der PAGE-XML.
- **Reihenfolge** der Zeilen innerhalb einer Region: Zeilen derselben ursprünglichen (strukturellen) Elternregion behalten ihre Reihenfolge nach eigenem Zeilen-Index (`readingOrder`; er ist nur pro Region relativ und fängt in jeder Region wieder bei 0 an). Zeilen, die per Geometrie aus einer **anderen** Elternregion in die Region gewandert sind, werden nach ihrer Lage einsortiert:
  - Verglichen wird ein entzerrtes `y' = y − m·x` am Mittelpunkt der Baseline (Mitte zwischen erstem und letztem Baseline-Punkt). `m` ist der Median der Baseline-Steigungen der Region (bei |m| > 1 wird 0 verwendet), so dass auch stark ansteigende Zeilen richtig verglichen werden.
  - Unterscheiden sich zwei Zeilen unterschiedlicher Elternregionen in `y'` um mehr als 0,3 × (Median der Bounding-Box-Höhe der Zeilen der Region), steht die mit dem kleineren `y'` zuerst. Bei kleineren Unterschieden ("gleiche Reihe") entscheidet die x-Position (links vor rechts), dann Index der Elternregion und Zeilen-Index.
  - Ein `continued:true`-Lauf über mehrere Zeilen derselben Elternregion wird als Einheit einsortiert (mit `y'`/x der ersten Zeile des Laufs), damit keine fremde Zeile mitten in den Lauf gerät.
  - Technisch: Jede Zeile bekommt einen `rank` (Zahl der Zeilen der Region, die vor ihr stehen); sortiert wird nach `rank`, dann Index der Elternregion, dann Zeilen-Index.
- Regionen werden zu `<zone>` **ohne `@type`** (der Regionstyp wird nicht mehr übernommen; nur die Zeilen-zones behalten `type="line"`).
- Für Zeilen selbst werden eigene `<zone>`-Elemente in `facsimile` angelegt, und zwar innerhalb der zone, der sie nach den Zeilenzuordnungsregeln zugeordnet werden.


## 5. Regionstyp → TEI-Element (in TEI/text/body)

- `surface` → `<div>` (facs-Verweis auf die surface). Behandlung der Attribute cat / subcat / source: 
    - Der `cat`-Wert steht nirgendwo und dient nur noch zur Verschachtelung von surface und div, siehe oben.
    - Der `subcat`-Wert steht in `<surface @type>` und in `<div @type>`
    - Der `source`-Wert steht in `<surface @source>`
- `column-block` → wird zu einem leeren tag **vor** den darin genesteten Regionen / Elementen, nämlich zu `<cb />`; es übernimmt den `block-extent`-Wert als TEI-Attribut `@n`.
- `add-block` → immer `<div type="add-block">`; wird **nie** per `add-id` oder `target` in eine `metamark` „eingesogen“, sondern bleibt an seiner eigenen Stelle (siehe Abschnitt 7); `rendition` der Region wird mit `#` übernommen
- `head` (ohne Kind-Zonen) mit cat:main oder cat:sub  → `<head type="[cat-value]">`; mit cat:cross → `<p rendition="#crosshead">`; **alle** `rendition`-Werte der head-Region werden (jeweils mit "#") auf `<head>` bzw. `<p>` übernommen, bei cat:cross zusätzlich zu `#crosshead`
- `annotation` **und** `metamark` → `<metamark>`, mit eigener xml:id (siehe Abschnitt 8); `rendition` der Region wird (jeweils mit `#`) übernommen
- `gap` → leeres `<gap/>` (kein Text-Inhalt; in den bisherigen Daten haben gap-Regionen ohnehin nie eigenen Text); Attribut `reason` inkl. Wert übernehmen
- `add` → `<add>` (siehe unten); `rendition` der Region wird (jeweils mit `#`) übernommen, auch am eingesogenen `<add>`
- `fw` → `<fw>`, der Wert von `cat` (z. B. `cat:fol`) wird als `@type` übernommen; innerhalb des `<div>`, dem es zugeordnet wird, steht es immer am **Anfang** (vor Text und den übrigen Kindern; mehrere `fw` untereinander in der bisherigen Reihenfolge)
- `advertisement` → `<div type="advertisement">`
- `long-quote-p` → tei:p in tei:quote; rendition wird bei p ergänzt (Attribut plus Wert mit vorangehendem "#");
- `long-quote-lg` → tei:lg in tei:quote; rendition wird bei p ergänzt (Attribut plus Wert mit vorangehendem "#"). ACHTUNG: statt tei:lb werden hier öffnende/schließende tei:l verwendet. 
- `paragraph` (ev. mit `part` und anderen Attributen) → `<p>`, Attribute und Werte werden 1:1 übernommen, außer: `hand-medium`, das ignoriert wird; single-p-article – bei Wert "y" erhält das den p umfassende `<div>´ den `@type` "article".
- `paragraph-indent`– genauso wie `paragraph`, aber in der rendition wird automatisch "#indent" ergänzt (wenn das händisch auch ergänzt wird, Wert nur einmal setzen)
- `masthead` wird zu `<div type="masthead">`, darin die anderen Zonen genestet
- `byline` wird zu `<byline>`, rendition wird übernommen, id als xml:id; `change` aus der Region wird als `@change` übernommen und liefert wie bei den anderen Elementen die change-abhängige `rendition` (Abschnitt 9, z. B. `#black-letter`)
- `dateline` wird zu `<dateline>`, rendition wird übernommen, id als xml:id; `change` aus der Region wird als `@change` übernommen und liefert wie bei den anderen Elementen die change-abhängige `rendition` (Abschnitt 9, z. B. `#black-letter`)
- alles andere (ohne Typangabe u. ä.) → `<p>`


### Zusätze:

- **Jede Zone MIT Kind-Zonen** wird zu `<div>` (auch wenn ihr eigener Typ sonst ein anderer wäre), sonst wäre Text direkt im div, was TEI nicht erlaubt; eigener Zeilentext (falls vorhanden) landet dann als `<p>` darin. AUSNAHME: wenn die Kind-Zone mit "long-quote" beginnt. Dann wird Zone selbst zu p, weil das verschachtelte quote darin in tei erlaubt ist.
- **`add` (Regionstyp):** validiert **nicht** gegen TEI (add ist als phrasenwertiges/Inline-Element gedacht, nicht als Block-Kind eines div) – das ist bekannt und akzeptiert, wird manuell nachkorrigiert. Der Inhalt steht kompakt in einer Zeile (kein Umbruch/Einrückung direkt nach dem Start- bzw. vor dem Endtag), nur echte `<lb/>` bei mehreren TextLines bleiben erhalten.
- **Alles andere → `<p>`:** kein `@type`-Attribut (TEI-All erlaubt das auf `<p>` nicht); `@facs` verweist auf die entsprechende `<zone>` im facsimile.
- **Generische Regel:** Regionen mit `structure{rendition:[Wert];}` → zusätzlich `@rendition="#[Wert]"` auf dem `<p>`.

**Geschwister-Regel:** TEI erlaubt in einem `<div>` **keine** Mischung von `<p>`/`<head>` und `<div>` als direkte Geschwister (Content-Model verlangt entweder nur divLike- oder nur Fließtext-Kinder). Kommen beide Arten unter demselben Elternteil vor, werden die `<p>`/`<head>`-Kinder zusätzlich in ein `<div>` gewickelt. `<metamark>`, `<gap>` und `<fw>` brauchen das nicht (dürfen direkt neben `<div>` stehen): `<fw>` wird also nie in ein eigenes `<div>` gewickelt.

### metamark-shortcuts
- `metamark-deleatur` bezeichnet die häufige Kombination aus Korrekturfähnchen + deleatur und wird zu `<metamark function="deletion">`, weitere Attribute werden wie gehabt übernommen: `@target`aus target, `@corresp` aus corresp, id siehe unten; die Textzeile darin - wenn sie keinen Text enthält - kriegt automatisch diesen Inhalt: `<g ref="#intervention"/> <g ref="#deleatur"/>` `rendition` der Region wird wie bei `metamark` übernommen.

## 6. Transkribus-Relationen

- Relationen vom Typ `article` oder `montage-element` gruppieren ihre Mitglieder (vom Regionstyp `paragraph`/`paragraph-*`/`long-quote-*`/`head`/`gap`; andere/ungültige Verweise werden stillschweigend ignoriert) zusätzlich in ein `<div type="article">` bzw. `<div type="montage-element">`, das an der Stelle des zuerst gelesenen Mitglieds im umgebenden div steht. Die Relationen geben auch die Reihenfolge der verknüpften Elemente zueinander an.
- Die Relation `block-order` (verknüpft nur column-blocks) gibt die Anordnung der column-block-Regionen an und legt fest, in welcher Reihenfolge deren Inhalte im TEI-XML angeordnet werden (column-block selbst wird ja nur zu einem `<cb n="..."/>`-tag, siehe oben).
- `multi-p-quote` – verbindet 2-n Regionen mit `long-quote` im Namen, die dann aber nicht in separate, sondern in ein gemeinsames `tei:quote` gepackt werden sollen.
- `paragraph` verbindet Regionen des Typ paragraph / paragraph-* / long-quote* / metamark, die nicht getrennt, sondern gemeinsam in ein `<p>`gepackt werden sollen - in der Reihenfolge wie durch die relation angegeben. Rendition der ersten paragraph / paragraph-* wird für den parent-p übernommen; andere renditions bei genesteten quote/p oder metamark werden wie gehabt behandelt.

Achtung: Wenn sich `article` oder `montage-element`-Relationen über hierarchische Grenzen hinweg spannen – sie mit einer xml:id ausstatten sowie mit `@next`/`@prev`, wo die Elemente aufeinander verweisen.

`<div type="article">` mit `@prev` und/oder `@next` bekommt zusätzlich ein `@part`: nur `prev` → `part="F"`, nur `next` → `part="I"`, beides → `part="M"`. `<div type="montage-element">` bekommt kein `@part`.

- `has-parent` – überschreibt die bisherige Zuordnung einer Region zu einer Elternregion (in body und in facsimile) und gibt stattdessen explizit an, in welche Region eine andere genestet werden soll (child > `has-parent` > parent)

## 7. Text-Annotationen innerhalb einer Zeile

Zeichenbasierte Blöcke in `@custom` von `<TextLine>` (offset/length relativ zum Zeilentext, z. B. `spacing {offset:5; length:10;}`).

### Einfache Abbildungen

**Zum Attribut `rendition` in den Inline-Blöcken (gilt für `hi`, `mod`, `seg`, `undo` usw.):** Der Block-Schlüssel `rendition` wird als TEI-Attribut `@rendition` ausgegeben, **jeder** Wert mit vorangestelltem `#` (Pointer auf die rendition-Definition). Mehrere Werte sind durch `\u0020` oder Leerzeichen getrennt; ein bereits vorhandenes `#` wird nicht verdoppelt. Der frühere Schlüssel `rend` wird **nicht mehr gelesen** (und nicht mehr als `@rend` ausgegeben).

- `spacing` → `<hi rendition="#letter-spacing">`
- `hi-spacing` → `<hi rendition="#letter-spacing">`
- `hi-bold` → `<hi rendition="#bold">`
- `hi-underline` → `<hi rendition="#underline">`
- `hi-latin` → `<hi rendition="#latin">`
- `hi` mit Attr. `rendition` →  übernehmen als `<hi rendition="#[rendition]">`
- `mod-underline` → `<mod rendition="#underline">` (siehe Hinweis unten)
- `del` (mit cat) → `<del type="...">`; wenn mit id und next > stattdessen zu Beginn des Textknotens ein delSpan, nach dem Textknoten einen `<anchor>`  setzen (in delSpan und im `<anchor>` selben type übernehmen, target zeigt auf anchor-id, diese nach Schema s.u. vergeben)
- `deselection` → `<del type="deselection">`; wenn mit id und next > stattdessen zu Beginn des Textknotens ein delSpan, nach dem Textknoten einen `<anchor>`  setzen (in delSpan und im `<anchor>` selben type übernehmen, target zeigt auf anchor-id, diese nach Schema s.u. vergeben)
Wenn del oder deselection über id/next verbunden sind, aber unterschiedliche change-Werte haben, wird im delSpan der des ersten übernommen, der zweite entfällt.
- `mod` → `<mod rendition="...">` (rendition aus dem Block, wenn angegeben, sonst Default `#underline`)
- `seg` (mit cat) → `<seg type="...">`; rendition übernehmen, id siehe Behelfs-ids
- `seg-relocation` → `<seg type="relocation">`; rendition übernehmen, id siehe Behelfs-ids
- `seg-transposition` → `<seg type="transposition">`; `subcat` → `@subtype`; rendition übernehmen, wenn keine eingetragen ist: standardmäßig `#transposition-sign`; id siehe Behelfs-ids
- `gap` (mit reason/extent) → `<gap reason="..." extent="...">`
- `gap-cut` → `<gap reason="cut" extent="[Zahl der "#" im gap]"/>`
- `gap-ill` → `<gap reason="illegible" extent="[Zahl der "#" im gap]"/>`
  - Achtung: wenn in Ausdehnung identisch mit `del`, dann immer innerhalb des `del`; das gilt auch für `subst-del` (das gap steht dann im `del` des `subst`).
- `add` (ggf. mit place) → `<add place="...">`
- `sic` (mit correction) → `<choice resp="#edHdR"><sic>[Textknoten]</sic><corr type="[cat des sic, sonst emen]">[Wert aus correction]</corr></choice>`
  - `choice` bekommt immer `resp="#edHdR"`; der `cat`-Wert des `sic`-Blocks wird als `@type` an `corr` übernommen, ohne `cat` ist `type="emen"` (Default).
  - `choice`, `sic` und `corr` bekommen kein `@change` (und damit auch keine change-abhängige rendition).
- `metamark` (mit function, target, id, corresp) → `<metamark function="..." target="[siehe ID-Regeln]" xml:id="[siehe ID-Regeln]" corresp="[siehe ID-Regeln]">`

- `head-run-in` → `<seg type="head-run-in">`, ggf. auch rendition übernehmen
- 'dateline'  → `<seg type="dateline">`, ggf. auch rendition übernehmen
- `unclear` (mit reason/cert/resp) → `<unclear reason="..." cert="..." resp="...">`
  - Wenn nicht anders angegeben, gelten die Defaults `reason="illegible"`, `cert="medium"` und `resp="#edHdR"`.
  - `unclear` bekommt keine change-abhängige `rendition` (nur das `@change` selbst bleibt).
- `retrace` (mit change) → `<retrace change="[siehe Abschnitt change-Werte unten]">...</retrace>`

### `seg-transposition`

→ `<seg type="transposition">`; Attribut `subcat` wird 1:1 als `@subtype` ins `<seg>` übernommen. Attribute `other-seg` (Verweis auf das andere bzw. die anderen segs, die neu geordnet werden sollen; Behelfs-ID(s), mehrere durch `\u0020` getrennt) und `new-order`: Nach dem letzten der aufeinander über `other-seg` verweisenden seg kommt ein `transposition`-Element, darin `listTranspose` und darin pointer (`ptr`) mit `@target`, die auf die seg-ids zeigen. Anordnung der `ptr` innerhalb von `listTranspose` nach Wert in `new-order`. Wenn eines der Attribute/Werte fehlt (seg-transposition ohne `other-seg` oder `new-order`): kein `listTranspose` bauen. `other-seg` und `new-order` werden nicht als Attribute ausgegeben.

### `undo`

Wird zu zwei Elementen, die vor und nach dem Inhalt des Textknotens des ursprünglichen undo zu stehen kommen.

- Anfang: leeres Element `<undo spanTo="[id]">`
- Ende: `<anchor type="undo" xml:id="[id]">`
- `id` wird generiert wie in Abschnitt 8.
- **`continued:true`:** Setzt sich ein `undo` mit `continued:true` auf der nächsten Zeile (bei `offset:0`) mit einem weiteren `undo`-Block fort, bilden diese Stücke **ein** Paar: `<undo>` nur am Anfang des ersten Stücks, `<anchor>` nur am Ende des letzten (Attribute und `id` des Paars vom ersten Stück). Die anchor-Nummer zählt je Paar, nicht je Stück.
- **Gleicher Bereich wie `metamark-add`:** Fällt ein `undo` exakt mit einer `metamark-add` zusammen, umschließt das `undo` die `metamark` samt dem eingefügten `add`: `<undo spanTo="#a"/><metamark function="addition"/><add>…</add><anchor type="undo" xml:id="a"/>`.
- Das Attribut `rendition` wird zu `@rendition` (jeder Wert mit `#` davor, z. B. `rendition:wavy-line` → `rendition="#wavy-line"`), `target` zu `@target` und `corresp` zu `@corresp`, Wert jeweils identisch (außer dem `#` bei `rendition`); in `target` und `corresp` steht eine Behelfs-ID, die nach Abschnitt 8 ersetzt wird, hier und im Ausgangs-Element.

### `metamark-add` mit `add-id`

→ `<metamark function="addition"/>` + `<add>`-Element. Das `add` wird aus der in `add-id` referenzierten Region `add` gebaut, wobei die Zeilen-`facs` und die Regions-`facs` mit übernommen werden. Verweist `add-id` auf einen **Zeilen-`add`** (`add {offset:..; length:..; id:..}` in einer TextLine, keine Region), wird dessen Zeichenbereich an der Importstelle als `<add facs="#zone_[Quellzeile]">` ausgegeben und an seiner eigenen Stelle unterdrückt (gilt ebenso für `subst`/`subst-del` mit `add-id`). Zeigt `add-id` auf eine `add-block`-Region, wird nichts eingesogen; die `<metamark function="addition">` verweist dann per `@target` auf deren `<div type="add-block">`. Eine `id` an der `metamark-add` wird zur `xml:id` der `<metamark>` (z. B. als Ziel eines `undo`; Nummerierung wie bei den übrigen `metamark`-IDs); hat sie denselben Wert wie die per `add-id` referenzierte Region, zählt sie nicht als eigene Deklaration.

### `metamark` mit `function="addition"` (auch `add`) und `target` auf ein `add`

Zeigt `target` auf ein `add` (Zeilen-`add` mit dieser `id` oder `add`-Region), wird das `add` wie bei `metamark-add` direkt hinter der `<metamark>` eingefügt und an seiner eigenen Stelle unterdrückt; der entsprechende Wert entfällt dann im `@target` der `<metamark>` (bleibt kein Wert übrig, gibt es kein `@target`). `function` bleibt, wie angegeben.

### `metamark` mit `function="insertion"`

Analog zu `metamark-add`: die in `target` referenzierte `add`-Region wird hier als `<add>` eingefügt. `add-block`-Regionen werden nie eingesogen; die `<metamark>` behält dann ihr `@target` auf das `<div type="add-block">`.

- **Ketten:** ein metamark mit function insertion verweist auf die id eines zweiten metamark function insertion, das auf die id eines add verweist. In diesem Fall ist das add an der Position des **ersten**, nicht des mittleren metamarks in der Kette einzufügen.
- **Ausnahme dokumentübergreifender Verweis:** enthält ein Wert in `target` den Teilstring `.xml#` (z. B. `target:0003_406.xml#add-0003-0004`), ist das ein bereits fertiger Verweis auf ein Element in einer **anderen** Datei.
  - Er wird **nicht** als Behelfs-ID behandelt und nicht ersetzt, nichts wird eingesogen.
  - Die metamark bleibt als `<metamark function="insertion" target="0003_406.xml#add-0003-0004"/>` stehen, sonst alles wie gewohnt.
  - Mehrere durch `\u0020` getrennte Werte: jeder Wert mit `.xml#` bleibt unverändert, die übrigen werden normal als Behelfs-IDs ersetzt.

### `subst`

→ `<subst>`, Container, der zusammengehörige del und add umfasst (Standard-TEI-Muster für Streichung+Ersetzung: `<subst><del>..</del><add>..</add></subst>`). Eine `id` am `subst`-Block wird zur `xml:id` des `<subst>` (Behelfs-ID, Präfix `subst`, z. B. `subst-0108-0001`).

Zusatzregel: wenn ein `add` und ein anderes Element als `del` dieselben Zeichen beinhalten (also vom Inhalt her identisch sind), ist immer das `add` das äußere.

### `subst` mit child `del`, ohne child `add`, dafür mit Attribut `add-id`

Wie normales `subst`, bloß wird als `add` die Region `add` hereingeholt, die den entsprechenden Wert im Attribut `id` hat. `facs`-Wert der add-Region und Zeile sollen mit übernommen werden.

### `subst-del` mit Attributen `add-id`, `del-id`, `del-cat` und `subst-id`

Wie normales `subst`, bloß wird als `add` die Region `add` hereingeholt, die den entsprechenden Wert im Attribut `id` hat. `facs`-Wert der add-Region und Zeile sollen mit übernommen werden; `del` kriegt `del-id` als xml:id und `del-cat` als `@type`; das erzeugte `<subst>` kriegt `subst-id` als xml:id (Behelfs-ID, Präfix `subst`, gemeinsamer Zähler mit den `subst`-Blöcken mit `id`).

**Mehrzeilig** (`continued:true`, siehe „Mehrzeilige Läufe“): Die Zeilenstücke werden nicht zeilenweise verarbeitet, sondern ergeben **ein** `<subst>` mit **einem** mehrzeiligen `<del>` (die `<lb/>` stehen darin) und dem importierten `<add>` nur **einmal**, am Ende hinter dem `</del>`. Attribute (`change`, `del-id`, `del-cat`) kommen vom ersten Zeilenstück.

### Verschachtelung

Blöcke können sich überlappen/verschachteln (z. B. ein `del` innerhalb eines `seg-transposition`, oder `del`+`add` gemeinsam unter `subst`, oder mehrere `metamark` auf einer Zeile). Das wird als Baum über Zeichenbereiche behandelt: die kleinste andere Angabe, die einen Bereich vollständig umschließt, wird dessen Elternelement; haben mehrere Angaben exakt denselben Bereich, gilt die Reihenfolge in `@custom`: die zuerst genannte ist außen, die zuletzt genannte innen, und ein weiterer Block in diesem Bereich hängt am innersten (zuletzt genannten); (davon unberührt bleiben die Sonderregeln für `add`, `gap`/`del` und `undo`/`metamark-add`); Geschwister werden nach Offset sortiert mit dazwischenliegendem Klartext ausgegeben. 

### Mehrzeilige Läufe

`continued:true` an einer Angabe heißt, der Lauf reicht über das Zeilenende hinaus und wird auf der nächsten Zeile (dort beginnend bei `offset:0`) fortgesetzt. Das wird zu **einem** durchgehenden Inline-Element, das `<lb/>` als Kind enthält (nicht mehrere separate Elemente). Das `<lb/>` steht im innersten Element, das sich fortsetzt. Das gilt für alle zeichenbasierten Elemente außer den unten genannten Ausnahmen, z. B. `hi`, `mod`, `seg`, `unclear`, `metamark` und `retrace`.

- **Fortsetzung erkannt**, wenn die Angabe bis zum Zeilenende reicht (dahinter höchstens Leerzeichen) und die Folgezeile bei `offset:0` eine Angabe mit gleichem Element und gleichen Attributen hat (`id`, `prev`, `next` zählen dabei nicht).
- **Mit Kindern:** Auch Angaben mit verschachtelten Angaben (Kindern) laufen über die Zeilengrenze, **wenn die Kinder immer sowohl innerhalb des Elements beginnen als auch enden**: Eine verschachtelte Angabe läuft nur mit, wenn auch ihr Elternelement weiterläuft und ihr Fortsetzungsstück im Fortsetzungsstück des Elternelements liegt (oberste Angaben: beide Stücke ohne Elternteil). Beispiel: `bold` ⊃ `mod-underline` ⊃ `undo`, alle mit `continued:true`, ergibt je EIN `<hi>` und EIN `<mod>` mit `<lb/>` darin.
- **Sonst** (ein Kind läuft über das Zeilenende, sein Elternelement aber nicht; oder die Fortsetzung hat andere Attribute oder liegt in einem anderen Elternbereich): ein eigenes Element pro Zeile.
- **Ausnahmen**, die nie zu einem Element zusammengefasst werden: `undo` und `del`/`deselection`-Ketten (Meilensteinpaare, siehe dort) sowie `subst`, `gap` und die Sonderformen `metamark-add` und `sic`. (`subst-del` läuft dagegen mit, siehe dort.)

### Bekannte Datenlücke (kein Code-Fehler)

Wenn die del/add-Kinder eines `subst` nicht die ganze deklarierte subst-Spanne abdecken, landet der Rest als nackter Text direkt in `<subst>`, was TEI dort verbietet. Muss im Einzelfall manuell nachkorrigiert werden.

**Ausnahme Leerzeichen:** Besteht der Rest direkt im `<subst>` (z. B. zwischen `del` und `add`) nur aus Leerzeichen, wird er automatisch in `<del subtype="implicit">` gesetzt, z. B. `<subst><del>Ei</del><del subtype="implicit"> </del><add>Die</add></subst>`. Anderer Resttext bleibt nackt stehen und ist weiterhin manuell nachzukorrigieren.

## 7a. Textstring-Transformationen

### Metamark-Regionen plus Textstring-Kürzel

Die Metamark-Region enthält maximal einen pipe-Charakter mit  Leerzeichen danach und dann eines der folgenden Kürzel – pipe wird zu `<g ref="#intervention"/>`, das Kürzel wird folgendermaßen verarbeitet und hat folgenden EInfluss auf das aus der Region generierte `<metamark>`:
- `#del` → Regionen-`<metamark>` wird `<metamark function="deletion">`, Kürzel selbst zu `<g ref="#deleatur"/>` (die CharDecl dafür wird noch nachgereicht)
- `#ker` → Regionen-`<metamark>` wird `<metamark function="kerning">`, Kürzel selbst zu `<g ref="#kerning"/>`
- `#lSpc`  → Regionen-`<metamark>` wird  `<metamark function="line-spacing">`, Kürzel selbst zu `<g ref="#line-spacing"/>`
- `#rel` → Regionen-`<metamark>` wird `<metamark function="relocation">`, Kürzel selbst zu `<g ref="#relocation"/>`
- `#trans` → Regionen-`<metamark>` wird `<metamark function="transposition">`, Kürzel selbst zu `<g ref="#transposition"/>`
- `#spcIns` → Regionen-`<metamark>` wird  `<metamark function="space-insert">`, Kürzel selbst zu `<g ref="#space-insert"/>`
- `|` → `<g ref="#intervention"/>`.

### Metamark-Grundregel

Wenn eine metamark nichts als ein `lb` und eine weitere metamark enthält, und sich die beiden metamarks in ihren Attributwerten nicht widersprechen (sondern nur ergänzen), dann wird nur die äußere metamark gebaut, diese aber mit den Attributen von beiden ausgestattet. Das `lb` wird dann direkt vor das in der metamark gebildete `g` gesetzt.

### gap aus `##``
Wenn mehr als ein `#` aufeinanderfolgt, das nicht als gap annotiert ist, soll das automatisch als `<gap reason="illegible" extent="[Anzahl der #]"/>`ausgegeben werden.

### Zeilenend-Trennzeichen („-“ und „⸗“)

Gilt für die Zeichen „-“ (Bindestrich) und „⸗“ (doppelter Schrägstrich-Trennstrich), wenn sie das **letzte Zeichen einer Zeile** sind (dahinter nur Whitespace; kein Text und kein `<gap/>`/`<g/>` bis zum nächsten `<lb/>`):

1. Sind sie **nicht** als `hyphen` getaggt (kein `hyphen`-Block, der das letzte Zeichen der Zeile abdeckt), werden sie automatisch in `<pc force="weak">` gepackt, z. B. `uner<pc force="weak">⸗</pc>`. Steht das Zeichen schon in einem `<pc>`, passiert nichts.
2. **Unabhängig** davon, ob sie als `hyphen` getaggt sind oder nicht, bekommt das darauffolgende `<lb/>` das Attribut `break="no"`.

## 8. Element-IDs

**Jedes `<metamark>`** (aus Regionstyp `annotation` oder `metamark`) bekommt eine eigene xml:id:

- `metamark` + vierstellige Seitenzahl (aus dem Dateinamen: der Teil nach dem letzten `_`, auf mindestens 4 Stellen mit führenden Nullen aufgefüllt) + vierstellige laufende Nummer (in globaler Lesereihenfolge über den readingOrder-Index aller annotation/metamark-Regionen der Seite), immer durch `-` getrennt.
- Beispiel: `metamark-0108-0001`, `metamark-0108-0002`, …


**Jedes `<add>`** aus Regionstyp erhält eine eigene xml:id nach demselben Muster, Beispiel: `add-0108-0001`, `add-0108-0002`, …

**Behelfs-IDs** (kommen als Wert von Attribut `id` mit) werden nach demselben Muster ausgetauscht, sowohl dort, wo sie in xml:id stehen sollen, als auch dort, wo sie in anderen Attributen stehen (`target`, `corresp`, `next`, `prev` …). In manchen Attributen (`target`) können mehrere, durch Leerzeichen getrennte Behelfs-IDs stehen.

Behelfs-IDs können auch an Zeilen-Blöcken deklariert sein (`add`, `del`, `mod`/`mod-underline`, `seg`, `hi`-Typen, `unclear`, `metamark`, `subst`, `subst-del` als `del-id` (für das `del`) und als `subst-id` (für das `subst`)). Der Präfix ist der erzeugte Elementname (`del-0406-0001`, `mod-0406-0002`, …), die laufende Nummer zählt je Präfix in Dokumentreihenfolge. Trägt ein `continued:true`-Lauf dieselbe `id` auf mehreren Zeilenstücken, bekommt nur das erste Stück die `xml:id`.

**`add-block` mit Behelfs-ID:** Die Region wird nie als `<add>` eingesogen, sondern bleibt `<div type="add-block">` und bekommt als `xml:id` eine ID mit Präfix `div` (`div-0180-0001`); Verweise (`target`, `add-id`) lösen auf diese ID auf.

**Doppelt vergebene Behelfs-IDs:** Wird derselbe Wert mehrfach deklariert (an Regionen per `structure{id}`, an Zeilen-Blöcken per `id`, `subst-id`, `del-id`), entscheidet das Stylesheet **nicht**, worauf sich ein Verweis bezieht (`target`/`corresp`/`add-id` lösen wie bisher auf die erste Deklaration auf, Regionen vor Zeilen-Blöcken). Stattdessen gibt die Transformation eine Warnung aus (`WARNUNG: Behelfs-ID "…" ist mehrfach vergeben: …`), die `transform.sh` im Terminal und im Report ausweist. Ausnahme: Stücke eines `continued:true`-Laufs mit derselben `id` zählen als eine Deklaration. Das `<subst>` aus `subst-id`/`id` bekommt dabei trotzdem seine eigene ID mit Präfix `subst`.

**Ausnahme dokumentübergreifende ID:** enthält ein Wert von `id` den Teilstring `.xml#` (z. B. `id:0003_406.xml#add-0003-0004` auf einer Region `add-block`), ist das **keine** Behelfs-ID.

- Es wird nichts generiert und kein Zähler verbraucht; als xml:id wird einfach der Teil nach `#` übernommen (hier: `xml:id="add-0003-0004"`).
- So kann eine andere Datei per `target="0003_406.xml#add-0003-0004"` (siehe metamark insertion) genau auf dieses Element verweisen.
- Gilt für `id` auf Regionen (add-block, add, metamark, paragraph, …) und auf Zeilen-Blöcken (add `id`, subst-del `del-id`).
- Die Eindeutigkeit der xml:id (und dass sie nicht mit generierten IDs wie `add-0003-0004` kollidiert) liegt in der Verantwortung der Eingabe.

## 9. Change-Werte

Vorläufiger Mechanismus:
### 1. In tei:teiHeader
Für jeden distinct-value aus den change-Werten (ggf. auch mehrere, leerzeichengetrennte Werte möglich!) im Dokument wird in teiHeader/profileDesc/changeList ein change-Element angelegt, der den value als xml:id hat. Textknoten: "[tbd]"
### 2. Element in tei:text
#### change selbst
In den jeweiligen Elementen werden die change-Werte (ggf. auch mehrere pro Attribut!) beibehalten, davor aber jeweils ein # eingefügt
##### Zusätzlich: change-abhängige renditions
Enthält ein Element (außer mod, undo, del, delSpan, div, subst, gap, unclear, seg) in change den hier erstgenannten Wert, erhält es im Attribut "rendition" zusätzlich den hier zweitgenannten Wert (immer mit # davor) – außer, in rendition steht schon einer der hier angegebenen Werte (dann passiert nix):

kk - kurrent

pr - latin

ar - latin

np - black-letter

fp - antiqua

op - antiqua

Sonderfall `subst`: Das `subst` selbst bekommt keine change-abhängige rendition, nur das darin enthaltene `add`. Hat das `add` selbst ein change, gilt dieses (das change des `subst` fällt für die rendition raus); hat es keins, wird das change des `subst` herangezogen. Das `@change` selbst bleibt an `subst` und `add` unverändert.

Eine an der Region (`add`, `add-block`, `metamark`, `metamark-deleatur`) angegebene `rendition` bleibt erhalten; die durch `change` ergänzten Werte kommen dahinter (oder entfallen, wenn schon ein Schriftwert in der `rendition` steht). Fehlt bei einem Wert das `#`, wird es ergänzt.

## 10. Formatierung

- Die Einrückungseinheit der manuellen Einrückung ist der Parameter `indentUnit` (Standard: 3 Leerzeichen wie bei Saxon/Oxygen; für `xsltproc` zwei Leerzeichen übergeben), damit `<lb/>`-Zeilen und automatisch eingerückte Tags bündig stehen.
- Einrückung wird manuell erzeugt (der Serialisierer indentiert bei gemischtem Inhalt/Text nicht automatisch): jedes `<lb/>` steht auf einer eigenen, zur Baumtiefe passend eingerückten Zeile.
- Ausnahme: `<add>` steht kompakt in einer Zeile (siehe Abschnitt 5), nur echte `<lb/>` zwischen mehreren TextLines bleiben als Markup erhalten, ohne Zeilenumbruch/Einrückung drumherum.

## 11. Bekannte, akzeptierte Validierungslücken

Das Projekt-Schema `meta/hdr-documentary-schema.rng` wird aus `meta/hdr-documentary-schema.odd` erzeugt (`meta/odd2rng.sh`); gearbeitet wird nur am ODD, das `.rng` nicht von Hand bearbeiten. `transform.sh` prüft gegen dieses Schema und gegen `tei_all.rng`.

Gegen `tei_all.rng` geprüft (jing). Diese Fälle validieren **nicht**, sind aber bewusst so gewünscht bzw. Datenlücken, keine Stylesheet-Fehler:

- `<add>` als Regionstyp direkt im `<div>` (add ist phrasenwertig, kein Block-Kind) – manuell nachzukorrigieren
- `<subst>`, dessen add/del-Kinder die deklarierte Spanne nicht komplett abdecken (siehe Abschnitt 7) – Datenlücke im Export

## 12. Batch-Verarbeitung

`transform-all.sh` transformiert alle `.xml`-Dateien aus `./page-xml` nach `./tei-xml` (gleicher Dateiname), legt `./tei-xml` bei Bedarf an.
