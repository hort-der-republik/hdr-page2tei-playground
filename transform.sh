#!/bin/bash
# transform.sh - PAGE-XML -> TEI und Validierungsreport
#
# Verarbeitet alle XML-Dateien aus ./page mit xsl/pagexml-to-tei.xsl und
# schreibt das Ergebnis unter demselben Dateinamen nach ./tei (vorhandene
# gleichnamige Dateien werden ersetzt). Danach wird jede erzeugte Datei mit
# jing gegen ZWEI Schemata geprueft - getrennt ausgewiesen:
#   1. das Projekt-Schema   meta/hdr-documentary-schema.rng
#   2. TEI-All              meta/tei_all.rng
# Zusaetzlich prueft der Report, welche Verweise (target, corresp, next, prev,
# spanTo sowie "unresolved add-id"-Kommentare) ins Leere zeigen, d.h. auf eine
# Behelfs-ID, die nirgends als xml:id vorkommt. Der Report listet alles je Datei
# (Terminal + Datei meta/validation-report.txt).
#
# Aufruf:
#   ./transform.sh                     alle Dateien aus ./page
#   ./transform.sh 0003_406 0005_581   nur diese Dateien (mit oder ohne .xml)
#   ./transform.sh -n                  ohne Validierung/Report
#   ./transform.sh -s anderes.rng      anderes Projekt-Schema verwenden
#   ./transform.sh -t anderes_all.rng  anderes TEI-All-Schema verwenden
#   ./transform.sh -r report.txt       Report an anderer Stelle speichern
#   ./transform.sh -h                  Hilfe
#
# Voraussetzungen: saxon (bevorzugt) oder xsltproc (PROCESSOR=xsltproc setzen,
# um xsltproc zu erzwingen), jing fuer die Schema-Validierung (z.B.
# "brew install saxon jing") und xmllint fuer die Verweis-Pruefung. Exit-Code 1, wenn eine Transformation
# fehlgeschlagen ist; Schema-Verstoesse allein aendern den Exit-Code nicht.

# (kein "set -u": leere Arrays sind in aelterem bash/macOS sonst ein Fehler)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAGE_DIR="$SCRIPT_DIR/page"
TEI_DIR="$SCRIPT_DIR/tei"
XSL="$SCRIPT_DIR/xsl/pagexml-to-tei.xsl"
RNG_PROJECT="$SCRIPT_DIR/meta/hdr-documentary-schema.rng"
RNG_TEIALL="$SCRIPT_DIR/meta/tei_all.rng"
REPORT="$SCRIPT_DIR/meta/validation-report.txt"
VALIDATE=1
REPORT_ON=1
MAXLEN=200   # jing-Meldungen (v.a. TEI-All: lange "expected ..."-Listen) im Report kuerzen

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while getopts "s:t:r:nh" opt; do
  case "$opt" in
    s) RNG_PROJECT="$OPTARG" ;;
    t) RNG_TEIALL="$OPTARG" ;;
    r) REPORT="$OPTARG" ;;
    n) VALIDATE=0; REPORT_ON=0 ;;
    h) usage ;;
    *) echo "Unbekannte Option. Hilfe: $0 -h" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# --- Voraussetzungen pruefen ---------------------------------------------
if [ ! -f "$XSL" ]; then echo "Stylesheet nicht gefunden: $XSL" >&2; exit 2; fi
if [ ! -d "$PAGE_DIR" ]; then echo "Ordner nicht gefunden: $PAGE_DIR" >&2; exit 2; fi

# Prozessor: saxon bevorzugt; mit PROCESSOR=xsltproc ./transform.sh erzwingbar
WANT="${PROCESSOR:-}"
if [ -z "$WANT" ] && command -v saxon >/dev/null 2>&1; then WANT="saxon"; fi
if [ "$WANT" = "saxon" ] && command -v saxon >/dev/null 2>&1; then
  PROC="saxon"
elif command -v xsltproc >/dev/null 2>&1; then
  PROC="xsltproc"
  # tiefe Rekursion im Stylesheet: C-Stack so gross wie erlaubt
  hard="$(ulimit -Hs 2>/dev/null || echo 0)"
  if [ "$hard" != "0" ] && [ "$hard" != "unlimited" ]; then ulimit -s "$hard" 2>/dev/null || true
  else ulimit -s unlimited 2>/dev/null || true; fi
