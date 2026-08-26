#!/usr/bin/env bash
#
# Die GEGENRICHTUNG zu `check-strings.sh` — Referenzen ohne Schlüssel.
#
# Owner: Phase 08 Plan 16.
#
# ## Warum es das gibt
#
# `check-strings.sh` sucht Katalogleichen: Schlüssel, die kein Quelltext mehr
# nennt. Es sucht NICHT die andere Richtung — eine Referenz, für die es keinen
# Schlüssel gibt. Genau die ist der teurere Fehler, weil sie sichtbar ist: der
# Nutzer liest `vorsorge.history.title` statt „Verlauf".
#
# Plan 08-22 hat 29 solcher Referenzen ausgeliefert. `check-strings.sh` lief
# dabei mit Exit 0 über 5.163 Schlüssel und null Leichen — nicht weil es
# nachsichtig war, sondern weil es die Frage nie gestellt hat. Dieses Skript
# stellt sie.
#
# ## Was geprüft wird
#
# Jedes String-Literal in DOTTED-ID-Form (`a.b.c`), das an einer
# Lokalisierungs-API steht, muss im Katalog SEINES Ziels stehen.
#
# Die API-Liste ist nicht neu erfunden: sie wird aus `scripts/i18n-guard.py`
# importiert. Der Guard prüft dieselben Stellen auf deutsche Literale und
# überspringt dotted IDs ausdrücklich („dotted-ID keys — a.b.c passthrough
# catalogue keys") — dieses Skript ist exakt die Ergänzung dieses `continue`.
# Wächst die API-Liste des Guards, wächst diese Prüfung mit; es gibt keine
# zweite Liste, die veralten könnte.
#
# Jedes Ziel wird gegen SEINEN eigenen Katalog geprüft. Widgets, Watch und die
# Notification-Extension haben eigene `Localizable.xcstrings`; gegen den
# App-Katalog geprüft, wären 48 völlig gesunde Schlüssel „fehlend".
#
# ## Was NICHT geprüft wird — und warum es hier steht
#
# Diese Prüfung ist fail-closed für die API-Fläche, die sie kennt, und für
# nichts darüber hinaus. Sie sieht NICHT:
#
#   * Literale, die an eine projekteigene Hilfsfunktion gehen, deren Parameter
#     ein `LocalizedStringKey` ist (`note("vorsorge.history.empty")` im
#     Ledger-Abschnitt). Dafür bräuchte es Typinformation, nicht Text.
#   * Schlüssel, die zur Laufzeit aus einem `switch` kommen
#     (`Text(LocalizedStringKey(entry.kindKey))`). Kein Literal-Scan der Welt
#     weiß, dass `kindKey` ein Katalogschlüssel ist.
#
# Beides deckt `HealthLogTests/Resources/Phase8LocalizationKeysTests.swift` für
# die betroffene Familie namentlich ab. Eine allgemeine Prüfung müsste jedes
# dotted Literal im Baum betrachten — im App-Ziel sind das rund 490 Kandidaten,
# ganz überwiegend SF-Symbol-Namen, Keychain-Schlüssel und Server-Fehlercodes.
# Die bräuchte eine eigene Positivliste und damit einen eigenen Plan.
#
# Ausnahme pro Zeile: `// i18n-guard: allow` (dieselbe Marke wie der Guard).
#
#   scripts/check-missing-strings.sh          # prüft, exit 1 bei Befund
#   scripts/check-missing-strings.sh --self-test
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - "$@" <<'PYTHON'
import importlib.util
import json
import os
import sys
import tempfile

SELF_TEST = "--self-test" in sys.argv[1:]

# Ziel → eigener Katalog. Ein Ziel ohne Katalog wird übersprungen, nicht geraten.
TARGETS = {
    "HealthLog": "HealthLog/Resources/Localizable.xcstrings",
    "HealthLogWatch": "HealthLogWatch/Resources/Localizable.xcstrings",
    "HealthLogWatchWidgets": "HealthLogWatchWidgets/Localizable.xcstrings",
    "HealthLogWidgets": "HealthLogWidgets/Resources/Localizable.xcstrings",
    "NotificationServiceExtension": "NotificationServiceExtension/Resources/Localizable.xcstrings",
}

# Kein `__pycache__` neben den Skripten: der Import ist ein Werkzeug, keine
# Änderung am Arbeitsbaum.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("i18n_guard", "scripts/i18n-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def catalog_keys(path):
    with open(path, encoding="utf-8") as handle:
        return set(json.load(handle)["strings"])


