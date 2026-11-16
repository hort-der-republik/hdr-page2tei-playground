#!/bin/bash
# odd2rng.sh - erzeugt aus meta/hdr-documentary-schema.odd das RelaxNG-Schema
# (benutzt die TEI-Stylesheets und p5subset.xml aus Oxygen; saxon erforderlich).
#   ./meta/odd2rng.sh                 schreibt meta/hdr-documentary-schema.rng
#   ./meta/odd2rng.sh out.rng         schreibt in die angegebene Datei
#   OXY="/Applications/Oxygen XML Editor" ./meta/odd2rng.sh   anderer Oxygen-Pfad
DIR="$(cd "$(dirname "$0")" && pwd)"
OXY="${OXY:-/Applications/Oxygen XML Editor}"
OUT="${1:-$DIR/hdr-documentary-schema.rng}"
S="$OXY/frameworks/tei/xml/tei/stylesheet/odds"
P5="$OXY/frameworks/tei/xml/tei/odd/p5subset.xml"
W="$(mktemp -d "${TMPDIR:-/tmp}/odd2rng.XXXXXX")"; trap 'rm -rf "$W"' EXIT
[ -f "$P5" ] && [ -d "$S" ] || { echo "TEI-Stylesheets/p5subset nicht gefunden unter $OXY" >&2; exit 2; }
sed "s#source=\"tei:current\"#source=\"file://${P5// /%20}\"#" "$DIR/hdr-documentary-schema.odd" > "$W/in.odd"
saxon -s:"$W/in.odd" -xsl:"$S/odd2odd.xsl" -o:"$W/compiled.odd" || exit 1
saxon -s:"$W/compiled.odd" -xsl:"$S/odd2relax.xsl" -o:"$OUT" || exit 1
echo "geschrieben: $OUT"
