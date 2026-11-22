#!/usr/bin/env python3
"""Privacy-manifest gate: every shipped binary declares the required-reason
APIs its own source closure calls.

Apple checks each binary of an upload separately (ITMS-91053). The app, the
widget extension, the notification service extension and the two watch
targets compile different subsets of `HealthLog/`, so one manifest per binary
has to match that binary's sources, not the app's. This gate reads the source
closure of each target from `project.yml`, scans its Swift files for the API
symbols Apple lists per category, and compares the result with the target's
`PrivacyInfo.xcprivacy`.

Fails on
  * a category the closure uses that the manifest does not declare (or a
    target that uses one and ships no manifest at all),
  * a reason code that is not one of Apple's codes for that category,
  * `UserDefaults(suiteName:)` in the closure without reason 1C8F.1 (App Group
    access is not covered by CA92.1),
  * `NSPrivacyTracking` true or a non-empty tracking domain list.

Reports, without failing, a category that is declared but not found in the
closure: declaring more than the scan sees is the safe direction, and some
uses (a dependency, a symbol the scan does not know) are invisible here.

Source: Apple, "Describing use of required reason API"
https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api

Usage
  scripts/check-privacy-manifests.py              # check the repository
  scripts/check-privacy-manifests.py --self-test  # prove the gate bites
Exit: 0 clean, 1 findings, 2 usage or input error.
"""

from __future__ import annotations

import fnmatch
import os
import plistlib
import re
import shutil
import sys
import tempfile

try:
    import yaml
except ImportError:  # pragma: no cover - environment problem, not a finding
    print("check-privacy-manifests: PyYAML is required (python3 -m pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

# Shipped targets and where their manifest lives. `None` means the target
# ships without one, which is only fine while its closure calls none of the
# categories below.
TARGETS = {
    "HealthLog": "HealthLog/Resources/PrivacyInfo.xcprivacy",
    "HealthLogWidgets": "HealthLogWidgets/Resources/PrivacyInfo.xcprivacy",
    "HealthLogNotificationService": "NotificationServiceExtension/Resources/PrivacyInfo.xcprivacy",
    "HealthLogWatch": None,
    "HealthLogWatchWidgets": None,
}

# Apple's symbols per category, as patterns over comment-free Swift.
CATEGORY_PATTERNS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|\bNSUserDefaults\b|@AppStorage\b",
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        r"\.(?:creationDate|modificationDate|fileModificationDate)\b"
        r"|\bcontentModificationDate(?:Key)?\b|\bcreationDateKey\b"
        r"|\b(?:f|l)?getattrlist(?:bulk|at)?\s*\(|\b(?:f|l)?stat(?:at)?\s*\("
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": r"\bsystemUptime\b|\bmach_absolute_time\s*\(",
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        r"\bvolumeAvailableCapacity(?:ForImportantUsage|ForOpportunisticUsage)?(?:Key)?\b"
        r"|\bvolumeTotalCapacity(?:Key)?\b|\bsystemFreeSize\b|\bsystemSize\b"
        r"|\b(?:f)?statv?fs\s*\("
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"\bactiveInputModes\b",
}

# Apple's reason codes per category.
VALID_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
}

APP_GROUP_DEFAULTS = re.compile(r"\bUserDefaults\s*\(\s*suiteName\s*:")

COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
STRING = re.compile(r'"""(?:.|\n)*?"""|"(?:\\.|[^"\\\n])*"')


def strip_swift(text: str) -> str:
    """Comments go; string literals stay as empty quotes so `"stat("` in a
    message is not a call."""
    text = COMMENT.sub("", text)
    return STRING.sub('""', text)


def source_entries(target: dict) -> list[tuple[str, list[str]]]:
    entries = []
    for entry in target.get("sources", []) or []:
        if isinstance(entry, str):
            entries.append((entry, []))
        elif isinstance(entry, dict) and "path" in entry:
            entries.append((entry["path"], list(entry.get("excludes", []) or [])))
    return entries


