#!/usr/bin/env bash
#
# UI-Standard E8 (R18) — Katalog-Hygiene für `HealthLog/Resources/Localizable.xcstrings`.
#
# Prüft drei Dinge:
#
#   1. **Unreferenzierte Schlüssel.** Ein Schlüssel, den kein Quelltext mehr
#      nennt, ist eine Katalogleiche. „Nennen" heißt hier mehr als ein
#      wörtliches Literal — siehe den Abschnitt unten.
#   2. **Fehlende Übersetzungen.** Jeder Eintrag mit Lokalisierungen braucht
#      `de` UND `en` (DE primär, EN Parität — PROJECT_GUIDE.md).
#   3. **Mojibake.** Doppelt kodierte UTF-8-Sequenzen (`flieãŸen` statt
#      `fließen`).
#
# ## Warum ein Grep auf Literale nicht reicht (U8-Befund)
#
# Drei Referenzarten sehen für einen naiven Grep aus wie „unbenutzt":
#
#   * **Interpolierte `Text()`-Schlüssel.** `Text("\(n) Einträge")` erzeugt den
#      Katalogschlüssel `%lld Einträge`. Im Quelltext steht das Literal
#      `\(n) Einträge` — der Schlüssel selbst kommt nirgends vor. Das Skript
#      übersetzt darum jedes interpolierte Literal in ein Formatspezifizierer-
#      Muster und gleicht die Schlüssel dagegen ab.
#   * **Zur Laufzeit zusammengesetzte Schlüssel.** `"report.leaf.\(leaf)"`,
#      `resolve(prefix: "insights.coach.metric.", token:)`, Server-gelieferte
#      `labelKey`/`titleKey`. Diese Familien stehen als Präfix samt Fundstelle
#      in `dynamicKeyPrefixes` der Baseline.
#   * **Mehrzeilige `"""`-Literale.** `EcgDetailScreen.swift:101` baut
#      `insights.ecg.waveform.a11y %@ %@ %@ %@` über vier Zeilen mit
#      Fortsetzungs-Backslashes. Ein zeilenweiser Literal-Scan sieht davon nur
#      Bruchstücke; das Skript setzt den Wert nach Swifts Regeln zusammen
#      (Einrückung des schließenden Delimiters abziehen, `\` + Umbruch
#      verbinden). Dieser Fall hat in U8 einen lebenden Schlüssel gekostet und
#      ist der Grund, dass er hier steht.
#   * **Schlüssel, die nur ein Test festnagelt** (`testAnchored`): kein
#      Bildschirm nennt sie mehr, aber ein i18n-Regressionsanker verlangt sie
#      — auch interpoliert (`String(localized: "key \(a) \(b)")` im Test).
#
# Die Baseline `scripts/check-strings-baseline.json` ist eine Ratsche und keine
# Erlaubnisliste: alle Listen werden in **beide** Richtungen abgeglichen. Ein
# Präfix ohne Fundstelle, ein `testAnchored`-Schlüssel ohne Testerwähnung und
# ein `knownOrphans`-Eintrag, der wieder referenziert wird, schlagen an. Damit
# können die Listen nicht auf Vorrat wachsen, sondern nur schrumpfen.
#
#   scripts/check-strings.sh            # prüft, exit 1 bei Befund
#   scripts/check-strings.sh --write    # schreibt `knownOrphans` neu (nur bewusst!)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - "$@" <<'PYTHON'
import json
import os
import re
import sys

WRITE = "--write" in sys.argv[1:]

CATALOG = "HealthLog/Resources/Localizable.xcstrings"
BASELINE = "scripts/check-strings-baseline.json"

# Ziele, in denen ein Katalogschlüssel als String-Literal auftauchen kann.
SOURCE_ROOTS = [
    "HealthLog",
    "HealthLogWatch",
    "HealthLogWatchWidgets",
    "HealthLogWidgets",
    "NotificationServiceExtension",
]

# Testziele — sie halten `testAnchored` am Leben, zählen aber nicht als
# Nutzung durch die App.
TEST_ROOTS = [
    "HealthLogTests",
    "HealthLogUITests",
    "HealthLogWatchTests",
]

# Klassisches Doppel-Encoding: ein Mojibake-Leitzeichen, gefolgt von einem
# Fortsetzungsbyte, das als Zeichen gerendert wurde.
MOJIBAKE = re.compile("[ÃÂãâÅ][-¿Œ-Ÿ–-€]")

