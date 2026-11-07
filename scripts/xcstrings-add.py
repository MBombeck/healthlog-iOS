#!/usr/bin/env python3
"""Add keys to Localizable.xcstrings without touching existing values.

Usage: scripts/xcstrings-add.py <strings.json> [--catalog HealthLog/Resources/Localizable.xcstrings]

<strings.json>: {"<key>": {"en": "...", "de": "...", "comment": "..."}, ...}
Existing keys keep every value they already have; only absent locales are filled.
The languages come from scripts/l10n/languages.json: a key that ends up without
a value in a `required` language aborts the run before anything is written; a
gap in a `pending` language gets the English placeholder (the `en` block, every
leaf `needs_review`, see scripts/l10n/l10n_common.py), so the screen never shows
a raw key while the language waits for its translation pass; prefixes in
scripts/l10n/placeholder-exemptions.json keep the gap. A language the list does not know
is an error (typo guard). Keys listed in scripts/l10n/medical-keys.json get
`state: needs_review` in every language but German, so a person approves them.
Output matches Xcode's serialization: 2-space indent, the file's own key/value
separator (": " or " : "), no trailing whitespace, original key order preserved
(new keys appended at the end of "strings"), one trailing newline. Do not sort
keys — Xcode's own ordering does not match a plain codepoint sort, and
round-tripping the file unsorted is what keeps an empty add a true no-op.
"""
import argparse
import json
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the checkout
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "l10n"))
import l10n_common as common  # noqa: E402

REVIEW_EXEMPT = "de"  # medical texts are written and approved in German first


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("strings_json")
    ap.add_argument("--catalog", default="HealthLog/Resources/Localizable.xcstrings")
    ap.add_argument("--languages", default=common.LANGUAGES_JSON)
    ap.add_argument("--medical-keys", default=common.MEDICAL_KEYS_JSON)
    a = ap.parse_args()

    langs = common.load_languages(a.languages)
    medical = common.load_medical_keys(a.medical_keys)
    with open(a.strings_json, encoding="utf-8") as f:
        add = json.load(f)
    cat, separator = common.read_catalog(a.catalog)

    unknown = sorted({lang for spec in add.values() for lang in spec if lang != "comment" and lang not in langs.status})
    if unknown:
        print(f"xcstrings-add: {unknown} not in scripts/l10n/languages.json, nothing written", file=sys.stderr)
        return 1

    strings = cat.setdefault("strings", {})
    exemptions = common.load_placeholder_exemptions(
        os.path.join(os.path.dirname(os.path.abspath(a.languages)), "placeholder-exemptions.json")
    )
    added = filled = review = 0
    placeholders = {lang: 0 for lang in langs.pending}
    gaps = {lang: [] for lang in langs.all}
    for key, spec in add.items():
        entry = strings.get(key)
        if entry is None:
            entry = {}
            if spec.get("comment"):
                entry["comment"] = spec["comment"]
            entry["extractionState"] = "manual"
            entry["localizations"] = {}
            strings[key] = entry
            added += 1
        locs = entry.setdefault("localizations", {})
        for lang in langs.all:
            if lang in spec and lang not in locs:
                state = "translated"
                if lang != REVIEW_EXEMPT and common.is_medical(key, medical):
                    state = "needs_review"
                    review += 1
                locs[lang] = {"stringUnit": {"state": state, "value": spec[lang]}}
                filled += 1
        for lang in langs.all:
            if (
                langs.status[lang] == "pending"
                and not common.has_text(locs.get(lang))
                and common.has_text(locs.get(langs.source))
                and not common.is_exempt(key, exemptions)
            ):
                locs[lang] = common.placeholder_from(locs[langs.source])
                placeholders[lang] += 1
            if not common.has_text(locs.get(lang)):
                gaps[lang].append(key)

    missing_required = {lang: keys for lang, keys in gaps.items() if keys and langs.status[lang] == "required"}
    if missing_required:
        for lang, keys in missing_required.items():
            print(f"xcstrings-add: {len(keys)} key(s) without `{lang}` (required): {keys[:10]}", file=sys.stderr)
        print("xcstrings-add: nothing written", file=sys.stderr)
        return 1

    common.write_catalog(a.catalog, cat, separator)
    summary = f"xcstrings-add: {added} keys added, {filled} locale values filled"
    if review:
        summary += f", {review} medical value(s) marked needs_review"
    for lang in langs.pending:
        summary += f", {placeholders[lang]} English placeholder(s) for pending `{lang}`"
        if gaps[lang]:
            summary += f", {len(gaps[lang])} without pending `{lang}`"
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
