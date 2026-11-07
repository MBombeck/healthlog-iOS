#!/usr/bin/env python3
"""Record a person's sign-off of the medical texts in one language (R2 3.3, Decision 16).

A medical key (scripts/l10n/medical-keys.json) in any language but German is
written with state `needs_review`, and the freeze pregates
(`check-catalog-format.py --release`) stop while a required language still has
one. This script is the sign-off step: it sets every medical value of the
language that is still `needs_review` to `translated` and appends one line to
scripts/l10n/medical-signoff.json with the name, the date, the number of values
and a fingerprint of exactly the text that was approved.

It is run once a person has read the review sheet of that language (for Dutch:
the review sheet kept with the maintainer), not by a unit.

What it never touches:
  * English placeholders. In a `pending` language a gap carries the English
    text with state `needs_review` (l10n_common.is_placeholder). That is not a
    translation, and signing it off would ship English as approved Dutch. The
    script skips every placeholder, lists it and exits 2: translate first, then
    sign off.
  * Non-medical keys, other languages, values already `translated`.

Usage:
  python3 scripts/l10n/signoff-medical.py --language nl --by "Name" --date 2026-11-20
  python3 scripts/l10n/signoff-medical.py --language nl --by "Name" --date 2026-11-20 --dry-run
  python3 scripts/l10n/signoff-medical.py --self-test
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import sys
import tempfile

sys.dont_write_bytecode = True  # no __pycache__ in the checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import l10n_common as common  # noqa: E402

SIGNOFF_JSON = os.path.join(common.L10N_DIR, "medical-signoff.json")
SIGNOFF_DOC = (
    "One line per medical sign-off (scripts/l10n/signoff-medical.py): who read the "
    "medical texts of a language and when, how many values were set from "
    "`needs_review` to `translated`, and a SHA-256 fingerprint of exactly those "
    "values (catalog, key, variant path and text, sorted). Appended only."
)
REVIEW = "needs_review"


class Result:
    def __init__(self):
        self.signed: list[tuple[str, str, str, str]] = []  # catalog, key, leaf path, value
        self.skipped: list[tuple[str, str]] = []  # placeholders: catalog, key

    @property
    def signed_keys(self) -> int:
        return len({(cat, key) for cat, key, _, _ in self.signed})

    def fingerprint(self) -> str:
        lines = sorted(f"{cat}\t{key}\t{path}\t{value}" for cat, key, path, value in self.signed)
        return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def sign(root: str, catalogs: list[str], langs: common.Languages, medical, language: str, write: bool) -> Result:
    result = Result()
    for relative in catalogs:
        path = os.path.join(root, relative)
        catalog, separator = common.read_catalog(path)
        changed = False
        for key, entry in catalog.get("strings", {}).items():
            if not common.translatable(entry) or not common.is_medical(key, medical):
                continue
            localizations = entry["localizations"]
            block = localizations.get(language)
            if not block:
                continue
            leaves = list(common.leaves(block))
            if not any(unit.get("state") == REVIEW for _, unit in leaves):
                continue
            if language != langs.source and common.is_placeholder(block, localizations.get(langs.source)):
                result.skipped.append((relative, key))
                continue
            for leaf_path, unit in leaves:
                if unit.get("state") == REVIEW:
                    result.signed.append((relative, key, leaf_path, unit.get("value", "")))
                    unit["state"] = "translated"
                    changed = True
        if changed and write:
            common.write_catalog(path, catalog, separator)
    return result


def append_record(path: str, record: dict) -> None:
    data = {"_doc": SIGNOFF_DOC, "signoffs": []}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    data.setdefault("signoffs", []).append(record)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def valid_date(text: str) -> bool:
    try:
        return datetime.date.fromisoformat(text).isoformat() == text
    except ValueError:
        return False


def run(root: str, catalogs: list[str], langs: common.Languages, medical, signoff_path: str,
        language: str, by: str, date: str, dry_run: bool, out=sys.stdout) -> int:
    if language not in langs.all:
        print(f"signoff-medical: `{language}` is not listed in languages.json", file=out)
        return 1
    if not by.strip():
        print("signoff-medical: --by needs the name of the person who read the texts", file=out)
        return 1
    if not valid_date(date):
        print(f"signoff-medical: --date {date!r} is not a date like 2026-11-20", file=out)
        return 1
    result = sign(root, catalogs, langs, medical, language, write=not dry_run)
    for cat, key in result.skipped:
        print(f"  skipped English placeholder: {cat}: {key!r} `{language}` (translate it first)", file=out)
    if dry_run:
        for cat, key, leaf, value in result.signed:
            print(f"  would sign: {cat}: {key!r}{leaf} `{language}`: {value}", file=out)
    if result.signed and not dry_run:
        append_record(signoff_path, {
            "language": language,
            "by": by.strip(),
            "date": date,
            "values": len(result.signed),
            "keys": result.signed_keys,
            "fingerprint": result.fingerprint(),
        })
    verb = "would sign off" if dry_run else "signed off"
    print(f"signoff-medical: {verb} {len(result.signed)} medical value(s) in {result.signed_keys} key(s) of `{language}`"
          f", skipped {len(result.skipped)} placeholder(s).", file=out)
    return 2 if result.skipped else 0


# ---------------------------------------------------------------- self-test
def self_test() -> int:
    langs = common.Languages("en", {"de": "required", "en": "required", "nl": "pending"})
    medical = (["mentalHealth.", "report.adherence."], ["coach.aiGeneratedNote"])

    def unit(value, state="translated"):
        return {"stringUnit": {"state": state, "value": value}}

    app = {
        "sourceLanguage": "en",
        "strings": {
            # own Dutch translation awaiting review: signed
            "mentalHealth.crisis.title": {"localizations": {
                "de": unit("Hilfe"), "en": unit("Help"), "nl": unit("Hulp", REVIEW)}},
            # English placeholder in a pending language: skipped, stays needs_review
            "mentalHealth.crisis.intro": {"localizations": {
                "de": unit("Einleitung"), "en": unit("Intro"), "nl": unit("Intro", REVIEW)}},
            # non-medical key awaiting review: untouched
            "settings.title": {"localizations": {
                "de": unit("Einstellungen"), "en": unit("Settings"), "nl": unit("Instellingen", REVIEW)}},
            # medical, English awaiting review: untouched by a Dutch sign-off
            "coach.aiGeneratedNote": {"localizations": {
                "de": unit("KI"), "en": unit("AI note", REVIEW), "nl": unit("AI-notitie", REVIEW)}},
            # medical, already translated: untouched
            "mentalHealth.back": {"localizations": {
                "de": unit("Zurück"), "en": unit("Back"), "nl": unit("Terug")}},
        },
    }
    report = {
        "sourceLanguage": "en",
        "strings": {
            # plural: every leaf signed
            "report.adherence.days %lld": {"localizations": {
                "de": {"variations": {"plural": {"one": unit("%lld Tag"), "other": unit("%lld Tage")}}},
                "en": {"variations": {"plural": {"one": unit("%lld day"), "other": unit("%lld days")}}},
                "nl": {"variations": {"plural": {"one": unit("%lld dag", REVIEW), "other": unit("%lld dagen", REVIEW)}}}}},
        },
    }
    failures = []

    def check(condition, message):
        if not condition:
            failures.append(message)

    with tempfile.TemporaryDirectory() as tmp:
        catalogs = ["App.xcstrings", "Report.xcstrings"]
        common.write_catalog(os.path.join(tmp, catalogs[0]), app, ": ")
        common.write_catalog(os.path.join(tmp, catalogs[1]), report, " : ")
        report_before = open(os.path.join(tmp, catalogs[1]), encoding="utf-8").read()
        signoff = os.path.join(tmp, "medical-signoff.json")
        sink = open(os.devnull, "w")

        # refusals: unlisted language, missing name, bad date; nothing written
        check(run(tmp, catalogs, langs, medical, signoff, "fr", "Rob", "2026-11-20", False, sink) == 1,
              "an unlisted language was accepted")
        check(run(tmp, catalogs, langs, medical, signoff, "nl", "  ", "2026-11-20", False, sink) == 1,
              "an empty name was accepted")
        check(run(tmp, catalogs, langs, medical, signoff, "nl", "Rob", "20.11.2026", False, sink) == 1,
              "a date that is not ISO was accepted")
        check(not os.path.exists(signoff), "a refused run wrote a sign-off line")

        # dry run: reports, changes nothing
        code = run(tmp, catalogs, langs, medical, signoff, "nl", "Rob", "2026-11-20", True, sink)
        check(code == 2, f"dry run with a placeholder exited {code}, expected 2")
        check(open(os.path.join(tmp, catalogs[1]), encoding="utf-8").read() == report_before, "dry run changed a catalog")
        check(not os.path.exists(signoff), "dry run wrote a sign-off line")

        # the real sign-off
        code = run(tmp, catalogs, langs, medical, signoff, "nl", "Rob de Graaf", "2026-11-20", False, sink)
        check(code == 2, f"sign-off with a placeholder exited {code}, expected 2 (placeholder listed)")
        result_app, _ = common.read_catalog(os.path.join(tmp, catalogs[0]))
        result_report, separator = common.read_catalog(os.path.join(tmp, catalogs[1]))
        s = result_app["strings"]
        check(s["mentalHealth.crisis.title"]["localizations"]["nl"]["stringUnit"]["state"] == "translated",
              "an own medical translation was not signed off")
        check(s["mentalHealth.crisis.intro"]["localizations"]["nl"]["stringUnit"]["state"] == REVIEW,
              "an English placeholder was signed off as Dutch")
        check(s["settings.title"]["localizations"]["nl"]["stringUnit"]["state"] == REVIEW,
              "a non-medical key was signed off")
        check(s["coach.aiGeneratedNote"]["localizations"]["en"]["stringUnit"]["state"] == REVIEW,
              "a Dutch sign-off touched English")
        check(s["coach.aiGeneratedNote"]["localizations"]["nl"]["stringUnit"]["state"] == "translated",
              "a medical key from the `keys` list was not signed off")
        plural = result_report["strings"]["report.adherence.days %lld"]["localizations"]["nl"]["variations"]["plural"]
        check(all(case["stringUnit"]["state"] == "translated" for case in plural.values()),
              "a plural variant stayed needs_review")
        check(separator == " : ", "the catalog lost its separator style")
        check(s["mentalHealth.back"]["localizations"]["nl"]["stringUnit"]["value"] == "Terug", "a translated value changed")
        with open(signoff, encoding="utf-8") as handle:
            records = json.load(handle)["signoffs"]
        check(len(records) == 1, f"expected one sign-off line, found {len(records)}")
        if records:
            record = records[0]
            check((record["language"], record["by"], record["date"]) == ("nl", "Rob de Graaf", "2026-11-20"),
                  f"sign-off line names {record}")
            check((record["values"], record["keys"]) == (4, 3), f"sign-off counted {record['values']} values in {record['keys']} keys")
            expected = Result()
            expected.signed = [
                (catalogs[0], "mentalHealth.crisis.title", "", "Hulp"),
                (catalogs[0], "coach.aiGeneratedNote", "", "AI-notitie"),
                (catalogs[1], "report.adherence.days %lld", "/plural.one", "%lld dag"),
                (catalogs[1], "report.adherence.days %lld", "/plural.other", "%lld dagen"),
            ]
            check(record["fingerprint"] == expected.fingerprint(), "the fingerprint does not cover exactly the signed values")

        # a second run signs nothing and writes no second line
        after = [open(os.path.join(tmp, name), encoding="utf-8").read() for name in catalogs]
        run(tmp, catalogs, langs, medical, signoff, "nl", "Rob de Graaf", "2026-11-21", False, sink)
        check([open(os.path.join(tmp, name), encoding="utf-8").read() for name in catalogs] == after,
              "a second run changed a catalog")
        with open(signoff, encoding="utf-8") as handle:
            check(len(json.load(handle)["signoffs"]) == 1, "a run with nothing to sign wrote a line")

        # English sign-off of a required language: the medical English value
        code = run(tmp, catalogs, langs, medical, signoff, "en", "Alex", "2026-11-21", False, sink)
        result_app, _ = common.read_catalog(os.path.join(tmp, catalogs[0]))
        check(code == 0 and result_app["strings"]["coach.aiGeneratedNote"]["localizations"]["en"]["stringUnit"]["state"]
              == "translated", "an English medical value was not signed off")
        sink.close()

    for failure in failures:
        print(f"  FAIL {failure}")
    print(f"signoff-medical self-test: {'PASS' if not failures else 'FAIL'}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--language")
    parser.add_argument("--by")
    parser.add_argument("--date")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not (args.language and args.by is not None and args.date):
        parser.error("--language, --by and --date are required")
    return run(common.REPO_ROOT, common.CATALOGS, common.load_languages(), common.load_medical_keys(), SIGNOFF_JSON,
               args.language, args.by, args.date, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
