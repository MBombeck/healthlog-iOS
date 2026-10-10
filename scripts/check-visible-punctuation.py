#!/usr/bin/env python3
"""Visible-punctuation gate (U5, 1.1.1): no "·", "—", "–", "→" or inline "•"
in anything a user reads.

A middle dot as separator, em/en dashes and arrows make interface text read
like a template rather than a sentence. 1.1.1 rewrote ~800 catalog values and every
Swift-composed string; this gate keeps them from coming back.

What is checked
  1. Every string catalog in the repo (`git ls-files '*.xcstrings'`), every
     localization, every `stringUnit` value, including plural/device
     variations and substitutions.
  2. `InfoPlist.strings` values and the `NS…UsageDescription` values in
     `project.yml` (the permission prompts).
  3. Swift string literals in the shipping targets (HealthLog, HealthLogWatch,
     HealthLogWidgets, HealthLogWatchWidgets, NotificationServiceExtension).
     The scan uses a small Swift lexer, so comments (`//`, `///`, nested
     `/* */`) and multi-line `\"\"\"` literals are handled exactly.

Not flagged (by construction, not by allowlist)
  * A value or literal that is only a dash ("—" / "–"): the empty-cell
    placeholder of a table or row, not prose.
  * A run of three or more "•" / "·": a masked secret ("••••••••").
  * Swift literals that ARE a catalog key (the catalog value is what renders
    and is checked in 1.). Interpolations are matched as format specifiers,
    the same way `check-strings.sh` does; a key must contain a letter, so a
    bare `"\\(a) · \\(b)"` never passes as a key.
  * Swift literals passed as `comment:`, inside a log/assert call
    (`HLLog…`, `Logger`, `print`, `os_log`, `fatalError`, `assert…`,
    `precondition…`), inside `#Preview { … }` or an `#if DEBUG` region.
  * Test targets.

Allowlist: `scripts/visible-punctuation-allowlist.json`. Each entry names a
`path`, optionally a `contains` substring of the literal (without it the whole
file is exempt), and a `reason`. Entries are matched exactly and an unused
entry fails the gate, so the list can only shrink.

Usage
  scripts/check-visible-punctuation.py              # check, exit 1 on findings
  scripts/check-visible-punctuation.py --self-test  # prove the detector bites
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile

FORBIDDEN = re.compile(r"[·—–→•]")
MASK_RUN = re.compile(r"[•·]{3,}")
LONE_DASHES = {"—", "–"}
SWIFT_ROOTS = (
    "HealthLog/",
    "HealthLogWatch/",
    "HealthLogWidgets/",
    "HealthLogWatchWidgets/",
    "NotificationServiceExtension/",
)
ALLOWLIST_PATH = "scripts/visible-punctuation-allowlist.json"
LOG_CALLEE = re.compile(
    r"(?:^|\.)(?:debug|info|notice|warning|error|fault|trace|critical|log)$"
    r"|^(?:print|debugPrint|os_log|NSLog|fatalError|assert|assertionFailure|"
    r"precondition|preconditionFailure|dump)$"
)
LOG_RECEIVER = re.compile(r"\b(?:HLLog|[lL]ogger|log|os_log|Self\.log|self\.log)\b")
SPECIFIER = r"%(?:\d+\$)?(?:lld|ld|llu|lu|d|u|@|f|\.\d+f|ld)"


def offending(value: str) -> list[str]:
    """Forbidden characters a user would see in `value` (masks and lone dashes excluded)."""
    if value.strip() in LONE_DASHES:
        return []
    return FORBIDDEN.findall(MASK_RUN.sub("", value))


# --------------------------------------------------------------------------
# Catalogs
# --------------------------------------------------------------------------


def _string_units(node, path):
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if isinstance(unit, dict):
            yield path, unit.get("value", "")
        for key, child in node.items():
            if key != "stringUnit":
                yield from _string_units(child, path + [key])
    elif isinstance(node, list):
        for index, child in enumerate(node):
            yield from _string_units(child, path + [str(index)])


def catalog_findings(path: str) -> tuple[list[str], set[str]]:
    with open(path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    findings = []
    keys = set(catalog.get("strings", {}))
    for key, entry in catalog.get("strings", {}).items():
        for lang, loc in entry.get("localizations", {}).items():
            for unit_path, value in _string_units(loc, [lang]):
                if offending(value):
                    findings.append(f"{path}: {key!r} [{'/'.join(unit_path)}] = {value!r}")
    return findings, keys


def strings_file_findings(path: str) -> list[str]:
    findings = []
    pattern = re.compile(r'^\s*"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            match = pattern.match(line)
            if match and offending(match.group(2)):
                findings.append(f"{path}:{number}: {match.group(1)} = {match.group(2)!r}")
    return findings


def project_yml_findings(path: str) -> list[str]:
    findings = []
    pattern = re.compile(r"^\s*(NS\w+UsageDescription):\s*(.*)$")
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            match = pattern.match(line)
            if match and offending(match.group(2)):
                findings.append(f"{path}:{number}: {match.group(1)} = {match.group(2).strip()!r}")
    return findings


# --------------------------------------------------------------------------
# Swift lexer
# --------------------------------------------------------------------------


class Literal:
    __slots__ = ("start", "end", "content")

    def __init__(self, start: int, end: int, content: str):
        self.start, self.end, self.content = start, end, content


def lex_swift(source: str) -> tuple[str, list[Literal]]:
    """Return (masked code, top-level string literals).

    The masked code keeps every character position; comments and literal
    contents become spaces, so bracket matching on it is exact.
    """
    masked = list(source)
    literals: list[Literal] = []
    n = len(source)

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if masked[k] != "\n":
                masked[k] = " "

    def skip_block_comment(i: int) -> int:
        depth = 0
        while i < n:
            if source.startswith("/*", i):
                depth += 1
                i += 2
            elif source.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        return n

    def scan_code(i: int, stop_at_paren: bool) -> int:
        """Scan code from i; with stop_at_paren, return just past the `)` closing an interpolation."""
        depth = 0
        while i < n:
            c = source[i]
            if source.startswith("//", i):
                j = source.find("\n", i)
                j = n if j < 0 else j
                blank(i, j)
                i = j
            elif source.startswith("/*", i):
                j = skip_block_comment(i)
                blank(i, j)
                i = j
            elif c == '"' or (c == "#" and re.match(r'#+"', source[i:])):
                j, _ = scan_string(i)
                if not stop_at_paren:
                    literals.append(Literal(i, j, source[i:j]))
                i = j
            elif stop_at_paren and c == "(":
                depth += 1
                i += 1
            elif stop_at_paren and c == ")":
                if depth == 0:
                    return i + 1
                depth -= 1
                i += 1
            else:
                i += 1
        return n

    def scan_string(i: int) -> tuple[int, str]:
        hashes = 0
        while source[i] == "#":
            hashes += 1
            i += 1
        multiline = source.startswith('"""', i)
        opener = '"""' if multiline else '"'
        i += len(opener)
        closer = opener + "#" * hashes
        escape = "\\" + "#" * hashes
        while i < n:
            if source.startswith(escape + "(", i):
                i = scan_code(i + len(escape) + 1, stop_at_paren=True)
            elif source.startswith(escape, i):
                i += len(escape) + 1
            elif source.startswith(closer, i):
                return i + len(closer), opener
            elif not multiline and source[i] == "\n":
                return i, opener  # unterminated single-line literal: stop at line end
            else:
                i += 1
        return n, opener

    scan_code(0, stop_at_paren=False)
    for literal in literals:
        blank(literal.start + 1, literal.end - 1)
    return "".join(masked), literals


