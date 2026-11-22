#!/usr/bin/env python3
"""Design ratchets for the screen code (C0 design foundation, section 5).

One engine behind three entry points:

  design-ratchet.sh        counts the C0 SwiftLint patterns (R1 to R18) plus the
                           two structural checks below per package and compares
                           them with scripts/design-ratchets/C<n>.json. A count
                           above the stored one fails; a lower one rewrites the
                           file (never with --check). With --base <ref> no count
                           and no limit may exceed the file at that commit.
                           The E3 action-form rules (E3_RULES plus two counters
                           without a SwiftLint rule) are held per file in
                           scripts/design-ratchets/E3.json the same way.
  check-sheet-scaffold.sh  every `struct ...Sheet...: View` under Screens uses
                           HLSheetScaffold( or is listed, with a reason, in
                           check-sheet-scaffold-exceptions.json.
  check-delete-ladder.sh   every `role: .destructive` under Screens sits inside
                           HLDeleteButton(, HLDeleteMenuItem( or
                           .hlSwipeDelete(, carries the stage 3 marker, or is
                           listed in
                           check-delete-ladder-exceptions.json.

The R patterns are read from .swiftlint.yml, so the editor warning and the
ratchet count the same sites. A match that touches a comment does not count,
which is how SwiftLint applies `excluded_match_kinds: [comment, doccomment]`;
a URL inside a comment is its own token kind there and does count.

Exit codes: 0 holds, 1 a count grew, a file is stale or an exception is
invalid, 2 usage or a broken setup.
"""

import argparse
import bisect
import json
import re
import subprocess
import sys
from pathlib import Path

SCREENS = "HealthLog/Screens"
RATCHET_DIR = "scripts/design-ratchets"

# Section 4.2 and appendix B. Every directory under Screens belongs to exactly
# one package; a new directory has to be assigned here before it can pass.
PACKAGES = {
    "C1": ["Settings", "PersonalSettings", "AboutMe"],
    "C2": ["Medications", "GLP1", "Measure", "Measurements", "Capture",
           "Notifications", "Records", "CustomMetrics"],
    "C3": ["Insights", "Dashboard", "Charts", "Coach", "PersonalRecords",
           "Achievements", "Workouts", "Environment", "Nutrition", "Shared",
           "Onboarding", "LifeCircumstances", "Timeline"],
    "C4": ["Mood", "Cycle", "Illness", "Seizures", "Labs", "Documents", "MentalHealth",
           "Sharing", "DoctorReport"],
}

# R1 to R18 in the order of section 5.1.
LINT_RULES = [
    ("R1", "hl_no_rejected_button_variant"),
    ("R2", "hl_button_large_only_onboarding"),
    ("R3", "hl_no_raw_sheet_roles"),
    ("R4", "hl_no_literal_sheet_verbs"),
    ("R5", "hl_no_raw_presentation"),
    ("R6", "hl_no_raw_icon_frame"),
    ("R7", "hl_no_handmade_card"),
    ("R8", "hl_no_settingscard"),
    ("R9", "hl_no_local_state_view"),
    ("R10", "hl_no_local_section_header"),
    ("R11", "hl_no_uppercase_header"),
    ("R12", "hl_date_via_helper"),
    ("R13", "hl_number_via_helper"),
    ("R14", "hl_no_fixed_color_scheme"),
    ("R15", "hl_single_retry_key"),
    ("R16", "hl_page_margin"),
    ("R17", "hl_no_raw_segmented"),
    ("R18", "hl_no_glass_in_content"),
    # F9: roles instead of free values (F9-ganzheit section 5).
    ("R21", "hl_free_page_spacing"),
    ("R22", "hl_raw_spacing"),
    ("R23", "hl_system_large_title"),
    ("R24", "hl_card_surface_in_screens"),
]
# F9 R19 and R20: free font and free text colour in screens. Counted here
# only; with several hundred sites each they would drown the SwiftLint
# warning baseline. They only fall: a text takes a role with `.hlText(_:)`.
F9_COUNTERS = [
    ("R19", "hl_free_font", re.compile(r"\.font\(\.hl(?!Icon)")),
    ("R20", "hl_free_text_color", re.compile(r"foregroundStyle\(HLText\.")),
]
F9_EXCLUDED = ("Onboarding",)
# E3 standardisation (action forms): SwiftLint rules on `warning`, held per
# file so the area packages can only lower them. Each one goes to `error` once
# it stands at zero.
E3_PACKAGE = "E3"
E3_RULES = [
    "hl_no_plain_buttonstyle",
    "hl_no_raw_hit_frame",
    "hl_no_underline",
    "hl_no_literal_more_toggle",
    "hl_no_choice_glyph",
    "hl_no_remove_glyph",
    "hl_no_clear_glyph",
    "hl_no_raw_ok_alert",
    "hl_toolbar_via_page_actions",
    "hl_no_custom_back",
    "hl_no_button_tint",
]
# Counted here only: a regex rule would also hit menus and context menus,
# which use the same form legitimately (Label button), or needs the line
# around the call (a tile action outside its row).
E3_COUNTERS = {
    "hl_no_form_label_button": re.compile(r"\bButton\s*\{[^{}]*\}\s*label:\s*\{\s*Label\("),
    "hl_tile_action_button_direct": re.compile(r"\bHLTileActionButton\s*\("),
}

