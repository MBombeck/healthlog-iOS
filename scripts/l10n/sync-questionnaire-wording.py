#!/usr/bin/env python3
"""Copy the questionnaire wording from the server into the app bundle.

The PHQ-9, GAD-7, WHO-5 and SCI texts are validated instruments: a changed
word changes what they measure. The server keeps them in code, one module per
instrument and language (`src/lib/mental-health/wording/<instrument>/<lang>.ts`),
each saying whether it reproduces a published validated translation (and
which one, in `source`) or is a translation written for HealthLog. The app
shows exactly that text. Nobody edits it here and it never enters a string
catalog; this script is the only way in.

    scripts/l10n/sync-questionnaire-wording.py --server-ref v1.46.6
    scripts/l10n/sync-questionnaire-wording.py --server-ref v1.46.6 --check
    scripts/l10n/sync-questionnaire-wording.py --self-test

It reads the server repository at a tag (`git show <ref>:<path>`, nothing is
checked out), finds the server repo in `--server-repo`, else
`$HEALTHLOG_SERVER_REPO`, else `../../HealthLog` from the main checkout, and
writes `HealthLog/Resources/Questionnaires/questionnaire-wording.<lang>.json`
for every case of `AppLanguage` (`HealthLog/Util/AppLanguage.swift`). Each file
names the server tag and commit, the blob of every module it was read from,
and every punctuation change it made (below). `--check` writes nothing and
fails when a file differs from what the tag gives. After a run, the SHA-256 of
each file goes into `QuestionnaireWordingLockstepTests` (the script prints
them), so a hand edit of a bundled file fails the unit suite.

Punctuation. The visible-punctuation gate allows no em dash, en dash, middle
dot, arrow or inline bullet anywhere a user reads, and gets no exception for
questionnaires. A few printed forms use them. Each such place is listed in
`PUNCTUATION` with the replacement and the reason, applied exactly once (a
place that no longer matches fails the run, so a server change is noticed),
and recorded in the output file. A range between two numbers in the SCI
answers ("46–60 min") reads as the language's range word ("46 to 60 min"),
as the app showed it since 1.3. Anything the table does not cover fails the
run instead of shipping.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the checkout

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(REPO_ROOT, "HealthLog", "Resources", "Questionnaires")
APP_LANGUAGE_SWIFT = os.path.join(REPO_ROOT, "HealthLog", "Util", "AppLanguage.swift")
WORDING_DIR = "src/lib/mental-health/wording"
GENERATOR = "scripts/l10n/sync-questionnaire-wording.py"

# Server instrument id -> folder under `src/lib/mental-health/wording/`.
INSTRUMENTS = {"PHQ9": "phq9", "GAD7": "gad7", "WHO5": "who5", "SCI": "sci"}

# What the app's `MentalHealthInstrument` expects of each instrument's text:
# item count, anchor groups with their score values, stem ids, and whether the
# PHQ-9 follow-up question is present. The server's `instruments.ts` is the
# reference; a mismatch fails the run.
SHAPE = {
    "PHQ9": {"items": 9, "anchors": {"all": range(0, 4)}, "stems": {"period"}, "functional": True},
    "GAD7": {"items": 7, "anchors": {"all": range(0, 4)}, "stems": {"period"}, "functional": False},
    "WHO5": {"items": 5, "anchors": {"all": range(0, 6)}, "stems": {"period"}, "functional": False},
    "SCI": {
        "items": 8,
        "anchors": {g: range(0, 5) for g in ("duration", "nights", "quality", "impact", "problemDuration")},
        "stems": {"night", "impact", "finally"},
        "functional": False,
    },
}

FORBIDDEN = {"·": "middle dot", "—": "em dash", "–": "en dash", "→": "arrow", "•": "bullet"}

# (language, instrument, field, printed text, shown text, reason)
PUNCTUATION = [
    (
        "en", "PHQ9", "items[5]", "yourself — or that", "yourself, or that",
        "The em dash before \"or\" becomes a comma, as the app has shown this item since 1.1.1.",
    ),
    (
        "en", "PHQ9", "items[7]", "the opposite — being", "the opposite: being",
        "The em dash after \"Or the opposite\" becomes a colon, as the app has shown this item since 1.1.1.",
    ),
    (
        "nl", "PHQ9", "items[5]", "uzelf — of het", "uzelf, of het",
        "The em dash before \"of\" becomes a comma, the same change as in the English item (R2 3.4).",
    ),
]

# Range word for "<number>–<number>" in answer labels.
RANGE_WORD = {"de": "bis", "en": "to", "nl": "tot"}
RANGE = re.compile(r"(\d)–(\d)")


# ------------------------------------------------------------------ TS literal


class ParseError(ValueError):
    pass


class _Literal:
    """A reader for the object literals in the wording modules: objects,
    arrays, strings in any quote, numbers, booleans and null, with comments
    and trailing commas. No expressions; anything else is an error."""

    def __init__(self, text: str, pos: int = 0):
        self.text, self.pos = text, pos

    def _skip(self) -> None:
        t = self.text
        while self.pos < len(t):
            if t[self.pos].isspace():
                self.pos += 1
            elif t.startswith("//", self.pos):
                end = t.find("\n", self.pos)
                self.pos = len(t) if end < 0 else end + 1
            elif t.startswith("/*", self.pos):
                end = t.find("*/", self.pos + 2)
                if end < 0:
                    raise ParseError("unterminated comment")
                self.pos = end + 2
            else:
                return

    def _peek(self) -> str:
        self._skip()
        if self.pos >= len(self.text):
            raise ParseError("unexpected end of input")
        return self.text[self.pos]

    def _expect(self, char: str) -> None:
        if self._peek() != char:
            raise ParseError(f"expected {char!r} at {self.pos}, found {self.text[self.pos]!r}")
        self.pos += 1

    def value(self):
        c = self._peek()
        if c == "{":
            return self._object()
        if c == "[":
            return self._array()
        if c in "\"'`":
            return self._string()
        m = re.compile(r"-?\d+(?:\.\d+)?|true\b|false\b|null\b").match(self.text, self.pos)
        if not m:
            raise ParseError(f"unsupported token at {self.pos}: {self.text[self.pos:self.pos + 20]!r}")
        self.pos = m.end()
        word = m.group(0)
        if word in ("true", "false"):
            return word == "true"
        if word == "null":
            return None
        return float(word) if "." in word else int(word)

    def _key(self) -> str:
        c = self._peek()
        if c in "\"'":
            return self._string()
        m = re.compile(r"[A-Za-z_$][\w$]*|\d+").match(self.text, self.pos)
        if not m:
            raise ParseError(f"bad key at {self.pos}")
        self.pos = m.end()
        return m.group(0)

    def _object(self) -> dict:
        self._expect("{")
        out: dict = {}
        while self._peek() != "}":
            key = self._key()
            if key in out:
                raise ParseError(f"duplicate key {key!r}")
            self._expect(":")
            out[key] = self.value()
            if self._peek() == ",":
                self.pos += 1
            elif self._peek() != "}":
                raise ParseError(f"expected ',' or '}}' at {self.pos}")
        self.pos += 1
        return out

    def _array(self) -> list:
        self._expect("[")
        out = []
        while self._peek() != "]":
            out.append(self.value())
            if self._peek() == ",":
                self.pos += 1
            elif self._peek() != "]":
                raise ParseError(f"expected ',' or ']' at {self.pos}")
        self.pos += 1
        return out

    def _string(self) -> str:
        quote = self.text[self.pos]
        self.pos += 1
        out = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"', "`": "`", "0": "\0"}
        while True:
            if self.pos >= len(self.text):
                raise ParseError("unterminated string")
            c = self.text[self.pos]
            if c == quote:
                self.pos += 1
                return "".join(out)
            if quote == "`" and self.text.startswith("${", self.pos):
                raise ParseError("template interpolation is not literal text")
            if c == "\\":
                n = self.text[self.pos + 1]
                if n == "u":
                    out.append(chr(int(self.text[self.pos + 2:self.pos + 6], 16)))
                    self.pos += 6
                    continue
                if n == "\n":
                    self.pos += 2
                    continue
                if n not in escapes:
                    raise ParseError(f"unsupported escape \\{n}")
                out.append(escapes[n])
                self.pos += 2
                continue
            if c == "\n" and quote != "`":
                raise ParseError("newline in string")
            out.append(c)
            self.pos += 1


def parse_wording_module(source: str) -> dict:
    """The `wording` object of one `<instrument>/<lang>.ts` module."""
    m = re.search(r"const\s+wording\s*:\s*InstrumentWording\s*=\s*", source)
    if not m:
        raise ParseError("no `const wording: InstrumentWording =` in module")
    reader = _Literal(source, m.end())
    value = reader.value()
    if reader._peek() != ";":
        raise ParseError("the wording object is not followed by ';'")
    if not re.search(r"export\s+default\s+wording\s*;", source[reader.pos:]):
        raise ParseError("module does not `export default wording`")
    return value


# ------------------------------------------------------------------ shaping


def check_shape(instrument: str, wording: dict, where: str) -> None:
    shape = SHAPE[instrument]
    allowed = {"validated", "source", "stems", "items", "anchors", "functional"}
    extra = set(wording) - allowed
    if extra:
        raise SystemExit(f"{where}: unknown fields {sorted(extra)}")
    if not isinstance(wording.get("validated"), bool):
        raise SystemExit(f"{where}: `validated` is not a boolean")
    if wording["validated"] != bool(wording.get("source")):
        raise SystemExit(f"{where}: a validated text needs a `source`, an unvalidated one has none")
    items = wording.get("items")
    if not (isinstance(items, list) and len(items) == shape["items"] and all(isinstance(i, str) and i for i in items)):
        raise SystemExit(f"{where}: expected {shape['items']} non-empty items")
    if set(wording.get("stems", {})) != shape["stems"]:
        raise SystemExit(f"{where}: stems {sorted(wording.get('stems', {}))} != {sorted(shape['stems'])}")
    anchors = wording.get("anchors", {})
    if set(anchors) != set(shape["anchors"]):
        raise SystemExit(f"{where}: anchor groups {sorted(anchors)} != {sorted(shape['anchors'])}")
    for group, values in shape["anchors"].items():
        if sorted(int(k) for k in anchors[group]) != list(values):
            raise SystemExit(f"{where}: anchors.{group} values {sorted(anchors[group])} != {list(values)}")
    functional = wording.get("functional")
    if shape["functional"] != (functional is not None):
        raise SystemExit(f"{where}: functional follow-up {'missing' if shape['functional'] else 'unexpected'}")
    if functional is not None:
        if not functional.get("title") or sorted(int(k) for k in functional.get("anchors", {})) != [0, 1, 2, 3]:
            raise SystemExit(f"{where}: functional follow-up needs a title and anchors 0 to 3")


def shaped(wording: dict) -> dict:
    """Fixed key order, anchor values as strings in score order."""
    out = {"validated": wording["validated"], "source": wording.get("source")}
    out["stems"] = {k: wording["stems"][k] for k in sorted(wording["stems"])}
    out["items"] = list(wording["items"])
    out["anchors"] = {
        group: {str(k): v for k, v in sorted(((int(k), v) for k, v in values.items()))}
        for group, values in sorted(wording["anchors"].items())
    }
    if wording.get("functional") is not None:
        f = wording["functional"]
        out["functional"] = {
            "title": f["title"],
            "anchors": {str(k): v for k, v in sorted(((int(k), v) for k, v in f["anchors"].items()))},
        }
    return out


def _texts(wording: dict):
    """(field path, text) for everything a reader sees."""
    for k, v in wording["stems"].items():
        yield f"stems.{k}", v
    for i, v in enumerate(wording["items"]):
        yield f"items[{i}]", v
    for group, values in wording["anchors"].items():
        for k, v in values.items():
            yield f"anchors.{group}.{k}", v
    if "functional" in wording:
        yield "functional.title", wording["functional"]["title"]
        for k, v in wording["functional"]["anchors"].items():
            yield f"functional.anchors.{k}", v


def _set(wording: dict, path: str, value: str) -> None:
    m = re.fullmatch(r"items\[(\d+)\]", path)
    if m:
        wording["items"][int(m.group(1))] = value
        return
    parts = path.split(".")
    node = wording
    for part in parts[:-1]:
        node = node[part]
    node[parts[-1]] = value


def apply_punctuation(language: str, instrument: str, wording: dict, table=PUNCTUATION) -> list:
    """Apply the table and the range rule; return what changed. Fails on a
    table entry that does not match exactly once, and on any forbidden
    character left over."""
    changes = []
    for lang, inst, path, old, new, reason in table:
        if (lang, inst) != (language, instrument):
            continue
        current = dict(_texts(wording)).get(path)
        if current is None or current.count(old) != 1:
            raise SystemExit(
                f"{instrument}/{language} {path}: punctuation entry {old!r} no longer matches exactly once; "
                "re-read the server text and update PUNCTUATION"
            )
        _set(wording, path, current.replace(old, new))
        changes.append({"field": path, "printed": old, "shown": new, "reason": reason})
    for path, text in list(_texts(wording)):
        if not path.startswith("anchors.") or not RANGE.search(text):
            continue
        word = RANGE_WORD.get(language)
        if word is None:
            raise SystemExit(f"{instrument}/{language} {path}: no range word for {language!r} in RANGE_WORD")
        shown = RANGE.sub(lambda m: f"{m.group(1)} {word} {m.group(2)}", text)
        _set(wording, path, shown)
        changes.append({
            "field": path, "printed": text, "shown": shown,
            "reason": f"A range between two numbers reads with the range word \"{word}\" instead of an en dash.",
        })
    for path, text in _texts(wording):
        for char, name in FORBIDDEN.items():
            if char in text:
                raise SystemExit(
                    f"{instrument}/{language} {path}: {name} {char!r} in {text!r}; "
                    "the punctuation gate allows none, add a reasoned entry to PUNCTUATION"
                )
    return changes


# ------------------------------------------------------------------ server


def app_languages() -> list:
    with open(APP_LANGUAGE_SWIFT, encoding="utf-8") as handle:
        body = handle.read()
    enum = re.search(r"enum AppLanguage\b[^{]*\{(.*?)\n\}", body, re.S)
    if not enum:
        raise SystemExit("AppLanguage enum not found")
    cases = re.findall(r"^\s*case\s+([a-z]{2}(?:_[A-Za-z]+)?)\s*$", enum.group(1), re.M)
    if not cases:
        raise SystemExit("AppLanguage has no cases")
    return cases


def server_language_file(language: str) -> str:
    """App language code -> server wording module name (`pt-BR` -> `pt-br`)."""
    return language.replace("_", "-").lower()


def git(repo: str, *args: str) -> str:
    result = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed in {repo}: {result.stderr.strip()}")
    return result.stdout


def default_server_repo() -> str:
    """`$HEALTHLOG_SERVER_REPO`, else `HealthLog` two levels above the main
    checkout (worktrees resolve to their main checkout first)."""
    if os.environ.get("HEALTHLOG_SERVER_REPO"):
        return os.environ["HEALTHLOG_SERVER_REPO"]
    common = git(REPO_ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    return os.path.normpath(os.path.join(os.path.dirname(common), "..", "..", "HealthLog"))


def build(server_repo: str, ref: str) -> dict:
    """{language: (file name, rendered JSON text)} for every app language."""
    commit = git(server_repo, "rev-parse", f"{ref}^{{commit}}").strip()
    index = git(server_repo, "show", f"{commit}:{WORDING_DIR}/index.ts")
    imported = set(re.findall(r'from\s+"\./([a-z0-9]+)/([a-z-]+)"', index))
    outputs = {}
    for language in app_languages():
        server_lang = server_language_file(language)
        instruments = {}
        punctuation = []
        for instrument, folder in INSTRUMENTS.items():
            if (folder, server_lang) not in imported:
                raise SystemExit(f"{ref}: {WORDING_DIR}/index.ts does not register {folder}/{server_lang}")
            path = f"{WORDING_DIR}/{folder}/{server_lang}.ts"
            where = f"{ref}:{path}"
            try:
                wording = parse_wording_module(git(server_repo, "show", f"{commit}:{path}"))
            except ParseError as error:
                raise SystemExit(f"{where}: {error}") from None
            check_shape(instrument, wording, where)
            wording = shaped(wording)
            for change in apply_punctuation(language, instrument, wording):
                punctuation.append({"instrument": instrument, **change})
            instruments[instrument] = {
                "serverFile": path,
                "serverBlob": git(server_repo, "rev-parse", f"{commit}:{path}").strip(),
                **wording,
            }
        document = {
            "_doc": (
                "Questionnaire wording copied from the HealthLog server. Do not edit: run "
                f"{GENERATOR} --server-ref <tag>. See docs/localization.md."
            ),
            "language": language,
            "serverRef": ref,
            "serverCommit": commit,
            "generator": GENERATOR,
            "punctuation": punctuation,
            "instruments": instruments,
        }
        text = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
        outputs[language] = (f"questionnaire-wording.{language}.json", text)
    return outputs


# ------------------------------------------------------------------ self-test


def self_test() -> int:
    failures = []
    ran = []

    def case(name, fn):
        ran.append(name)
        try:
            fn()
        except Exception as error:  # noqa: BLE001 - every failure is a finding
            failures.append(f"{name}: {error!r}")

    module = """/**
 * comment with "quotes" and a // slash
 */
