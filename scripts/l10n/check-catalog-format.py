#!/usr/bin/env python3
"""Structural gate for every string catalog the app ships (R2 3.3).

Checks, for every `.xcstrings` file in `common.CATALOGS` (the five target
`Localizable` catalogs, the doctor report's table `DoctorReport.xcstrings`
and the Siri phrase catalog `AppShortcuts.xcstrings`):

  * languages.json is well formed and matches `CFBundleLocalizations` of all
    five targets in project.yml (every shipped language is listed, every
    `required` language ships, all targets agree).
  * Completeness: a key without a value in any listed language fails. A
    `pending` language fills its gaps with English placeholders (the source
    block, every leaf `needs_review`; scripts/l10n/fill-placeholders.py), so
    a Dutch screen never shows a raw key like `settings.foo.title`.
    Placeholders are counted per `pending` language and fail in a `required`
    one. Prefixes in placeholder-exemptions.json (keys another unit is
    rewriting) keep their gaps, counted; a prefix without a gap fails.
  * Format specifiers: every language consumes the same arguments as the source
    language (count, type, position). `%1$@`, `%lld`, `%#@name@` substitutions
    with their `argNum`/`formatSpecifier`, and `%arg` inside them are resolved
    to (argument index, type) before comparing. Plural variants may leave an
    argument out (`one` often says "a day"), but the union over all variants
    must equal the source, and no variant may use an argument the source lacks.
  * Plural categories follow CLDR for the language (de/en/nl: one, other);
    `zero` is allowed as an explicit extra, any other extra or gap fails.
  * No empty value anywhere.
  * App Shortcut phrases (`AppShortcuts.xcstrings`, keys with `${name}`
    tokens): every value carries exactly the tokens of its key, so Siri can
    fill the parameter, and always `${applicationName}`, which Apple requires
    in every phrase of every language.
  * `needs_review` is counted per language; medical keys (medical-keys.json)
    in that state are listed. With --release such a key in a `required`
    language fails (freeze pregates). Every medical prefix and key must match
    a key of one of the catalogs (the `report.` keys live in the doctor
    report's table).

`CatalogFormatSignatureTests` stays as the runtime check; this is the fast one
that runs in the CI step "Lint".

Usage:
  python3 scripts/l10n/check-catalog-format.py [--release]
  python3 scripts/l10n/check-catalog-format.py --self-test
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import tempfile

sys.dont_write_bytecode = True  # no __pycache__ in the checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import l10n_common as common  # noqa: E402

# CLDR cardinal plural categories (CLDR 46). A language missing here fails the
# gate with a hint to add it, rather than being checked against a guess.
CLDR_PLURALS = {
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "cs": {"one", "few", "many", "other"},
    "da": {"one", "other"},
    "de": {"one", "other"},
    "el": {"one", "other"},
    "en": {"one", "other"},
    "es": {"one", "many", "other"},
    "fi": {"one", "other"},
    "fr": {"one", "many", "other"},
    "he": {"one", "two", "other"},
    "hu": {"one", "other"},
    "it": {"one", "many", "other"},
    "ja": {"other"},
    "ko": {"other"},
    "nb": {"one", "other"},
    "nl": {"one", "other"},
    "pl": {"one", "few", "many", "other"},
    "pt": {"one", "many", "other"},
    "ro": {"one", "few", "other"},
    "ru": {"one", "few", "many", "other"},
    "sv": {"one", "other"},
    "tr": {"one", "other"},
    "uk": {"one", "few", "many", "other"},
    "zh-Hans": {"other"},
    "zh-Hant": {"other"},
}
ALWAYS_ALLOWED_PLURAL = {"zero"}

# `%%` and `%#@name@` first, then a printf conversion. The space flag is left
# out on purpose: "66 % today" is prose, not `% t` + `o`.
TOKEN = re.compile(
    r"%%"
    r"|%#@(?P<sub>[A-Za-z0-9_]+)@"
    r"|%arg\b"
    r"|%(?:(?P<pos>\d+)\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<len>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDiuUxXoOfFeEgGaAcCsSp])"
)


def normalized_type(length: str | None, conv: str) -> str:
    conv = "d" if conv == "i" else conv
    return (length or "") + conv


class Signature:
    """Argument index -> type for one string value."""

    def __init__(self):
        self.args: dict[int, str] = {}
        self.clashes: list[str] = []

    def add(self, index: int, kind: str):
        known = self.args.get(index)
        if known is not None and known != kind:
            self.clashes.append(f"argument {index} used as %{known} and %{kind}")
        self.args.setdefault(index, kind)

    def describe(self) -> str:
        return ", ".join(f"{i}:%{t}" for i, t in sorted(self.args.items())) or "none"


def parse(value: str, substitutions: dict, own_arg: tuple[int, str] | None = None) -> Signature:
    signature = Signature()
    sequential = 0
    for match in TOKEN.finditer(value):
        text = match.group(0)
        if text == "%%":
            continue
        if text == "%arg":
            if own_arg:
                signature.add(*own_arg)
            continue
        if match.group("sub"):
            sub = substitutions.get(match.group("sub")) or {}
            sequential += 1
            index = sub.get("argNum", sequential)
            spec = sub.get("formatSpecifier", "@")
            spec_match = re.fullmatch(r"(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp])", spec)
            kind = normalized_type(spec_match.group(1), spec_match.group(2)) if spec_match else spec
            signature.add(int(index), kind)
            continue
        if match.group("pos"):
            index = int(match.group("pos"))
        else:
            sequential += 1
            index = sequential
        signature.add(index, normalized_type(match.group("len"), match.group("conv")))
    return signature


def leaves(node: dict, path: str):
    """Yield (path, stringUnit, plural-variations-dict-or-None) below a localization node."""
    if "stringUnit" in node:
        yield path, node["stringUnit"]
    for kind, cases in (node.get("variations") or {}).items():
        for case, child in cases.items():
            yield from leaves(child, f"{path}/{kind}.{case}")


def plural_sets(node: dict, path: str):
    """Yield (path, set of plural categories) for every plural variation below node."""
    for kind, cases in (node.get("variations") or {}).items():
        if kind == "plural":
            yield path, set(cases)
        for case, child in cases.items():
            yield from plural_sets(child, f"{path}/{kind}.{case}")


def language_signature(block: dict) -> tuple[Signature, list[tuple[str, Signature]], list[str], list[str]]:
    """Union signature, per-leaf signatures, states, and empty-value paths of one language block."""
    substitutions = block.get("substitutions") or {}
    union = Signature()
    per_leaf, states, empties = [], [], []

    def take(path, unit, own_arg=None):
        value = unit.get("value")
        states.append(unit.get("state"))
        if value is None or value == "":
            empties.append(path)
            return
        sig = parse(value, substitutions, own_arg)
        per_leaf.append((path, sig))
        union.clashes.extend(sig.clashes)
        for index, kind in sig.args.items():
            union.add(index, kind)

    for path, unit in leaves(block, ""):
        take(path or "/", unit)
    for name, sub in substitutions.items():
        spec = sub.get("formatSpecifier", "@")
        spec_match = re.fullmatch(r"(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp])", spec)
        kind = normalized_type(spec_match.group(1), spec_match.group(2)) if spec_match else spec
        own = (int(sub.get("argNum", 0)), kind)
        for path, unit in leaves(sub, f"/substitutions.{name}"):
            take(path, unit, own)
    return union, per_leaf, states, empties


def plural_problems(lang: str, block: dict) -> list[str]:
    required = CLDR_PLURALS.get(lang)
    if required is None:
        return [f"no CLDR plural table for `{lang}`, add it to CLDR_PLURALS in check-catalog-format.py"]
    problems = []
    nodes = [("", block)] + [
        (f"/substitutions.{name}", sub) for name, sub in (block.get("substitutions") or {}).items()
    ]
    for base, node in nodes:
        for path, cats in plural_sets(node, base):
            missing = required - cats
            extra = cats - required - ALWAYS_ALLOWED_PLURAL
            if missing:
                problems.append(f"{path or '/'}: plural lacks {sorted(missing)} (CLDR for `{lang}`)")
            if extra:
                problems.append(f"{path or '/'}: plural has {sorted(extra)}, not a CLDR category for `{lang}`")
    return problems


class Report:
    def __init__(self):
        self.errors: list[str] = []
        self.pending_gaps: dict[str, int] = {}
        self.placeholders: dict[str, int] = {}
        self.needs_review: dict[str, int] = {}
        self.medical_review: list[str] = []
        self.keys = 0

    def error(self, text: str):
        self.errors.append(text)


def check_languages(langs: common.Languages, project_yml: str, report: Report):
    for lang in langs.all:
        if lang not in CLDR_PLURALS:
            report.error(f"languages.json: no CLDR plural table for `{lang}` in check-catalog-format.py")
    lists = common.bundle_localizations(project_yml)
    if len(lists) != 5:
        report.error(f"project.yml: expected 5 CFBundleLocalizations lists (five targets), found {len(lists)}")
    for number, items in enumerate(lists, 1):
        unlisted = sorted(set(items) - set(langs.all))
        unshipped = sorted(set(langs.required) - set(items))
        if unlisted:
            report.error(f"project.yml CFBundleLocalizations #{number}: {unlisted} not in languages.json")
        if unshipped:
            report.error(f"project.yml CFBundleLocalizations #{number}: required {unshipped} missing")
    if lists and any(sorted(items) != sorted(lists[0]) for items in lists):
        report.error(f"project.yml: the five targets disagree on CFBundleLocalizations: {lists}")


def check_catalog(name: str, catalog: dict, langs: common.Languages, medical, report: Report,
                  exemptions: list[str] = (), exempt_gaps: set[str] | None = None):
    if catalog.get("sourceLanguage") != langs.source:
        report.error(f"{name}: sourceLanguage {catalog.get('sourceLanguage')!r}, languages.json says {langs.source!r}")
    for key, entry in catalog.get("strings", {}).items():
        report.keys += 1
        if not common.translatable(entry):
            continue
        localizations = entry["localizations"]
        for lang in localizations:
            if lang not in langs.status:
                report.error(f"{name}: {key!r} has `{lang}`, which languages.json does not list")
        source_block = localizations.get(langs.source)
        source_sig = language_signature(source_block)[0] if source_block else None
        for lang in langs.all:
            block = localizations.get(lang)
            if not common.has_text(block):
                if langs.status[lang] == "required":
                    report.error(f"{name}: {key!r} has no `{lang}` value (required)")
                elif common.is_exempt(key, exemptions):
                    report.pending_gaps[lang] = report.pending_gaps.get(lang, 0) + 1
                    if exempt_gaps is not None:
                        exempt_gaps.add(key)
                else:
                    report.error(
                        f"{name}: {key!r} has no `{lang}` value; a pending language needs the English placeholder "
                        "(python3 scripts/l10n/fill-placeholders.py)"
                    )
                continue
            if lang != langs.source and common.is_placeholder(block, source_block):
                report.placeholders[lang] = report.placeholders.get(lang, 0) + 1
                if langs.status[lang] == "required":
                    report.error(f"{name}: {key!r} `{lang}` is still the English placeholder (required)")
            union, per_leaf, states, empties = language_signature(block)
            for path in empties:
                report.error(f"{name}: {key!r} `{lang}` {path}: empty value")
            for clash in union.clashes:
                report.error(f"{name}: {key!r} `{lang}`: {clash}")
            for problem in plural_problems(lang, block):
                report.error(f"{name}: {key!r} `{lang}` {problem}")
            review = states.count("needs_review")
            if review:
                report.needs_review[lang] = report.needs_review.get(lang, 0) + 1
                if medical and common.is_medical(key, medical):
                    report.medical_review.append(f"{name}: {key!r} `{lang}` ({langs.status[lang]})")
            for path, value in phrase_leaves(key, block):
                report.error(f"{name}: {key!r} `{lang}` {path}: {value}")
            if source_sig is None or lang == langs.source:
                continue
            if union.args != source_sig.args:
                report.error(
                    f"{name}: {key!r} `{lang}` uses [{union.describe()}], source `{langs.source}` uses [{source_sig.describe()}]"
                )
                continue
            for path, sig in per_leaf:
                stray = {i: t for i, t in sig.args.items() if source_sig.args.get(i) != t}
                if stray:
                    report.error(f"{name}: {key!r} `{lang}` {path}: arguments {stray} not in the source")


PHRASE_TOKEN = re.compile(r"\$\{(\w+)\}")


def phrase_leaves(key: str, block: dict):
    """Token problems of an App Shortcut phrase: `${…}` tokens must match the key's."""
    expected = sorted(PHRASE_TOKEN.findall(key))
    if not expected:
        return
    for path, unit in leaves(block, ""):
        value = unit.get("value") or ""
        tokens = sorted(PHRASE_TOKEN.findall(value))
        if tokens != expected:
            yield path or "value", f"phrase tokens {tokens}, the key has {expected}"
        elif "applicationName" not in tokens:
            yield path or "value", "a phrase without ${applicationName} is never registered"


