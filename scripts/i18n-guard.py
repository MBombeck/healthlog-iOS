#!/usr/bin/env python3
"""i18n build-time guard (v0.8.0 W5) — fail on German literals inside a localization API.

The catalogue is `sourceLanguage: en` (after the v0.7.2 de→en flip). A German
string literal passed to a localization API derives a German catalogue key that
has no English source unit, so it renders raw German under the English locale.
This guard is the loc-API-scoped, low-false-positive gate that re-introduction
must not pass — it mirrors the API surface of `scripts/flip-literals.py`.

Detection: a literal is flagged iff
  1. it sits in a localization-deriving API call
     (`Text(`, `String(localized:`, `NSLocalizedString(`,
      `LocalizedStringResource(`, `LocalizedStringKey(`, `Button(`, `Label(`,
      `Section(`, `Picker(`, `Toggle(`, `TextField(`, `Tab(`, `Link(`, `Menu(`,
      `Stepper(`, `NavigationLink(`, `HLButton(`, `HLBadge(`,
      `ContentUnavailableView(`, `ProgressView(`, `LabeledContent(`,
      `DatePicker(`,
      `.navigationTitle(`, `.navigationBarTitle(`, `.accessibilityLabel(`,
      `.accessibilityHint(`, `.accessibilityValue(`, `.alert(`,
      `.confirmationDialog(`, the `prompt:` named arg
      (`.searchable(prompt:)` / `TextField(prompt:)`), and the
      `HLSettingsCard/Page/PageHeader` `title:/subtitle:/footer:` wrappers), AND
  2. it looks German — contains äöüÄÖÜß OR a German function word.

Allow-listed (German there is intentional, NOT a catalogue-key leak):
  * `Text(verbatim:`        — renders the string as-is, never localized.
  * `Services/AI/**`        — on-device LLM prompt builders (plain String).
  * `DoctorReport*`         — explicit per-`ReportLocale` `.de` PDF branch.
  * `*Tests` / `*UITests`   — fixtures.
  * dotted-ID keys          — `a.b.c` passthrough catalogue keys.
  * a line carrying `// i18n-guard: allow` — explicit per-line opt-out + reason.

Exit code 1 (with a report) on any flag, 0 when clean. Wire into the lint gate
right after `swiftlint`.

Second rule (1.5 L10N-CORE, R2 3.1): no language decision outside
`AppLanguage`. `.languageCode`, `preferredLocalizations` and
`Locale.preferredLanguages` in app code outside `AppLanguage.swift` fail the
guard. The only exceptions are the files in `_LANGUAGE_ALLOWLIST`, each with a
reason and the exact number of hits it may carry. The allowlist only shrinks:
a file with more hits fails, and so does one with fewer (lower the count or
drop the entry). The per-line `// i18n-guard: allow` marker does not apply to
this rule. Comment lines and `*Tests` paths are skipped like above.

Usage: scripts/i18n-guard.py [ROOT]   (ROOT defaults to ./HealthLog)
       scripts/i18n-guard.py --self-test
"""
from __future__ import annotations

import os
import re
import sys

_FOUNDATION = [
    r"String\(localized:\s*",
    r"NSLocalizedString\(\s*",
    r"LocalizedStringResource\(\s*",
    r"LocalizedStringKey\(\s*",
]
_KEY_FIRST_ARG_APIS = [
    "Text", "Button", "Label", "Section", "Picker", "Toggle", "TextField",
    "Tab", "Link", "Menu", "Stepper", "NavigationLink", "HLButton", "HLBadge",
    # L10N-7 — previously-uncovered first-arg-`LocalizedStringKey` APIs.
    "ContentUnavailableView", "ProgressView", "LabeledContent", "DatePicker",
]
_KEY_FIRST_ARG_MODIFIERS = [
    "navigationTitle", "navigationBarTitle", "accessibilityLabel",
    "accessibilityHint", "accessibilityValue", "alert", "confirmationDialog",
]
# L10N-7 — a bare literal on a `prompt:` named arg is a `LocalizedStringKey`
# (`.searchable(prompt:)`, `TextField(…, prompt:)`) and derives a catalogue key
# just like a first-arg literal. `prompt: Text("…")` is caught by the `Text(`
# matcher instead, so this only fires on the direct-literal form.
_KEY_NAMED_ARGS = ["prompt"]
_LSK_NAMED_ARG_WRAPPERS = ["HLSettingsCard", "HLSettingsPage", "HLSettingsPageHeader"]
_LSK_NAMED_ARGS = ["title", "subtitle", "footer"]

_EXCLUDED_PATH_RES = [
    re.compile(r"/Services/AI/"),
    re.compile(r"/Services/DoctorReport"),
    re.compile(r"/Screens/DoctorReport/"),
]