else
  echo "Weder saxon noch xsltproc gefunden." >&2; exit 2
fi

# Schemata: parallele Listen (Pfad, Kuerzel fuer Dateinamen, Anzeigename)
SCHEMA_PATHS=(); SCHEMA_TAGS=(); SCHEMA_NAMES=()
if [ "$VALIDATE" = "1" ]; then
  if ! command -v jing >/dev/null 2>&1; then
    echo "Hinweis: jing nicht gefunden - es wird NICHT validiert (brew install jing)." >&2
    VALIDATE=0
  else
    if [ -f "$RNG_PROJECT" ]; then
      SCHEMA_PATHS+=("$RNG_PROJECT"); SCHEMA_TAGS+=("proj"); SCHEMA_NAMES+=("Projekt-Schema ($(basename "$RNG_PROJECT"))")
    else
      echo "Hinweis: Projekt-Schema nicht gefunden: $RNG_PROJECT - wird uebersprungen." >&2
    fi
    if [ -f "$RNG_TEIALL" ]; then
      SCHEMA_PATHS+=("$RNG_TEIALL"); SCHEMA_TAGS+=("teiall"); SCHEMA_NAMES+=("TEI-All ($(basename "$RNG_TEIALL"))")
    else
      echo "Hinweis: TEI-All-Schema nicht gefunden: $RNG_TEIALL - wird uebersprungen (Option -t)." >&2
    fi
    if [ "${#SCHEMA_PATHS[@]}" -eq 0 ]; then VALIDATE=0; fi
  fi
fi

mkdir -p "$TEI_DIR"
mkdir -p "$(dirname "$REPORT")"

# --- zu verarbeitende Dateien --------------------------------------------
FILES=()
if [ "$#" -gt 0 ]; then
  for a in "$@"; do
    b="$(basename "$a")"; b="${b%.xml}.xml"
    if [ -f "$PAGE_DIR/$b" ]; then FILES+=("$PAGE_DIR/$b"); else echo "Uebersprungen (nicht in page/): $a" >&2; fi
  done
else
  for f in "$PAGE_DIR"/*.xml; do [ -e "$f" ] && FILES+=("$f"); done
fi
if [ "${#FILES[@]}" -eq 0 ]; then echo "Keine XML-Dateien zu verarbeiten." >&2; exit 2; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/transform.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "Prozessor: $PROC   Stylesheet: ${XSL#$SCRIPT_DIR/}"
echo

# --- Transformation ------------------------------------------------------
OKFILES=()
FAILED=0
for src in "${FILES[@]}"; do
  name="$(basename "$src")"
  out="$TEI_DIR/$name"
  printf 'Transformiere %-18s ' "$name"
  if [ "$PROC" = "saxon" ]; then
    saxon -s:"$src" -xsl:"$XSL" -o:"$TMP/$name" >"$TMP/$name.log" 2>&1
  else
    xsltproc --stringparam indentUnit "  " "$XSL" "$src" >"$TMP/$name" 2>"$TMP/$name.log"
  fi
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$TMP/$name" ]; then
    mv "$TMP/$name" "$out"      # erst jetzt wird eine vorhandene Datei ersetzt
    nwarn="$(grep -c 'WARNUNG' "$TMP/$name.log" 2>/dev/null)"
    if [ "${nwarn:-0}" -gt 0 ]; then
      echo "ok  ($nwarn Warnung(en))"
      grep 'WARNUNG' "$TMP/$name.log" | cut -c1-200 | sed 's/^/    /'
    else
      echo "ok"
    fi
    OKFILES+=("$name")
  else
    echo "FEHLER"
    sed 's/^/    /' "$TMP/$name.log" | head -8
    FAILED=$((FAILED + 1))
  fi
done

# --- Validierung + Report ------------------------------------------------
# validate_one <Schema-Pfad> <Kuerzel> <Dateiname>
#   schreibt $TMP/<Datei>.<Kuerzel>.msgs  (Zeile:Spalte <TAB> Art <TAB> Meldung)
#   und $TMP/<Datei>.<Kuerzel>.other (jing-Ausgabe ohne Standardmeldungen)
validate_one() {
  local schema="$1" tag="$2" name="$3"
  jing "$schema" "$TEI_DIR/$name" >"$TMP/$name.$tag.jing" 2>&1
  # jing-Zeilen: <datei>:<zeile>:<spalte>: error|warning: <meldung>
  grep -E ':[0-9]+:[0-9]+: (error|warning|fatal)' "$TMP/$name.$tag.jing" \
    | sed -E "s|^.*/([^/]+):([0-9]+):([0-9]+): (error\|warning\|fatal): |\2:\3\t\4\t|" \
    >"$TMP/$name.$tag.msgs"
  grep -vE ':[0-9]+:[0-9]+: (error|warning|fatal)' "$TMP/$name.$tag.jing" >"$TMP/$name.$tag.other"
}