def check_medical_list(medical, catalogs: list[dict], report: Report):
    prefixes, keys = medical
    strings = {key for catalog in catalogs for key in catalog.get("strings", {})}
    for prefix in prefixes:
        if not any(key.startswith(prefix) for key in strings):
            report.error(f"medical-keys.json: prefix {prefix!r} matches no key of any catalog")
    for key in keys:
        if key not in strings:
            report.error(f"medical-keys.json: key {key!r} is in no catalog")


def run(root: str, languages_path: str, medical_path: str, catalogs: list[str], release: bool,
        exemptions_path: str | None = None) -> tuple[int, Report]:
    report = Report()
    langs = common.load_languages(languages_path)
    medical = common.load_medical_keys(medical_path)
    exemptions = common.load_placeholder_exemptions(exemptions_path or common.PLACEHOLDER_EXEMPTIONS_JSON)
    exempt_gaps: set[str] = set()
    check_languages(langs, os.path.join(root, "project.yml"), report)
    loaded = {}
    for relative in catalogs:
        path = os.path.join(root, relative)
        if not os.path.exists(path):
            report.error(f"{relative}: catalog missing")
            continue
        catalog, _ = common.read_catalog(path)
        loaded[relative] = catalog
        check_catalog(relative, catalog, langs, medical, report, exemptions, exempt_gaps)
    for prefix in exemptions:
        if not any(key.startswith(prefix) for key in exempt_gaps):
            report.error(f"placeholder-exemptions.json: {prefix!r} has no open gap any more, delete the entry")
    if loaded:
        check_medical_list(medical, list(loaded.values()), report)
    if release:
        for line in report.medical_review:
            if "(required)" in line:
                report.error(f"medical key awaits review in a required language: {line}")
    return (1 if report.errors else 0), report