def closure(root: str, target: dict) -> list[str]:
    files = set()
    for path, excludes in source_entries(target):
        full = os.path.join(root, path)
        if os.path.isfile(full):
            if full.endswith(".swift"):
                files.add(os.path.relpath(full, root))
            continue
        for current, _dirs, names in os.walk(full):
            for name in names:
                if not name.endswith(".swift"):
                    continue
                rel_to_entry = os.path.relpath(os.path.join(current, name), full)
                if any(fnmatch.fnmatch(rel_to_entry, pattern) or fnmatch.fnmatch(name, pattern) for pattern in excludes):
                    continue
                files.add(os.path.relpath(os.path.join(current, name), root))
    return sorted(files)


def scan(root: str, files: list[str]) -> tuple[dict[str, list[str]], list[str]]:
    used: dict[str, list[str]] = {}
    app_group: list[str] = []
    compiled = {category: re.compile(pattern) for category, pattern in CATEGORY_PATTERNS.items()}
    for rel in files:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as handle:
            code = strip_swift(handle.read())
        for category, pattern in compiled.items():
            if pattern.search(code):
                used.setdefault(category, []).append(rel)
        if APP_GROUP_DEFAULTS.search(code):
            app_group.append(rel)
    return used, app_group


def declared(manifest_path: str) -> tuple[dict, dict[str, set[str]]]:
    with open(manifest_path, "rb") as handle:
        manifest = plistlib.load(handle)
    reasons: dict[str, set[str]] = {}
    for item in manifest.get("NSPrivacyAccessedAPITypes", []) or []:
        category = item.get("NSPrivacyAccessedAPIType")
        if category:
            reasons[category] = set(item.get("NSPrivacyAccessedAPITypeReasons", []) or [])
    return manifest, reasons


def check(root: str, targets: dict = TARGETS) -> tuple[list[str], list[str]]:
    findings: list[str] = []
    notes: list[str] = []
    with open(os.path.join(root, "project.yml"), encoding="utf-8") as handle:
        project = yaml.safe_load(handle)
    project_targets = project.get("targets", {}) or {}
    for name, manifest_rel in targets.items():
        target = project_targets.get(name)
        if target is None:
            findings.append(f"{name}: target missing from project.yml")
            continue
        files = closure(root, target)
        if not files:
            findings.append(f"{name}: no Swift sources found in its project.yml closure")
            continue
        used, app_group = scan(root, files)
        if manifest_rel is None:
            for category, where in sorted(used.items()):
                findings.append(f"{name}: uses {category} ({where[0]}) but ships no privacy manifest")
            continue
        manifest_path = os.path.join(root, manifest_rel)
        if not os.path.isfile(manifest_path):
            findings.append(f"{name}: privacy manifest missing at {manifest_rel}")
            continue
        manifest, reasons = declared(manifest_path)
        if manifest.get("NSPrivacyTracking") is not False:
            findings.append(f"{name}: NSPrivacyTracking must be false")
        if manifest.get("NSPrivacyTrackingDomains"):
            findings.append(f"{name}: NSPrivacyTrackingDomains must be empty")
        for category, codes in sorted(reasons.items()):
            valid = VALID_REASONS.get(category)
            if valid is None:
                findings.append(f"{name}: unknown required-reason category {category}")
                continue
            if not codes:
                findings.append(f"{name}: {category} is declared without a reason")
            for code in sorted(codes - valid):
                findings.append(f"{name}: {code} is not a reason Apple defines for {category}")
        for category, where in sorted(used.items()):
            if category not in reasons:
                findings.append(f"{name}: {where[0]} uses {category}, which {manifest_rel} does not declare")
        if app_group and "1C8F.1" not in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", set()):
            findings.append(f"{name}: {app_group[0]} reads App Group defaults; declare UserDefaults reason 1C8F.1")
        for category in sorted(set(reasons) - set(used)):
            notes.append(f"{name}: {category} is declared but not seen in the closure (kept, the safe direction)")
    return findings, notes