SHEET_KEY = "sheet_without_scaffold"
DELETE_KEY = "delete_without_ladder"
STAGE3_KEY = "delete_stage3"
PAGE_KEY = "page_without_scaffold"
STRUCTURAL = [("S1", SHEET_KEY), ("S2", DELETE_KEY), ("S3", PAGE_KEY)]

# Targets after the merge, per package; everything not listed is 0. The
# reasons are in STANDARD-ui.md ("C0-Ratschen: begründete Restfälle").
TARGETS = {
    "C1": {"hl_no_glass_in_content": 2},              # pinned consent bars
    "C2": {"hl_no_raw_sheet_roles": 2,                 # two pushed edit pages
           "hl_no_literal_sheet_verbs": 3},            # those two and the keyboard bar
    "C3": {"hl_no_handmade_card": 6,                   # hero tile, gradient card, record hero, welcome
           "hl_no_uppercase_header": 1,                # share image label
           "hl_no_glass_in_content": 7},               # coach input bar, onboarding CTA bars, chart pill
    "C4": {"hl_no_handmade_card": 2,                   # document bulk bar
           "hl_no_fixed_color_scheme": 2,              # cycle ring previews
           "hl_no_glass_in_content": 1},               # document bulk bar
}

# Section 3.4: stage 3 is account, all data and the like, each with its own
# confirmation screen. Only C1 has those (reset data, delete account).
STAGE3_LIMITS = {"C1": 2, "C2": 0, "C3": 0, "C4": 0}

# S3: a titled scroll page under Screens without the page scaffold.
PAGE_SCROLL = re.compile(r"\bScrollView\s*(?:\([^()]*\))?\s*\{")
PAGE_TITLE = re.compile(r"\bHLTabHeader\s*\(|\.navigationTitle\s*\(")
PAGE_SCAFFOLD = re.compile(r"\bHLPage\s*[(<{]|\.hlPageMargins\s*\(\)")
SHEET_TYPE = re.compile(r"struct (\w+Sheet\w*)\s*:\s*View")      # appendix A, B4
DESTRUCTIVE = re.compile(r"role: \.destructive")                  # appendix A, L2
SCAFFOLD_CALL = re.compile(r"\bHLSheetScaffold\s*\(")
LADDER_CALL = re.compile(r"\b(?:HLDeleteButton|HLDeleteMenuItem)\s*\(|\.hlSwipeDelete\s*\(")
STAGE3_MARKER = re.compile(r"//\s*hl-delete-ladder:\s*stage-3\b(.*)$")
COMMENT_URL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://\S*")
ANCHOR_WINDOW = 4  # lines between an anchor and the destructive role it names
MIN_REASON = 12    # characters; "ok" or "todo" is not a reason
STRING_OPEN = re.compile(r'(#*)("""|")')
LINE_GUARD = "(?m)^(?:(?!//)[^\\n])*?"


class SetupError(Exception):
    pass


# ---------------------------------------------------------------------------
# Source views
# ---------------------------------------------------------------------------

def mask_source(text):
    """Return (code, bare, comments): `code` has comments blanked, `bare` also
    string contents, `comments` lists the comment spans. Newlines survive, so
    offsets and line numbers stay valid."""
    code = list(text)
    bare = list(text)
    n = len(text)
    i = 0
    # Stack of contexts: ("code", paren_depth) inside an interpolation, or
    # ("str", hashes, multiline).
    stack = [("code", 0)]
    comments = []

    def blank(view, start, end):
        for k in range(start, end):
            if view[k] != "\n":
                view[k] = " "

    while i < n:
        top = stack[-1]
        ch = text[i]
        if top[0] == "code":
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                blank(code, i, end)
                blank(bare, i, end)
                comments.append((i, end))
                i = end
                continue
            if text.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if text.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif text.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                blank(code, i, j)
                blank(bare, i, j)
                comments.append((i, j))
                i = j
                continue
            m = STRING_OPEN.match(text, i)
            if m:
                hashes = len(m.group(1))
                multiline = m.group(2) == '"""'
                stack.append(("str", hashes, multiline))
                i = m.end()
                continue
            if len(stack) > 1:
                if ch == "(":
                    stack[-1] = ("code", top[1] + 1)
                elif ch == ")":
                    if top[1] == 0:
                        stack.pop()       # back into the enclosing string
                        i += 1
                        continue
                    stack[-1] = ("code", top[1] - 1)
            i += 1
            continue
        # Inside a string literal.
        _, hashes, multiline = top
        closing = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        if text.startswith(escape + "(", i):
            bare[i] = " "
            i += len(escape) + 1
            stack.append(("code", 0))
            continue
        if text.startswith(escape, i) and hashes == 0:
            blank(bare, i, min(i + 2, n))
            i += 2
            continue
        if text.startswith(closing, i):
            stack.pop()
            i += len(closing)
            continue
        if ch == "\n" and not multiline:
            stack.pop()             # unterminated single-line string
            i += 1
            continue
        if ch != "\n":
            bare[i] = " "
        i += 1
    return "".join(code), "".join(bare), comments


