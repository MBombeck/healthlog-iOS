#!/usr/bin/env python3
"""Lower HealthLogTests/Resources/UIStandardBaseline.json after a merge.

UIStandardBaselineTests treats every number in that file as an upper bound
per file, so branches that clean up do not have to touch the shared file. This
script is the one place that lowers it: it counts the same rules the way the
test does (patterns, path filters and the both-slots special case are read
from the test source, so the two cannot drift) and writes the lower numbers.

  refresh-ui-standard-baseline.py          lower the file; a count above the
                                           file fails and nothing is written
  refresh-ui-standard-baseline.py --check  write nothing; fail only where the
                                           test would fail (a count grew)

Exit: 0 holds, 1 a count grew, 2 usage or a broken setup.
"""

import argparse
import collections
import json
import re
import sys
from pathlib import Path

TEST = "HealthLogTests/DesignSystem/UIStandardBaselineTests.swift"
BASELINE = "HealthLogTests/Resources/UIStandardBaseline.json"
RULE = re.compile(
    r'Rule\(\s*id:\s*"(?P<id>[^"]+)",\s*'
    r'includePrefixes:\s*\[(?P<include>[^\]]*)\],\s*'
    r'excludeSubstrings:\s*\[(?P<exclude>[^\]]*)\],\s*'
    r'pattern:\s*(?:nil|#"(?P<pattern>.*?)"#)', re.S)
BOTH_SLOTS = "hl_card_both_slots"


def fail(message, status=2):
    print("refresh-ui-standard-baseline: ERROR %s" % message)
    sys.exit(status)


def strings(listing):
    return re.findall(r'"([^"]*)"', listing)


def read_rules(root):
    text = (root / TEST).read_text(encoding="utf-8")
    rules = []
    for match in RULE.finditer(text):
        pattern = match.group("pattern")
        if pattern is None and match.group("id") != BOTH_SLOTS:
            fail("rule %s has no pattern and is not the both-slots case" % match.group("id"))
        rules.append({"id": match.group("id"),
                      "include": strings(match.group("include")),
                      "exclude": strings(match.group("exclude")),
                      "regex": re.compile(pattern) if pattern is not None else None})
    if not rules:
        fail("no Rule(...) entries found in %s" % TEST)
    return rules


def matching_paren(chars, start):
    """Port of the test's matchingParen: skips string literals."""
    depth, in_string, escaped = 0, False, False
    for index in range(start, len(chars)):
        char = chars[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                return index
    return None


CARD_NEEDLES = ("HLCard(", "HLSettingsCard(")


def cards_with_both_slots(text):
    """Port of the test's countCardsWithBothSlots."""
    return sum(both_slots(text, needle) for needle in CARD_NEEDLES)


def both_slots(text, needle):
    hits, index = 0, 0
    while True:
        index = text.find(needle, index)
        if index < 0:
            return hits
        opening = index + len(needle) - 1
        closing = matching_paren(text, opening)
        if closing is None:
            return hits
        args = text[opening + 1:closing]
        if "subtitle:" in args and "footer:" in args and "bothSlotsJustification:" not in args:
            hits += 1
        index = closing


def measure(root, rules):
    sources = []
    for path in sorted((root / "HealthLog").rglob("*.swift")):
        sources.append((path.relative_to(root).as_posix(), path.read_text(encoding="utf-8")))
    result = {}
    for rule in rules:
        per_file = {}
        for relative, text in sources:
            if not any(relative.startswith(prefix) for prefix in rule["include"]):
                continue
            if any(part in relative for part in rule["exclude"]):
                continue
            hits = (sum(1 for _ in rule["regex"].finditer(text)) if rule["regex"]
                    else cards_with_both_slots(text))
            if hits:
                per_file[relative] = hits
        result[rule["id"]] = per_file
    return result


def main(argv):
    parser = argparse.ArgumentParser(prog="refresh-ui-standard-baseline.py")
    parser.add_argument("--check", action="store_true", help="write nothing, fail only on growth")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    baseline_path = root / BASELINE
    document = json.loads(baseline_path.read_text(encoding="utf-8"),
                          object_pairs_hook=collections.OrderedDict)
    stored = document.get("rules")
    if not isinstance(stored, dict):
        fail("%s has no \"rules\" object" % BASELINE)
    rules = read_rules(root)
    if set(stored) != {rule["id"] for rule in rules}:
        fail("the rules in %s and %s differ" % (BASELINE, TEST))
    actual = measure(root, rules)

    grew, lowered = [], []
    for rule_id, per_file in stored.items():
        for path in sorted(set(per_file) | set(actual[rule_id])):
            before, now = per_file.get(path, 0), actual[rule_id].get(path, 0)
            if now > before:
                grew.append("%s %s %d -> %d GREW" % (rule_id, path, before, now))
            elif now < before:
                lowered.append("%s %s %d -> %d %s" % (rule_id, path, before, now,
                                                      "could be lowered" if args.check else "lowered"))
    for line in lowered + grew:
        print("refresh-ui-standard-baseline: %s" % line)
    if grew:
        print("refresh-ui-standard-baseline: FAIL a count grew; fix the code, nothing was written")
        return 1
    if not args.check and lowered:
        document["rules"] = collections.OrderedDict(
            (rule_id, dict(sorted(actual[rule_id].items()))) for rule_id in stored)
        baseline_path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print("refresh-ui-standard-baseline: wrote %s" % BASELINE)
    print("refresh-ui-standard-baseline: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