def print_report(report: Report, langs_path: str, release: bool):
    langs = common.load_languages(langs_path)
    for error in report.errors[:200]:
        print(f"  {error}")
    if len(report.errors) > 200:
        print(f"  ... and {len(report.errors) - 200} more")
    for lang in langs.pending:
        print(f"pending `{lang}`: {report.placeholders.get(lang, 0)} English placeholder(s), "
              f"{report.pending_gaps.get(lang, 0)} exempt gap(s) without a value")
    for lang in langs.all:
        print(f"needs_review `{lang}`: {report.needs_review.get(lang, 0)} key(s)")
    if report.medical_review:
        print(f"medical keys awaiting review: {len(report.medical_review)}" + ("" if release else " (report only; --release fails on required languages)"))
        for line in report.medical_review[:50]:
            print(f"  {line}")
    status = "FAILED" if report.errors else "OK"
    print(f"check-catalog-format: {status}, {report.keys} keys in the catalogs, {len(report.errors)} finding(s).")


# ---------------------------------------------------------------- self-test
def _unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def _plural(cases, state="translated"):
    return {"variations": {"plural": {case: _unit(value, state) for case, value in cases.items()}}}


def self_test() -> int:
    base_catalog = {
        "sourceLanguage": "en",
        "strings": {
            "plain": {"localizations": {"de": _unit("Hallo"), "en": _unit("Hello")}},
            "fmt %@ %lld": {"localizations": {"de": _unit("%2$lld mal %1$@"), "en": _unit("%1$@ %2$lld times")}},
            "%lld entries": {"localizations": {
                "de": _plural({"one": "Ein Eintrag", "other": "%lld Einträge"}),
                "en": _plural({"one": "%lld entry", "other": "%lld entries"}),
            }},
            "sub": {"localizations": {
                lang: {
                    "stringUnit": {"state": "translated", "value": f"%1$@: %#@days@ {word}"},
                    "substitutions": {"days": {"argNum": 2, "formatSpecifier": "lld", **_plural({"one": "%arg d", "other": "%arg d"})}},
                } for lang, word in (("de", "her"), ("en", "ago"))
            }},
            "mentalHealth.disclaimer": {"localizations": {"de": _unit("Kein Befund"), "en": _unit("Not a diagnosis")}},
            "percent": {"localizations": {"de": _unit("66 % heute"), "en": _unit("66% today")}},
            "Log ${kind} in ${applicationName}": {"localizations": {
                "de": _unit("Erfasse ${kind} in ${applicationName}"),
                "en": _unit("Log ${kind} in ${applicationName}"),
            }},
        },
        "version": "1.0",
    }
    project = "targets:\n" + "".join(
        f"  t{i}:\n    info:\n      properties:\n        CFBundleLocalizations:\n          - de\n          - en\n        Other: x\n" for i in range(5)
    )
    cases = []

    def case(name, expect_fail, mutate=None, languages=None, project_text=None, medical=None, release=False,
             exemptions=(), second=None):
        cases.append((name, expect_fail, mutate, languages, project_text, medical, release, exemptions, second))

    loc = lambda c, key: c["strings"][key]["localizations"]  # noqa: E731

    case("clean catalogs pass", False)
    case("missing value in a required language fails", True, lambda c: loc(c, "plain").pop("de"))
    pending_nl = {"de": "required", "en": "required", "nl": "pending"}

    def with_placeholders(c):
        for entry in c["strings"].values():
            entry["localizations"]["nl"] = common.placeholder_from(entry["localizations"]["en"])

    case("missing value in a pending language fails (raw key on screen)", True,
         lambda c: loc(c, "plain").update(nl=_unit("Hallo")) or None, languages=pending_nl)
    case("English placeholders in a pending language are counted", False, with_placeholders, languages=pending_nl)
    case("an English placeholder in a required language fails", True,
         lambda c: loc(c, "plain").update(de=common.placeholder_from(loc(c, "plain")["en"])))
    case("a translated value equal to English is no placeholder", False,
         lambda c: with_placeholders(c) or loc(c, "plain").update(nl=_unit("Hello")), languages=pending_nl)
    case("an exempt prefix keeps its gaps, counted", False,
         lambda c: with_placeholders(c) or loc(c, "mentalHealth.disclaimer").pop("nl"), languages=pending_nl,
         exemptions=["mentalHealth."])
    case("an exempt prefix without a gap fails", True, with_placeholders, languages=pending_nl,
         exemptions=["mentalHealth."])
    case("wrong specifier type fails", True, lambda c: loc(c, "fmt %@ %lld").update(de=_unit("%2$@ mal %1$@")))
    case("dropped argument fails", True, lambda c: loc(c, "fmt %@ %lld").update(de=_unit("%1$@ mal")))
    case("stray argument fails", True, lambda c: loc(c, "plain").update(de=_unit("Hallo %@")))
    case("swapped positional arguments pass", False, lambda c: loc(c, "fmt %@ %lld").update(de=_unit("%2$lld, %1$@")))
    case("missing plural category fails", True, lambda c: loc(c, "%lld entries")["de"]["variations"]["plural"].pop("other"))
    case("non-CLDR plural category fails", True, lambda c: loc(c, "%lld entries")["de"]["variations"]["plural"].update(few=_unit("%lld x")))
    case("explicit zero category passes", False, lambda c: loc(c, "%lld entries")["de"]["variations"]["plural"].update(zero=_unit("Keine")))
    case("missing CLDR category in a pending pl plural fails", True,
         lambda c: loc(c, "%lld entries").update(pl=_plural({"one": "%lld wpis", "other": "%lld wpisów"})),
         languages={"de": "required", "en": "required", "pl": "pending"})
    case("substitution type mismatch fails", True,
         lambda c: loc(c, "sub")["de"]["substitutions"]["days"].update(formatSpecifier="@"))
    case("empty value fails", True, lambda c: loc(c, "plain").update(de=_unit("")))
    case("empty plural variant fails", True, lambda c: loc(c, "%lld entries")["de"]["variations"]["plural"].update(one=_unit("")))
    case("language outside languages.json fails", True, lambda c: loc(c, "plain").update(fr=_unit("Bonjour")))
    case("medical needs_review in required is reported without --release", False,
         lambda c: loc(c, "mentalHealth.disclaimer").update(en=_unit("Not a diagnosis", "needs_review")))
    case("medical needs_review in required fails with --release", True,
         lambda c: loc(c, "mentalHealth.disclaimer").update(en=_unit("Not a diagnosis", "needs_review")), release=True)
    case("medical needs_review in pending passes with --release", False,
         lambda c: with_placeholders(c) or loc(c, "mentalHealth.disclaimer").update(nl=_unit("Geen diagnose", "needs_review")),
         languages=pending_nl, release=True)
    case("non-medical needs_review passes with --release", False,
         lambda c: loc(c, "plain").update(en=_unit("Hello", "needs_review")), release=True)
    case("required language missing from a target fails", True,
         project_text=project.replace("          - de\n          - en\n        Other", "          - en\n        Other", 1))
    case("shipped language missing from languages.json fails", True,
         project_text=project.replace("          - en\n", "          - en\n          - fr\n"))
    case("only four CFBundleLocalizations lists fails", True, project_text=project.split("  t4:")[0])
    case("medical prefix matching nothing fails", True, medical={"prefixes": ["nothing.here."], "keys": []})
    phrase = "Log ${kind} in ${applicationName}"
    case("reordered phrase tokens pass", False,
         lambda c: loc(c, phrase).update(de=_unit("${kind} in ${applicationName} erfassen")))
    case("a phrase that drops ${applicationName} fails", True,
         lambda c: loc(c, phrase).update(de=_unit("Erfasse ${kind} in HealthLog")))
    case("a phrase that drops a parameter token fails", True,
         lambda c: loc(c, phrase).update(de=_unit("Erfasse etwas in ${applicationName}")))
    case("a phrase with a renamed token fails", True,
         lambda c: loc(c, phrase).update(de=_unit("Erfasse ${art} in ${applicationName}")))
    case("sourceLanguage mismatch fails", True, lambda c: c.update(sourceLanguage="de"))
    report_table = {"sourceLanguage": "en", "version": "1.0", "strings": {
        "report.disclaimer": {"localizations": {"de": _unit("Kein Befund"), "en": _unit("Not a medical document")}},
    }}
    case("medical prefix matching a key of a second catalog passes", False, second=report_table,
         medical={"prefixes": ["mentalHealth.", "report."], "keys": []})
    case("a gap in a second catalog fails", True, second={**report_table, "strings": {
        "report.disclaimer": {"localizations": {"de": _unit("Kein Befund")}}}})
    case("a pending language without its value in a second catalog fails", True, with_placeholders,
         languages=pending_nl, second=report_table)

    failures = 0
    for name, expect_fail, mutate, languages, project_text, medical, release, exemptions, second in cases:
        with tempfile.TemporaryDirectory() as tmp:
            catalog = copy.deepcopy(base_catalog)
            if mutate:
                mutate(catalog)
            with open(os.path.join(tmp, "Localizable.xcstrings"), "w", encoding="utf-8") as handle:
                handle.write(common.dumps_catalog(catalog))
            with open(os.path.join(tmp, "project.yml"), "w", encoding="utf-8") as handle:
                handle.write(project_text or project)
            with open(os.path.join(tmp, "languages.json"), "w", encoding="utf-8") as handle:
                json.dump({"sourceLanguage": "en", "languages": languages or {"de": "required", "en": "required"}}, handle)
            with open(os.path.join(tmp, "medical.json"), "w", encoding="utf-8") as handle:
                json.dump(medical or {"prefixes": ["mentalHealth."], "keys": []}, handle)
            with open(os.path.join(tmp, "exemptions.json"), "w", encoding="utf-8") as handle:
                json.dump({"prefixes": list(exemptions)}, handle)
            names = ["Localizable.xcstrings"]
            if second is not None:
                with open(os.path.join(tmp, "DoctorReport.xcstrings"), "w", encoding="utf-8") as handle:
                    handle.write(common.dumps_catalog(second))
                names.append("DoctorReport.xcstrings")
            code, report = run(tmp, os.path.join(tmp, "languages.json"), os.path.join(tmp, "medical.json"),
                               names, release, os.path.join(tmp, "exemptions.json"))
            ok = (code != 0) == expect_fail
            if name.startswith("English placeholders in a pending") and ok:
                ok = report.placeholders.get("nl") == 7
            if name.startswith("a translated value equal") and ok:
                ok = report.placeholders.get("nl") == 6
            if name.startswith("an exempt prefix keeps") and ok:
                ok = report.pending_gaps.get("nl") == 1 and report.placeholders.get("nl") == 6
            if name.endswith("reported without --release") and ok:
                ok = len(report.medical_review) == 1 and report.needs_review.get("en") == 1
            print(f"  {'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f" (exit {code}, {report.errors[:3]})"))
            failures += 0 if ok else 1
    print(f"check-catalog-format self-test: {'PASS' if not failures else 'FAIL'} ({len(cases) - failures}/{len(cases)})")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--release", action="store_true", help="fail on medical keys awaiting review in a required language")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    code, report = run(common.REPO_ROOT, common.LANGUAGES_JSON, common.MEDICAL_KEYS_JSON, common.CATALOGS, args.release)
    print_report(report, common.LANGUAGES_JSON, args.release)
    return code


if __name__ == "__main__":
    sys.exit(main())
