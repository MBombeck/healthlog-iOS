#!/usr/bin/env python3
"""Rewrite German string-literal keys -> English equivalents in Swift code.

After the catalogue source flips to English (scripts/flip-xcstrings.py), every
German literal that SwiftUI/Foundation derives a key from must be rewritten to
the new English key, otherwise the string renders as its raw German key (which
is now only a `de` translation, not the source key).

Driven by the same `de->en` map the catalogue flip emitted, so code and
catalogue stay in lock-step. Scoped to an explicit file/dir list -- the caller
decides which cluster to codemod (the catalogue is one file and must not be
parallel-edited; code files are disjoint and parallelize freely).

Only literals matching the localization APIs are rewritten; an occurrence of
the same German text inside a comment or unrelated string is left alone.

Idempotent: a literal already English is skipped. Reversible: pass the inverse
map (en->de) to roll back.

Usage:
    flip-literals.py --map MAP.json PATH [PATH...]            # forward de->en
    flip-literals.py --map MAP.json --reverse PATH [PATH...]  # rollback en->de
    flip-literals.py --map MAP.json --dry-run PATH [PATH...]  # report only
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

# Localization APIs whose FIRST string-literal argument SwiftUI/Foundation
# derives a catalogue key from. Each entry is the call prefix up to the opening
# quote; the regex captures (prefix, literal) so only that first literal moves.
#
# This list is the union of every key-bearing initializer ACTUALLY used in the
# HealthLog codebase against a catalogue key (surveyed at spike time):
#   Text, LocalizedStringResource, Button, navigationTitle, Label, Section,
#   Picker, Toggle, TextField, Tab, Link, alert, confirmationDialog,
#   LocalizedStringKey, String(localized:), NSLocalizedString,
#   .accessibilityLabel/.accessibilityHint/.accessibilityValue,
#   plus the project's custom wrappers HLButton / HLBadge (first arg is a key).
# Adding an API here is the supported way to widen coverage; an unlisted API
# silently leaves its literal German and the string falls back to the raw key,
# so keep this in sync with the survey before the full run.
_FOUNDATION = [
    r'String\(localized:\s*',
    r'NSLocalizedString\(\s*',
    r'LocalizedStringResource\(\s*',
    r'LocalizedStringKey\(\s*',
]
# View / modifier initializers whose first positional arg is a LocalizedStringKey.
_KEY_FIRST_ARG_APIS = [
    "Text", "Button", "Label", "Section", "Picker", "Toggle", "TextField",
    "Tab", "Link", "Menu", "Stepper", "NavigationLink",
    # project custom wrappers (verified: first arg is a LocalizedStringKey/title)
    "HLButton", "HLBadge",
]
_KEY_FIRST_ARG_MODIFIERS = [
    "navigationTitle", "navigationBarTitle", "accessibilityLabel",
    "accessibilityHint", "accessibilityValue", "alert", "confirmationDialog",
]
# Custom view wrappers that declare title:/subtitle:/footer: as
# LocalizedStringKey (verified in DesignSystem/HLSettingsCard.swift:
# HLSettingsCard / HLSettingsPage / HLSettingsPageHeader). Only these wrappers
# get their named-arg literals rewritten -- a blanket `title:` match would also
# hit plain-String wrappers like HLNumericField/HLButton/DashboardMetric and
# wrongly flip verbatim copy. Pattern requires the wrapper name to appear
# before the named arg (it may sit on an earlier line, so the prefix is matched
# across the gap up to the named arg). Rewrite still only fires on a map-key
# match, so this is doubly guarded.
_LSK_NAMED_ARG_WRAPPERS = ["HLSettingsCard", "HLSettingsPage", "HLSettingsPageHeader"]
_LSK_NAMED_ARGS = ["title", "subtitle", "footer"]


def _build_patterns():
    pats = [re.compile(f'({f})"((?:[^"\\\\]|\\\\.)*)"') for f in _FOUNDATION]
    for api in _KEY_FIRST_ARG_APIS:
        pats.append(re.compile(rf'(\b{api}\(\s*)"((?:[^"\\]|\\.)*)"'))
    for mod in _KEY_FIRST_ARG_MODIFIERS:
        pats.append(re.compile(rf'(\.{mod}\(\s*)"((?:[^"\\]|\\.)*)"'))
    wrappers = "|".join(_LSK_NAMED_ARG_WRAPPERS)
    args = "|".join(_LSK_NAMED_ARGS)
    # \b(HLSettings…)\( ... (title|subtitle|footer):  "literal"
    # The middle [^()"] run stays inside the same call's arg list and never
    # crosses a nested string/paren, so only the wrapper's own args match.
    pats.append(
        re.compile(rf'(\b(?:{wrappers})\((?:[^()"]|"[^"]*")*?\b(?:{args}):\s*)"((?:[^"\\]|\\.)*)"')
    )
    return pats


API_PATTERNS = _build_patterns()

# JSON encodes catalogue keys with real characters; Swift source escapes some.
# Map between the on-disk Swift literal text and the catalogue key string.
_SWIFT_UNESCAPE = {
    r"\"": '"',
    r"\\": "\\",
    r"\n": "\n",
    r"\t": "\t",
    r"\r": "\r",
}


def swift_to_key(lit: str) -> str:
    out = []
    i = 0
    while i < len(lit):
        if lit[i] == "\\" and i + 1 < len(lit):
            pair = lit[i : i + 2]
            out.append(_SWIFT_UNESCAPE.get(pair, pair))
            i += 2
        else:
            out.append(lit[i])
            i += 1
    return "".join(out)


def key_to_swift(key: str) -> str:
    return (
        key.replace("\\", r"\\")
        .replace('"', r"\"")
        .replace("\n", r"\n")
        .replace("\t", r"\t")
        .replace("\r", r"\r")
    )


def iter_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in files:
                    if f.endswith(".swift"):
                        yield os.path.join(root, f)
        elif p.endswith(".swift"):
            yield p


def rewrite_text(text: str, mapping: dict[str, str]):
    """Return (new_text, [(old_key, new_key)]) for all replacements made."""
    changes: list[tuple[str, str]] = []

    def make_repl(_pattern):
        def repl(m):
            prefix, lit = m.group(1), m.group(2)
            key = swift_to_key(lit)
            if key in mapping:
                new_key = mapping[key]
                if new_key != key:
                    changes.append((key, new_key))
                    return f'{prefix}"{key_to_swift(new_key)}"'
            return m.group(0)

        return repl

    for pat in API_PATTERNS:
        text = pat.sub(make_repl(pat), text)
    return text, changes


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", required=True, help="JSON map from flip-xcstrings.py")
    ap.add_argument("--reverse", action="store_true", help="rollback en->de")
    ap.add_argument("--dry-run", action="store_true", help="report only, do not write")
    ap.add_argument("paths", nargs="+", help="files or directories to scope")
    args = ap.parse_args()

    with open(args.map, encoding="utf-8") as fh:
        mp = json.load(fh)
    mapping = mp["inverse_en_to_de"] if args.reverse else mp["forward_de_to_en"]

    total = 0
    touched = 0
    for path in iter_files(args.paths):
        with open(path, encoding="utf-8") as fh:
            original = fh.read()
        new_text, changes = rewrite_text(original, mapping)
        if not changes:
            continue
        touched += 1
        total += len(changes)
        for old, new in changes:
            print(f"  {path}: {old!r} -> {new!r}")
        if not args.dry_run:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_text)
    verb = "would change" if args.dry_run else "changed"
    print(f"{verb} {total} literal(s) across {touched} file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
