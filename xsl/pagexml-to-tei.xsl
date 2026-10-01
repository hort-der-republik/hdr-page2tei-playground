<?xml version="1.0" encoding="UTF-8"?>
<!--
  Wandelt PAGE-XML (eScriptorium/Transkribus) in TEI um.

  KURZFASSUNG (die ausfuehrliche, immer aktuell gehaltene Referenz aller
  Regeln steht in verarbeitungsregeln.txt im selben Ordner; die Architektur-
  Erklaerung fuer Programmierer steht weiter unten, Abschnitt "WIE MAN DIESE
  DATEI LIEST"):

  facsimile: reine Bild-Geometrie. Genau ein <graphic> (das ganze Digitalisat)
  als Kind von <facsimile>. Regionen mit custom-type "surface" werden zu
  <surface>, alle anderen Regionen zu <zone>. Verschachtelung wird geometrisch
  bestimmt (Bounding-Box-Naeherung statt exakter Polygonflaeche, siehe unten):
    - surface enthaelt zone, wenn zone zu >=95% in surface liegt und in
      keiner kleineren surface >=95% enthalten ist
    - surface enthaelt surface analog; die aeusserste surface ist immer
      "base" (Marker structure{subtype:base;} oder structure{composit-order:base;}
      in @custom; ohne solchen Marker: die einzige/groesste surface-Region;
      gibt es gar keine surface-Region, wird eine synthetische Basis-Surface
      in Bildgroesse erzeugt)
    - zone enthaelt zone analog (kleinste passende Elternzone gewinnt)
  Einzelne <TextLine>-Zeilen bekommen bewusst KEINE eigene facsimile-Zone
  (Ruecksprache: nicht noetig). Welche Region eine Zeile "besitzt" wird NICHT
  aus der PAGE-XML-Struktur uebernommen, sondern geometrisch neu bestimmt:
  jede Zeile gehoert zur kleinsten Region, deren Bounding-Box den Mittelpunkt
  der Zeile enthaelt (Details und Begruendung bei $lineAssign weiter unten).

  text/body: dieselbe Verschachtelung (surface/zone) wird gespiegelt, aber
  mit den Transkriptionen statt Koordinaten:
    - surface -> <div facs="#surface_...">, aeusserste = type="base"
    - zone type "column-block"/"add-block" -> immer <div type="...">
    - jede zone mit eigenen Kind-Zonen -> <div> (sonst waere Text direkt im
      div, was TEI nicht erlaubt); eigener Zeilentext (falls vorhanden) als
      <p> Kind
    - zone type "head" (ohne Kinder) -> <head>
    - zone type "annotation" ODER "metamark" -> <metamark xml:id="...">
      (fortlaufend nummeriert, siehe $metamarkOrder), immer direktes Kind
      des naechsten umschliessenden <div> (ergibt sich automatisch, weil
      jede Zone mit einem solchen Kind zu einem <div> statt <p> wird)
    - zone type "gap" -> leeres <gap/>
    - zone type "add" -> <add> (validiert bewusst NICHT gegen TEI, siehe
      render-zone-text), kompakt ohne Zeilenumbruch im Markup
    - zone type "fw" -> <fw>
    - alle anderen zones (paragraph, ohne type, ...) -> <p> (kein @type,
      TEI-All erlaubt das dort nicht; structure{rendition:longquote;} wird
      zu @rendition="longQuote")
    - Transkribus-Relationen vom Typ "Article"/"montage-element": deren
      Mitglieder (nur die vom Typ paragraph/head) werden zusaetzlich in ein
      <div type="article"|"montage-element"> gruppiert, das an der Stelle
      des zuerst gelesenen Mitglieds im umgebenden div steht
    - innerhalb einer Zeile koennen zeichenbasierte Annotationen stehen
      (spacing/bold/underline/del/mod/seg/gap/add/metamark/unclear/subst),
      die zu Inline-Elementen wie <hi>/<del>/<add>/<subst>/... werden,
      ggf. verschachtelt und/oder ueber mehrere Zeilen reichend (siehe
      process-line weiter unten)

  Namespace-unabhaengig (local-name()), Reading-Order per @custom-Index.

  Benoetigt einen XSLT-1.0-Prozessor mit EXSLT node-set() (xsltproc/libxslt,
  Saxon, Xalan erfuellen das).


  ===========================================================================
  WIE MAN DIESE DATEI LIEST (fuer Menschen, die sie zum ersten Mal oeffnen)
  ===========================================================================

  A) DAS WIEDERKEHRENDE MUSTER: "RTF bauen, dann node-set() konvertieren"
  =========================================================================
  XSLT 1.0 kennt keine "Objekte" oder Arrays - nur Knoten aus dem Eingabe-
  dokument, Strings, Zahlen und sog. Result Tree Fragments (RTF). Ein RTF
  entsteht, wenn man mit <xsl:variable name="x">...Markup...</xsl:variable>
  neues XML "on the fly" baut; man kann darin aber NICHT mit XPath navigieren
  (kein x/foo, kein Filtern, kein Sortieren) - es ist erstmal nur ein Klumpen
  Markup. Ueberall im Skript, wo Zwischenergebnisse berechnet werden muessen
  (Regionen-Metadaten, Eltern-Zuordnungen, Zeichenbereiche einer Zeile, ...),
  taucht deshalb dasselbe zweistufige Muster auf:

      <xsl:variable name="fooRTF">
        <xsl:for-each select="...">
          <my:bar id="{...}" wert="{...}"/>        [ eigenes Mini-XML bauen ]
        </xsl:for-each>
      </xsl:variable>
      <xsl:variable name="foo" select="exsl:node-set($fooRTF)/my:bar"/>
                                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                        macht aus dem RTF einen "echten"
                                        Node-Set, den man wie jedes XPath-
                                        Ergebnis filtern/sortieren/durchlaufen
                                        kann ($foo[@id='x'], <xsl:sort>, ...)

  Der Namespace-Praefix "my:" (xmlns:my="urn:x-internal-helper") kennzeichnet
  genau dieses selbstgebaute Buchhaltungs-Markup: es hat mit dem PAGE-Format
  UND mit dem TEI-Ergebnis nichts zu tun, landet auch nie im Output
  (deshalb exclude-result-prefixes="my"). Wo immer also ein Element mit
  "my:"-Praefix auftaucht (<my:region>, <my:range>, <my:rp>, <my:unit>, ...),
  ist das interne Buchhaltung, kein PAGE- oder TEI-Element.

  B) DIE DREI SUBSYSTEME UND IHR DATENFLUSS
  =========================================================================
  Das Skript arbeitet in zwei Phasen: erst werden (als globale <xsl:variable>,
  ganz oben in der Datei, also VOR jedem <xsl:template>) alle Hilfsdaten fuer
  die ganze Seite auf einmal berechnet ("Phase 0"); erst danach beginnt das
  eigentliche rekursive Rendern ("Phase 1", ab dem <xsl:template match=...>).
  Diese Trennung ist noetig, weil z.B. "welches ist die kleinste Region, die
  Zeile X enthaelt" nur beantwortet werden kann, wenn ALLE Regionen bereits
  ihre Bounding-Box kennen - man kann das nicht "im Vorbeigehen" beim Rendern
  einer einzelnen Zeile berechnen.

  Es gibt DREI voneinander unabhaengige Buchhaltungs-Subsysteme, jedes mit
  eigenen Bezeichnern und eigener "kein Elternteil"-Markierung - wichtig, sie
  nicht zu verwechseln:

    1. REGIONEN-HIERARCHIE (surface/zone-Verschachtelung, Abschnitt "globale
       Datenbasis" unten):
         $regions       - eine <my:region> pro TextRegion, mit Bounding-Box,
                           Typ, Flaeche etc. (siehe build-region-entry)
         $parents       - eine <my:parent id=".." of=".."/> pro Region: "of"
                           ist die @id der Elternregion, oder LEER ("") fuer
                           die aeusserste Basis-Surface, oder das literale
                           id-lose Sentinel "SYNTHETIC_BASE" fuer Regionen
                           direkt unter der synthetischen Basis-Surface
                           (siehe $baseId weiter unten)
       "Kein Elternteil" wird hier also durch LEERSTRING bzw. den String
       "SYNTHETIC_BASE" ausgedrueckt.

    2. ZEILEN-ZUORDNUNG (welche Region "besitzt" welche TextLine):
         $lineAssign    - eine <my:la id="Zeilen-id" region="Regions-id"
                           pindex=".." oindex=".."/> pro TextLine
       Unabhaengig von (1); verwendet aber $regions' Bounding-Boxen mit.

    3. ZEICHENBEREICHS-BAUM INNERHALB EINER ZEILE (Textannotationen wie
       <hi>/<del>/<add>/<subst>/...): NUR lokal pro Zeile gueltig, wird bei
       jedem process-line-Aufruf neu berechnet (nicht global):
         $ranges        - eine <my:range idx=".." offset=".." end=".."
                           element=".." continued="true|false"> pro
                           Annotations-Block dieser einen Zeile
         $rangeParents  - eine <my:rp idx=".." parent=".."/> je Bereich:
                           "parent" ist die @idx des kleinsten umschliessenden
                           Bereichs, oder die Ziffer "0" fuer "oberste Ebene".
       "Kein Elternteil" wird hier durch die Ziffer "0" ausgedrueckt - ein
       ANDERES Sentinel als in Subsystem 1! ("0" ist hier nur ein neutraler
       Zaehlerwert, keine echte @idx, da position() bei 1 beginnt.)

  In allen drei Faellen gilt dasselbe Prinzip: "welches ist die kleinste
  Angabe, die mich umschliesst" (Region in Region, Zone in Zone, Zeichen-
  bereich in Zeichenbereich) - nur auf drei verschiedenen Ebenen angewendet
  (Bildflaeche / Bildflaeche / Zeichen-Offsets in einer Zeile).

  C) RENDERING: WER RUFT WEN AUF
  =========================================================================
  Startpunkt ist das einzige "echte" <xsl:template match="..."> (Abschnitt
  "Haupteinstieg"). Alles andere sind benannte Templates (xsl:template
  name="..."), die wie normale Funktionsaufrufe verkettet sind:

    facsimile (reine Geometrie, kein Text):
      render-node-fac  == rekursiv, ein Aufruf pro Region, folgt $parents

    text/body (Transkription):
      render-surface-text
        -> render-children-text   (Geschwister-Reihenfolge + TEI-Mischregel,
                                    siehe Kommentar dort)
             -> render-child-text     (Weiche: surface/annotation|metamark/
                                        gap/alles andere)
                  -> render-zone-text     (head/div/add/fw/p je nach Typ)
                  -> render-metamark
                  -> render-surface-text  (bei verschachtelten surfaces)
             -> render-article-group  (Transkribus-Relationen)
      ... und render-zone-text/render-metamark rufen fuer ihren eigenen Text
      wiederum render-lines -> process-line auf, das den Zeichenbereichs-
      Baum einer Zeile (Subsystem 3 oben) abarbeitet.

  D) DAS $depth-PARAMETER (manuelle Einrueckung)
  =========================================================================
  xsltproc/libxslt indentiert automatisch NUR Elemente, die ausschliesslich
  Element-Kinder haben (keinen eigenen Text). Sobald ein Element gemischten
  Inhalt hat (z.B. <p> mit <lb/> UND Text dazwischen), schaltet der
  Serialisierer die automatische Einrueckung fuer dessen Inhalt ab - deshalb
  wird sie fuer <lb/>-Zeilen manuell nachgebaut (siehe Template "indent").
  $depth ist dabei die tatsaechliche Verschachtelungstiefe im fertigen
  Dokument (2 Leerzeichen pro Ebene), NICHT irgendein Zaehler mit freier
  Bedeutung. Der Startwert 3 im Haupteinstieg kommt daher, dass <TEI> selbst
  bereits auf Ebene 0 steht, <text> auf 1, <body> auf 2 - die aeusserste
  <div> (Basis-Surface) landet also auf Ebene 3. Jede weitere Verschachtelung
  (surface in surface, div in div, p in div, ...) erhoeht $depth um genau 1.
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:exsl="http://exslt.org/common"
    xmlns:my="urn:x-internal-helper"
    xmlns="http://www.tei-c.org/ns/1.0"
    extension-element-prefixes="exsl"
    exclude-result-prefixes="my">

  <xsl:output method="xml" indent="yes" encoding="UTF-8"/>

  <!-- ===================== globale Datenbasis ===================== -->

  <xsl:variable name="page" select="/*[local-name()='PcGts']/*[local-name()='Page']"/>
  <xsl:variable name="allRegions" select="$page//*[local-name()='TextRegion']"/>

  <xsl:variable name="regionsRTF">
    <xsl:for-each select="$allRegions">
      <xsl:call-template name="build-region-entry"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="regions" select="exsl:node-set($regionsRTF)/my:region"/>

  <!-- Zeilen-Zuordnung: jede Zeile gehoert zur kleinsten Region, deren
       Bounding-Box den MITTELPUNKT der Zeile enthaelt. (Eine woertliche
       95%-Flaechenregel wurde getestet, zerriss aber zusammenhaengenden
       Fliesztext: PAGE-Regionen sind oft schraege Polygone, deren eigene
       Bounding-Box dadurch aufgeblaeht ist - bei kleinen Zeilen faellt das
       viel staerker ins Gewicht als bei ganzen Regionen, siehe Absprache.
       Der Mittelpunkt-Test ist robust dagegen und trifft den Zweck der
       Regel zuverlaessiger.) Gibt es keine solche Region, bleibt es bei der
       strukturellen Elternregion aus der PAGE-XML. Sortierung innerhalb
       einer Region nach (Index der urspruenglichen Elternregion, eigener
       Zeilen-Index) - der Zeilen-Index in @custom ist nur pro Region
       relativ, daher reicht er allein nicht als globaler Sortierschluessel. -->
  <xsl:variable name="allLines" select="$page//*[local-name()='TextLine']"/>

  <xsl:variable name="lineAssignRTF">
    <xsl:for-each select="$allLines">
      <xsl:variable name="ln" select="."/>
      <xsl:variable name="bboxRTF">
        <xsl:call-template name="bbox">
          <xsl:with-param name="points" select="*[local-name()='Coords']/@points"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:variable name="bbox" select="exsl:node-set($bboxRTF)"/>
      <xsl:variable name="midX" select="(number($bbox/my:minX) + number($bbox/my:maxX)) div 2"/>
      <xsl:variable name="midY" select="(number($bbox/my:minY) + number($bbox/my:maxY)) div 2"/>
      <xsl:variable name="parentRegionId" select="$ln/../@id"/>
      <xsl:variable name="parentRegionIndex" select="$regions[@id=$parentRegionId]/@index"/>
      <xsl:variable name="ownIndex">
        <xsl:call-template name="custom-value">
          <xsl:with-param name="custom" select="$ln/@custom"/>
          <xsl:with-param name="block" select="'readingOrder'"/>
          <xsl:with-param name="key" select="'index'"/>
        </xsl:call-template>
      </xsl:variable>
      <xsl:variable name="qualifyingRTF">
        <xsl:for-each select="$regions[number(@minX) &lt;= $midX and $midX &lt;= number(@maxX) and number(@minY) &lt;= $midY and $midY &lt;= number(@maxY)]">
          <my:cand id="{@id}" area="{@area}"/>
        </xsl:for-each>
      </xsl:variable>
      <xsl:variable name="best">
        <xsl:for-each select="exsl:node-set($qualifyingRTF)/my:cand">
          <xsl:sort select="@area" data-type="number" order="ascending"/>
          <xsl:if test="position()=1"><xsl:value-of select="@id"/></xsl:if>
        </xsl:for-each>
      </xsl:variable>
      <xsl:variable name="targetRegion">
        <xsl:choose>
          <xsl:when test="$best != ''"><xsl:value-of select="$best"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="$parentRegionId"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <my:la id="{$ln/@id}" region="{$targetRegion}" pindex="{$parentRegionIndex}" oindex="{$ownIndex}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineAssign" select="exsl:node-set($lineAssignRTF)/my:la"/>

  <xsl:variable name="surfaceRegions" select="$regions[@type='surface']"/>

  <xsl:variable name="baseId">
    <xsl:choose>
      <xsl:when test="$surfaceRegions[@subtype='base']">
        <xsl:call-template name="pick-extreme-id">
          <xsl:with-param name="nodes" select="$surfaceRegions[@subtype='base']"/>
          <xsl:with-param name="order" select="'descending'"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:when test="$surfaceRegions[@compositOrder='base']">
        <xsl:call-template name="pick-extreme-id">
          <xsl:with-param name="nodes" select="$surfaceRegions[@compositOrder='base']"/>
          <xsl:with-param name="order" select="'descending'"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:when test="count($surfaceRegions) = 1">
        <xsl:value-of select="$surfaceRegions[1]/@id"/>
      </xsl:when>
      <xsl:when test="$surfaceRegions">
        <xsl:call-template name="pick-extreme-id">
          <xsl:with-param name="nodes" select="$surfaceRegions"/>
          <xsl:with-param name="order" select="'descending'"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>SYNTHETIC_BASE</xsl:otherwise>
    </xsl:choose>
  </xsl:variable>

  <xsl:variable name="parentsRTF">
    <xsl:for-each select="$regions">
      <xsl:variable name="me" select="."/>
      <xsl:variable name="parentId">
        <xsl:call-template name="determine-parent">
          <xsl:with-param name="me" select="$me"/>
        </xsl:call-template>
      </xsl:variable>
      <my:parent id="{$me/@id}" of="{$parentId}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="parents" select="exsl:node-set($parentsRTF)/my:parent"/>

  <xsl:variable name="relMembersRTF">
    <xsl:for-each select="$page//*[local-name()='Relation']">
      <xsl:variable name="relCustom" select="@custom"/>
      <xsl:variable name="relNameRaw" select="substring-before(substring-after($relCustom,'relationName {value:'),';')"/>
      <xsl:variable name="relNameLower" select="translate($relNameRaw,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')"/>
      <xsl:if test="$relNameLower='article' or $relNameLower='montage-element'">
        <xsl:variable name="gid" select="generate-id(.)"/>
        <xsl:for-each select="*[local-name()='RegionRef']">
          <xsl:variable name="rid" select="@regionRef"/>
          <xsl:variable name="target" select="$allRegions[@id=$rid]"/>
          <xsl:if test="$target">
            <xsl:variable name="ttype">
              <xsl:call-template name="custom-value">
                <xsl:with-param name="custom" select="$target/@custom"/>
                <xsl:with-param name="block" select="'structure'"/>
                <xsl:with-param name="key" select="'type'"/>
              </xsl:call-template>
            </xsl:variable>
            <xsl:if test="$ttype='paragraph' or $ttype='head'">
              <my:relmember region="{$rid}" group="{$gid}" type="{$relNameLower}"/>
            </xsl:if>
          </xsl:if>
        </xsl:for-each>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="relMembers" select="exsl:node-set($relMembersRTF)/my:relmember"/>

  <!-- vierstellige Seitenzahl aus dem Dateinamen (ueber @imageFilename, das
       denselben Basisnamen traegt wie die PAGE-XML-Datei): der Teil nach dem
       letzten "_" (oder der ganze Basisname, falls kein "_" vorkommt), auf
       mindestens 4 Stellen mit fuehrenden Nullen aufgefuellt -->
  <xsl:variable name="imageBasename" select="substring-before(concat($page/@imageFilename,'.'), '.')"/>
  <xsl:variable name="pageNumRaw">
    <xsl:call-template name="after-last-underscore">
      <xsl:with-param name="s" select="$imageBasename"/>
    </xsl:call-template>
  </xsl:variable>
  <xsl:variable name="pageNumPadded">
    <xsl:call-template name="pad4">
      <xsl:with-param name="s" select="$pageNumRaw"/>
    </xsl:call-template>
  </xsl:variable>

  <!-- laufende Nummer jeder annotation- ODER metamark-Region (beide werden
       zu <metamark>) in globaler Lesereihenfolge (@index), fuer die
       metamark-xml:id -->
  <xsl:variable name="metamarkOrderRTF">
    <xsl:for-each select="$regions[@type='annotation' or @type='metamark']">
      <xsl:sort select="@index" data-type="number"/>
      <my:mm id="{@id}" seq="{position()}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="metamarkOrder" select="exsl:node-set($metamarkOrderRTF)/my:mm"/>

  <!-- ===================== Haupteinstieg ===================== -->

  <xsl:template match="/*[local-name()='PcGts']">
    <TEI xml:lang="de">
      <teiHeader>
        <fileDesc>
          <titleStmt>
            <title>Diplomatische Transkription: <xsl:value-of select="$page/@imageFilename"/></title>
          </titleStmt>
          <publicationStmt>
            <p>Automatisch erzeugt aus PAGE-XML (eScriptorium-/Transkribus-Export) per XSLT.</p>
          </publicationStmt>
          <sourceDesc>
            <p>
              Quelle: <xsl:value-of select="$page/@imageFilename"/>.
              Erstellt: <xsl:value-of select="*[local-name()='Metadata']/*[local-name()='Created']"/>,
              zuletzt geaendert: <xsl:value-of select="*[local-name()='Metadata']/*[local-name()='LastChange']"/>.
            </p>
          </sourceDesc>
        </fileDesc>
      </teiHeader>

      <facsimile>
        <graphic url="{$page/@imageFilename}" width="{$page/@imageWidth}px" height="{$page/@imageHeight}px"/>
        <xsl:choose>
          <xsl:when test="$baseId='SYNTHETIC_BASE'">
            <surface lrx="{$page/@imageWidth}" lry="{$page/@imageHeight}">
              <xsl:attribute name="xml:id">surface_<xsl:value-of select="$page/@imageFilename"/></xsl:attribute>
              <xsl:attribute name="type">base</xsl:attribute>
              <xsl:for-each select="$parents[@of='SYNTHETIC_BASE']">
                <xsl:call-template name="render-node-fac">
                  <xsl:with-param name="id" select="@id"/>
                </xsl:call-template>
              </xsl:for-each>
            </surface>
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="render-node-fac">
              <xsl:with-param name="id" select="$baseId"/>
            </xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
      </facsimile>

      <text>
        <body>
          <xsl:choose>
            <xsl:when test="$baseId='SYNTHETIC_BASE'">
              <div type="base">
                <xsl:attribute name="facs">#surface_<xsl:value-of select="$page/@imageFilename"/></xsl:attribute>
                <xsl:call-template name="render-children-text">
                  <xsl:with-param name="id" select="'SYNTHETIC_BASE'"/>
                  <xsl:with-param name="depth" select="4"/>
                </xsl:call-template>
              </div>
            </xsl:when>
            <xsl:otherwise>
              <xsl:call-template name="render-surface-text">
                <xsl:with-param name="id" select="$baseId"/>
                <xsl:with-param name="depth" select="3"/>
              </xsl:call-template>
            </xsl:otherwise>
          </xsl:choose>
        </body>
      </text>
    </TEI>
  </xsl:template>

  <!-- ===================== facsimile rendern ===================== -->

  <!-- Rekursiv EIN Knoten der Regionen-Hierarchie (siehe $parents oben):
       $id kann sowohl eine surface als auch eine zone sein, entschieden
       ueber $region/@type. Reine Geometrie, kein Zeilentext - das
       text/body-Pendant mit denselben Verzweigungen (aber mit Transkription
       statt Koordinaten) ist render-surface-text/render-child-text weiter
       unten. Rekursion folgt $parents[@of=$id] (die Kinder dieser Region). -->
  <xsl:template name="render-node-fac">
    <xsl:param name="id"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:variable name="src" select="$allRegions[@id=$id]"/>
    <xsl:variable name="childIds" select="$parents[@of=$id]/@id"/>
    <xsl:choose>
      <xsl:when test="$region/@type='surface'">
        <surface>
          <xsl:attribute name="xml:id">surface_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:attribute name="type">
            <xsl:choose>
              <xsl:when test="$id=$baseId">base</xsl:when>
              <xsl:otherwise>surface</xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <xsl:if test="$region/@subtype != ''">
            <xsl:attribute name="subtype"><xsl:value-of select="$region/@subtype"/></xsl:attribute>
          </xsl:if>
          <xsl:if test="$src/*[local-name()='Coords']/@points">
            <xsl:attribute name="points"><xsl:value-of select="$src/*[local-name()='Coords']/@points"/></xsl:attribute>
          </xsl:if>
          <xsl:for-each select="$childIds">
            <xsl:call-template name="render-node-fac"><xsl:with-param name="id" select="."/></xsl:call-template>
          </xsl:for-each>
        </surface>
      </xsl:when>
      <xsl:otherwise>
        <zone>
          <xsl:attribute name="xml:id">zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:if test="$region/@type != ''">
            <xsl:attribute name="type"><xsl:value-of select="$region/@type"/></xsl:attribute>
          </xsl:if>
          <xsl:if test="$src/*[local-name()='Coords']/@points">
            <xsl:attribute name="points"><xsl:value-of select="$src/*[local-name()='Coords']/@points"/></xsl:attribute>
          </xsl:if>
          <xsl:for-each select="$childIds">
            <xsl:call-template name="render-node-fac"><xsl:with-param name="id" select="."/></xsl:call-template>
          </xsl:for-each>
        </zone>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ===================== text/body rendern ===================== -->

  <xsl:template name="render-surface-text">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="3"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:variable name="hasOwnTextV">
      <xsl:call-template name="region-has-own-text"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
    </xsl:variable>
    <div>
      <xsl:attribute name="facs">#surface_<xsl:value-of select="$id"/></xsl:attribute>
      <xsl:attribute name="type">
        <xsl:choose>
          <xsl:when test="$id=$baseId">base</xsl:when>
          <xsl:otherwise>surface</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
      <xsl:if test="$region/@subtype != ''">
        <xsl:attribute name="subtype"><xsl:value-of select="$region/@subtype"/></xsl:attribute>
      </xsl:if>
      <xsl:call-template name="render-children-text">
        <xsl:with-param name="id" select="$id"/>
        <xsl:with-param name="depth" select="$depth + 1"/>
        <xsl:with-param name="ownText" select="$hasOwnTextV='true'"/>
        <xsl:with-param name="ownTextRegionId" select="$id"/>
      </xsl:call-template>
    </div>
  </xsl:template>

  <!-- TEI erlaubt innerhalb eines div KEINE Mischung von <p>/<head> und
       <div> als direkte Geschwister (das Content-Model verlangt entweder
       nur divLike- oder nur Flowcontent-Kinder). Deshalb wird hier zuerst
       ermittelt, was jede Einheit (eigener Text, einzelnes Kind, oder eine
       ganze Article/montage-element-Gruppe) rendern WIRD ("kind"); kommen
       div- und p/head-Einheiten gemischt vor, werden die p/head-Einheiten
       zusaetzlich in ein <div> gewickelt, damit alle Geschwister divLike
       sind. <metamark> ist milestone-artig und braucht das nicht. -->
  <xsl:template name="render-children-text">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="4"/>
    <xsl:param name="ownText" select="false()"/>
    <xsl:param name="ownTextRegionId"/>
    <xsl:variable name="childEntries" select="$parents[@of=$id]"/>

    <!-- Jede "Einheit" ist entweder: der eigene Zeilentext dieser Region
         (own="yes", nur wenn $ownText - z.B. eine surface, die neben ihren
         Kind-Regionen auch selbst Text traegt), EIN einzelnes Kind, oder
         eine ganze Article/montage-element-Gruppe (group != ""). index="-1"
         fuer den eigenen Text ist reine Sortier-Konvention: er soll vor
         allen echten Kindern erscheinen (deren @index immer >= 0 ist, siehe
         readingOrder in PAGE-XML) - keine inhaltliche Bedeutung. -->
    <xsl:variable name="unitsRTF">
      <xsl:if test="$ownText">
        <my:unit id="{$id}" kind="p" group="" index="-1" own="yes"/>
      </xsl:if>
      <xsl:for-each select="$childEntries">
        <xsl:variable name="childId" select="@id"/>
        <xsl:variable name="rel" select="$relMembers[@region=$childId]"/>
        <xsl:choose>
          <xsl:when test="$rel">
            <xsl:variable name="groupKey" select="$rel/@group"/>
            <xsl:variable name="siblingGroupIds" select="$relMembers[@group=$groupKey][$childEntries/@id = @region]/@region"/>
            <xsl:variable name="isAnchor">
              <xsl:for-each select="$siblingGroupIds">
                <xsl:sort select="$regions[@id=current()]/@index" data-type="number"/>
                <xsl:if test="position()=1 and .=$childId">yes</xsl:if>
              </xsl:for-each>
            </xsl:variable>
            <xsl:if test="$isAnchor='yes'">
              <my:unit id="{$childId}" kind="div" group="{$groupKey}" index="{$regions[@id=$childId]/@index}" own=""/>
            </xsl:if>
          </xsl:when>
          <xsl:otherwise>
            <xsl:variable name="kind"><xsl:call-template name="child-kind"><xsl:with-param name="id" select="$childId"/></xsl:call-template></xsl:variable>
            <my:unit id="{$childId}" kind="{$kind}" group="" index="{$regions[@id=$childId]/@index}" own=""/>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="units" select="exsl:node-set($unitsRTF)/my:unit"/>
    <xsl:variable name="mixed" select="boolean($units[@kind='div']) and boolean($units[@kind='p' or @kind='head'])"/>

    <xsl:for-each select="$units">
      <xsl:sort select="@index" data-type="number"/>
      <xsl:variable name="u" select="."/>
      <xsl:variable name="willWrap" select="$mixed and ($u/@kind='p' or $u/@kind='head')"/>
      <xsl:variable name="unitDepth">
        <xsl:choose>
          <xsl:when test="$willWrap"><xsl:value-of select="$depth + 1"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="$depth"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:variable name="rendered">
        <xsl:choose>
          <xsl:when test="$u/@own='yes'">
            <p>
              <xsl:call-template name="render-lines">
                <xsl:with-param name="regionId" select="$ownTextRegionId"/>
                <xsl:with-param name="depth" select="$unitDepth + 1"/>
              </xsl:call-template>
            </p>
          </xsl:when>
          <xsl:when test="$u/@group != ''">
            <xsl:variable name="memberIds" select="$relMembers[@group=$u/@group][$childEntries/@id = @region]/@region"/>
            <xsl:call-template name="render-article-group">
              <xsl:with-param name="groupKey" select="$u/@group"/>
              <xsl:with-param name="memberIds" select="$memberIds"/>
              <xsl:with-param name="depth" select="$unitDepth"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="render-child-text">
              <xsl:with-param name="id" select="$u/@id"/>
              <xsl:with-param name="depth" select="$unitDepth"/>
            </xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:choose>
        <xsl:when test="$willWrap">
          <div><xsl:copy-of select="$rendered"/></div>
        </xsl:when>
        <xsl:otherwise>
          <xsl:copy-of select="$rendered"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:for-each>
  </xsl:template>

  <!-- welches Element eine Kind-Zone rendern wird (fuer die Mixing-Erkennung) -->
  <xsl:template name="child-kind">
    <xsl:param name="id"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:choose>
      <xsl:when test="$region/@type='surface'">div</xsl:when>
      <xsl:when test="$region/@type='annotation' or $region/@type='metamark'">metamark</xsl:when>
      <xsl:when test="$region/@type='gap'">gap</xsl:when>
      <xsl:when test="$region/@type='column-block' or $region/@type='add-block'">div</xsl:when>
      <xsl:when test="boolean($parents[@of=$id])">div</xsl:when>
      <xsl:when test="$region/@type='head'">head</xsl:when>
      <xsl:otherwise>p</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="render-article-group">
    <xsl:param name="groupKey"/>
    <xsl:param name="memberIds"/>
    <xsl:param name="depth" select="4"/>
    <div>
      <xsl:attribute name="type"><xsl:value-of select="$relMembers[@group=$groupKey][1]/@type"/></xsl:attribute>
      <xsl:for-each select="$memberIds">
        <xsl:sort select="$regions[@id=current()]/@index" data-type="number"/>
        <xsl:call-template name="render-child-text">
          <xsl:with-param name="id" select="."/>
          <xsl:with-param name="depth" select="$depth + 1"/>
        </xsl:call-template>
      </xsl:for-each>
    </div>
  </xsl:template>

  <!-- Typ-Weiche fuer EIN einzelnes Kind (egal ob es aus render-children-text
       oder aus render-article-group kommt): surface rendert sich selbst
       rekursiv, annotation/metamark werden zu <metamark>, gap zu <gap/>,
       alles andere geht an render-zone-text (das dort nochmal zwischen
       head/div/add/fw/p unterscheidet). Diese Weiche entscheidet NUR das
       Element; ob es evtl. zusaetzlich in ein <div> gewickelt werden muss
       (TEI-Mischregel), entscheidet bereits der Aufrufer anhand von
       child-kind, bevor render-child-text ueberhaupt gerufen wird. -->
  <xsl:template name="render-child-text">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="4"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:choose>
      <xsl:when test="$region/@type='surface'">
        <xsl:call-template name="render-surface-text">
          <xsl:with-param name="id" select="$id"/>
          <xsl:with-param name="depth" select="$depth"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:when test="$region/@type='annotation' or $region/@type='metamark'">
        <xsl:call-template name="render-metamark">
          <xsl:with-param name="id" select="$id"/>
          <xsl:with-param name="depth" select="$depth"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:when test="$region/@type='gap'">
        <gap><xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute></gap>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="render-zone-text">
          <xsl:with-param name="id" select="$id"/>
          <xsl:with-param name="depth" select="$depth"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="render-zone-text">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="4"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:variable name="type" select="$region/@type"/>
    <xsl:variable name="hasChildren" select="boolean($parents[@of=$id])"/>
    <xsl:variable name="hasOwnTextV">
      <xsl:call-template name="region-has-own-text"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="$type='head' and not($hasChildren)">
        <head>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </head>
      </xsl:when>
      <xsl:when test="$type='column-block' or $type='add-block' or $hasChildren">
        <div>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:if test="$type != ''"><xsl:attribute name="type"><xsl:value-of select="$type"/></xsl:attribute></xsl:if>
          <xsl:call-template name="render-children-text">
            <xsl:with-param name="id" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
            <xsl:with-param name="ownText" select="$hasOwnTextV='true'"/>
            <xsl:with-param name="ownTextRegionId" select="$id"/>
          </xsl:call-template>
        </div>
      </xsl:when>
      <xsl:when test="$type='add'">
        <!-- <add> validiert vermutlich nicht direkt in einem div (es ist als
             phrasenwertiges Element gedacht, nicht als Block-Kind) - bewusst
             so gewuenscht, wird manuell nachkorrigiert. Anders als p/head/fw
             steht der Inhalt kompakt in einer Zeile (kein Umbruch/Einrueckung
             direkt nach dem Start- bzw. vor dem Endtag), nur echte <lb/> bei
             mehreren TextLines bleiben erhalten. -->
        <add>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
            <xsl:with-param name="compact" select="true()"/>
          </xsl:call-template>
        </add>
      </xsl:when>
      <xsl:when test="$type='fw'">
        <fw>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </fw>
      </xsl:when>
      <xsl:otherwise>
        <!-- TEI-All erlaubt @type auf <p> nicht; der Regionstyp bleibt ueber
             @facs an der entsprechenden <zone type="..."> im facsimile nachvollziehbar. -->
        <p>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:if test="$region/@rendition='longquote'">
            <xsl:attribute name="rendition">longQuote</xsl:attribute>
          </xsl:if>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </p>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="render-metamark">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="4"/>
    <xsl:variable name="seqPadded">
      <xsl:call-template name="pad4">
        <xsl:with-param name="s" select="$metamarkOrder[@id=$id]/@seq"/>
      </xsl:call-template>
    </xsl:variable>
    <metamark>
      <xsl:attribute name="xml:id">metamark<xsl:value-of select="$pageNumPadded"/><xsl:value-of select="$seqPadded"/></xsl:attribute>
      <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
      <xsl:call-template name="render-lines">
        <xsl:with-param name="regionId" select="$id"/>
        <xsl:with-param name="depth" select="$depth + 1"/>
      </xsl:call-template>
    </metamark>
    <!-- Falls eine annotation-Zone wider Erwarten eigene Kind-Zonen hat (in
         den vorliegenden Dateien nicht beobachtet): einfach danach ausgeben.
         Das umgeht die Mixing-Pruefung der eigentlichen Elternebene - fuer
         diesen Randfall bewusst vereinfacht. -->
    <xsl:call-template name="render-children-text">
      <xsl:with-param name="id" select="$id"/>
      <xsl:with-param name="depth" select="$depth"/>
    </xsl:call-template>
  </xsl:template>

  <!-- die einer Region per $lineAssign zugeordneten Zeilen, sortiert nach
       (Index der urspruenglichen Elternregion, eigener Zeilen-Index), als
       eigenstaendige Kopien (damit sie als normaler Node-Set indizierbar
       sind statt nur als Verweise auf die Originalknoten) -->
  <xsl:template name="ordered-lines-for-region">
    <xsl:param name="regionId"/>
    <xsl:for-each select="$lineAssign[@region=$regionId]">
      <xsl:sort select="number(@pindex)" data-type="number"/>
      <xsl:sort select="number(@oindex)" data-type="number"/>
      <xsl:copy-of select="$allLines[@id=current()/@id]"/>
    </xsl:for-each>
  </xsl:template>

  <!-- hat eine Region (nach der Zeilen-Neuzuordnung) mindestens eine eigene
       Zeile mit nicht-leerem Text? -->
  <xsl:template name="region-has-own-text">
    <xsl:param name="regionId"/>
    <xsl:variable name="ids" select="$lineAssign[@region=$regionId]/@id"/>
    <xsl:value-of select="boolean($allLines[@id=$ids][normalize-space(*[local-name()='TextEquiv'][1]/*[local-name()='Unicode']) != ''])"/>
  </xsl:template>

  <!-- Einstiegspunkt fuer "gib den Text EINER Region aus" - wird von
       render-zone-text/render-metamark/render-children-text (eigener Text
       einer surface) aufgerufen. Nimmt bewusst eine Regions-@id entgegen,
       KEINEN Knoten: die tatsaechlich zugehoerigen Zeilen kommen ueber
       $lineAssign (Zeilen-Zuordnung, Subsystem 2), nicht ueber PAGE-XML-
       Kindschaft. depth=$depth ist die Tiefe, auf der die <lb/>-Zeilen
       selbst stehen sollen (typischerweise die Tiefe des rufenden <p>/
       <head>/... plus 1). compact=true unterdrueckt die Einrueckung
       (fuer <add>, siehe render-zone-text). -->
  <xsl:template name="render-lines">
    <xsl:param name="regionId"/>
    <xsl:param name="depth" select="1"/>
    <xsl:param name="compact" select="false()"/>
    <xsl:variable name="linesRTF">
      <xsl:call-template name="ordered-lines-for-region"><xsl:with-param name="regionId" select="$regionId"/></xsl:call-template>
    </xsl:variable>
    <xsl:variable name="lines" select="exsl:node-set($linesRTF)/*[local-name()='TextLine']"/>
    <xsl:call-template name="process-line">
      <xsl:with-param name="lines" select="$lines"/>
      <xsl:with-param name="index" select="1"/>
      <xsl:with-param name="depth" select="$depth"/>
      <xsl:with-param name="compact" select="$compact"/>
    </xsl:call-template>
    <xsl:if test="not($compact)">
      <xsl:text>&#10;</xsl:text>
      <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth - 1"/></xsl:call-template>
    </xsl:if>
  </xsl:template>

  <!-- ============ zeilenweise Ausgabe mit inline-Textannotationen ============
       TextLine-@custom kann mehrere zeichenbasierte Annotations-Bloecke
       gleichzeitig tragen (spacing/bold/underline/del/mod/seg/seg-transposition/
       gap/add/metamark/unclear/subst {offset:..;length:..;...}), auch
       verschachtelt (z.B. del innerhalb seg-transposition, oder del+add
       gemeinsam unter subst). Das wird als Baum ueber Zeichenbereiche
       behandelt: die kleinste andere Angabe, die einen Bereich vollstaendig
       umschliesst, wird dessen Elternelement; Geschwister werden nach Offset
       sortiert mit dem dazwischenliegenden Klartext verschachtelt ausgegeben.
       "continued:true" an einer OBERSTEN (nicht verschachtelten) Angabe
       heisst: der Lauf reicht ueber das Zeilenende hinaus und wird auf der
       naechsten Zeile (dort beginnend bei offset:0) fortgesetzt - das wird zu
       EINEM Inline-Element, das <lb/> als Kind enthaelt. -->

  <xsl:template name="process-line">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="depth"/>
    <xsl:param name="compact" select="false()"/>
    <xsl:if test="$index &lt;= count($lines)">
      <xsl:variable name="line" select="$lines[$index]"/>
      <xsl:variable name="text" select="$line/*[local-name()='TextEquiv'][1]/*[local-name()='Unicode']"/>
      <xsl:variable name="rangesRTF">
        <xsl:call-template name="parse-line-ranges"><xsl:with-param name="line" select="$line"/></xsl:call-template>
      </xsl:variable>
      <xsl:variable name="ranges" select="exsl:node-set($rangesRTF)/my:range"/>
      <xsl:variable name="rangeParentsRTF">
        <xsl:call-template name="build-range-parents"><xsl:with-param name="ranges" select="$ranges"/></xsl:call-template>
      </xsl:variable>
      <xsl:variable name="rangeParents" select="exsl:node-set($rangeParentsRTF)/my:rp"/>

      <xsl:if test="not($compact)">
        <xsl:text>&#10;</xsl:text>
        <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
      </xsl:if>
      <lb/>

      <xsl:choose>
        <xsl:when test="not($ranges)">
          <xsl:value-of select="$text"/>
          <xsl:call-template name="process-line">
            <xsl:with-param name="lines" select="$lines"/>
            <xsl:with-param name="index" select="$index + 1"/>
            <xsl:with-param name="depth" select="$depth"/>
            <xsl:with-param name="compact" select="$compact"/>
          </xsl:call-template>
        </xsl:when>
        <xsl:otherwise>
          <xsl:variable name="topOrderedRTF">
            <xsl:for-each select="$rangeParents[@parent='0']">
              <xsl:sort select="number($ranges[@idx=current()/@idx]/@offset)" data-type="number"/>
              <my:child idx="{@idx}"/>
            </xsl:for-each>
          </xsl:variable>
          <xsl:variable name="topOrdered" select="exsl:node-set($topOrderedRTF)/my:child"/>
          <xsl:variable name="lastTopIdx" select="$topOrdered[last()]/@idx"/>
          <xsl:variable name="lastTop" select="$ranges[@idx=$lastTopIdx]"/>
          <xsl:variable name="lastTopHasChildren" select="boolean($rangeParents[@parent=$lastTopIdx])"/>

          <xsl:choose>
            <xsl:when test="$lastTop/@continued='true' and not($lastTopHasChildren)">
              <!-- alle obersten Bereiche ausser dem letzten normal ausgeben,
                   dann den letzten an die zeilenuebergreifende Logik uebergeben -->
              <xsl:call-template name="render-children-seq">
                <xsl:with-param name="ranges" select="$ranges"/>
                <xsl:with-param name="rangeParents" select="$rangeParents"/>
                <xsl:with-param name="ordered" select="$topOrdered[position() &lt; last()]"/>
                <xsl:with-param name="pos" select="1"/>
                <xsl:with-param name="cursor" select="0"/>
                <xsl:with-param name="spanEnd" select="number($lastTop/@offset)"/>
                <xsl:with-param name="text" select="$text"/>
              </xsl:call-template>
              <xsl:call-template name="render-run-span">
                <xsl:with-param name="lines" select="$lines"/>
                <xsl:with-param name="index" select="$index"/>
                <xsl:with-param name="depth" select="$depth"/>
                <xsl:with-param name="compact" select="$compact"/>
                <xsl:with-param name="element" select="$lastTop/@element"/>
                <xsl:with-param name="attrs" select="$lastTop/my:attr"/>
                <xsl:with-param name="startOffset" select="number($lastTop/@offset)"/>
              </xsl:call-template>
            </xsl:when>
            <xsl:otherwise>
              <xsl:call-template name="render-children-seq">
                <xsl:with-param name="ranges" select="$ranges"/>
                <xsl:with-param name="rangeParents" select="$rangeParents"/>
                <xsl:with-param name="ordered" select="$topOrdered"/>
                <xsl:with-param name="pos" select="1"/>
                <xsl:with-param name="cursor" select="0"/>
                <xsl:with-param name="spanEnd" select="string-length($text)"/>
                <xsl:with-param name="text" select="$text"/>
              </xsl:call-template>
              <xsl:call-template name="process-line">
                <xsl:with-param name="lines" select="$lines"/>
                <xsl:with-param name="index" select="$index + 1"/>
                <xsl:with-param name="depth" select="$depth"/>
                <xsl:with-param name="compact" select="$compact"/>
              </xsl:call-template>
            </xsl:otherwise>
          </xsl:choose>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:if>
  </xsl:template>

  <!-- alle Annotations-Bloecke einer Zeile: liefert
       <my:range idx=".." offset=".." end=".." element=".." continued="true|false">
         <my:attr name=".." value=".."/>*
       </my:range>*  (idx = Position in Lesereihenfolge des @custom-Attributs) -->
  <xsl:template name="parse-line-ranges">
    <xsl:param name="line"/>
    <xsl:variable name="blocksRTF">
      <xsl:call-template name="parse-all-blocks">
        <xsl:with-param name="s" select="$line/@custom"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="blocks" select="exsl:node-set($blocksRTF)/my:block"/>
    <xsl:for-each select="$blocks[@name='spacing' or @name='bold' or @name='underline' or @name='del' or @name='mod' or @name='seg-transposition' or @name='seg' or @name='gap' or @name='add' or @name='metamark' or @name='unclear' or @name='subst']">
      <xsl:variable name="name" select="@name"/>
      <xsl:variable name="content" select="@content"/>
      <xsl:variable name="offset"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'offset'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="length"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'length'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="continued"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'continued'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="element">
        <xsl:choose>
          <xsl:when test="$name='spacing' or $name='bold' or $name='underline'">hi</xsl:when>
          <xsl:when test="$name='del'">del</xsl:when>
          <xsl:when test="$name='mod'">mod</xsl:when>
          <xsl:when test="$name='seg' or $name='seg-transposition'">seg</xsl:when>
          <xsl:when test="$name='gap'">gap</xsl:when>
          <xsl:when test="$name='add'">add</xsl:when>
          <xsl:when test="$name='metamark'">metamark</xsl:when>
          <xsl:when test="$name='unclear'">unclear</xsl:when>
          <xsl:when test="$name='subst'">subst</xsl:when>
        </xsl:choose>
      </xsl:variable>
      <my:range idx="{position()}" offset="{number($offset)}" end="{number($offset) + number($length)}" element="{$element}" continued="{$continued='true'}">
        <xsl:choose>
          <xsl:when test="$name='spacing'"><my:attr name="style" value="letter-spacing"/></xsl:when>
          <xsl:when test="$name='bold'"><my:attr name="style" value="bold"/></xsl:when>
          <xsl:when test="$name='underline'"><my:attr name="style" value="underline"/></xsl:when>
          <xsl:when test="$name='mod'">
            <xsl:variable name="styleOverride"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'style'"/></xsl:call-template></xsl:variable>
            <xsl:choose>
              <xsl:when test="$styleOverride != ''"><my:attr name="style" value="{$styleOverride}"/></xsl:when>
              <xsl:otherwise><my:attr name="style" value="underline"/></xsl:otherwise>
            </xsl:choose>
          </xsl:when>
          <xsl:when test="$name='seg'">
            <xsl:variable name="type"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'type'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$type != ''"><my:attr name="type" value="{$type}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='seg-transposition'">
            <my:attr name="type" value="transposition"/>
          </xsl:when>
          <xsl:when test="$name='gap'">
            <xsl:variable name="reason"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'reason'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="extent"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'extent'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$reason != ''"><my:attr name="reason" value="{$reason}"/></xsl:if>
            <xsl:if test="$extent != ''"><my:attr name="extent" value="{$extent}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='add'">
            <xsl:variable name="place"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'place'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$place != ''"><my:attr name="place" value="{$place}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='metamark'">
            <xsl:variable name="function"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'function'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$function != ''"><my:attr name="function" value="{$function}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='unclear'">
            <xsl:variable name="reason"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'reason'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="cert"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'cert'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$reason != ''"><my:attr name="reason" value="{$reason}"/></xsl:if>
            <xsl:if test="$cert != ''"><my:attr name="cert" value="{$cert}"/></xsl:if>
          </xsl:when>
        </xsl:choose>
      </my:range>
    </xsl:for-each>
  </xsl:template>

  <!-- zerlegt einen @custom-String in ALLE "name {inhalt}"-Bloecke (auch
       mehrfach vorkommende Namen), in Lesereihenfolge; "readingOrder" wird
       uebersprungen -->
  <xsl:template name="parse-all-blocks">
    <xsl:param name="s"/>
    <xsl:variable name="trimmed">
      <xsl:call-template name="trim"><xsl:with-param name="s" select="$s"/></xsl:call-template>
    </xsl:variable>
    <xsl:if test="contains($trimmed,'{')">
      <xsl:variable name="name" select="normalize-space(substring-before($trimmed,'{'))"/>
      <xsl:variable name="afterBrace" select="substring-after($trimmed,'{')"/>
      <xsl:variable name="content" select="substring-before($afterBrace,'}')"/>
      <xsl:variable name="rest" select="substring-after($afterBrace,'}')"/>
      <xsl:if test="$name != 'readingOrder'">
        <my:block name="{$name}" content="{$content}"/>
      </xsl:if>
      <xsl:call-template name="parse-all-blocks">
        <xsl:with-param name="s" select="$rest"/>
      </xsl:call-template>
    </xsl:if>
  </xsl:template>

  <!-- fuer jeden Bereich: die kleinste ANDERE Angabe, die ihn vollstaendig
       umschliesst (0 = keine, also oberste Ebene) -->
  <xsl:template name="build-range-parents">
    <xsl:param name="ranges"/>
    <xsl:for-each select="$ranges">
      <xsl:variable name="me" select="."/>
      <xsl:variable name="p">
        <xsl:call-template name="find-range-parent">
          <xsl:with-param name="ranges" select="$ranges"/>
          <xsl:with-param name="me" select="$me"/>
        </xsl:call-template>
      </xsl:variable>
      <my:rp idx="{$me/@idx}" parent="{$p}"/>
    </xsl:for-each>
  </xsl:template>

  <xsl:template name="find-range-parent">
    <xsl:param name="ranges"/>
    <xsl:param name="me"/>
    <xsl:variable name="candidatesRTF">
      <xsl:for-each select="$ranges[@idx != $me/@idx and number(@offset) &lt;= number($me/@offset) and number(@end) &gt;= number($me/@end)]">
        <xsl:sort select="number(@end) - number(@offset)" data-type="number" order="ascending"/>
        <xsl:if test="position()=1"><my:pidx val="{@idx}"/></xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="candidate" select="exsl:node-set($candidatesRTF)/my:pidx/@val"/>
    <xsl:choose>
      <xsl:when test="$candidate"><xsl:value-of select="$candidate"/></xsl:when>
      <xsl:otherwise>0</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Geschwister-Bereiche eines Containers (Zeile oder verschachtelter
       Bereich) der Reihe nach ausgeben, mit dem dazwischenliegenden Klartext -->
  <xsl:template name="render-span-children">
    <xsl:param name="ranges"/>
    <xsl:param name="rangeParents"/>
    <xsl:param name="parentIdx"/>
    <xsl:param name="spanStart"/>
    <xsl:param name="spanEnd"/>
    <xsl:param name="text"/>
    <xsl:variable name="orderedRTF">
      <xsl:for-each select="$rangeParents[@parent=$parentIdx]">
        <xsl:sort select="number($ranges[@idx=current()/@idx]/@offset)" data-type="number"/>
        <my:child idx="{@idx}"/>
      </xsl:for-each>
    </xsl:variable>
    <xsl:call-template name="render-children-seq">
      <xsl:with-param name="ranges" select="$ranges"/>
      <xsl:with-param name="rangeParents" select="$rangeParents"/>
      <xsl:with-param name="ordered" select="exsl:node-set($orderedRTF)/my:child"/>
      <xsl:with-param name="pos" select="1"/>
      <xsl:with-param name="cursor" select="$spanStart"/>
      <xsl:with-param name="spanEnd" select="$spanEnd"/>
      <xsl:with-param name="text" select="$text"/>
    </xsl:call-template>
  </xsl:template>

  <xsl:template name="render-children-seq">
    <xsl:param name="ranges"/>
    <xsl:param name="rangeParents"/>
    <xsl:param name="ordered"/>
    <xsl:param name="pos"/>
    <xsl:param name="cursor"/>
    <xsl:param name="spanEnd"/>
    <xsl:param name="text"/>
    <xsl:choose>
      <xsl:when test="$pos &gt; count($ordered)">
        <xsl:value-of select="substring($text, $cursor + 1, $spanEnd - $cursor)"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="childIdx" select="$ordered[$pos]/@idx"/>
        <xsl:variable name="range" select="$ranges[@idx=$childIdx]"/>
        <xsl:variable name="cStart" select="number($range/@offset)"/>
        <xsl:variable name="cEnd" select="number($range/@end)"/>
        <xsl:value-of select="substring($text, $cursor + 1, $cStart - $cursor)"/>
        <xsl:call-template name="render-one-range">
          <xsl:with-param name="ranges" select="$ranges"/>
          <xsl:with-param name="rangeParents" select="$rangeParents"/>
          <xsl:with-param name="range" select="$range"/>
          <xsl:with-param name="text" select="$text"/>
        </xsl:call-template>
        <xsl:call-template name="render-children-seq">
          <xsl:with-param name="ranges" select="$ranges"/>
          <xsl:with-param name="rangeParents" select="$rangeParents"/>
          <xsl:with-param name="ordered" select="$ordered"/>
          <xsl:with-param name="pos" select="$pos + 1"/>
          <xsl:with-param name="cursor" select="$cEnd"/>
          <xsl:with-param name="spanEnd" select="$spanEnd"/>
          <xsl:with-param name="text" select="$text"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ein Bereich als Element: eigene Attribute, Inhalt entweder Klartext
       (Blatt) oder rekursiv verschachtelte Kind-Bereiche -->
  <xsl:template name="render-one-range">
    <xsl:param name="ranges"/>
    <xsl:param name="rangeParents"/>
    <xsl:param name="range"/>
    <xsl:param name="text"/>
    <xsl:variable name="hasChildren" select="boolean($rangeParents[@parent=$range/@idx])"/>
    <xsl:element name="{$range/@element}">
      <xsl:for-each select="$range/my:attr">
        <xsl:attribute name="{@name}"><xsl:value-of select="@value"/></xsl:attribute>
      </xsl:for-each>
      <xsl:choose>
        <xsl:when test="$hasChildren">
          <xsl:call-template name="render-span-children">
            <xsl:with-param name="ranges" select="$ranges"/>
            <xsl:with-param name="rangeParents" select="$rangeParents"/>
            <xsl:with-param name="parentIdx" select="$range/@idx"/>
            <xsl:with-param name="spanStart" select="number($range/@offset)"/>
            <xsl:with-param name="spanEnd" select="number($range/@end)"/>
            <xsl:with-param name="text" select="$text"/>
          </xsl:call-template>
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select="substring($text, number($range/@offset) + 1, number($range/@end) - number($range/@offset))"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:element>
  </xsl:template>

  <!-- ein ueber mehrere Zeilen (via continued:true an einer obersten,
       kinderlosen Angabe) reichender Lauf: EIN Element, das <lb/> als Kind
       enthaelt; danach der Rest der letzten Zeile und die normale
       Weiterverarbeitung ab der Folgezeile -->
  <xsl:template name="render-run-span">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="depth"/>
    <xsl:param name="compact" select="false()"/>
    <xsl:param name="element"/>
    <xsl:param name="attrs"/>
    <xsl:param name="startOffset"/>
    <xsl:variable name="endIndexRTF">
      <xsl:call-template name="find-run-end-index">
        <xsl:with-param name="lines" select="$lines"/>
        <xsl:with-param name="index" select="$index"/>
        <xsl:with-param name="element" select="$element"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="endIndex" select="number($endIndexRTF)"/>
    <xsl:element name="{$element}">
      <xsl:for-each select="$attrs">
        <xsl:attribute name="{@name}"><xsl:value-of select="@value"/></xsl:attribute>
      </xsl:for-each>
      <xsl:call-template name="run-span-body">
        <xsl:with-param name="lines" select="$lines"/>
        <xsl:with-param name="index" select="$index"/>
        <xsl:with-param name="current" select="$index"/>
        <xsl:with-param name="endIndex" select="$endIndex"/>
        <xsl:with-param name="depth" select="$depth"/>
        <xsl:with-param name="compact" select="$compact"/>
        <xsl:with-param name="startOffset" select="$startOffset"/>
      </xsl:call-template>
    </xsl:element>
    <xsl:variable name="lastLine" select="$lines[$endIndex]"/>
    <xsl:variable name="lastText" select="$lastLine/*[local-name()='TextEquiv'][1]/*[local-name()='Unicode']"/>
    <xsl:variable name="lastLen">
      <xsl:choose>
        <xsl:when test="$endIndex = $index">
          <xsl:value-of select="string-length($lastText)"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:variable name="rRTF"><xsl:call-template name="parse-line-ranges"><xsl:with-param name="line" select="$lastLine"/></xsl:call-template></xsl:variable>
          <xsl:value-of select="number(exsl:node-set($rRTF)/my:range[@offset='0' and @element=$element]/@end)"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:value-of select="substring($lastText, number($lastLen) + 1)"/>
    <xsl:call-template name="process-line">
      <xsl:with-param name="lines" select="$lines"/>
      <xsl:with-param name="index" select="$endIndex + 1"/>
      <xsl:with-param name="depth" select="$depth"/>
      <xsl:with-param name="compact" select="$compact"/>
    </xsl:call-template>
  </xsl:template>

  <!-- letzter Zeilenindex, der noch zum bei $index beginnenden Lauf
       desselben Elementtyps gehoert (Fortsetzung erkannt an offset:0 auf der
       Folgezeile, kinderlos, gleicher Elementname) -->
  <xsl:template name="find-run-end-index">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="element"/>
    <xsl:choose>
      <xsl:when test="$index &lt; count($lines)">
        <xsl:variable name="nextRangesRTF">
          <xsl:call-template name="parse-line-ranges"><xsl:with-param name="line" select="$lines[$index + 1]"/></xsl:call-template>
        </xsl:variable>
        <xsl:variable name="nextRanges" select="exsl:node-set($nextRangesRTF)/my:range"/>
        <xsl:variable name="cont" select="$nextRanges[@offset='0' and @element=$element]"/>
        <xsl:choose>
          <xsl:when test="$cont">
            <xsl:variable name="contParentsRTF">
              <xsl:call-template name="build-range-parents"><xsl:with-param name="ranges" select="$nextRanges"/></xsl:call-template>
            </xsl:variable>
            <xsl:variable name="contHasChildren" select="boolean(exsl:node-set($contParentsRTF)/my:rp[@parent=$cont/@idx])"/>
            <xsl:choose>
              <xsl:when test="$contHasChildren"><xsl:value-of select="$index"/></xsl:when>
              <xsl:when test="$cont/@continued='true'">
                <xsl:call-template name="find-run-end-index">
                  <xsl:with-param name="lines" select="$lines"/>
                  <xsl:with-param name="index" select="$index + 1"/>
                  <xsl:with-param name="element" select="$element"/>
                </xsl:call-template>
              </xsl:when>
              <xsl:otherwise><xsl:value-of select="$index + 1"/></xsl:otherwise>
            </xsl:choose>
          </xsl:when>
          <xsl:otherwise><xsl:value-of select="$index"/></xsl:otherwise>
        </xsl:choose>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$index"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Inhalt eines mehrzeiligen Laufs: fuer jede beteiligte Zeile ihr
       Laufabschnitt, getrennt durch <lb/> (ausser vor der ersten Zeile,
       deren <lb/> schon von process-line ausgegeben wurde) -->
  <xsl:template name="run-span-body">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="current"/>
    <xsl:param name="endIndex"/>
    <xsl:param name="depth"/>
    <xsl:param name="compact" select="false()"/>
    <xsl:param name="startOffset"/>
    <xsl:variable name="line" select="$lines[$current]"/>
    <xsl:variable name="text" select="$line/*[local-name()='TextEquiv'][1]/*[local-name()='Unicode']"/>
    <xsl:if test="$current &gt; $index">
      <xsl:if test="not($compact)">
        <xsl:text>&#10;</xsl:text>
        <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
      </xsl:if>
      <lb/>
    </xsl:if>
    <xsl:choose>
      <xsl:when test="$current = $index">
        <xsl:value-of select="substring($text, number($startOffset) + 1)"/>
      </xsl:when>
      <xsl:when test="$current = $endIndex">
        <xsl:variable name="rRTF"><xsl:call-template name="parse-line-ranges"><xsl:with-param name="line" select="$line"/></xsl:call-template></xsl:variable>
        <xsl:variable name="r" select="exsl:node-set($rRTF)/my:range[@offset='0']"/>
        <xsl:value-of select="substring($text, 1, number($r/@end))"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$text"/>
      </xsl:otherwise>
    </xsl:choose>
    <xsl:if test="$current &lt; $endIndex">
      <xsl:call-template name="run-span-body">
        <xsl:with-param name="lines" select="$lines"/>
        <xsl:with-param name="index" select="$index"/>
        <xsl:with-param name="current" select="$current + 1"/>
        <xsl:with-param name="endIndex" select="$endIndex"/>
        <xsl:with-param name="depth" select="$depth"/>
        <xsl:with-param name="compact" select="$compact"/>
        <xsl:with-param name="startOffset" select="$startOffset"/>
      </xsl:call-template>
    </xsl:if>
  </xsl:template>


  <!-- $depth mal zwei Leerzeichen (fuer die manuelle Einrueckung von
       Mischinhalt, den der Serialisierer nicht automatisch einrueckt) -->
  <xsl:template name="indent">
    <xsl:param name="depth"/>
    <xsl:if test="$depth &gt; 0">
      <xsl:text>  </xsl:text>
      <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth - 1"/></xsl:call-template>
    </xsl:if>
  </xsl:template>

  <!-- ===================== Regionen-Index (Phase 0) ===================== -->

  <xsl:template name="build-region-entry">
    <xsl:variable name="bboxRTF">
      <xsl:call-template name="bbox">
        <xsl:with-param name="points" select="*[local-name()='Coords']/@points"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="bbox" select="exsl:node-set($bboxRTF)"/>
    <xsl:variable name="minX" select="number($bbox/my:minX)"/>
    <xsl:variable name="minY" select="number($bbox/my:minY)"/>
    <xsl:variable name="maxX" select="number($bbox/my:maxX)"/>
    <xsl:variable name="maxY" select="number($bbox/my:maxY)"/>
    <xsl:variable name="type">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'type'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="subtype">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'subtype'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="compositOrder">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'composit-order'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="index">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'readingOrder'"/>
        <xsl:with-param name="key" select="'index'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="rendition">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'rendition'"/>
      </xsl:call-template>
    </xsl:variable>
    <my:region id="{@id}" type="{$type}" subtype="{$subtype}" compositOrder="{$compositOrder}" index="{$index}" rendition="{$rendition}"
            minX="{$minX}" minY="{$minY}" maxX="{$maxX}" maxY="{$maxY}"
            area="{($maxX - $minX) * ($maxY - $minY)}"/>
  </xsl:template>

  <!-- Min/Max aus "x,y x,y ..." extrahieren -->
  <xsl:template name="bbox">
    <xsl:param name="points"/>
    <xsl:param name="minX" select="''"/>
    <xsl:param name="minY" select="''"/>
    <xsl:param name="maxX" select="''"/>
    <xsl:param name="maxY" select="''"/>
    <xsl:variable name="trimmed" select="normalize-space($points)"/>
    <xsl:choose>
      <xsl:when test="$trimmed = ''">
        <my:minX><xsl:value-of select="$minX"/></my:minX>
        <my:minY><xsl:value-of select="$minY"/></my:minY>
        <my:maxX><xsl:value-of select="$maxX"/></my:maxX>
        <my:maxY><xsl:value-of select="$maxY"/></my:maxY>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="pair">
          <xsl:choose>
            <xsl:when test="contains($trimmed,' ')"><xsl:value-of select="substring-before($trimmed,' ')"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="$trimmed"/></xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:variable name="rest">
          <xsl:if test="contains($trimmed,' ')"><xsl:value-of select="substring-after($trimmed,' ')"/></xsl:if>
        </xsl:variable>
        <xsl:variable name="x" select="number(substring-before($pair,','))"/>
        <xsl:variable name="y" select="number(substring-after($pair,','))"/>
        <xsl:variable name="newMinX"><xsl:choose><xsl:when test="$minX='' or $x &lt; $minX"><xsl:value-of select="$x"/></xsl:when><xsl:otherwise><xsl:value-of select="$minX"/></xsl:otherwise></xsl:choose></xsl:variable>
        <xsl:variable name="newMinY"><xsl:choose><xsl:when test="$minY='' or $y &lt; $minY"><xsl:value-of select="$y"/></xsl:when><xsl:otherwise><xsl:value-of select="$minY"/></xsl:otherwise></xsl:choose></xsl:variable>
        <xsl:variable name="newMaxX"><xsl:choose><xsl:when test="$maxX='' or $x &gt; $maxX"><xsl:value-of select="$x"/></xsl:when><xsl:otherwise><xsl:value-of select="$maxX"/></xsl:otherwise></xsl:choose></xsl:variable>
        <xsl:variable name="newMaxY"><xsl:choose><xsl:when test="$maxY='' or $y &gt; $maxY"><xsl:value-of select="$y"/></xsl:when><xsl:otherwise><xsl:value-of select="$maxY"/></xsl:otherwise></xsl:choose></xsl:variable>
        <xsl:call-template name="bbox">
          <xsl:with-param name="points" select="$rest"/>
          <xsl:with-param name="minX" select="$newMinX"/>
          <xsl:with-param name="minY" select="$newMinY"/>
          <xsl:with-param name="maxX" select="$newMaxX"/>
          <xsl:with-param name="maxY" select="$newMaxY"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ===================== Eltern-Ermittlung (Phase 1) ===================== -->

  <!-- Fuellt $parents (siehe Ueberblick am Dateianfang, Subsystem 1): fuer
       EINE Region $me wird deren Elternteil bestimmt.
         - $me ist selbst eine surface: Elternteil kann nur eine andere
           surface sein (surface-in-surface); kein Treffer -> $baseId, ausser
           $me IST bereits $baseId (die aeusserste hat keinen Elternteil).
         - $me ist eine zone: zuerst unter anderen zones suchen (zone-in-
           zone), dann unter surfaces (zone-in-surface), zuletzt Fallback auf
           $baseId, damit nichts verloren geht.
       Das eigentliche "wer enthaelt wen" entscheidet find-parent-id. -->
  <xsl:template name="determine-parent">
    <xsl:param name="me"/>
    <xsl:choose>
      <xsl:when test="$me/@type='surface'">
        <xsl:variable name="candidates" select="$surfaceRegions[@id != $me/@id]"/>
        <xsl:variable name="found">
          <xsl:call-template name="find-parent-id">
            <xsl:with-param name="me" select="$me"/>
            <xsl:with-param name="candidates" select="$candidates"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:choose>
          <xsl:when test="$found != ''"><xsl:value-of select="$found"/></xsl:when>
          <xsl:when test="$me/@id = $baseId"/>
          <xsl:otherwise><xsl:value-of select="$baseId"/></xsl:otherwise>
        </xsl:choose>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="zoneCandidates" select="$regions[@type != 'surface' and @id != $me/@id]"/>
        <xsl:variable name="foundZone">
          <xsl:call-template name="find-parent-id">
            <xsl:with-param name="me" select="$me"/>
            <xsl:with-param name="candidates" select="$zoneCandidates"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:choose>
          <xsl:when test="$foundZone != ''"><xsl:value-of select="$foundZone"/></xsl:when>
          <xsl:otherwise>
            <xsl:variable name="foundSurface">
              <xsl:call-template name="find-parent-id">
                <xsl:with-param name="me" select="$me"/>
                <xsl:with-param name="candidates" select="$surfaceRegions"/>
              </xsl:call-template>
            </xsl:variable>
            <xsl:choose>
              <xsl:when test="$foundSurface != ''"><xsl:value-of select="$foundSurface"/></xsl:when>
              <xsl:otherwise><xsl:value-of select="$baseId"/></xsl:otherwise>
            </xsl:choose>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- unter $candidates die kleinste, die $me zu >=95% enthaelt -->
  <xsl:template name="find-parent-id">
    <xsl:param name="me"/>
    <xsl:param name="candidates"/>
    <xsl:variable name="qualifyingRTF">
      <xsl:for-each select="$candidates">
        <xsl:variable name="ratio">
          <xsl:call-template name="containment-ratio">
            <xsl:with-param name="aMinX" select="$me/@minX"/>
            <xsl:with-param name="aMinY" select="$me/@minY"/>
            <xsl:with-param name="aMaxX" select="$me/@maxX"/>
            <xsl:with-param name="aMaxY" select="$me/@maxY"/>
            <xsl:with-param name="bMinX" select="@minX"/>
            <xsl:with-param name="bMinY" select="@minY"/>
            <xsl:with-param name="bMaxX" select="@maxX"/>
            <xsl:with-param name="bMaxY" select="@maxY"/>
          </xsl:call-template>
        </xsl:variable>
        <!-- Ein Kandidat muss mindestens so gross sein wie $me selbst (Flaeche,
             bei Gleichstand @id als Tiebreak). Sonst koennten zwei Regionen
             mit fast identischer Bounding-Box sich gegenseitig als Elternteil
             waehlen (Zyklus, beide wuerden dann nie erreicht). -->
        <xsl:variable name="sizeOk" select="number(@area) &gt; number($me/@area) or (number(@area) = number($me/@area) and @id &gt; $me/@id)"/>
        <xsl:if test="number($ratio) &gt;= 0.95 and $sizeOk">
          <my:cand id="{@id}" area="{@area}"/>
        </xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <xsl:for-each select="exsl:node-set($qualifyingRTF)/my:cand">
      <xsl:sort select="@area" data-type="number" order="ascending"/>
      <xsl:if test="position()=1"><xsl:value-of select="@id"/></xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- Anteil von a, der innerhalb von b liegt (Bounding-Box-Naeherung) -->
  <xsl:template name="containment-ratio">
    <xsl:param name="aMinX"/><xsl:param name="aMinY"/><xsl:param name="aMaxX"/><xsl:param name="aMaxY"/>
    <xsl:param name="bMinX"/><xsl:param name="bMinY"/><xsl:param name="bMaxX"/><xsl:param name="bMaxY"/>
    <xsl:variable name="ix0"><xsl:choose><xsl:when test="number($aMinX) &gt;= number($bMinX)"><xsl:value-of select="$aMinX"/></xsl:when><xsl:otherwise><xsl:value-of select="$bMinX"/></xsl:otherwise></xsl:choose></xsl:variable>
    <xsl:variable name="iy0"><xsl:choose><xsl:when test="number($aMinY) &gt;= number($bMinY)"><xsl:value-of select="$aMinY"/></xsl:when><xsl:otherwise><xsl:value-of select="$bMinY"/></xsl:otherwise></xsl:choose></xsl:variable>
    <xsl:variable name="ix1"><xsl:choose><xsl:when test="number($aMaxX) &lt;= number($bMaxX)"><xsl:value-of select="$aMaxX"/></xsl:when><xsl:otherwise><xsl:value-of select="$bMaxX"/></xsl:otherwise></xsl:choose></xsl:variable>
    <xsl:variable name="iy1"><xsl:choose><xsl:when test="number($aMaxY) &lt;= number($bMaxY)"><xsl:value-of select="$aMaxY"/></xsl:when><xsl:otherwise><xsl:value-of select="$bMaxY"/></xsl:otherwise></xsl:choose></xsl:variable>
    <xsl:variable name="iw"><xsl:choose><xsl:when test="number($ix1) - number($ix0) &gt; 0"><xsl:value-of select="number($ix1) - number($ix0)"/></xsl:when><xsl:otherwise>0</xsl:otherwise></xsl:choose></xsl:variable>
    <xsl:variable name="ih"><xsl:choose><xsl:when test="number($iy1) - number($iy0) &gt; 0"><xsl:value-of select="number($iy1) - number($iy0)"/></xsl:when><xsl:otherwise>0</xsl:otherwise></xsl:choose></xsl:variable>
    <xsl:variable name="interArea" select="number($iw) * number($ih)"/>
    <xsl:variable name="areaA" select="(number($aMaxX)-number($aMinX)) * (number($aMaxY)-number($aMinY))"/>
    <xsl:choose>
      <xsl:when test="$areaA &gt; 0"><xsl:value-of select="$interArea div $areaA"/></xsl:when>
      <xsl:otherwise>0</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- @id des Knotens mit groesster/kleinster @area aus $nodes -->
  <xsl:template name="pick-extreme-id">
    <xsl:param name="nodes"/>
    <xsl:param name="order"/>
    <xsl:for-each select="$nodes">
      <xsl:sort select="@area" data-type="number" order="{$order}"/>
      <xsl:if test="position()=1"><xsl:value-of select="@id"/></xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- Text nach dem letzten "_" (oder der ganze String, falls kein "_" enthalten) -->
  <xsl:template name="after-last-underscore">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s,'_')">
        <xsl:call-template name="after-last-underscore">
          <xsl:with-param name="s" select="substring-after($s,'_')"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- mit fuehrenden Nullen auf mindestens 4 Stellen auffuellen -->
  <xsl:template name="pad4">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="string-length($s) &gt;= 4"><xsl:value-of select="$s"/></xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="pad4">
          <xsl:with-param name="s" select="concat('0',$s)"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ===================== @custom auswerten ===================== -->

  <!-- roher Inhalt von "block {..inhalt..}" innerhalb von @custom (erstes
       Vorkommen), oder leer falls der Block fehlt -->
  <xsl:template name="block-content">
    <xsl:param name="custom"/>
    <xsl:param name="block"/>
    <xsl:variable name="marker" select="concat($block,' {')"/>
    <xsl:if test="contains($custom,$marker)">
      <xsl:value-of select="substring-before(substring-after($custom,$marker),'}')"/>
    </xsl:if>
  </xsl:template>

  <!-- liest key aus "block {..key:value;..}" innerhalb von @custom -->
  <xsl:template name="custom-value">
    <xsl:param name="custom"/>
    <xsl:param name="block"/>
    <xsl:param name="key"/>
    <xsl:variable name="inner">
      <xsl:call-template name="block-content">
        <xsl:with-param name="custom" select="$custom"/>
        <xsl:with-param name="block" select="$block"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:call-template name="token-value">
      <xsl:with-param name="tokens" select="$inner"/>
      <xsl:with-param name="key" select="$key"/>
    </xsl:call-template>
  </xsl:template>

  <xsl:template name="token-value">
    <xsl:param name="tokens"/>
    <xsl:param name="key"/>
    <xsl:variable name="first">
      <xsl:choose>
        <xsl:when test="contains($tokens,';')"><xsl:value-of select="substring-before($tokens,';')"/></xsl:when>
        <xsl:otherwise><xsl:value-of select="$tokens"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="trimmed">
      <xsl:call-template name="trim"><xsl:with-param name="s" select="$first"/></xsl:call-template>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="substring-before($trimmed,':') = $key">
        <xsl:value-of select="substring-after($trimmed,':')"/>
      </xsl:when>
      <xsl:when test="contains($tokens,';')">
        <xsl:call-template name="token-value">
          <xsl:with-param name="tokens" select="substring-after($tokens,';')"/>
          <xsl:with-param name="key" select="$key"/>
        </xsl:call-template>
      </xsl:when>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="trim">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="starts-with($s,' ')">
        <xsl:call-template name="trim"><xsl:with-param name="s" select="substring($s,2)"/></xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

</xsl:stylesheet>