# Ein Formatspezifizierer, wie ihn SwiftUI/Foundation aus einer Interpolation
# in den Katalogschlüssel schreibt (`%lld`, `%@`, `%1$@`, `%.1f`, …).
FORMAT_SPEC = r"%(?:\d+\$)?[-+ #0]*[\d]*(?:\.\d+)?(?:ll|l|h|hh|z|t|q)?[@diufFeEgGxXoscpaA]"

catalog = json.load(open(CATALOG, encoding="utf-8"))
entries = catalog["strings"]
baseline = json.load(open(BASELINE, encoding="utf-8"))

server_provided = set(baseline.get("serverProvided", []))
dynamic_prefixes = baseline.get("dynamicKeyPrefixes", {})
test_anchored = set(baseline.get("testAnchored", []))
known_orphans = set(baseline.get("knownOrphans", []))

# ---------------------------------------------------------------- Referenzen
literal_re = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
multiline_re = re.compile(r'"""\n(.*?)^[ \t]*"""', re.S | re.M)


def multiline_value(body, closing_indent):
    """Rekonstruiert den Wert eines `\"\"\"`-Literals.

    Swift zieht die Einrückung des schließenden Delimiters von jeder Zeile ab
    und fügt eine mit `\\` beendete Zeile ohne Zeilenumbruch an die nächste an.
    Genau so entsteht `insights.ecg.waveform.a11y %@ %@ %@ %@` aus dem
    vierzeiligen Literal in `EcgDetailScreen.swift:101` — ohne diese
    Rekonstruktion sähe der Schlüssel unreferenziert aus.
    """
    lines = body.split("\n")
    if lines and lines[-1].strip() == "":
        lines = lines[:-1]
    lines = [
        line[len(closing_indent):] if line.startswith(closing_indent) else line.lstrip()
        for line in lines
    ]
    pieces = []
    for index, line in enumerate(lines):
        if line.endswith("\\") and not line.endswith("\\\\"):
            pieces.append(line[:-1])
            continue
        pieces.append(line)
        if index < len(lines) - 1:
            pieces.append("\n")
    return "".join(pieces)


def _read_literal(text, index):
    """Liest EIN einzeiliges Literal ab `index` (hinter dem Anführungszeichen).

    Gibt `(rumpf, index_hinter_dem_schließenden_zeichen, verschachtelte)` zurück.
    Der Rumpf behält seine `\\(…)`-Interpolationen wörtlich, damit
    ``interpolation_segments`` unverändert damit weiterarbeiten kann.
    """
    body, nested, size = [], [], len(text)
    while index < size:
        char = text[index]
        if char == "\\" and index + 1 < size:
            if text[index + 1] == "(":
                depth, cursor = 0, index + 1
                while cursor < size:
                    inner = text[cursor]
                    if inner == '"':
                        value, cursor, deeper = _read_literal(text, cursor + 1)
                        nested.append(value)
                        nested.extend(deeper)
                        continue
                    if inner == "(":
                        depth += 1
                    elif inner == ")":
                        depth -= 1
                        if depth == 0:
                            cursor += 1
                            break
                    elif inner == "\n":
                        break  # unbalanciert — defensiv abbrechen
                    cursor += 1
                body.append(text[index:cursor])
                index = cursor
                continue
            body.append(text[index:index + 2])
            index += 2
            continue
        if char == '"':
            return "".join(body), index + 1, nested
        if char == "\n":
            return "".join(body), index, nested  # unterminiert — defensiv abbrechen
        body.append(char)
        index += 1
    return "".join(body), index, nested


def literals_in(text):
    """Jedes einzeilige Literal — auch die INNERHALB einer Interpolation.

    Ein naiver Paar-Regex über `"a \\(String(localized: "key")) b"` sieht die
    Anführungszeichen in der falschen Reihenfolge und liefert zwei Bruchstücke,
    in denen `key` gar nicht vorkommt. Genau so blieb
    `clinicalSignals.labs.previous` unsichtbar: `LabsChangesCard.swift:118` ist
    seine EINZIGE Fundstelle, der Schlüssel fehlte im Katalog, und weder die
    Leichen- noch eine Fehlt-Prüfung konnte ihn sehen. Dieser Scanner liest
    Literale zeichenweise und steigt in jede Interpolation ab.
    """
    found, index, size = [], 0, len(text)
    while index < size:
        if text[index] == '"':
            value, index, nested = _read_literal(text, index + 1)
            found.append(value)
            found.extend(nested)
            continue
        index += 1
    return found