def matching_close(bare, start):
    """Offset just past the bracket that closes bare[start]."""
    pairs = {"(": ")", "{": "}", "[": "]"}
    opener = bare[start]
    closer = pairs[opener]
    depth = 0
    for k in range(start, len(bare)):
        if bare[k] == opener:
            depth += 1
        elif bare[k] == closer:
            depth -= 1
            if depth == 0:
                return k + 1
    return len(bare)


def call_span(bare, match_end):
    """Span of a call whose `(` ends the match, with a trailing closure."""
    open_paren = match_end - 1
    end = matching_close(bare, open_paren)
    rest = re.compile(r"\s*\{").match(bare, end)
    if rest:
        end = matching_close(bare, rest.end() - 1)
    return open_paren, end


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def comment_tokens(text, spans):
    """Comment spans without the URLs inside them; SwiftLint gives a URL in a
    comment its own token kind, so a match there is not excluded."""
    tokens = []
    for start, end in spans:
        cursor = start
        for url in COMMENT_URL.finditer(text, start, end):
            if url.start() > cursor:
                tokens.append((cursor, url.start()))
            cursor = url.end()
        if cursor < end:
            tokens.append((cursor, end))
    return tokens


class Source:
    def __init__(self, root, path):
        self.rel = path.relative_to(root).as_posix()
        self.text = path.read_text(encoding="utf-8")
        self.code, self.bare, spans = mask_source(self.text)
        self.comments = comment_tokens(self.text, spans)
        self._starts = [start for start, _ in self.comments]
        self.lines = self.text.split("\n")
        parts = self.rel.split("/")
        self.directory = parts[2] if len(parts) > 3 else None

    def touches_comment(self, start, end):
        # Spans are sorted and disjoint: only the last one that starts before
        # `end` can reach into the match.
        index = bisect.bisect_left(self._starts, end) - 1
        return index >= 0 and self.comments[index][1] > start


# ---------------------------------------------------------------------------
# Repository
# ---------------------------------------------------------------------------

class Repo:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.screens = self.root / SCREENS
        if not self.screens.is_dir():
            raise SetupError("%s is missing under %s" % (SCREENS, self.root))
        self.package_of = {}
        for package, directories in PACKAGES.items():
            for directory in directories:
                self.package_of[directory] = package
        problems = []
        for entry in sorted(self.screens.iterdir()):
            if entry.is_dir() and entry.name not in self.package_of:
                problems.append("directory %s/%s belongs to no package; assign it in "
                                "scripts/design-ratchet.py" % (SCREENS, entry.name))
            elif entry.is_file() and entry.suffix == ".swift":
                problems.append("file %s/%s sits outside a package directory" % (SCREENS, entry.name))
        if problems:
            raise SetupError("\n".join(problems))
        self.sources = [Source(self.root, path) for path in sorted(self.screens.rglob("*.swift"))]
        self.scripts = self.root / "scripts"

    def package(self, source):
        return self.package_of[source.directory]

    def lint_rules(self, numbered=None):
        config = load_yaml(self.root / ".swiftlint.yml")
        custom = (config or {}).get("custom_rules") or {}
        rules = []
        for number, identifier in numbered or LINT_RULES:
            spec = custom.get(identifier)
            if not spec or "regex" not in spec:
                raise SetupError("rule %s (%s) is missing in .swiftlint.yml" % (number, identifier))
            kinds = set(spec.get("excluded_match_kinds") or [])
            skips_comments = {"comment", "doccomment"} <= kinds
            # A rule without the exclusion must keep comment lines out in its
            # own pattern, as R1 and R2 do.
            if not skips_comments and not spec["regex"].startswith(LINE_GUARD):
                raise SetupError("rule %s must exclude comment and doccomment or start with %s"
                                 % (identifier, LINE_GUARD))
            rules.append({
                "skips_comments": skips_comments,
                "number": number,
                "id": identifier,
                "regex": re.compile(spec["regex"]),
                "included": [re.compile(p) for p in spec.get("included") or []],
                "excluded": [re.compile(p) for p in spec.get("excluded") or []],
            })
        return rules

    def git_show(self, ref, path):
        """Text of `path` at `ref`, or None when the file is not there."""
        verify = subprocess.run(["git", "-C", str(self.root), "rev-parse", "--verify", "--quiet",
                                 "%s^{commit}" % ref], capture_output=True, text=True)
        if verify.returncode != 0:
            raise SetupError("base %s is not a commit in this repository" % ref)
        shown = subprocess.run(["git", "-C", str(self.root), "show", "%s:%s" % (ref, path)],
                               capture_output=True, text=True)
        return shown.stdout if shown.returncode == 0 else None


def load_yaml(path):
    try:
        import yaml
        with open(path, encoding="utf-8") as handle:
            return yaml.safe_load(handle)
    except ImportError:
        out = subprocess.run(
            ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", str(path)],
            check=True, capture_output=True, text=True)
        return json.loads(out.stdout)


