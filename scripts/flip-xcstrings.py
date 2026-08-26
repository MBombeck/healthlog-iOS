#!/usr/bin/env python3
"""Flip Localizable.xcstrings source language German -> English.

Re-roots the string catalogue so the English value becomes the key (matching
SwiftUI's literal-derived keys) and the former German key text moves into a
`de` translation unit. Dotted-ID keys (e.g. `dashboard.complianceRing.hint`)
are immune and pass through untouched.

The transform is reversible: it emits a `de->en` map and the inverse so the
literal codemod (scripts/flip-literals.py) rewrites code in lock-step and a
rollback flip can be produced from the same data.

Usage:
    flip-xcstrings.py flip   --in CAT --out CAT [--map MAP.json] [--collisions TABLE.json]
    flip-xcstrings.py audit  --in CAT [--collisions TABLE.json]
    flip-xcstrings.py verify --in CAT --map MAP.json   # post-flip sanity

A key is a *flip target* iff: not a dotted ID AND its `de` value equals the key
(i.e. the literal in code is the German source string). Everything else
(dotted IDs, keys whose source is already English, number/symbol keys) is
passed through with key unchanged.

Collisions: several German keys can share one English value (e.g. Speichern +
Sichern -> Save). Merging them is usually desirable de-duplication, but it is
NEVER done silently. The collision table records, per English value, the
canonical German source + comment to keep and the surplus keys being merged.
If a collision is found that the table does not cover, `flip` aborts.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict

DOTTED = re.compile(r"^[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9_]+)+$")


def is_dotted_id(key: str) -> bool:
    """Dotted key-IDs are flip-immune: key stays, langs are pure translations."""
    return bool(DOTTED.match(key)) and " " not in key


def unit_value(entry: dict, lang: str):
    return (
        entry.get("localizations", {})
        .get(lang, {})
        .get("stringUnit", {})
        .get("value")
    )


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def dump(cat: dict, path: str) -> None:
    cat["strings"] = {k: cat["strings"][k] for k in sorted(cat["strings"])}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(cat, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def classify(cat: dict):
    """Return (flip_targets, passthrough_keys).

    flip_targets maps German-source-key -> English value (the new key).
    """
    flip_targets: dict[str, str] = {}
    passthrough: list[str] = []
    for key, entry in cat["strings"].items():
        de = unit_value(entry, "de")
        en = unit_value(entry, "en")
        if is_dotted_id(key):
            passthrough.append(key)
        elif de is not None and key == de and en is not None and en != key:
            flip_targets[key] = en
        else:
            # key already English, number/symbol, or de==en: source unchanged
            passthrough.append(key)
    return flip_targets, passthrough


def detect_collisions(flip_targets: dict[str, str], passthrough: list[str] | None = None):
    """Group German keys by the English value they flip to.

    A collision is any English value claimed by >1 German flip target OR by a
    flip target plus an already-existing passthrough key with the same name
    (the cross-class case, e.g. German `Kontext` flips onto already-English key
    `Context`). Both must be resolved via the collision table.
    """
    pset = set(passthrough or [])
    by_en: dict[str, list[str]] = defaultdict(list)
    for de_key, en_val in flip_targets.items():
        by_en[en_val].append(de_key)
    collisions = {}
    for en, keys in by_en.items():
        if len(keys) > 1 or en in pset:
            collisions[en] = keys
    return collisions


def richest_comment(*comments: str) -> str:
    """Pick the most informative comment among colliding entries."""
    present = [c for c in comments if c]
    if not present:
        return ""
    return max(present, key=len)


def collision_drop(en_val: str, de_keys: list[str], passthrough_set: set[str]) -> int:
    """How many keys disappear when this collision merges into one English key.

    de_keys collapse to 1 (drop len-1); if an English passthrough key with the
    same name already exists it is also absorbed (drop 1 more).
    """
    drop = len(de_keys) - 1
    if en_val in passthrough_set:
        drop += 1
    return drop


def cmd_audit(args) -> int:
    cat = load(args.in_path)
    flip_targets, passthrough = classify(cat)
    pset = set(passthrough)
    collisions = detect_collisions(flip_targets, passthrough)
    surplus = sum(collision_drop(en, ks, pset) for en, ks in collisions.items())
    print(f"sourceLanguage: {cat['sourceLanguage']}")
    print(f"total keys:        {len(cat['strings'])}")
    print(f"flip targets:      {len(flip_targets)}")
    print(f"passthrough keys:  {len(passthrough)}")
    print(f"colliding en vals: {len(collisions)}")
    print(f"surplus keys:      {surplus}")
    print(f"keys after flip:   {len(cat['strings']) - surplus}")
    if args.collisions:
        table = _auto_collision_table(cat, flip_targets, collisions, passthrough)
        with open(args.collisions, "w", encoding="utf-8") as fh:
            json.dump(table, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print(f"wrote starter collision table -> {args.collisions}")
    return 0


def _auto_collision_table(cat, flip_targets, collisions, passthrough) -> dict:
    """Build a starter collision table; hand-review before flipping at scale."""
    pset = set(passthrough)
    table = {}
    for en_val, de_keys in sorted(collisions.items()):
        de_keys_sorted = sorted(de_keys)
        canonical = de_keys_sorted[0]
        comments = [cat["strings"][k].get("comment", "") for k in de_keys_sorted]
        de_values = {
            k: unit_value(cat["strings"][k], "de") for k in de_keys_sorted
        }
        existing_en = en_val in pset
        if existing_en:
            comments.append(cat["strings"][en_val].get("comment", ""))
        table[en_val] = {
            "canonical_de_key": canonical,
            "canonical_de_value": de_values[canonical],
            "comment": richest_comment(*comments),
            "merged_keys": de_keys_sorted,
            "de_values": de_values,
            # True when an already-English key of this name exists and is absorbed.
            "absorbs_existing_en_key": existing_en,
        }
    return table


def cmd_flip(args) -> int:
    cat = load(args.in_path)
    if cat["sourceLanguage"] != "de":
        print(f"refusing: sourceLanguage is {cat['sourceLanguage']!r}, expected 'de'", file=sys.stderr)
        return 2

    flip_targets, passthrough = classify(cat)
    pset = set(passthrough)
    collisions = detect_collisions(flip_targets, passthrough)

    table = {}
    if args.collisions:
        try:
            table = load(args.collisions)
        except FileNotFoundError:
            table = {}
    # Every collision MUST be covered by the table -- never silent last-write-wins.
    uncovered = [en for en in collisions if en not in table]
    if uncovered:
        print("ABORT: collisions not in resolution table:", file=sys.stderr)
        for en in uncovered:
            print(f"  {en!r} <- {collisions[en]}", file=sys.stderr)
        print("Run `audit --collisions TABLE.json` to seed the table, hand-review, retry.", file=sys.stderr)
        return 3

    old_strings = cat["strings"]
    total_in = len(old_strings)
    new_strings: dict[str, dict] = {}
    fwd_map: dict[str, str] = {}  # old German key -> new English key

    # English passthrough keys absorbed by a cross-class collision must not be
    # emitted twice; track them so the verbatim copy below skips them.
    absorbed_en_keys = {en for en in collisions if en in pset}

    # 1) passthrough keys keep their key verbatim (except absorbed ones)
    for key in passthrough:
        if key in absorbed_en_keys:
            continue
        new_strings[key] = old_strings[key]
        # dotted IDs / already-en: language units unchanged; only sourceLanguage flips role

    # 2) flip targets: new key = English value; German text -> de unit
    consumed_by_collision: set[str] = set()
    for en_val, de_keys in collisions.items():
        resolution = table[en_val]
        canonical_key = resolution["canonical_de_key"]
        canonical_de = resolution.get("canonical_de_value") or unit_value(
            old_strings[canonical_key], "de"
        )
        merge_comments = [old_strings[k].get("comment", "") for k in de_keys]
        if en_val in pset:
            merge_comments.append(old_strings[en_val].get("comment", ""))
        comment = resolution.get("comment") or richest_comment(*merge_comments)
        merged_entry = _build_flipped_entry(en_val, canonical_de, comment, old_strings[canonical_key])
        new_strings[en_val] = merged_entry
        for k in de_keys:
            consumed_by_collision.add(k)
            fwd_map[k] = en_val

    for de_key, en_val in flip_targets.items():
        if de_key in consumed_by_collision:
            continue
        entry = old_strings[de_key]
        de_text = unit_value(entry, "de")
        new_strings[en_val] = _build_flipped_entry(
            en_val, de_text, entry.get("comment", ""), entry
        )
        fwd_map[de_key] = en_val

    cat["strings"] = new_strings
    cat["sourceLanguage"] = "en"

    surplus = sum(collision_drop(en, ks, pset) for en, ks in collisions.items())
    expected = total_in - surplus
    if len(new_strings) != expected:
        print(
            f"ABORT count mismatch: got {len(new_strings)} keys, expected {expected}",
            file=sys.stderr,
        )
        return 4

    dump(cat, args.out_path)
    if args.map_path:
        inverse = {v: k for k, v in fwd_map.items()}
        with open(args.map_path, "w", encoding="utf-8") as fh:
            json.dump(
                {"forward_de_to_en": fwd_map, "inverse_en_to_de": inverse},
                fh,
                ensure_ascii=False,
                indent=2,
            )
            fh.write("\n")
    print(f"flipped {len(flip_targets)} keys; {len(passthrough)} passthrough; "
          f"{surplus} merged; {len(new_strings)} keys out -> {args.out_path}")
    if args.map_path:
        print(f"wrote map ({len(fwd_map)} entries) -> {args.map_path}")
    return 0


def _build_flipped_entry(en_val: str, de_text: str, comment: str, src_entry: dict) -> dict:
    """English value becomes the key; English unit + German translation unit."""
    en_unit = src_entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
    en_state = en_unit.get("state", "translated")
    entry: dict = {}
    if comment:
        entry["comment"] = comment
    # preserve extractionState if it was set (e.g. "manual")
    if "extractionState" in src_entry:
        entry["extractionState"] = src_entry["extractionState"]
    entry["localizations"] = {
        "de": {"stringUnit": {"state": "translated", "value": de_text}},
        "en": {"stringUnit": {"state": en_state, "value": en_val}},
    }
    return entry


def cmd_verify(args) -> int:
    cat = load(args.in_path)
    if cat["sourceLanguage"] != "en":
        print(f"FAIL: sourceLanguage is {cat['sourceLanguage']!r}, expected 'en'", file=sys.stderr)
        return 1
    mp = load(args.map_path)
    fwd = mp["forward_de_to_en"]
    missing = [en for en in set(fwd.values()) if en not in cat["strings"]]
    if missing:
        print(f"FAIL: {len(missing)} flipped keys absent from catalogue", file=sys.stderr)
        for en in missing[:10]:
            print(f"  {en!r}", file=sys.stderr)
        return 1
    # every flipped key must still carry the German text as a de translation
    bad = []
    for de_key, en_key in fwd.items():
        de_val = unit_value(cat["strings"][en_key], "de")
        if de_val is None:
            bad.append(en_key)
    if bad:
        print(f"FAIL: {len(bad)} flipped keys lost their German translation", file=sys.stderr)
        return 1
    print(f"OK: source=en, {len(set(fwd.values()))} flipped keys present, German preserved")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("audit", help="report classification + collisions")
    a.add_argument("--in", dest="in_path", required=True)
    a.add_argument("--collisions", dest="collisions", default=None)
    a.set_defaults(func=cmd_audit)

    f = sub.add_parser("flip", help="rewrite catalogue de->en")
    f.add_argument("--in", dest="in_path", required=True)
    f.add_argument("--out", dest="out_path", required=True)
    f.add_argument("--map", dest="map_path", default=None)
    f.add_argument("--collisions", dest="collisions", default=None)
    f.set_defaults(func=cmd_flip)

    v = sub.add_parser("verify", help="sanity-check a flipped catalogue")
    v.add_argument("--in", dest="in_path", required=True)
    v.add_argument("--map", dest="map_path", required=True)
    v.set_defaults(func=cmd_verify)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