def self_test() -> int:
    root = tempfile.mkdtemp(prefix="privacy-manifest-selftest.")
    try:
        def write(rel: str, text: str) -> None:
            full = os.path.join(root, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as handle:
                handle.write(text)

        def manifest(entries: dict[str, list[str]], tracking: bool = False) -> None:
            data = {
                "NSPrivacyTracking": tracking,
                "NSPrivacyTrackingDomains": [],
                "NSPrivacyCollectedDataTypes": [],
                "NSPrivacyAccessedAPITypes": [
                    {"NSPrivacyAccessedAPIType": key, "NSPrivacyAccessedAPITypeReasons": value}
                    for key, value in entries.items()
                ],
            }
            path = os.path.join(root, "App/PrivacyInfo.xcprivacy")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                plistlib.dump(data, handle)

        write("project.yml", "targets:\n  App:\n    sources:\n      - path: App\n        excludes:\n          - \"Skip.swift\"\n  Watch:\n    sources:\n      - path: Watch\n")
        write("App/Main.swift", "let d = UserDefaults(suiteName: \"group.x\")\nlet t = ProcessInfo.processInfo.systemUptime\n")
        write("App/Skip.swift", "let v = URL(fileURLWithPath: \"/\").resourceValues(forKeys: [.contentModificationDateKey])\n")
        write("App/Comment.swift", "// mach_absolute_time() in a comment does not count\nlet s = \"stat(\"\n")
        write("Watch/Face.swift", "struct Face {}\n")
        targets = {"App": "App/PrivacyInfo.xcprivacy", "Watch": None}

        cases = []
        manifest({"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
                  "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]})
        cases.append(("complete manifest passes", check(root, targets)[0] == []))

        manifest({"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"]})
        cases.append(("missing SystemBootTime fails", any("SystemBootTime" in f for f in check(root, targets)[0])))

        manifest({"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                  "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]})
        cases.append(("App Group defaults without 1C8F.1 fails", any("1C8F.1" in f for f in check(root, targets)[0])))

        manifest({"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
                  "NSPrivacyAccessedAPICategorySystemBootTime": ["C617.1"]})
        cases.append(("foreign reason code fails", any("C617.1 is not a reason" in f for f in check(root, targets)[0])))

        manifest({"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
                  "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]}, tracking=True)
        cases.append(("tracking true fails", any("NSPrivacyTracking" in f for f in check(root, targets)[0])))

        manifest({"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
                  "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]})
        write("Watch/Store.swift", "let d = UserDefaults.standard\n")
        cases.append(("watch target without manifest fails once it uses an API",
                      any("Watch: uses NSPrivacyAccessedAPICategoryUserDefaults" in f for f in check(root, targets)[0])))
        os.remove(os.path.join(root, "Watch/Store.swift"))

        manifest({"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
                  "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
                  "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"]})
        findings, notes = check(root, targets)
        cases.append(("over-declaration is a note, not a finding", findings == [] and any("DiskSpace" in n for n in notes)))

        failed = [name for name, ok in cases if not ok]
        for name, ok in cases:
            print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        if failed:
            print(f"check-privacy-manifests self-test: FAIL ({len(failed)} of {len(cases)})", file=sys.stderr)
            return 1
        print(f"check-privacy-manifests self-test: PASS ({len(cases)} cases)")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()
    if argv:
        print(__doc__.split("Usage", 1)[1], file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    findings, notes = check(root)
    for note in notes:
        print(f"note: {note}")
    if findings:
        for finding in findings:
            print(f"FAIL: {finding}", file=sys.stderr)
        print(f"check-privacy-manifests: {len(findings)} finding(s)", file=sys.stderr)
        return 1
    print(f"check-privacy-manifests: PASS ({len(TARGETS)} targets)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