def scan(roots):
    """Alle String-Literale und der rohe Quelltext der Ziele."""
    literals, blob = set(), []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if not name.endswith(".swift"):
                    continue
                with open(os.path.join(dirpath, name), encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                blob.append(text)
                for match in multiline_re.finditer(text):
                    closing = text[match.start():match.end()].rsplit("\n", 1)[-1]
                    indent = closing[:len(closing) - len(closing.lstrip())]
                    literals.add(multiline_value(match.group(1), indent))
                # Die `"""`-Blöcke sind ersetzt, damit ihr Inhalt nicht ein
                # zweites Mal als einzeilige Literale zerfällt.
                literals.update(literals_in(multiline_re.sub('""', text)))
    return literals, "\n".join(blob)


literals, source_blob = scan(SOURCE_ROOTS)
test_literals, _ = scan(TEST_ROOTS)


def interpolation_segments(literal):
    """Zerlegt ein Swift-Literal an seinen `\\(…)`-Interpolationen.

    Gibt `None` zurück, wenn das Literal keine Interpolation enthält.
    """
    segments, buffer, i, size, found = [], [], 0, len(literal), False
    escapes = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}
    while i < size:
        if literal[i] == "\\" and i + 1 < size:
            if literal[i + 1] == "(":
                found = True
                segments.append("".join(buffer))
                buffer = []
                depth, i = 0, i + 1
                while i < size:
                    if literal[i] == "(":
                        depth += 1
                    elif literal[i] == ")":
                        depth -= 1
                        if depth == 0:
                            i += 1
                            break
                    i += 1
                continue
            buffer.append(escapes.get(literal[i + 1], literal[i + 1]))
            i += 2
            continue
        buffer.append(literal[i])
        i += 1
    segments.append("".join(buffer))
    return segments if found else None


def interpolation_patterns(source_literals):
    patterns = []
    for literal in source_literals:
        segments = interpolation_segments(literal)
        if segments:
            joined = FORMAT_SPEC.join(re.escape(segment) for segment in segments)
            patterns.append(re.compile("^" + joined + "$"))
    return patterns


interpolated = interpolation_patterns(literals)
test_interpolated = interpolation_patterns(test_literals)


def dynamic_family(key):
    for prefix in sorted(dynamic_prefixes, key=len, reverse=True):
        if key.startswith(prefix):
            return prefix
    return None


def referenced(key):
    """Nennt die App diesen Schlüssel — wörtlich, interpoliert oder dynamisch?"""
    if key in literals:
        return "literal"
    if any(pattern.match(key) for pattern in interpolated):
        return "interpoliert"
    if dynamic_family(key):
        return "dynamisch"
    return None


unreferenced = {key for key in entries if referenced(key) is None}
tolerated = server_provided | test_anchored | known_orphans

# ---------------------------------------------------------------- Übersetzungen
missing = {"de": [], "en": []}
for key, entry in entries.items():
    localizations = entry.get("localizations")
    if not localizations:
        continue  # Quellsprache-Only-Eintrag; EmptyTranslationGuardTests deckt das ab.
    for lang in ("de", "en"):
        block = localizations.get(lang) or {}
        has_text = bool((block.get("stringUnit") or {}).get("value"))
        if not has_text and not block.get("variations"):
            missing[lang].append(key)

# ---------------------------------------------------------------- Mojibake
mojibake = set()
for key, entry in entries.items():
    # Mojibake in einem bereits verwaisten Schlüssel ist kein Nutzerbefund —
    # der Text wird nirgends gerendert und die zuständige Einheit löscht den
    # Schlüssel ohnehin. Ein LEBENDER Schlüssel mit Mojibake schlägt an.
    if key in known_orphans and key in unreferenced:
        continue
    for block in (entry.get("localizations") or {}).values():
        value = (block.get("stringUnit") or {}).get("value") or ""
        if MOJIBAKE.search(value):
            mojibake.add(key)

# ---------------------------------------------------------------- Auswertung
if WRITE:
    baseline["knownOrphans"] = sorted(unreferenced - server_provided - test_anchored)
    with open(BASELINE, "w", encoding="utf-8") as handle:
        json.dump(baseline, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"Baseline neu geschrieben: {len(baseline['knownOrphans'])} bekannte Katalogleichen.")
    raise SystemExit(0)

problems = 0

