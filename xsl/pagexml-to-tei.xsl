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
    - surface -> <div facs="#surface_...">, aeusserste = type="base"
    - zone type "column-block"/"add-block" -> immer <div type="...">
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
      (spacing/hi-*/bold/underline/mod/mod-underline/del/deselection/seg/
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
        <my:lr line="{$lnId}" idx="{@idx}" offset="{@offset}" end="{@end}" element="{@element}" continued="{@continued}">
          <xsl:copy-of select="my:attr"/>
        </my:lr>
      </xsl:for-each>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="allLineRanges" select="exsl:node-set($allLineRangesRTF)/my:lr"/>

  <xsl:param name="lineAssignTolerance" select="20"/>

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
          <xsl:when test="$parentNearHit"><xsl:value-of select="$parentRegionId"/></xsl:when>
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
            <xsl:if test="starts-with($ttype,'paragraph') or $ttype='head' or $ttype='gap' or starts-with($ttype,'long-quote')">
              <my:relmember region="{$rid}" group="{$gid}" type="{$relNameLower}"/>
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
      <xsl:variable name="par" select="string($parents[@id=current()/@region]/@of)"/>
      <xsl:variable name="qh"><xsl:call-template name="is-quote-host"><xsl:with-param name="id" select="$par"/></xsl:call-template></xsl:variable>
      <xsl:if test="$qh != 'yes'">
        <my:fr group="{@group}" parent="{$par}" idx="{$regions[@id=current()/@region]/@index}"/>
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
    <xsl:for-each select="$allLineRanges[my:attr[@name='id']]">
      <my:d tag="{@element}" behelfs="{my:attr[@name='id']/@value}"/>
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

  <!-- laufende Nummer jedes "undo"-Blocks (Abschnitt 7/8) in Dokumentreihenfolge,
       fuer die generierte anchor-Seitenzahl-Nummer-ID (Behelfs-ID-Vergabe wie
       oben, aber ohne Bezug zu einer deklarierten Behelfs-ID in den Daten -
       "id" wird hier komplett neu erzeugt). Jede Zeile traegt hoechstens
       einen undo-Block pro Zeichenbereich, daher genuegt (Zeile, offset) als
       eindeutiger Schluessel. -->
  <xsl:variable name="undoOrderRawRTF">
    <xsl:for-each select="$allLineRanges[@element='undo']">
      <my:u line="{@line}" offset="{@offset}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="undoOrderRTF">
    <xsl:for-each select="exsl:node-set($undoOrderRawRTF)/my:u">
      <my:u line="{@line}" offset="{@offset}" seq="{position()}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="undoOrder" select="exsl:node-set($undoOrderRTF)/my:u"/>

  <!-- ===================== deselection: delSpan/anchor-Paare =====================
       Korrektur (siehe Chat): "deselection" mit @part wird NICHT mehr als ein
       oder mehrere <del>...</del>-Paare gerendert, sondern als GENAU EIN
       leeres <delSpan target="#X"/> an der Stelle des ERSTEN Vorkommens mit
       part "I"/"i" und EIN leeres <anchor xml:id="X"/> an der Stelle des
       LETZTEN Vorkommens mit part "F"/"f" - alles dazwischen (auch ueber
       Regionsgrenzen, Zeilen und andere Annotationen wie subst-del hinweg)
       bleibt unveraendert/unverpackt stehen. Alle "inneren" Wiederholungen
       der deselection auf den Zwischenzeilen (dieselbe @part-Gruppe, kommt
       in den Daten aus dem staendigen "continued:true" pro Zeile) sind reine
       Ketten-Fortsetzungen und werden komplett ignoriert (keine eigene
       Ausgabe). "deselection" OHNE @part ist davon nicht betroffen und wird
       weiterhin normal als <del type="deselection"> gerendert. -->

  <!-- alle del-Bereiche mit @part, in Dokumentreihenfolge -->
  <xsl:variable name="delWithPartRTF">
    <xsl:for-each select="$allLineRanges[@element='del' and my:attr[@name='part']]">
      <my:d line="{@line}" offset="{@offset}" part="{my:attr[@name='part']/@value}"/>
    </xsl:for-each>
  </xsl:variable>
  <xsl:variable name="delWithPart" select="exsl:node-set($delWithPartRTF)/my:d"/>

  <xsl:variable name="deselMarkersRTF">
    <xsl:call-template name="pair-desel-groups">
      <xsl:with-param name="items" select="$delWithPart"/>
    </xsl:call-template>
  </xsl:variable>
  <xsl:variable name="deselMarkers" select="exsl:node-set($deselMarkersRTF)/my:marker"/>

  <!-- xml:id des <anchor> (Ende) jedes delSpan-Paars: traegt der letzte Block
       des Paars (part F) eine eigene id (Behelfs-ID, auf die z.B. das next
       des Start-Blocks verweist), ist das deren echte xml:id - sonst die
       generierte delSpan-PPPP-NNNN. Zentral berechnet, damit delSpan/@spanTo,
       <anchor> und nachgezogener <anchor> dieselbe ID verwenden. -->
  <xsl:variable name="deselPairIdsRTF">
    <xsl:for-each select="$deselMarkers[@role='end']">
      <xsl:variable name="endR" select="$allLineRanges[@line=current()/@line and @offset=current()/@offset and @element='del' and my:attr[@name='part']][1]"/>
      <xsl:variable name="endHit" select="$behelfsMap[@behelfs=$endR/my:attr[@name='id']/@value]"/>
      <xsl:variable name="padded"><xsl:call-template name="pad4"><xsl:with-param name="s" select="@pairSeq"/></xsl:call-template></xsl:variable>
      <my:pid seq="{@pairSeq}" line="{@line}" offset="{@offset}">
        <xsl:attribute name="id">
          <xsl:choose>
            <xsl:when test="$endHit"><xsl:value-of select="$endHit[1]/@genid"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="concat('delSpan-', $pageNumPadded, '-', $padded)"/></xsl:otherwise>
          </xsl:choose>
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
        <xsl:if test="$regionId != ''"><my:c id="{$regionId}"/></xsl:if>
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
        <xsl:if test="$regionId != ''"><my:site region="{$regionId}" line="{$lnLine}"/></xsl:if>
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
          <xsl:call-template name="render-line-zones-for-region"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
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
      <xsl:for-each select="$childEntries[not(@id = $consumedAddRegions/@id)]">
        <xsl:variable name="childId" select="@id"/>
        <xsl:variable name="rel" select="$relMembers[@region=$childId]"/>
        <xsl:choose>
          <xsl:when test="$rel and not($inlineMode)">
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
              <my:unit id="{$childId}" kind="p" group="" qgroup="{$qGroup}" index="{$regions[@id=$childId]/@index}" own=""/>
            </xsl:if>
          </xsl:when>
          <xsl:otherwise>
            <xsl:variable name="kind"><xsl:call-template name="child-kind"><xsl:with-param name="id" select="$childId"/></xsl:call-template></xsl:variable>
            <!-- single-p-article:y (Abschnitt 5): der <p> steht in einem
                 <div type="article"> (zaehlt deshalb als div-Einheit) -->
            <xsl:variable name="spa" select="$regions[@id=$childId]/@singlePArticle"/>
            <my:unit id="{$childId}" index="{$regions[@id=$childId]/@index}" own="" group="" spa="{$spa}">
              <xsl:attribute name="kind"><xsl:choose><xsl:when test="$spa='y' and $kind='p'">div</xsl:when><xsl:otherwise><xsl:value-of select="$kind"/></xsl:otherwise></xsl:choose></xsl:attribute>
            </my:unit>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:for-each>
    </xsl:variable>
    <xsl:variable name="units" select="exsl:node-set($unitsRTF)/my:unit"/>
    <xsl:variable name="mixed" select="not($inlineMode) and boolean($units[@kind='div']) and boolean($units[@kind='p' or @kind='head'])"/>

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
              <xsl:call-template name="rendition-attr-if-any"><xsl:with-param name="value" select="$regions[@id=$ownTextRegionId]/@rendition"/></xsl:call-template>
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
              <xsl:with-param name="parentId" select="string($id)"/>
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
    <xsl:if test="$inlineMode and $units[not(@own='yes')]">
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
      <xsl:variable name="kids" select="$regions[@id=$parents[@of=$id]/@id][not(@id = $consumedAddRegions/@id)]"/>
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
      <xsl:when test="$region/@type='column-block' or $region/@type='add-block'">div</xsl:when>
      <xsl:when test="boolean($parents[@of=$id])">div</xsl:when>
      <!-- <fw> darf in TEI direkt neben <div> stehen (wie metamark/gap) und
           muss deshalb nicht in ein <div> gewickelt werden (siehe Mixing-
           Regel in render-children-text) -->
      <xsl:when test="$region/@type='fw'">fw</xsl:when>
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
    <xsl:variable name="hasChildren" select="boolean($parents[@of=$id])"/>
    <xsl:variable name="quoteHost"><xsl:call-template name="is-quote-host"><xsl:with-param name="id" select="$id"/></xsl:call-template></xsl:variable>
    <xsl:choose>
      <xsl:when test="$type='surface'">div</xsl:when>
      <xsl:when test="$type='annotation' or $type='metamark'">metamark</xsl:when>
      <xsl:when test="$type='gap'">gap</xsl:when>
      <xsl:when test="$quoteHost='yes'">p</xsl:when>
      <xsl:when test="$type='head' and not($hasChildren) and $region/@cat='cross'">p</xsl:when>
      <xsl:when test="$type='head' and not($hasChildren)">head</xsl:when>
      <xsl:when test="$type='column-block' or $type='add-block' or $type='advertisement' or $type='masthead' or $hasChildren">div</xsl:when>
      <xsl:when test="$type='add'">add</xsl:when>
      <xsl:when test="$type='fw'">fw</xsl:when>
      <xsl:when test="$type='long-quote-lg'">lg</xsl:when>
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
      <xsl:for-each select="$memberIds">
        <xsl:sort select="$regions[@id=current()]/@index" data-type="number"/>
        <xsl:variable name="mid" select="."/>
        <xsl:variable name="qGroup" select="$quoteMembers[@region=$mid][1]/@group"/>
        <xsl:choose>
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
    <xsl:variable name="hasChildren" select="boolean($parents[@of=$id])"/>
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
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:attribute name="rendition">#crosshead</xsl:attribute>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
        </p>
      </xsl:when>
      <xsl:when test="$type='head' and not($hasChildren)">
        <head>
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:if test="$region/@cat='main' or $region/@cat='sub'"><xsl:attribute name="type"><xsl:value-of select="$region/@cat"/></xsl:attribute></xsl:if>
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
      <xsl:when test="$type='column-block' or $type='add-block' or $type='advertisement' or $type='masthead' or $hasChildren">
        <div>
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
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
          <xsl:call-template name="behelfs-id-attr-if-any"><xsl:with-param name="regionId" select="$id"/></xsl:call-template>
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
    <xsl:for-each select="exsl:node-set($pairsRTF)/my:kv[@name != 'type' and @name != 'subtype' and @name != 'composit-order' and @name != 'rendition' and @name != 'id' and @name != 'function' and @name != 'target' and @name != 'hand-medium' and @name != 'single-p-article' and @name != 'prev' and @name != 'next']">
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
      <xsl:when test="$isChainInitiator and $regions[@id=$chainTargetRegionId]/@type='add'">
        <metamark facs="{concat('#zone_',$id)}" function="insertion">
          <xsl:attribute name="xml:id"><xsl:value-of select="$ownId"/></xsl:attribute>
          <xsl:call-template name="foreign-target-attr"><xsl:with-param name="target" select="$region/@target"/></xsl:call-template>
        </metamark>
        <xsl:call-template name="render-imported-add">
          <xsl:with-param name="addRegionId" select="$chainTargetRegionId"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <metamark>
          <xsl:attribute name="xml:id"><xsl:value-of select="$ownId"/></xsl:attribute>
          <xsl:attribute name="facs">#zone_<xsl:value-of select="$id"/></xsl:attribute>
          <xsl:if test="$region/@function != ''">
            <xsl:attribute name="function"><xsl:value-of select="$region/@function"/></xsl:attribute>
          </xsl:if>
          <xsl:if test="$region/@target != ''">
            <xsl:attribute name="target">
              <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$region/@target"/></xsl:call-template>
            </xsl:attribute>
          </xsl:if>
          <xsl:call-template name="render-lines">
            <xsl:with-param name="regionId" select="$id"/>
            <xsl:with-param name="depth" select="$depth + 1"/>
          </xsl:call-template>
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
      <lb facs="#zone_{$line/@id}"/>

      <xsl:choose>
        <xsl:when test="not($ranges)">
          <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="$text"/></xsl:call-template>
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
            <!-- "undo" und "deselection mit @part" werden nie zeilenuebergreifend
                 in EIN Element zusammengefasst - beide werden stattdessen als
                 Meilenstein-Paar gerendert (render-one-range), das ueber die
                 global vorberechneten $undoOrder/$deselMarkers auch ueber
                 Regionsgrenzen hinweg zusammenpasst; die klassische
                 render-run-span-Klammerung (EIN umschliessendes Element)
                 wuerde hier nicht mehr passen. -->
            <xsl:when test="$lastTop/@continued='true' and not($lastTopHasChildren) and $lastTop/@element != 'undo' and not($lastTop/@element='del' and $lastTop/my:attr[@name='part'])">
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
                <xsl:with-param name="lineId" select="$line/@id"/>
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
    <xsl:for-each select="$blocks[not(@name='head-run-in' and not(contains(@content,'offset'))) and (@name='head-run-in' or @name='spacing' or @name='hi-spacing' or @name='bold' or @name='hi-bold' or @name='underline' or @name='hi-underline' or @name='mod-underline' or @name='del' or @name='deselection' or @name='mod' or @name='seg-transposition' or @name='seg' or @name='gap' or @name='gap-cut' or @name='gap-ill' or @name='add' or @name='metamark' or @name='metamark-add' or @name='unclear' or @name='subst' or @name='subst-del' or @name='sic' or @name='undo')]">
      <xsl:variable name="name" select="@name"/>
      <xsl:variable name="content" select="@content"/>
      <xsl:variable name="offset"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'offset'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="length"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'length'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="continued"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'continued'"/></xsl:call-template></xsl:variable>
      <xsl:variable name="element">
        <xsl:choose>
          <xsl:when test="$name='spacing' or $name='hi-spacing' or $name='bold' or $name='hi-bold' or $name='underline' or $name='hi-underline'">hi</xsl:when>
          <xsl:when test="$name='mod-underline'">mod</xsl:when>
          <xsl:when test="$name='del' or $name='deselection'">del</xsl:when>
          <xsl:when test="$name='mod'">mod</xsl:when>
          <xsl:when test="$name='seg' or $name='seg-transposition' or $name='head-run-in'">seg</xsl:when>
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
        <xsl:choose>
          <xsl:when test="$name='spacing' or $name='hi-spacing'"><my:attr name="style" value="letter-spacing"/></xsl:when>
          <xsl:when test="$name='bold' or $name='hi-bold'"><my:attr name="style" value="bold"/></xsl:when>
          <xsl:when test="$name='underline' or $name='hi-underline'"><my:attr name="style" value="underline"/></xsl:when>
          <xsl:when test="$name='mod-underline'"><my:attr name="style" value="underline"/></xsl:when>
          <xsl:when test="$name='mod'">
            <xsl:variable name="styleOverride"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'style'"/></xsl:call-template></xsl:variable>
            <xsl:choose>
              <xsl:when test="$styleOverride != ''"><my:attr name="style" value="{$styleOverride}"/></xsl:when>
              <xsl:otherwise><my:attr name="style" value="underline"/></xsl:otherwise>
            </xsl:choose>
          </xsl:when>
          <xsl:when test="$name='del'">
            <xsl:variable name="type"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'type'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$type != ''"><my:attr name="type" value="{$type}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='deselection'">
            <xsl:variable name="part"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'part'"/></xsl:call-template></xsl:variable>
            <my:attr name="type" value="deselection"/>
            <xsl:if test="$part != ''"><my:attr name="part" value="{$part}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='seg'">
            <xsl:variable name="type"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'type'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$type != ''"><my:attr name="type" value="{$type}"/></xsl:if>
          </xsl:when>
          <!-- head-run-in (Abschnitt 7) -> <seg type="head-run-in"> -->
          <xsl:when test="$name='head-run-in'"><my:attr name="type" value="head-run-in"/></xsl:when>
          <xsl:when test="$name='seg-transposition'">
            <my:attr name="type" value="transposition"/>
            <!-- Die volle listTranspose/ptr-Konstruktion (Abschnitt 7: nur
                 wenn corresp UND new-order vorhanden sind) ist NICHT
                 umgesetzt - in keiner der vorliegenden Dateien kommen diese
                 beiden Werte vor (immer nur offset/length), es gibt also
                 keine Belegstelle, an der sich das verifizieren liesse. Per
                 Regel ("fehlt einer der Werte - kein listTranspose bauen")
                 ist das aktuelle Verhalten (einfaches <seg type="transposition">,
                 corresp als gewoehnliches Attribut falls vorhanden) fuer alle
                 vorhandenen Daten ohnehin korrekt. -->
            <xsl:variable name="corresp"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'corresp'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$corresp != ''"><my:attr name="corresp" value="{$corresp}"/></xsl:if>
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
            <xsl:if test="$function != ''"><my:attr name="function" value="{$function}"/></xsl:if>
            <xsl:if test="$target != ''"><my:attr name="target" value="{$target}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='metamark-add'">
            <xsl:variable name="addId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'add-id'"/></xsl:call-template></xsl:variable>
            <my:attr name="add-id" value="{$addId}"/>
          </xsl:when>
          <xsl:when test="$name='subst-del'">
            <xsl:variable name="addId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'add-id'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="delId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'del-id'"/></xsl:call-template></xsl:variable>
            <my:attr name="add-id" value="{$addId}"/>
            <xsl:if test="$delId != ''"><my:attr name="del-id" value="{$delId}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='subst'">
            <xsl:variable name="addId"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'add-id'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$addId != ''"><my:attr name="add-id" value="{$addId}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='sic'">
            <xsl:variable name="correction"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'correction'"/></xsl:call-template></xsl:variable>
            <my:attr name="correction" value="{$correction}"/>
          </xsl:when>
          <xsl:when test="$name='undo'">
            <xsl:variable name="rend"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'rend'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="target"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'target'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$rend != ''"><my:attr name="rend" value="{$rend}"/></xsl:if>
            <xsl:if test="$target != ''"><my:attr name="target" value="{$target}"/></xsl:if>
          </xsl:when>
          <xsl:when test="$name='unclear'">
            <xsl:variable name="reason"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'reason'"/></xsl:call-template></xsl:variable>
            <xsl:variable name="cert"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'cert'"/></xsl:call-template></xsl:variable>
            <xsl:if test="$reason != ''"><my:attr name="reason" value="{$reason}"/></xsl:if>
            <xsl:if test="$cert != ''"><my:attr name="cert" value="{$cert}"/></xsl:if>
          </xsl:when>
        </xsl:choose>
        <!-- "id" (Behelfs-ID-Deklaration, Abschnitt 8) auch auf den uebrigen
             Bloecken, die ueber die generische Weiche als Element ausgegeben
             werden (add hat seinen eigenen Zweig oben); wird in
             render-one-range zur echten xml:id. -->
        <xsl:if test="contains(' spacing hi-spacing bold hi-bold underline hi-underline mod-underline mod del deselection seg seg-transposition unclear metamark ', concat(' ',$name,' '))">
          <xsl:variable name="declaredIdOther"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'id'"/></xsl:call-template></xsl:variable>
          <xsl:if test="$declaredIdOther != ''"><my:attr name="id" value="{$declaredIdOther}"/></xsl:if>
        </xsl:if>
        <!-- "prev"/"next": Verweise auf Behelfs-IDs, werden zu den gleichnamigen
             TEI-Attributen (aufgeloest in resolved-ref-attrs) -->
        <xsl:if test="contains(' spacing hi-spacing bold hi-bold underline hi-underline mod-underline mod del deselection seg seg-transposition unclear metamark add ', concat(' ',$name,' '))">
          <xsl:variable name="prevV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'prev'"/></xsl:call-template></xsl:variable>
          <xsl:variable name="nextV"><xsl:call-template name="token-value"><xsl:with-param name="tokens" select="$content"/><xsl:with-param name="key" select="'next'"/></xsl:call-template></xsl:variable>
          <xsl:if test="$prevV != ''"><my:attr name="prev" value="{$prevV}"/></xsl:if>
          <xsl:if test="$nextV != ''"><my:attr name="next" value="{$nextV}"/></xsl:if>
        </xsl:if>
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
                 (gap/gap-cut/gap-ill) exakt mit dem Bereich eines del
                 zusammen, ist del IMMER das aeussere - unabhaengig von der
                 Deklarationsreihenfolge. -->
            <xsl:when test="@element='del' and $me/@element='gap'">true</xsl:when>
            <xsl:when test="$me/@element='del' and @element='gap'">false</xsl:when>
            <xsl:otherwise><xsl:value-of select="number(@idx) &lt; number($me/@idx)"/></xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:if test="$qualifies='true'">
          <xsl:variable name="priority">
            <xsl:choose>
              <xsl:when test="@element='add' and $candSize = $mySize and $me/@element != 'add' and $me/@element != 'del'">0</xsl:when>
              <xsl:when test="@element='del' and $candSize = $mySize and $me/@element='gap'">0</xsl:when>
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
        <xsl:sort select="number(@val)" data-type="number" order="ascending"/>
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
    <xsl:param name="lineId"/>
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
        <xsl:choose>
          <xsl:when test="$suppressGap"><xsl:value-of select="substring($text, $cursor + 1, $spanEnd - $cursor)"/></xsl:when>
          <xsl:otherwise><xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($text, $cursor + 1, $spanEnd - $cursor)"/></xsl:call-template></xsl:otherwise>
        </xsl:choose>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="childIdx" select="$ordered[$pos]/@idx"/>
        <xsl:variable name="range" select="$ranges[@idx=$childIdx]"/>
        <xsl:variable name="cStart" select="number($range/@offset)"/>
        <xsl:variable name="cEnd" select="number($range/@end)"/>
        <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($text, $cursor + 1, $cStart - $cursor)"/></xsl:call-template>
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
    <xsl:variable name="hasChildren" select="boolean($rangeParents[@parent=$range/@idx])"/>
    <xsl:choose>
      <!-- subst-del + add-id (Abschnitt 7): der ganze Bereich ist geloescht,
           der Ersatz kommt NICHT aus lokalem Zeichenversatz, sondern wird aus
           einer per Behelfs-ID referenzierten add-Region importiert - direkt
           <subst><del>eigener Text</del><add>importiert</add></subst>, kein
           gewoehnliches Wrapper-Element. -->
      <xsl:when test="$range/@element='subst-del-synth'">
        <subst>
          <del>
            <xsl:variable name="delIdBehelfs" select="$range/my:attr[@name='del-id']/@value"/>
            <xsl:if test="$delIdBehelfs != ''">
              <xsl:variable name="delIdHit" select="$behelfsMap[@behelfs=$delIdBehelfs]"/>
              <xsl:if test="$delIdHit">
                <xsl:attribute name="xml:id"><xsl:value-of select="$delIdHit[1]/@genid"/></xsl:attribute>
              </xsl:if>
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
        <metamark function="addition"/>
        <xsl:variable name="addIdsRTF">
          <xsl:call-template name="all-behelfs-tokens"><xsl:with-param name="s" select="$range/my:attr[@name='add-id']/@value"/></xsl:call-template>
        </xsl:variable>
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
              <xsl:call-template name="foreign-target-attr"><xsl:with-param name="target" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
            </metamark>
            <xsl:call-template name="render-imported-add">
              <xsl:with-param name="addRegionId" select="$chainTargetRegionId"/>
              <xsl:with-param name="lineId" select="$lineId"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <metamark function="insertion">
              <xsl:call-template name="foreign-target-attr"><xsl:with-param name="target" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
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
        <choice>
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
          <corr><xsl:value-of select="$range/my:attr[@name='correction']/@value"/></corr>
        </choice>
      </xsl:when>

      <!-- undo (Abschnitt 7): kein umschliessendes Element - stattdessen ein
           leeres Meilenstein-Paar <undo spanTo="#X"/> ... <anchor xml:id="X"/>
           VOR und NACH dem unveraendert weitergerenderten Inhalt. Wird
           bewusst NIE zeilenuebergreifend zusammengefasst (siehe process-line
           weiter oben) - das ist hier also immer der volle, einzeilige Bereich. -->
      <xsl:when test="$range/@element='undo'">
        <xsl:variable name="seq" select="$undoOrder[@line=$lineId and @offset=$range/@offset]/@seq"/>
        <xsl:variable name="seqPadded"><xsl:call-template name="pad4"><xsl:with-param name="s" select="$seq"/></xsl:call-template></xsl:variable>
        <xsl:variable name="anchorId" select="concat('anchor-', $pageNumPadded, '-', $seqPadded)"/>
        <undo spanTo="{concat('#',$anchorId)}">
          <xsl:if test="$range/my:attr[@name='rend']">
            <xsl:attribute name="rend"><xsl:value-of select="$range/my:attr[@name='rend']/@value"/></xsl:attribute>
          </xsl:if>
          <xsl:if test="$range/my:attr[@name='target']">
            <xsl:attribute name="target">
              <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
            </xsl:attribute>
          </xsl:if>
        </undo>
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
        <anchor type="undo"><xsl:attribute name="xml:id"><xsl:value-of select="$anchorId"/></xsl:attribute></anchor>
      </xsl:when>

      <!-- deselection mit @part (Korrektur, siehe Chat): KEIN umschliessendes
           <del> mehr - stattdessen ein leeres <delSpan target="#X"/> GENAU an
           der Stelle des ERSTEN "I"/"i"-Vorkommens (siehe $deselMarkers) bzw.
           ein leeres <anchor xml:id="X"/> GENAU an der Stelle des LETZTEN
           "F"/"f"-Vorkommens; alle dazwischenliegenden Wiederholungen (reine
           Ketten-Fortsetzungen aus dem Quell-@custom) bleiben ohne jede
           eigene Ausgabe - der Inhalt fliesst unveraendert durch. -->
      <xsl:when test="$range/@element='del' and $range/my:attr[@name='part']">
        <xsl:variable name="marker" select="$deselMarkers[@line=$lineId and @offset=$range/@offset]"/>
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
          <!-- id/prev/next der deselection (Abschnitt 8) landen auf dem
               <delSpan>, dem Startelement des Paars -->
          <delSpan>
            <xsl:if test="$range/my:attr[@name='id']">
              <xsl:variable name="declHit" select="$behelfsMap[@behelfs=$range/my:attr[@name='id']/@value]"/>
              <xsl:variable name="firstDecl" select="$allLineRanges[my:attr[@name='id']/@value=$range/my:attr[@name='id']/@value][1]"/>
              <xsl:if test="$declHit and $firstDecl/@line=$lineId and $firstDecl/@offset=$range/@offset"><xsl:attribute name="xml:id"><xsl:value-of select="$declHit[1]/@genid"/></xsl:attribute></xsl:if>
            </xsl:if>
            <xsl:attribute name="spanTo"><xsl:value-of select="concat('#',$pairId)"/></xsl:attribute>
            <xsl:call-template name="resolved-ref-attrs"><xsl:with-param name="attrs" select="$range/my:attr"/></xsl:call-template>
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
            <xsl:attribute name="xml:id"><xsl:value-of select="$pairId"/></xsl:attribute>
            <xsl:call-template name="resolved-ref-attrs"><xsl:with-param name="attrs" select="$range/my:attr"/></xsl:call-template>
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
        <xsl:element name="{$range/@element}">
          <!-- "id" (Behelfs-ID-Deklaration, z.B. auf einem add-Block) wird
               zu einer echten xml:id statt eines Ausgabeattributs "id";
               "target" wird - wo immer es vorkommt - als Behelfs-ID
               aufgeloest statt roh kopiert (Abschnitt 8). add-id/del-id
               sind reine Buchhaltung, nie ein Ausgabeattribut. -->
          <xsl:if test="$range/my:attr[@name='id']">
            <xsl:variable name="declHit" select="$behelfsMap[@behelfs=$range/my:attr[@name='id']/@value]"/>
            <!-- nur die ERSTE Deklaration einer ID bekommt die xml:id (ein
                 "continued:true"-Lauf traegt dieselbe id auf jedem Zeilen-
                 stueck, soll aber nur EINE xml:id ergeben) -->
            <xsl:variable name="firstDecl" select="$allLineRanges[my:attr[@name='id']/@value=$range/my:attr[@name='id']/@value][1]"/>
            <xsl:if test="$declHit and $firstDecl/@line=$lineId and $firstDecl/@offset=$range/@offset"><xsl:attribute name="xml:id"><xsl:value-of select="$declHit[1]/@genid"/></xsl:attribute></xsl:if>
          </xsl:if>
          <xsl:for-each select="$range/my:attr[@name != 'add-id' and @name != 'del-id' and @name != 'id' and @name != 'target' and @name != 'prev' and @name != 'next']">
            <xsl:attribute name="{@name}"><xsl:value-of select="@value"/></xsl:attribute>
          </xsl:for-each>
          <xsl:call-template name="resolved-ref-attrs"><xsl:with-param name="attrs" select="$range/my:attr"/></xsl:call-template>
          <xsl:if test="$range/my:attr[@name='target']">
            <xsl:attribute name="target">
              <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$range/my:attr[@name='target']/@value"/></xsl:call-template>
            </xsl:attribute>
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
      <!-- wie in render-one-range (generische Weiche): "id" -> echte xml:id
           ueber $behelfsMap, "target" -> aufgeloeste Behelfs-ID(s),
           add-id/del-id sind reine Buchhaltung -->
      <xsl:if test="$attrs[@name='id']">
        <xsl:variable name="declHit" select="$behelfsMap[@behelfs=$attrs[@name='id']/@value]"/>
        <xsl:variable name="firstDecl" select="$allLineRanges[my:attr[@name='id']/@value=$attrs[@name='id']/@value][1]"/>
        <xsl:if test="$declHit and $firstDecl/@line=$lines[$index]/@id and $firstDecl/@offset=$startOffset"><xsl:attribute name="xml:id"><xsl:value-of select="$declHit[1]/@genid"/></xsl:attribute></xsl:if>
      </xsl:if>
      <xsl:for-each select="$attrs[@name != 'add-id' and @name != 'del-id' and @name != 'id' and @name != 'target' and @name != 'prev' and @name != 'next']">
        <xsl:attribute name="{@name}"><xsl:value-of select="@value"/></xsl:attribute>
      </xsl:for-each>
      <xsl:call-template name="resolved-ref-attrs"><xsl:with-param name="attrs" select="$attrs"/></xsl:call-template>
      <xsl:if test="$attrs[@name='target']">
        <xsl:attribute name="target">
          <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="$attrs[@name='target']/@value"/></xsl:call-template>
        </xsl:attribute>
      </xsl:if>
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
    <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($lastText, number($lastLen) + 1)"/></xsl:call-template>
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
            <xsl:variable name="contParents" select="exsl:node-set($contParentsRTF)/my:rp"/>
            <xsl:variable name="contHasChildren" select="boolean($contParents[@parent=$cont/@idx])"/>
            <!-- Der Lauf darf auch dann nicht ueber diese Zeile hinaus
                 fortgesetzt werden, wenn die vermeintliche Fortsetzung dort
                 selbst NICHT oberste Ebene ist (also ihrerseits Kind eines
                 anderen Bereichs auf dieser Zeile ist, z.B. wenn ein
                 subst-del denselben Bereich umschliesst) - die einzeilige
                 roh-Textstueckelung (run-span-body) kann diesen umschliessenden
                 Bereich sonst gar nicht abbilden und wuerde dessen Struktur
                 stillschweigend verschlucken. -->
            <xsl:variable name="contIsTopLevel" select="boolean($contParents[@idx=$cont/@idx and @parent='0'])"/>
            <xsl:choose>
              <xsl:when test="$contHasChildren or not($contIsTopLevel)"><xsl:value-of select="$index"/></xsl:when>
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
      <lb facs="#zone_{$line/@id}"/>
    </xsl:if>
    <xsl:choose>
      <xsl:when test="$current = $index">
        <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($text, number($startOffset) + 1)"/></xsl:call-template>
      </xsl:when>
      <xsl:when test="$current = $endIndex">
        <xsl:variable name="rRTF"><xsl:call-template name="parse-line-ranges"><xsl:with-param name="line" select="$line"/></xsl:call-template></xsl:variable>
        <xsl:variable name="r" select="exsl:node-set($rRTF)/my:range[@offset='0']"/>
        <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="substring($text, 1, number($r/@end))"/></xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="text-with-gaps"><xsl:with-param name="txt" select="$text"/></xsl:call-template>
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
    <xsl:variable name="subtype">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'subtype'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="cat">
      <xsl:call-template name="custom-value">
        <xsl:with-param name="custom" select="@custom"/>
        <xsl:with-param name="block" select="'structure'"/>
        <xsl:with-param name="key" select="'cat'"/>
      </xsl:call-template>
    </xsl:variable>
    <!-- Ausgabe-@subtype der surface: der Wert aus structure{cat:..} (base/att);
         fehlt cat, wie bisher structure{subtype:..} -->
    <xsl:variable name="subtypeOut">
      <xsl:choose>
        <xsl:when test="$cat != ''"><xsl:value-of select="$cat"/></xsl:when>
        <xsl:otherwise><xsl:value-of select="$subtype"/></xsl:otherwise>
      </xsl:choose>
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
    <my:region id="{@id}" type="{$type}" cat="{$cat}" singlePArticle="{$singlePArticle}" reason="{$reasonV}" subtype="{$subtypeOut}" compositOrder="{$compositOrder}" index="{$index}" rendition="{$rendition}"
            function="{$function}" target="{$target}" behelfsId="{$behelfsId}"
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
       (also Laenge >= 2) wird zu <gap extent="N" reason=""/>; ein einzelnes
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
                <!-- reason="" (woertlich Abschnitt 7a) ist gegen tei_all.rng
                     ungueltig (@reason muss entweder ganz fehlen oder ein
                     echter Wert/Token sein) - wird deshalb weggelassen. -->
                <gap extent="{2 + $extra}"/>
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

  <!-- laeuft einmal in Dokumentreihenfolge ueber $items (alle del-Bereiche
       mit @part) und erkennt Gruppen aufeinanderfolgender gleicher @part-
       Werte ("I..." bzw. "F..."-Ketten): bei jedem Wechsel I->(etwas anderes)
       bzw. (etwas anderes)->I wird ein neues Paar begonnen, beim Wechsel
       WEG von einer F-Gruppe (oder am Ende der Liste, falls sie dort noch
       offen ist) wird das zuletzt begonnene Paar geschlossen. Liefert pro
       Paar genau zwei <my:marker role="start|end" pairSeq=".." line=".."
       offset=".."/>. -->
  <xsl:template name="pair-desel-groups">
    <xsl:param name="items"/>
    <xsl:param name="pos" select="1"/>
    <xsl:param name="prevPart" select="''"/>
    <xsl:param name="pairSeq" select="0"/>
    <xsl:choose>
      <xsl:when test="$pos &gt; count($items)">
        <xsl:if test="$prevPart='F'">
          <xsl:variable name="last" select="$items[count($items)]"/>
          <my:marker role="end" pairSeq="{$pairSeq}" line="{$last/@line}" offset="{$last/@offset}"/>
        </xsl:if>
      </xsl:when>
      <xsl:otherwise>
        <xsl:variable name="cur" select="$items[$pos]"/>
        <xsl:variable name="firstChar" select="substring($cur/@part,1,1)"/>
        <xsl:variable name="curPart">
          <xsl:choose>
            <xsl:when test="translate($firstChar,'i','I')='I'">I</xsl:when>
            <xsl:when test="translate($firstChar,'f','F')='F'">F</xsl:when>
            <xsl:otherwise>?</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:variable name="isNewGroup" select="$curPart != $prevPart"/>
        <xsl:variable name="newPairSeq">
          <xsl:choose>
            <xsl:when test="$isNewGroup and $curPart='I'"><xsl:value-of select="$pairSeq + 1"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="$pairSeq"/></xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:if test="$isNewGroup and $prevPart='F'">
          <xsl:variable name="prevItem" select="$items[$pos - 1]"/>
          <my:marker role="end" pairSeq="{$pairSeq}" line="{$prevItem/@line}" offset="{$prevItem/@offset}"/>
        </xsl:if>
        <xsl:if test="$isNewGroup and $curPart='I'">
          <my:marker role="start" pairSeq="{$newPairSeq}" line="{$cur/@line}" offset="{$cur/@offset}"/>
        </xsl:if>
        <xsl:call-template name="pair-desel-groups">
          <xsl:with-param name="items" select="$items"/>
          <xsl:with-param name="pos" select="$pos + 1"/>
          <xsl:with-param name="prevPart" select="$curPart"/>
          <xsl:with-param name="pairSeq" select="$newPairSeq"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
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

  <!-- das Ende-<anchor> eines delSpan-Paars mit xml:id und - falls der
       letzte Block des Paars sie traegt - prev/next -->
  <xsl:template name="desel-end-anchor">
    <xsl:param name="id"/>
    <xsl:variable name="pid" select="$deselPairIds[@id=$id][1]"/>
    <anchor>
      <xsl:attribute name="xml:id"><xsl:value-of select="$id"/></xsl:attribute>
      <xsl:call-template name="resolved-ref-attrs">
        <xsl:with-param name="attrs" select="$allLineRanges[@line=$pid/@line and @offset=$pid/@offset and @element='del' and my:attr[@name='part']][1]/my:attr"/>
      </xsl:call-template>
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
      <xsl:for-each select="$ranges[@element='del' and my:attr[@name='part']]">
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
    <xsl:for-each select="$attrs[@name='prev' or @name='next']">
      <xsl:attribute name="{@name}">
        <xsl:call-template name="resolve-behelfs"><xsl:with-param name="behelfsId" select="@value"/></xsl:call-template>
      </xsl:attribute>
    </xsl:for-each>
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
