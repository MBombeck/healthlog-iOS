"""Shared helpers for the string-catalog tooling (scripts/l10n, check-strings.sh, xcstrings-add.py).

One place for: the language list (`languages.json`), the medical key list
(`medical-keys.json`), and reading/writing a `.xcstrings` file byte-stable.
"""
from __future__ import annotations

import json
import os
import re

L10N_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(L10N_DIR))
LANGUAGES_JSON = os.path.join(L10N_DIR, "languages.json")
MEDICAL_KEYS_JSON = os.path.join(L10N_DIR, "medical-keys.json")
PLACEHOLDER_EXEMPTIONS_JSON = os.path.join(L10N_DIR, "placeholder-exemptions.json")

# Every string catalog the app ships, relative to the repository root.
CATALOGS = [
    "HealthLog/Resources/Localizable.xcstrings",
    "HealthLogWidgets/Resources/Localizable.xcstrings",
    "HealthLogWatch/Resources/Localizable.xcstrings",
    "HealthLogWatchWidgets/Localizable.xcstrings",
    "NotificationServiceExtension/Resources/Localizable.xcstrings",
    # The local doctor report's labels, read with the bundle of the report
    # language rather than the interface language (docs/localization.md).
    "HealthLog/Resources/DoctorReport.xcstrings",
    # Siri and Shortcuts read App Shortcut phrases only from this catalog, never
    # from Localizable (1.5 SIRI-L10N). Keys are the English phrase with
    # `${applicationName}` and `${parameter}` tokens.
    "HealthLog/Resources/AppShortcuts.xcstrings",
]

STATUSES = ("required", "pending")


class Languages:
    def __init__(self, source: str, status: dict[str, str]):
        self.source = source
        self.status = status  # insertion order is the write order of xcstrings-add.py

    @property
    def all(self) -> list[str]:
        return list(self.status)

    @property
    def required(self) -> list[str]:
        return [lang for lang, state in self.status.items() if state == "required"]

    @property
    def pending(self) -> list[str]:
        return [lang for lang, state in self.status.items() if state == "pending"]


def load_languages(path: str = LANGUAGES_JSON) -> Languages:
    with open(path, encoding="utf-8") as handle:
        raw = json.load(handle)
    source = raw.get("sourceLanguage")
    status = raw.get("languages") or {}
    if not isinstance(status, dict) or not status:
        raise ValueError(f"{path}: `languages` must be a non-empty object")
    for lang, state in status.items():
        if state not in STATUSES:
            raise ValueError(f"{path}: `{lang}` has status {state!r}, expected one of {STATUSES}")
    if status.get(source) != "required":
        raise ValueError(f"{path}: sourceLanguage {source!r} must be listed as `required`")
    return Languages(source, dict(status))


def load_medical_keys(path: str = MEDICAL_KEYS_JSON) -> tuple[list[str], list[str]]:
    with open(path, encoding="utf-8") as handle:
        raw = json.load(handle)
    return list(raw.get("prefixes", [])), list(raw.get("keys", []))


def is_medical(key: str, medical: tuple[list[str], list[str]]) -> bool:
    prefixes, keys = medical
    return key in keys or any(key.startswith(prefix) for prefix in prefixes)


# ---------------------------------------------------------------- catalog I/O
# Xcode writes the app catalog with `"key": value` and older catalogs with
# `"key" : value`. Whatever a file uses, a tool that rewrites it keeps it, so a
# load + dump with no change is byte-identical.
def separator_of(text: str) -> str:
    return " : " if re.search(r'^\s*"[^"\n]*" : ', text, re.M) else ": "


def dumps_catalog(catalog: dict, separator: str = ": ") -> str:
    return json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", separator)) + "\n"


def read_catalog(path: str) -> tuple[dict, str]:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    return json.loads(text), separator_of(text)