def missing_in(root, keys):
    """Jede dotted Referenz an einer Lokalisierungs-API ohne Schlüssel."""
    findings = {}
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            if guard._excluded_path(path):
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                for lineno, line in enumerate(handle, 1):
                    if guard._ALLOW_LINE.search(line):
                        continue
                    for pattern in guard._PATTERNS:
                        for match in pattern.finditer(line):
                            literal = match.group(2)
                            if not guard._DOTTED.match(literal) or literal in keys:
                                continue
                            findings.setdefault(literal, []).append(f"{path}:{lineno}")
    return findings


def run(targets):
    problems = 0
    for root in sorted(targets):
        catalog = targets[root]
        if not os.path.isdir(root) or not os.path.isfile(catalog):
            continue
        keys = catalog_keys(catalog)
        findings = missing_in(root, keys)
        if findings:
            problems += len(findings)
            print(f"\n✗ {len(findings)} Referenz(en) ohne Schlüssel in {catalog}:")
            for literal in sorted(findings):
                print(f"    {literal}")
                for site in findings[literal][:3]:
                    print(f"      {site}")
        print(f"{root}: {len(keys)} Schlüssel · {len(findings)} fehlend")
    return problems


if SELF_TEST:
    with tempfile.TemporaryDirectory() as work:
        target = os.path.join(work, "FakeTarget")
        os.makedirs(target)
        catalog = os.path.join(work, "Fake.xcstrings")
        source = os.path.join(target, "Screen.swift")

        def write(keys, body):
            with open(catalog, "w", encoding="utf-8") as handle:
                json.dump(
                    {"sourceLanguage": "en", "version": "1.0",
                     "strings": {key: {} for key in keys}},
                    handle,
                )
            with open(source, "w", encoding="utf-8") as handle:
                handle.write(body)

        failures = []

        # 1. Eine fehlende Referenz an einer Lokalisierungs-API schlägt an.
        write([], 'Text("demo.title")\n')
        if not missing_in(target, catalog_keys(catalog)):
            failures.append("a missing Text(\"a.b\") key was not reported")

        # 2. Dieselbe Referenz mit Schlüssel ist sauber.
        write(["demo.title"], 'Text("demo.title")\n')
        if missing_in(target, catalog_keys(catalog)):
            failures.append("a present key was reported as missing")

        # 3. Auch String(localized:) zählt.
        write([], 'let a = String(localized: "demo.other")\n')
        if not missing_in(target, catalog_keys(catalog)):
            failures.append("String(localized:) was not scanned")

        # 4. Ein Nicht-dotted-Literal ist Quellsprache, kein Schlüssel.
        write([], 'Text("Just English source copy")\n')
        if missing_in(target, catalog_keys(catalog)):
            failures.append("a natural-language source string was treated as a key")

        # 5. Ein dotted Literal AUSSERHALB einer Lokalisierungs-API — ein
        #    SF-Symbol, ein Accessibility-Identifier — ist keins.
        write([], 'Image(systemName: "arrow.up.heart")\n    .accessibilityIdentifier("demo.row")\n')
        if missing_in(target, catalog_keys(catalog)):
            failures.append("a non-localization dotted literal was treated as a key")

        # 6. Die Zeilen-Ausnahme des Guards gilt auch hier.
        write([], 'Text("demo.title") // i18n-guard: allow — intentionally raw\n')
        if missing_in(target, catalog_keys(catalog)):
            failures.append("the per-line allow marker was ignored")

        # 7. Ein Ziel wird nur gegen SEINEN Katalog geprüft.
        write(["demo.title"], 'Text("demo.title")\n')
        if run({target: catalog}) != 0:
            failures.append("a green target did not report zero")

        if failures:
            for failure in failures:
                print(f"✗ {failure}")
            raise SystemExit(1)
        print("\nSelf-test passed: 7 cases.")
        raise SystemExit(0)

problems = run(TARGETS)
if problems:
    print(f"\nFEHLGESCHLAGEN — {problems} Referenz(en) ohne Katalogschlüssel.")
    print("  → Schlüssel mit `de` UND `en` in den Katalog des Ziels aufnehmen.")
    print("    Ein bewusst rohes Literal braucht `// i18n-guard: allow` + Grund.")
    raise SystemExit(1)

print("\nOK — jede geprüfte Lokalisierungs-Referenz hat einen Katalogschlüssel.")
PYTHON