# check_refs <Dateiname>
#   Verweise, die ins Leere zeigen (Behelfs-IDs ohne Gegenstueck):
#   - #id in target/corresp/next/prev/spanTo, die in DIESER Datei nirgends als
#     xml:id steht
#   - "datei.xml#id": die Datei oder die ID dort fehlt
#   - "unresolved add-id: X"-Kommentare des Stylesheets
#   schreibt $TMP/<Datei>.refs  (Zeile <TAB> Beschreibung)
#   (g/@ref auf die noch nachzureichende charDecl wird bewusst nicht geprueft)
check_refs() {
  local name="$1" f="$TEI_DIR/$1"
  : >"$TMP/$name.refs"
  command -v xmllint >/dev/null 2>&1 || return 0
  # alle vorhandenen xml:id
  xmllint --xpath '//@xml:id' "$f" 2>/dev/null \
    | grep -oE 'xml:id="[^"]*"' | sed -E 's/^xml:id="//; s/"$//' | sort -u >"$TMP/$name.ids"
  # alle Verweise: Attribut<TAB>Wert
  xmllint --xpath '//@target|//@corresp|//@next|//@prev|//@spanTo' "$f" 2>/dev/null \
    | grep -oE '(target|corresp|next|prev|spanTo)="[^"]*"' \
    | sed -E 's/^([a-zA-Z]+)="(.*)"$/\1\t\2/' | sort -u >"$TMP/$name.refvals"
  # lokale Verweise
  awk -F'\t' -v idsfile="$TMP/$name.ids" '
    BEGIN { while ((getline l < idsfile) > 0) ids[l] = 1 }
    { n = split($2, tok, " ")
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t ~ /\.xml#/) { print "X\t" $1 "\t" t }
        else if (substr(t, 1, 1) == "#") { id = substr(t, 2); if (!(id in ids)) print "L\t" $1 "\t" t }
      } }' "$TMP/$name.refvals" >"$TMP/$name.refcand"
  # Zeilennummern + Text
  while IFS=$'\t' read -r kind attr tok; do
    if [ "$kind" = "X" ]; then
      file="${tok%%#*}"; id="${tok#*#}"
      if [ ! -f "$TEI_DIR/$file" ]; then why="Datei $file nicht in tei/ vorhanden"
      elif ! xmllint --xpath "count(//*[@xml:id='$id'])" "$TEI_DIR/$file" 2>/dev/null | grep -qv '^0$'; then why="ID $id existiert in $file nicht"
      else continue; fi
    else
      why="ID ${tok#\#} nirgends als xml:id vorhanden"
    fi
    esc="$(printf '%s' "$tok" | sed 's/[][\.*^$/]/\\&/g')"
    grep -nE "$attr=\"([^\"]* )?$esc( [^\"]*)?\"" "$f" | cut -d: -f1 | while read -r ln; do
      printf '%s\t%s=\"%s\"  ->  %s\n' "$ln" "$attr" "$tok" "$why"
    done >>"$TMP/$name.refs"
  done <"$TMP/$name.refcand"
  # vom Stylesheet markierte, nicht aufloesbare add-id
  grep -n 'unresolved add-id:' "$f" \
    | awk '{ ln = $0; sub(/:.*/, "", ln); id = $0; sub(/.*unresolved add-id: /, "", id); sub(/ .*/, "", id);
            printf "%s\tadd-id \"%s\"  ->  keine Region / kein Zeilen-add mit dieser Behelfs-ID\n", ln, id }' \
    >>"$TMP/$name.refs"
  sort -u "$TMP/$name.refs" | sort -n -k1,1 >"$TMP/$name.refs.sorted" && mv "$TMP/$name.refs.sorted" "$TMP/$name.refs"
}