def load_exceptions(path, fields):
    """Entries of an exception list. Every entry needs a reason."""
    errors = []
    if not path.is_file():
        return [], ["exception list %s is missing" % path.name]
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return [], ["%s is not valid JSON: %s" % (path.name, error)]
    entries = document.get("exceptions")
    if document.get("schema") != 1 or not isinstance(entries, list):
        return [], ["%s needs {\"schema\": 1, \"exceptions\": [...]}" % path.name]
    for index, entry in enumerate(entries):
        where = "%s entry %d" % (path.name, index + 1)
        if not isinstance(entry, dict):
            errors.append("%s is not an object" % where)
            continue
        reason = entry.get("reason")
        if not isinstance(reason, str) or len(reason.strip()) < MIN_REASON:
            errors.append("%s has no reason (at least %d characters)" % (where, MIN_REASON))
        for field in fields:
            if not isinstance(entry.get(field), str) or not entry.get(field):
                errors.append("%s lacks \"%s\"" % (where, field))
    return entries, errors


# ---------------------------------------------------------------------------
# Analyses
# ---------------------------------------------------------------------------

def lint_hits(repo, rules):
    """(rule id, source, line) for every counted match, the way SwiftLint
    reports them."""
    hits = []
    for source in repo.sources:
        for rule in rules:
            if rule["included"] and not any(p.search(source.rel) for p in rule["included"]):
                continue
            if any(p.search(source.rel) for p in rule["excluded"]):
                continue
            for match in rule["regex"].finditer(source.text):
                if not rule["skips_comments"] or \
                        not source.touches_comment(match.start(), max(match.end(), match.start() + 1)):
                    hits.append((rule["id"], source, line_of(source.text, match.start())))
    return hits


def count_lint(repo, rules):
    counts = {package: {rule["id"]: 0 for rule in rules} for package in PACKAGES}
    for identifier, source, _ in lint_hits(repo, rules):
        counts[repo.package(source)][identifier] += 1
    return counts


def analyse_sheets(repo):
    """Sheet types with their state: scaffold, exception or open."""
    types = []
    extensions = {}
    for source in repo.sources:
        for match in SHEET_TYPE.finditer(source.code):
            brace = source.bare.find("{", match.end())
            end = matching_close(source.bare, brace) if brace >= 0 else match.end()
            types.append({"name": match.group(1), "source": source,
                          "line": line_of(source.text, match.start()),
                          "spans": [(source, match.start(), end)]})
        for match in re.finditer(r"\bextension\s+(\w+)\b", source.code):
            brace = source.bare.find("{", match.end())
            if brace >= 0:
                extensions.setdefault(match.group(1), []).append(
                    (source, match.start(), matching_close(source.bare, brace)))
    entries, errors = load_exceptions(repo.scripts / "check-sheet-scaffold-exceptions.json", ["type"])
    names = {}
    for sheet in types:
        names.setdefault(sheet["name"], []).append(sheet)
        sheet["spans"] += extensions.get(sheet["name"], [])
        sheet["scaffold"] = any(SCAFFOLD_CALL.search(src.bare, start, end)
                                for src, start, end in sheet["spans"])
        sheet["exception"] = None
    stale = []
    seen = set()
    for entry in entries:
        name = entry.get("type")
        if name in seen:
            errors.append("sheet exception %s is listed twice" % name)
            continue
        seen.add(name)
        matches = [s for s in names.get(name, []) if entry.get("path") in (None, s["source"].rel)]
        if not matches:
            stale.append("sheet exception %s names no sheet type under %s" % (name, SCREENS))
            continue
        if len(matches) > 1:
            errors.append("sheet exception %s is ambiguous; add \"path\"" % name)
            continue
        if matches[0]["scaffold"]:
            stale.append("sheet exception %s already uses HLSheetScaffold; drop the entry" % name)
        matches[0]["exception"] = entry.get("reason")
    return types, errors, stale