import type { InstrumentWording } from "../types";

const wording: InstrumentWording = {
  validated: true,
  source:
    'He said "hi", it\\'s fine', // trailing comment
  stems: { period: "Over \\u2026" },
  items: ["a", "b",],
  anchors: { all: { 0: "x", 1: `y` } },
};

export default wording;
"""

    def parses():
        w = parse_wording_module(module)
        assert w["source"] == "He said \"hi\", it's fine", w["source"]
        assert w["stems"]["period"] == "Over …"
        assert w["items"] == ["a", "b"]
        assert w["anchors"] == {"all": {"0": "x", "1": "y"}}

    def rejects(text, label):
        try:
            parse_wording_module(text)
        except ParseError:
            return
        raise AssertionError(f"{label} accepted")

    case("parses a module", parses)
    case("rejects an expression", lambda: rejects("const wording: InstrumentWording = { a: b };\nexport default wording;", "expr"))
    case("rejects interpolation", lambda: rejects("const wording: InstrumentWording = { a: `${x}` };\nexport default wording;", "tmpl"))
    case("rejects a duplicate key", lambda: rejects("const wording: InstrumentWording = { a: 1, a: 2 };\nexport default wording;", "dup"))
    case("rejects a module without export", lambda: rejects("const wording: InstrumentWording = { a: 1 };\n", "export"))

    def phq(item6):
        return shaped({
            "validated": True, "source": "s", "stems": {"period": "p"},
            "items": ["1", "2", "3", "4", "5", item6, "7", "8", "9"],
            "anchors": {"all": {0: "a", 1: "b", 2: "c", 3: "d"}},
            "functional": {"title": "t", "anchors": {0: "a", 1: "b", 2: "c", 3: "d"}},
        })

    def table_applies():
        w = phq("Een slecht gevoel hebben over uzelf — of het gevoel")
        changes = apply_punctuation("nl", "PHQ9", w)
        assert w["items"][5] == "Een slecht gevoel hebben over uzelf, of het gevoel", w["items"][5]
        assert len(changes) == 1 and changes[0]["field"] == "items[5]"

    def stale_entry_fails():
        try:
            apply_punctuation("nl", "PHQ9", phq("no dash here"))
        except SystemExit:
            return
        raise AssertionError("a stale table entry passed")

    def stray_dash_fails():
        w = phq("x")
        w["items"][2] = "a — b"
        try:
            apply_punctuation("de", "PHQ9", w)
        except SystemExit:
            return
        raise AssertionError("an uncovered em dash passed")

    def range_rule():
        w = shaped({
            "validated": False, "source": None, "stems": {"night": "n", "impact": "i", "finally": "f"},
            "items": ["1", "2", "3", "4", "5", "6", "7", "8"],
            "anchors": {
                "duration": {0: "≥ 61 Min.", 1: "46–60 Min.", 2: "a", 3: "b", 4: "0–15 Min."},
                "nights": {0: "5–7", 1: "4", 2: "3", 3: "2", 4: "0–1"},
                "quality": {k: "q" for k in range(5)}, "impact": {k: "i" for k in range(5)},
                "problemDuration": {0: "> 1 Jahr", 1: "7–12 Monate", 2: "c", 3: "d", 4: "e"},
            },
        })
        changes = apply_punctuation("de", "SCI", w)
        assert w["anchors"]["duration"]["1"] == "46 bis 60 Min.", w["anchors"]["duration"]["1"]
        assert w["anchors"]["nights"]["0"] == "5 bis 7"
        assert w["anchors"]["problemDuration"]["1"] == "7 bis 12 Monate"
        assert len(changes) == 5, changes

    def range_in_item_fails():
        w = phq("x")
        w["items"][0] = "1–2 times"
        try:
            apply_punctuation("en", "PHQ9", phq("yourself — or that") | {"items": w["items"]})
        except SystemExit:
            return
        raise AssertionError("an en dash outside the answers passed")

    def shape_guard():
        try:
            check_shape("GAD7", {"validated": True, "source": "s", "stems": {"period": "p"},
                                 "items": ["x"] * 6, "anchors": {"all": {0: "", 1: "", 2: "", 3: ""}}}, "t")
        except SystemExit:
            return
        raise AssertionError("six GAD-7 items passed")

    def unvalidated_with_source_fails():
        try:
            check_shape("GAD7", {"validated": False, "source": "s", "stems": {"period": "p"},
                                 "items": ["x"] * 7, "anchors": {"all": {0: "", 1: "", 2: "", 3: ""}}}, "t")
        except SystemExit:
            return
        raise AssertionError("an unvalidated text with a source passed")

    case("table entry applies once", table_applies)
    case("stale table entry fails", stale_entry_fails)
    case("uncovered dash fails", stray_dash_fails)
    case("range rule in answers", range_rule)
    case("en dash outside answers fails", range_in_item_fails)
    case("shape guard", shape_guard)
    case("unvalidated with source fails", unvalidated_with_source_fails)
    case("app languages parse", lambda: app_languages())

    total = len(ran)
    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        print(f"sync-questionnaire-wording self-test: {total - len(failures)}/{total} passed", file=sys.stderr)
        return 1
    print(f"sync-questionnaire-wording self-test: PASS {total}/{total}")
    return 0


# ------------------------------------------------------------------ main


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--server-ref", help="server tag to read, e.g. v1.46.6")
    ap.add_argument("--server-repo", default=None, help="path to the HealthLog server repository")
    ap.add_argument("--check", action="store_true", help="write nothing, fail on any difference")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if not a.server_ref:
        ap.error("--server-ref is required")
    repo = a.server_repo or default_server_repo()
    if not os.path.isdir(os.path.join(repo, ".git")) and not os.path.isfile(os.path.join(repo, ".git")):
        raise SystemExit(f"no server repository at {repo}; pass --server-repo or set HEALTHLOG_SERVER_REPO")
    outputs = build(repo, a.server_ref)
    differs = []
    for language, (name, text) in outputs.items():
        path = os.path.join(OUT_DIR, name)
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if a.check:
            if current != text:
                differs.append(name)
            continue
        os.makedirs(OUT_DIR, exist_ok=True)
        if current != text:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
        print(f"{name}  sha256 {digest}")
    stale = sorted(
        f for f in (os.listdir(OUT_DIR) if os.path.isdir(OUT_DIR) else [])
        if f.endswith(".json") and f not in {name for name, _ in outputs.values()}
    )
    if stale:
        print(f"files for no AppLanguage case: {stale}", file=sys.stderr)
        return 1
    if differs:
        print(f"differs from {a.server_ref}: {differs}; run without --check", file=sys.stderr)
        return 1
    if a.check:
        print(f"questionnaire wording matches {a.server_ref} for {sorted(outputs)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
