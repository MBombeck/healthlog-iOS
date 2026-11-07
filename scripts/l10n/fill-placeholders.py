#!/usr/bin/env python3
"""Give every gap of a `pending` language its English placeholder.

A language ships in CFBundleLocalizations while it is still `pending`
(scripts/l10n/languages.json). A key without a value in it would show the raw
key on screen (`settings.foo.title`): the bundle looks the key up in that
language's table and does not fall back to English. This fills each such gap
in all five catalogs with the source-language block, every leaf in state
`needs_review`, so the screen reads English until the translation pass
replaces it. check-catalog-format.py counts the placeholders and fails on any
left in a `required` language. Keys under a prefix in
placeholder-exemptions.json are left alone.

Idempotent: a second run changes nothing. Run it after merging a branch that
added keys without the pending languages (scripts/xcstrings-add.py fills them
itself).

Usage:
  python3 scripts/l10n/fill-placeholders.py
  python3 scripts/l10n/fill-placeholders.py --self-test
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile

sys.dont_write_bytecode = True  # no __pycache__ in the checkout
import l10n_common as common  # noqa: E402


def fill(root: str, langs: common.Languages, exemptions: list[str], catalogs: list[str]) -> dict[str, int]:
    totals = {lang: 0 for lang in langs.pending}
    for relative in catalogs:
        path = os.path.join(root, relative)
        catalog, separator = common.read_catalog(path)
        filled = common.fill_placeholders(catalog, langs, exemptions)
        if any(filled.values()):
            common.write_catalog(path, catalog, separator)
        for lang, keys in filled.items():
            totals[lang] += len(keys)
    return totals


def self_test() -> int:
    langs = common.Languages("en", {"de": "required", "en": "required", "nl": "pending"})
    catalog = {
        "sourceLanguage": "en",
        "strings": {
            "a.title": {"localizations": {"de": {"stringUnit": {"state": "translated", "value": "Titel"}},
                                          "en": {"stringUnit": {"state": "translated", "value": "Title"}}}},
            "%lld days": {"localizations": {"en": {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": "%lld day"}},
                "other": {"stringUnit": {"state": "translated", "value": "%lld days"}}}}}}},
            "done.title": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Done"}},
                                             "nl": {"stringUnit": {"state": "translated", "value": "Klaar"}}}},
            "skip.me": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Skip"}}}},
        },
    }
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "Localizable.xcstrings")
        common.write_catalog(path, catalog, ": ")
        first = fill(tmp, langs, ["skip."], ["Localizable.xcstrings"])
        after_first = open(path, encoding="utf-8").read()
        second = fill(tmp, langs, ["skip."], ["Localizable.xcstrings"])
        result, _ = common.read_catalog(path)
        strings = result["strings"]
        if first != {"nl": 2}:
            failures.append(f"first run filled {first}, expected 2 nl")
        if second != {"nl": 0} or open(path, encoding="utf-8").read() != after_first:
            failures.append("second run was not a no-op")
        nl = strings["a.title"]["localizations"].get("nl", {})
        if nl.get("stringUnit") != {"state": "needs_review", "value": "Title"}:
            failures.append(f"a.title nl is {nl}")
        if not common.is_placeholder(strings["%lld days"]["localizations"]["nl"], strings["%lld days"]["localizations"]["en"]):
            failures.append("plural placeholder not recognised")
        if strings["done.title"]["localizations"]["nl"]["stringUnit"]["value"] != "Klaar":
            failures.append("an existing nl value was touched")
        if "nl" in strings["skip.me"]["localizations"]:
            failures.append("an exempt key was filled")
        if "de" in strings["%lld days"]["localizations"]:
            failures.append("a required language was filled")
    for failure in failures:
        print(f"  FAIL {failure}")
    print(f"fill-placeholders self-test: {'PASS' if not failures else 'FAIL'}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    langs = common.load_languages()
    totals = fill(common.REPO_ROOT, langs, common.load_placeholder_exemptions(), common.CATALOGS)
    print("fill-placeholders: " + ", ".join(f"{count} `{lang}` placeholder(s) added" for lang, count in totals.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
