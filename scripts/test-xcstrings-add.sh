#!/usr/bin/env bash
# scripts/test-xcstrings-add.sh — the writer is additive and format-stable.
set -euo pipefail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# The writer's behaviour is tested against a fixed de/en list, not the live
# scripts/l10n/languages.json, so a language turning `required` (nl in 1.5)
# does not change what this test means. The pending case below has its own list.
echo '{"sourceLanguage": "en", "languages": {"de": "required", "en": "required"}}' > "$tmp/de-en.json"
cat > "$tmp/cat.xcstrings" <<'EOF'
{
  "sourceLanguage": "en",
  "strings": {
    "a.existing": {
      "extractionState": "manual",
      "localizations": {
        "de": { "stringUnit": { "state": "translated", "value": "Alt" } },
        "en": { "stringUnit": { "state": "translated", "value": "Old" } }
      }
    }
  },
  "version": "1.0"
}
EOF
cat > "$tmp/add.json" <<'EOF'
{ "a.existing": {"en": "MUST NOT OVERWRITE", "de": "DARF NICHT", "comment": "x"},
  "b.new": {"en": "New", "de": "Neu", "comment": "added"} }
EOF
python3 scripts/xcstrings-add.py "$tmp/add.json" --catalog "$tmp/cat.xcstrings" --languages "$tmp/de-en.json"
python3 - "$tmp/cat.xcstrings" <<'EOF'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["strings"]["a.existing"]["localizations"]["en"]["stringUnit"]["value"]=="Old", "overwrote"
assert d["strings"]["b.new"]["localizations"]["de"]["stringUnit"]["value"]=="Neu"
assert d["strings"]["b.new"]["extractionState"]=="manual"
assert d["strings"]["b.new"]["comment"]=="added"
print("ok")
EOF
grep -q '"b.new": {' "$tmp/cat.xcstrings" || { echo "format drift: expected Xcode ': ' separator"; exit 1; }
# idempotent: second run changes nothing
cp "$tmp/cat.xcstrings" "$tmp/before"; python3 scripts/xcstrings-add.py "$tmp/add.json" --catalog "$tmp/cat.xcstrings" --languages "$tmp/de-en.json"; cmp -s "$tmp/before" "$tmp/cat.xcstrings" || { echo "not idempotent"; exit 1; }

# languages.json: a missing `required` value aborts without writing.
echo '{ "c.only.en": {"en": "Only English"} }' > "$tmp/no-de.json"
if python3 scripts/xcstrings-add.py "$tmp/no-de.json" --catalog "$tmp/cat.xcstrings" --languages "$tmp/de-en.json" 2>/dev/null; then
  echo "accepted a key without the required de value"; exit 1
fi
cmp -s "$tmp/before" "$tmp/cat.xcstrings" || { echo "wrote despite a required gap"; exit 1; }

# A language the list does not know is a typo, not a new language.
echo '{ "c.typo": {"en": "x", "de": "x", "dee": "x"} }' > "$tmp/typo.json"
if python3 scripts/xcstrings-add.py "$tmp/typo.json" --catalog "$tmp/cat.xcstrings" --languages "$tmp/de-en.json" 2>/dev/null; then
  echo "accepted an unknown language"; exit 1
fi

