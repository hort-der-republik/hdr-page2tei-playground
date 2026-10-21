#!/bin/bash
# transform.sh - PAGE-XML -> TEI und Validierungsreport
#
# Verarbeitet alle XML-Dateien aus ./page mit xsl/pagexml-to-tei.xsl und
# schreibt das Ergebnis unter demselben Dateinamen nach ./tei (vorhandene
# gleichnamige Dateien werden ersetzt). Danach wird jede erzeugte Datei mit
# jing gegen ZWEI Schemata geprueft - getrennt ausgewiesen:
#   1. das Projekt-Schema   meta/hdr-test-schema.rng
#   2. TEI-All              meta/tei_all.rng
# Der Report listet alle Verstoesse je Datei und Schema (Terminal + Datei
# meta/validation-report.txt).
#
# Aufruf:
#   ./transform.sh                     alle Dateien aus ./page
#   ./transform.sh 0003_406 0005_581   nur diese Dateien (mit oder ohne .xml)
#   ./transform.sh -n                  ohne Validierung
#   ./transform.sh -s anderes.rng      anderes Projekt-Schema verwenden
#   ./transform.sh -t anderes_all.rng  anderes TEI-All-Schema verwenden
#   ./transform.sh -r report.txt       Report an anderer Stelle speichern
#   ./transform.sh -h                  Hilfe
#
# Voraussetzungen: saxon (bevorzugt) oder xsltproc (PROCESSOR=xsltproc setzen,
# um xsltproc zu erzwingen), sowie jing fuer die Validierung (z.B.
# "brew install saxon jing"). Exit-Code 1, wenn eine Transformation
# fehlgeschlagen ist; Schema-Verstoesse allein aendern den Exit-Code nicht.

# (kein "set -u": leere Arrays sind in aelterem bash/macOS sonst ein Fehler)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAGE_DIR="$SCRIPT_DIR/page"
TEI_DIR="$SCRIPT_DIR/tei"
XSL="$SCRIPT_DIR/xsl/pagexml-to-tei.xsl"
RNG_PROJECT="$SCRIPT_DIR/meta/hdr-test-schema.rng"
RNG_TEIALL="$SCRIPT_DIR/meta/tei_all.rng"
REPORT="$SCRIPT_DIR/meta/validation-report.txt"
VALIDATE=1
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
    n) VALIDATE=0 ;;
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
    echo "ok"
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

if [ "$VALIDATE" = "1" ] && [ "${#OKFILES[@]}" -gt 0 ]; then
  {
    echo "VALIDIERUNGSREPORT"
    echo "Erstellt: $(date '+%Y-%m-%d %H:%M:%S')"
    i=0
    while [ "$i" -lt "${#SCHEMA_PATHS[@]}" ]; do
      echo "Schema $((i + 1)): ${SCHEMA_NAMES[$i]}"
      i=$((i + 1))
    done
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
  done

  # Zusammenfassung: je Schema haeufigste Meldungen + Tabelle Datei x Schema
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

    echo "ZUSAMMENFASSUNG (Verstoesse je Datei)"
    # Kopfzeile
    printf '  %-18s' "Datei"
    i=0
    while [ "$i" -lt "${#SCHEMA_PATHS[@]}" ]; do
      case "${SCHEMA_TAGS[$i]}" in proj) lbl="Projekt";; teiall) lbl="TEI-All";; *) lbl="${SCHEMA_TAGS[$i]}";; esac
      printf ' %10s' "$lbl"
      i=$((i + 1))
    done
    printf '\n'
    for name in "${OKFILES[@]}"; do
      printf '  %-18s' "$name"
      i=0
      while [ "$i" -lt "${#SCHEMA_PATHS[@]}" ]; do
        tag="${SCHEMA_TAGS[$i]}"
        n="$(wc -l <"$TMP/$name.$tag.msgs" | tr -d ' ')"
        printf ' %10s' "$n"
        echo "$n" >>"$TMP/sum.$tag.txt"
        i=$((i + 1))
      done
      printf '\n'
    done
    echo "  ----------------------------------------------"
    printf '  %-18s' "Summe"
    i=0
    while [ "$i" -lt "${#SCHEMA_PATHS[@]}" ]; do
      tag="${SCHEMA_TAGS[$i]}"
      printf ' %10s' "$(awk '{ s += $1 } END { print s + 0 }' "$TMP/sum.$tag.txt")"
      i=$((i + 1))
    done
    printf '\n'
  } >>"$TMP/report.txt"

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