def write_catalog(path: str, catalog: dict, separator: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(dumps_catalog(catalog, separator))


def has_text(block: dict | None) -> bool:
    """A localization block counts as present when it carries any text."""
    if not block:
        return False
    if (block.get("stringUnit") or {}).get("value"):
        return True
    return bool(block.get("variations"))


def translatable(entry: dict) -> bool:
    return entry.get("shouldTranslate", True) is not False and bool(entry.get("localizations"))


def bundle_localizations(project_yml: str) -> list[list[str]]:
    """Every `CFBundleLocalizations:` list in project.yml, in file order.

    project.yml is plain enough that a line scan is exact: the key, then
    `- xx` items one indentation level deeper.
    """
    with open(project_yml, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    found = []
    for index, line in enumerate(lines):
        match = re.match(r"^(\s*)CFBundleLocalizations:\s*$", line)
        if not match:
            continue
        items = []
        for follow in lines[index + 1:]:
            item = re.match(r"^\s*-\s*([A-Za-z0-9_-]+)\s*(?:#.*)?$", follow)
            if not item:
                break
            items.append(item.group(1))
        found.append(items)
    return found


# ---------------------------------------------------------------- placeholders
# A `pending` language ships before it is translated. A key without a value in
# it would show the raw key on screen (`settings.foo.title`), because the
# bundle looks the key up in that language's table and does not fall back to
# English. So every gap in a `pending` language carries an English placeholder:
# the source-language block, copied, with every leaf in state `needs_review`.
# A placeholder is recognised by exactly that shape (same text as the source,
# all `needs_review`); the format gate counts it in a `pending` language and
# fails on it in a `required` one, so the translation pass finds every one.
PLACEHOLDER_STATE = "needs_review"


def leaves(block: dict, path: str = ""):
    """(path, stringUnit) for every leaf of a localization block."""
    if "stringUnit" in block:
        yield path, block["stringUnit"]
    for axis, cases in (block.get("variations") or {}).items():
        for case, sub in cases.items():
            yield from leaves(sub, f"{path}/{axis}.{case}")
    for name, sub in (block.get("substitutions") or {}).items():
        yield from leaves(sub, f"{path}/%{name}")


def placeholder_from(source_block: dict) -> dict:
    """The English placeholder for a gap: the source block, all `needs_review`."""
    block = json.loads(json.dumps(source_block))
    for _, unit in leaves(block):
        unit["state"] = PLACEHOLDER_STATE
    return block


def is_placeholder(block: dict | None, source_block: dict | None) -> bool:
    if not block or not source_block:
        return False
    ours = list(leaves(block))
    theirs = {path: unit.get("value") for path, unit in leaves(source_block)}
    return bool(ours) and all(
        unit.get("state") == PLACEHOLDER_STATE and theirs.get(path) == unit.get("value") for path, unit in ours
    ) and len(ours) == len(theirs)


def load_placeholder_exemptions(path: str = PLACEHOLDER_EXEMPTIONS_JSON) -> list[str]:
    """Key prefixes another unit is still rewriting: their gaps stay open (counted, not filled)."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return list(json.load(handle).get("prefixes", []))


def is_exempt(key: str, exemptions: list[str]) -> bool:
    return any(key.startswith(prefix) for prefix in exemptions)


def fill_placeholders(catalog: dict, langs: Languages, exemptions: list[str]) -> dict[str, list[str]]:
    """Give every gap of a `pending` language its English placeholder. Returns the filled keys."""
    filled: dict[str, list[str]] = {lang: [] for lang in langs.pending}
    for key, entry in catalog.get("strings", {}).items():
        if not translatable(entry) or is_exempt(key, exemptions):
            continue
        localizations = entry["localizations"]
        source = localizations.get(langs.source)
        if not has_text(source):
            continue
        for lang in langs.pending:
            if not has_text(localizations.get(lang)):
                localizations[lang] = placeholder_from(source)
                filled[lang].append(key)
    return filled