def analyse_deletes(repo):
    """Destructive roles with their state: ladder, stage 3, exception or open."""
    hits = []
    errors = []
    for source in repo.sources:
        spans = [call_span(source.bare, m.end()) for m in LADDER_CALL.finditer(source.bare)]
        for match in DESTRUCTIVE.finditer(source.code):
            line = line_of(source.text, match.start())
            hit = {"source": source, "line": line, "state": "open"}
            if any(start <= match.start() < end for start, end in spans):
                hit["state"] = "ladder"
            else:
                for candidate in (line, line - 1):
                    if candidate < 1:
                        continue
                    marker = STAGE3_MARKER.search(source.lines[candidate - 1])
                    if marker:
                        if len(marker.group(1).strip(" ,:.")) < MIN_REASON:
                            errors.append("%s:%d stage 3 marker without a reason"
                                          % (source.rel, candidate))
                        hit["state"] = "stage-3"
                        hit["marker_line"] = candidate
                        break
            hits.append(hit)
    entries, list_errors = load_exceptions(repo.scripts / "check-delete-ladder-exceptions.json",
                                           ["path", "anchor"])
    errors += list_errors
    stale = []
    seen = set()
    for entry in entries:
        path, anchor = entry.get("path"), entry.get("anchor")
        if not isinstance(path, str) or not isinstance(anchor, str) or not anchor:
            continue
        if (path, anchor) in seen:
            errors.append("delete exception %s / %s is listed twice" % (path, anchor))
            continue
        seen.add((path, anchor))
        # Every line naming the anchor points at the nearest open destructive
        # role within ANCHOR_WINDOW lines; the entry must point at exactly one.
        open_hits = [h for h in hits if h["source"].rel == path and h["state"] == "open"]
        covered = []
        lines = open_hits[0]["source"].lines if open_hits else []
        for number, text in enumerate(lines, start=1):
            if anchor not in text:
                continue
            near = sorted((abs(h["line"] - number), h["line"], id(h), h) for h in open_hits
                          if abs(h["line"] - number) <= ANCHOR_WINDOW)
            if not near:
                continue
            if len(near) > 1 and near[0][0] == near[1][0]:
                errors.append("delete exception %s / %s: line %d is as close to line %d as to %d"
                              % (path, anchor, number, near[0][1], near[1][1]))
                continue
            if near[0][3] not in covered:
                covered.append(near[0][3])
        if not covered:
            stale.append("delete exception %s / %s covers no open destructive role; drop the entry"
                         % (path, anchor))
        elif len(covered) > 1:
            errors.append("delete exception %s / %s covers %d destructive roles (lines %s); "
                          "use an anchor that names one"
                          % (path, anchor, len(covered), ", ".join(str(h["line"]) for h in covered)))
        else:
            covered[0]["state"] = "exception"
    return hits, errors, stale


def f9_counts(repo):
    """{package: {key: count}} for the counters without a SwiftLint rule."""
    counts = {package: {key: 0 for _, key, _ in F9_COUNTERS} for package in PACKAGES}
    for source in repo.sources:
        if source.directory in F9_EXCLUDED:
            continue
        for _, key, pattern in F9_COUNTERS:
            for match in pattern.finditer(source.text):
                if not source.touches_comment(match.start(), max(match.end(), match.start() + 1)):
                    counts[repo.package(source)][key] += 1
    return counts


def analyse_pages(repo):
    """Titled scroll pages without HLPage or hlPageMargins(): open or listed."""
    entries, errors = load_exceptions(repo.scripts / "check-page-scaffold-exceptions.json", ["path"])
    listed = {}
    for entry in entries:
        path = entry.get("path")
        if path in listed:
            errors.append("page exception %s is listed twice" % path)
        listed[path] = entry.get("reason")
    pages = []
    for source in repo.sources:
        if source.directory in F9_EXCLUDED:
            continue
        if PAGE_SCROLL.search(source.code) and PAGE_TITLE.search(source.code) \
                and not PAGE_SCAFFOLD.search(source.code):
            pages.append({"source": source, "exception": listed.get(source.rel)})
    found = {page["source"].rel for page in pages}
    stale = ["page exception %s names no open page; drop the entry" % path
             for path in listed if path not in found]
    return pages, errors, stale


def structural_counts(repo, sheets, deletes, pages=()):
    counts = {package: {SHEET_KEY: 0, DELETE_KEY: 0, PAGE_KEY: 0} for package in PACKAGES}
    for page in pages:
        if not page["exception"]:
            counts[repo.package(page["source"])][PAGE_KEY] += 1
    for sheet in sheets:
        if not sheet["scaffold"] and not sheet["exception"]:
            counts[repo.package(sheet["source"])][SHEET_KEY] += 1
    for hit in deletes:
        if hit["state"] == "open":
            counts[repo.package(hit["source"])][DELETE_KEY] += 1
    return counts


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def report_problems(prefix, errors, stale, strict):
    for line in errors:
        print("%s: ERROR %s" % (prefix, line))
    for line in stale:
        print("%s: %s %s" % (prefix, "ERROR" if strict else "STALE", line))
    return bool(errors) or (strict and bool(stale))


def command_sheets(repo, args):
    sheets, errors, stale = analyse_sheets(repo)
    failed = report_problems("check-sheet-scaffold", errors, stale, args.strict)
    open_sheets = [s for s in sheets if not s["scaffold"] and not s["exception"]]
    for sheet in open_sheets:
        print("check-sheet-scaffold: open %s:%d %s"
              % (sheet["source"].rel, sheet["line"], sheet["name"]))
    for package in PACKAGES:
        mine = [s for s in sheets if repo.package(s["source"]) == package]
        print("check-sheet-scaffold: %s %d sheet types, %d with HLSheetScaffold, %d exceptions, %d open"
              % (package, len(mine), sum(s["scaffold"] for s in mine),
                 sum(bool(s["exception"]) and not s["scaffold"] for s in mine),
                 sum(1 for s in mine if s in open_sheets)))
    if args.strict and open_sheets:
        print("check-sheet-scaffold: FAIL %d sheet types without HLSheetScaffold" % len(open_sheets))
        return 1
    if failed:
        print("check-sheet-scaffold: FAIL")
        return 1
    print("check-sheet-scaffold: PASS (open sheets are held by design-ratchet.sh)")
    return 0