def debug_regions(source: str) -> list[tuple[int, int]]:
    """Character ranges inside `#if DEBUG … #endif` (nested `#if` respected)."""
    regions, stack, offset = [], [], 0
    for line in source.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith("#if"):
            stack.append((offset, stripped.startswith("#if DEBUG")))
        elif stripped.startswith("#endif") and stack:
            start, is_debug = stack.pop()
            if is_debug:
                regions.append((start, offset + len(line)))
        offset += len(line)
    return regions


def enclosing_contexts(masked: str, position: int, limit: int = 12) -> list[str]:
    """Callee/opener text of the brackets enclosing `position`, innermost first."""
    contexts = []
    depth = {"(": 0, "{": 0, "[": 0}
    closer_of = {")": "(", "}": "{", "]": "["}
    i = position - 1
    while i >= 0 and len(contexts) < limit:
        c = masked[i]
        if c in closer_of:
            depth[closer_of[c]] += 1
        elif c in depth:
            if depth[c] > 0:
                depth[c] -= 1
            else:
                # `HLLog.api\n    .warning(` → `HLLog.api.warning(`
                head = re.sub(r"\s+(?=\.)", "", masked[max(0, i - 200) : i])
                if c == "{":
                    # what introduces this block: `#Preview(...) {`, `#Preview {`, a func, …
                    contexts.append("{" + _block_head(masked, i))
                else:
                    match = re.search(r"([#\w.]+)\s*$", head)
                    contexts.append(c + (match.group(1) if match else ""))
        i -= 1
    return contexts