_UMLAUT = re.compile(r"[äöüÄÖÜß]")
_GERMAN_WORDS = re.compile(
    r"\b(?:und|oder|nicht|noch|kein|keine|keinen|wird|wurde|werden|ist|sind|"
    r"deine?|dein|du|eine|einen|einer|mehr|von|mit|zum|zur|für|über|den|dem|"
    r"heute|gestern|bitte|alle|jede[rs]?|aller|nach|vor|auf|aus|bei|ohne|"
    r"messung|messungen|einträge|eintrag|verlauf|stimmung|tage|tagen|woche|"
    r"monat|jahr|gegenüber|vorwoche|punkten|punkte|zielbereich|verfügbar|"
    r"hinzufügen|löschen|öffnen|quelle|spiegel|wirkstoff|einnahme|erfasse|"
    r"erfassen|logge|gewählt|geplant|offen|alles|sauber|genug|genommen|"
    r"unbekannt|veränderung|schritte|gewicht|blutdruck|herzfrequenz|diese[rs]?|"
    r"nebenwirkung|medikament|medikamente|erinnerung|metrik|metriken|"
    r"mittelwert|reihenfolge|kachel|kacheln|neuer|neues|letzte[rs]?|verbinden|"
    r"verbindung|trennen|aktivieren|deaktiviert|ausgeblendet|anzeigen|"
    r"verbergen|wiederherstellen|synchronisieren|zugestellt|abgelehnt|"
    r"blockiert|teilweise|prozent|schnitt|säule|aufschlüsselung|forschungsmodus|"
    r"bestätigen|entfernen|sicherheit|konto|abmelden|anmelden|schlüssel|fehlt)\b",
    re.IGNORECASE,
)
_DOTTED = re.compile(r"^[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9_]+)+$")
_ALLOW_LINE = re.compile(r"//\s*i18n-guard:\s*allow")


def _build_patterns():
    pats = [re.compile(f'({f})"((?:[^"\\\\]|\\\\.)*)"') for f in _FOUNDATION]
    for api in _KEY_FIRST_ARG_APIS:
        pats.append(re.compile(rf'(\b{api}\(\s*)"((?:[^"\\]|\\.)*)"'))
    for mod in _KEY_FIRST_ARG_MODIFIERS:
        pats.append(re.compile(rf'(\.{mod}\(\s*)"((?:[^"\\]|\\.)*)"'))
    for arg in _KEY_NAMED_ARGS:
        pats.append(re.compile(rf'(\b{arg}:\s*)"((?:[^"\\]|\\.)*)"'))
    wrappers = "|".join(_LSK_NAMED_ARG_WRAPPERS)
    args = "|".join(_LSK_NAMED_ARGS)
    pats.append(
        re.compile(rf'(\b(?:{wrappers})\((?:[^()"]|"[^"]*")*?\b(?:{args}):\s*)"((?:[^"\\]|\\.)*)"')
    )
    return pats


_PATTERNS = _build_patterns()


def _looks_german(literal: str) -> bool:
    return bool(_UMLAUT.search(literal) or _GERMAN_WORDS.search(literal))


def _excluded_path(path: str) -> bool:
    norm = path.replace(os.sep, "/")
    if "Tests/" in norm or norm.endswith("Tests.swift"):
        return True
    return any(rx.search(norm) for rx in _EXCLUDED_PATH_RES)


def scan(root: str):
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            if _excluded_path(path):
                continue
            with open(path, encoding="utf-8") as fh:
                for lineno, line in enumerate(fh, 1):
                    if "verbatim:" in line or _ALLOW_LINE.search(line):
                        continue
                    for pat in _PATTERNS:
                        for m in pat.finditer(line):
                            lit = m.group(2)
                            if _DOTTED.match(lit):
                                continue
                            if _looks_german(lit):
                                hits.append((path, lineno, lit))
    return hits


_LANGUAGE_DECISION = re.compile(r"\.languageCode\b|\bpreferredLocalizations\b|\bLocale\.preferredLanguages\b")
_LANGUAGE_HOME = "AppLanguage.swift"

# path relative to ROOT -> (hits allowed, reason). Shrinks only.
_LANGUAGE_ALLOWLIST: dict[str, tuple[int, str]] = {
    "Screens/Settings/Sub/SettingsAboutScreen+SupportInfo.swift": (
        1, "support info reports the raw bundle localization for diagnosis, it decides nothing"),
}


def scan_language_decisions(root: str):
    """Who decides the UI language outside `AppLanguage`: (relpath, line, text)."""
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if not name.endswith(".swift") or name == _LANGUAGE_HOME:
                continue
            path = os.path.join(dirpath, name)
            norm = path.replace(os.sep, "/")
            if "Tests/" in norm or norm.endswith("Tests.swift"):
                continue
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            with open(path, encoding="utf-8") as fh:
                for lineno, line in enumerate(fh, 1):
                    if line.lstrip().startswith("//"):
                        continue
                    if _LANGUAGE_DECISION.search(line):
                        hits.append((rel, lineno, line.strip()))
    return hits