def command_deletes(repo, args):
    hits, errors, stale = analyse_deletes(repo)
    failed = report_problems("check-delete-ladder", errors, stale, args.strict)
    open_hits = [h for h in hits if h["state"] == "open"]
    for hit in open_hits:
        print("check-delete-ladder: open %s:%d" % (hit["source"].rel, hit["line"]))
    for hit in hits:
        if hit["state"] == "stage-3":
            print("check-delete-ladder: stage-3 %s:%d" % (hit["source"].rel, hit["marker_line"]))
    for package in PACKAGES:
        mine = [h for h in hits if repo.package(h["source"]) == package]

        def count(state, mine=mine):
            return sum(1 for h in mine if h["state"] == state)
        print("check-delete-ladder: %s %d destructive roles, %d in the ladder, %d stage 3, "
              "%d exceptions, %d open"
              % (package, len(mine), count("ladder"), count("stage-3"), count("exception"), count("open")))
    if args.strict and open_hits:
        print("check-delete-ladder: FAIL %d destructive roles outside the ladder" % len(open_hits))
        return 1
    if failed:
        print("check-delete-ladder: FAIL")
        return 1
    print("check-delete-ladder: PASS (open sites are held by design-ratchet.sh)")
    return 0


def ratchet_rel(package):
    return "%s/%s.json" % (RATCHET_DIR, package)


def render(package, counts, limits):
    document = {"schema": 1, "package": package, "directories": PACKAGES[package],
                "counts": dict(sorted(counts.items())),
                "limits": dict(sorted(limits.items()))}
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def parse_ratchet(text, package, where):
    """(counts, limits) of a package file, or raise SetupError."""
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise SetupError("%s is not valid JSON: %s" % (where, error)) from error
    if document.get("schema") != 1 or document.get("package") != package:
        raise SetupError("%s has the wrong schema or package" % where)
    return document.get("counts", {}), document.get("limits", {}), document


def command_ratchet(repo, args):
    rules = repo.lint_rules()
    sheets, sheet_errors, sheet_stale = analyse_sheets(repo)
    deletes, delete_errors, delete_stale = analyse_deletes(repo)
    pages, page_errors, page_stale = analyse_pages(repo)
    failed = report_problems("design-ratchet", sheet_errors + delete_errors + page_errors,
                             sheet_stale + delete_stale, False)
    # A stale page exception would silently exempt a later relapse in the same
    # file, so --check (CI, release gates) rejects it.
    if report_problems("design-ratchet", [], page_stale, args.check):
        failed = True
    grew_any = False
    current = count_lint(repo, rules)
    for package, values in structural_counts(repo, sheets, deletes, pages).items():
        current[package].update(values)
    for package, values in f9_counts(repo).items():
        current[package].update(values)
    for page in pages:
        if not page["exception"]:
            print("design-ratchet: S3 open %s" % page["source"].rel)
    markers = {package: [h for h in deletes if h["state"] == "stage-3"
                         and repo.package(h["source"]) == package] for package in PACKAGES}

    existing = [p for p in PACKAGES if (repo.root / ratchet_rel(p)).is_file()]
    if (repo.root / e3_rel()).is_file():
        existing.append(E3_PACKAGE)
    if args.init and len(existing) == len(PACKAGES) + 1:
        print("design-ratchet: FAIL --init only creates missing files; %s exist (--force-init "
              "rewrites them)" % ", ".join(existing))
        return 1

    base_counts, base_limits = {}, {}
    if args.base:
        for package in PACKAGES:
            text = repo.git_show(args.base, ratchet_rel(package))
            if text is None:
                print("design-ratchet: %s.json is not at base %s; the checked-in file applies"
                      % (package, args.base))
                continue
            counts, limits, _ = parse_ratchet(text, package, "%s at %s" % (package, args.base))
            base_counts[package], base_limits[package] = counts, limits
    else:
        print("design-ratchet: no base given; compared with the checked-in files only")

    to_write = {}
    for package in PACKAGES:
        path = repo.root / ratchet_rel(package)
        limits = {STAGE3_KEY: STAGE3_LIMITS[package]}
        if args.init or args.force_init:
            if args.init and package in existing:
                continue
            to_write[package] = (current[package], limits)
            if check_stage3(package, markers[package], limits):
                failed = grew_any = True
            continue
        if not path.is_file():
            print("design-ratchet: FAIL %s is missing" % path.name)
            failed = True
            continue
        try:
            stored, limits, document = parse_ratchet(path.read_text(encoding="utf-8"), package, path.name)
        except SetupError as error:
            print("design-ratchet: FAIL %s" % error)
            failed = True
            continue
        if document.get("directories") != PACKAGES[package]:
            print("design-ratchet: FAIL %s lists other directories than scripts/design-ratchet.py"
                  % path.name)
            failed = True
        if STAGE3_KEY not in limits:
            print("design-ratchet: FAIL %s has no limit %s" % (path.name, STAGE3_KEY))
            failed = True
            limits = {STAGE3_KEY: 0}
        grew = lowered = False
        for key in sorted(set(stored) | set(current[package])):
            if key not in current[package]:
                print("design-ratchet: FAIL %s records %s, which is no longer counted" % (package, key))
                failed = True
                continue
            if key not in stored:
                print("design-ratchet: FAIL %s does not record %s" % (package, key))
                failed = True
                continue
            before, now = stored[key], current[package][key]
            if now > before:
                print("design-ratchet: FAIL %s %s %d -> %d GREW" % (package, key, before, now))
                grew = True
            elif now < before:
                print("design-ratchet: %s %s %d -> %d %s" % (package, key, before, now,
                                                              "STALE" if args.check else "lowered"))
                lowered = True
        if grew:
            failed = grew_any = True
        elif lowered:
            if args.check:
                failed = True
            else:
                to_write[package] = (current[package], limits)
        elif path.read_text(encoding="utf-8") != render(package, current[package], limits):
            # Same numbers, other bytes: the file was edited by hand.
            if args.check:
                print("design-ratchet: FAIL %s is not in canonical form; run scripts/design-ratchet.sh"
                      % path.name)
                failed = True
            else:
                to_write[package] = (current[package], limits)

        # The base holds what the package may not raise: counts and limits.
        for key, allowed in base_counts.get(package, {}).items():
            if key in current[package] and current[package][key] > allowed:
                print("design-ratchet: FAIL %s %s is %d, above %d at base %s"
                      % (package, key, current[package][key], allowed, args.base))
                failed = grew_any = True
        for key, allowed in base_limits.get(package, {}).items():
            if limits.get(key, 0) > allowed:
                print("design-ratchet: FAIL %s limit %s is %d, above %d at base %s"
                      % (package, key, limits.get(key, 0), allowed, args.base))
                failed = grew_any = True
        if check_stage3(package, markers[package], limits):
            failed = grew_any = True

    print_summary(rules, current, markers)
    e3_failed, e3_grew, e3_text = e3_ratchet(repo, args)
    if e3_failed:
        failed = True
    if e3_grew:
        grew_any = True
    if failed:
        if grew_any:
            print("design-ratchet: FAIL (a count or limit grew; fix the code, nothing was written)")
        elif args.check:
            print("design-ratchet: FAIL (--check; nothing was written. Run scripts/design-ratchet.sh "
                  "and commit the lowered files)")
        else:
            print("design-ratchet: FAIL (nothing was written)")
        return 1
    for package, (counts, limits) in to_write.items():
        path = repo.root / ratchet_rel(package)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(render(package, counts, limits), encoding="utf-8")
        print("design-ratchet: wrote %s" % ratchet_rel(package))
    if e3_text is not None:
        path = repo.root / e3_rel()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(e3_text, encoding="utf-8")
        print("design-ratchet: wrote %s" % e3_rel())
    print("design-ratchet: PASS")
    return 0