def _block_head(masked: str, brace: int) -> str:
    i = brace - 1
    while i >= 0 and masked[i] in " \t\n":
        i -= 1
    if i >= 0 and masked[i] == ")":
        depth = 0
        while i >= 0:
            if masked[i] == ")":
                depth += 1
            elif masked[i] == "(":
                depth -= 1
                if depth == 0:
                    break
            i -= 1
        i -= 1
    j = i
    while j >= 0 and (masked[j].isalnum() or masked[j] in "_.#"):
        j -= 1
    return masked[j + 1 : i + 1]


def literal_text(raw: str) -> str:
    """The literal's content with interpolations replaced by `\\x00`."""
    body = raw.lstrip("#")
    hashes = len(raw) - len(body)
    quote = '"""' if body.startswith('"""') else '"'
    body = body[len(quote) : len(body) - len(quote) - hashes] if body.endswith(quote + "#" * hashes) else body[len(quote) :]
    if quote == '"""':
        # Swift's rules: drop the opening line break, strip the closing
        # delimiter's indentation from every line.
        lines = body.split("\n")
        indent = lines[-1] if not lines[-1].strip() else ""
        lines = lines[1:-1] if not lines[-1].strip() else lines[1:]
        body = "\n".join(line[len(indent) :] if line.startswith(indent) else line.lstrip() for line in lines)
    out, i, escape = [], 0, "\\" + "#" * hashes
    while i < len(body):
        if body.startswith(escape + "(", i):
            depth, i = 1, i + len(escape) + 1
            while i < len(body) and depth:
                depth += {"(": 1, ")": -1}.get(body[i], 0)
                i += 1
            out.append("\x00")
        elif body.startswith(escape, i) and i + len(escape) < len(body):
            nxt = body[i + len(escape)]
            out.append({"n": "\n", "t": "\t", "0": "\x00", "\n": ""}.get(nxt, nxt))
            i += len(escape) + 1
        else:
            out.append(body[i])
            i += 1
    return "".join(out)


def is_catalog_key(text: str, keys: set[str], localized_call: bool = False) -> bool:
    # Outside an explicit `localized:` argument a key must carry a word, so a
    # verbatim join like "\(a) · \(b)" can never hide behind a "%@ · %@" key.
    if not localized_call and not re.search(r"[A-Za-zÄÖÜäöüß]", text.replace("\x00", "")):
        return False
    if "\x00" not in text:
        return text in keys
    pattern = re.compile("^" + SPECIFIER.join(re.escape(part) for part in text.split("\x00")) + "$")
    return any(pattern.match(key) for key in keys)


def swift_findings(path: str, source: str, keys: set[str]) -> list[tuple[str, int, str]]:
    masked, literals = lex_swift(source)
    debug = debug_regions(source)
    findings = []
    for literal in literals:
        text = literal_text(literal.content)
        if text.strip() in LONE_DASHES or not offending(text.replace("\x00", "x")):
            continue
        if any(a <= literal.start < b for a, b in debug):
            continue
        before = masked[max(0, literal.start - 40) : literal.start]
        if re.search(r"\bcomment:\s*$", before):
            continue
        contexts = enclosing_contexts(masked, literal.start)
        if any(ctx.startswith("{#Preview") or ctx.startswith("(#Preview") for ctx in contexts):
            continue
        if any(
            ctx.startswith("(") and (LOG_CALLEE.search(ctx[1:]) and (LOG_RECEIVER.search(ctx[1:]) or "." not in ctx[1:]))
            for ctx in contexts
        ):
            continue
        if is_catalog_key(text, keys, localized_call=bool(re.search(r"\blocalized:\s*$", before))):
            continue
        line = source.count("\n", 0, literal.start) + 1
        findings.append((path, line, literal.content))
    return findings


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------


def git_files(pattern: str) -> list[str]:
    output = subprocess.check_output(["git", "ls-files", pattern], text=True)
    return [line for line in output.splitlines() if line]