def check_language_decisions(root: str, allowlist=None) -> list[str]:
    """Problems with the language rule; empty when every hit is allow-listed exactly."""
    allowlist = _LANGUAGE_ALLOWLIST if allowlist is None else allowlist
    per_file: dict[str, list[tuple[int, str]]] = {}
    for rel, lineno, line in scan_language_decisions(root):
        per_file.setdefault(rel, []).append((lineno, line))
    problems = []
    for rel, rows in sorted(per_file.items()):
        allowed = allowlist.get(rel, (0, ""))[0]
        if len(rows) > allowed:
            for lineno, line in rows:
                problems.append(f"{root}/{rel}:{lineno}: {line}")
            if allowed:
                problems.append(f"  {rel}: {len(rows)} hits, allowlist permits {allowed}")
    for rel, (allowed, _reason) in sorted(allowlist.items()):
        found = len(per_file.get(rel, []))
        if found < allowed:
            problems.append(
                f"{rel}: allowlist permits {allowed} hit(s), {found} left; "
                "lower the count or drop the entry (the allowlist only shrinks)"
            )
    return problems


def _self_test() -> int:
    import tempfile

    failures = []

    def run(files: dict[str, str], allowlist) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            for rel, text in files.items():
                path = os.path.join(tmp, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text)
            return check_language_decisions(tmp, allowlist)

    decide = 'let c = Locale.current.language.languageCode?.identifier ?? "de"\n'
    cases = [
        ("decision outside AppLanguage fails", {"Screens/A.swift": decide}, {}, True),
        ("preferredLocalizations fails", {"A.swift": "Bundle.main.preferredLocalizations.first\n"}, {}, True),
        ("Locale.preferredLanguages fails", {"A.swift": "Locale.preferredLanguages.first\n"}, {}, True),
        ("AppLanguage.swift itself passes", {"Util/AppLanguage.swift": decide}, {}, False),
        ("comment line passes", {"A.swift": "// " + decide}, {}, False),
        ("test file passes", {"FooTests.swift": decide}, {}, False),
        ("per-line allow marker does not exempt", {"A.swift": decide.rstrip() + " // i18n-guard: allow\n"}, {}, True),
        ("allow-listed with the exact count passes", {"A.swift": decide}, {"A.swift": (1, "r")}, False),
        ("one hit more than allow-listed fails", {"A.swift": decide * 2}, {"A.swift": (1, "r")}, True),
        ("stale allowlist count fails", {"A.swift": "let x = 1\n"}, {"A.swift": (1, "r")}, True),
        ("AppLanguage.current passes", {"A.swift": "let c = AppLanguage.current.serverCode\n"}, {}, False),
    ]
    for name, files, allowlist, want_fail in cases:
        got_fail = bool(run(files, allowlist))
        status = "ok" if got_fail == want_fail else "FAIL"
        if got_fail != want_fail:
            failures.append(name)
        print(f"  {status}: {name}")
    if failures:
        print(f"i18n-guard self-test: {len(failures)} of {len(cases)} failed", file=sys.stderr)
        return 1
    print(f"i18n-guard self-test: PASS {len(cases)}/{len(cases)}")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return _self_test()
    root = sys.argv[1] if len(sys.argv) > 1 else "HealthLog"
    status = 0
    language_problems = check_language_decisions(root)
    if language_problems:
        print(f"i18n-guard: language decided outside {_LANGUAGE_HOME}:", file=sys.stderr)
        for line in language_problems:
            print(f"  {line}", file=sys.stderr)
        print(
            "\nFix: read AppLanguage.current (Util/AppLanguage.swift) instead. Only formatting "
            "and the support info may stay, listed in _LANGUAGE_ALLOWLIST with a reason.",
            file=sys.stderr,
        )
        status = 1
    else:
        allowed = sum(count for count, _ in _LANGUAGE_ALLOWLIST.values())
        print(f"i18n-guard: language decided only in {_LANGUAGE_HOME} "
              f"({allowed} allow-listed hit(s) in {len(_LANGUAGE_ALLOWLIST)} file(s)).")
    hits = scan(root)
    if not hits:
        print("i18n-guard: clean — no German literals in localization APIs.")
        return status
    print(f"i18n-guard: {len(hits)} German literal(s) in a localization API "
          f"(would render raw German under the English locale):", file=sys.stderr)
    for path, lineno, lit in sorted(hits):
        print(f"  {path}:{lineno}: {lit!r}", file=sys.stderr)
    print(
        "\nFix: add an English key to Localizable.xcstrings with a `de` "
        "translation = the German text, then use the English key here. For a "
        "genuine exception add `// i18n-guard: allow` + a reason on the line.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