# ---------------------------------------------------------------------------
# E3: action forms, per file
# ---------------------------------------------------------------------------

def e3_rel():
    return "%s/%s.json" % (RATCHET_DIR, E3_PACKAGE)


def e3_keys():
    return sorted(E3_RULES + list(E3_COUNTERS))


def e3_counts(repo):
    """{key: {file: count}} with only the files that have a finding."""
    rules = repo.lint_rules([("E3", identifier) for identifier in E3_RULES])
    counts = {key: {} for key in e3_keys()}
    for identifier, source, _ in lint_hits(repo, rules):
        counts[identifier][source.rel] = counts[identifier].get(source.rel, 0) + 1
    for key, pattern in E3_COUNTERS.items():
        for source in repo.sources:
            found = [m for m in pattern.finditer(source.code) if e3_counts_match(key, source, m)]
            if found:
                counts[key][source.rel] = len(found)
    return {key: dict(sorted(files.items())) for key, files in counts.items()}


# Where a Label button is the system's own form: menus, context menus, swipe
# actions and bars. A Label button outside those is a form or content row.
E3_MENU_OPEN = re.compile(r"(?:\bMenu\s*|\.contextMenu\s*|\.swipeActions\s*(?:\([^)]*\))?\s*|"
                          r"\.toolbar\s*|\bmenu:\s*)\{")


def e3_counts_match(key, source, match):
    if key != "hl_no_form_label_button":
        return True
    for menu in E3_MENU_OPEN.finditer(source.bare):
        if menu.end() - 1 <= match.start() < matching_close(source.bare, menu.end() - 1):
            return False
    return True


def e3_render(counts):
    document = {"schema": 1, "package": E3_PACKAGE, "rules": e3_keys(),
                "counts": {key: dict(sorted(counts.get(key, {}).items())) for key in e3_keys()}}
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def e3_parse(text, where):
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise SetupError("%s is not valid JSON: %s" % (where, error)) from error
    if document.get("schema") != 1 or document.get("package") != E3_PACKAGE:
        raise SetupError("%s has the wrong schema or package" % where)
    counts = document.get("counts")
    if not isinstance(counts, dict) or not all(isinstance(v, dict) for v in counts.values()):
        raise SetupError("%s needs \"counts\": {rule: {file: count}}" % where)
    return document, counts


