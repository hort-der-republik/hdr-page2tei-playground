<?xml version="1.0" encoding="UTF-8"?>
<!--
  Wandelt PAGE-XML (eScriptorium/Transkribus) in TEI um.

  KURZFASSUNG (die ausfuehrliche, immer aktuell gehaltene Referenz aller
  Regeln steht in verarbeitungsregeln.md im selben Ordner; die Architektur-
  Erklaerung fuer Programmierer steht weiter unten, Abschnitt "WIE MAN DIESE
  DATEI LIEST"):

  facsimile: reine Bild-Geometrie. Genau ein <graphic> (das ganze Digitalisat)
  als Kind von <facsimile>. Regionen mit custom-type "surface" werden zu
  <surface>, alle anderen Regionen zu <zone>. Verschachtelung wird geometrisch
  bestimmt (Bounding-Box-Naeherung statt exakter Polygonflaeche, siehe unten):
    - surface enthaelt zone, wenn zone zu >=95% in surface liegt und in
      keiner kleineren surface >=95% enthalten ist
    - surface enthaelt surface analog; die aeusserste surface ist immer
      "base" (Marker structure{cat:base;} in @custom; ohne solchen Marker:
      die einzige surface-Region; sonst wird eine synthetische Basis-
      Surface in Bildgroesse erzeugt)
    - zone enthaelt zone analog (kleinste passende Elternzone gewinnt)
  Jede <TextLine> bekommt zusaetzlich eine eigene <zone type="line">,
  verschachtelt in der Zone/surface, der sie per $lineAssign zugeordnet ist
  (siehe render-line-zones-for-region); <lb facs="#zone_<Zeilen-id>"/> im
  text/body-Teil verweist darauf. Welche Region eine Zeile "besitzt" wird
  NICHT aus der PAGE-XML-Struktur uebernommen, sondern geometrisch neu
  bestimmt: jede Zeile gehoert zur kleinsten Region, deren Bounding-Box den
  Mittelpunkt der Zeile enthaelt (Details und Begruendung bei $lineAssign
  weiter unten).

  text/body: dieselbe Verschachtelung (surface/zone) wird gespiegelt, aber
  mit den Transkriptionen statt Koordinaten:
    - surface -> <div facs="#surface_..."> (@type nur aus subcat; cat/source stehen nicht am div)
    - zone type "column-block" -> leeres <cb n=".."/> VOR den Inhalten; "add-block" -> <div type="add-block">
    - jede zone mit eigenen Kind-Zonen -> <div> (sonst waere Text direkt im
      div, was TEI nicht erlaubt); eigener Zeilentext (falls vorhanden) als
      <p> Kind
    - zone type "head" (ohne Kinder) -> <head>
    - zone type "annotation" ODER "metamark" -> <metamark xml:id="metamark-
      SEITE-NNNN">, fortlaufend nummeriert (siehe $metamarkOrder), immer
      direktes Kind des naechsten umschliessenden <div> (ergibt sich
      automatisch, weil jede Zone mit einem solchen Kind zu einem <div>
      statt <p> wird); @function/@target aus structure{function:..;target:..;}
      werden uebernommen (target ueber die Behelfs-ID-Tabelle aufgeloest,
      siehe $behelfsMap weiter unten). Hat die metamark @target, wird sie
      abweichend von der sonstigen Zone-Verschachtelung direktes Kind der
      surface (nicht der kleinsten umschliessenden Zone).
    - zone type "gap" -> leeres <gap/>
    - zone type "add" -> <add xml:id="add-SEITE-NNNN"> (validiert bewusst
      NICHT gegen TEI, siehe render-zone-text), kompakt ohne Zeilenumbruch
      im Markup; wird eine add-Region per Behelfs-ID (add-id) anderswo
      inline importiert (siehe subst-del/metamark-add unten), entfaellt
      ihre eigene Baumposition hier (siehe $consumedAddRegions)
    - zone type "fw" -> <fw>
    - zone type "advertisement" -> <div type="advertisement">
    - Ausnahme zu "jede Zone mit Kind-Zonen -> <div>": hat eine Zone
      long-quote-Kind-Zonen (und sonst nur metamark/gap), wird sie selbst
      zu <p> mit den <quote> darin (siehe is-quote-host)
    - zone type "long-quote-p" -> <quote><p rendition="long-quote">; "long-quote-lg"
      -> <quote><lg rendition="long-quote"> mit <l facs> statt <lb/>; die
      Relation "multi-p-quote" packt mehrere solche Regionen in EIN <quote>
    - alle anderen zones (paragraph, ohne type, ...) -> <p> (kein @type,
      TEI-All erlaubt das dort nicht; structure{rendition:[Wert];} wird
      generisch zu @rendition="[Wert]", "longquote" speziell zu "longQuote";
      hat die Region eine Behelfs-ID, bekommt das <p> zusaetzlich eine
      xml:id nach demselben Muster)
    - Transkribus-Relationen vom Typ "Article"/"montage-element": deren
      Mitglieder (nur die vom Typ paragraph/long-quote-*/head) werden zusaetzlich in ein
      <div type="article"|"montage-element"> gruppiert, das an der Stelle
      des zuerst gelesenen Mitglieds im umgebenden div steht
    - innerhalb einer Zeile koennen zeichenbasierte Annotationen stehen
      (hi mit rendition/spacing/hi-*/bold/underline/retrace/mod/mod-underline/del/deselection/seg/
      seg-transposition/gap/gap-cut/add/metamark/metamark-add/unclear/
      subst/subst-del/sic/undo), die zu Inline-Elementen wie <hi>/<del>/
      <add>/<subst>/<choice><sic>/<corr>/<undo>...<anchor> werden, ggf.
      verschachtelt und/oder ueber mehrere Zeilen reichend (siehe
      process-line weiter unten). Eine ununterbrochene Gruppe von mehr als
      einem "#" im Klartext wird ausserdem automatisch zu <gap extent="N"/>
      zusammengefasst (siehe text-with-gaps).

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

  <!-- suppress-indentation (XSLT 3.0-Attribut, von Saxon auch in
       1.0-Stylesheets akzeptiert): Saxon (z.B. Oxygen) setzt bei indent="yes"
       Zeilenumbrueche zwischen Geschwister-ELEMENTEN, auch in Fliesstext -
       also vor und nach <subst>/<hi>/<anchor> usw. - was im Text zusaetzliche
       Leerzeichen erzeugt. Fuer alle Elemente mit Fliesstext (Zeilen/<lb/>)
       wird die automatische Einrueckung daher abgeschaltet; die Einrueckung
       der <lb/>-Zeilen selbst kommt aus dem Template "indent" (siehe oben).
       xsltproc/libxslt ignoriert das Attribut (setzt dort ohnehin keine Umbrueche). -->
  <xsl:output method="xml" indent="yes" encoding="UTF-8"
              suppress-indentation="p head fw add metamark l"/>

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

  <!-- EINMALIGE, zentrale Zeichenbereichs-Analyse ALLER Zeilen (Abschnitt 7):
       parse-line-ranges wird bewusst nur HIER fuer die ganze Seite
       aufgerufen; alle spaeteren globalen Variablen (Behelfs-ID-Sammlung,
       Ketten-Erkennung, undo-/deselection-/Import-Nummerierung...), die
       frueher jede fuer sich unabhaengig noch einmal ueber $allLines
       gelaufen sind und parse-line-ranges NEU aufgerufen haben, filtern
       stattdessen nur noch aus dieser einen vorberechneten Liste. Grund:
       xsltproc wurde bei acht/neun unabhaengigen globalen RTF-Variablen,
       die alle dasselbe rekursive Template ueber die ganze Seite aufrufen,
       nachweislich instabil (sporadisches "Redefinition of variable" -
       ein interner Fehler des Prozessors, kein Fehler in diesem Stylesheet,
       aber durch weniger redundante Rekursion zuverlaessig vermeidbar). -->
  <xsl:variable name="allLineRangesRTF">
    <xsl:for-each select="$allLines">
      <xsl:variable name="lnId" select="@id"/>
      <xsl:variable name="rRTF"><xsl:call-template name="parse-line-ranges"><xsl:with-param name="line" select="."/></xsl:call-template></xsl:variable>
      <xsl:for-each select="exsl:node-set($rRTF)/my:range">
        <my:lr line="{$lnId}" idx="{@idx}" offset="{@offset}" end="{@end}" element="{@element}" continued="{@continued}" newOrder="{@newOrder}" otherSeg="{@otherSeg}">
          <xsl:copy-of select="my:attr"/>
        </my:lr>
      </xsl:for-each>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="allLineRanges" select="exsl:node-set($allLineRangesRTF)/my:lr"/>

  <xsl:param name="lineAssignTolerance" select="20"/>

  <xsl:variable name="lineAssignRawRTF">
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
        <!-- fixed-lines:y (Abschnitt 4): so eine Region bekommt KEINE fremden
             Zeilen zugeordnet (nur ihre eigenen) - sie scheidet fuer alle
             anderen Zeilen als Kandidat aus -->
        <xsl:for-each select="$regions[number(@minX) &lt;= $midX and $midX &lt;= number(@maxX) and number(@minY) &lt;= $midY and $midY &lt;= number(@maxY) and (@fixedLines != 'y' or @id = $parentRegionId)]">
          <!-- Zusatzbedingung (Abschnitt 4): eine Region, die NICHT die
               strukturelle Elternregion der Zeile ist, zaehlt nur, wenn der
               Mittelpunkt auch im ECHTEN Polygon liegt - die Bounding-Box
               allein rechnet schraege/gezackte Polygone zu gross und
               "klaut" sonst Zeilen, die tatsaechlich in der Elternregion
               liegen. -->
          <xsl:variable name="candPts" select="string($allRegions[@id=current()/@id]/*[local-name()='Coords']/@points)"/>
          <xsl:variable name="polyOk">
            <xsl:choose>
              <xsl:when test="@id = $parentRegionId or $candPts = ''">1</xsl:when>
              <xsl:otherwise>
                <xsl:call-template name="point-in-polygon">
                  <xsl:with-param name="x" select="$midX"/>
                  <xsl:with-param name="y" select="$midY"/>
                  <xsl:with-param name="pts" select="$candPts"/>
                </xsl:call-template>
              </xsl:otherwise>
            </xsl:choose>
          </xsl:variable>
          <xsl:if test="$polyOk = '1'"><my:cand id="{@id}" area="{@area}"/></xsl:if>
        </xsl:for-each>
      </xsl:variable>
      <xsl:variable name="best">
        <xsl:for-each select="exsl:node-set($qualifyingRTF)/my:cand">
          <xsl:sort select="@area" data-type="number" order="ascending"/>
          <xsl:if test="position()=1"><xsl:value-of select="@id"/></xsl:if>
        </xsl:for-each>
      </xsl:variable>
      <!-- Toleranz-Ausnahme (Abschnitt 4): liegt der Mittelpunkt nur knapp
           (<= $lineAssignTolerance Pixel) neben der Box der STRUKTURELLEN
           Elternregion und wuerde die Zeile stattdessen einer GROESSEREN
           Region zufallen, bleibt sie bei der Elternregion. Gilt bewusst
           nur fuer die Elternregion, nicht allgemein fuer alle Regionen. -->
      <xsl:variable name="parentRegion" select="$regions[@id=$parentRegionId]"/>
      <xsl:variable name="parentNearHit" select="boolean($parentRegion) and $best != '' and $best != $parentRegionId
          and number($parentRegion/@minX) - $lineAssignTolerance &lt;= $midX and $midX &lt;= number($parentRegion/@maxX) + $lineAssignTolerance
          and number($parentRegion/@minY) - $lineAssignTolerance &lt;= $midY and $midY &lt;= number($parentRegion/@maxY) + $lineAssignTolerance
          and number($parentRegion/@area) &lt;= number($regions[@id=$best]/@area)"/>
      <xsl:variable name="targetRegion">
        <xsl:choose>
          <!-- Ausnahme (Abschnitt 4): Region mit structure{fixed-lines:y;} -
               ihre eigenen Zeilen bleiben in dieser Region (facsimile und
               text), egal was die Geometrie sagt; fremde Zeilen bekommt sie
               nicht (siehe Kandidatenliste oben) -->
          <xsl:when test="$parentRegion/@fixedLines = 'y'"><xsl:value-of select="$parentRegionId"/></xsl:when>
          <xsl:when test="$parentNearHit"><xsl:value-of select="$parentRegionId"/></xsl:when>
          <xsl:when test="$best != ''"><xsl:value-of select="$best"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="$parentRegionId"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <my:la id="{$ln/@id}" region="{$targetRegion}" parent="{$parentRegionId}" pindex="{$parentRegionIndex}" oindex="{$ownIndex}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineAssignRaw" select="exsl:node-set($lineAssignRawRTF)/my:la"/>

  <!-- ===== Zeilenreihenfolge innerhalb einer Region =====
       Grundsatz: die Annotationsreihenfolge (Elternregion/readingOrder) bleibt
       erhalten. Nur Zeilen, die per Geometrie aus einer FREMDEN Elternregion in
       eine Region gewandert sind, werden nach ihrer Lage einsortiert:
         - y' = y - m*x an der Mitte der Baseline (erster/letzter Punkt), m = Median
           der Baseline-Steigungen der Zielregion (Schraglage-Korrektur; |m| > 1 -> 0)
         - unterscheiden sich zwei Zeilen unterschiedlicher Elternregionen in y' um
           mehr als $lineRowTolerance * (Median der Zeilen-Bounding-Box-Hoehe der
           Region), gilt die kleinere y' als frueher; sonst ("gleiche Reihe")
           entscheidet x (links vor rechts), dann pindex/oindex
         - Zeilen derselben Elternregion: weiter nach oindex
         - ein continued:true-Lauf (Folgezeilen derselben Elternregion) wird als
           Einheit behandelt: er nimmt y'/x seiner Kopfzeile, so dass keine fremde
           Zeile mitten in den Lauf einsortiert wird
       Ergebnis: @rank (Anzahl der Zeilen der Region, die vor dieser Zeile stehen);
       sortiert wird nach rank, dann pindex, dann oindex. -->
  <xsl:param name="lineRowTolerance" select="0.3"/>

  <xsl:template name="last-token">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s,' ')"><xsl:call-template name="last-token"><xsl:with-param name="s" select="substring-after($s,' ')"/></xsl:call-template></xsl:when>
      <xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Kopf eines continued:true-Laufs: die Zeile, deren Block (continued:true) bis
       hierher durchgelaufen ist, wird rueckwaerts (je Elternregion nach oindex)
       verfolgt. Ein solcher Lauf muss in der Ausgabe zusammenhaengend bleiben und
       wird deshalb als EINE Einheit einsortiert (gemeinsamer Schluessel = Kopfzeile). -->
  <xsl:variable name="contLinesRTF">
    <xsl:for-each select="$allLineRanges[@continued='true' and not(@line = preceding-sibling::*[@continued='true']/@line)]">
      <my:c id="{@line}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="contLines" select="exsl:node-set($contLinesRTF)/my:c"/>
  <!-- Elternregionen, in denen mindestens eine Zeile einen continued-Block hat -->
  <xsl:variable name="contParentsRTF">
    <xsl:for-each select="$lineAssignRaw[@id = $contLines/@id and not(@parent = preceding-sibling::*[@id = $contLines/@id]/@parent)]">
      <my:cp id="{@parent}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="contParents" select="exsl:node-set($contParentsRTF)/my:cp"/>

  <xsl:template name="run-head">
    <xsl:param name="id"/>
    <xsl:variable name="me" select="$lineAssignRaw[@id=$id]"/>
    <xsl:choose>
      <!-- schneller Ausgang: keine Zeile der Elternregion hat einen continued-Block -->
      <xsl:when test="not($contParents[@id=$me/@parent])"><xsl:value-of select="$id"/></xsl:when>
      <xsl:otherwise>
    <xsl:variable name="predRTF">
      <xsl:for-each select="$lineAssignRaw[@parent=$me/@parent and number(@oindex) &lt; number($me/@oindex)]">
        <xsl:sort select="number(@oindex)" data-type="number" order="descending"/>
        <xsl:if test="position()=1"><xsl:value-of select="@id"/></xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="pred" select="string($predRTF)"/>
    <xsl:choose>
      <!-- nur ein ECHTER Lauf: die Vorgaengerzeile hat einen continued:true-Block UND
           diese Zeile setzt ihn (gleiches Element) bei offset:0 fort -->
      <xsl:when test="$pred != '' and $allLineRanges[@line=$pred and @continued='true' and @element = $allLineRanges[@line=$id and number(@offset)=0]/@element]">
        <xsl:call-template name="run-head"><xsl:with-param name="id" select="$pred"/></xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$id"/></xsl:otherwise>
    </xsl:choose>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Regionen, in die mindestens eine Zeile aus einer FREMDEN Elternregion gewandert
       ist; nur dort ist die Geometrie-Einsortierung noetig (alle anderen behalten
       rank 0, d.h. die Reihenfolge nach pindex/oindex wie bisher) -->
  <xsl:variable name="mixedRegionsRTF">
    <xsl:for-each select="$lineAssignRaw[@parent != @region and not(@region = preceding-sibling::*[@parent != @region]/@region)]">
      <my:mx id="{@region}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="mixedRegions" select="exsl:node-set($mixedRegionsRTF)/my:mx"/>

  <!-- Stufe 1: je Zeile Mittelpunkt (xm,ym) der Baseline, Steigung, Boxhoehe h -->
  <xsl:variable name="lineGeoRTF">
    <xsl:for-each select="$lineAssignRaw[@region = $mixedRegions/@id]">
      <xsl:variable name="la" select="."/>
      <xsl:variable name="ln" select="$allLines[@id=$la/@id]"/>
      <xsl:variable name="bboxRTF"><xsl:call-template name="bbox"><xsl:with-param name="points" select="$ln/*[local-name()='Coords']/@points"/></xsl:call-template></xsl:variable>
      <xsl:variable name="bb" select="exsl:node-set($bboxRTF)"/>
      <xsl:variable name="bl" select="normalize-space($ln/*[local-name()='Baseline']/@points)"/>
      <xsl:variable name="firstPair" select="substring-before(concat($bl,' '),' ')"/>
      <xsl:variable name="lastPair"><xsl:call-template name="last-token"><xsl:with-param name="s" select="$bl"/></xsl:call-template></xsl:variable>
      <xsl:variable name="x1" select="number(substring-before($firstPair,','))"/>
      <xsl:variable name="y1" select="number(substring-after($firstPair,','))"/>
      <xsl:variable name="x2" select="number(substring-before($lastPair,','))"/>
      <xsl:variable name="y2" select="number(substring-after($lastPair,','))"/>
      <xsl:variable name="hasBl" select="$bl != '' and $x1 = $x1 and $y1 = $y1 and $x2 = $x2 and $y2 = $y2"/>
      <xsl:variable name="bmx" select="(number($bb/my:minX) + number($bb/my:maxX)) div 2"/>
      <xsl:variable name="bmy" select="(number($bb/my:minY) + number($bb/my:maxY)) div 2"/>
      <xsl:variable name="hRaw" select="number($bb/my:maxY) - number($bb/my:minY)"/>
      <my:la>
        <xsl:copy-of select="@*"/>
        <xsl:attribute name="head"><xsl:call-template name="run-head"><xsl:with-param name="id" select="@id"/></xsl:call-template></xsl:attribute>
        <xsl:attribute name="xm"><xsl:choose><xsl:when test="$hasBl"><xsl:value-of select="($x1 + $x2) div 2"/></xsl:when><xsl:when test="$bmx = $bmx"><xsl:value-of select="$bmx"/></xsl:when><xsl:otherwise>0</xsl:otherwise></xsl:choose></xsl:attribute>
        <xsl:attribute name="ym"><xsl:choose><xsl:when test="$hasBl"><xsl:value-of select="($y1 + $y2) div 2"/></xsl:when><xsl:when test="$bmy = $bmy"><xsl:value-of select="$bmy"/></xsl:when><xsl:otherwise>0</xsl:otherwise></xsl:choose></xsl:attribute>
        <xsl:attribute name="slope"><xsl:if test="$hasBl and $x2 != $x1"><xsl:value-of select="($y2 - $y1) div ($x2 - $x1)"/></xsl:if></xsl:attribute>
        <xsl:attribute name="h"><xsl:choose><xsl:when test="$hRaw = $hRaw"><xsl:value-of select="$hRaw"/></xsl:when><xsl:otherwise>0</xsl:otherwise></xsl:choose></xsl:attribute>
      </my:la>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineGeo" select="exsl:node-set($lineGeoRTF)/my:la"/>

  <!-- Stufe 2: je Zielregion Median-Steigung m und Zeilen-Reihen-Toleranz tol -->
  <xsl:variable name="lineRegionStatsRTF">
    <xsl:for-each select="$lineGeo[not(@region = preceding-sibling::*/@region)]">
      <xsl:variable name="rg" select="@region"/>
      <xsl:variable name="slopesRTF">
        <xsl:for-each select="$lineGeo[@region=$rg and @slope != '']">
          <xsl:sort select="number(@slope)" data-type="number"/>
          <my:v><xsl:value-of select="@slope"/></my:v>
        </xsl:for-each>
      </xsl:variable>
      <xsl:variable name="sl" select="exsl:node-set($slopesRTF)/my:v"/>
      <xsl:variable name="ns" select="count($sl)"/>
      <xsl:variable name="mRaw">
        <xsl:choose>
          <xsl:when test="$ns = 0">0</xsl:when>
          <xsl:otherwise><xsl:value-of select="(number($sl[floor(($ns + 1) div 2)]) + number($sl[ceiling(($ns + 1) div 2)])) div 2"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:variable name="hsRTF">
        <xsl:for-each select="$lineGeo[@region=$rg]">
          <xsl:sort select="number(@h)" data-type="number"/>
          <my:v><xsl:value-of select="@h"/></my:v>
        </xsl:for-each>
      </xsl:variable>
      <xsl:variable name="hs" select="exsl:node-set($hsRTF)/my:v"/>
      <xsl:variable name="nh" select="count($hs)"/>
      <my:rs region="{$rg}">
        <xsl:attribute name="m"><xsl:choose><xsl:when test="number($mRaw) &gt; 1 or number($mRaw) &lt; -1">0</xsl:when><xsl:otherwise><xsl:value-of select="$mRaw"/></xsl:otherwise></xsl:choose></xsl:attribute>
        <xsl:attribute name="tol"><xsl:value-of select="$lineRowTolerance * ((number($hs[floor(($nh + 1) div 2)]) + number($hs[ceiling(($nh + 1) div 2)])) div 2)"/></xsl:attribute>
      </my:rs>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineRegionStats" select="exsl:node-set($lineRegionStatsRTF)/my:rs"/>

  <!-- Stufe 3: entzerrtes y' je Zeile -->
  <xsl:variable name="lineYpRTF">
    <xsl:for-each select="$lineGeo">
      <xsl:variable name="st" select="$lineRegionStats[@region=current()/@region]"/>
      <xsl:variable name="hd" select="$lineGeo[@id=current()/@head]"/>
      <my:la>
        <xsl:copy-of select="@*"/>
        <xsl:attribute name="xmh"><xsl:value-of select="$hd/@xm"/></xsl:attribute>
        <xsl:attribute name="yp"><xsl:value-of select="number($hd/@ym) - number($st/@m) * number($hd/@xm)"/></xsl:attribute>
        <xsl:attribute name="tol"><xsl:value-of select="$st/@tol"/></xsl:attribute>
      </my:la>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineYp" select="exsl:node-set($lineYpRTF)/my:la"/>

  <!-- Stufe 4: @rank = Zahl der Zeilen derselben Region, die vor dieser stehen -->
  <xsl:variable name="lineAssignRTF">
    <xsl:for-each select="$lineAssignRaw[not(@region = $mixedRegions/@id)]">
      <my:la rank="0">
        <xsl:copy-of select="@id|@region|@parent|@pindex|@oindex"/>
      </my:la>
    </xsl:for-each>
    <xsl:for-each select="$lineYp[not(@region = preceding-sibling::*/@region)]">
     <xsl:variable name="rg" select="@region"/>
     <xsl:variable name="regionLines" select="$lineYp[@region=$rg]"/>
     <xsl:for-each select="$regionLines">
      <xsl:variable name="myId" select="@id"/>
      <xsl:variable name="lp" select="string(@parent)"/>
      <xsl:variable name="lpi" select="number(@pindex)"/>
      <xsl:variable name="lo" select="number(@oindex)"/>
      <xsl:variable name="ly" select="number(@yp)"/>
      <xsl:variable name="lx" select="number(@xmh)"/>
      <xsl:variable name="lt" select="number(@tol)"/>
      <my:la>
        <xsl:copy-of select="@id|@region|@parent|@pindex|@oindex"/>
        <xsl:attribute name="rank"><xsl:value-of select="count($regionLines[@id != $myId and (
            (@parent = $lp and number(@oindex) &lt; $lo)
            or (@parent != $lp and (
                 number(@yp) &lt; $ly - $lt
                 or (number(@yp) &lt;= $ly + $lt and number(@yp) &gt;= $ly - $lt and (
                      number(@xmh) &lt; $lx
                      or (number(@xmh) = $lx and (number(@pindex) &lt; $lpi or (number(@pindex) = $lpi and number(@oindex) &lt; $lo)))
                    ))
               ))
          )])"/></xsl:attribute>
      </my:la>
     </xsl:for-each>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineAssign" select="exsl:node-set($lineAssignRTF)/my:la"/>

  <xsl:variable name="surfaceRegions" select="$regions[@type='surface']"/>

  <xsl:variable name="baseId">
    <xsl:choose>
      <!-- Abschnitt 2: 1. Region mit structure{cat:base;}, 2. sonst die einzige
           surface-Region, 3. sonst eine synthetische Basis-Surface -->
      <xsl:when test="$surfaceRegions[@cat='base']">
        <xsl:call-template name="pick-extreme-id">
          <xsl:with-param name="nodes" select="$surfaceRegions[@cat='base']"/>
          <xsl:with-param name="order" select="'descending'"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:when test="count($surfaceRegions) = 1">
        <xsl:value-of select="$surfaceRegions[1]/@id"/>
      </xsl:when>
      <xsl:otherwise>SYNTHETIC_BASE</xsl:otherwise>
    </xsl:choose>
  </xsl:variable>

  <!-- Relation "has-parent" (Abschnitt 6): ueberschreibt die geometrische
       Eltern-Zuordnung - die ERSTE RegionRef ist das Kind, die ZWEITE die
       Elternregion (child > has-parent > parent), in body UND facsimile. -->
  <xsl:variable name="hasParentRTF">
    <xsl:for-each select="$page//*[local-name()='Relation']">
      <xsl:variable name="relNameRaw" select="substring-before(substring-after(@custom,'relationName {value:'),';')"/>
      <xsl:if test="translate($relNameRaw,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='has-parent'">
        <xsl:variable name="childRef" select="string(*[local-name()='RegionRef'][1]/@regionRef)"/>
        <xsl:variable name="parentRef" select="string(*[local-name()='RegionRef'][2]/@regionRef)"/>
        <xsl:if test="$childRef != '' and $parentRef != '' and $childRef != $parentRef">
          <my:hp child="{$childRef}" parent="{$parentRef}"/>
        </xsl:if>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="hasParent" select="exsl:node-set($hasParentRTF)/my:hp"/>

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

  <!-- ===== column-block (Abschnitt 5/6) =====
       Ein column-block wird im Text NICHT zu einem <div>, sondern zu einem
       leeren <cb n=".."/> VOR seinen Inhalten; die darin genesteten Regionen
       stehen daneben (eine Ebene hoeher). Die Geometrie (facsimile) bleibt
       unveraendert. $effParents ist die dafuer "abgeflachte" Eltern-Tabelle
       (Eltern = naechste Vorfahrenregion, die kein column-block ist, bis zu
       drei verschachtelte Bloecke); @via = der aeusserste uebersprungene
       column-block, @key = Sortierschluessel im Text.
       Relation "block-order": die Reihenfolge der aufgelisteten column-blocks
       (und damit ihrer Inhalte) - der k-te genannte Block nimmt den Platz
       (readingOrder-Index) des k-ten der aufgelisteten Bloecke ein. -->
  <xsl:variable name="blockOrderAllRTF">
    <xsl:for-each select="$page//*[local-name()='Relation']">
      <xsl:variable name="relNameRaw" select="substring-before(substring-after(@custom,'relationName {value:'),';')"/>
      <xsl:if test="translate($relNameRaw,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='block-order'">
        <xsl:variable name="boGid" select="generate-id(.)"/>
        <xsl:for-each select="*[local-name()='RegionRef']">
          <my:bo group="{$boGid}" region="{@regionRef}" pos="{position()}"/>
        </xsl:for-each>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="blockOrderAll" select="exsl:node-set($blockOrderAllRTF)/my:bo[not(@region = preceding-sibling::my:bo/@region)]"/>
  <xsl:variable name="blockSlotsRTF">
    <xsl:for-each select="$regions[@type='column-block']">
      <xsl:variable name="bsId" select="@id"/>
      <xsl:variable name="bsBo" select="$blockOrderAll[@region=$bsId]"/>
      <my:slot region="{$bsId}">
        <xsl:attribute name="slot">
          <xsl:choose>
            <xsl:when test="$bsBo">
              <xsl:variable name="bsK" select="number($bsBo[1]/@pos)"/>
              <xsl:variable name="bsG" select="$bsBo[1]/@group"/>
              <xsl:for-each select="$blockOrderAll[@group=$bsG]">
                <xsl:sort select="$regions[@id=current()/@region]/@index" data-type="number"/>
                <xsl:if test="position() = count($blockOrderAll[@group=$bsG and number(@pos) &lt; $bsK]) + 1"><xsl:value-of select="$regions[@id=current()/@region]/@index"/></xsl:if>
              </xsl:for-each>
            </xsl:when>
            <xsl:otherwise><xsl:value-of select="@index"/></xsl:otherwise>
          </xsl:choose>
        </xsl:attribute>
      </my:slot>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="blockSlots" select="exsl:node-set($blockSlotsRTF)/my:slot"/>

  <xsl:variable name="effParentsRTF">
    <xsl:for-each select="$regions">
      <xsl:variable name="epRid" select="string(@id)"/>
      <xsl:variable name="epP1" select="string($parents[@id=$epRid]/@of)"/>
      <xsl:variable name="epB1" select="boolean($regions[@id=$epP1 and @type='column-block'])"/>
      <xsl:variable name="epP2" select="string($parents[@id=$epP1]/@of)"/>
      <xsl:variable name="epB2" select="$epB1 and boolean($regions[@id=$epP2 and @type='column-block'])"/>
      <xsl:variable name="epP3" select="string($parents[@id=$epP2]/@of)"/>
      <xsl:variable name="epB3" select="$epB2 and boolean($regions[@id=$epP3 and @type='column-block'])"/>
      <xsl:variable name="epP4" select="string($parents[@id=$epP3]/@of)"/>
      <xsl:variable name="epOf">
        <xsl:choose>
          <xsl:when test="not($epB1)"><xsl:value-of select="$epP1"/></xsl:when>
          <xsl:when test="not($epB2)"><xsl:value-of select="$epP2"/></xsl:when>
          <xsl:when test="not($epB3)"><xsl:value-of select="$epP3"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="$epP4"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:variable name="epVia">
        <xsl:choose>
          <xsl:when test="not($epB1)"/>
          <xsl:when test="not($epB2)"><xsl:value-of select="$epP1"/></xsl:when>
          <xsl:when test="not($epB3)"><xsl:value-of select="$epP2"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="$epP3"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:variable name="epViaSlot" select="number($blockSlots[@region=string($epVia)]/@slot)"/>
      <my:ep id="{$epRid}" of="{$epOf}" via="{$epVia}">
        <xsl:attribute name="key">
          <xsl:choose>
            <xsl:when test="$epVia != ''"><xsl:value-of select="$epViaSlot + number(@index) div 1000000"/></xsl:when>
            <xsl:when test="@type='column-block'"><xsl:value-of select="$blockSlots[@region=$epRid]/@slot"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="@index"/></xsl:otherwise>
          </xsl:choose>
        </xsl:attribute>
      </my:ep>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="effParents" select="exsl:node-set($effParentsRTF)/my:ep"/>

  <!-- Relation "paragraph" (Abschnitt 6): verbindet Regionen vom Typ
       paragraph / paragraph-* / long-quote-* / metamark, die gemeinsam in EIN
       <p> gepackt werden (in der Reihenfolge der Relation). Eine Region wird
       nur Mitglied der ERSTEN Relation, in der sie vorkommt. -->
  <xsl:variable name="pgAllRTF">
    <xsl:for-each select="$page//*[local-name()='Relation']">
      <xsl:variable name="relNameRaw" select="substring-before(substring-after(@custom,'relationName {value:'),';')"/>
      <xsl:if test="translate($relNameRaw,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='paragraph'">
        <xsl:variable name="gid" select="generate-id(.)"/>
        <xsl:for-each select="*[local-name()='RegionRef']">
          <xsl:variable name="rid" select="@regionRef"/>
          <xsl:variable name="rtype" select="string($regions[@id=$rid]/@type)"/>
          <xsl:if test="starts-with($rtype,'paragraph') or starts-with($rtype,'long-quote') or $rtype='metamark' or $rtype='annotation'">
            <my:pg group="{$gid}" region="{$rid}" pos="{position()}" type="{$rtype}"/>
          </xsl:if>
        </xsl:for-each>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="pgMembers" select="exsl:node-set($pgAllRTF)/my:pg[not(@region = preceding-sibling::my:pg/@region)]"/>

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
            <xsl:if test="starts-with($ttype,'paragraph') or $ttype='head' or $ttype='gap' or $ttype='byline' or $ttype='dateline' or starts-with($ttype,'long-quote')">
              <my:relmember region="{$rid}" group="{$gid}" type="{$relNameLower}" pos="{position()}"/>
            </xsl:if>
          </xsl:if>
        </xsl:for-each>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <!-- Eine Region kann in mehreren Relationen vorkommen (z.B. r_21 in zwei
       article-Relationen). Sie wird nur zum Mitglied der ERSTEN - sonst
       fehlte in der zweiten Gruppe ihr Anker, und die uebrigen Mitglieder
       (z.B. ein gap) wuerden nirgends gerendert. -->
  <xsl:variable name="relMembers" select="exsl:node-set($relMembersRTF)/my:relmember[not(@region = preceding-sibling::my:relmember/@region)]"/>

  <!-- Abschnitt 6, Achtung: spannt eine article/montage-element-Relation ueber
       Hierarchiegrenzen (ihre Mitglieder haben verschiedene Elternregionen,
       z.B. mehrere column-blocks), entsteht pro Elternregion ein eigenes
       <div type="article">. Diese Teil-<div>s bekommen eine xml:id
       (div-PPPP-NNNN) sowie @prev/@next, die aufeinander verweisen (in
       Lesereihenfolge, d.h. nach dem kleinsten readingOrder-Index der
       Mitglieder je Elternregion). Elternregionen, die selbst ein <p> sind
       (is-quote-host), rendern ihre Kinder inline ohne article-<div> und
       zaehlen deshalb nicht mit. Die Nummerierung setzt nach den schon
       vergebenen div-IDs (Regionen mit Behelfs-ID) fort. -->
  <xsl:variable name="fragRawRTF">
    <xsl:for-each select="$relMembers">
      <xsl:variable name="par" select="string($effParents[@id=current()/@region]/@of)"/>
      <xsl:variable name="qh"><xsl:call-template name="is-quote-host"><xsl:with-param name="id" select="$par"/></xsl:call-template></xsl:variable>
      <xsl:if test="$qh != 'yes'">
        <my:fr group="{@group}" parent="{concat($par,'|',$effParents[@id=current()/@region]/@via)}" idx="{$effParents[@id=current()/@region]/@key}"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="fragRaw" select="exsl:node-set($fragRawRTF)/my:fr"/>
  <xsl:variable name="fragAllRTF">
    <xsl:for-each select="$fragRaw">
      <xsl:variable name="g" select="@group"/>
      <xsl:variable name="pp" select="@parent"/>
      <xsl:if test="not(preceding-sibling::my:fr[@group=$g and @parent=$pp])">
        <xsl:variable name="minIdx">
          <xsl:for-each select="$fragRaw[@group=$g and @parent=$pp]">
            <xsl:sort select="@idx" data-type="number"/>
            <xsl:if test="position()=1"><xsl:value-of select="@idx"/></xsl:if>
          </xsl:for-each>
        </xsl:variable>
        <my:fa group="{$g}" parent="{$pp}" minIdx="{$minIdx}"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="fragAll" select="exsl:node-set($fragAllRTF)/my:fa"/>
  <!-- nur Gruppen mit mindestens zwei Teil-<div>s -->
  <xsl:variable name="fragMultiRTF">
    <xsl:for-each select="$fragAll">
      <xsl:variable name="g" select="@group"/>
      <xsl:if test="count($fragAll[@group=$g]) &gt; 1"><xsl:copy-of select="."/></xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="fragRankedRTF">
    <xsl:for-each select="exsl:node-set($fragMultiRTF)/my:fa">
      <xsl:variable name="g" select="@group"/>
      <xsl:variable name="mi" select="number(@minIdx)"/>
      <xsl:variable name="fragSeq" select="position()"/>
      <my:fk group="{$g}" parent="{@parent}" seq="{$fragSeq}" rank="{count($fragAll[@group=$g and number(@minIdx) &lt; $mi]) + 1}">
        <xsl:attribute name="genid">
          <xsl:text>div-</xsl:text><xsl:value-of select="$pageNumPadded"/><xsl:text>-</xsl:text>
          <xsl:call-template name="pad4"><xsl:with-param name="s" select="count($behelfsOrder[@tag='div']) + $fragSeq"/></xsl:call-template>
        </xsl:attribute>
      </my:fk>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="fragRanked" select="exsl:node-set($fragRankedRTF)/my:fk"/>
  <xsl:variable name="articleFragmentsRTF">
    <xsl:for-each select="$fragRanked">
      <xsl:variable name="g" select="@group"/>
      <xsl:variable name="r" select="number(@rank)"/>
      <my:frag group="{$g}" parent="{@parent}" genid="{@genid}"
               prev="{$fragRanked[@group=$g and number(@rank)=$r - 1]/@genid}"
               next="{$fragRanked[@group=$g and number(@rank)=$r + 1]/@genid}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="articleFragments" select="exsl:node-set($articleFragmentsRTF)/my:frag"/>

  <!-- Relation "multi-p-quote" (Abschnitt 6): verbindet mehrere Regionen mit
       "long-quote" im Typ (long-quote-p/long-quote-lg); die werden nicht in
       je ein eigenes <quote>, sondern gemeinsam in EIN <quote> gepackt. -->
  <xsl:variable name="quoteMembersRTF">
    <xsl:for-each select="$page//*[local-name()='Relation']">
      <xsl:variable name="relNameRaw" select="substring-before(substring-after(@custom,'relationName {value:'),';')"/>
      <xsl:if test="translate($relNameRaw,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='multi-p-quote'">
        <xsl:variable name="gid" select="generate-id(.)"/>
        <xsl:for-each select="*[local-name()='RegionRef']">
          <xsl:variable name="rid" select="@regionRef"/>
          <xsl:if test="starts-with($regions[@id=$rid]/@type,'long-quote')">
            <my:qmember region="{$rid}" group="{$gid}"/>
          </xsl:if>
        </xsl:for-each>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="quoteMembers" select="exsl:node-set($quoteMembersRTF)/my:qmember"/>

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

  <!-- laufende Nummer jeder add-Region (Regionstyp "add") in globaler
       Lesereihenfolge, fuer die add-xml:id (siehe verarbeitungsregeln.md
       Abschnitt 8: JEDES <add> aus Regionstyp bekommt eine eigene xml:id,
       nicht nur die referenzierten) -->
  <xsl:variable name="addOrderRTF">
    <xsl:for-each select="$regions[@type='add']">
      <xsl:sort select="@index" data-type="number"/>
      <my:mm id="{@id}" seq="{position()}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="addOrder" select="exsl:node-set($addOrderRTF)/my:mm"/>

  <!-- ===================== Behelfs-IDs (Abschnitt 8) =====================
       Manche Regionen tragen in ihrem structure-Block ein "id:X" - eine
       Behelfs-ID, mit der andere Stellen (target/add-id/corresp) auf genau
       diese Region verweisen. Jede so referenzierte Region bekommt eine
       "echte" xml:id nach dem etablierten Muster (Elementname-Seitenzahl-
       laufende Nummer), und jede Referenz auf die Behelfs-ID wird durch
       diese echte ID ersetzt. Fuer metamark/add-Regionen wird dabei die
       ohnehin schon vergebene $metamarkOrder/$addOrder-ID verwendet (die
       bekommen IMMER eine ID, ob referenziert oder nicht); fuer alle
       anderen Regionstypen (z.B. paragraph) wird nur bei Bedarf (d.h. nur
       wenn eine Behelfs-ID vorhanden ist) eine ID nach demselben Muster neu
       vergeben, mit dem Elementnamen als Praefix (region-tei-tag). -->
  <xsl:variable name="behelfsOrderRTF">
    <xsl:for-each select="$regions[@behelfsId != '' and not(contains(@behelfsId,'.xml#')) and @type != 'add' and @type != 'annotation' and @type != 'metamark']">
      <xsl:sort select="@index" data-type="number"/>
      <xsl:variable name="tag">
        <xsl:call-template name="region-tei-tag"><xsl:with-param name="id" select="@id"/></xsl:call-template>
      </xsl:variable>
      <xsl:variable name="seq">
        <xsl:for-each select="$regions[@behelfsId != '' and not(contains(@behelfsId,'.xml#')) and @type != 'add' and @type != 'annotation' and @type != 'metamark']">
          <xsl:sort select="@index" data-type="number"/>
          <xsl:variable name="t2"><xsl:call-template name="region-tei-tag"><xsl:with-param name="id" select="@id"/></xsl:call-template></xsl:variable>
          <xsl:if test="$t2=$tag and number(@index) &lt;= number(current()/@index)">
            <my:x/>
          </xsl:if>
        </xsl:for-each>
      </xsl:variable>
      <my:mm id="{@id}" tag="{$tag}" seq="{count(exsl:node-set($seq)/my:x)}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="behelfsOrder" select="exsl:node-set($behelfsOrderRTF)/my:mm"/>

  <!-- Gesamt-Nachschlagetabelle Behelfs-ID -> echte generierte ID (ohne "#") -->
  <xsl:variable name="behelfsMapRTF">
    <xsl:for-each select="$regions[@behelfsId != '']">
      <xsl:variable name="r" select="."/>
      <xsl:variable name="genId">
        <xsl:choose>
          <!-- dokumentuebergreifende ID ("datei.xml#id", Abschnitt 8): keine
               Behelfs-ID, nichts generieren - nur der Teil nach "#" wird
               unveraendert als xml:id uebernommen. -->
          <xsl:when test="contains($r/@behelfsId,'.xml#')">
            <xsl:value-of select="substring-after($r/@behelfsId,'.xml#')"/>
          </xsl:when>
          <xsl:when test="$r/@type='annotation' or $r/@type='metamark'">
            <xsl:value-of select="concat('metamark-', $pageNumPadded, '-')"/>
            <xsl:call-template name="pad4"><xsl:with-param name="s" select="$metamarkOrder[@id=$r/@id]/@seq"/></xsl:call-template>
          </xsl:when>
          <xsl:when test="$r/@type='add'">
            <xsl:value-of select="concat('add-', $pageNumPadded, '-')"/>
            <xsl:call-template name="pad4"><xsl:with-param name="s" select="$addOrder[@id=$r/@id]/@seq"/></xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <xsl:value-of select="concat($behelfsOrder[@id=$r/@id]/@tag, '-', $pageNumPadded, '-')"/>
            <xsl:call-template name="pad4"><xsl:with-param name="s" select="$behelfsOrder[@id=$r/@id]/@seq"/></xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <my:b2r behelfs="{$r/@behelfsId}" region="{$r/@id}" genid="{$genId}"/>
    </xsl:for-each>
  </xsl:variable>

  <!-- dasselbe Behelfs-ID-Prinzip, aber fuer IDs, die nicht auf einer
       Region deklariert sind, sondern per "del-id" direkt in einem
       subst-del-Zeilenblock (Abschnitt 7/8: "del kriegt del-id als xml:id"):
       laufende Nummer in Dokumentreihenfolge, Praefix "del". -->
  <xsl:variable name="lineDeclaredIdsRawRTF">
    <xsl:for-each select="$allLineRanges[@element='subst-del-synth' and my:attr[@name='del-id']]">
      <my:d behelfs="{my:attr[@name='del-id']/@value}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineDeclaredIdsMapRTF">
    <xsl:for-each select="exsl:node-set($lineDeclaredIdsRawRTF)/my:d">
      <xsl:variable name="seqPadded"><xsl:call-template name="pad4"><xsl:with-param name="s" select="count(preceding-sibling::my:d[not(contains(@behelfs,'.xml#'))]) + 1"/></xsl:call-template></xsl:variable>
      <my:b2r behelfs="{@behelfs}" region="">
        <xsl:attribute name="genid">
          <xsl:choose>
            <xsl:when test="contains(@behelfs,'.xml#')"><xsl:value-of select="substring-after(@behelfs,'.xml#')"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="concat('del-', $pageNumPadded, '-', $seqPadded)"/></xsl:otherwise>
          </xsl:choose>
        </xsl:attribute>
      </my:b2r>
    </xsl:for-each>
  </xsl:variable>

  <!-- dasselbe fuer "id" auf JEDEM anderen Zeilen-Block (add, del, mod/
       mod-underline, seg, hi, unclear, metamark; Abschnitt 7/8): Praefix ist
       der erzeugte Elementname, laufende Nummer pro Praefix in
       Dokumentreihenfolge. Der Zaehler setzt bewusst NACH den schon
       anderweitig vergebenen Nummern desselben Praefixes fort (add: nach
       den add-REGIONEN, metamark: nach den metamark-Regionen, del: nach den
       del-id-Eintraegen von subst-del), damit nie dieselbe ID zweimal
       vergeben wird. -->
  <xsl:variable name="lineAddIdsRawRTF">
    <xsl:for-each select="$allLineRanges[my:attr[@name='id'] or (@element='subst-del-synth' and my:attr[@name='subst-id'])]">
      <!-- subst-del: die Deklaration steht in subst-id (-> <subst>, Praefix "subst") -->
      <xsl:variable name="lnIdVal">
        <xsl:choose>
          <xsl:when test="@element='subst-del-synth'"><xsl:value-of select="my:attr[@name='subst-id']/@value"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="my:attr[@name='id']/@value"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <!-- metamark-add: traegt id denselben Wert wie die add-Region, auf die
           add-id zeigt (so in den Daten), ist das KEINE eigene Deklaration -
           sonst gaebe es zwei Elemente mit derselben xml:id -->
      <xsl:if test="not(@element='metamark-add-synth' and $regions[@behelfsId=$lnIdVal])">
        <my:d behelfs="{$lnIdVal}">
          <xsl:attribute name="tag">
            <xsl:choose>
              <xsl:when test="@element='metamark-add-synth'">metamark</xsl:when>
              <xsl:when test="@element='subst-del-synth'">subst</xsl:when>
              <xsl:otherwise><xsl:value-of select="@element"/></xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
        </my:d>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineAddIdsMapRTF">
    <xsl:for-each select="exsl:node-set($lineAddIdsRawRTF)/my:d">
      <xsl:variable name="tag" select="@tag"/>
      <xsl:variable name="base">
        <xsl:choose>
          <xsl:when test="$tag='add'"><xsl:value-of select="count($addOrder)"/></xsl:when>
          <xsl:when test="$tag='metamark'"><xsl:value-of select="count($metamarkOrder)"/></xsl:when>
          <xsl:when test="$tag='del'"><xsl:value-of select="count(exsl:node-set($lineDeclaredIdsRawRTF)/my:d[not(contains(@behelfs,'.xml#'))])"/></xsl:when>
          <xsl:otherwise>0</xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:variable name="seqPadded"><xsl:call-template name="pad4"><xsl:with-param name="s" select="$base + count(preceding-sibling::my:d[@tag=$tag and not(contains(@behelfs,'.xml#'))]) + 1"/></xsl:call-template></xsl:variable>
      <my:b2r behelfs="{@behelfs}" region="">
        <xsl:attribute name="genid">
          <xsl:choose>
            <xsl:when test="contains(@behelfs,'.xml#')"><xsl:value-of select="substring-after(@behelfs,'.xml#')"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="concat($tag, '-', $pageNumPadded, '-', $seqPadded)"/></xsl:otherwise>
          </xsl:choose>
        </xsl:attribute>
      </my:b2r>
    </xsl:for-each>
  </xsl:variable>

  <xsl:variable name="behelfsMap" select="exsl:node-set($behelfsMapRTF)/my:b2r | exsl:node-set($lineDeclaredIdsMapRTF)/my:b2r | exsl:node-set($lineAddIdsMapRTF)/my:b2r"/>

  <!-- ===================== metamark-Insertion-Ketten (Abschnitt 7) =====================
       Eine metamark mit function="insertion" UND @target "zieht" das per
       Behelfs-ID referenzierte Element an ihre eigene Stelle (wie
       metamark-add). Dabei kann die Kette ueber eine ZWEITE metamark mit
       function="insertion" laufen, die selbst wieder ein @target hat - das
       add muss dann an der Stelle der ERSTEN, nicht der mittleren metamark
       eingefuegt werden (siehe resolve-insertion-chain). Eine metamark-
       Region, die selbst als Zwischenglied einer solchen Kette dient (d.h.
       Ziel einer ANDEREN insertion-metamark ist), $chainConsumedMetamarks,
       rendert deshalb bei sich selbst NICHT das importierte add, sondern
       ganz normal (eigener Text, @function/@target als Attribute). -->
  <xsl:variable name="chainConsumedRTF">
    <xsl:for-each select="$regions[@type='metamark' and @function='insertion' and @target != '']">
      <xsl:variable name="firstTarget"><xsl:call-template name="first-behelfs-token"><xsl:with-param name="s" select="@target"/></xsl:call-template></xsl:variable>
      <xsl:variable name="targetRegionId" select="$behelfsMap[@behelfs=$firstTarget][1]/@region"/>
      <xsl:if test="$regions[@id=$targetRegionId]/@type='metamark'">
        <my:c id="{$targetRegionId}"/>
      </xsl:if>
    </xsl:for-each>
    <xsl:for-each select="$allLineRanges[@element='metamark' and my:attr[@name='function']/@value='insertion' and my:attr[@name='target']]">
      <xsl:variable name="firstTarget"><xsl:call-template name="first-behelfs-token"><xsl:with-param name="s" select="my:attr[@name='target']/@value"/></xsl:call-template></xsl:variable>
      <xsl:variable name="targetRegionId" select="$behelfsMap[@behelfs=$firstTarget][1]/@region"/>
      <xsl:if test="$regions[@id=$targetRegionId]/@type='metamark'">
        <my:c id="{$targetRegionId}"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="chainConsumedMetamarks" select="exsl:node-set($chainConsumedRTF)/my:c"/>

  <!-- Aufloesung JEDER Kette EINMAL zentral (statt an mehreren Stellen
       unabhaengig resolve-insertion-chain aufzurufen): libxslt/xsltproc hat
       ein Problem ("Redefinition of variable"), wenn dasselbe rekursive
       Template aus mehreren VERSCHIEDENEN globalen RTF-Variablen heraus
       aufgerufen wird - alle anderen Stellen (render-metamark,
       render-one-range, consumedAddRegions, addImportSites) lesen daher nur
       noch aus dieser einen Tabelle. -->
  <xsl:variable name="insertionChainResolutionsRTF">
    <xsl:for-each select="$regions[@type='metamark' and @function='insertion' and @target != '' and not($chainConsumedMetamarks[@id=current()/@id])]">
      <xsl:variable name="chainTarget"><xsl:call-template name="resolve-insertion-chain"><xsl:with-param name="behelfsId" select="@target"/></xsl:call-template></xsl:variable>
      <my:res kind="region" id="{@id}" target="{$chainTarget}"/>
    </xsl:for-each>
    <xsl:for-each select="$allLineRanges[@element='metamark' and my:attr[@name='function']/@value='insertion' and my:attr[@name='target']]">
      <xsl:variable name="chainTarget"><xsl:call-template name="resolve-insertion-chain"><xsl:with-param name="behelfsId" select="my:attr[@name='target']/@value"/></xsl:call-template></xsl:variable>
      <my:res kind="line" id="{@line}" offset="{@offset}" target="{$chainTarget}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="insertionChainResolutions" select="exsl:node-set($insertionChainResolutionsRTF)/my:res"/>

  <!-- undo (Abschnitt 7/8): ein undo mit continued:true setzt sich auf der
       naechsten Zeile (der Region, in der Ausgabereihenfolge) bei offset:0
       mit einem weiteren undo-Block fort. Solche Stuecke bilden EINEN
       Bereich: nur EIN <undo spanTo> am Anfang des ersten und nur EIN
       <anchor> am Ende des letzten Stuecks. Die anchor-Nummer (Seitenzahl-
       Nummer-ID wie in Abschnitt 8, "id" wird komplett neu erzeugt) zaehlt
       je Bereich (nicht je Stueck) in Dokumentreihenfolge. -->

  <!-- Zeilenfolge je Region in Ausgabereihenfolge (wie ordered-lines-for-region):
       my:rg/my:l, zum Nachschlagen der Folgezeile -->
  <xsl:variable name="lineSeqRTF">
    <xsl:for-each select="$lineAssign[not(@region = preceding-sibling::*/@region)]">
      <xsl:variable name="uqRg" select="@region"/>
      <my:rg id="{$uqRg}">
        <xsl:for-each select="$lineAssign[@region=$uqRg]">
          <xsl:sort select="number(@rank)" data-type="number"/>
          <xsl:sort select="number(@pindex)" data-type="number"/>
          <xsl:sort select="number(@oindex)" data-type="number"/>
          <my:l id="{@id}"/>
        </xsl:for-each>
      </my:rg>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="lineSeq" select="exsl:node-set($lineSeqRTF)/my:rg/my:l"/>

  <!-- Fortsetzungskanten: undo-Stueck (Zeile, offset) mit continued:true ->
       undo-Stueck bei offset:0 auf der Folgezeile -->
  <xsl:variable name="undoEdgesRTF">
    <xsl:for-each select="$allLineRanges[@element='undo' and @continued='true']">
      <xsl:variable name="uqNext" select="string($lineSeq[@id=current()/@line][1]/following-sibling::my:l[1]/@id)"/>
      <xsl:if test="$uqNext != '' and $allLineRanges[@element='undo' and @line=$uqNext and number(@offset)=0]">
        <my:e fl="{@line}" fo="{@offset}" tl="{$uqNext}"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="undoEdges" select="exsl:node-set($undoEdgesRTF)/my:e"/>

  <!-- Bereichsanfaenge (kein Stueck ist Fortsetzung eines anderen), numeriert -->
  <xsl:variable name="undoHeadsRawRTF">
    <xsl:for-each select="$allLineRanges[@element='undo']">
      <xsl:if test="not($undoEdges[@tl=current()/@line and number(current()/@offset)=0])">
        <my:u line="{@line}" offset="{@offset}"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="undoOrderRTF">
    <xsl:for-each select="exsl:node-set($undoHeadsRawRTF)/my:u">
      <my:u line="{@line}" offset="{@offset}" seq="{position()}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="undoOrder" select="exsl:node-set($undoOrderRTF)/my:u"/>

  <!-- jedes Stueck mit Bereichsnummer und Rolle: single | start | mid | end -->
  <xsl:variable name="undoPiecesRTF">
    <xsl:for-each select="$undoOrder">
      <xsl:call-template name="undo-chain-walk">
        <xsl:with-param name="line" select="string(@line)"/>
        <xsl:with-param name="offset" select="string(@offset)"/>
        <xsl:with-param name="seq" select="string(@seq)"/>
      </xsl:call-template>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="undoPieces" select="exsl:node-set($undoPiecesRTF)/my:up"/>

  <xsl:template name="undo-chain-walk">
    <xsl:param name="line"/>
    <xsl:param name="offset"/>
    <xsl:param name="seq"/>
    <xsl:param name="first" select="true()"/>
    <xsl:param name="depth" select="1"/>
    <xsl:variable name="uqNextEdge" select="$undoEdges[@fl=$line and number(@fo)=number($offset)][1]"/>
    <xsl:variable name="uqHasNext" select="boolean($uqNextEdge) and $depth &lt; 100"/>
    <my:up line="{$line}" offset="{$offset}" seq="{$seq}">
      <xsl:attribute name="role">
        <xsl:choose>
          <xsl:when test="$first and not($uqHasNext)">single</xsl:when>
          <xsl:when test="$first">start</xsl:when>
          <xsl:when test="$uqHasNext">mid</xsl:when>
          <xsl:otherwise>end</xsl:otherwise>
        </xsl:choose>
      </xsl:attribute>
    </my:up>
    <xsl:if test="$uqHasNext">
      <xsl:call-template name="undo-chain-walk">
        <xsl:with-param name="line" select="string($uqNextEdge/@tl)"/>
        <xsl:with-param name="offset" select="'0'"/>
        <xsl:with-param name="seq" select="$seq"/>
        <xsl:with-param name="first" select="false()"/>
        <xsl:with-param name="depth" select="$depth + 1"/>
      </xsl:call-template>
    </xsl:if>
  </xsl:template>

  <!-- ===================== del/deselection-Ketten: delSpan + anchor =====================
       Mehrere aufeinanderfolgende deselection- bzw. del-Bloecke haengen ueber
       "id" und "next" zusammen: next nennt die id des FOLGENDEN Blocks, der
       letzte hat kein next. Eine Kette (mindestens zwei ids) wird NICHT als
       <del> gerendert, sondern als GENAU EIN leeres <delSpan type=".."
       spanTo="#anchor"/> am Anfang des Textes des ersten Blocks und EIN
       leeres <anchor/> am Ende des Textes des letzten Blocks - alles
       dazwischen (auch ueber Zeilen, Regionsgrenzen und andere Annotationen
       hinweg) bleibt unveraendert stehen. Eine id kann auf mehreren
       Zeilenstuecken stehen (continued:true) - das ist EIN Kettenglied.
       Der type kommt bei deselection aus "deselection", bei del aus cat. -->

  <!-- Kettenanfaenge: ids mit next, die von keinem anderen del-Bereich als next
       genannt werden (nur die erste Stelle je id) -->
  <xsl:variable name="delChainHeadsRTF">
    <xsl:for-each select="$allLineRanges[@element='del' and my:attr[@name='id'] and my:attr[@name='next']]">
      <xsl:variable name="dcHeadId" select="string(my:attr[@name='id']/@value)"/>
      <xsl:if test="generate-id(.) = generate-id($allLineRanges[@element='del' and my:attr[@name='id']/@value=$dcHeadId][1])
                    and not($allLineRanges[@element='del' and my:attr[@name='next']/@value=$dcHeadId])">
        <my:head id="{$dcHeadId}"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <!-- jede Kette einmal abschreiten (dieser eine Aufruf ist der einzige) -->
  <xsl:variable name="delChainIdsRTF">
    <xsl:for-each select="exsl:node-set($delChainHeadsRTF)/my:head">
      <xsl:call-template name="del-chain-walk">
        <xsl:with-param name="id" select="string(@id)"/>
        <xsl:with-param name="chainNo" select="position()"/>
      </xsl:call-template>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="delChainIds" select="exsl:node-set($delChainIdsRTF)/my:cm"/>

  <!-- alle Zeilenstuecke von Kettengliedern, in Dokumentreihenfolge, mit Rolle
       start (erstes Stueck des ersten Glieds) / end (letztes Stueck des
       letzten Glieds) / mid; nur Ketten mit mindestens zwei Gliedern -->
  <xsl:variable name="deselMarkersRTF">
    <xsl:for-each select="$allLineRanges[@element='del' and my:attr[@name='id']]">
      <xsl:variable name="dcPieceId" select="string(my:attr[@name='id']/@value)"/>
      <xsl:variable name="dcMember" select="$delChainIds[@id=$dcPieceId][1]"/>
      <xsl:if test="$dcMember and count($delChainIds[@chain=$dcMember/@chain]) &gt; 1">
        <xsl:variable name="dcFirstPiece" select="generate-id(.) = generate-id($allLineRanges[@element='del' and my:attr[@name='id']/@value=$dcPieceId][1])"/>
        <xsl:variable name="dcLastPiece" select="generate-id(.) = generate-id($allLineRanges[@element='del' and my:attr[@name='id']/@value=$dcPieceId][last()])"/>
        <my:marker pairSeq="{$dcMember/@chain}" line="{@line}" offset="{@offset}">
          <xsl:attribute name="role">
            <xsl:choose>
              <xsl:when test="$dcMember/@first='y' and $dcFirstPiece">start</xsl:when>
              <xsl:when test="$dcMember/@last='y' and $dcLastPiece">end</xsl:when>
              <xsl:otherwise>mid</xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
        </my:marker>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="deselMarkers" select="exsl:node-set($deselMarkersRTF)/my:marker"/>

  <!-- xml:id des <anchor> je Kette nach dem ID-Schema (Abschnitt 8):
       anchor-PPPP-NNNN, Nummer nach den undo-Ankern fortgesetzt -->
  <xsl:variable name="deselPairIdsRTF">
    <xsl:for-each select="$deselMarkers[@role='end']">
      <xsl:variable name="pidStart" select="$deselMarkers[@role='start' and @pairSeq=current()/@pairSeq][1]"/>
      <my:pid seq="{@pairSeq}" line="{@line}" offset="{@offset}">
        <!-- type des delSpan (= type des ersten Kettenglieds) fuer den <anchor> -->
        <xsl:attribute name="type"><xsl:value-of select="$allLineRanges[@element='del' and @line=$pidStart/@line and number(@offset)=number($pidStart/@offset)][1]/my:attr[@name='type']/@value"/></xsl:attribute>
        <xsl:attribute name="id">
          <xsl:text>anchor-</xsl:text><xsl:value-of select="$pageNumPadded"/><xsl:text>-</xsl:text>
          <xsl:call-template name="pad4"><xsl:with-param name="s" select="count($undoOrder) + number(@pairSeq)"/></xsl:call-template>
        </xsl:attribute>
      </my:pid>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="deselPairIds" select="exsl:node-set($deselPairIdsRTF)/my:pid"/>

  <!-- add-Regionen, deren Inhalt per add-id (subst-del/metamark-add, Abschnitt
       7) an anderer Stelle inline importiert wird (render-imported-add),
       werden an ihrer eigenen, geometrischen Baumposition NICHT nochmal
       gerendert - sonst gaebe es den Text doppelt UND doppelte xml:ids. Ihre
       facsimile-Zone bleibt trotzdem bestehen (render-imported-add verweist
       ja per @facs darauf). -->
  <xsl:variable name="consumedAddRegionsRTF">
    <!-- add-id traegt gelegentlich mehrere  -getrennte Werte (siehe
         render-one-range) - jede referenzierte Region wird hier einzeln
         als "konsumiert" vermerkt. -->
    <xsl:for-each select="$allLineRanges[(@element='subst-del-synth' or @element='metamark-add-synth' or @element='subst') and my:attr[@name='add-id']]">
      <xsl:variable name="tokensRTF">
        <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="my:attr[@name='add-id']/@value"/></xsl:call-template>
      </xsl:variable>
      <xsl:for-each select="exsl:node-set($tokensRTF)/my:tok">
        <xsl:variable name="regionId" select="$behelfsMap[@behelfs=current()/@val][1]/@region"/>
        <xsl:if test="$regionId != '' and $regions[@id=$regionId]/@type != 'add-block'"><my:c id="{$regionId}"/></xsl:if>
        <!-- add-id kann auch auf einen ZEILEN-add verweisen (add {id:..} in einer
             TextLine, keine Region): dann wird dessen Zeichenbereich an der
             Importstelle ausgegeben und an seiner eigenen Stelle unterdrueckt -->
        <xsl:variable name="srcLineAdd" select="$allLineRanges[@element='add' and my:attr[@name='id']/@value=current()/@val][1]"/>
        <xsl:if test="$regionId = '' and $srcLineAdd"><my:cl line="{$srcLineAdd/@line}" offset="{$srcLineAdd/@offset}"/></xsl:if>
      </xsl:for-each>
    </xsl:for-each>
    <!-- Zeilen-metamark mit function="addition" (auch "add") und target auf ein
         add (add-Region oder Zeilen-add mit dieser id): das add wird an der
         Stelle der metamark eingefuegt und an seiner eigenen Stelle unterdrueckt
         (siehe mm-add-targets) -->
    <xsl:for-each select="$allLineRanges[@element='metamark' and (my:attr[@name='function']/@value='addition' or my:attr[@name='function']/@value='add') and my:attr[@name='target']]">
      <xsl:variable name="mmTokRTF">
        <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="my:attr[@name='target']/@value"/></xsl:call-template>
      </xsl:variable>
      <xsl:for-each select="exsl:node-set($mmTokRTF)/my:tok">
        <xsl:variable name="mmReg" select="$behelfsMap[@behelfs=current()/@val][1]/@region"/>
        <xsl:variable name="mmLineAdd" select="$allLineRanges[@element='add' and my:attr[@name='id']/@value=current()/@val][1]"/>
        <xsl:choose>
          <xsl:when test="$regions[@id=$mmReg]/@type='add'"><my:c id="{$mmReg}"/></xsl:when>
          <xsl:when test="$mmReg = '' and $mmLineAdd"><my:cl line="{$mmLineAdd/@line}" offset="{$mmLineAdd/@offset}"/></xsl:when>
        </xsl:choose>
      </xsl:for-each>
    </xsl:for-each>
    <!-- metamark mit function="insertion" (Zeilenebene) - dieselbe
         Unterdrueckung wie oben; die Kette selbst ist schon zentral in
         $insertionChainResolutions aufgeloest (s.o., wichtig fuer
         xsltproc-Stabilitaet). -->
    <xsl:for-each select="$allLineRanges[@element='metamark' and my:attr[@name='function']/@value='insertion' and my:attr[@name='target']]">
      <xsl:variable name="chainTarget" select="$insertionChainResolutions[@kind='line' and @id=current()/@line and @offset=current()/@offset]/@target"/>
      <xsl:if test="$regions[@id=$chainTarget]/@type='add'"><my:c id="{$chainTarget}"/></xsl:if>
    </xsl:for-each>
    <!-- dasselbe fuer metamark-insertion-Regionen (Abschnitt 7): das Ziel
         der Kette wird an der Stelle der Region selbst eingefuegt und darf
         daher nicht zusaetzlich an seiner eigenen Baumposition erscheinen. -->
    <xsl:for-each select="$insertionChainResolutions[@kind='region']">
      <xsl:variable name="chainTarget" select="@target"/>
      <xsl:if test="$regions[@id=$chainTarget]/@type='add'"><my:c id="{$chainTarget}"/></xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="consumedAddRegions" select="exsl:node-set($consumedAddRegionsRTF)/my:c"/>
  <xsl:variable name="consumedLineAdds" select="exsl:node-set($consumedAddRegionsRTF)/my:cl"/>

  <!-- Dieselbe add-Region kann (siehe Testdaten) von MEHREREN Stellen aus
       importiert werden (subst-del, metamark-add, metamark-insertion-Kette
       koennen alle auf dieselbe Behelfs-ID zeigen). Jeder Import bekommt
       denselben @facs/Inhalt, aber xml:id darf nur EINMAL im Dokument
       vorkommen - deshalb bekommt nur der ERSTE Import (in Dokument-
       reihenfolge ueber alle Zeilen) die echte xml:id, alle weiteren
       Importe derselben Region bleiben ohne xml:id. -->
  <xsl:variable name="addImportSitesRTF">
    <!-- add-id traegt gelegentlich mehrere  -getrennte Werte - jeder
         importierte Import-Standort wird einzeln erfasst, damit jede
         Region ihre eigene Erstimport-Erkennung bekommt. -->
    <xsl:for-each select="$allLineRanges[(@element='subst-del-synth' or @element='metamark-add-synth' or (@element='subst' and my:attr[@name='add-id']))]">
      <xsl:variable name="lnLine" select="@line"/>
      <xsl:variable name="tokensRTF">
        <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="my:attr[@name='add-id']/@value"/></xsl:call-template>
      </xsl:variable>
      <xsl:for-each select="exsl:node-set($tokensRTF)/my:tok">
        <xsl:variable name="regionId" select="$behelfsMap[@behelfs=current()/@val][1]/@region"/>
        <xsl:if test="$regionId != '' and $regions[@id=$regionId]/@type != 'add-block'"><my:site region="{$regionId}" line="{$lnLine}"/></xsl:if>
      </xsl:for-each>
    </xsl:for-each>
    <xsl:for-each select="$allLineRanges[@element='metamark' and (my:attr[@name='function']/@value='addition' or my:attr[@name='function']/@value='add') and my:attr[@name='target']]">
      <xsl:variable name="mmLnLine" select="@line"/>
      <xsl:variable name="mmTokRTF">
        <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="my:attr[@name='target']/@value"/></xsl:call-template>
      </xsl:variable>
      <xsl:for-each select="exsl:node-set($mmTokRTF)/my:tok">
        <xsl:variable name="mmReg" select="$behelfsMap[@behelfs=current()/@val][1]/@region"/>
        <xsl:if test="$regions[@id=$mmReg]/@type='add'"><my:site region="{$mmReg}" line="{$mmLnLine}"/></xsl:if>
      </xsl:for-each>
    </xsl:for-each>
    <xsl:for-each select="$allLineRanges[@element='metamark' and my:attr[@name='function']/@value='insertion' and my:attr[@name='target']]">
      <xsl:variable name="chainTarget" select="$insertionChainResolutions[@kind='line' and @id=current()/@line and @offset=current()/@offset]/@target"/>
      <xsl:if test="$regions[@id=$chainTarget]/@type='add'"><my:site region="{$chainTarget}" line="{@line}"/></xsl:if>
    </xsl:for-each>
    <xsl:for-each select="$insertionChainResolutions[@kind='region']">
      <xsl:variable name="chainTarget" select="@target"/>
      <xsl:if test="$regions[@id=$chainTarget]/@type='add'"><my:site region="{$chainTarget}" line=""/></xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="addImportSites" select="exsl:node-set($addImportSitesRTF)/my:site"/>
  <xsl:variable name="canonicalAddImportRTF">
    <xsl:for-each select="$addImportSites">
      <xsl:variable name="pos" select="position()"/>
      <xsl:variable name="r" select="@region"/>
      <xsl:if test="count($addImportSites[@region=$r and position() &lt; $pos]) = 0">
        <my:canon region="{$r}" line="{@line}"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="canonicalAddImport" select="exsl:node-set($canonicalAddImportRTF)/my:canon"/>

  <!-- ===================== seg-transposition: listTranspose (Abschnitt 7) =====================
       seg-transposition-Bloecke, die ueber other-seg aufeinander verweisen
       (Verweise in beide Richtungen gelten), bilden eine Gruppe. Hinter dem
       LETZTEN Gruppenmitglied im AUSGABETEXT kommt <listTranspose><transpose>
       mit je einem <ptr target="#seg-id"/> pro Mitglied, geordnet nach
       new-order. Die Ausgabereihenfolge steht erst nach dem Rendern fest
       (Regionen werden in Relations-/Lesereihenfolge ausgegeben, nicht in
       PAGE-Quellreihenfolge): jedes Mitglied bekommt beim Rendern eine
       Marke <my:tpm group=".."/>, und ein Nachlauf (Modus tp-post) ersetzt
       nur die LETZTE Marke jeder Gruppe durch die listTranspose und
       verwirft die uebrigen. Fehlt einem Mitglied id oder
       new-order (oder ist new-order keine Zahl), oder hat die Gruppe nur
       ein Mitglied: kein listTranspose. Gruppen werden hier EINMAL zentral
       berechnet (Label-Propagation ueber die other-seg-Kanten, wie bei den
       anderen Tabellen wegen der xsltproc-Stabilitaet). -->
  <xsl:variable name="tpSegsRTF">
    <xsl:for-each select="$allLineRanges[@element='seg' and my:attr[@name='type']/@value='transposition']">
      <xsl:variable name="tpId" select="string(my:attr[@name='id']/@value)"/>
      <!-- ein continued-Lauf traegt dieselbe id auf mehreren Zeilenstuecken: nur das erste zaehlt -->
      <xsl:if test="$tpId = '' or not(preceding-sibling::my:lr[@element='seg' and my:attr[@name='type']/@value='transposition' and my:attr[@name='id']/@value=$tpId])">
        <my:s pos="{position()}" line="{@line}" offset="{@offset}" id="{$tpId}" newOrder="{@newOrder}" otherSeg="{@otherSeg}"/>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="tpSegs" select="exsl:node-set($tpSegsRTF)/my:s"/>

  <xsl:variable name="tpEdgesRTF">
    <xsl:for-each select="$tpSegs[@otherSeg != '']">
      <xsl:variable name="tpFrom" select="@pos"/>
      <xsl:variable name="tpTokRTF">
        <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="@otherSeg"/></xsl:call-template>
      </xsl:variable>
      <xsl:for-each select="exsl:node-set($tpTokRTF)/my:tok">
        <xsl:variable name="tpTo" select="$tpSegs[@id != '' and @id=current()/@val][1]/@pos"/>
        <xsl:if test="$tpTo != '' and $tpTo != $tpFrom">
          <my:e a="{$tpFrom}" b="{$tpTo}"/>
          <my:e a="{$tpTo}" b="{$tpFrom}"/>
        </xsl:if>
      </xsl:for-each>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="tpEdges" select="exsl:node-set($tpEdgesRTF)/my:e"/>

  <xsl:variable name="tpInitRTF">
    <xsl:for-each select="$tpSegs"><my:n pos="{@pos}" label="{@pos}"/></xsl:for-each>
  </xsl:variable>
  <xsl:variable name="tpLabelsRTF">
    <xsl:call-template name="tp-propagate">
      <xsl:with-param name="state" select="exsl:node-set($tpInitRTF)/my:n"/>
    </xsl:call-template>
  </xsl:variable>
  <xsl:variable name="tpLabels" select="exsl:node-set($tpLabelsRTF)/my:n"/>

  <xsl:variable name="transposeListsRTF">
    <xsl:for-each select="$tpLabels[not(@label = preceding-sibling::my:n/@label)]">
      <xsl:variable name="tpGrp" select="$tpLabels[@label=current()/@label]"/>
      <xsl:variable name="tpGrpSegs" select="$tpSegs[@pos=$tpGrp/@pos]"/>
      <xsl:if test="count($tpGrpSegs) &gt;= 2 and not($tpGrpSegs[@id='' or @newOrder='' or string(number(@newOrder))='NaN'])">
        <my:tl group="{@label}">
          <xsl:for-each select="$tpGrpSegs">
            <xsl:sort select="@newOrder" data-type="number"/>
            <xsl:sort select="@pos" data-type="number"/>
            <my:p id="{@id}" line="{@line}" offset="{@offset}"/>
          </xsl:for-each>
        </my:tl>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="transposeLists" select="exsl:node-set($transposeListsRTF)/my:tl"/>

  <!-- Label-Propagation: jedes Segment uebernimmt das kleinste Label seiner
       Nachbarn (und sein eigenes), bis sich nichts mehr aendert -->
  <xsl:template name="tp-propagate">
    <xsl:param name="state"/>
    <xsl:param name="iter" select="1"/>
    <xsl:variable name="tpNextRTF">
      <xsl:for-each select="$state">
        <xsl:variable name="tpMe" select="."/>
        <xsl:variable name="tpNb" select="$state[@pos=$tpMe/@pos or @pos=$tpEdges[@a=$tpMe/@pos]/@b]"/>
        <my:n pos="{@pos}">
          <xsl:attribute name="label">
            <xsl:for-each select="$tpNb">
              <xsl:sort select="@label" data-type="number"/>
              <xsl:if test="position()=1"><xsl:value-of select="@label"/></xsl:if>
            </xsl:for-each>
          </xsl:attribute>
        </my:n>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="tpNext" select="exsl:node-set($tpNextRTF)/my:n"/>
    <xsl:variable name="tpOldSig"><xsl:for-each select="$state"><xsl:value-of select="concat(@label,',')"/></xsl:for-each></xsl:variable>
    <xsl:variable name="tpNewSig"><xsl:for-each select="$tpNext"><xsl:value-of select="concat(@label,',')"/></xsl:for-each></xsl:variable>
    <xsl:choose>
      <xsl:when test="string($tpOldSig) = string($tpNewSig) or $iter &gt;= 30">
        <xsl:copy-of select="$tpNext"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="tp-propagate">
          <xsl:with-param name="state" select="$tpNext"/>
          <xsl:with-param name="iter" select="$iter + 1"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- gibt (falls dieses seg Mitglied einer gueltigen Gruppe ist) die Marke
       fuer den Nachlauf aus (siehe oben) -->
  <xsl:template name="render-transpose-mark">
    <xsl:param name="lineId"/>
    <xsl:param name="offset"/>
    <xsl:variable name="tpMem" select="$transposeLists/my:p[@line=$lineId and number(@offset)=number($offset)]"/>
    <xsl:if test="$tpMem">
      <my:tpm group="{$tpMem[1]/parent::my:tl/@group}"/>
    </xsl:if>
  </xsl:template>

  <!-- Nachlauf: kopiert den fertigen Baum unveraendert, ersetzt aber die
       letzte Marke jeder Gruppe durch die listTranspose und entfernt die
       uebrigen Marken -->
  <xsl:template match="*|@*|text()|comment()|processing-instruction()" mode="tp-post">
    <xsl:copy><xsl:apply-templates select="@*|node()" mode="tp-post"/></xsl:copy>
  </xsl:template>
  <!-- Abschnitt 9 "change-abhaengige renditions": enthaelt das change den
       Kuerzel-Wert (links), bekommt das Element zusaetzlich die zugehoerige
       rendition (rechts, mit "#") - ausser in rendition steht schon einer
       der Zielwerte (dann passiert nichts). Gilt nicht fuer <div>/<mod>/<undo>/<del>/<delSpan>/<gap>/<unclear>/<seg>/<subst> (im <subst>
       nur das <add>, siehe unten). -->
  <xsl:variable name="changeScriptMapRTF">
    <my:m code="kk" val="kurrent"/>
    <my:m code="pr" val="latin"/>
    <my:m code="ar" val="latin"/>
    <my:m code="np" val="black-letter"/>
    <my:m code="fp" val="antiqua"/>
    <my:m code="op" val="antiqua"/>
  </xsl:variable>
  <xsl:variable name="changeScriptMap" select="exsl:node-set($changeScriptMapRTF)/my:m"/>

  <!-- liefert die neue rendition (bestehende Werte + ggf. ergaenzte) oder leer -->
  <xsl:template name="change-rendition-merge">
    <xsl:param name="rendition" select="''"/>
    <xsl:param name="change" select="''"/>
    <xsl:variable name="rn" select="concat(' ', normalize-space(translate($rendition,'#',' ')), ' ')"/>
    <xsl:variable name="hasScript" select="boolean($changeScriptMap[contains($rn, concat(' ', @val, ' '))])"/>
    <xsl:value-of select="normalize-space($rendition)"/>
    <xsl:if test="not($hasScript)">
      <xsl:for-each select="$changeScriptMap[contains($change, @code)]">
        <xsl:variable name="mapVal" select="@val"/>
        <xsl:if test="not(preceding-sibling::my:m[@val=$mapVal and contains($change, @code)])">
          <xsl:if test="normalize-space($rendition) != '' or position() &gt; 1"><xsl:text> </xsl:text></xsl:if>
          <xsl:value-of select="concat('#', @val)"/>
        </xsl:if>
      </xsl:for-each>
    </xsl:if>
  </xsl:template>

  <!-- <div>, <mod>, <undo>, <del>, <delSpan>, <gap>, <unclear>, <seg> und <subst> sind ausgenommen
       (bekommen keine change-abhaengige rendition). Im <subst> bekommt nur
       das <add> sie: hat das add ein eigenes change, zaehlt dieses (das des
       subst faellt raus), sonst das change des subst. -->
  <xsl:template match="*[@change and local-name()!='div' and local-name()!='mod' and local-name()!='undo' and local-name()!='del' and local-name()!='delSpan' and local-name()!='subst' and local-name()!='gap' and local-name()!='unclear' and local-name()!='seg']" mode="tp-post">
    <xsl:call-template name="copy-with-change-rendition">
      <xsl:with-param name="change" select="string(@change)"/>
    </xsl:call-template>
  </xsl:template>
  <xsl:template match="*[local-name()='add' and not(@change) and parent::*[local-name()='subst' and @change]]" mode="tp-post">
    <xsl:call-template name="copy-with-change-rendition">
      <xsl:with-param name="change" select="string(parent::*/@change)"/>
    </xsl:call-template>
  </xsl:template>

  <!-- kopiert das aktuelle Element und setzt die change-abhaengige rendition
       (aus dem uebergebenen change-String); das @change selbst bleibt wie es ist -->
  <xsl:template name="copy-with-change-rendition">
    <xsl:param name="change"/>
    <xsl:variable name="mergedRend">
      <xsl:call-template name="change-rendition-merge">
        <xsl:with-param name="rendition" select="string(@rendition)"/>
        <xsl:with-param name="change" select="$change"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:copy>
      <xsl:for-each select="@*">
        <xsl:choose>
          <xsl:when test="local-name()='rendition'">
            <xsl:attribute name="rendition"><xsl:value-of select="normalize-space($mergedRend)"/></xsl:attribute>
          </xsl:when>
          <xsl:otherwise><xsl:copy/></xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
      <xsl:if test="not(@rendition) and normalize-space($mergedRend) != ''">
        <xsl:attribute name="rendition"><xsl:value-of select="normalize-space($mergedRend)"/></xsl:attribute>
      </xsl:if>
      <xsl:apply-templates select="node()" mode="tp-post"/>
    </xsl:copy>
  </xsl:template>

  <!-- ===================== Zeilenend-Trennzeichen (Abschnitt 7a) =====================
       "-" und "⸗" als LETZTES Zeichen einer Zeile (nur Whitespace und
       Milestones dahinter, kein Text/gap/g bis zum naechsten <lb/>):
       1. nicht als "hyphen" getaggt -> <pc force="weak">; innerhalb eines
          schon vorhandenen <pc> passiert nichts
       2. das darauffolgende <lb/> bekommt IMMER break="no" (auch bei
          getaggtem hyphen) -->
  <xsl:template match="text()[normalize-space()!='']" mode="tp-post">
    <xsl:variable name="norm" select="normalize-space(.)"/>
    <xsl:variable name="lastCh" select="substring($norm, string-length($norm))"/>
    <xsl:variable name="isFinal">
      <xsl:if test="($lastCh='-' or $lastCh='&#x2E17;') and not(parent::*[local-name()='pc'])">
        <xsl:variable name="nl" select="following::*[local-name()='lb'][1]"/>
        <xsl:choose>
          <xsl:when test="$nl">
            <xsl:if test="generate-id($nl/preceding::text()[normalize-space()!=''][1]) = generate-id(.)
                          and not(following::*[local-name()='gap' or local-name()='g'][count(. | $nl/preceding::*) = count($nl/preceding::*)])">yes</xsl:if>
          </xsl:when>
          <xsl:otherwise>
            <xsl:if test="not(following::text()[normalize-space()!='']) and not(following::*[local-name()='gap' or local-name()='g'])">yes</xsl:if>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:if>
    </xsl:variable>
    <xsl:variable name="tagged">
      <xsl:if test="$isFinal='yes'">
        <xsl:call-template name="line-has-hyphen-tag">
          <xsl:with-param name="lineId" select="substring-after(string(preceding::*[local-name()='lb'][1]/@facs), '#zone_')"/>
        </xsl:call-template>
      </xsl:if>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="$isFinal='yes' and $tagged!='yes'">
        <!-- Text vor dem Zeichen, das Zeichen selbst, Whitespace dahinter -->
        <xsl:variable name="coreLen"><xsl:call-template name="rtrim-length"><xsl:with-param name="s" select="string(.)"/></xsl:call-template></xsl:variable>
        <xsl:value-of select="substring(., 1, number($coreLen) - 1)"/>
        <pc force="weak"><xsl:value-of select="substring(., number($coreLen), 1)"/></pc>
        <xsl:value-of select="substring(., number($coreLen) + 1)"/>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="."/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="*[local-name()='lb']" mode="tp-post">
    <xsl:variable name="pt" select="preceding::text()[normalize-space()!=''][1]"/>
    <xsl:variable name="ptNorm" select="normalize-space($pt)"/>
    <xsl:variable name="ptLast" select="substring($ptNorm, string-length($ptNorm))"/>
    <xsl:variable name="brk">
      <xsl:if test="$pt and ($ptLast='-' or $ptLast='&#x2E17;')">
        <xsl:variable name="thisLb" select="."/>
        <xsl:if test="not($pt/following::*[local-name()='gap' or local-name()='g'][count(. | $thisLb/preceding::*) = count($thisLb/preceding::*)])">yes</xsl:if>
      </xsl:if>
    </xsl:variable>
    <xsl:copy>
      <xsl:apply-templates select="@*" mode="tp-post"/>
      <xsl:if test="$brk='yes'"><xsl:attribute name="break">no</xsl:attribute></xsl:if>
      <xsl:apply-templates select="node()" mode="tp-post"/>
    </xsl:copy>
  </xsl:template>

  <!-- Laenge des Textes ohne nachgestellten Whitespace -->
  <xsl:template name="rtrim-length">
    <xsl:param name="s"/>
    <xsl:variable name="n" select="string-length($s)"/>
    <xsl:choose>
      <xsl:when test="$n &gt; 0 and normalize-space(substring($s, $n)) = ''">
        <xsl:call-template name="rtrim-length"><xsl:with-param name="s" select="substring($s, 1, $n - 1)"/></xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$n"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- "yes", wenn die Zeile einen "hyphen"-Block hat, der das letzte Zeichen
       der Zeile abdeckt (offset+length bis zum Zeilenende) -->
  <xsl:template name="line-has-hyphen-tag">
    <xsl:param name="lineId"/>
    <xsl:variable name="ln" select="$allLines[@id=$lineId]"/>
    <xsl:if test="$ln and contains($ln/@custom,'hyphen')">
      <xsl:variable name="raw" select="string($ln/*[local-name()='TextEquiv'][1]/*[local-name()='Unicode'])"/>
      <xsl:variable name="coreLen"><xsl:call-template name="rtrim-length"><xsl:with-param name="s" select="$raw"/></xsl:call-template></xsl:variable>
      <xsl:variable name="blocksRTF"><xsl:call-template name="parse-all-blocks"><xsl:with-param name="s" select="string($ln/@custom)"/></xsl:call-template></xsl:variable>
      <xsl:for-each select="exsl:node-set($blocksRTF)/my:block[@name='hyphen']">
        <xsl:variable name="hOff"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="@content"/><xsl:with-param name="key" select="'offset'"/></xsl:call-template></xsl:variable>
        <xsl:variable name="hLen"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="@content"/><xsl:with-param name="key" select="'length'"/></xsl:call-template></xsl:variable>
        <xsl:if test="number($hOff) + number($hLen) &gt;= number($coreLen)">yes</xsl:if>
      </xsl:for-each>
    </xsl:if>
  </xsl:template>

  <xsl:template match="my:tpm" mode="tp-post">
    <xsl:if test="not(following::my:tpm[@group=current()/@group])">
      <listTranspose>
        <transpose>
          <xsl:for-each select="$transposeLists[@group=current()/@group]/my:p">
            <ptr>
              <xsl:attribute name="target">
                <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="@id"/></xsl:call-template>
              </xsl:attribute>
            </ptr>
          </xsl:for-each>
        </transpose>
      </listTranspose>
    </xsl:if>
  </xsl:template>

  <!-- ===================== change-Werte (Abschnitt 9) =====================
       Alle einzelnen change-Werte des Dokuments (Regionen: structure{change:..};
       Zeilen: Wert auf irgendeinem Block), jeder Wert genau einmal, fuer die
       change-Eintraege im teiHeader. -->
  <xsl:variable name="changeTokensRTF">
    <xsl:for-each select="$regions[@change != '']">
      <xsl:call-template name="change-token-list"><xsl:with-param name="s" select="string(@change)"/></xsl:call-template>
    </xsl:for-each>
    <xsl:for-each select="$allLineRanges/my:attr[@name='change']">
      <xsl:call-template name="change-token-list"><xsl:with-param name="s" select="string(@value)"/></xsl:call-template>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="changeTokens" select="exsl:node-set($changeTokensRTF)/my:cv"/>
  <xsl:variable name="changeValues" select="$changeTokens[@v != '' and not(@v = preceding-sibling::my:cv/@v)]"/>

  <!-- ===================== Warnung: doppelt vergebene Behelfs-IDs =====================
       Wird derselbe Behelfs-ID-Wert mehrfach deklariert (Region-structure{id},
       Zeilen-Block id/subst-id/del-id), ist unklar, worauf sich Verweise
       (target/corresp/add-id) beziehen. Das Stylesheet entscheidet das NICHT,
       sondern meldet es (xsl:message "WARNUNG: ..."; transform.sh uebernimmt die
       Meldungen in den Report). Stuecke eines continued:true-Laufs, die dieselbe
       id auf mehreren Zeilen tragen, zaehlen als eine Deklaration. -->
  <xsl:variable name="behelfsDeclsRawRTF">
    <xsl:for-each select="$regions[@behelfsId != '' and not(contains(@behelfsId,'.xml#'))]">
      <my:dd v="{@behelfsId}" kind="region" el="{@type}" continued="false" where="Region {@id} ({@type})"/>
    </xsl:for-each>
    <xsl:for-each select="$allLineRanges[my:attr[@name='id' or @name='subst-id' or @name='del-id']]">
      <xsl:variable name="ddR" select="."/>
      <xsl:for-each select="my:attr[@name='id' or @name='subst-id' or @name='del-id']">
        <xsl:if test="@value != '' and not(contains(@value,'.xml#'))">
          <my:dd v="{@value}" kind="line" el="{$ddR/@element}" continued="{$ddR/@continued}" where="Zeile {$ddR/@line} ({$ddR/@element}, {@name})"/>
        </xsl:if>
      </xsl:for-each>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="behelfsDeclsRTF">
    <xsl:for-each select="exsl:node-set($behelfsDeclsRawRTF)/my:dd">
      <my:dd v="{@v}" where="{@where}">
        <xsl:attribute name="benign">
          <xsl:value-of select="boolean(@kind='line' and preceding-sibling::my:dd[@v=current()/@v][1][@kind='line' and @el=current()/@el and @continued='true'])"/>
        </xsl:attribute>
      </my:dd>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="behelfsDecls" select="exsl:node-set($behelfsDeclsRTF)/my:dd"/>
  <xsl:variable name="behelfsDupsRTF">
    <xsl:for-each select="$behelfsDecls[not(@v = preceding-sibling::my:dd/@v)]">
      <xsl:variable name="ddV" select="@v"/>
      <xsl:if test="count($behelfsDecls[@v=$ddV and @benign='false']) &gt; 1">
        <my:dup v="{$ddV}">
          <xsl:attribute name="where">
            <xsl:for-each select="$behelfsDecls[@v=$ddV and @benign='false']">
              <xsl:if test="position() &gt; 1"><xsl:text>; </xsl:text></xsl:if>
              <xsl:value-of select="@where"/>
            </xsl:for-each>
          </xsl:attribute>
        </my:dup>
      </xsl:if>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="behelfsDups" select="exsl:node-set($behelfsDupsRTF)/my:dup"/>

  <!-- ===================== Haupteinstieg ===================== -->

  <xsl:template match="/*[local-name()='PcGts']">
    <xsl:for-each select="$behelfsDups">
      <xsl:message>WARNUNG: Behelfs-ID "<xsl:value-of select="@v"/>" ist mehrfach vergeben: <xsl:value-of select="@where"/></xsl:message>
    </xsl:for-each>
    <!-- Schema-Verknuepfung (Pfad relativ zu tei/) -->
    <xsl:processing-instruction name="xml-model">href="../meta/hdr-documentary-schema.rng" type="application/xml" schematypens="http://relaxng.org/ns/structure/1.0"</xsl:processing-instruction>
    <xsl:choose>
      <!-- seg-transposition mit gueltiger Gruppe (listTranspose an die richtige
           Stelle setzen), change-abhaengige rendition ergaenzen (Abschnitt 9),
           Zeilenend-Trennzeichen (Abschnitt 7a): Baum erst in eine Variable
           bauen, dann im Nachlauf (Modus tp-post) fertigstellen -->
      <xsl:when test="true()">
        <xsl:variable name="teiRTF"><xsl:call-template name="build-tei"/></xsl:variable>
        <xsl:apply-templates select="exsl:node-set($teiRTF)/*" mode="tp-post"/>
      </xsl:when>
      <xsl:otherwise><xsl:call-template name="build-tei"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="build-tei">
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
        <!-- Abschnitt 9: ein change-Element je distinct change-Wert -->
        <xsl:if test="$changeValues">
          <profileDesc>
            <creation>
              <listChange>
                <xsl:for-each select="$changeValues">
                  <xsl:sort select="@v"/>
                  <change xml:id="{@v}">[tbd]</change>
                </xsl:for-each>
              </listChange>
            </creation>
          </profileDesc>
        </xsl:if>
      </teiHeader>

      <facsimile>
        <graphic url="{$page/@imageFilename}" width="{$page/@imageWidth}px" height="{$page/@imageHeight}px"/>
        <xsl:choose>
          <xsl:when test="$baseId='SYNTHETIC_BASE'">
            <surface lrx="{$page/@imageWidth}" lry="{$page/@imageHeight}">
              <xsl:attribute name="xml:id">surface_<xsl:value-of select="$page/@imageFilename"/></xsl:attribute>
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
              <div>
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
          <!-- Abschnitt 2/5: @type = structure{subcat:..}; ohne subcat KEIN @type.
               Der cat-Wert selbst wird NICHT ausgegeben (er dient nur der Wahl
               der base-surface, siehe $baseId). @source = structure{source:..}. -->
          <xsl:if test="$region/@subcat != ''">
            <xsl:attribute name="type"><xsl:value-of select="$region/@subcat"/></xsl:attribute>
          </xsl:if>
          <xsl:if test="$region/@source != ''">
            <xsl:attribute name="source"><xsl:value-of select="$region/@source"/></xsl:attribute>
          </xsl:if>
          <xsl:if test="$src/*[local-name()='Coords']/@points">
            <xsl:attribute name="points"><xsl:value-of select="$src/*[local-name()='Coords']/@points"/></xsl:attribute>
          </xsl:if>
          <xsl:for-each select="$childIds">
            <xsl:call-template name="render-node-fac"><xsl:with-param name="id" select="."/></xsl:call-template>
          </xsl:for-each>
          <xsl:call-template name="render-line-zones-for-region"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
        </surface>
      </xsl:when>
      <xsl:otherwise>
        <zone>
          <xsl:attribute name="xml:id">zone_<xsl:value-of select="$id"/></xsl:attribute>
          <!-- kein @type an der zone (frueher: Regionstyp aus rawType) -->
          <xsl:if test="$src/*[local-name()='Coords']/@points">
            <xsl:attribute name="points"><xsl:value-of select="$src/*[local-name()='Coords']/@points"/></xsl:attribute>
          </xsl:if>
          <xsl:for-each select="$childIds">
            <xsl:call-template name="render-node-fac"><xsl:with-param name="id" select="."/></xsl:call-template>
          </xsl:for-each>
          <xsl:call-template name="render-line-zones-for-region"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
        </zone>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Abschnitt 4, letzter Punkt: jede Zeile bekommt eine eigene <zone
       type="line"> in facsimile, verschachtelt in der Zone/surface, der sie
       per $lineAssign zugeordnet ist (nicht der PAGE-Struktur). Referenziert
       wird sie von <lb facs="#zone_<Zeilen-id>"/> im text/body-Teil. -->
  <xsl:template name="render-line-zones-for-region">
    <xsl:param name="regionId"/>
    <xsl:for-each select="$lineAssign[@region=$regionId]">
      <xsl:sort select="number(@rank)" data-type="number"/>
      <xsl:sort select="number(@pindex)" data-type="number"/>
      <xsl:sort select="number(@oindex)" data-type="number"/>
      <xsl:variable name="line" select="$allLines[@id=current()/@id]"/>
      <zone type="line">
        <xsl:attribute name="xml:id">zone_<xsl:value-of select="$line/@id"/></xsl:attribute>
        <xsl:if test="$line/*[local-name()='Coords']/@points">
          <xsl:attribute name="points"><xsl:value-of select="$line/*[local-name()='Coords']/@points"/></xsl:attribute>
        </xsl:if>
      </zone>
    </xsl:for-each>
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
      <!-- Abschnitt 5: subcat steht in <div @type> (und in <surface @type>);
           cat/source stehen am <div> nirgends -->
      <xsl:if test="$region/@subcat != ''">
        <xsl:attribute name="type"><xsl:value-of select="$region/@subcat"/></xsl:attribute>
      </xsl:if>
      <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
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
       sind. <metamark>, <gap> und <fw> brauchen das nicht (dürfen direkt neben
       <div> stehen). -->
  <xsl:template name="render-children-text">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="4"/>
    <xsl:param name="ownText" select="false()"/>
    <xsl:param name="ownTextRegionId"/>
    <!-- inlineMode: die Region ist selbst ein <p> (is-quote-host): eigener
         Text steht direkt darin (ohne zusaetzliches <p>), Kinder werden nicht
         zu article-Gruppen zusammengefasst und nie in <div> gewickelt. -->
    <xsl:param name="inlineMode" select="false()"/>
    <!-- inlineTrailing=false: kein Umbruch nach der letzten Einheit (die rufende
         Stelle, z.B. render-paragraph-group, setzt ihn selbst) -->
    <xsl:param name="inlineTrailing" select="true()"/>
    <xsl:variable name="childEntries" select="$effParents[@of=$id]"/>

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
      <xsl:for-each select="$childEntries[not(@id = $consumedAddRegions/@id)]">
        <xsl:variable name="childId" select="@id"/>
        <xsl:variable name="rel" select="$relMembers[@region=$childId]"/>
        <xsl:choose>
          <!-- column-block -> <cb/> vor seinen (nach oben gezogenen) Inhalten -->
          <xsl:when test="$regions[@id=$childId]/@type='column-block'">
            <my:unit id="{$childId}" kind="cb" group="" cb="y" index="{$childEntries[@id=$childId]/@key}" own=""/>
          </xsl:when>
          <!-- Relation "paragraph": die ganze Gruppe wird EINE Einheit an der
               Stelle des ZUERST in der Relation genannten Mitglieds; alle
               anderen Mitglieder entfallen an ihrer eigenen Position. -->
          <xsl:when test="$pgMembers[@region=$childId] and not($rel and not($inlineMode))">
            <xsl:variable name="pgGroup" select="$pgMembers[@region=$childId][1]/@group"/>
            <xsl:variable name="firstPg">
              <xsl:for-each select="$pgMembers[@group=$pgGroup]">
                <xsl:sort select="@pos" data-type="number"/>
                <xsl:if test="position()=1"><xsl:value-of select="@region"/></xsl:if>
              </xsl:for-each>
            </xsl:variable>
            <xsl:if test="$firstPg = $childId">
              <my:unit id="{$childId}" kind="p" group="" pgroup="{$pgGroup}" index="{$childEntries[@id=$childId]/@key}" own=""/>
            </xsl:if>
          </xsl:when>
          <xsl:when test="$rel and not($inlineMode)">
            <xsl:variable name="groupKey" select="$rel/@group"/>
            <!-- Mitglieder in verschiedenen column-blocks bilden getrennte
                 Teil-<div>s (je Block), ueber <cb/> hinweg wird nicht zusammen-
                 gezogen: gleiche Gruppe UND gleicher uebersprungener Block -->
            <xsl:variable name="myVia" select="string($childEntries[@id=$childId]/@via)"/>
            <xsl:variable name="siblingGroupIds" select="$relMembers[@group=$groupKey][$childEntries[@via=$myVia]/@id = @region]/@region"/>
            <xsl:variable name="isAnchor">
              <xsl:for-each select="$siblingGroupIds">
                <xsl:sort select="$regions[@id=current()]/@index" data-type="number"/>
                <xsl:if test="position()=1 and .=$childId">yes</xsl:if>
              </xsl:for-each>
            </xsl:variable>
            <xsl:if test="$isAnchor='yes'">
              <my:unit id="{$childId}" kind="div" group="{$groupKey}" index="{$childEntries[@id=$childId]/@key}" own=""/>
            </xsl:if>
          </xsl:when>
          <xsl:when test="$quoteMembers[@region=$childId]">
            <!-- multi-p-quote: EIN Einheit fuer die ganze Gruppe, an der
                 Stelle des zuerst gelesenen Mitglieds (wie bei article) -->
            <xsl:variable name="qGroup" select="$quoteMembers[@region=$childId][1]/@group"/>
            <xsl:variable name="qSiblingIds" select="$quoteMembers[@group=$qGroup][$childEntries/@id = @region]/@region"/>
            <xsl:variable name="isQAnchor">
              <xsl:for-each select="$qSiblingIds">
                <xsl:sort select="$regions[@id=current()]/@index" data-type="number"/>
                <xsl:if test="position()=1 and .=$childId">yes</xsl:if>
              </xsl:for-each>
            </xsl:variable>
            <xsl:if test="$isQAnchor='yes'">
              <my:unit id="{$childId}" kind="p" group="" qgroup="{$qGroup}" index="{$childEntries[@id=$childId]/@key}" own=""/>
            </xsl:if>
          </xsl:when>
          <xsl:otherwise>
            <xsl:variable name="kind"><xsl:call-template name="child-kind"><xsl:with-param name="id" select="$childId"/></xsl:call-template></xsl:variable>
            <!-- single-p-article:y (Abschnitt 5): der <p> steht in einem
                 <div type="article"> (zaehlt deshalb als div-Einheit) -->
            <xsl:variable name="spa" select="$regions[@id=$childId]/@singlePArticle"/>
            <my:unit id="{$childId}" index="{$childEntries[@id=$childId]/@key}" own="" group="" spa="{$spa}">
              <xsl:attribute name="kind"><xsl:choose><xsl:when test="$spa='y' and $kind='p'">div</xsl:when><xsl:otherwise><xsl:value-of select="$kind"/></xsl:otherwise></xsl:choose></xsl:attribute>
            </my:unit>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="units" select="exsl:node-set($unitsRTF)/my:unit"/>
    <xsl:variable name="mixed" select="not($inlineMode) and boolean($units[@kind='div']) and boolean($units[@kind='p' or @kind='head'])"/>

    <xsl:for-each select="$units">
      <!-- <fw> (Kolumnentitel, Seitenzahl, ...) stehen innerhalb ihres <div>
           immer am ANFANG (vor Text und den uebrigen Kindern), untereinander
           in der bisherigen Reihenfolge -->
      <xsl:sort select="number(@kind != 'fw')" data-type="number"/>
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
          <xsl:when test="$u/@own='yes' and $inlineMode">
            <xsl:call-template name="render-lines">
              <xsl:with-param name="regionId" select="$ownTextRegionId"/>
              <xsl:with-param name="depth" select="$unitDepth"/>
              <xsl:with-param name="trailing" select="false()"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:when test="$u/@own='yes'">
            <p>
              <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$ownTextRegionId"/></xsl:call-template>
              <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$ownTextRegionId"/></xsl:call-template>
              <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$regions[@id=$ownTextRegionId]/@rendition"/></xsl:call-template>
              <xsl:call-template name="render-lines">
                <xsl:with-param name="regionId" select="$ownTextRegionId"/>
                <xsl:with-param name="depth" select="$unitDepth + 1"/>
              </xsl:call-template>
            </p>
          </xsl:when>
          <xsl:when test="$u/@group != ''">
            <xsl:variable name="uVia" select="string($childEntries[@id=$u/@id]/@via)"/>
            <xsl:variable name="memberIds" select="$relMembers[@group=$u/@group][$childEntries[@via=$uVia]/@id = @region]/@region"/>
            <xsl:call-template name="render-article-group">
              <xsl:with-param name="groupKey" select="$u/@group"/>
              <xsl:with-param name="memberIds" select="$memberIds"/>
              <xsl:with-param name="depth" select="$unitDepth"/>
              <xsl:with-param name="parentId" select="concat($id,'|',$uVia)"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:when test="$u/@cb='y'">
            <cb>
              <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$u/@id"/></xsl:call-template>
              <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$u/@id"/></xsl:call-template>
              <xsl:attribute name="facs">#zone_<xsl:value-of select="$u/@id"/></xsl:attribute>
              <xsl:if test="$regions[@id=$u/@id]/@blockExtent != ''"><xsl:attribute name="n"><xsl:value-of select="$regions[@id=$u/@id]/@blockExtent"/></xsl:attribute></xsl:if>
            </cb>
          </xsl:when>
          <xsl:when test="$u/@pgroup != ''">
            <xsl:call-template name="render-paragraph-group">
              <xsl:with-param name="groupKey" select="$u/@pgroup"/>
              <xsl:with-param name="depth" select="$unitDepth"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:when test="$u/@qgroup != ''">
            <xsl:call-template name="render-quote-group">
              <xsl:with-param name="memberIds" select="$quoteMembers[@group=$u/@qgroup][$childEntries/@id = @region]/@region"/>
              <xsl:with-param name="depth" select="$unitDepth"/>
              <xsl:with-param name="manualIndent" select="$inlineMode"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:when test="$u/@spa='y'">
            <div type="article">
              <xsl:call-template name="render-child-text">
                <xsl:with-param name="id" select="$u/@id"/>
                <xsl:with-param name="depth" select="$unitDepth + 1"/>
              </xsl:call-template>
            </div>
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="render-child-text">
              <xsl:with-param name="id" select="$u/@id"/>
              <xsl:with-param name="depth" select="$unitDepth"/>
              <xsl:with-param name="manualIndent" select="$inlineMode"/>
            </xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:choose>
        <xsl:when test="$willWrap">
          <div><xsl:copy-of select="$rendered"/></div>
        </xsl:when>
        <xsl:otherwise>
          <xsl:if test="$inlineMode and not($u/@own='yes')">
            <xsl:text>&#10;</xsl:text>
            <xsl:call-template name="indent"><xsl:with-param name="depth" select="$unitDepth"/></xsl:call-template>
          </xsl:if>
          <xsl:copy-of select="$rendered"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:for-each>
    <xsl:if test="$inlineMode and $inlineTrailing and $units[not(@own='yes')]">
      <xsl:text>&#10;</xsl:text>
      <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth - 1"/></xsl:call-template>
    </xsl:if>
  </xsl:template>

  <!-- Abschnitt 5, Ausnahme zur Regel "Zone mit Kind-Zonen -> <div>": hat die
       Zone Kind-Zonen mit "long-quote" im Typ (und sonst hoechstens
       metamark/gap bzw. per add-id verbrauchte add-Regionen), wird sie
       selbst zu <p>, weil das verschachtelte <quote> in <p> erlaubt ist.
       Liefert "yes" oder nichts. surface/column-block/add-block/
       advertisement bleiben immer <div>. -->
  <xsl:template name="is-quote-host">
    <xsl:param name="id"/>
    <xsl:variable name="type" select="$regions[@id=$id]/@type"/>
    <xsl:if test="$type != 'surface' and $type != 'column-block' and $type != 'add-block' and $type != 'advertisement' and $type != 'masthead'">
      <xsl:variable name="kids" select="$regions[@id=$effParents[@of=$id]/@id][not(@id = $consumedAddRegions/@id)]"/>
      <xsl:if test="$kids[starts-with(@type,'long-quote')] and not($kids[not(starts-with(@type,'long-quote') or @type='metamark' or @type='annotation' or @type='gap')])">yes</xsl:if>
    </xsl:if>
  </xsl:template>

  <!-- welches Element eine Kind-Zone rendern wird (fuer die Mixing-Erkennung) -->
  <xsl:template name="child-kind">
    <xsl:param name="id"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:variable name="quoteHost"><xsl:call-template name="is-quote-host"><xsl:with-param name="id" select="$id"/></xsl:call-template></xsl:variable>
    <xsl:choose>
      <xsl:when test="$quoteHost='yes'">p</xsl:when>
      <xsl:when test="$region/@type='surface'">div</xsl:when>
      <xsl:when test="$region/@type='annotation' or $region/@type='metamark'">metamark</xsl:when>
      <xsl:when test="$region/@type='gap'">gap</xsl:when>
      <xsl:when test="$region/@type='column-block'">cb</xsl:when>
      <xsl:when test="$region/@type='add-block'">div</xsl:when>
      <xsl:when test="boolean($effParents[@of=$id])">div</xsl:when>
      <!-- <fw> darf in TEI direkt neben <div> stehen (wie metamark/gap) und
           muss deshalb nicht in ein <div> gewickelt werden (siehe Mixing-
           Regel in render-children-text) -->
      <xsl:when test="$region/@type='fw'">fw</xsl:when>
      <!-- byline/dateline stehen als <byline>/<dateline> direkt im <div> und
           brauchen keine Wickelung (weder p- noch div-Art) -->
      <xsl:when test="$region/@type='byline' or $region/@type='paragraph-byline' or $region/@type='dateline' or $region/@type='paragraph-dateline'">byline</xsl:when>
      <xsl:when test="$region/@type='head'">head</xsl:when>
      <xsl:otherwise>p</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- welches TEI-Element eine Region LETZTLICH rendert (feiner als child-kind:
       unterscheidet zusaetzlich add/fw/p, die child-kind alle als "p"
       durchwinkt) - wird nur fuer die Behelfs-ID-Vergabe (Abschnitt 8)
       gebraucht, um Nicht-metamark/add-Regionen mit eigener Behelfs-ID den
       richtigen Elementnamen als ID-Praefix zu geben. -->
  <xsl:template name="region-tei-tag">
    <xsl:param name="id"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:variable name="type" select="$region/@type"/>
    <xsl:variable name="hasChildren" select="boolean($effParents[@of=$id])"/>
    <xsl:variable name="quoteHost"><xsl:call-template name="is-quote-host"><xsl:with-param name="id" select="$id"/></xsl:call-template></xsl:variable>
    <xsl:choose>
      <xsl:when test="$type='surface'">div</xsl:when>
      <xsl:when test="$type='annotation' or $type='metamark'">metamark</xsl:when>
      <xsl:when test="$type='gap'">gap</xsl:when>
      <xsl:when test="$quoteHost='yes'">p</xsl:when>
      <xsl:when test="$type='head' and not($hasChildren) and $region/@cat='cross'">p</xsl:when>
      <xsl:when test="$type='head' and not($hasChildren)">head</xsl:when>
      <xsl:when test="$type='add-block' or $type='advertisement' or $type='masthead' or $hasChildren">div</xsl:when>
      <xsl:when test="$type='add'">add</xsl:when>
      <xsl:when test="$type='fw'">fw</xsl:when>
      <xsl:when test="$type='long-quote-lg'">lg</xsl:when>
      <xsl:when test="$type='byline' or $type='paragraph-byline'">byline</xsl:when>
      <xsl:when test="$type='dateline' or $type='paragraph-dateline'">dateline</xsl:when>
      <xsl:otherwise>p</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="render-article-group">
    <xsl:param name="groupKey"/>
    <xsl:param name="memberIds"/>
    <xsl:param name="depth" select="4"/>
    <xsl:param name="parentId" select="''"/>
    <xsl:variable name="frag" select="$articleFragments[@group=$groupKey and @parent=$parentId]"/>
    <div>
      <!-- ueber Hierarchiegrenzen verteilte Gruppen: xml:id + prev/next -->
      <xsl:if test="$frag">
        <xsl:attribute name="xml:id"><xsl:value-of select="$frag[1]/@genid"/></xsl:attribute>
      </xsl:if>
      <xsl:attribute name="type"><xsl:value-of select="$relMembers[@group=$groupKey][1]/@type"/></xsl:attribute>
      <xsl:if test="$frag[1]/@prev != ''"><xsl:attribute name="prev"><xsl:value-of select="concat('#',$frag[1]/@prev)"/></xsl:attribute></xsl:if>
      <xsl:if test="$frag[1]/@next != ''"><xsl:attribute name="next"><xsl:value-of select="concat('#',$frag[1]/@next)"/></xsl:attribute></xsl:if>
      <!-- Abschnitt 6: <div type="article"> mit prev und/oder next bekommt @part:
           nur prev -> F, nur next -> I, beides -> M -->
      <xsl:if test="$relMembers[@group=$groupKey][1]/@type='article' and ($frag[1]/@prev != '' or $frag[1]/@next != '')">
        <xsl:attribute name="part">
          <xsl:choose>
            <xsl:when test="$frag[1]/@prev != '' and $frag[1]/@next != ''">M</xsl:when>
            <xsl:when test="$frag[1]/@prev != ''">F</xsl:when>
            <xsl:otherwise>I</xsl:otherwise>
          </xsl:choose>
        </xsl:attribute>
      </xsl:if>
      <xsl:for-each select="$memberIds">
        <xsl:sort select="$relMembers[@group=$groupKey and @region=current()][1]/@pos" data-type="number"/>
        <xsl:variable name="mid" select="."/>
        <xsl:variable name="qGroup" select="$quoteMembers[@region=$mid][1]/@group"/>
        <xsl:variable name="pgM" select="$pgMembers[@region=$mid]"/>
        <xsl:choose>
          <!-- Relation "paragraph": Mitglied einer gemeinsamen <p>-Gruppe - die
               ganze Gruppe wird genau EINMAL an der Stelle ihres zuerst in
               der Relation genannten Mitglieds ausgegeben, die uebrigen
               Mitglieder entfallen hier -->
          <xsl:when test="$pgM">
            <xsl:variable name="pgFirst">
              <xsl:for-each select="$pgMembers[@group=$pgM[1]/@group]">
                <xsl:sort select="@pos" data-type="number"/>
                <xsl:if test="position()=1"><xsl:value-of select="@region"/></xsl:if>
              </xsl:for-each>
            </xsl:variable>
            <xsl:if test="$pgFirst = $mid">
              <xsl:call-template name="render-paragraph-group">
                <xsl:with-param name="groupKey" select="$pgM[1]/@group"/>
                <xsl:with-param name="depth" select="$depth + 1"/>
              </xsl:call-template>
            </xsl:if>
          </xsl:when>
          <xsl:when test="$qGroup != ''">
            <!-- multi-p-quote-Mitglieder innerhalb eines article: EIN <quote>
                 an der Stelle des ersten Mitglieds, die uebrigen entfallen -->
            <xsl:variable name="qIds" select="$memberIds[$quoteMembers[@group=$qGroup]/@region = .]"/>
            <xsl:variable name="firstQ">
              <xsl:for-each select="$qIds">
                <xsl:sort select="$regions[@id=current()]/@index" data-type="number"/>
                <xsl:if test="position()=1"><xsl:value-of select="."/></xsl:if>
              </xsl:for-each>
            </xsl:variable>
            <xsl:if test="$firstQ=$mid">
              <xsl:call-template name="render-quote-group">
                <xsl:with-param name="memberIds" select="$qIds"/>
                <xsl:with-param name="depth" select="$depth + 1"/>
              </xsl:call-template>
            </xsl:if>
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="render-child-text">
              <xsl:with-param name="id" select="$mid"/>
              <xsl:with-param name="depth" select="$depth + 1"/>
            </xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
    </div>
  </xsl:template>

  <!-- Relation "paragraph" (Abschnitt 6): alle Mitglieder in EIN <p>, in
       Relationsreihenfolge. paragraph/paragraph-*-Mitglieder liefern ihre
       Zeilen direkt (ohne eigenes <p>), long-quote-* ein <quote>, metamark
       ein <metamark>. facs verweist auf alle paragraph-Mitglieder;
       rendition, xml:id und die uebrigen Attribute kommen vom ERSTEN
       paragraph/paragraph-*-Mitglied (die renditions der anderen Mitglieder
       bleiben bei deren eigenen Elementen, d.h. quote/p/metamark). -->
  <xsl:template name="render-paragraph-group">
    <xsl:param name="groupKey"/>
    <xsl:param name="depth" select="4"/>
    <xsl:variable name="members" select="$pgMembers[@group=$groupKey]"/>
    <xsl:variable name="firstPara">
      <xsl:for-each select="$members[starts-with(@type,'paragraph')]">
        <xsl:sort select="@pos" data-type="number"/>
        <xsl:if test="position()=1"><xsl:value-of select="@region"/></xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="fr" select="$regions[@id=string($firstPara)]"/>
    <p>
      <xsl:if test="$firstPara != ''">
        <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="string($firstPara)"/></xsl:call-template>
        <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="string($firstPara)"/></xsl:call-template>
      </xsl:if>
      <xsl:variable name="facsList">
        <xsl:for-each select="$members[starts-with(@type,'paragraph')]">
          <xsl:sort select="@pos" data-type="number"/>
          <xsl:if test="position() &gt; 1"><xsl:text> </xsl:text></xsl:if>
          <xsl:value-of select="concat('#zone_', @region)"/>
        </xsl:for-each>
      </xsl:variable>
      <xsl:if test="$facsList != ''"><xsl:attribute name="facs"><xsl:value-of select="$facsList"/></xsl:attribute></xsl:if>
      <xsl:if test="$firstPara != ''">
        <xsl:call-template name="rendition-attr-if-any">
          <xsl:with-param name="value" select="$fr/@rendition"/>
          <xsl:with-param name="extra"><xsl:if test="$fr/@type='paragraph-indent'">indent</xsl:if></xsl:with-param>
        </xsl:call-template>
        <xsl:if test="$fr/@type='paragraph' or $fr/@type='paragraph-indent'">
          <xsl:call-template name="paragraph-extra-attrs"><xsl:with-param name="regionId" select="string($firstPara)"/></xsl:call-template>
        </xsl:if>
      </xsl:if>
      <xsl:for-each select="$members">
        <xsl:sort select="@pos" data-type="number"/>
        <xsl:choose>
          <xsl:when test="starts-with(@type,'paragraph')">
            <!-- eigener Text UND ggf. geschachtelte Zonen des Mitglieds werden
                 mit uebernommen (inlineMode: direkt im <p>, ohne eigenes <p>) -->
            <xsl:variable name="memberHasText">
              <xsl:call-template name="region-has-own-text"><xsl:with-param name="regionId" select="@region"/></xsl:call-template>
            </xsl:variable>
            <xsl:call-template name="render-children-text">
              <xsl:with-param name="id" select="@region"/>
              <xsl:with-param name="depth" select="$depth + 1"/>
              <xsl:with-param name="ownText" select="$memberHasText='true'"/>
              <xsl:with-param name="ownTextRegionId" select="@region"/>
              <xsl:with-param name="inlineMode" select="true()"/>
              <xsl:with-param name="inlineTrailing" select="false()"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <xsl:text>&#10;</xsl:text>
            <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth + 1"/></xsl:call-template>
            <xsl:call-template name="render-child-text">
              <xsl:with-param name="id" select="@region"/>
              <xsl:with-param name="depth" select="$depth + 1"/>
              <xsl:with-param name="manualIndent" select="true()"/>
            </xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
      <xsl:text>&#10;</xsl:text>
      <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
    </p>
  </xsl:template>

  <!-- multi-p-quote (Abschnitt 6): alle Mitglieder gemeinsam in EIN <quote>;
       die einzelnen p/lg werden dabei ohne eigenes <quote> gerendert
       (inQuoteGroup). -->
  <xsl:template name="render-quote-group">
    <xsl:param name="memberIds"/>
    <xsl:param name="depth" select="4"/>
    <!-- manualIndent: das <quote> steht in einem <p> (Saxon rueckt dort nicht
         selbst ein), Umbrueche/Einrueckung werden daher hier erzeugt -->
    <xsl:param name="manualIndent" select="false()"/>
    <quote>
      <xsl:for-each select="$memberIds">
        <xsl:sort select="$regions[@id=current()]/@index" data-type="number"/>
        <xsl:if test="$manualIndent">
          <xsl:text>&#10;</xsl:text>
          <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth + 1"/></xsl:call-template>
        </xsl:if>
        <xsl:call-template name="render-child-text">
          <xsl:with-param name="id" select="."/>
          <xsl:with-param name="depth" select="$depth + 1"/>
          <xsl:with-param name="inQuoteGroup" select="true()"/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:if test="$manualIndent">
        <xsl:text>&#10;</xsl:text>
        <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
      </xsl:if>
    </quote>
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
    <xsl:param name="inQuoteGroup" select="false()"/>
    <xsl:param name="manualIndent" select="false()"/>
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
        <gap>
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:if test="$region/@reason != ''"><xsl:attribute name="reason"><xsl:value-of select="$region/@reason"/></xsl:attribute></xsl:if>
        </gap>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="render-zone-text">
          <xsl:with-param name="id" select="$id"/>
          <xsl:with-param name="depth" select="$depth"/>
          <xsl:with-param name="inQuoteGroup" select="$inQuoteGroup"/>
          <xsl:with-param name="manualIndent" select="$manualIndent"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="render-zone-text">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="4"/>
    <xsl:param name="inQuoteGroup" select="false()"/>
    <xsl:param name="manualIndent" select="false()"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:variable name="type" select="$region/@type"/>
    <xsl:variable name="hasChildren" select="boolean($effParents[@of=$id])"/>
    <xsl:variable name="quoteHost"><xsl:call-template name="is-quote-host"><xsl:with-param name="id" select="$id"/></xsl:call-template></xsl:variable>
    <xsl:variable name="hasOwnTextV">
      <xsl:call-template name="region-has-own-text"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
    </xsl:variable>
    <xsl:choose>
      <!-- Abschnitt 5: head mit cat:cross -> <p rendition="crosshead">; mit
           cat:main/cat:sub -> <head type="main|sub"> -->
      <xsl:when test="$type='head' and not($hasChildren) and $region/@cat='cross'">
        <p>
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <!-- #crosshead plus alle rendition-Werte der Region -->
          <xsl:call-template name="rendition-attr-if-any">
            <xsl:with-param name="value" select="$region/@rendition"/>
            <xsl:with-param name="extra" select="'crosshead'"/>
          </xsl:call-template>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </p>
      </xsl:when>
      <xsl:when test="$type='head' and not($hasChildren)">
        <head>
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:if test="$region/@cat='main' or $region/@cat='sub'"><xsl:attribute name="type"><xsl:value-of select="$region/@cat"/></xsl:attribute></xsl:if>
          <!-- alle rendition-Werte der head-Region (mit "#") -->
          <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$region/@rendition"/></xsl:call-template>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </head>
      </xsl:when>
      <xsl:when test="$quoteHost='yes'">
        <!-- Abschnitt 5, Ausnahme: Zone mit long-quote-Kindern wird selbst zu
             <p> (Attribute wie beim normalen <p>), die <quote> stehen darin. -->
        <p>
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:call-template name="rendition-attr-if-any">
            <xsl:with-param name="value" select="$region/@rendition"/>
            <xsl:with-param name="extra"><xsl:if test="$type='paragraph-indent'">indent</xsl:if></xsl:with-param>
          </xsl:call-template>
          <xsl:if test="$type='paragraph' or $type='paragraph-indent'">
            <xsl:call-template name="paragraph-extra-attrs"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          </xsl:if>
          <xsl:call-template name="render-children-text">
            <xsl:with-param name="id" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
            <xsl:with-param name="ownText" select="$hasOwnTextV='true'"/>
            <xsl:with-param name="ownTextRegionId" select="$id"/>
            <xsl:with-param name="inlineMode" select="true()"/>
          </xsl:call-template>
        </p>
      </xsl:when>
      <xsl:when test="$type='add-block' or $type='advertisement' or $type='masthead' or $hasChildren">
        <div>
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:if test="$type != ''"><xsl:attribute name="type"><xsl:value-of select="$type"/></xsl:attribute></xsl:if>
          <xsl:if test="$type='add-block'"><xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$region/@rendition"/></xsl:call-template></xsl:if>
          <xsl:call-template name="render-children-text">
            <xsl:with-param name="id" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
            <xsl:with-param name="ownText" select="$hasOwnTextV='true'"/>
            <xsl:with-param name="ownTextRegionId" select="$id"/>
          </xsl:call-template>
        </div>
      </xsl:when>
      <!-- Abschnitt 5: Region byline -> <byline>, Region dateline -> <dateline>
           (rendition uebernehmen, id als xml:id); paragraph-byline/-dateline
           (Namensvariante in aelteren Exporten) werden ebenso behandelt -->
      <xsl:when test="$type='byline' or $type='paragraph-byline' or $type='dateline' or $type='paragraph-dateline'">
        <xsl:variable name="blName">
          <xsl:choose>
            <xsl:when test="$type='byline' or $type='paragraph-byline'">byline</xsl:when>
            <xsl:otherwise>dateline</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:element name="{$blName}">
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$region/@rendition"/></xsl:call-template>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </xsl:element>
      </xsl:when>
      <xsl:when test="$type='long-quote-p' or $type='long-quote-lg'">
        <!-- Abschnitt 5: long-quote-p -> <quote><p>, long-quote-lg ->
             <quote><lg> mit <l> statt <lb/>. Gehoert die Region zu einer
             multi-p-quote-Relation, steht das <quote> schon aussen
             (render-quote-group). -->
        <xsl:choose>
          <xsl:when test="$inQuoteGroup">
            <xsl:call-template name="render-quote-content">
              <xsl:with-param name="id" select="$id"/>
              <xsl:with-param name="depth" select="$depth"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <quote>
              <xsl:if test="$manualIndent">
                <xsl:text>&#10;</xsl:text>
                <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth + 1"/></xsl:call-template>
              </xsl:if>
              <xsl:call-template name="render-quote-content">
                <xsl:with-param name="id" select="$id"/>
                <xsl:with-param name="depth" select="$depth + 1"/>
              </xsl:call-template>
              <xsl:if test="$manualIndent">
                <xsl:text>&#10;</xsl:text>
                <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
              </xsl:if>
            </quote>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:when>
      <xsl:when test="$type='add'">
        <!-- <add> validiert vermutlich nicht direkt in einem div (es ist als
             phrasenwertiges Element gedacht, nicht als Block-Kind) - bewusst
             so gewuenscht, wird manuell nachkorrigiert. Anders als p/head/fw
             steht der Inhalt kompakt in einer Zeile (kein Umbruch/Einrueckung
             direkt nach dem Start- bzw. vor dem Endtag), nur echte <lb/> bei
             mehreren TextLines bleiben erhalten. Bekommt wie jedes <add> eine
             eigene xml:id (Abschnitt 8). -->
        <add>
          <xsl:variable name="foreignIdHit" select="$behelfsMap[@region=$id and contains(@behelfs,'.xml#')]"/>
          <xsl:attribute name="xml:id">
            <xsl:choose>
              <xsl:when test="$foreignIdHit"><xsl:value-of select="$foreignIdHit[1]/@genid"/></xsl:when>
              <xsl:otherwise>add-<xsl:value-of select="$pageNumPadded"/>-<xsl:call-template name="pad4"><xsl:with-param name="s" select="$addOrder[@id=$id]/@seq"/></xsl:call-template></xsl:otherwise>
            </xsl:choose>
          </xsl:attribute>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$region/@rendition"/></xsl:call-template>
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
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <!-- structure{cat:..} (z.B. fol) wird zu @type -->
          <xsl:if test="$region/@cat != ''"><xsl:attribute name="type"><xsl:value-of select="$region/@cat"/></xsl:attribute></xsl:if>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </fw>
      </xsl:when>
      <xsl:otherwise>
        <!-- TEI-All erlaubt @type auf <p> nicht; der Regionstyp bleibt ueber
             @facs an der entsprechenden <zone> im facsimile (Regionstyp dort nicht mehr als @type) nachvollziehbar. -->
        <p>
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:call-template name="rendition-attr-if-any">
            <xsl:with-param name="value" select="$region/@rendition"/>
            <xsl:with-param name="extra"><xsl:if test="$type='paragraph-indent'">indent</xsl:if></xsl:with-param>
          </xsl:call-template>
          <!-- Abschnitt 5: bei type="paragraph" werden ALLE uebrigen
               structure{}-Schluessel/Werte (z.B. part; hand-medium wird ignoriert) 1:1 als
               Attribute uebernommen - anders als bei anderen Regionstypen,
               wo nur die einzeln aufgefuehrten Schluessel (rendition, id)
               durchgereicht werden. -->
          <xsl:if test="$type='paragraph' or $type='paragraph-indent'">
            <xsl:call-template name="paragraph-extra-attrs"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          </xsl:if>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </p>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- das <p> bzw. <lg> einer long-quote-p/long-quote-lg-Region (ohne
       umgebendes <quote>). rendition: der Wert aus structure{rendition:..},
       sonst "long-quote". Bei long-quote-lg steht jede Zeile in einem <l
       facs="..."> statt hinter einem <lb/>: die <lb/> der normal gerenderten
       Zeilen werden dazu zu Zeilen-Containern umgebaut (reicht ein Lauf wie
       del/hi ueber mehrere Zeilen, bleibt das <lb/> darin als Markup stehen,
       weil ein Element nicht auf zwei <l> aufgeteilt werden kann). -->
  <xsl:template name="render-quote-content">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="4"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:variable name="elName">
      <xsl:choose>
        <xsl:when test="$region/@type='long-quote-lg'">lg</xsl:when>
        <xsl:otherwise>p</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:element name="{$elName}">
      <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
      <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
      <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
      <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$region/@rendition"/></xsl:call-template>
      <xsl:choose>
        <xsl:when test="$elName='lg'">
          <xsl:variable name="rawRTF">
            <xsl:call-template name="render-lines">
              <xsl:with-param name="regionId" select="$id"/>
              <xsl:with-param name="depth" select="$depth + 1"/>
              <xsl:with-param name="compact" select="true()"/>
            </xsl:call-template>
          </xsl:variable>
          <xsl:variable name="nodes" select="exsl:node-set($rawRTF)/node()"/>
          <xsl:for-each select="$nodes[self::*[local-name()='lb']]">
            <xsl:variable name="n" select="position()"/>
            <xsl:text>&#10;</xsl:text>
            <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth + 1"/></xsl:call-template>
            <l facs="{@facs}">
              <xsl:copy-of select="$nodes[count(preceding-sibling::*[local-name()='lb']) = $n and not(self::*[local-name()='lb'])]"/>
            </l>
          </xsl:for-each>
          <xsl:text>&#10;</xsl:text>
          <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
        </xsl:when>
        <xsl:otherwise>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:element>
  </xsl:template>

  <!-- Generische Regel (Abschnitt 5): structure{rendition:[Wert];} -> zusaetzlich
       @rendition="#[Wert]" (Pointer auf die rendition-Definition, daher mit
       vorangestelltem "#"). Mehrere Werte (durch \u0020 oder Leerzeichen
       getrennt) werden einzeln mit "#" versehen. $extra ist ein Wert, der
       automatisch ergaenzt wird (z.B. "indent" bei paragraph-indent), aber
       nur einmal vorkommen darf, auch wenn er schon von Hand gesetzt wurde.
       "longquote" wird speziell zu "longQuote". -->
  <xsl:template name="rendition-attr-if-any">
    <xsl:param name="value"/>
    <xsl:param name="extra" select="''"/>
    <xsl:variable name="tokensRTF">
      <xsl:call-template name="rendition-tokens"><xsl:with-param name="s" select="$value"/></xsl:call-template>
      <xsl:if test="$extra != ''"><my:t v="{$extra}"/></xsl:if>
    </xsl:variable>
    <xsl:variable name="tokens" select="exsl:node-set($tokensRTF)/my:t"/>
    <xsl:if test="$tokens">
      <xsl:attribute name="rendition">
        <xsl:for-each select="$tokens">
          <xsl:variable name="v" select="@v"/>
          <xsl:if test="not(preceding-sibling::my:t[@v=$v])">
            <xsl:if test="position() &gt; 1 and count(preceding-sibling::my:t[not(@v = preceding-sibling::my:t/@v)]) &gt; 0"><xsl:text> </xsl:text></xsl:if>
            <xsl:text>#</xsl:text>
            <xsl:choose>
              <xsl:when test="$v='longquote'">longQuote</xsl:when>
              <xsl:otherwise><xsl:value-of select="$v"/></xsl:otherwise>
            </xsl:choose>
          </xsl:if>
        </xsl:for-each>
      </xsl:attribute>
    </xsl:if>
  </xsl:template>

  <!-- zerlegt einen rendition-Wert in Tokens (Trenner: Leerzeichen oder das
       literale \u0020), fuehrendes "#" wird entfernt -->
  <xsl:template name="rendition-tokens">
    <xsl:param name="s"/>
    <xsl:variable name="n" select="normalize-space(translate($s,'&#9;&#10;',' '))"/>
    <xsl:if test="$n != ''">
      <xsl:variable name="normSep">
        <xsl:choose>
          <xsl:when test="contains($n,$sepMarker)"><xsl:value-of select="concat(substring-before($n,$sepMarker),' ',substring-after($n,$sepMarker))"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="$n"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:choose>
        <xsl:when test="contains($n,$sepMarker)">
          <xsl:call-template name="rendition-tokens"><xsl:with-param name="s" select="substring-before($n,$sepMarker)"/></xsl:call-template>
          <xsl:call-template name="rendition-tokens"><xsl:with-param name="s" select="substring-after($n,$sepMarker)"/></xsl:call-template>
        </xsl:when>
        <xsl:when test="contains($n,' ')">
          <xsl:call-template name="rendition-tokens"><xsl:with-param name="s" select="substring-before($n,' ')"/></xsl:call-template>
          <xsl:call-template name="rendition-tokens"><xsl:with-param name="s" select="substring-after($n,' ')"/></xsl:call-template>
        </xsl:when>
        <xsl:otherwise>
          <my:t v="{translate(substring($n, 1 + number(starts-with($n,'#'))), '#', '')}"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:if>
  </xsl:template>

  <!-- vergibt eine xml:id fuer ein <p> nur dann, wenn seine Region tatsaechlich
       eine Behelfs-ID traegt (also von woanders referenziert wird) - siehe
       $behelfsOrder/$behelfsMap oben. Andere <p> bleiben ohne xml:id. -->
  <xsl:template name="behelfs-id-attr-if-any">
    <xsl:param name="regionId"/>
    <xsl:variable name="hit" select="$behelfsMap[@region=$regionId]"/>
    <xsl:if test="$hit">
      <xsl:attribute name="xml:id"><xsl:value-of select="$hit[1]/@genid"/></xsl:attribute>
    </xsl:if>
  </xsl:template>

  <!-- Abschnitt 5: fuer type="paragraph" werden alle structure{}-Schluessel
       AUSSER den bereits anderswo behandelten (type/subtype/composit-order/
       rendition/id/function/target) sowie hand-medium (bewusst ignoriert) 1:1 als
       Attribute auf dem <p> ausgegeben (z.B. part). -->
  <xsl:template name="paragraph-extra-attrs">
    <xsl:param name="regionId"/>
    <xsl:variable name="src" select="$allRegions[@id=$regionId]"/>
    <xsl:variable name="inner">
      <xsl:call-template name="block-content">
        <xsl:with-param name="custom" select="$src/@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="pairsRTF">
      <xsl:call-template name="all-key-value-pairs"><xsl:with-param name="tokens" select="$inner"/></xsl:call-template>
    </xsl:variable>
    <xsl:for-each select="exsl:node-set($pairsRTF)/my:kv[@name != 'type' and @name != 'subtype' and @name != 'composit-order' and @name != 'rendition' and @name != 'id' and @name != 'function' and @name != 'target' and @name != 'hand-medium' and @name != 'fixed-lines' and @name != 'single-p-article' and @name != 'prev' and @name != 'next' and @name != 'change']">
      <xsl:attribute name="{@name}"><xsl:value-of select="@value"/></xsl:attribute>
    </xsl:for-each>
    <!-- prev/next sind Behelfs-ID-Verweise (Abschnitt 8) -->
    <xsl:for-each select="exsl:node-set($pairsRTF)/my:kv[@name='prev' or @name='next']">
      <xsl:attribute name="{@name}">
        <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="@value"/></xsl:call-template>
      </xsl:attribute>
    </xsl:for-each>
  </xsl:template>

  <!-- zerlegt "key1:val1; key2:val2; ..." (Inhalt EINES Blocks, z.B. schon
       aus block-content) in ALLE Schluessel/Wert-Paare -->
  <xsl:template name="all-key-value-pairs">
    <xsl:param name="tokens"/>
    <xsl:if test="normalize-space($tokens) != ''">
      <xsl:variable name="first">
        <xsl:choose>
          <xsl:when test="contains($tokens,';')"><xsl:value-of select="substring-before($tokens,';')"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="$tokens"/></xsl:otherwise>
        </xsl:choose>
      </xsl:variable>
      <xsl:variable name="trimmed"><xsl:call-template name="trim"><xsl:with-param name="s" select="$first"/></xsl:call-template></xsl:variable>
      <xsl:if test="contains($trimmed,':')">
        <my:kv name="{substring-before($trimmed,':')}" value="{substring-after($trimmed,':')}"/>
      </xsl:if>
      <xsl:if test="contains($tokens,';')">
        <xsl:call-template name="all-key-value-pairs">
          <xsl:with-param name="tokens" select="substring-after($tokens,';')"/>
        </xsl:call-template>
      </xsl:if>
    </xsl:if>
  </xsl:template>

  <xsl:template name="render-metamark">
    <xsl:param name="id"/>
    <xsl:param name="depth" select="4"/>
    <xsl:variable name="region" select="$regions[@id=$id]"/>
    <xsl:variable name="seqPadded">
      <xsl:call-template name="pad4">
        <xsl:with-param name="s" select="$metamarkOrder[@id=$id]/@seq"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="foreignIdHit" select="$behelfsMap[@region=$id and contains(@behelfs,'.xml#')]"/>
    <xsl:variable name="ownId">
      <xsl:choose>
        <xsl:when test="$foreignIdHit"><xsl:value-of select="$foreignIdHit[1]/@genid"/></xsl:when>
        <xsl:otherwise>metamark-<xsl:value-of select="$pageNumPadded"/>-<xsl:value-of select="$seqPadded"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <!-- Abschnitt 7: function="insertion" + @target zieht das referenzierte
         Element hier ein (analog metamark-add), ausser diese Region ist
         selbst nur Zwischenglied einer Kette ($chainConsumedMetamarks) -
         dann normal rendern (siehe Kommentar bei $chainConsumedMetamarks). -->
    <xsl:variable name="isChainInitiator" select="$region/@function='insertion' and $region/@target != '' and not($chainConsumedMetamarks[@id=$id])"/>
    <xsl:variable name="chainTargetRegionId" select="$insertionChainResolutions[@kind='region' and @id=$id]/@target"/>
    <xsl:choose>
      <xsl:when test="$isChainInitiator and ($regions[@id=$chainTargetRegionId]/@type='add')">
        <metamark facs="{concat('#zone_',$id)}" function="insertion">
          <xsl:attribute name="xml:id"><xsl:value-of select="$ownId"/></xsl:attribute>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$region/@rendition"/></xsl:call-template>
          <xsl:call-template name="foreign-target-attr"><xsl:with-param name="target" select="$region/@target"/></xsl:call-template>
        </metamark>
        <xsl:call-template name="render-imported-add">
          <xsl:with-param name="addRegionId" select="$chainTargetRegionId"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <!-- Abschnitt 7a "Metamark-Regionen plus Textstring-Kuerzel": der Text
             der Region wird normal gerendert (Kuerzel wie #del/#ker/... und
             "|" werden dabei zu je einer eigenen <metamark><g/></metamark>).
             Hier werden diese erzeugten inneren <metamark> aufgeloest: nur das
             <g> bleibt stehen, und das Kuerzel bestimmt die @function der
             Regionen-<metamark> (eine in structure{} angegebene function hat
             Vorrang). -->
        <!-- metamark-deleatur ohne eigenen Text: Inhalt (g-Zeichen) wird automatisch
             erzeugt und steht direkt hinter dem <lb/> -->
        <xsl:variable name="mmHasText"><xsl:call-template name="region-has-own-text"><xsl:with-param name="regionId" select="$id"/></xsl:call-template></xsl:variable>
        <xsl:variable name="mmAuto" select="$region/@deleatur='true' and $mmHasText != 'true'"/>
        <xsl:variable name="contentRTF">
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
            <xsl:with-param name="trailing" select="not($mmAuto)"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:variable name="content" select="exsl:node-set($contentRTF)"/>
        <xsl:variable name="shortcutFn" select="string($content//*[local-name()='metamark' and not(@*[local-name()!='function']) and count(*)=1 and *[local-name()='g'] and normalize-space(.)='' and @function != 'intervention'][1]/@function)"/>
        <metamark>
          <xsl:attribute name="xml:id"><xsl:value-of select="$ownId"/></xsl:attribute>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$region/@rendition"/></xsl:call-template>
          <xsl:choose>
            <xsl:when test="$region/@function != ''">
              <xsl:attribute name="function"><xsl:value-of select="$region/@function"/></xsl:attribute>
            </xsl:when>
            <xsl:when test="$shortcutFn != ''">
              <xsl:attribute name="function"><xsl:value-of select="$shortcutFn"/></xsl:attribute>
            </xsl:when>
          </xsl:choose>
          <xsl:if test="$region/@target != ''">
            <xsl:attribute name="target">
              <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$region/@target"/></xsl:call-template>
            </xsl:attribute>
          </xsl:if>
          <xsl:apply-templates select="$content/node()" mode="mm-unwrap"/>
          <!-- metamark-deleatur ohne eigenen Text: Inhalt wird automatisch erzeugt -->
          <xsl:if test="$mmAuto">
            <g ref="#intervention"/><xsl:text> </xsl:text><g ref="#deleatur"/>
            <xsl:text>&#10;</xsl:text>
            <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
          </xsl:if>
        </metamark>
      </xsl:otherwise>
    </xsl:choose>
    <!-- Falls eine annotation-Zone wider Erwarten eigene Kind-Zonen hat (in
         den vorliegenden Dateien nicht beobachtet): einfach danach ausgeben.
         Das umgeht die Mixing-Pruefung der eigentlichen Elternebene - fuer
         diesen Randfall bewusst vereinfacht. -->
    <xsl:call-template name="render-children-text">
      <xsl:with-param name="id" select="$id"/>
      <xsl:with-param name="depth" select="$depth"/>
    </xsl:call-template>
  </xsl:template>

  <!-- Abschnitt 7a: Identitaets-Transformation, die vom Text-Kuerzel erzeugte
       <metamark function=".."><g/></metamark> (genau ein <g>, kein Text, nur
       @function) durch das nackte <g/> ersetzt -->
  <xsl:template match="*[local-name()='metamark' and not(@*[local-name()!='function']) and count(*)=1 and *[local-name()='g'] and normalize-space(.)='']" mode="mm-unwrap">
    <xsl:copy-of select="*[local-name()='g']"/>
  </xsl:template>
  <xsl:template match="*" mode="mm-unwrap">
    <xsl:copy>
      <xsl:copy-of select="@*"/>
      <xsl:apply-templates select="node()" mode="mm-unwrap"/>
    </xsl:copy>
  </xsl:template>
  <xsl:template match="text()|comment()|processing-instruction()" mode="mm-unwrap">
    <xsl:copy/>
  </xsl:template>

  <!-- die einer Region per $lineAssign zugeordneten Zeilen, sortiert nach
       (Index der urspruenglichen Elternregion, eigener Zeilen-Index), als
       eigenstaendige Kopien (damit sie als normaler Node-Set indizierbar
       sind statt nur als Verweise auf die Originalknoten) -->
  <xsl:template name="ordered-lines-for-region">
    <xsl:param name="regionId"/>
    <xsl:for-each select="$lineAssign[@region=$regionId]">
      <xsl:sort select="number(@rank)" data-type="number"/>
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
    <!-- trailing=false: kein Umbruch/Einrueckung nach der letzten Zeile (fuer
         eigenen Text direkt in einem <p> mit nachfolgenden Kindern) -->
    <xsl:param name="trailing" select="true()"/>
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
    <xsl:if test="not($compact) and $trailing">
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
    <!-- fromOffset (nur bei Wiederaufnahme nach einem zeilenuebergreifenden
         Element, siehe ml-render-open): die Zeile ist schon begonnen (lb steht),
         verarbeitet wird nur der Rest ab diesem Zeichenversatz -->
    <xsl:param name="fromOffset" select="''"/>
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

      <xsl:variable name="from" select="number(concat('0', $fromOffset))"/>
      <xsl:if test="$fromOffset = ''">
        <xsl:if test="not($compact)">
          <xsl:text>&#10;</xsl:text>
          <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
        </xsl:if>
        <lb facs="#zone_{$line/@id}"/>
      </xsl:if>

      <xsl:choose>
        <xsl:when test="not($ranges)">
          <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($text, $from + 1)"/></xsl:call-template>
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
              <xsl:if test="number($ranges[@idx=current()/@idx]/@offset) &gt;= $from"><my:child idx="{@idx}"/></xsl:if>
            </xsl:for-each>
          </xsl:variable>
          <xsl:variable name="topOrdered" select="exsl:node-set($topOrderedRTF)/my:child"/>
          <xsl:variable name="lastTopIdx" select="$topOrdered[last()]/@idx"/>
          <xsl:variable name="lastTop" select="$ranges[@idx=$lastTopIdx]"/>
          <!-- zeilenuebergreifendes Element (continued:true), auch mit Kindern:
               siehe ml-open / ml-render-open -->
          <xsl:variable name="lastTopOpen">
            <xsl:if test="$lastTop">
              <xsl:call-template name="ml-open">
                <xsl:with-param name="lines" select="$lines"/>
                <xsl:with-param name="index" select="$index"/>
                <xsl:with-param name="rangeIdx" select="string($lastTopIdx)"/>
              </xsl:call-template>
            </xsl:if>
          </xsl:variable>

          <xsl:choose>
            <!-- Das letzte oberste Element laeuft ueber die Zeilengrenze (continued:true,
                 Fortsetzung auf der Folgezeile bei offset:0): EIN Element, das <lb/> als
                 Kind enthaelt - auch wenn es Kinder hat, solange diese innerhalb des
                 Elements beginnen und enden (siehe ml-open). undo und del/deselection-
                 Ketten sind Meilenstein-Paare und nie betroffen. -->
            <xsl:when test="$lastTopOpen='yes'">
              <xsl:variable name="endRTF">
                <xsl:call-template name="ml-chain-end">
                  <xsl:with-param name="lines" select="$lines"/>
                  <xsl:with-param name="index" select="$index"/>
                  <xsl:with-param name="rangeIdx" select="string($lastTopIdx)"/>
                </xsl:call-template>
              </xsl:variable>
              <xsl:variable name="chainEnd" select="exsl:node-set($endRTF)/my:end"/>
              <!-- alle obersten Bereiche ausser dem letzten normal ausgeben -->
              <xsl:call-template name="render-children-seq">
                <xsl:with-param name="ranges" select="$ranges"/>
                <xsl:with-param name="rangeParents" select="$rangeParents"/>
                <xsl:with-param name="ordered" select="$topOrdered[position() &lt; last()]"/>
                <xsl:with-param name="pos" select="1"/>
                <xsl:with-param name="cursor" select="$from"/>
                <xsl:with-param name="spanEnd" select="number($lastTop/@offset)"/>
                <xsl:with-param name="text" select="$text"/>
                <xsl:with-param name="lineId" select="$line/@id"/>
              </xsl:call-template>
              <xsl:call-template name="ml-render-open">
                <xsl:with-param name="lines" select="$lines"/>
                <xsl:with-param name="index" select="$index"/>
                <xsl:with-param name="rangeIdx" select="string($lastTopIdx)"/>
                <xsl:with-param name="depth" select="$depth"/>
                <xsl:with-param name="compact" select="$compact"/>
              </xsl:call-template>
              <!-- Rest der Endzeile hinter dem Element, dann weiter -->
              <xsl:call-template name="process-line">
                <xsl:with-param name="lines" select="$lines"/>
                <xsl:with-param name="index" select="number($chainEnd/@index)"/>
                <xsl:with-param name="depth" select="$depth"/>
                <xsl:with-param name="compact" select="$compact"/>
                <xsl:with-param name="fromOffset" select="string($chainEnd/@offset)"/>
              </xsl:call-template>
            </xsl:when>
            <xsl:otherwise>
              <xsl:call-template name="render-children-seq">
                <xsl:with-param name="ranges" select="$ranges"/>
                <xsl:with-param name="rangeParents" select="$rangeParents"/>
                <xsl:with-param name="ordered" select="$topOrdered"/>
                <xsl:with-param name="pos" select="1"/>
                <xsl:with-param name="cursor" select="$from"/>
                <xsl:with-param name="spanEnd" select="string-length($text)"/>
                <xsl:with-param name="text" select="$text"/>
                <xsl:with-param name="lineId" select="$line/@id"/>
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

  <!-- ===================== zeilenuebergreifende Elemente (continued:true) =====================
       Ein Block mit continued:true, der bis zum Zeilenende reicht und auf der
       Folgezeile bei offset:0 ein gleichartiges Stueck (gleiches Element, gleiche
       Attribute) hat, wird EIN Element, das <lb/> als Kind enthaelt - auch wenn
       er Kinder hat. Voraussetzung (sonst bleibt es bei je einem Element pro
       Zeile): die Kinder beginnen und enden immer innerhalb des Elements, d.h.
       jeder Elternbereich eines solchen Stuecks setzt sich seinerseits mit dem
       Elternstueck der Folgezeile fort (oberste Stuecke: beide ohne Elternteil).
       Pro Zeile wird immer in den Zeilenkoordinaten der Quelle gearbeitet, damit
       alle zeilenbezogenen Nachschlagetabellen (ids, Ketten, ...) gelten. -->

  <!-- Bereiche + Elternbeziehungen einer Zeile in einem Rutsch -->
  <xsl:template name="ml-line-data">
    <xsl:param name="line"/>
    <xsl:variable name="mlR"><xsl:call-template name="parse-line-ranges"><xsl:with-param name="line" select="$line"/></xsl:call-template></xsl:variable>
    <xsl:variable name="mlRs" select="exsl:node-set($mlR)/my:range"/>
    <xsl:copy-of select="$mlRs"/>
    <xsl:call-template name="build-range-parents"><xsl:with-param name="ranges" select="$mlRs"/></xsl:call-template>
  </xsl:template>

  <!-- Attribut-Signatur eines Bereichs (ohne id/subst-id/del-id/prev/next) -->
  <xsl:template name="ml-sig">
    <xsl:param name="range"/>
    <xsl:for-each select="$range/my:attr[@name != 'id' and @name != 'subst-id' and @name != 'del-id' and @name != 'prev' and @name != 'next']">
      <xsl:sort select="@name"/>
      <xsl:value-of select="concat(@name,'=',@value,';')"/>
    </xsl:for-each>
  </xsl:template>

  <!-- idx des Fortsetzungsstuecks auf der Folgezeile (oder leer) -->
  <xsl:template name="ml-cont">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="rangeIdx"/>
    <xsl:if test="$index &lt; count($lines)">
      <xsl:variable name="mlD"><xsl:call-template name="ml-line-data"><xsl:with-param name="line" select="$lines[$index]"/></xsl:call-template></xsl:variable>
      <xsl:variable name="mlX" select="exsl:node-set($mlD)/my:range[@idx=$rangeIdx]"/>
      <xsl:variable name="mlXSig"><xsl:call-template name="ml-sig"><xsl:with-param name="range" select="$mlX"/></xsl:call-template></xsl:variable>
      <xsl:variable name="mlN"><xsl:call-template name="ml-line-data"><xsl:with-param name="line" select="$lines[$index + 1]"/></xsl:call-template></xsl:variable>
      <xsl:variable name="mlMatchRTF">
        <xsl:for-each select="exsl:node-set($mlN)/my:range[number(@offset)=0 and @element=$mlX/@element]">
          <xsl:variable name="mlCSig"><xsl:call-template name="ml-sig"><xsl:with-param name="range" select="."/></xsl:call-template></xsl:variable>
          <xsl:if test="string($mlCSig)=string($mlXSig)"><my:m idx="{@idx}"/></xsl:if>
        </xsl:for-each>
      </xsl:variable>
      <xsl:value-of select="exsl:node-set($mlMatchRTF)/my:m[1]/@idx"/>
    </xsl:if>
  </xsl:template>

  <!-- "yes", wenn das Stueck (Zeile index, Bereich rangeIdx) ueber die Zeilengrenze laeuft -->
  <xsl:template name="ml-open">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="rangeIdx"/>
    <xsl:variable name="mlLine" select="$lines[$index]"/>
    <xsl:variable name="mlD"><xsl:call-template name="ml-line-data"><xsl:with-param name="line" select="$mlLine"/></xsl:call-template></xsl:variable>
    <xsl:variable name="mlRs" select="exsl:node-set($mlD)/my:range"/>
    <xsl:variable name="mlRp" select="exsl:node-set($mlD)/my:rp"/>
    <xsl:variable name="mlX" select="$mlRs[@idx=$rangeIdx]"/>
    <xsl:variable name="mlText" select="$mlLine/*[local-name()='TextEquiv'][1]/*[local-name()='Unicode']"/>
    <xsl:if test="$mlX/@continued='true' and $index &lt; count($lines)
                  and normalize-space(substring($mlText, number($mlX/@end) + 1)) = ''
                  and not($mlX/@element='undo' or $mlX/@element='subst' or $mlX/@element='metamark-add-synth' or $mlX/@element='choice-sic-synth' or $mlX/@element='gap')
                  and not($mlX/@element='del' and $deselMarkers[@line=$mlLine/@id and number(@offset)=number($mlX/@offset)])
                  and not($mlX/@element='add' and $consumedLineAdds[@line=$mlLine/@id and number(@offset)=number($mlX/@offset)])
                  and not($mlX/@element='metamark' and $mlX/my:attr[@name='function']/@value='insertion' and $mlX/my:attr[@name='target'])">
      <xsl:variable name="mlContIdx"><xsl:call-template name="ml-cont"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$rangeIdx"/></xsl:call-template></xsl:variable>
      <xsl:if test="$mlContIdx != ''">
        <xsl:variable name="mlNd"><xsl:call-template name="ml-line-data"><xsl:with-param name="line" select="$lines[$index + 1]"/></xsl:call-template></xsl:variable>
        <xsl:variable name="mlParent" select="string($mlRp[@idx=$rangeIdx]/@parent)"/>
        <xsl:variable name="mlContParent" select="string(exsl:node-set($mlNd)/my:rp[@idx=$mlContIdx]/@parent)"/>
        <xsl:choose>
          <xsl:when test="$mlParent = '0'"><xsl:if test="$mlContParent = '0'">yes</xsl:if></xsl:when>
          <xsl:otherwise>
            <xsl:variable name="mlPOpen"><xsl:call-template name="ml-open"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$mlParent"/></xsl:call-template></xsl:variable>
            <xsl:variable name="mlPCont"><xsl:call-template name="ml-cont"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$mlParent"/></xsl:call-template></xsl:variable>
            <xsl:if test="$mlPOpen = 'yes' and string($mlPCont) = $mlContParent">yes</xsl:if>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:if>
    </xsl:if>
  </xsl:template>

  <!-- Ende der Kette: <my:end index=".." idx=".." offset=".."/> (letzte Zeile
       samt Stueck und dessen Ende) -->
  <xsl:template name="ml-chain-end">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="rangeIdx"/>
    <xsl:variable name="mlOpenX"><xsl:call-template name="ml-open"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$rangeIdx"/></xsl:call-template></xsl:variable>
    <xsl:choose>
      <xsl:when test="$mlOpenX = 'yes'">
        <xsl:variable name="mlNextIdx"><xsl:call-template name="ml-cont"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$rangeIdx"/></xsl:call-template></xsl:variable>
        <xsl:call-template name="ml-chain-end">
          <xsl:with-param name="lines" select="$lines"/>
          <xsl:with-param name="index" select="$index + 1"/>
          <xsl:with-param name="rangeIdx" select="string($mlNextIdx)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="mlD"><xsl:call-template name="ml-line-data"><xsl:with-param name="line" select="$lines[$index]"/></xsl:call-template></xsl:variable>
        <my:end index="{$index}" idx="{$rangeIdx}" offset="{exsl:node-set($mlD)/my:range[@idx=$rangeIdx]/@end}"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- das Stueck der Kette nach $steps Fortsetzungen: idx auf der Zeile index+steps -->
  <xsl:template name="ml-chain-piece">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="rangeIdx"/>
    <xsl:param name="steps"/>
    <xsl:choose>
      <xsl:when test="$steps &gt; 0">
        <xsl:variable name="mlNextIdx"><xsl:call-template name="ml-cont"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$rangeIdx"/></xsl:call-template></xsl:variable>
        <xsl:call-template name="ml-chain-piece">
          <xsl:with-param name="lines" select="$lines"/>
          <xsl:with-param name="index" select="$index + 1"/>
          <xsl:with-param name="rangeIdx" select="string($mlNextIdx)"/>
          <xsl:with-param name="steps" select="$steps - 1"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$rangeIdx"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- gibt das zeilenuebergreifende Element aus: Start-Tag mit Attributen des
       ersten Stuecks, Inhalt ueber alle Zeilen (ml-content), Ende-Tag -->
  <xsl:template name="ml-render-open">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="rangeIdx"/>
    <xsl:param name="depth"/>
    <xsl:param name="compact" select="false()"/>
    <xsl:variable name="mlLine" select="$lines[$index]"/>
    <xsl:variable name="mlD"><xsl:call-template name="ml-line-data"><xsl:with-param name="line" select="$mlLine"/></xsl:call-template></xsl:variable>
    <xsl:variable name="mlRange" select="exsl:node-set($mlD)/my:range[@idx=$rangeIdx]"/>
    <xsl:variable name="mlAttrs" select="$mlRange/my:attr"/>
    <xsl:choose>
      <!-- mehrzeiliges subst-del (Abschnitt 7): EIN <subst> mit EINEM
           (mehrzeiligen) <del> und dem importierten <add> nur EINMAL (am Ende) -->
      <xsl:when test="$mlRange/@element='subst-del-synth'">
        <subst>
          <xsl:call-template name="subst-id-attr"><xsl:with-param name="range" select="$mlRange"/><xsl:with-param name="lineId" select="string($mlLine/@id)"/></xsl:call-template>
          <xsl:call-template name="range-change-attr"><xsl:with-param name="range" select="$mlRange"/></xsl:call-template>
          <del>
            <xsl:variable name="mlDelIdB" select="$mlAttrs[@name='del-id']/@value"/>
            <xsl:if test="$mlDelIdB != ''">
              <xsl:variable name="mlDelIdHit" select="$behelfsMap[@behelfs=$mlDelIdB]"/>
              <xsl:if test="$mlDelIdHit">
                <xsl:attribute name="xml:id"><xsl:value-of select="$mlDelIdHit[1]/@genid"/></xsl:attribute>
              </xsl:if>
            </xsl:if>
            <xsl:if test="$mlAttrs[@name='del-cat']">
              <xsl:attribute name="type"><xsl:value-of select="$mlAttrs[@name='del-cat']/@value"/></xsl:attribute>
            </xsl:if>
            <xsl:call-template name="ml-content">
              <xsl:with-param name="lines" select="$lines"/>
              <xsl:with-param name="index" select="$index"/>
              <xsl:with-param name="rangeIdx" select="$rangeIdx"/>
              <xsl:with-param name="depth" select="$depth"/>
              <xsl:with-param name="compact" select="$compact"/>
              <xsl:with-param name="cursor" select="number($mlRange/@offset)"/>
            </xsl:call-template>
          </del>
          <xsl:variable name="mlSdAddIdsRTF">
            <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="$mlAttrs[@name='add-id']/@value"/></xsl:call-template>
          </xsl:variable>
          <xsl:for-each select="exsl:node-set($mlSdAddIdsRTF)/my:tok">
            <xsl:call-template name="render-imported-add">
              <xsl:with-param name="behelfsId" select="@val"/>
              <xsl:with-param name="lineId" select="string($mlLine/@id)"/>
            </xsl:call-template>
          </xsl:for-each>
        </subst>
        <!-- faellt das Ende eines deselection-Bereichs mit dem Ende dieses
             subst zusammen, steht dessen <anchor> hinter dem </subst> (wie beim
             einzeiligen subst-del); massgeblich ist das LETZTE Stueck -->
        <xsl:variable name="mlSdEndRTF">
          <xsl:call-template name="ml-chain-end"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$rangeIdx"/></xsl:call-template>
        </xsl:variable>
        <xsl:variable name="mlSdEnd" select="exsl:node-set($mlSdEndRTF)/my:end"/>
        <xsl:variable name="mlSdD"><xsl:call-template name="ml-line-data"><xsl:with-param name="line" select="$lines[number($mlSdEnd/@index)]"/></xsl:call-template></xsl:variable>
        <xsl:variable name="mlSdPending">
          <xsl:call-template name="pending-anchor-id-for">
            <xsl:with-param name="ranges" select="exsl:node-set($mlSdD)/my:range"/>
            <xsl:with-param name="rangeParents" select="exsl:node-set($mlSdD)/my:rp"/>
            <xsl:with-param name="myIdx" select="string($mlSdEnd/@idx)"/>
            <xsl:with-param name="lineId" select="string($lines[number($mlSdEnd/@index)]/@id)"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:if test="$mlSdPending != ''"><xsl:call-template name="desel-end-anchor"><xsl:with-param name="id" select="$mlSdPending"/></xsl:call-template></xsl:if>
      </xsl:when>
      <xsl:otherwise>
    <xsl:element name="{$mlRange/@element}">
      <xsl:if test="$mlAttrs[@name='id']">
        <xsl:variable name="declHit" select="$behelfsMap[@behelfs=$mlAttrs[@name='id']/@value]"/>
        <xsl:variable name="firstDecl" select="$allLineRanges[my:attr[@name='id']/@value=$mlAttrs[@name='id']/@value][1]"/>
        <xsl:if test="$declHit and $firstDecl/@line=$mlLine/@id and $firstDecl/@offset=$mlRange/@offset"><xsl:attribute name="xml:id"><xsl:value-of select="$declHit[1]/@genid"/></xsl:attribute></xsl:if>
      </xsl:if>
      <xsl:for-each select="$mlAttrs[@name != 'add-id' and @name != 'del-id' and @name != 'id' and @name != 'target' and @name != 'corresp' and @name != 'rendition' and @name != 'prev' and @name != 'next']">
        <xsl:attribute name="{@name}"><xsl:value-of select="@value"/></xsl:attribute>
      </xsl:for-each>
      <xsl:call-template name="resolved-ref-attrs"><xsl:with-param name="attrs" select="$mlAttrs"/></xsl:call-template>
      <xsl:if test="$mlAttrs[@name='target']">
        <xsl:attribute name="target">
          <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$mlAttrs[@name='target']/@value"/></xsl:call-template>
        </xsl:attribute>
      </xsl:if>
      <xsl:call-template name="ml-content">
        <xsl:with-param name="lines" select="$lines"/>
        <xsl:with-param name="index" select="$index"/>
        <xsl:with-param name="rangeIdx" select="$rangeIdx"/>
        <xsl:with-param name="depth" select="$depth"/>
        <xsl:with-param name="compact" select="$compact"/>
        <xsl:with-param name="cursor" select="number($mlRange/@offset)"/>
      </xsl:call-template>
    </xsl:element>
    <xsl:if test="$mlRange/@element='seg' and $mlAttrs[@name='type']/@value='transposition'">
      <xsl:call-template name="render-transpose-mark">
        <xsl:with-param name="lineId" select="string($mlLine/@id)"/>
        <xsl:with-param name="offset" select="$mlRange/@offset"/>
      </xsl:call-template>
    </xsl:if>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Inhalt eines Stuecks (Zeile index, Bereich rangeIdx) ab Zeichenversatz cursor.
       Laeuft das letzte Kind selbst ueber die Zeilengrenze, wird es (samt seinen
       <lb/>) ausgegeben und danach beim Elternstueck der Endzeile des Kindes
       fortgefahren; sonst folgt, wenn das Stueck selbst weiterlaeuft, das
       <lb/> der Folgezeile und deren Inhalt. -->
  <xsl:template name="ml-content">
    <xsl:param name="lines"/>
    <xsl:param name="index"/>
    <xsl:param name="rangeIdx"/>
    <xsl:param name="depth"/>
    <xsl:param name="compact" select="false()"/>
    <xsl:param name="cursor"/>
    <xsl:variable name="mlLine" select="$lines[$index]"/>
    <xsl:variable name="mlText" select="$mlLine/*[local-name()='TextEquiv'][1]/*[local-name()='Unicode']"/>
    <xsl:variable name="mlD"><xsl:call-template name="ml-line-data"><xsl:with-param name="line" select="$mlLine"/></xsl:call-template></xsl:variable>
    <xsl:variable name="mlRs" select="exsl:node-set($mlD)/my:range"/>
    <xsl:variable name="mlRp" select="exsl:node-set($mlD)/my:rp"/>
    <xsl:variable name="mlP" select="$mlRs[@idx=$rangeIdx]"/>
    <xsl:variable name="mlKidsRTF">
      <xsl:for-each select="$mlRp[@parent=$rangeIdx]">
        <xsl:sort select="number($mlRs[@idx=current()/@idx]/@offset)" data-type="number"/>
        <xsl:if test="number($mlRs[@idx=current()/@idx]/@offset) &gt;= number($cursor)"><my:child idx="{@idx}"/></xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="mlKids" select="exsl:node-set($mlKidsRTF)/my:child"/>
    <xsl:variable name="mlLastKid" select="$mlRs[@idx=$mlKids[last()]/@idx]"/>
    <xsl:variable name="mlPOpen"><xsl:call-template name="ml-open"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$rangeIdx"/></xsl:call-template></xsl:variable>
    <xsl:variable name="mlKidOpen">
      <xsl:if test="$mlPOpen = 'yes' and $mlLastKid">
        <xsl:call-template name="ml-open"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="string($mlLastKid/@idx)"/></xsl:call-template>
      </xsl:if>
    </xsl:variable>
    <xsl:choose>
      <xsl:when test="$mlKidOpen = 'yes'">
        <xsl:call-template name="render-children-seq">
          <xsl:with-param name="ranges" select="$mlRs"/>
          <xsl:with-param name="rangeParents" select="$mlRp"/>
          <xsl:with-param name="ordered" select="$mlKids[position() &lt; last()]"/>
          <xsl:with-param name="pos" select="1"/>
          <xsl:with-param name="cursor" select="number($cursor)"/>
          <xsl:with-param name="spanEnd" select="number($mlLastKid/@offset)"/>
          <xsl:with-param name="text" select="$mlText"/>
          <xsl:with-param name="lineId" select="$mlLine/@id"/>
        </xsl:call-template>
        <xsl:call-template name="ml-render-open">
          <xsl:with-param name="lines" select="$lines"/>
          <xsl:with-param name="index" select="$index"/>
          <xsl:with-param name="rangeIdx" select="string($mlLastKid/@idx)"/>
          <xsl:with-param name="depth" select="$depth"/>
          <xsl:with-param name="compact" select="$compact"/>
        </xsl:call-template>
        <!-- hier endet das Kind; das Elternstueck laeuft auf dessen Endzeile weiter -->
        <xsl:variable name="mlEndRTF">
          <xsl:call-template name="ml-chain-end"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="string($mlLastKid/@idx)"/></xsl:call-template>
        </xsl:variable>
        <xsl:variable name="mlEnd" select="exsl:node-set($mlEndRTF)/my:end"/>
        <xsl:variable name="mlParentPiece">
          <xsl:call-template name="ml-chain-piece">
            <xsl:with-param name="lines" select="$lines"/>
            <xsl:with-param name="index" select="$index"/>
            <xsl:with-param name="rangeIdx" select="$rangeIdx"/>
            <xsl:with-param name="steps" select="number($mlEnd/@index) - number($index)"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:call-template name="ml-content">
          <xsl:with-param name="lines" select="$lines"/>
          <xsl:with-param name="index" select="number($mlEnd/@index)"/>
          <xsl:with-param name="rangeIdx" select="string($mlParentPiece)"/>
          <xsl:with-param name="depth" select="$depth"/>
          <xsl:with-param name="compact" select="$compact"/>
          <xsl:with-param name="cursor" select="number($mlEnd/@offset)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="render-children-seq">
          <xsl:with-param name="ranges" select="$mlRs"/>
          <xsl:with-param name="rangeParents" select="$mlRp"/>
          <xsl:with-param name="ordered" select="$mlKids"/>
          <xsl:with-param name="pos" select="1"/>
          <xsl:with-param name="cursor" select="number($cursor)"/>
          <xsl:with-param name="spanEnd">
            <xsl:choose>
              <xsl:when test="$mlPOpen = 'yes'"><xsl:value-of select="string-length($mlText)"/></xsl:when>
              <xsl:otherwise><xsl:value-of select="$mlP/@end"/></xsl:otherwise>
            </xsl:choose>
          </xsl:with-param>
          <xsl:with-param name="text" select="$mlText"/>
          <xsl:with-param name="lineId" select="$mlLine/@id"/>
        </xsl:call-template>
        <xsl:if test="$mlPOpen = 'yes'">
          <xsl:variable name="mlContIdx"><xsl:call-template name="ml-cont"><xsl:with-param name="lines" select="$lines"/><xsl:with-param name="index" select="$index"/><xsl:with-param name="rangeIdx" select="$rangeIdx"/></xsl:call-template></xsl:variable>
          <xsl:if test="not($compact)">
            <xsl:text>&#10;</xsl:text>
            <xsl:call-template name="indent"><xsl:with-param name="depth" select="$depth"/></xsl:call-template>
          </xsl:if>
          <lb facs="#zone_{$lines[$index + 1]/@id}"/>
          <xsl:call-template name="ml-content">
            <xsl:with-param name="lines" select="$lines"/>
            <xsl:with-param name="index" select="$index + 1"/>
            <xsl:with-param name="rangeIdx" select="string($mlContIdx)"/>
            <xsl:with-param name="depth" select="$depth"/>
            <xsl:with-param name="compact" select="$compact"/>
            <xsl:with-param name="cursor" select="0"/>
          </xsl:call-template>
        </xsl:if>
      </xsl:otherwise>
    </xsl:choose>
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
    <xsl:variable name="text" select="$line/*[local-name()='TextEquiv'][1]/*[local-name()='Unicode']"/>
    <xsl:for-each select="$blocks[not(@name='head-run-in' and not(contains(@content,'offset'))) and (@name='head-run-in' or @name='dateline' or @name='seg-relocation' or @name='hi' or @name='retrace' or @name='spacing' or @name='hi-spacing' or @name='bold' or @name='hi-bold' or @name='underline' or @name='hi-underline' or @name='hi-latin' or @name='mod-underline' or @name='del' or @name='deselection' or @name='mod' or @name='seg-transposition' or @name='seg' or @name='gap' or @name='gap-cut' or @name='gap-ill' or @name='add' or @name='metamark' or @name='metamark-add' or @name='unclear' or @name='subst' or @name='subst-del' or @name='sic' or @name='undo')]">
      <xsl:variable name="name" select="@name"/>
      <xsl:variable name="content" select="@content"/>
      <xsl:variable name="offset"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'offset'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="length"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'length'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="continued"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'continued'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="element">
        <xsl:choose>
          <xsl:when test="$name='hi' or $name='spacing' or $name='hi-spacing' or $name='bold' or $name='hi-bold' or $name='underline' or $name='hi-underline' or $name='hi-latin'">hi</xsl:when>
          <xsl:when test="$name='retrace'">retrace</xsl:when>
          <xsl:when test="$name='mod-underline'">mod</xsl:when>
          <xsl:when test="$name='del' or $name='deselection'">del</xsl:when>
          <xsl:when test="$name='mod'">mod</xsl:when>
          <xsl:when test="$name='seg' or $name='seg-transposition' or $name='seg-relocation' or $name='head-run-in' or $name='dateline'">seg</xsl:when>
          <xsl:when test="$name='gap' or $name='gap-cut' or $name='gap-ill'">gap</xsl:when>
          <xsl:when test="$name='add'">add</xsl:when>
          <xsl:when test="$name='metamark'">metamark</xsl:when>
          <xsl:when test="$name='metamark-add'">metamark-add-synth</xsl:when>
          <xsl:when test="$name='unclear'">unclear</xsl:when>
          <xsl:when test="$name='subst'">subst</xsl:when>
          <xsl:when test="$name='subst-del'">subst-del-synth</xsl:when>
          <xsl:when test="$name='sic'">choice-sic-synth</xsl:when>
          <xsl:when test="$name='undo'">undo</xsl:when>
        </xsl:choose>
      </xsl:variable>
      <my:range idx="{position()}" offset="{number($offset)}" end="{number($offset) + number($length)}" element="{$element}" continued="{$continued='true'}">
        <!-- seg-transposition: new-order und other-seg bleiben bewusst KEIN
             my:attr (wuerden als Ausgabeattribut durchschlagen), sondern
             wandern als Attribute des Ranges in $tpSegs (Abschnitt 7,
             listTranspose) -->
        <xsl:if test="$name='seg-transposition'">
          <xsl:attribute name="newOrder"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'new-order'"/></xsl:call-template></xsl:attribute>
          <xsl:attribute name="otherSeg"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'other-seg'"/></xsl:call-template></xsl:attribute>
        </xsl:if>
        <xsl:choose>
          <!-- generisches hi (Abschnitt 7): rendition aus dem Block uebernehmen (ausgegeben mit "#") -->
          <xsl:when test="$name='hi'">
            <xsl:variable name="hiRend"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'rendition'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$hiRend != ''"><my:attr name="rendition" value="{$hiRend}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='spacing' or $name='hi-spacing'"><my:attr name="rendition" value="letter-spacing"/></xsl:when>
          <xsl:when test="$name='bold' or $name='hi-bold'"><my:attr name="rendition" value="bold"/></xsl:when>
          <xsl:when test="$name='underline' or $name='hi-underline'"><my:attr name="rendition" value="underline"/></xsl:when>
          <xsl:when test="$name='hi-latin'"><my:attr name="rendition" value="latin"/></xsl:when>
          <xsl:when test="$name='mod-underline'"><my:attr name="rendition" value="underline"/></xsl:when>
          <xsl:when test="$name='mod'">
            <!-- Abschnitt 7: rendition aus dem Block (frueher "style" - bleibt als
                 Rueckfall lesbar), sonst Default underline -->
            <xsl:variable name="rendOverrideRaw"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'rendition'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="styleOverride">
              <xsl:choose>
                <xsl:when test="$rendOverrideRaw != ''"><xsl:value-of select="$rendOverrideRaw"/></xsl:when>
                <xsl:otherwise><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'style'"/></xsl:call-template></xsl:otherwise>
              </xsl:choose>
            </xsl:variable>
            <xsl:choose>
              <xsl:when test="$styleOverride != ''"><my:attr name="rendition" value="{$styleOverride}"/></xsl:when>
              <xsl:otherwise><my:attr name="rendition" value="underline"/></xsl:otherwise>
            </xsl:choose>
          </xsl:when>
          <xsl:when test="$name='del'">
            <!-- Abschnitt 7: cat wird zu @type (frueher "type" - bleibt als Rueckfall lesbar) -->
            <xsl:variable name="catV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'cat'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="typeV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'type'"/></xsl:call-template></xsl:variable>
            <xsl:choose>
              <xsl:when test="$catV != ''"><my:attr name="type" value="{$catV}"/></xsl:when>
              <xsl:when test="$typeV != ''"><my:attr name="type" value="{$typeV}"/></xsl:when>
            </xsl:choose>
          </xsl:when>
          <xsl:when test="$name='deselection'">
            <my:attr name="type" value="deselection"/>
          </xsl:when>
          <xsl:when test="$name='seg'">
            <!-- cat wird zu @type (frueher "type" - bleibt als Rueckfall lesbar); rendition uebernehmen -->
            <xsl:variable name="catV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'cat'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="typeV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'type'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="rendV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'rendition'"/></xsl:call-template></xsl:variable>
            <xsl:choose>
              <xsl:when test="$catV != ''"><my:attr name="type" value="{$catV}"/></xsl:when>
              <xsl:when test="$typeV != ''"><my:attr name="type" value="{$typeV}"/></xsl:when>
            </xsl:choose>
            <xsl:if test="$rendV != ''"><my:attr name="rendition" value="{$rendV}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='seg-relocation'">
            <my:attr name="type" value="relocation"/>
            <xsl:variable name="rendV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'rendition'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$rendV != ''"><my:attr name="rendition" value="{$rendV}"/></xsl:if>
          </xsl:when>
          <!-- Inline-Annotation dateline (Abschnitt 7) -> <seg type="dateline">, rendition uebernehmen -->
          <xsl:when test="$name='dateline'">
            <my:attr name="type" value="dateline"/>
            <xsl:variable name="rendnV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'rendition'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$rendnV != ''"><my:attr name="rendition" value="{$rendnV}"/></xsl:if>
          </xsl:when>
          <!-- head-run-in (Abschnitt 7) -> <seg type="head-run-in"> -->
          <xsl:when test="$name='head-run-in'"><my:attr name="type" value="head-run-in"/></xsl:when>
          <xsl:when test="$name='seg-transposition'">
            <my:attr name="type" value="transposition"/>
            <!-- corresp bleibt ein gewoehnliches Attribut (aufgeloest in
                 resolved-ref-attrs); other-seg/new-order (listTranspose,
                 Abschnitt 7) siehe $tpSegs/$transposeLists und werden NICHT
                 ausgegeben; rendition uebernehmen, sonst Default "transposition-sign" -->
            <xsl:variable name="corresp"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'corresp'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$corresp != ''"><my:attr name="corresp" value="{$corresp}"/></xsl:if>
            <!-- subcat wird 1:1 zu @subtype -->
            <xsl:variable name="tpSubcat"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'subcat'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$tpSubcat != ''"><my:attr name="subtype" value="{$tpSubcat}"/></xsl:if>
            <xsl:variable name="rendV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'rendition'"/></xsl:call-template></xsl:variable>
            <my:attr name="rendition">
              <xsl:attribute name="value">
                <xsl:choose>
                  <xsl:when test="$rendV != ''"><xsl:value-of select="$rendV"/></xsl:when>
                  <xsl:otherwise>transposition-sign</xsl:otherwise>
                </xsl:choose>
              </xsl:attribute>
            </my:attr>
          </xsl:when>
          <xsl:when test="$name='gap'">
            <xsl:variable name="reason"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'reason'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="extent"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'extent'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$reason != ''"><my:attr name="reason" value="{$reason}"/></xsl:if>
            <xsl:if test="$extent != ''"><my:attr name="extent" value="{$extent}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='gap-cut' or $name='gap-ill'">
            <xsl:variable name="hashCountRTF">
              <xsl:call-template name="count-char">
                <xsl:with-param name="s" select="substring($text, number($offset) + 1, number($length))"/>
                <xsl:with-param name="char" select="'#'"/>
              </xsl:call-template>
            </xsl:variable>
            <xsl:choose>
              <xsl:when test="$name='gap-cut'"><my:attr name="reason" value="cut"/></xsl:when>
              <xsl:otherwise><my:attr name="reason" value="illegible"/></xsl:otherwise>
            </xsl:choose>
            <my:attr name="extent" value="{number($hashCountRTF)}"/>
          </xsl:when>
          <xsl:when test="$name='add'">
            <xsl:variable name="place"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'place'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="declaredId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'id'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$place != ''"><my:attr name="place" value="{$place}"/></xsl:if>
            <!-- "id" auf einem Zeilen-add-Block (Abschnitt 7/8) ist wie
                 "del-id" eine Behelfs-ID-Deklaration, kein Ausgabeattribut -
                 wird ueber $behelfsMap zu einer echten xml:id (siehe
                 render-one-range/generische Weiche unten). -->
            <xsl:if test="$declaredId != ''"><my:attr name="id" value="{$declaredId}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='metamark'">
            <xsl:variable name="function"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'function'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="target"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'target'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="corresp"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'corresp'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$function != ''"><my:attr name="function" value="{$function}"/></xsl:if>
            <xsl:if test="$target != ''"><my:attr name="target" value="{$target}"/></xsl:if>
            <xsl:if test="$corresp != ''"><my:attr name="corresp" value="{$corresp}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='metamark-add'">
            <xsl:variable name="addId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'add-id'"/></xsl:call-template></xsl:variable>
            <my:attr name="add-id" value="{$addId}"/>
          </xsl:when>
          <xsl:when test="$name='subst-del'">
            <xsl:variable name="addId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'add-id'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="delId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'del-id'"/></xsl:call-template></xsl:variable>
            <!-- del-cat wird als @type ans del uebergeben -->
            <xsl:variable name="delCat"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'del-cat'"/></xsl:call-template></xsl:variable>
            <!-- subst-id: Behelfs-ID-Deklaration fuer das erzeugte <subst> (Praefix "subst") -->
            <xsl:variable name="substIdV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'subst-id'"/></xsl:call-template></xsl:variable>
            <my:attr name="add-id" value="{$addId}"/>
            <xsl:if test="$delId != ''"><my:attr name="del-id" value="{$delId}"/></xsl:if>
            <xsl:if test="$delCat != ''"><my:attr name="del-cat" value="{$delCat}"/></xsl:if>
            <xsl:if test="$substIdV != ''"><my:attr name="subst-id" value="{$substIdV}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='subst'">
            <xsl:variable name="addId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'add-id'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$addId != ''"><my:attr name="add-id" value="{$addId}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='sic'">
            <xsl:variable name="correction"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'correction'"/></xsl:call-template></xsl:variable>
            <my:attr name="correction" value="{$correction}"/>
            <!-- cat des sic wird als @type an corr uebergeben -->
            <xsl:variable name="sicCat"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'cat'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$sicCat != ''"><my:attr name="cat" value="{$sicCat}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='undo'">
            <xsl:variable name="undoRendition"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'rendition'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="target"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'target'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="undoCorresp"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'corresp'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$undoRendition != ''"><my:attr name="rendition" value="{$undoRendition}"/></xsl:if>
            <xsl:if test="$target != ''"><my:attr name="target" value="{$target}"/></xsl:if>
            <xsl:if test="$undoCorresp != ''"><my:attr name="corresp" value="{$undoCorresp}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='unclear'">
            <xsl:variable name="reason"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'reason'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="cert"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'cert'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="resp"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'resp'"/></xsl:call-template></xsl:variable>
            <!-- Defaults, wenn nicht angegeben: reason=illegible, cert=medium, resp=#edHdR -->
            <my:attr name="reason"><xsl:attribute name="value"><xsl:choose><xsl:when test="$reason != ''"><xsl:value-of select="$reason"/></xsl:when><xsl:otherwise>illegible</xsl:otherwise></xsl:choose></xsl:attribute></my:attr>
            <my:attr name="cert"><xsl:attribute name="value"><xsl:choose><xsl:when test="$cert != ''"><xsl:value-of select="$cert"/></xsl:when><xsl:otherwise>medium</xsl:otherwise></xsl:choose></xsl:attribute></my:attr>
            <my:attr name="resp"><xsl:attribute name="value"><xsl:choose><xsl:when test="$resp != ''"><xsl:value-of select="$resp"/></xsl:when><xsl:otherwise>#edHdR</xsl:otherwise></xsl:choose></xsl:attribute></my:attr>
          </xsl:when>
        </xsl:choose>
        <!-- "id" (Behelfs-ID-Deklaration, Abschnitt 8) auch auf den uebrigen
             Bloecken, die ueber die generische Weiche als Element ausgegeben
             werden (add hat seinen eigenen Zweig oben); wird in
             render-one-range zur echten xml:id. -->
        <xsl:if test="contains(' hi retrace spacing hi-spacing bold hi-bold underline hi-underline hi-latin mod-underline mod del deselection seg seg-transposition seg-relocation dateline unclear metamark metamark-add subst ', concat(' ',$name,' '))">
          <xsl:variable name="declaredIdOther"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'id'"/></xsl:call-template></xsl:variable>
          <xsl:if test="$declaredIdOther != ''"><my:attr name="id" value="{$declaredIdOther}"/></xsl:if>
        </xsl:if>
        <!-- "prev"/"next": Verweise auf Behelfs-IDs, werden zu den gleichnamigen
             TEI-Attributen (aufgeloest in resolved-ref-attrs) -->
        <xsl:if test="contains(' hi retrace spacing hi-spacing bold hi-bold underline hi-underline hi-latin mod-underline mod del deselection seg seg-transposition seg-relocation dateline unclear metamark add subst ', concat(' ',$name,' '))">
          <xsl:variable name="prevV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'prev'"/></xsl:call-template></xsl:variable>
          <xsl:variable name="nextV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'next'"/></xsl:call-template></xsl:variable>
          <xsl:if test="$prevV != ''"><my:attr name="prev" value="{$prevV}"/></xsl:if>
          <xsl:if test="$nextV != ''"><my:attr name="next" value="{$nextV}"/></xsl:if>
        </xsl:if>
        <!-- Abschnitt 9: change auf jedem Block, wird zu @change -->
        <xsl:call-template name="change-attr"><xsl:with-param name="content" select="$content"/></xsl:call-template>
      </my:range>
    </xsl:for-each>
  </xsl:template>

  <!-- Abschnitt 9 (Change-Werte): "change" wird auf jedem Zeilen-Block als
       @change uebernommen; mehrere Werte (im @custom durch das Literal
       \u0020 getrennt) bleiben mehrere, jeder bekommt ein vorangestelltes
       "#". Bei einer del/deselection-Kette (delSpan) zaehlt nur der Wert
       des ERSTEN Gliedes, siehe render-one-range. -->
  <xsl:template name="change-attr">
    <xsl:param name="content"/>
    <xsl:variable name="changeRaw"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'change'"/></xsl:call-template></xsl:variable>
    <xsl:if test="$changeRaw != ''">
      <my:attr name="change">
        <xsl:attribute name="value">
          <xsl:call-template name="change-hashed"><xsl:with-param name="s" select="string($changeRaw)"/></xsl:call-template>
        </xsl:attribute>
      </my:attr>
    </xsl:if>
  </xsl:template>

  <!-- "a\u0020b" (oder "a b") -> "#a #b"; schon mit "#" beginnende Werte bleiben -->
  <xsl:template name="change-hashed">
    <xsl:param name="s"/>
    <xsl:variable name="spaced"><xsl:call-template name="sep-to-space"><xsl:with-param name="s" select="$s"/></xsl:call-template></xsl:variable>
    <xsl:call-template name="change-hash-list"><xsl:with-param name="s" select="string($spaced)"/></xsl:call-template>
  </xsl:template>

  <xsl:template name="change-hash-list">
    <xsl:param name="s"/>
    <xsl:variable name="n" select="normalize-space($s)"/>
    <xsl:choose>
      <xsl:when test="contains($n,' ')">
        <xsl:call-template name="change-hash-list"><xsl:with-param name="s" select="substring-before($n,' ')"/></xsl:call-template>
        <xsl:text> </xsl:text>
        <xsl:call-template name="change-hash-list"><xsl:with-param name="s" select="substring-after($n,' ')"/></xsl:call-template>
      </xsl:when>
      <xsl:when test="$n != ''">
        <xsl:if test="not(starts-with($n,'#'))">#</xsl:if><xsl:value-of select="$n"/>
      </xsl:when>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="sep-to-space">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s,$sepMarker)">
        <xsl:value-of select="substring-before($s,$sepMarker)"/>
        <xsl:text> </xsl:text>
        <xsl:call-template name="sep-to-space"><xsl:with-param name="s" select="substring-after($s,$sepMarker)"/></xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="normalize-space($s)"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- subst-del (Abschnitt 7/8): subst-id wird zur xml:id des erzeugten <subst>
       (nur an der ersten Deklaration der id) -->
  <xsl:template name="subst-id-attr">
    <xsl:param name="range"/>
    <xsl:param name="lineId"/>
    <xsl:if test="$range/my:attr[@name='subst-id']">
      <xsl:variable name="sidV" select="string($range/my:attr[@name='subst-id']/@value)"/>
      <!-- heisst die subst-id wie eine Region-Behelfs-ID (z.B. einer add-Region),
           zaehlt hier die Zeilen-Deklaration (eigene subst-ID), nicht die der Region -->
      <xsl:variable name="sidHit" select="$behelfsMap[@behelfs=$sidV and @region='']"/>
      <xsl:variable name="sidFirst" select="$allLineRanges[my:attr[@name='subst-id']/@value=$sidV or my:attr[@name='id']/@value=$sidV][1]"/>
      <xsl:if test="$sidHit and $sidFirst/@line=$lineId and $sidFirst/@offset=$range/@offset">
        <xsl:attribute name="xml:id"><xsl:value-of select="$sidHit[1]/@genid"/></xsl:attribute>
      </xsl:if>
    </xsl:if>
  </xsl:template>

  <!-- gibt das @change eines Zeilen-Ranges aus (falls vorhanden) -->
  <xsl:template name="range-change-attr">
    <xsl:param name="range"/>
    <xsl:if test="$range/my:attr[@name='change']">
      <xsl:attribute name="change"><xsl:value-of select="$range/my:attr[@name='change']/@value"/></xsl:attribute>
    </xsl:if>
  </xsl:template>

  <!-- gibt das @change einer Region (structure{change:..}) aus (falls vorhanden) -->
  <xsl:template name="region-change-attr">
    <xsl:param name="regionId"/>
    <xsl:variable name="rcRaw" select="string($regions[@id=$regionId]/@change)"/>
    <xsl:if test="$rcRaw != ''">
      <xsl:attribute name="change">
        <xsl:call-template name="change-hashed"><xsl:with-param name="s" select="$rcRaw"/></xsl:call-template>
      </xsl:attribute>
    </xsl:if>
  </xsl:template>

  <!-- ein my:cv v=".." je einzelnem change-Wert (ohne "#") -->
  <xsl:template name="change-token-list">
    <xsl:param name="s"/>
    <xsl:variable name="hashed"><xsl:call-template name="change-hashed"><xsl:with-param name="s" select="$s"/></xsl:call-template></xsl:variable>
    <xsl:call-template name="change-token-split"><xsl:with-param name="s" select="string($hashed)"/></xsl:call-template>
  </xsl:template>
  <xsl:template name="change-token-split">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s,' ')">
        <my:cv v="{substring-after(substring-before($s,' '),'#')}"/>
        <xsl:call-template name="change-token-split"><xsl:with-param name="s" select="substring-after($s,' ')"/></xsl:call-template>
      </xsl:when>
      <xsl:when test="$s != ''"><my:cv v="{substring-after($s,'#')}"/></xsl:when>
    </xsl:choose>
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

  <!-- Abschnitt 7, Zusatzregel: wenn add und ein anderes Element als del
       denselben Zeichenbereich haben (identischer offset/end), ist IMMER
       add das aeussere Element. Ausserdem allgemeine Zyklus-Sicherheit: bei
       exakt gleich grossen, sich gegenseitig umschliessenden Bereichen
       (wie subst-del und deselection ueber denselben Bereich) wuerde ohne
       Tiebreak jeder den anderen zum Elternteil waehlen koennen (Zyklus -
       keiner von beiden waere dann erreichbar). Deshalb qualifiziert sich
       ein gleich grosser Kandidat nur EINSEITIG als Elternteil: bei
       add-Beteiligung gewinnt add; sonst gewinnt der zuerst deklarierte
       (kleinerer @idx) - und zwar nur in dessen Richtung, nicht umgekehrt. -->
  <xsl:template name="find-range-parent">
    <xsl:param name="ranges"/>
    <xsl:param name="me"/>
    <xsl:variable name="candidatesRTF">
      <xsl:for-each select="$ranges[@idx != $me/@idx and number(@offset) &lt;= number($me/@offset) and number(@end) &gt;= number($me/@end)]">
        <xsl:variable name="candSize" select="number(@end) - number(@offset)"/>
        <xsl:variable name="mySize" select="number($me/@end) - number($me/@offset)"/>
        <xsl:variable name="qualifies">
          <xsl:choose>
            <xsl:when test="$candSize &gt; $mySize">true</xsl:when>
            <xsl:when test="@element='add' and $me/@element != 'add' and $me/@element != 'del'">true</xsl:when>
            <xsl:when test="$me/@element='add' and @element != 'add' and @element != 'del'">false</xsl:when>
            <!-- gap-ill (Abschnitt 7): faellt eine gap-erzeugende Angabe
                 (gap/gap-cut/gap-ill) exakt mit dem Bereich eines del (oder
                 subst-del, dessen del) zusammen, ist del IMMER das aeussere -
                 unabhaengig von der Deklarationsreihenfolge. -->
            <xsl:when test="(@element='del' or @element='subst-del-synth') and $me/@element='gap'">true</xsl:when>
            <xsl:when test="($me/@element='del' or $me/@element='subst-del-synth') and @element='gap'">false</xsl:when>
            <!-- undo (Abschnitt 7): faellt ein undo exakt mit einer metamark-add
                 zusammen, umschliesst das undo die metamark samt eingefuegtem add -->
            <xsl:when test="@element='undo' and $me/@element='metamark-add-synth'">true</xsl:when>
            <xsl:when test="$me/@element='undo' and @element='metamark-add-synth'">false</xsl:when>
            <xsl:otherwise><xsl:value-of select="number(@idx) &lt; number($me/@idx)"/></xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:if test="$qualifies='true'">
          <xsl:variable name="priority">
            <xsl:choose>
              <xsl:when test="@element='add' and $candSize = $mySize and $me/@element != 'add' and $me/@element != 'del'">0</xsl:when>
              <xsl:when test="(@element='del' or @element='subst-del-synth') and $candSize = $mySize and $me/@element='gap'">0</xsl:when>
              <xsl:when test="@element='undo' and $candSize = $mySize and $me/@element='metamark-add-synth'">0</xsl:when>
              <xsl:otherwise>1</xsl:otherwise>
            </xsl:choose>
          </xsl:variable>
          <my:pidx val="{@idx}" size="{$candSize}" priority="{$priority}"/>
        </xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <!-- winnerRTF liefert hoechstens EIN my:winner-Element; wichtig: der
         Leer-Test unten braucht einen echten (evtl. leeren) Node-Set via
         exsl:node-set() - ein RTF-Ergebnis ist in XSLT 1.0/libxslt naemlich
         IMMER wahr, selbst wenn es keinen Inhalt hat (es ist ein Baum mit
         einem Wurzelknoten, also nie ein leerer Node-Set). Ein direkter
         "xsl:when test=RTF-Variable" wuerde deshalb nie den 0-Fallback
         erreichen. -->
    <xsl:variable name="winnerRTF">
      <xsl:for-each select="exsl:node-set($candidatesRTF)/my:pidx">
        <xsl:sort select="number(@size)" data-type="number" order="ascending"/>
        <xsl:sort select="number(@priority)" data-type="number" order="ascending"/>
        <!-- gleich grosse Kandidaten mit gleicher Prioritaet (Bloecke mit 
          exakt gleichem Bereich): der zuletzt deklarierte ist der INNERSTE 
          und damit das unmittelbare Elternelement -->
        <xsl:sort select="number(@val)" data-type="number" order="descending"/> 
        <xsl:if test="position()=1"><my:winner val="{@val}"/></xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="winnerNode" select="exsl:node-set($winnerRTF)/my:winner"/>
    <xsl:choose>
      <xsl:when test="$winnerNode"><xsl:value-of select="$winnerNode/@val"/></xsl:when>
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
    <xsl:param name="lineId"/>
    <xsl:param name="wrapSpaces" select="false()"/>
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
      <xsl:with-param name="lineId" select="$lineId"/>
      <xsl:with-param name="wrapSpaces" select="$wrapSpaces"/>
    </xsl:call-template>
  </xsl:template>

  <!-- Text direkt in einem Elternelement. wrapSpaces (nur fuer <subst>,
       Abschnitt 7 "Bekannte Datenluecke"): besteht der Text nur aus
       Leerzeichen, wird er als <del subtype="implicit"> ausgegeben, damit
       kein nackter Text in <subst> steht. suppressGap: kein #-Zusammenfassen. -->
  <xsl:template name="seq-text">
    <xsl:param name="txt"/>
    <xsl:param name="wrapSpaces" select="false()"/>
    <xsl:param name="suppressGap" select="false()"/>
    <xsl:choose>
      <xsl:when test="$wrapSpaces and $txt != '' and normalize-space($txt) = ''">
        <del subtype="implicit"><xsl:value-of select="$txt"/></del>
      </xsl:when>
      <xsl:when test="$suppressGap"><xsl:value-of select="$txt"/></xsl:when>
      <xsl:otherwise><xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="$txt"/></xsl:call-template></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="render-children-seq">
    <xsl:param name="ranges"/>
    <xsl:param name="rangeParents"/>
    <xsl:param name="ordered"/>
    <xsl:param name="pos"/>
    <xsl:param name="cursor"/>
    <xsl:param name="spanEnd"/>
    <xsl:param name="text"/>
    <xsl:param name="lineId"/>
    <xsl:param name="wrapSpaces" select="false()"/>
    <xsl:choose>
      <xsl:when test="$pos &gt; count($ordered)">
        <!-- Sonderfall: wenn dieser Textrest unmittelbar auf einen
             nullbreiten gap-Bereich folgt (etablierte Konvention fuer manuell
             annotierte Streckstellen, z.B. <gap reason="illegible" extent="N"/>
             gefolgt von den N literalen "#"-Zeichen als Klartext), wird das
             automatische #-Zusammenfassen (Abschnitt 7a) hier bewusst NICHT
             angewendet - sonst entstuende ein zweites, redundantes <gap>. -->
        <xsl:variable name="lastChild" select="$ordered[last()]"/>
        <xsl:variable name="lastRange" select="$ranges[@idx=$lastChild/@idx]"/>
        <xsl:variable name="suppressGap" select="boolean($lastChild) and $lastRange/@element='gap' and number($lastRange/@end) = number($lastRange/@offset)"/>
        <xsl:call-template name="seq-text">
          <xsl:with-param name="txt" select="substring($text, $cursor + 1, $spanEnd - $cursor)"/>
          <xsl:with-param name="wrapSpaces" select="$wrapSpaces"/>
          <xsl:with-param name="suppressGap" select="$suppressGap"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="childIdx" select="$ordered[$pos]/@idx"/>
        <xsl:variable name="range" select="$ranges[@idx=$childIdx]"/>
        <xsl:variable name="cStart" select="number($range/@offset)"/>
        <xsl:variable name="cEnd" select="number($range/@end)"/>
        <xsl:call-template name="seq-text">
          <xsl:with-param name="txt" select="substring($text, $cursor + 1, $cStart - $cursor)"/>
          <xsl:with-param name="wrapSpaces" select="$wrapSpaces"/>
        </xsl:call-template>
        <xsl:call-template name="render-one-range">
          <xsl:with-param name="ranges" select="$ranges"/>
          <xsl:with-param name="rangeParents" select="$rangeParents"/>
          <xsl:with-param name="range" select="$range"/>
          <xsl:with-param name="text" select="$text"/>
          <xsl:with-param name="lineId" select="$lineId"/>
        </xsl:call-template>
        <xsl:call-template name="render-children-seq">
          <xsl:with-param name="ranges" select="$ranges"/>
          <xsl:with-param name="rangeParents" select="$rangeParents"/>
          <xsl:with-param name="ordered" select="$ordered"/>
          <xsl:with-param name="pos" select="$pos + 1"/>
          <xsl:with-param name="cursor" select="$cEnd"/>
          <xsl:with-param name="spanEnd" select="$spanEnd"/>
          <xsl:with-param name="text" select="$text"/>
          <xsl:with-param name="lineId" select="$lineId"/>
          <xsl:with-param name="wrapSpaces" select="$wrapSpaces"/>
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
    <xsl:param name="lineId"/>
    <!-- forceRender: ein per add-id importierter Zeilen-add wird an der
         Importstelle trotz Unterdrueckung an der Originalstelle gerendert -->
    <xsl:param name="forceRender" select="false()"/>
    <xsl:variable name="hasChildren" select="boolean($rangeParents[@parent=$range/@idx])"/>
    <xsl:choose>
      <!-- Zeilen-add, der per add-id an anderer Stelle importiert wird: an der
           eigenen Stelle entfaellt er (Zeichenbereich inkl. Kindern) -->
      <xsl:when test="not($forceRender) and $range/@element='add' and $consumedLineAdds[@line=$lineId and number(@offset)=number($range/@offset)]"/>
      <!-- subst-del + add-id (Abschnitt 7): der ganze Bereich ist geloescht,
           der Ersatz kommt NICHT aus lokalem Zeichenversatz, sondern wird aus
           einer per Behelfs-ID referenzierten add-Region importiert - direkt
           <subst><del>eigener Text</del><add>importiert</add></subst>, kein
           gewoehnliches Wrapper-Element. -->
      <xsl:when test="$range/@element='subst-del-synth'">
        <subst>
          <xsl:call-template name="subst-id-attr"><xsl:with-param name="range" select="$range"/><xsl:with-param name="lineId" select="$lineId"/></xsl:call-template>
          <xsl:call-template name="range-change-attr"><xsl:with-param name="range" select="$range"/></xsl:call-template>
          <del>
            <xsl:variable name="delIdBehelfs" select="$range/my:attr[@name='del-id']/@value"/>
            <xsl:if test="$delIdBehelfs != ''">
              <xsl:variable name="delIdHit" select="$behelfsMap[@behelfs=$delIdBehelfs]"/>
              <xsl:if test="$delIdHit">
                <xsl:attribute name="xml:id"><xsl:value-of select="$delIdHit[1]/@genid"/></xsl:attribute>
              </xsl:if>
            </xsl:if>
            <xsl:if test="$range/my:attr[@name='del-cat']">
              <xsl:attribute name="type"><xsl:value-of select="$range/my:attr[@name='del-cat']/@value"/></xsl:attribute>
            </xsl:if>
            <xsl:choose>
              <xsl:when test="$hasChildren">
                <xsl:call-template name="render-span-children">
                  <xsl:with-param name="ranges" select="$ranges"/>
                  <xsl:with-param name="rangeParents" select="$rangeParents"/>
                  <xsl:with-param name="parentIdx" select="$range/@idx"/>
                  <xsl:with-param name="spanStart" select="number($range/@offset)"/>
                  <xsl:with-param name="spanEnd" select="number($range/@end)"/>
                  <xsl:with-param name="text" select="$text"/>
                  <xsl:with-param name="lineId" select="$lineId"/>
                </xsl:call-template>
              </xsl:when>
              <xsl:otherwise>
                <xsl:call-template name="text-with-gaps">
                  <xsl:with-param name="txt" select="substring($text, number($range/@offset) + 1, number($range/@end) - number($range/@offset))"/>
                </xsl:call-template>
              </xsl:otherwise>
            </xsl:choose>
          </del>
          <!-- add-id kann wie bei metamark-add gelegentlich mehrere
                -getrennte Werte tragen - dann werden alle als Kind
               des subst eingefuegt. -->
          <xsl:variable name="substDelAddIdsRTF">
            <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="$range/my:attr[@name='add-id']/@value"/></xsl:call-template>
          </xsl:variable>
          <xsl:for-each select="exsl:node-set($substDelAddIdsRTF)/my:tok">
            <xsl:call-template name="render-imported-add">
              <xsl:with-param name="behelfsId" select="@val"/>
              <xsl:with-param name="lineId" select="$lineId"/>
            </xsl:call-template>
          </xsl:for-each>
        </subst>
        <xsl:variable name="pendingAnchorId">
          <xsl:call-template name="pending-anchor-id-for">
            <xsl:with-param name="ranges" select="$ranges"/>
            <xsl:with-param name="rangeParents" select="$rangeParents"/>
            <xsl:with-param name="myIdx" select="$range/@idx"/>
            <xsl:with-param name="lineId" select="$lineId"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:if test="$pendingAnchorId != ''"><xsl:call-template name="desel-end-anchor"><xsl:with-param name="id" select="$pendingAnchorId"/></xsl:call-template></xsl:if>
      </xsl:when>

      <!-- metamark-add + add-id (Abschnitt 7): Meilenstein + importierte(s)
           <add>, kein eigener Zeicheninhalt. add-id traegt gelegentlich
           MEHRERE  -getrennte Werte (siehe Korrektur im Chat) - dann
           werden alle referenzierten add-Regionen hier nacheinander
           "reingesaugt", nicht nur die erste. -->
      <xsl:when test="$range/@element='metamark-add-synth'">
        <xsl:variable name="addIdsRTF">
          <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="$range/my:attr[@name='add-id']/@value"/></xsl:call-template>
        </xsl:variable>
        <!-- zeigt add-id auf eine add-block (wird nie eingesogen), verweist die
             metamark per @target auf deren <div type="add-block"> -->
        <xsl:variable name="mabBlocksRTF">
          <xsl:for-each select="exsl:node-set($addIdsRTF)/my:tok">
            <xsl:if test="$regions[@id=$behelfsMap[@behelfs=current()/@val][1]/@region]/@type='add-block'"><my:b val="{@val}"/></xsl:if>
          </xsl:for-each>
        </xsl:variable>
        <metamark function="addition">
          <!-- id (Behelfs-ID-Deklaration, z.B. als Ziel eines undo) wird zur xml:id -->
          <xsl:if test="$range/my:attr[@name='id']">
            <xsl:variable name="mabDeclHit" select="$behelfsMap[@behelfs=$range/my:attr[@name='id']/@value]"/>
            <xsl:variable name="mabFirstDecl" select="$allLineRanges[my:attr[@name='id']/@value=$range/my:attr[@name='id']/@value][1]"/>
            <xsl:if test="$mabDeclHit and $mabDeclHit[1]/@region='' and $mabFirstDecl/@line=$lineId and $mabFirstDecl/@offset=$range/@offset"><xsl:attribute name="xml:id"><xsl:value-of select="$mabDeclHit[1]/@genid"/></xsl:attribute></xsl:if>
          </xsl:if>
          <xsl:call-template name="range-change-attr"><xsl:with-param name="range" select="$range"/></xsl:call-template>
          <xsl:if test="exsl:node-set($mabBlocksRTF)/my:b">
            <xsl:attribute name="target">
              <xsl:for-each select="exsl:node-set($mabBlocksRTF)/my:b">
                <xsl:if test="position() &gt; 1"><xsl:text> </xsl:text></xsl:if>
                <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="@val"/></xsl:call-template>
              </xsl:for-each>
            </xsl:attribute>
          </xsl:if>
        </metamark>
        <xsl:for-each select="exsl:node-set($addIdsRTF)/my:tok">
          <xsl:call-template name="render-imported-add">
            <xsl:with-param name="behelfsId" select="@val"/>
            <xsl:with-param name="lineId" select="$lineId"/>
          </xsl:call-template>
        </xsl:for-each>
      </xsl:when>

      <!-- metamark mit function="insertion" und @target (Abschnitt 7): wie
           metamark-add, aber die Ziel-add-Region wird erst durch Verfolgen
           der Behelfs-ID-Kette gefunden (siehe resolve-insertion-chain) -
           kann ueber eine zweite metamark mit function="insertion" laufen.
           Loest die Kette NICHT zu einer add-Region auf (unerwartete/
           unvollstaendige Daten): defensiv normal rendern (Fallback unten). -->
      <xsl:when test="$range/@element='metamark' and $range/my:attr[@name='function']/@value='insertion' and $range/my:attr[@name='target']">
        <xsl:variable name="chainTargetRegionId" select="$insertionChainResolutions[@kind='line' and @id=$lineId and @offset=$range/@offset]/@target"/>
        <xsl:choose>
          <xsl:when test="$regions[@id=$chainTargetRegionId]/@type='add'">
            <metamark function="insertion">
              <xsl:call-template name="range-change-attr"><xsl:with-param name="range" select="$range"/></xsl:call-template>
              <xsl:call-template name="foreign-target-attr"><xsl:with-param name="target" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
            </metamark>
            <xsl:call-template name="render-imported-add">
              <xsl:with-param name="addRegionId" select="$chainTargetRegionId"/>
              <xsl:with-param name="lineId" select="$lineId"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <metamark function="insertion">
              <xsl:call-template name="range-change-attr"><xsl:with-param name="range" select="$range"/></xsl:call-template>
              <xsl:choose>
                <!-- Kette endet in einer add-block (wird nie eingesogen): normaler Verweis -->
                <xsl:when test="$regions[@id=$chainTargetRegionId]/@type='add-block'">
                  <xsl:attribute name="target">
                    <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
                  </xsl:attribute>
                </xsl:when>
                <xsl:otherwise>
                  <xsl:call-template name="foreign-target-attr"><xsl:with-param name="target" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
                </xsl:otherwise>
              </xsl:choose>
              <xsl:choose>
                <xsl:when test="$hasChildren">
                  <xsl:call-template name="render-span-children">
                    <xsl:with-param name="ranges" select="$ranges"/>
                    <xsl:with-param name="rangeParents" select="$rangeParents"/>
                    <xsl:with-param name="parentIdx" select="$range/@idx"/>
                    <xsl:with-param name="spanStart" select="number($range/@offset)"/>
                    <xsl:with-param name="spanEnd" select="number($range/@end)"/>
                    <xsl:with-param name="text" select="$text"/>
                    <xsl:with-param name="lineId" select="$lineId"/>
                  </xsl:call-template>
                </xsl:when>
                <xsl:otherwise>
                  <xsl:call-template name="text-with-gaps">
                    <xsl:with-param name="txt" select="substring($text, number($range/@offset) + 1, number($range/@end) - number($range/@offset))"/>
                  </xsl:call-template>
                </xsl:otherwise>
              </xsl:choose>
            </metamark>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:when>

      <!-- sic mit correction (Abschnitt 7) -->
      <xsl:when test="$range/@element='choice-sic-synth'">
        <choice resp="#edHdR">
          <sic>
            <xsl:choose>
              <xsl:when test="$hasChildren">
                <xsl:call-template name="render-span-children">
                  <xsl:with-param name="ranges" select="$ranges"/>
                  <xsl:with-param name="rangeParents" select="$rangeParents"/>
                  <xsl:with-param name="parentIdx" select="$range/@idx"/>
                  <xsl:with-param name="spanStart" select="number($range/@offset)"/>
                  <xsl:with-param name="spanEnd" select="number($range/@end)"/>
                  <xsl:with-param name="text" select="$text"/>
                  <xsl:with-param name="lineId" select="$lineId"/>
                </xsl:call-template>
              </xsl:when>
              <xsl:otherwise>
                <xsl:call-template name="text-with-gaps">
                  <xsl:with-param name="txt" select="substring($text, number($range/@offset) + 1, number($range/@end) - number($range/@offset))"/>
                </xsl:call-template>
              </xsl:otherwise>
            </xsl:choose>
          </sic>
          <corr>
            <!-- type aus cat des sic; ohne cat Default "emen" -->
            <xsl:attribute name="type"><xsl:choose><xsl:when test="$range/my:attr[@name='cat']"><xsl:value-of select="$range/my:attr[@name='cat']/@value"/></xsl:when><xsl:otherwise>emen</xsl:otherwise></xsl:choose></xsl:attribute>
            <xsl:value-of select="$range/my:attr[@name='correction']/@value"/>
          </corr>
        </choice>
      </xsl:when>

      <!-- undo (Abschnitt 7): kein umschliessendes Element - stattdessen ein
           leeres Meilenstein-Paar <undo spanTo="#X"/> ... <anchor xml:id="X"/>
           VOR und NACH dem unveraendert weitergerenderten Inhalt. Stuecke mit
           continued:true (siehe $undoPieces) bilden EIN Paar: <undo> nur am
           ersten, <anchor> nur am letzten Stueck. -->
      <xsl:when test="$range/@element='undo'">
        <xsl:variable name="uqPiece" select="$undoPieces[@line=$lineId and number(@offset)=number($range/@offset)][1]"/>
        <xsl:variable name="seq" select="$uqPiece/@seq"/>
        <xsl:variable name="uqRole" select="string($uqPiece/@role)"/>
        <xsl:variable name="seqPadded"><xsl:call-template name="pad4"><xsl:with-param name="s" select="$seq"/></xsl:call-template></xsl:variable>
        <xsl:variable name="anchorId" select="concat('anchor-', $pageNumPadded, '-', $seqPadded)"/>
        <xsl:if test="$uqRole='single' or $uqRole='start'">
        <undo spanTo="{concat('#',$anchorId)}">
          <xsl:call-template name="range-change-attr"><xsl:with-param name="range" select="$range"/></xsl:call-template>
          <xsl:if test="$range/my:attr[@name='corresp']">
            <xsl:attribute name="corresp">
              <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$range/my:attr[@name='corresp']/@value"/></xsl:call-template>
            </xsl:attribute>
          </xsl:if>
          <xsl:if test="$range/my:attr[@name='rendition']">
            <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$range/my:attr[@name='rendition']/@value"/></xsl:call-template>
          </xsl:if>
          <xsl:if test="$range/my:attr[@name='target']">
            <xsl:attribute name="target">
              <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
            </xsl:attribute>
          </xsl:if>
        </undo>
        </xsl:if>
        <xsl:choose>
          <xsl:when test="$hasChildren">
            <xsl:call-template name="render-span-children">
              <xsl:with-param name="ranges" select="$ranges"/>
              <xsl:with-param name="rangeParents" select="$rangeParents"/>
              <xsl:with-param name="parentIdx" select="$range/@idx"/>
              <xsl:with-param name="spanStart" select="number($range/@offset)"/>
              <xsl:with-param name="spanEnd" select="number($range/@end)"/>
              <xsl:with-param name="text" select="$text"/>
              <xsl:with-param name="lineId" select="$lineId"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="text-with-gaps">
              <xsl:with-param name="txt" select="substring($text, number($range/@offset) + 1, number($range/@end) - number($range/@offset))"/>
            </xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
        <xsl:if test="$uqRole='single' or $uqRole='end'">
          <anchor type="undo"><xsl:attribute name="xml:id"><xsl:value-of select="$anchorId"/></xsl:attribute></anchor>
        </xsl:if>
      </xsl:when>

      <!-- deselection mit @part (Korrektur, siehe Chat): KEIN umschliessendes
           <del> mehr - stattdessen ein leeres <delSpan target="#X"/> GENAU an
           der Stelle des ERSTEN "I"/"i"-Vorkommens (siehe $deselMarkers) bzw.
           ein leeres <anchor xml:id="X"/> GENAU an der Stelle des LETZTEN
           "F"/"f"-Vorkommens; alle dazwischenliegenden Wiederholungen (reine
           Ketten-Fortsetzungen aus dem Quell-@custom) bleiben ohne jede
           eigene Ausgabe - der Inhalt fliesst unveraendert durch. -->
      <xsl:when test="$range/@element='del' and $deselMarkers[@line=$lineId and number(@offset)=number($range/@offset)]">
        <xsl:variable name="marker" select="$deselMarkers[@line=$lineId and number(@offset)=number($range/@offset)]"/>
        <xsl:variable name="pairId" select="string($deselPairIds[@seq=$marker/@pairSeq]/@id)"/>
        <!-- Korrektur: faellt das Ende dieses Bereichs mit dem Ende eines
             umschliessenden subst/subst-del-synth zusammen, wird der
             <anchor> NICHT hier ausgegeben, sondern von jenem subst-
             Rendering selbst NACH dessen </subst> (siehe relocation-target-for
             und pending-anchor-id-for weiter unten). -->
        <xsl:variable name="relocTarget">
          <xsl:call-template name="relocation-target-for">
            <xsl:with-param name="ranges" select="$ranges"/>
            <xsl:with-param name="rangeParents" select="$rangeParents"/>
            <xsl:with-param name="idx" select="$range/@idx"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:if test="$marker/@role='start'">
          <!-- Kette: <delSpan type=".." xml:id=".." spanTo="#anchor"/>; xml:id aus der
               id des ersten Glieds, type aus deselection bzw. del/cat -->
          <delSpan>
            <xsl:if test="$range/my:attr[@name='id']">
              <xsl:variable name="declHit" select="$behelfsMap[@behelfs=$range/my:attr[@name='id']/@value]"/>
              <xsl:variable name="firstDecl" select="$allLineRanges[my:attr[@name='id']/@value=$range/my:attr[@name='id']/@value][1]"/>
              <xsl:if test="$declHit and $firstDecl/@line=$lineId and $firstDecl/@offset=$range/@offset"><xsl:attribute name="xml:id"><xsl:value-of select="$declHit[1]/@genid"/></xsl:attribute></xsl:if>
            </xsl:if>
            <xsl:if test="$range/my:attr[@name='type']"><xsl:attribute name="type"><xsl:value-of select="$range/my:attr[@name='type']/@value"/></xsl:attribute></xsl:if>
            <!-- change: nur der Wert des ersten Kettenglieds (dieses Range), die
                 uebrigen Glieder rendern kein eigenes Element und entfallen -->
            <xsl:if test="$range/my:attr[@name='change']"><xsl:attribute name="change"><xsl:value-of select="$range/my:attr[@name='change']/@value"/></xsl:attribute></xsl:if>
            <xsl:attribute name="spanTo"><xsl:value-of select="concat('#',$pairId)"/></xsl:attribute>
          </delSpan>
        </xsl:if>
        <xsl:choose>
          <xsl:when test="$hasChildren">
            <xsl:call-template name="render-span-children">
              <xsl:with-param name="ranges" select="$ranges"/>
              <xsl:with-param name="rangeParents" select="$rangeParents"/>
              <xsl:with-param name="parentIdx" select="$range/@idx"/>
              <xsl:with-param name="spanStart" select="number($range/@offset)"/>
              <xsl:with-param name="spanEnd" select="number($range/@end)"/>
              <xsl:with-param name="text" select="$text"/>
              <xsl:with-param name="lineId" select="$lineId"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <xsl:call-template name="text-with-gaps">
              <xsl:with-param name="txt" select="substring($text, number($range/@offset) + 1, number($range/@end) - number($range/@offset))"/>
            </xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
        <xsl:if test="$marker/@role='end' and $relocTarget=''">
          <anchor>
            <xsl:if test="string($deselPairIds[@id=$pairId]/@type) != ''"><xsl:attribute name="type"><xsl:value-of select="$deselPairIds[@id=$pairId]/@type"/></xsl:attribute></xsl:if>
            <xsl:attribute name="xml:id"><xsl:value-of select="$pairId"/></xsl:attribute>
          </anchor>
        </xsl:if>
      </xsl:when>

      <!-- <gap> ist in TEI ein leeres Element (kein Text-Inhalt) - das gilt
           genauso fuer gap-cut, dessen eigene Zeichenspanne oft genau die
           literalen "#"-Zeichen umfasst, die es beschreibt: die wuerden vom
           text-with-gaps-Automatismus (Abschnitt 7a) sonst NOCHMAL in ein
           verschachteltes <gap> verpackt. -->
      <xsl:when test="$range/@element='gap'">
        <gap>
          <xsl:for-each select="$range/my:attr">
            <xsl:attribute name="{@name}"><xsl:value-of select="@value"/></xsl:attribute>
          </xsl:for-each>
        </gap>
      </xsl:when>

      <xsl:otherwise>
        <!-- Abschnitt 7: literales "subst" mit add-id, aber OHNE eigenes
             add-Kind (nur ein del-Kind) - der Ersatztext fehlt lokal
             komplett und wird stattdessen aus der per add-id referenzierten
             add-Region importiert, als zusaetzliches Kind NACH dem
             normalen (del-)Inhalt. -->
        <xsl:variable name="substAddId" select="$range/my:attr[@name='add-id']/@value"/>
        <xsl:variable name="hasAddChild" select="boolean($ranges[@idx = $rangeParents[@parent=$range/@idx]/@idx and @element='add'])"/>
        <xsl:variable name="mmTgtRTF"><xsl:call-template name="mm-add-targets"><xsl:with-param name="range" select="$range"/></xsl:call-template></xsl:variable>
        <xsl:variable name="mmTgt" select="exsl:node-set($mmTgtRTF)/my:t"/>
        <xsl:element name="{$range/@element}">
          <!-- "id" (Behelfs-ID-Deklaration, z.B. auf einem add-Block) wird
               zu einer echten xml:id statt eines Ausgabeattributs "id";
               "target" wird - wo immer es vorkommt - als Behelfs-ID
               aufgeloest statt roh kopiert (Abschnitt 8). add-id/del-id
               sind reine Buchhaltung, nie ein Ausgabeattribut. -->
          <xsl:if test="$range/my:attr[@name='id']">
            <!-- <subst>: heisst die id wie eine Region-Behelfs-ID, zaehlt die
                 Zeilen-Deklaration (eigene subst-ID) -->
            <xsl:variable name="declHit" select="$behelfsMap[@behelfs=$range/my:attr[@name='id']/@value and (@region='' or $range/@element!='subst')]"/>
            <!-- nur die ERSTE Deklaration einer ID bekommt die xml:id (ein
                 "continued:true"-Lauf traegt dieselbe id auf jedem Zeilen-
                 stueck, soll aber nur EINE xml:id ergeben) -->
            <xsl:variable name="firstDecl" select="$allLineRanges[my:attr[@name='id']/@value=$range/my:attr[@name='id']/@value][1]"/>
            <xsl:if test="$declHit and $firstDecl/@line=$lineId and $firstDecl/@offset=$range/@offset"><xsl:attribute name="xml:id"><xsl:value-of select="$declHit[1]/@genid"/></xsl:attribute></xsl:if>
          </xsl:if>
          <xsl:for-each select="$range/my:attr[@name != 'add-id' and @name != 'del-id' and @name != 'id' and @name != 'target' and @name != 'corresp' and @name != 'rendition' and @name != 'prev' and @name != 'next']">
            <xsl:attribute name="{@name}"><xsl:value-of select="@value"/></xsl:attribute>
          </xsl:for-each>
          <xsl:call-template name="resolved-ref-attrs"><xsl:with-param name="attrs" select="$range/my:attr"/></xsl:call-template>
          <xsl:choose>
            <!-- metamark function="addition": importierte add-Ziele stehen NICHT
                 mehr im target (das add folgt direkt hinter der metamark) -->
            <xsl:when test="$mmTgt">
              <xsl:if test="$mmTgt[@imp='no']">
                <xsl:attribute name="target">
                  <xsl:for-each select="$mmTgt[@imp='no']">
                    <xsl:if test="position() &gt; 1"><xsl:text> </xsl:text></xsl:if>
                    <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="@val"/></xsl:call-template>
                  </xsl:for-each>
                </xsl:attribute>
              </xsl:if>
            </xsl:when>
            <xsl:when test="$range/my:attr[@name='target']">
              <xsl:attribute name="target">
                <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
              </xsl:attribute>
            </xsl:when>
          </xsl:choose>
          <xsl:choose>
            <xsl:when test="$hasChildren">
              <xsl:call-template name="render-span-children">
                <xsl:with-param name="ranges" select="$ranges"/>
                <xsl:with-param name="rangeParents" select="$rangeParents"/>
                <xsl:with-param name="parentIdx" select="$range/@idx"/>
                <xsl:with-param name="spanStart" select="number($range/@offset)"/>
                <xsl:with-param name="spanEnd" select="number($range/@end)"/>
                <xsl:with-param name="text" select="$text"/>
                <xsl:with-param name="lineId" select="$lineId"/>
                <xsl:with-param name="wrapSpaces" select="$range/@element='subst'"/>
              </xsl:call-template>
            </xsl:when>
            <xsl:otherwise>
              <xsl:call-template name="text-with-gaps">
                <xsl:with-param name="txt" select="substring($text, number($range/@offset) + 1, number($range/@end) - number($range/@offset))"/>
              </xsl:call-template>
            </xsl:otherwise>
          </xsl:choose>
          <xsl:if test="$range/@element='subst' and $substAddId != '' and not($hasAddChild)">
            <xsl:variable name="substAddIdsRTF">
              <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="$substAddId"/></xsl:call-template>
            </xsl:variable>
            <xsl:for-each select="exsl:node-set($substAddIdsRTF)/my:tok">
              <xsl:call-template name="render-imported-add">
                <xsl:with-param name="behelfsId" select="@val"/>
                <xsl:with-param name="lineId" select="$lineId"/>
              </xsl:call-template>
            </xsl:for-each>
          </xsl:if>
        </xsl:element>
        <!-- metamark function="addition": das add wird hier, direkt hinter der
             metamark, eingefuegt -->
        <xsl:for-each select="$mmTgt[@imp='yes']">
          <xsl:call-template name="render-imported-add">
            <xsl:with-param name="behelfsId" select="@val"/>
            <xsl:with-param name="lineId" select="$lineId"/>
          </xsl:call-template>
        </xsl:for-each>
        <xsl:if test="$range/@element='seg' and $range/my:attr[@name='type']/@value='transposition'">
          <xsl:call-template name="render-transpose-mark">
            <xsl:with-param name="lineId" select="$lineId"/>
            <xsl:with-param name="offset" select="$range/@offset"/>
          </xsl:call-template>
        </xsl:if>
        <!-- siehe subst-del-synth weiter oben: dasselbe gilt fuer ein
             LITERALES subst (aus einem echten "subst"-Block, nicht nur die
             subst-del-Konstruktion) - faellt das Ende eines deselection-
             Bereichs mit dessen Ende zusammen, wird der <anchor> hierher
             (nach dem schliessenden Tag) verschoben. -->
        <xsl:if test="$range/@element='subst'">
          <xsl:variable name="pendingAnchorId">
            <xsl:call-template name="pending-anchor-id-for">
              <xsl:with-param name="ranges" select="$ranges"/>
              <xsl:with-param name="rangeParents" select="$rangeParents"/>
              <xsl:with-param name="myIdx" select="$range/@idx"/>
              <xsl:with-param name="lineId" select="$lineId"/>
            </xsl:call-template>
          </xsl:variable>
          <xsl:if test="$pendingAnchorId != ''"><xsl:call-template name="desel-end-anchor"><xsl:with-param name="id" select="$pendingAnchorId"/></xsl:call-template></xsl:if>
        </xsl:if>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- baut das <add> fuer subst-del/metamark-add aus der per Behelfs-ID
       referenzierten add-Region: eigener Text der Region (via render-lines),
       @facs zeigt sowohl auf die add-Region-Zone als auch auf die Zeile, in
       der der Verweis steht (Abschnitt 7/8: "facs-Wert der add-Region und
       Zeile sollen mituebernommen werden"). -->
  <!-- add-id auf einen ZEILEN-add (Abschnitt 7): der per "add {id:..}" in einer
       TextLine deklarierte Zeichenbereich wird an der Importstelle als <add>
       ausgegeben (mit facs auf die Quellzeile); an seiner eigenen Stelle
       wird er unterdrueckt (siehe $consumedLineAdds in render-one-range). -->
  <!-- Abschnitt 7: Zeilen-metamark mit function="addition" (auch "add") und
       target: jeder target-Wert, der auf ein add zeigt (add-Region oder
       Zeilen-add mit dieser id), wird als <my:t val=".." imp="yes"/>
       geliefert (wird an der metamark importiert), alle anderen als imp="no" -->
  <xsl:template name="mm-add-targets">
    <xsl:param name="range"/>
    <xsl:if test="$range/@element='metamark' and ($range/my:attr[@name='function']/@value='addition' or $range/my:attr[@name='function']/@value='add') and $range/my:attr[@name='target']">
      <xsl:variable name="mmTokRTF">
        <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
      </xsl:variable>
      <xsl:for-each select="exsl:node-set($mmTokRTF)/my:tok">
        <xsl:variable name="mmReg" select="$behelfsMap[@behelfs=current()/@val][1]/@region"/>
        <xsl:choose>
          <xsl:when test="$regions[@id=$mmReg]/@type='add'"><my:t val="{@val}" imp="yes"/></xsl:when>
          <xsl:when test="$mmReg = '' and $allLineRanges[@element='add' and my:attr[@name='id']/@value=current()/@val]"><my:t val="{@val}" imp="yes"/></xsl:when>
          <xsl:otherwise><my:t val="{@val}" imp="no"/></xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
    </xsl:if>
  </xsl:template>

  <xsl:template name="render-imported-line-add">
    <xsl:param name="behelfsId"/>
    <xsl:variable name="src" select="$allLineRanges[@element='add' and my:attr[@name='id']/@value=$behelfsId][1]"/>
    <xsl:variable name="srcLine" select="$allLines[@id=$src/@line]"/>
    <xsl:variable name="srcText" select="$srcLine/*[local-name()='TextEquiv'][1]/*[local-name()='Unicode']"/>
    <xsl:variable name="srcRangesRTF"><xsl:call-template name="parse-line-ranges"><xsl:with-param name="line" select="$srcLine"/></xsl:call-template></xsl:variable>
    <xsl:variable name="srcRanges" select="exsl:node-set($srcRangesRTF)/my:range"/>
    <xsl:variable name="srcParentsRTF"><xsl:call-template name="build-range-parents"><xsl:with-param name="ranges" select="$srcRanges"/></xsl:call-template></xsl:variable>
    <xsl:variable name="srcParents" select="exsl:node-set($srcParentsRTF)/my:rp"/>
    <xsl:variable name="srcRange" select="$srcRanges[@element='add' and number(@offset)=number($src/@offset) and my:attr[@name='id']/@value=$behelfsId][1]"/>
    <xsl:variable name="addRTF">
      <xsl:call-template name="render-one-range">
        <xsl:with-param name="ranges" select="$srcRanges"/>
        <xsl:with-param name="rangeParents" select="$srcParents"/>
        <xsl:with-param name="range" select="$srcRange"/>
        <xsl:with-param name="text" select="$srcText"/>
        <xsl:with-param name="lineId" select="string($src/@line)"/>
        <xsl:with-param name="forceRender" select="true()"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:for-each select="exsl:node-set($addRTF)/*">
      <xsl:copy>
        <xsl:attribute name="facs"><xsl:value-of select="concat('#zone_', $src/@line)"/></xsl:attribute>
        <xsl:copy-of select="@*|node()"/>
      </xsl:copy>
    </xsl:for-each>
  </xsl:template>

  <xsl:template name="render-imported-add">
    <xsl:param name="behelfsId"/>
    <xsl:param name="addRegionId" select="''"/>
    <xsl:param name="lineId" select="''"/>
    <xsl:variable name="hit" select="$behelfsMap[@behelfs=$behelfsId]"/>
    <xsl:variable name="resolvedAddRegionId">
      <xsl:choose>
        <xsl:when test="$addRegionId != ''"><xsl:value-of select="$addRegionId"/></xsl:when>
        <xsl:otherwise><xsl:value-of select="$hit[1]/@region"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <!-- @region="" darf NIE gegen $behelfsMap gematcht werden - sonst
         wuerde ein fehlgeschlagenes Lookup (leere resolvedAddRegionId)
         zufaellig auf einen der ebenfalls region-losen Eintraege (del-id/
         Zeilen-add-id, siehe oben) treffen. -->
    <xsl:variable name="genIdHit" select="$behelfsMap[@region=$resolvedAddRegionId and $resolvedAddRegionId != '']"/>
    <xsl:variable name="isCanonicalImport" select="boolean($canonicalAddImport[@region=$resolvedAddRegionId and @line=$lineId])"/>
    <!-- Datenluecke statt Stylesheet-Fehler: loest die Behelfs-ID nirgends
         auf (keine Region deklariert dieses add-id), bleibt resolvedAddRegionId
         leer - dann wird NICHT ein irrefuehrendes leeres <add facs="#zone_"/>
         ausgegeben, sondern ein XML-Kommentar mit der unaufgeloesten ID, damit
         die Luecke beim Lesen sofort auffaellt statt wie ein stiller Bug
         auszusehen. -->
    <xsl:choose>
      <xsl:when test="$resolvedAddRegionId = '' and $allLineRanges[@element='add' and my:attr[@name='id']/@value=$behelfsId]">
        <xsl:call-template name="render-imported-line-add"><xsl:with-param name="behelfsId" select="$behelfsId"/></xsl:call-template>
      </xsl:when>
      <!-- add-block wird NIE eingesogen: er bleibt als <div type="add-block"> an
           seiner eigenen Stelle (Abschnitt 5); hier entsteht nichts -->
      <xsl:when test="$regions[@id=$resolvedAddRegionId]/@type='add-block'"/>
      <xsl:when test="$resolvedAddRegionId = ''">
        <xsl:comment> unresolved add-id: <xsl:value-of select="$behelfsId"/> (keine Region mit dieser Behelfs-ID im Export) </xsl:comment>
      </xsl:when>
      <xsl:otherwise>
        <add>
          <!-- Korrektur (siehe Chat): @facs traegt NUR die eigene Zone der
               add-Region - die Zeile, in die importiert wird, wird NICHT mehr
               mitreferenziert (die <lb/> innerhalb des <add> tragen ohnehin
               schon ihre eigenen facs-Verweise auf die add-Region-eigenen
               Zeilen, siehe render-lines/process-line). $lineId wird nur noch
               fuer die Erstimport-Erkennung ($canonicalAddImport) gebraucht. -->
          <xsl:attribute name="facs"><xsl:value-of select="concat('#zone_', $resolvedAddRegionId)"/></xsl:attribute>
          <xsl:call-template name="region-change-attr"><xsl:with-param name="regionId" select="$resolvedAddRegionId"/></xsl:call-template>
          <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$regions[@id=$resolvedAddRegionId]/@rendition"/></xsl:call-template>
          <xsl:if test="$genIdHit and $isCanonicalImport">
            <xsl:attribute name="xml:id"><xsl:value-of select="$genIdHit[1]/@genid"/></xsl:attribute>
          </xsl:if>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$resolvedAddRegionId"/>
            <xsl:with-param name="depth" select="1"/>
            <xsl:with-param name="compact" select="true()"/>
          </xsl:call-template>
        </add>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Einrueckungseinheit pro Ebene fuer die manuelle Einrueckung. Muss zur
       Einrueckung des Serialisierers passen, damit <lb/>-Zeilen und die
       automatisch eingerueckten Tags (<p>, <metamark>, ...) buendig stehen:
       Saxon (Oxygen) rueckt standardmaessig mit 3 Leerzeichen ein, xsltproc/
       libxml2 mit 2 - fuer xsltproc daher
       dem Parameter indentUnit zwei Leerzeichen uebergeben. -->
  <xsl:param name="indentUnit" select="'   '"/>

  <!-- $depth mal $indentUnit (fuer die manuelle Einrueckung von
       Mischinhalt, den der Serialisierer nicht automatisch einrueckt) -->
  <xsl:template name="indent">
    <xsl:param name="depth"/>
    <xsl:if test="$depth &gt; 0">
      <xsl:value-of select="$indentUnit"/>
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
    <xsl:variable name="cat">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'cat'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="subcatV">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'subcat'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="sourceV">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'source'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="changeV">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'change'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="fixedLines">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'fixed-lines'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="blockExtent">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'block-extent'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="singlePArticle">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'single-p-article'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="reasonV">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'reason'"/>
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
    <xsl:variable name="function">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'function'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="target">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'target'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="behelfsId">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'id'"/>
      </xsl:call-template>
    </xsl:variable>
    <!-- metamark-deleatur (Abschnitt 5, metamark-shortcuts): Korrekturfaehnchen +
         Deleatur; wird intern wie eine metamark-Region behandelt, mit function
         "deletion" (sofern nicht ausdruecklich anders angegeben); der
         urspruengliche Typ bleibt in @rawType (facsimile-Zone) erhalten -->
    <xsl:variable name="typeNorm">
      <xsl:choose>
        <xsl:when test="$type='metamark-deleatur'">metamark</xsl:when>
        <xsl:otherwise><xsl:value-of select="$type"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="functionNorm">
      <xsl:choose>
        <xsl:when test="$type='metamark-deleatur' and $function=''">deletion</xsl:when>
        <xsl:otherwise><xsl:value-of select="$function"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <my:region id="{@id}" type="{$typeNorm}" rawType="{$type}" deleatur="{boolean($type='metamark-deleatur')}" cat="{$cat}" subcat="{$subcatV}" source="{$sourceV}" change="{$changeV}" fixedLines="{$fixedLines}" blockExtent="{$blockExtent}" singlePArticle="{$singlePArticle}" reason="{$reasonV}" compositOrder="{$compositOrder}" index="{$index}" rendition="{$rendition}"
            function="{$functionNorm}" target="{$target}" behelfsId="{$behelfsId}"
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
      <!-- explizite has-parent-Relation hat Vorrang (nur wenn die Elternregion
           existiert und nicht die aeusserste surface das Kind ist) -->
      <xsl:when test="$hasParent[@child=$me/@id] and $regions[@id=$hasParent[@child=$me/@id][1]/@parent] and $me/@id != $baseId">
        <xsl:value-of select="$hasParent[@child=$me/@id][1]/@parent"/>
      </xsl:when>
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
        <!-- Sonderregel fuer metamark-Zonen mit @target (siehe verarbeitungsregeln.md
             Abschnitt 3): eine metamark, die auf ein anderes Element verweist,
             wird NICHT in die kleinste umschliessende Zone genestet, sondern
             direkt Kind der (kleinsten passenden) surface. -->
        <xsl:variable name="isTargetedMetamark" select="($me/@type='annotation' or $me/@type='metamark') and $me/@target != ''"/>
        <xsl:variable name="zoneCandidates" select="$regions[@type != 'surface' and @id != $me/@id]"/>
        <xsl:variable name="foundZone">
          <xsl:if test="not($isTargetedMetamark)">
            <xsl:call-template name="find-parent-id">
              <xsl:with-param name="me" select="$me"/>
              <xsl:with-param name="candidates" select="$zoneCandidates"/>
            </xsl:call-template>
          </xsl:if>
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
          <!-- Zusatzbedingung (Abschnitt 3): der Mittelpunkt der Bounding-Box von
               $me muss im ECHTEN Polygon des Kandidaten liegen. Die reine
               Bounding-Box-Naeherung rechnet schraege Polygone (z.B. eine
               aufgeklebte, schief liegende surface) zu gross; so fiele eine
               Zone am Rand faelschlich hinein. -->
          <xsl:variable name="candPoints" select="string($allRegions[@id=current()/@id]/*[local-name()='Coords']/@points)"/>
          <xsl:variable name="centerInside">
            <xsl:choose>
              <xsl:when test="$candPoints = ''">1</xsl:when>
              <xsl:otherwise>
                <xsl:call-template name="point-in-polygon">
                  <xsl:with-param name="x" select="(number($me/@minX) + number($me/@maxX)) div 2"/>
                  <xsl:with-param name="y" select="(number($me/@minY) + number($me/@maxY)) div 2"/>
                  <xsl:with-param name="pts" select="$candPoints"/>
                </xsl:call-template>
              </xsl:otherwise>
            </xsl:choose>
          </xsl:variable>
          <xsl:if test="$centerInside = '1'">
            <my:cand id="{@id}" area="{@area}"/>
          </xsl:if>
        </xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <xsl:for-each select="exsl:node-set($qualifyingRTF)/my:cand">
      <xsl:sort select="@area" data-type="number" order="ascending"/>
      <xsl:if test="position()=1"><xsl:value-of select="@id"/></xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- Punkt-im-Polygon (Strahlverfahren, Paritaet der Kantenschnitte):
       liefert 1, wenn (x,y) im Polygon "x,y x,y ..." liegt, sonst 0. Laeuft
       rekursiv ueber die Eckpunkte; px/py/count sind Hilfsparameter. -->
  <xsl:template name="point-in-polygon">
    <xsl:param name="x"/>
    <xsl:param name="y"/>
    <xsl:param name="pts"/>
    <xsl:param name="firstX" select="''"/>
    <xsl:param name="firstY" select="''"/>
    <xsl:param name="px" select="''"/>
    <xsl:param name="py" select="''"/>
    <xsl:param name="count" select="0"/>
    <xsl:variable name="rest" select="normalize-space($pts)"/>
    <xsl:choose>
      <xsl:when test="$rest = ''">
        <!-- Schlusskante: letzter Punkt -> erster Punkt -->
        <xsl:variable name="closing">
          <xsl:call-template name="edge-crosses">
            <xsl:with-param name="x" select="$x"/><xsl:with-param name="y" select="$y"/>
            <xsl:with-param name="x1" select="$px"/><xsl:with-param name="y1" select="$py"/>
            <xsl:with-param name="x2" select="$firstX"/><xsl:with-param name="y2" select="$firstY"/>
          </xsl:call-template>
        </xsl:variable>
        <xsl:value-of select="($count + number($closing)) mod 2"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="tok">
          <xsl:choose>
            <xsl:when test="contains($rest,' ')"><xsl:value-of select="substring-before($rest,' ')"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="$rest"/></xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:variable name="cx" select="number(substring-before($tok,','))"/>
        <xsl:variable name="cy" select="number(substring-after($tok,','))"/>
        <xsl:variable name="edge">
          <xsl:choose>
            <xsl:when test="$px = ''">0</xsl:when>
            <xsl:otherwise>
              <xsl:call-template name="edge-crosses">
                <xsl:with-param name="x" select="$x"/><xsl:with-param name="y" select="$y"/>
                <xsl:with-param name="x1" select="$px"/><xsl:with-param name="y1" select="$py"/>
                <xsl:with-param name="x2" select="$cx"/><xsl:with-param name="y2" select="$cy"/>
              </xsl:call-template>
            </xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:call-template name="point-in-polygon">
          <xsl:with-param name="x" select="$x"/>
          <xsl:with-param name="y" select="$y"/>
          <xsl:with-param name="pts" select="substring-after($rest,' ')"/>
          <xsl:with-param name="firstX"><xsl:choose><xsl:when test="$firstX = ''"><xsl:value-of select="$cx"/></xsl:when><xsl:otherwise><xsl:value-of select="$firstX"/></xsl:otherwise></xsl:choose></xsl:with-param>
          <xsl:with-param name="firstY"><xsl:choose><xsl:when test="$firstY = ''"><xsl:value-of select="$cy"/></xsl:when><xsl:otherwise><xsl:value-of select="$firstY"/></xsl:otherwise></xsl:choose></xsl:with-param>
          <xsl:with-param name="px" select="$cx"/>
          <xsl:with-param name="py" select="$cy"/>
          <xsl:with-param name="count" select="$count + number($edge)"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- 1, wenn der waagrechte Strahl von (x,y) nach rechts die Kante
       (x1,y1)-(x2,y2) schneidet, sonst 0 -->
  <xsl:template name="edge-crosses">
    <xsl:param name="x"/><xsl:param name="y"/>
    <xsl:param name="x1"/><xsl:param name="y1"/><xsl:param name="x2"/><xsl:param name="y2"/>
    <xsl:choose>
      <xsl:when test="((number($y1) &gt; number($y)) != (number($y2) &gt; number($y))) and (number($x) &lt; (number($x2) - number($x1)) * (number($y) - number($y1)) div (number($y2) - number($y1)) + number($x1))">1</xsl:when>
      <xsl:otherwise>0</xsl:otherwise>
    </xsl:choose>
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

  <!-- Abschnitt 7a: eine ununterbrochene Gruppe von MEHR als einem "#"
       (also Laenge >= 2) wird zu <gap reason="illegible" extent="N"/>; ein einzelnes
       "#" bleibt literaler Text. Wird an jeder Stelle aufgerufen, an der
       sonst rohe Zeichenspannen als Text ausgegeben werden (Klartext
       zwischen/nach annotierten Bereichen). -->
  <!-- Abschnitt 7a: Textstring-Transformationen. Wird VOR allem anderen
       geprueft: ist der GESAMTE uebergebene Textabschnitt exakt "|" (kein
       Zeichen davor/danach), gilt "|" als onlychild einer bereits
       bestehenden, als Textannotation angelegten metamark (die typischen
       Faelle: eine annotation/metamark-Region, deren einzige Zeile nur "|"
       enthaelt, ggf. zusaetzlich von einem Meilenstein wie undo umschlossen
       - text-with-gaps bekommt dann als Leaf-Text genau "|" uebergeben) -
       dann wird NUR das <g ref="#intervention"/> eingesetzt, OHNE neue
       umschliessende metamark (die existiert ja schon aussenrum). In jedem
       anderen Fall (Text drumherum vorhanden) wird "|" wie #del/#ker/#lSpc/
       #rel/#trans in eine eigene <metamark function="intervention"><g/></metamark>
       gepackt. -->
  <xsl:template name="text-with-gaps">
    <xsl:param name="txt"/>
    <xsl:choose>
      <xsl:when test="$txt = '|'">
        <g ref="#intervention"/>
      </xsl:when>
      <xsl:when test="contains($txt,'#') or contains($txt,'|')">
        <xsl:variable name="hashPos">
          <xsl:choose>
            <xsl:when test="contains($txt,'#')"><xsl:value-of select="string-length(substring-before($txt,'#'))"/></xsl:when>
            <xsl:otherwise>-1</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:variable name="pipePos">
          <xsl:choose>
            <xsl:when test="contains($txt,'|')"><xsl:value-of select="string-length(substring-before($txt,'|'))"/></xsl:when>
            <xsl:otherwise>-1</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:choose>
          <!-- naechstgelegenes Vorkommen zuerst behandeln (# und | koennen
               beide im selben Textstueck vorkommen, z.B. "| #del") -->
          <xsl:when test="number($hashPos) &gt;= 0 and (number($pipePos) &lt; 0 or number($hashPos) &lt;= number($pipePos))">
            <xsl:variable name="before" select="substring($txt, 1, number($hashPos))"/>
            <xsl:variable name="rest" select="substring($txt, number($hashPos) + 1)"/>
            <xsl:value-of select="$before"/>
            <xsl:choose>
              <xsl:when test="starts-with($rest,'#del')">
                <metamark function="deletion"><g ref="#deleatur"/></metamark>
                <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($rest,5)"/></xsl:call-template>
              </xsl:when>
              <xsl:when test="starts-with($rest,'#ker')">
                <metamark function="kerning"><g ref="#kerning"/></metamark>
                <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($rest,5)"/></xsl:call-template>
              </xsl:when>
              <xsl:when test="starts-with($rest,'#lSpc')">
                <metamark function="line-spacing"><g ref="#line-spacing"/></metamark>
                <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($rest,6)"/></xsl:call-template>
              </xsl:when>
              <xsl:when test="starts-with($rest,'#rel')">
                <metamark function="relocation"><g ref="#relocation"/></metamark>
                <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($rest,5)"/></xsl:call-template>
              </xsl:when>
              <xsl:when test="starts-with($rest,'#spcIns')">
                <metamark function="space-insert"><g ref="#space-insert"/></metamark>
                <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($rest,8)"/></xsl:call-template>
              </xsl:when>
              <xsl:when test="starts-with($rest,'#trans')">
                <metamark function="transposition"><g ref="#transposition"/></metamark>
                <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($rest,7)"/></xsl:call-template>
              </xsl:when>
              <xsl:when test="starts-with($rest,'##')">
                <xsl:variable name="afterFirstTwo" select="substring($rest,3)"/>
                <xsl:variable name="extraRTF">
                  <xsl:call-template name="count-leading-hashes"><xsl:with-param name="s" select="$afterFirstTwo"/></xsl:call-template>
                </xsl:variable>
                <xsl:variable name="extra" select="number($extraRTF)"/>
                <!-- Abschnitt 7a: ein nicht als gap annotierter Lauf von mehr als
                     einem "#" wird zu <gap reason="illegible" extent="N"/> -->
                <gap reason="illegible" extent="{2 + $extra}"/>
                <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($afterFirstTwo, $extra + 1)"/></xsl:call-template>
              </xsl:when>
              <xsl:otherwise>
                <!-- einzelnes "#", das keinem der obigen Muster entspricht
                     und auch kein Lauf ist: bleibt literaler Text -->
                <xsl:text>#</xsl:text>
                <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($rest,2)"/></xsl:call-template>
              </xsl:otherwise>
            </xsl:choose>
          </xsl:when>
          <xsl:otherwise>
            <xsl:variable name="before" select="substring($txt, 1, number($pipePos))"/>
            <xsl:variable name="rest" select="substring($txt, number($pipePos) + 2)"/>
            <xsl:value-of select="$before"/>
            <metamark function="intervention"><g ref="#intervention"/></metamark>
            <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="$rest"/></xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$txt"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Anzahl der "#" am Anfang von $s -->
  <xsl:template name="count-leading-hashes">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="starts-with($s,'#')">
        <xsl:variable name="restRTF"><xsl:call-template name="count-leading-hashes"><xsl:with-param name="s" select="substring($s,2)"/></xsl:call-template></xsl:variable>
        <xsl:value-of select="1 + number($restRTF)"/>
      </xsl:when>
      <xsl:otherwise>0</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Gesamtzahl der Vorkommen von $char (ein einzelnes Zeichen) in $s,
       egal an welcher Position (nicht nur fuehrend) - fuer gap-cut/extent -->
  <xsl:template name="count-char">
    <xsl:param name="s"/>
    <xsl:param name="char"/>
    <xsl:choose>
      <xsl:when test="contains($s,$char)">
        <xsl:variable name="restRTF"><xsl:call-template name="count-char"><xsl:with-param name="s" select="substring-after($s,$char)"/><xsl:with-param name="char" select="$char"/></xsl:call-template></xsl:variable>
        <xsl:value-of select="1 + number($restRTF)"/>
      </xsl:when>
      <xsl:otherwise>0</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- schreitet eine del-Kette ab: gibt je Kettenglied (id) ein
       <my:cm chain=".." id=".." first="y|" last="y|"/> aus und folgt next, solange
       dessen Ziel als id eines del-Bereichs existiert (Tiefenbegrenzung gegen
       Zyklen) -->
  <xsl:template name="del-chain-walk">
    <xsl:param name="id"/>
    <xsl:param name="chainNo"/>
    <xsl:param name="depth" select="1"/>
    <xsl:variable name="dcNext" select="string($allLineRanges[@element='del' and my:attr[@name='id']/@value=$id and my:attr[@name='next']][1]/my:attr[@name='next']/@value)"/>
    <xsl:variable name="dcGo" select="$dcNext != '' and $depth &lt; 200 and boolean($allLineRanges[@element='del' and my:attr[@name='id']/@value=$dcNext])"/>
    <my:cm chain="{$chainNo}" id="{$id}">
      <xsl:if test="$depth = 1"><xsl:attribute name="first">y</xsl:attribute></xsl:if>
      <xsl:if test="not($dcGo)"><xsl:attribute name="last">y</xsl:attribute></xsl:if>
    </my:cm>
    <xsl:if test="$dcGo">
      <xsl:call-template name="del-chain-walk">
        <xsl:with-param name="id" select="$dcNext"/>
        <xsl:with-param name="chainNo" select="$chainNo"/>
        <xsl:with-param name="depth" select="$depth + 1"/>
      </xsl:call-template>
    </xsl:if>
  </xsl:template>

  <!-- Korrektur (siehe Chat): faellt das Ende eines deselection-Bereichs
       (also die Position, an der dessen <anchor> stehen wuerde) GENAU mit
       dem Ende eines umschliessenden subst/subst-del-synth zusammen, soll
       der <anchor> NICHT innerhalb von dessen <del> landen, sondern ERST
       NACH dem kompletten </subst>. Diese Funktion laeuft von einem
       Bereich ($idx) aus die Eltern-Kette hoch, SOLANGE deren @end exakt
       uebereinstimmt (nur dann "beruehrt" der Abschluss wirklich den
       Aussenrand des jeweiligen Eltern-Bereichs), und merkt sich dabei den
       AEUSSERSTEN Vorfahren, der selbst subst/subst-del-synth ist. Liefert
       dessen @idx, oder leer, wenn kein solcher Vorfahre existiert (dann
       bleibt der <anchor> wie gehabt direkt an seiner urspruenglichen
       Stelle stehen). -->
  <xsl:template name="relocation-target-for">
    <xsl:param name="ranges"/>
    <xsl:param name="rangeParents"/>
    <xsl:param name="idx"/>
    <xsl:param name="best" select="''"/>
    <xsl:variable name="me" select="$ranges[@idx=$idx]"/>
    <xsl:variable name="parentIdx" select="$rangeParents[@idx=$idx]/@parent"/>
    <xsl:choose>
      <xsl:when test="not($parentIdx) or $parentIdx='0'">
        <xsl:value-of select="$best"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="parent" select="$ranges[@idx=$parentIdx]"/>
        <xsl:choose>
          <xsl:when test="number($parent/@end) = number($me/@end)">
            <xsl:variable name="newBest">
              <xsl:choose>
                <xsl:when test="$parent/@element='subst' or $parent/@element='subst-del-synth'"><xsl:value-of select="$parentIdx"/></xsl:when>
                <xsl:otherwise><xsl:value-of select="$best"/></xsl:otherwise>
              </xsl:choose>
            </xsl:variable>
            <xsl:call-template name="relocation-target-for">
              <xsl:with-param name="ranges" select="$ranges"/>
              <xsl:with-param name="rangeParents" select="$rangeParents"/>
              <xsl:with-param name="idx" select="$parentIdx"/>
              <xsl:with-param name="best" select="$newBest"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <xsl:value-of select="$best"/>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- das Ende-<anchor> einer del/deselection-Kette (xml:id, type vom delSpan) -->
  <xsl:template name="desel-end-anchor">
    <xsl:param name="id"/>
    <anchor>
      <xsl:if test="string($deselPairIds[@id=$id]/@type) != ''"><xsl:attribute name="type"><xsl:value-of select="$deselPairIds[@id=$id]/@type"/></xsl:attribute></xsl:if>
      <xsl:attribute name="xml:id"><xsl:value-of select="$id"/></xsl:attribute>
    </anchor>
  </xsl:template>

  <!-- Kehrseite von relocation-target-for: wird beim Rendern eines
       subst/subst-del-synth-Bereichs ($myIdx) aufgerufen, NACHDEM dessen
       </subst> bereits geschlossen ist. Durchsucht alle deselection-
       Bereiche dieser Zeile mit Rolle "end" (siehe $deselMarkers) und
       liefert die delSpan-ID desjenigen, dessen relocation-target genau
       $myIdx ist - also dessen <anchor> hierher verschoben werden muss.
       Leer, wenn keiner zutrifft. -->
  <xsl:template name="pending-anchor-id-for">
    <xsl:param name="ranges"/>
    <xsl:param name="rangeParents"/>
    <xsl:param name="myIdx"/>
    <xsl:param name="lineId"/>
    <xsl:variable name="candidatesRTF">
      <xsl:for-each select="$ranges[@element='del']">
        <xsl:variable name="thisIdx" select="@idx"/>
        <xsl:variable name="marker" select="$deselMarkers[@line=$lineId and @offset=current()/@offset]"/>
        <xsl:if test="$marker/@role='end'">
          <xsl:variable name="target">
            <xsl:call-template name="relocation-target-for">
              <xsl:with-param name="ranges" select="$ranges"/>
              <xsl:with-param name="rangeParents" select="$rangeParents"/>
              <xsl:with-param name="idx" select="$thisIdx"/>
            </xsl:call-template>
          </xsl:variable>
          <xsl:if test="$target=$myIdx">
            <my:pending id="{$deselPairIds[@seq=$marker/@pairSeq]/@id}"/>
          </xsl:if>
        </xsl:if>
      </xsl:for-each>
    </xsl:variable>
    <xsl:value-of select="exsl:node-set($candidatesRTF)/my:pending[1]/@id"/>
  </xsl:template>

  <!-- loest eine Behelfs-ID (aus target/add-id/corresp) zu einer echten
       TEI-Pointer-Referenz auf ("#echte-id"); unbekannte Behelfs-IDs werden
       defensiv als "#<roher Wert>" durchgereicht, damit nichts stillschweigend
       verschwindet -->
  <!-- manche Attribute (v.a. target) koennen MEHRERE, durch das literale
       Trennzeichen " " (so kodiert das PAGE-XML ein Leerzeichen
       innerhalb eines einzelnen Attributwerts, siehe z.B.
       "target:456 567;") getrennte Behelfs-IDs enthalten. Jede wird
       einzeln aufgeloest, das Ergebnis ist eine durch ECHTE Leerzeichen
       getrennte TEI-Pointer-Liste (data.pointer-Konvention). -->
  <xsl:variable name="sepMarker">&#92;u0020</xsl:variable>
  <xsl:template name="resolve-behelfs">
    <xsl:param name="behelfsId"/>
    <xsl:choose>
      <xsl:when test="contains($behelfsId,$sepMarker)">
        <xsl:call-template name="resolve-behelfs">
          <xsl:with-param name="behelfsId" select="substring-before($behelfsId,$sepMarker)"/>
        </xsl:call-template>
        <xsl:text> </xsl:text>
        <xsl:call-template name="resolve-behelfs">
          <xsl:with-param name="behelfsId" select="substring-after($behelfsId,$sepMarker)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="hit" select="$behelfsMap[@behelfs=$behelfsId]"/>
        <xsl:choose>
          <!-- dokumentuebergreifender Verweis ("datei.xml#id"): bereits
               fertig, wird unveraendert uebernommen (Abschnitt 8). -->
          <xsl:when test="contains($behelfsId,'.xml#')"><xsl:value-of select="$behelfsId"/></xsl:when>
          <xsl:when test="$hit"><xsl:value-of select="concat('#', $hit[1]/@genid)"/></xsl:when>
          <xsl:otherwise><xsl:value-of select="concat('#', $behelfsId)"/></xsl:otherwise>
        </xsl:choose>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- "prev"/"next" (Behelfs-IDs) als gleichnamige TEI-Attribute, aufgeloest
       wie target (Abschnitt 8) -->
  <xsl:template name="resolved-ref-attrs">
    <xsl:param name="attrs"/>
    <xsl:for-each select="$attrs[@name='prev' or @name='next' or @name='corresp']">
      <xsl:attribute name="{@name}">
        <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="@value"/></xsl:call-template>
      </xsl:attribute>
    </xsl:for-each>
    <!-- rendition (z.B. bei dateline): Werte mit "#" -->
    <xsl:if test="$attrs[@name='rendition']">
      <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$attrs[@name='rendition']/@value"/></xsl:call-template>
    </xsl:if>
  </xsl:template>

  <!-- gibt @target nur aus, wenn mindestens ein Token ein dokumentuebergreifender
       Verweis ("datei.xml#id") ist: solche Ziele koennen nicht eingesogen
       werden, die metamark bleibt als Verweis stehen. -->
  <xsl:template name="foreign-target-attr">
    <xsl:param name="target"/>
    <xsl:if test="contains($target,'.xml#')">
      <xsl:attribute name="target">
        <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$target"/></xsl:call-template>
      </xsl:attribute>
    </xsl:if>
  </xsl:template>

  <!-- gibt das ERSTE Token vor einem  -Trenner zurueck (oder den ganzen
       String, falls keiner vorkommt) - fuer Stellen, die bei mehreren
       Behelfs-IDs nur die erste brauchen (z.B. beim Ketten-Verfolgen). -->
  <xsl:template name="first-behelfs-token">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s,$sepMarker)"><xsl:value-of select="substring-before($s,$sepMarker)"/></xsl:when>
      <xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- wie first-behelfs-token, aber liefert ALLE  -getrennten Tokens
       als <my:tok val=".."/>* (bei nur einem Wert genau ein my:tok) - fuer
       add-id, das gelegentlich mehrere Werte traegt (z.B. metamark-add
       "add-id:dfg fgh;" zieht BEIDE add-Regionen rein). -->
  <xsl:template name="all-behelfs-tokens">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s,$sepMarker)">
        <my:tok val="{substring-before($s,$sepMarker)}"/>
        <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="substring-after($s,$sepMarker)"/></xsl:call-template>
      </xsl:when>
      <xsl:otherwise><my:tok val="{$s}"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Abschnitt 7: verfolgt eine metamark-insertion-Kette (siehe
       $chainConsumedMetamarks oben) bis zum Ende: loest $behelfsId auf; ist
       das Ziel selbst wieder eine metamark mit function="insertion" und
       eigenem @target, wird mit DESSEN target weiterverfolgt; sonst wird
       die erreichte Regions-@id zurueckgegeben (im Normalfall eine
       add-Region). -->
  <xsl:template name="resolve-insertion-chain">
    <xsl:param name="behelfsId"/>
    <xsl:variable name="firstId"><xsl:call-template name="first-behelfs-token"><xsl:with-param name="s" select="$behelfsId"/></xsl:call-template></xsl:variable>
    <xsl:variable name="regionId" select="$behelfsMap[@behelfs=$firstId][1]/@region"/>
    <xsl:variable name="region" select="$regions[@id=$regionId]"/>
    <xsl:choose>
      <xsl:when test="$region/@type='metamark' and $region/@function='insertion' and $region/@target != ''">
        <xsl:call-template name="resolve-insertion-chain">
          <xsl:with-param name="behelfsId" select="$region/@target"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$regionId"/>
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