# Historie: Werte des letzten Durchgangs je Datei und Spalte (Tab-getrennt:
# Datei, Spalte, Wert). Wird nur fuer die in diesem Lauf verarbeiteten Dateien
# fortgeschrieben - ein Lauf mit einer einzelnen Datei verliert die Vergleichs-
# werte der anderen nicht.
HISTORY="$(dirname "$REPORT")/.validation-history.tsv"
prev_val() {   # <Datei> <Spalte> -> frueherer Wert oder leer
  [ -f "$HISTORY" ] || return 0
  awk -F'\t' -v n="$1" -v l="$2" '$1 == n && $2 == l { v = $3 } END { if (v != "") print v }' "$HISTORY"
}
fmt_delta() {  # <aktuell> <frueher oder leer> -> "aktuell (Differenz)"
  local cur="$1" old="$2" d
  if [ -z "$old" ]; then printf '%s (neu)' "$cur"; return; fi
  d=$((cur - old))
  if [ "$d" -gt 0 ]; then printf '%s (+%s)' "$cur" "$d"
  elif [ "$d" -lt 0 ]; then printf '%s (%s)' "$cur" "$d"
  else printf '%s (±0)' "$cur"; fi
}

if [ "$REPORT_ON" = "1" ] && [ "${#OKFILES[@]}" -gt 0 ]; then
  {
    echo "VALIDIERUNGSREPORT"
    echo "Erstellt: $(date '+%Y-%m-%d %H:%M:%S')"
    i=0
    while [ "$i" -lt "${#SCHEMA_PATHS[@]}" ]; do
      echo "Schema $((i + 1)): ${SCHEMA_NAMES[$i]}"
      i=$((i + 1))
    done
    echo "Verweis-Pruefung: ins Leere zeigende Behelfs-IDs"
    echo "=============================================================="
  } >"$TMP/report.txt"

  for name in "${OKFILES[@]}"; do
    {
      echo
      echo "### $name"
    } >>"$TMP/report.txt"
    i=0
    while [ "$i" -lt "${#SCHEMA_PATHS[@]}" ]; do
      tag="${SCHEMA_TAGS[$i]}"
      validate_one "${SCHEMA_PATHS[$i]}" "$tag" "$name"
      n="$(wc -l <"$TMP/$name.$tag.msgs" | tr -d ' ')"
      other="$(wc -l <"$TMP/$name.$tag.other" | tr -d ' ')"
      {
        echo "  --- gegen ${SCHEMA_NAMES[$i]}: $n Verstoesse"
        if [ "$n" -gt 0 ]; then
          awk -F'\t' '{ m = $3; if (length(m) > MAXLEN) m = substr(m, 1, MAXLEN) " [...]"; printf "      Zeile %-10s %s\n", $1, m }' MAXLEN="$MAXLEN" "$TMP/$name.$tag.msgs"
        fi
        if [ "$other" -gt 0 ]; then
          echo "      (weitere jing-Ausgabe:)"
          sed 's/^/      /' "$TMP/$name.$tag.other"
        fi
      } >>"$TMP/report.txt"
      cut -f3 "$TMP/$name.$tag.msgs" | cut -c1-"$MAXLEN" >>"$TMP/allmsgs.$tag.txt"
      i=$((i + 1))
    done
    # Warnungen der Transformation (z.B. doppelt vergebene Behelfs-IDs)
    nw="$(grep -c 'WARNUNG' "$TMP/$name.log" 2>/dev/null)"
    {
      echo "  --- Warnungen der Transformation (z.B. doppelt vergebene Behelfs-IDs): ${nw:-0}"
      if [ "${nw:-0}" -gt 0 ]; then
        grep 'WARNUNG' "$TMP/$name.log" | cut -c1-"$MAXLEN" | sed 's/^/      /'
      fi
    } >>"$TMP/report.txt"
    check_refs "$name"
    nr="$(wc -l <"$TMP/$name.refs" | tr -d ' ')"
    {
      echo "  --- ins Leere zeigende Verweise / Behelfs-IDs: $nr"
      if [ "$nr" -gt 0 ]; then
        awk -F'\t' '{ printf "      Zeile %-10s %s\n", $1, $2 }' "$TMP/$name.refs"
      fi
    } >>"$TMP/report.txt"
  done

  # Zusammenfassung: je Schema haeufigste Meldungen + Tabelle Datei x Pruefung
  {
    echo
    echo "=============================================================="
    i=0
    while [ "$i" -lt "${#SCHEMA_PATHS[@]}" ]; do
      tag="${SCHEMA_TAGS[$i]}"
      echo "HAEUFIGSTE MELDUNGEN - ${SCHEMA_NAMES[$i]}"
      if [ -s "$TMP/allmsgs.$tag.txt" ]; then
        sort "$TMP/allmsgs.$tag.txt" | uniq -c | sort -rn | head -15 | sed -E 's/^ *([0-9]+) /  \1x  /'
      else
        echo "  keine"
      fi
      echo
      i=$((i + 1))
    done

    echo "ZUSAMMENFASSUNG (Verstoesse je Datei; in Klammern: Differenz zum letzten Durchgang)"
    # Spalten: die Schemata + die Verweis-Pruefung (Kuerzel / Anzeigename)
    COL_TAGS=("${SCHEMA_TAGS[@]}" "refs"); COL_LBL=()
    for t in "${SCHEMA_TAGS[@]}"; do
      case "$t" in proj) COL_LBL+=("Projekt");; teiall) COL_LBL+=("TEI-All");; *) COL_LBL+=("$t");; esac
    done
    COL_LBL+=("Verweise")
    printf '  %-18s' "Datei"
    for l in "${COL_LBL[@]}"; do printf ' %14s' "$l"; done
    printf '\n'
    : >"$TMP/history.new"
    for name in "${OKFILES[@]}"; do
      printf '  %-18s' "$name"
      c=0
      while [ "$c" -lt "${#COL_TAGS[@]}" ]; do
        tag="${COL_TAGS[$c]}"
        if [ "$tag" = "refs" ]; then f="$TMP/$name.refs"; else f="$TMP/$name.$tag.msgs"; fi
        n="$(wc -l <"$f" | tr -d ' ')"
        old="$(prev_val "$name" "$tag")"
        printf ' %14s' "$(fmt_delta "$n" "$old")"
        echo "$n" >>"$TMP/sumcur.$tag"
        echo "${old:-0}" >>"$TMP/sumold.$tag"
        [ -n "$old" ] && : >"$TMP/hasold.$tag"
        printf '%s\t%s\t%s\n' "$name" "$tag" "$n" >>"$TMP/history.new"
        c=$((c + 1))
      done
      printf '\n'
    done
    echo "  ------------------------------------------------------------"
    printf '  %-18s' "Summe"
    c=0
    while [ "$c" -lt "${#COL_TAGS[@]}" ]; do
      tag="${COL_TAGS[$c]}"
      cur="$(awk '{ s += $1 } END { print s + 0 }' "$TMP/sumcur.$tag")"
      if [ -e "$TMP/hasold.$tag" ]; then old="$(awk '{ s += $1 } END { print s + 0 }' "$TMP/sumold.$tag")"; else old=""; fi
      printf ' %14s' "$(fmt_delta "$cur" "$old")"
      c=$((c + 1))
    done
    printf '\n'
  } >>"$TMP/report.txt"

  # Historie fortschreiben: alte Werte der hier verarbeiteten Dateien ersetzen
  {
    if [ -f "$HISTORY" ]; then
      for name in "${OKFILES[@]}"; do printf '%s\n' "$name"; done >"$TMP/okdatei.txt"
      awk -F'\t' 'NR == FNR { ok[$1] = 1; next } !($1 in ok)' "$TMP/okdatei.txt" "$HISTORY"
    fi
    cat "$TMP/history.new"
  } >"$TMP/history.merged"
  mv "$TMP/history.merged" "$HISTORY"
  cp "$TMP/report.txt" "$REPORT"
  echo
  cat "$TMP/report.txt"
  echo
  echo "Report gespeichert: ${REPORT#$SCRIPT_DIR/}"
fi

echo
echo "Fertig: ${#OKFILES[@]} von ${#FILES[@]} Datei(en) nach tei/ geschrieben."
[ "$FAILED" -eq 0 ] || exit 1
exit 0
