#!/usr/bin/env python3
"""Git merge driver for `.xcstrings` string catalogs (R2 3.3).

    python3 scripts/l10n/merge-xcstrings.py %O %A %B
    python3 scripts/l10n/merge-xcstrings.py --self-test

Registered once per clone (worktrees share it):

    git config merge.xcstrings.name "string catalog merge"
    git config merge.xcstrings.driver "python3 scripts/l10n/merge-xcstrings.py %O %A %B"

with `*.xcstrings merge=xcstrings` in .gitattributes.

Why: scripts/xcstrings-add.py appends new keys at the end of "strings", so two
branches that each add a key collide in the same lines and a line merge fails
every time. This driver merges by key instead:

  * keys are united; the result keeps our order and appends the keys only the
    other side has, in its order (the same shape xcstrings-add.py writes);
  * a key changed on one side only takes that change, including a deletion;
  * a key changed on both sides is merged per field and per language, each one
    three-way; only the same field or language changed differently on both
    sides (or deleted on one, changed on the other) is a conflict.

On a conflict the driver names every conflicting key and language on stderr,
leaves git's usual conflict markers in the file (via `git merge-file`) and
exits 1, so git reports the path as conflicted and nothing is lost silently.
The result is written in the separator style of our side, byte-identical to
what Xcode and xcstrings-add.py write.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True  # no __pycache__ in the checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import l10n_common as common  # noqa: E402

MISSING = object()


class Conflict(Exception):
    pass


def merged_order(ours: dict, theirs: dict) -> list:
    return list(ours) + [key for key in theirs if key not in ours]


def three_way(base, ours, theirs, where: str, conflicts: list):
    """Merge one atomic value; MISSING stands for "absent"."""
    if ours == theirs:
        return ours
    if ours == base:
        return theirs
    if theirs == base:
        return ours
    conflicts.append(where)
    return ours


def merge_mapping(base, ours, theirs, where: str, conflicts: list, atomic_children: bool, child_merge=None):
    base = base if isinstance(base, dict) else {}
    result = {}
    for key in merged_order(ours, theirs):
        b, o, t = base.get(key, MISSING), ours.get(key, MISSING), theirs.get(key, MISSING)
        if o == t or atomic_children or child_merge is None or MISSING in (o, t) or o == b or t == b:
            value = three_way(b, o, t, f"{where}{key}", conflicts)
        else:
            value = child_merge(b, o, t, f"{where}{key}", conflicts)
        if value is not MISSING:
            result[key] = value
    return result


def merge_entry(base, ours, theirs, where, conflicts):
    """Both sides changed one key: fields three-way, `localizations` per language."""
    def merge_localizations(b, o, t, w, c):
        return merge_mapping(b, o, t, w + " ", c, atomic_children=True)

    base = base if isinstance(base, dict) else {}
    result = {}
    for field in merged_order(ours, theirs):
        b, o, t = base.get(field, MISSING), ours.get(field, MISSING), theirs.get(field, MISSING)
        if field == "localizations" and isinstance(o, dict) and isinstance(t, dict):
            value = merge_localizations(b if b is not MISSING else {}, o, t, f"{where!r} language", conflicts)
        else:
            value = three_way(b, o, t, f"{where!r} field {field}", conflicts)
        if value is not MISSING:
            result[field] = value
    return result


def merge_catalogs(base: dict, ours: dict, theirs: dict) -> tuple[dict, list]:
    conflicts: list = []
    result = {}
    for field in merged_order(ours, theirs):
        b, o, t = base.get(field, MISSING), ours.get(field, MISSING), theirs.get(field, MISSING)
        if field == "strings" and isinstance(o, dict) and isinstance(t, dict):
            value = merge_mapping(b, o, t, "", conflicts, atomic_children=False, child_merge=merge_entry)
        else:
            value = three_way(b, o, t, f"top-level {field}", conflicts)
        if value is not MISSING:
            result[field] = value
    return result, conflicts


def load(path: str):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if not text.strip():
        return {}, None  # git hands an empty base when both sides added the file
    return json.loads(text), common.separator_of(text)


def merge_files(base_path: str, ours_path: str, theirs_path: str, quiet: bool = False) -> int:
    try:
        base, _ = load(base_path)
        ours, separator = load(ours_path)
        theirs, _ = load(theirs_path)
    except (ValueError, OSError) as error:
        print(f"merge-xcstrings: cannot parse a side ({error}), falling back to a line merge", file=sys.stderr)
        return line_merge(base_path, ours_path, theirs_path)
    result, conflicts = merge_catalogs(base, ours, theirs)
    if conflicts:
        if not quiet:
            print(f"merge-xcstrings: {len(conflicts)} conflict(s), both sides changed:", file=sys.stderr)
            for where in conflicts:
                print(f"  {where}", file=sys.stderr)
        line_merge(base_path, ours_path, theirs_path)
        return 1
    with open(ours_path, "w", encoding="utf-8") as handle:
        handle.write(common.dumps_catalog(result, separator or ": "))
    return 0


def line_merge(base_path: str, ours_path: str, theirs_path: str) -> int:
    code = subprocess.run(
        ["git", "merge-file", "-q", "-L", "ours", "-L", "base", "-L", "theirs", ours_path, base_path, theirs_path],
        check=False,
    ).returncode
    return 1 if code else 0


# ---------------------------------------------------------------- self-test
ADD = os.path.join(common.REPO_ROOT, "scripts", "xcstrings-add.py")
SELF = os.path.abspath(__file__)


def _add(catalog_path: str, spec: dict, tmp: str):
    # A fixed de/en list, not the live languages.json: the merge fixtures carry
    # de and en, and a language turning `required` must not change the test.
    spec_path = os.path.join(tmp, "spec.json")
    languages_path = os.path.join(tmp, "de-en-languages.json")
    with open(spec_path, "w", encoding="utf-8") as handle:
        json.dump(spec, handle)
    with open(languages_path, "w", encoding="utf-8") as handle:
        json.dump({"sourceLanguage": "en", "languages": {"de": "required", "en": "required"}}, handle)
    subprocess.run([sys.executable, ADD, spec_path, "--catalog", catalog_path, "--languages", languages_path],
                   check=True, capture_output=True)


def _git(repo: str, *args, check=True):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run(["git", "-C", repo, *args], check=check, capture_output=True, text=True, env=env)


def self_test() -> int:
    failures = []

    def check(name, condition, detail=""):
        print(f"  {'ok  ' if condition else 'FAIL'} {name}" + ("" if condition else f" {detail}"))
        if not condition:
            failures.append(name)

    base_catalog = {
        "sourceLanguage": "en",
        "strings": {
            "a.one": {"extractionState": "manual", "localizations": {
                "de": {"stringUnit": {"state": "translated", "value": "Eins"}},
                "en": {"stringUnit": {"state": "translated", "value": "One"}}}},
            "a.two": {"extractionState": "manual", "localizations": {
                "de": {"stringUnit": {"state": "translated", "value": "Zwei"}},
                "en": {"stringUnit": {"state": "translated", "value": "Two"}}}},
        },
        "version": "1.0",
    }
    add_ours = {"b.ours": {"en": "Ours", "de": "Unseres", "comment": "left"}}
    add_theirs = {"c.theirs": {"en": "Theirs", "de": "Ihres", "comment": "right"}}

    with tempfile.TemporaryDirectory() as tmp:
        def write(name, data, separator=": "):
            path = os.path.join(tmp, name)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(common.dumps_catalog(data, separator))
            return path

        def read(path):
            with open(path, encoding="utf-8") as handle:
                return handle.read()

        # 1. Two branches append a key each with xcstrings-add.py.
        base = write("base.xcstrings", base_catalog)
        ours = write("ours.xcstrings", base_catalog)
        theirs = write("theirs.xcstrings", base_catalog)
        _add(ours, add_ours, tmp)
        _add(theirs, add_theirs, tmp)
        expected = write("expected.xcstrings", base_catalog)
        _add(expected, add_ours, tmp)
        _add(expected, add_theirs, tmp)
        code = merge_files(base, ours, theirs)
        check("keys appended on both branches merge cleanly", code == 0)

        # 1b. The shipped catalogs pass through an unchanged merge byte-identical.
        for relative in common.CATALOGS:
            source = os.path.join(common.REPO_ROOT, relative)
            copy = os.path.join(tmp, "real.xcstrings")
            with open(source, encoding="utf-8") as handle, open(copy, "w", encoding="utf-8") as out:
                out.write(handle.read())
            code = merge_files(source, copy, source)
            check(f"{relative} survives a no-op merge byte-identical", code == 0 and read(copy) == read(source))
        check("result is byte-identical to xcstrings-add.py adding ours, then theirs", read(ours) == read(expected))

        # 2. Same key, same language, different values: conflict.
        def variant(change):
            data = json.loads(json.dumps(base_catalog))
            change(data["strings"])
            return data

        de = lambda s, v: s["a.one"]["localizations"]["de"]["stringUnit"].update(value=v)  # noqa: E731
        en = lambda s, v: s["a.one"]["localizations"]["en"]["stringUnit"].update(value=v)  # noqa: E731
        ours = write("ours.xcstrings", variant(lambda s: de(s, "Eins!")))
        theirs = write("theirs.xcstrings", variant(lambda s: de(s, "EINS")))
        code = merge_files(base, ours, theirs, quiet=True)
        check("same key and language changed differently on both sides conflicts", code == 1)
        check("the conflict leaves markers instead of picking a side", "<<<<<<<" in read(ours))

        # 3. Same key, different languages: clean, both kept.
        ours = write("ours.xcstrings", variant(lambda s: de(s, "Eins!")))
        theirs = write("theirs.xcstrings", variant(lambda s: en(s, "One!")))
        code = merge_files(base, ours, theirs)
        merged = json.loads(read(ours))["strings"]["a.one"]["localizations"]
        check("same key, different languages merge cleanly", code == 0 and merged["de"]["stringUnit"]["value"] == "Eins!"
              and merged["en"]["stringUnit"]["value"] == "One!")

        # 4. Same change on both sides: clean.
        ours = write("ours.xcstrings", variant(lambda s: de(s, "Eins!")))
        theirs = write("theirs.xcstrings", variant(lambda s: de(s, "Eins!")))
        check("identical change on both sides merges cleanly", merge_files(base, ours, theirs) == 0)

        # 5. Deletion on one side, untouched on the other: deleted.
        ours = write("ours.xcstrings", base_catalog)
        theirs = write("theirs.xcstrings", variant(lambda s: s.pop("a.two")))
        code = merge_files(base, ours, theirs)
        check("a key deleted on one side stays deleted", code == 0 and "a.two" not in json.loads(read(ours))["strings"])

        # 6. Deletion on one side, change on the other: conflict.
        ours = write("ours.xcstrings", variant(lambda s: s.pop("a.one")))
        theirs = write("theirs.xcstrings", variant(lambda s: de(s, "EINS")))
        check("deleted on one side, changed on the other conflicts", merge_files(base, ours, theirs, quiet=True) == 1)

        # 7. The same new key added on both sides with a different value in one language.
        ours = write("ours.xcstrings", base_catalog)
        theirs = write("theirs.xcstrings", base_catalog)
        _add(ours, {"n.key": {"en": "New", "de": "Neu"}}, tmp)
        _add(theirs, {"n.key": {"en": "New", "de": "Neues"}}, tmp)
        check("the same new key with different values conflicts", merge_files(base, ours, theirs, quiet=True) == 1)

        # 8. The separator style of our side is kept (NotificationServiceExtension uses " : ").
        base = write("base.xcstrings", base_catalog, " : ")
        ours = write("ours.xcstrings", base_catalog, " : ")
        theirs = write("theirs.xcstrings", base_catalog, " : ")
        _add(theirs, add_theirs, tmp)
        code = merge_files(base, ours, theirs)
        check("the ' : ' separator style survives", code == 0 and '"c.theirs" : {' in read(ours) and '": ' not in read(ours))

        # 9. A real `git merge` through .gitattributes and the registered driver.
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo)
        _git(repo, "init", "-q", "-b", "main")
        _git(repo, "config", "merge.xcstrings.driver", f"{sys.executable} {SELF} %O %A %B")
        with open(os.path.join(repo, ".gitattributes"), "w", encoding="utf-8") as handle:
            handle.write("*.xcstrings merge=xcstrings\n")
        catalog = os.path.join(repo, "Localizable.xcstrings")
        with open(catalog, "w", encoding="utf-8") as handle:
            handle.write(common.dumps_catalog(base_catalog))
        _git(repo, "add", ".")
        _git(repo, "commit", "-q", "-m", "base")
        _git(repo, "checkout", "-q", "-b", "left")
        _add(catalog, add_ours, tmp)
        _git(repo, "commit", "-q", "-am", "left")
        _git(repo, "checkout", "-q", "main")
        _git(repo, "checkout", "-q", "-b", "right")
        _add(catalog, add_theirs, tmp)
        _git(repo, "commit", "-q", "-am", "right")
        _git(repo, "checkout", "-q", "left")
        merge = _git(repo, "merge", "-q", "--no-edit", "right", check=False)
        check("git merge of two appending branches succeeds", merge.returncode == 0, merge.stdout + merge.stderr)
        check("git merge result equals xcstrings-add.py order", read(catalog) == read(expected))
        # Control: the same merge without the driver is the conflict it exists for.
        _git(repo, "checkout", "-q", "-b", "control", "left~1")
        _git(repo, "config", "--unset", "merge.xcstrings.driver")
        control = _git(repo, "merge", "-q", "--no-edit", "right", check=False)
        check("control: without the driver the same merge conflicts", control.returncode != 0)

    print(f"merge-xcstrings self-test: {'PASS' if not failures else 'FAIL'}")
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    return merge_files(*argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