def e3_ratchet(repo, args):
    """(failed, grew, text to write or None) for E3.json."""
    current = e3_counts(repo)
    path = repo.root / e3_rel()
    for key in e3_keys():
        total = sum(current[key].values())
        print("design-ratchet: E3 %-32s %4d in %d files" % (key, total, len(current[key])))
    if args.init or args.force_init:
        if path.is_file() and not args.force_init:
            return False, False, None
        return False, False, e3_render(current)
    if not path.is_file():
        print("design-ratchet: FAIL %s is missing (create it with --init)" % path.name)
        return True, False, None
    try:
        document, stored = e3_parse(path.read_text(encoding="utf-8"), path.name)
    except SetupError as error:
        print("design-ratchet: FAIL %s" % error)
        return True, False, None
    failed = grew = lowered = False
    if document.get("rules") != e3_keys() or sorted(stored) != e3_keys():
        print("design-ratchet: FAIL %s lists other rules than scripts/design-ratchet.py" % path.name)
        return True, False, None
    for key in e3_keys():
        for rel in sorted(set(stored[key]) | set(current[key])):
            before, now = stored[key].get(rel, 0), current[key].get(rel, 0)
            if now > before:
                print("design-ratchet: FAIL E3 %s %s %d -> %d GREW" % (key, rel, before, now))
                grew = True
            elif now < before:
                print("design-ratchet: E3 %s %s %d -> %d %s"
                      % (key, rel, before, now, "STALE" if args.check else "lowered"))
                lowered = True
    if args.base:
        text = repo.git_show(args.base, e3_rel())
        if text is None:
            print("design-ratchet: E3.json is not at base %s; the checked-in file applies" % args.base)
        else:
            _, base = e3_parse(text, "E3 at %s" % args.base)
            for key, files in current.items():
                if key not in base:
                    continue
                for rel, now in files.items():
                    allowed = base[key].get(rel, 0)
                    if now > allowed:
                        print("design-ratchet: FAIL E3 %s %s is %d, above %d at base %s"
                              % (key, rel, now, allowed, args.base))
                        grew = True
    if grew:
        return True, True, None
    if lowered:
        return (True, False, None) if args.check else (False, False, e3_render(current))
    if path.read_text(encoding="utf-8") != e3_render(current):
        if args.check:
            print("design-ratchet: FAIL %s is not in canonical form; run scripts/design-ratchet.sh" % path.name)
            return True, False, None
        return False, False, e3_render(current)
    return failed, False, None


def check_stage3(package, markers, limits):
    """List every stage 3 marker; True when there are more than the limit."""
    for hit in markers:
        print("design-ratchet: %s stage-3 %s:%d" % (package, hit["source"].rel, hit["marker_line"]))
    if len(markers) > limits.get(STAGE3_KEY, 0):
        print("design-ratchet: FAIL %s has %d stage 3 markers, the limit is %d"
              % (package, len(markers), limits.get(STAGE3_KEY, 0)))
        return True
    return False


def print_summary(rules, current, markers):
    rows = [(r["number"], r["id"]) for r in rules] + [(n, k) for n, k, _ in F9_COUNTERS] + STRUCTURAL
    print("design-ratchet: %-4s %-32s %9s %9s %9s %9s %9s"
          % ("", "now/target", "C1", "C2", "C3", "C4", "total"))
    for number, key in rows:
        cells = []
        total = total_target = 0
        for package in PACKAGES:
            value, target = current[package][key], TARGETS.get(package, {}).get(key, 0)
            total, total_target = total + value, total_target + target
            cells.append("%d/%d" % (value, target))
        print("design-ratchet: %-4s %-32s %9s %9s %9s %9s %9s"
              % (number, key, *cells, "%d/%d" % (total, total_target)))
    cells = ["%d/%d" % (len(markers[p]), STAGE3_LIMITS[p]) for p in PACKAGES]
    print("design-ratchet: %-4s %-32s %9s %9s %9s %9s" % ("L1", STAGE3_KEY + " (limit)", *cells))


def main(argv):
    parser = argparse.ArgumentParser(prog="design-ratchet.py")
    parser.add_argument("command", choices=["ratchet", "sheets", "deletes"])
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--check", action="store_true", help="ratchet: compare only, write nothing")
    parser.add_argument("--base", help="ratchet: no count or limit may exceed the files at this commit")
    parser.add_argument("--init", action="store_true", help="ratchet: create the files that are missing")
    parser.add_argument("--force-init", action="store_true", help="ratchet: rewrite all files from the tree")
    parser.add_argument("--strict", action="store_true", help="sheets, deletes: open sites and stale exceptions fail")
    args = parser.parse_args(argv)
    ratchet_only = args.check or args.init or args.force_init or args.base
    if args.command != "ratchet" and ratchet_only:
        parser.error("--check, --base, --init and --force-init belong to the ratchet")
    if args.command == "ratchet" and args.strict:
        parser.error("--strict belongs to sheets and deletes")
    if sum([args.check, args.init, args.force_init]) > 1:
        parser.error("--check, --init and --force-init exclude each other")
    try:
        repo = Repo(args.root)
        handler = {"ratchet": command_ratchet, "sheets": command_sheets, "deletes": command_deletes}
        return handler[args.command](repo, args)
    except SetupError as error:
        for line in str(error).split("\n"):
            print("design-ratchet: ERROR %s" % line)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