def load_allowlist(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    entries = data.get("entries", [])
    for entry in entries:
        if not entry.get("path") or not entry.get("reason"):
            raise SystemExit(f"{path}: every entry needs `path` and `reason`: {entry}")
    return entries


def run(root: str, allowlist_path: str) -> int:
    os.chdir(root)
    problems: list[str] = []
    keys: set[str] = set()
    for catalog in git_files("*.xcstrings"):
        found, catalog_keys = catalog_findings(catalog)
        problems += found
        keys |= catalog_keys
    for strings in git_files("*InfoPlist.strings"):
        problems += strings_file_findings(strings)
    if os.path.exists("project.yml"):
        problems += project_yml_findings("project.yml")

    allowlist = load_allowlist(allowlist_path)
    used = [False] * len(allowlist)
    for swift in git_files("*.swift"):
        if not swift.startswith(SWIFT_ROOTS) or "Tests/" in swift:
            continue
        with open(swift, encoding="utf-8") as handle:
            source = handle.read()
        for path, line, raw in swift_findings(swift, source, keys):
            allowed = False
            for index, entry in enumerate(allowlist):
                if entry["path"] == path and entry.get("contains", "") in raw:
                    used[index] = allowed = True
            if not allowed:
                problems.append(f"{path}:{line}: {raw[:140]}")

    for index, entry in enumerate(allowlist):
        if not used[index]:
            problems.append(f"{allowlist_path}: unused entry {entry['path']} {entry.get('contains', '')!r}; remove it")

    if problems:
        print(f"visible-punctuation: {len(problems)} finding(s). Use a comma, colon, period, parentheses, "
              "'bis'/'to' for ranges, or a layout gap instead of · — – → •:")
        for problem in problems:
            print("  " + problem)
        return 1
    print("visible-punctuation: clean.")
    return 0


def self_test() -> int:
    swift_bad = {
        "a.swift": 'let s = "\\(a) · \\(b)"\n',
        "b.swift": 'Text(verbatim: "Saved — will sync")\n',
        "c.swift": 'let r = "\\(lo)–\\(hi)"\n',
        "d.swift": 'let m = """\n    Step 1 → Step 2\n    """\n',
        "e.swift": 'let x = items.joined(separator: " • ")\n',
    }
    swift_good = {
        "f.swift": '// Comment with — and · is fine\nlet s = "\\(a), \\(b)"\n',
        "g.swift": 'HLLog.sync.error("retry failed — \\(e)")\n',
        "h.swift": 'Text(String(localized: "Target \\(lo)–\\(hi)", comment: "A — B"))\n',
        "i.swift": '#Preview("Tile — empty") {\n    Text(verbatim: "Demo · data")\n}\n',
        "j.swift": '#if DEBUG\nlet demo = "a · b"\n#endif\n',
        "k.swift": 'let placeholder = "—"\nlet mask = "••••"\n',
        "l.swift": '/* block /* nested — */ still comment · */\nlet ok = "fine"\n',
    }
    keys = {"Target %@–%@"}
    failures = []
    for name, src in swift_bad.items():
        if not swift_findings(name, src, keys):
            failures.append(f"missed a violation in {name}: {src!r}")
    for name, src in swift_good.items():
        found = swift_findings(name, src, keys)
        if found:
            failures.append(f"false positive in {name}: {found}")
    for value, expected in [("A · B", True), ("—", False), ("•••••• (saved)", False), ("1 to 5", False), ("x → y", True)]:
        if bool(offending(value)) != expected:
            failures.append(f"offending({value!r}) != {expected}")

    with tempfile.TemporaryDirectory() as tmp:
        subprocess.check_call(["git", "init", "-q", tmp])
        os.makedirs(os.path.join(tmp, "HealthLog"))
        with open(os.path.join(tmp, "HealthLog", "Localizable.xcstrings"), "w", encoding="utf-8") as handle:
            json.dump({"sourceLanguage": "en", "strings": {"k": {"localizations": {
                "de": {"variations": {"plural": {"one": {"stringUnit": {"state": "translated", "value": "%lld Tag · ok"}},
                                                 "other": {"stringUnit": {"state": "translated", "value": "%lld Tage"}}}}},
                "en": {"stringUnit": {"state": "translated", "value": "ok"}}}}}}, handle)
        subprocess.check_call(["git", "-C", tmp, "add", "."])
        cwd = os.getcwd()
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                status = run(tmp, os.path.join(tmp, "none.json"))
            if status != 1:
                failures.append("a plural variant with · was not flagged")
        finally:
            os.chdir(cwd)

    if failures:
        print("visible-punctuation self-test FAILED:")
        for failure in failures:
            print("  " + failure)
        return 1
    print("visible-punctuation self-test: ok.")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    return run(root, ALLOWLIST_PATH)


if __name__ == "__main__":
    sys.exit(main())