new_orphans = sorted(unreferenced - tolerated)
if new_orphans:
    problems += len(new_orphans)
    print(f"\n✗ {len(new_orphans)} NEUE unreferenzierte Schlüssel (R18 — Katalogleiche):")
    for key in new_orphans[:60]:
        print(f"    {key}")
    print("  → Schlüssel löschen. Oder, falls er doch genannt wird:")
    print("    · der Server liefert ihn      → `serverProvided`")
    print("    · er wird zur Laufzeit gebaut → `dynamicKeyPrefixes` (Präfix + Fundstelle)")
    print("    · nur ein i18n-Anker hält ihn → `testAnchored`")
    print("    in scripts/check-strings-baseline.json.")

resurrected = sorted(known_orphans & literals)
if resurrected:
    problems += len(resurrected)
    print(f"\n✗ {len(resurrected)} `knownOrphans`-Einträge werden wieder referenziert — STREICHEN:")
    for key in resurrected:
        print(f"    {key}")
    print("  → Die Liste ist eine Restschuld-Anzeige. Ein referenzierter Schlüssel")
    print("    darf nicht darin stehen, sonst könnte sie wachsen statt zu schrumpfen.")

# Rückrichtung: jeder Präfix braucht eine lebende Fundstelle im Quelltext UND
# mindestens einen Schlüssel, den er schützt. Ein Präfix ohne Schlüssel ist
# meist gar kein Katalog-Namensraum, sondern ein Accessibility-Identifier.
stale_prefixes = sorted(
    p for p in dynamic_prefixes
    if p not in source_blob or not any(key.startswith(p) for key in entries)
)
if stale_prefixes:
    problems += len(stale_prefixes)
    print(f"\n✗ {len(stale_prefixes)} `dynamicKeyPrefixes` ohne Fundstelle im Quelltext — STREICHEN:")
    for prefix in stale_prefixes:
        print(f"    {prefix}   ({dynamic_prefixes[prefix]})")
    print("  → Fällt die Stelle, die den Schlüssel baut, fällt der Schutz für die Familie —")
    print("    und die Schlüssel werden zu ganz normalen Katalogleichen.")

# Rückrichtung: `testAnchored` gilt nur, solange ein Test den Schlüssel nennt
# und die App ihn NICHT nennt.
def named_by_tests(key):
    return key in test_literals or any(pattern.match(key) for pattern in test_interpolated)


stale_anchors = sorted(key for key in test_anchored if not named_by_tests(key))
if stale_anchors:
    problems += len(stale_anchors)
    print(f"\n✗ {len(stale_anchors)} `testAnchored`-Schlüssel nennt kein Test mehr — STREICHEN (und Schlüssel löschen):")
    for key in stale_anchors:
        print(f"    {key}")

live_anchors = sorted(key for key in test_anchored if referenced(key))
if live_anchors:
    problems += len(live_anchors)
    print(f"\n✗ {len(live_anchors)} `testAnchored`-Schlüssel sind wieder in der App referenziert — STREICHEN:")
    for key in live_anchors:
        print(f"    {key}")

missing_anchors = sorted(test_anchored - set(entries))
if missing_anchors:
    problems += len(missing_anchors)
    print(f"\n✗ {len(missing_anchors)} `testAnchored`-Schlüssel fehlen im Katalog:")
    for key in missing_anchors:
        print(f"    {key}")

for lang in ("de", "en"):
    if missing[lang]:
        problems += len(missing[lang])
        print(f"\n✗ {len(missing[lang])} Einträge ohne `{lang}`-Übersetzung (DE primär, EN Parität):")
        for key in sorted(missing[lang])[:40]:
            print(f"    {key}")

if mojibake:
    problems += len(mojibake)
    print(f"\n✗ {len(mojibake)} Einträge mit Mojibake (doppelt kodiertes UTF-8):")
    for key in sorted(mojibake):
        print(f"    {key}")

dynamic_keys = sum(1 for key in entries if key not in literals and dynamic_family(key))
interp_keys = sum(
    1 for key in entries
    if key not in literals and not dynamic_family(key) and any(p.match(key) for p in interpolated)
)
print(
    f"\n{len(entries)} Schlüssel · {dynamic_keys} über dynamische Familien erreicht"
    f" · {interp_keys} über interpolierte Literale · {len(test_anchored)} nur von Tests festgenagelt"
    f" · {len(known_orphans)} Restschuld"
)

if problems:
    print(f"\nFEHLGESCHLAGEN — {problems} Befund(e).")
    raise SystemExit(1)

print("OK — Katalog-Hygiene sauber.")
PYTHON