# A `pending` language never blocks: a gap gets the English placeholder (en
# block, needs_review) so the screen shows English, never the raw key; a value
# given for it is written as is.
echo '{"sourceLanguage": "en", "languages": {"de": "required", "en": "required", "nl": "pending"}}' > "$tmp/langs.json"
echo '{ "d.pending": {"en": "Later", "de": "Später"}, "d.given": {"en": "Now", "de": "Jetzt", "nl": "Nu"} }' > "$tmp/pending.json"
out="$(python3 scripts/xcstrings-add.py "$tmp/pending.json" --catalog "$tmp/cat.xcstrings" --languages "$tmp/langs.json")"
[[ "$out" == *'1 English placeholder(s) for pending `nl`'* ]] || { echo "pending placeholder not reported: $out"; exit 1; }
python3 - "$tmp/cat.xcstrings" <<'EOF'
import json,sys
s=json.load(open(sys.argv[1]))["strings"]
assert s["d.pending"]["localizations"]["nl"]["stringUnit"]=={"state":"needs_review","value":"Later"}, s["d.pending"]
assert s["d.given"]["localizations"]["nl"]["stringUnit"]=={"state":"translated","value":"Nu"}, s["d.given"]
EOF
# A prefix in placeholder-exemptions.json keeps its gap (counted).
echo '{"prefixes": ["e."]}' > "$tmp/placeholder-exemptions.json"
echo '{ "e.exempt": {"en": "Open", "de": "Offen"} }' > "$tmp/exempt.json"
out="$(python3 scripts/xcstrings-add.py "$tmp/exempt.json" --catalog "$tmp/cat.xcstrings" --languages "$tmp/langs.json")"
[[ "$out" == *'1 without pending `nl`'* ]] || { echo "exempt gap not counted: $out"; exit 1; }
rm "$tmp/placeholder-exemptions.json"

# The live list: a key without a value in a `required` language (nl since
# 1.5 L10N-FINAL) aborts without writing.
echo '{ "f.no.nl": {"en": "Only English and German", "de": "Nur Englisch und Deutsch"} }' > "$tmp/no-nl.json"
cp "$tmp/cat.xcstrings" "$tmp/before-live"
python3 - <<'PY' && live_nl_required=1 || live_nl_required=0
import json; raise SystemExit(0 if json.load(open("scripts/l10n/languages.json"))["languages"].get("nl") == "required" else 1)
PY
if [[ $live_nl_required == 1 ]]; then
  if python3 scripts/xcstrings-add.py "$tmp/no-nl.json" --catalog "$tmp/cat.xcstrings" 2>/dev/null; then
    echo "accepted a key without the required nl value"; exit 1
  fi
  cmp -s "$tmp/before-live" "$tmp/cat.xcstrings" || { echo "wrote despite a required nl gap"; exit 1; }
fi

# Medical keys: every language but German lands as needs_review.
echo '{ "mentalHealth.test": {"en": "Not a diagnosis", "de": "Keine Diagnose"} }' > "$tmp/med.json"
python3 scripts/xcstrings-add.py "$tmp/med.json" --catalog "$tmp/cat.xcstrings" --languages "$tmp/de-en.json" >/dev/null
python3 - "$tmp/cat.xcstrings" <<'EOF'
import json,sys
l=json.load(open(sys.argv[1]))["strings"]["mentalHealth.test"]["localizations"]
assert l["en"]["stringUnit"]["state"]=="needs_review", l
assert l["de"]["stringUnit"]["state"]=="translated", l
EOF

# A catalog written with Xcode's older " : " separator keeps it.
printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n    "a" : {\n      "localizations" : {\n\n      }\n    }\n  },\n  "version" : "1.0"\n}\n' > "$tmp/spaced.xcstrings"
python3 scripts/xcstrings-add.py "$tmp/add.json" --catalog "$tmp/spaced.xcstrings" --languages "$tmp/de-en.json" >/dev/null
grep -q '"b.new" : {' "$tmp/spaced.xcstrings" || { echo "separator style lost"; exit 1; }
if grep -q '"b.new": {' "$tmp/spaced.xcstrings"; then echo "mixed separators"; exit 1; fi

# The real catalogs round-trip byte-identical through an empty add.
echo '{}' > "$tmp/empty.json"
for catalog in HealthLog/Resources/Localizable.xcstrings HealthLogWidgets/Resources/Localizable.xcstrings \
  HealthLogWatch/Resources/Localizable.xcstrings HealthLogWatchWidgets/Localizable.xcstrings \
  NotificationServiceExtension/Resources/Localizable.xcstrings; do
  cp "$catalog" "$tmp/rt.xcstrings"
  python3 scripts/xcstrings-add.py "$tmp/empty.json" --catalog "$tmp/rt.xcstrings" --languages "$tmp/de-en.json" >/dev/null
  cmp -s "$catalog" "$tmp/rt.xcstrings" || { echo "round trip changed $catalog"; exit 1; }
done
echo "test-xcstrings-add: PASS"
