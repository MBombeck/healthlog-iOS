#!/usr/bin/env python3
"""Third-party license inventory of the Swift packages the app resolves.

`docs/third-party-licenses.md` lists every pin of the committed
`Package.resolved` with its version, its license and where the license text
lives. The App Store binary carries code under MIT, BSD and Apache-2.0, and
those licenses ask that their notices travel with the binary; this file is the
inventory that the release notes are built from.

`HealthLog/Resources/ThirdPartyLicenses.json` is the same list for the app
bundle: per package its name, version, license and the full license text, plus
the text of a `NOTICE` file where the package ships one (Apache-2.0, section
4d). Settings > About > Licenses reads it.

  --generate [--checkouts DIR]   rewrite the inventory and the bundle file
                                 from the license files of a resolved checkout
                                 (SourcePackages/checkouts of a build). Without
                                 --checkouts the newest DerivedData checkout
                                 (Xcode's or a gate's /tmp/dd-hl-*) whose
                                 versions match Package.resolved is used.
  --check                        fail when the inventory or the bundle file and
                                 Package.resolved disagree on a package or a
                                 version, when a bundle entry has no license
                                 text, when a package carries no permissive
                                 license, or when a package brings its own
                                 cryptography (export compliance). Needs no
                                 checkout, so CI runs it anywhere.
  --self-test                    prove that --check bites.

Exit: 0 clean, 1 drift or a finding, 2 usage or input error.
"""

from __future__ import annotations

import glob
import json
import os
import re
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOLVED = "HealthLog.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
INVENTORY = "docs/third-party-licenses.md"
BUNDLE = "HealthLog/Resources/ThirdPartyLicenses.json"

# Licenses that allow shipping the code inside a paid, closed App Store
# binary as long as the notices are reproduced. Anything else needs a look.
PERMISSIVE = {
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "BSD-3-Clause OR GPL-2.0-only",
    "BSD-2-Clause AND MIT",
}

# Packages that bring their own cryptography. The export-compliance answer
# (`ITSAppUsesNonExemptEncryption = false`, docs/compliance.md) rests on the
# app using only the encryption built into Apple's operating system
# (CryptoKit, Security, URLSession TLS). A resolved package from this list
# changes that answer, so it fails until the answer has been revisited.
BUNDLED_CRYPTO = {
    "boringssl", "cryptoswift", "libsodium", "openssl", "swift-certificates",
    "swift-crypto", "swift-nio-ssl", "swift-sodium", "swiftnio-ssl",
}

ROW = re.compile(r"^\| `(?P<identity>[^`]+)` \| (?P<version>[^|]+?) \| (?P<license>[^|]+?) \| (?P<scope>[^|]+?) \| (?P<url>[^|]+?) \|$")


def load_pins(root: str) -> dict[str, dict]:
    with open(os.path.join(root, RESOLVED), encoding="utf-8") as handle:
        data = json.load(handle)
    pins = {}
    for pin in data.get("pins", []):
        state = pin.get("state", {})
        pins[pin["identity"]] = {
            "version": state.get("version") or state.get("revision", "")[:12],
            "location": pin["location"].removesuffix(".git"),
        }
    return pins


def direct_urls(root: str) -> set[str]:
    urls = set()
    try:
        import yaml  # noqa: PLC0415 - only --generate needs it
    except ImportError:
        return urls
    with open(os.path.join(root, "project.yml"), encoding="utf-8") as handle:
        project = yaml.safe_load(handle)
    for package in (project.get("packages") or {}).values():
        url = (package or {}).get("url")
        if url:
            urls.add(url.removesuffix(".git").lower())
    return urls


def classify(text: str) -> str:
    flat = re.sub(r"\s+", " ", text)
    if "GNU GENERAL PUBLIC LICENSE" in flat and "BSD" in flat:
        return "BSD-3-Clause OR GPL-2.0-only"
    if "Apache License" in flat and "Version 2.0" in flat:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in flat:
        if "Redistribution and use in source and binary forms" in flat:
            return "BSD-2-Clause AND MIT"
        return "MIT"
    if "Redistribution and use in source and binary forms" in flat:
        return "BSD-3-Clause" if "Neither the name" in flat or "neither the name" in flat else "BSD-2-Clause"
    if "GNU GENERAL PUBLIC LICENSE" in flat:
        return "GPL"
    return "UNKNOWN"


def license_files(checkout: str) -> list[str]:
    names = sorted(os.listdir(checkout))
    return [name for name in names if re.match(r"(?i)^(licen[cs]e|copying)(\.(md|txt))?$", name)]


def find_checkouts(pins: dict[str, dict]) -> str | None:
    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/HealthLog-*/SourcePackages"))
    candidates += glob.glob("/tmp/dd-hl-*/SourcePackages")
    candidates.sort(key=lambda path: os.path.getmtime(path), reverse=True)
    for packages in candidates:
        state_path = os.path.join(packages, "workspace-state.json")
        if not os.path.isfile(state_path):
            continue
        with open(state_path, encoding="utf-8") as handle:
            state = json.load(handle)
        versions = {
            dep["packageRef"]["identity"]: dep["state"].get("checkoutState", {}).get("version")
            for dep in state.get("object", {}).get("dependencies", [])
        }
        if all(versions.get(identity) == pin["version"] for identity, pin in pins.items()):
            return os.path.join(packages, "checkouts")
    return None


def generate(root: str, checkouts: str | None) -> int:
    pins = load_pins(root)
    checkouts = checkouts or find_checkouts(pins)
    if not checkouts or not os.path.isdir(checkouts):
        print("third-party-licenses: no checkout matches Package.resolved; build once or pass --checkouts", file=sys.stderr)
        return 2
    direct = direct_urls(root)
    rows = []
    notices = []
    entries = []
    for identity in sorted(pins):
        pin = pins[identity]
        folder = os.path.join(checkouts, pin["location"].rstrip("/").split("/")[-1])
        if not os.path.isdir(folder):
            print(f"third-party-licenses: checkout missing for {identity} ({folder})", file=sys.stderr)
            return 2
        files = license_files(folder)
        text = ""
        for name in files:
            path = os.path.join(folder, name)
            if os.path.isfile(path):
                with open(path, encoding="utf-8", errors="replace") as handle:
                    text += handle.read() + "\n"
        spdx = classify(text) if text else "UNKNOWN"
        notice_files = sorted(name for name in os.listdir(folder) if re.match(r"(?i)^notice(\.(md|txt))?$", name))
        if notice_files:
            notices.append(f"`{identity}`")
        scope = "direct" if pin["location"].lower() in direct else "transitive"
        rows.append(f"| `{identity}` | {pin['version']} | {spdx} | {scope} | {pin['location']} |")
        entries.append({
            "identity": identity,
            "name": pin["location"].rstrip("/").split("/")[-1],
            "version": pin["version"],
            "license": spdx,
            "source": pin["location"],
            # The license the app uses first: zstd's BSD LICENSE before its GPL COPYING.
            "text": tidy([os.path.join(folder, name) for name in sorted(files, key=lambda n: (not n.lower().startswith("licen"), n))]),
            "notice": tidy([os.path.join(folder, name) for name in notice_files]) or None,
        })
    header = [
        "# Third-party licenses",
        "",
        "Generated by `scripts/third-party-licenses.py --generate` from",
        f"`{RESOLVED}` and the license files of the",
        "resolved checkouts. CI runs `--check`, which fails when a package or a",
        "version here no longer matches the resolved file. Do not edit by hand.",
        "",
        "Every package below is under a permissive license. MIT, BSD and Apache-2.0",
        "ask that the copyright notice and license text travel with the binary, so",
        "the App Store build needs an acknowledgements screen that reproduces them.",
        "`zstd` is dual-licensed; HealthLog uses it under BSD-3-Clause. Apache-2.0",
        "packages that ship a `NOTICE` file need that text reproduced as well:",
        (", ".join(notices) + ".") if notices else "none.",
        "",
        "Direct means `project.yml` names the package; transitive packages come in",
        "through one of those. Build-time-only packages (macros, code generators,",
        "test helpers) are listed because they resolve, even where no code of",
        "theirs reaches the binary.",
        "",
        "| Package | Version | License (SPDX) | Scope | Source |",
        "| --- | --- | --- | --- | --- |",
    ]
    with open(os.path.join(root, INVENTORY), "w", encoding="utf-8") as handle:
        handle.write("\n".join(header + rows) + "\n")
    entries.sort(key=lambda entry: entry["name"].lower())
    with open(os.path.join(root, BUNDLE), "w", encoding="utf-8") as handle:
        json.dump({"packages": entries}, handle, ensure_ascii=False, indent=1, sort_keys=True)
        handle.write("\n")
    print(f"third-party-licenses: wrote {INVENTORY} and {BUNDLE} ({len(rows)} packages)")
    return check(root)


def tidy(paths: list[str]) -> str:
    """The files' text as the app shows it: Unix line ends, no trailing blanks."""
    parts = []
    for path in paths:
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read().replace("\r\n", "\n").replace("\r", "\n")
            parts.append("\n".join(line.rstrip() for line in text.split("\n")).strip("\n"))
    return "\n\n".join(part for part in parts if part)


def check_bundle(root: str, pins: dict[str, dict], listed: dict[str, tuple[str, str]]) -> list[str]:
    path = os.path.join(root, BUNDLE)
    if not os.path.isfile(path):
        return [f"{BUNDLE} is missing; run --generate"]
    try:
        with open(path, encoding="utf-8") as handle:
            entries = json.load(handle)["packages"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        return [f"{BUNDLE} is unreadable: {error}"]
    findings = []
    bundled = {}
    for entry in entries:
        identity = entry.get("identity", "")
        if identity in bundled:
            findings.append(f"{identity} appears twice in {BUNDLE}")
        bundled[identity] = entry
    for identity in sorted(set(pins) - set(bundled)):
        findings.append(f"{identity} {pins[identity]['version']} is resolved but not in {BUNDLE}")
    for identity in sorted(set(bundled) - set(pins)):
        findings.append(f"{identity} is in {BUNDLE} but no longer resolved")
    for identity in sorted(set(pins) & set(bundled)):
        entry = bundled[identity]
        if entry.get("version") != pins[identity]["version"]:
            findings.append(f"{identity}: {BUNDLE} says {entry.get('version')}, Package.resolved says {pins[identity]['version']}")
        if not (entry.get("name") or "").strip():
            findings.append(f"{identity}: {BUNDLE} has no name")
        if not (entry.get("text") or "").strip():
            findings.append(f"{identity}: {BUNDLE} has no license text")
        if identity in listed and entry.get("license") != listed[identity][1]:
            findings.append(f"{identity}: {BUNDLE} says {entry.get('license')}, {INVENTORY} says {listed[identity][1]}")
    return findings


def check(root: str) -> int:
    path = os.path.join(root, INVENTORY)
    if not os.path.isfile(path):
        print(f"third-party-licenses: {INVENTORY} is missing; run --generate", file=sys.stderr)
        return 1
    listed = {}
    findings = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = ROW.match(line.rstrip("\n"))
            if match:
                listed[match["identity"]] = (match["version"].strip(), match["license"].strip())
    pins = load_pins(root)
    for identity in sorted(set(pins) - set(listed)):
        findings.append(f"{identity} {pins[identity]['version']} is resolved but not in {INVENTORY}")
    for identity in sorted(set(listed) - set(pins)):
        findings.append(f"{identity} is in {INVENTORY} but no longer resolved")
    findings += check_bundle(root, pins, listed)
    for identity in sorted(set(pins) & BUNDLED_CRYPTO):
        findings.append(f"{identity} brings its own cryptography; revisit the export-compliance answer in docs/compliance.md first")
    for identity in sorted(set(pins) & set(listed)):
        version, spdx = listed[identity]
        if version != pins[identity]["version"]:
            findings.append(f"{identity}: {INVENTORY} says {version}, Package.resolved says {pins[identity]['version']}")
        if spdx not in PERMISSIVE:
            findings.append(f"{identity}: license {spdx} needs a review before it ships")
    if findings:
        for finding in findings:
            print(f"FAIL: {finding}", file=sys.stderr)
        print("third-party-licenses: run scripts/third-party-licenses.py --generate after a dependency change", file=sys.stderr)
        return 1
    print(f"third-party-licenses: PASS ({len(pins)} packages)")
    return 0


def self_test() -> int:
    root = tempfile.mkdtemp(prefix="third-party-licenses-selftest.")
    try:
        os.makedirs(os.path.join(root, os.path.dirname(RESOLVED)))
        os.makedirs(os.path.join(root, "docs"))
        os.makedirs(os.path.join(root, os.path.dirname(BUNDLE)))

        def resolved(pins: list[tuple[str, str]]) -> None:
            with open(os.path.join(root, RESOLVED), "w", encoding="utf-8") as handle:
                json.dump({"pins": [
                    {"identity": i, "location": f"https://github.com/example/{i}.git", "state": {"version": v}}
                    for i, v in pins
                ], "version": 3}, handle)

        def inventory(rows: list[tuple[str, str, str]]) -> None:
            with open(os.path.join(root, INVENTORY), "w", encoding="utf-8") as handle:
                handle.write("| Package | Version | License (SPDX) | Scope | Source |\n| --- | --- | --- | --- | --- |\n")
                for i, v, spdx in rows:
                    handle.write(f"| `{i}` | {v} | {spdx} | direct | https://github.com/example/{i} |\n")
            bundle([(i, v, spdx, "Permission is hereby granted") for i, v, spdx in rows])

        def bundle(rows: list[tuple[str, str, str, str]]) -> None:
            with open(os.path.join(root, BUNDLE), "w", encoding="utf-8") as handle:
                json.dump({"packages": [
                    {"identity": i, "name": i, "version": v, "license": spdx, "text": text, "notice": None,
                     "source": f"https://github.com/example/{i}"}
                    for i, v, spdx, text in rows
                ]}, handle)

        cases = []
        resolved([("alpha", "1.0.0"), ("beta", "2.1.0")])
        inventory([("alpha", "1.0.0", "MIT"), ("beta", "2.1.0", "Apache-2.0")])
        cases.append(("matching inventory passes", check(root) == 0))
        resolved([("alpha", "1.0.1"), ("beta", "2.1.0")])
        cases.append(("version bump without regeneration fails", check(root) == 1))
        resolved([("alpha", "1.0.0"), ("beta", "2.1.0"), ("gamma", "0.1.0")])
        cases.append(("new package without regeneration fails", check(root) == 1))
        resolved([("alpha", "1.0.0"), ("beta", "2.1.0")])
        inventory([("alpha", "1.0.0", "MIT"), ("beta", "2.1.0", "GPL")])
        cases.append(("copyleft license fails", check(root) == 1))
        resolved([("alpha", "1.0.0"), ("swift-crypto", "3.0.0")])
        inventory([("alpha", "1.0.0", "MIT"), ("swift-crypto", "3.0.0", "Apache-2.0")])
        cases.append(("a bundled crypto library fails", check(root) == 1))
        resolved([("alpha", "1.0.0"), ("beta", "2.1.0")])
        inventory([("alpha", "1.0.0", "MIT"), ("beta", "2.1.0", "Apache-2.0")])
        bundle([("alpha", "1.0.0", "MIT", "Permission is hereby granted")])
        cases.append(("a package missing from the bundle fails", check(root) == 1))
        bundle([("alpha", "1.0.0", "MIT", "Permission"), ("beta", "2.1.0", "Apache-2.0", "  ")])
        cases.append(("a bundle entry without license text fails", check(root) == 1))
        bundle([("alpha", "1.0.0", "MIT", "Permission"), ("beta", "2.0.0", "Apache-2.0", "Apache License")])
        cases.append(("a stale bundle version fails", check(root) == 1))
        os.remove(os.path.join(root, BUNDLE))
        cases.append(("a missing bundle file fails", check(root) == 1))
        cases.append(("MIT text is classified", classify("Permission is hereby granted, free of charge, to any person") == "MIT"))
        cases.append(("zstd dual license is classified", classify("BSD License ... GNU GENERAL PUBLIC LICENSE Version 2") == "BSD-3-Clause OR GPL-2.0-only"))
        for name, ok in cases:
            print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        failed = [name for name, ok in cases if not ok]
        if failed:
            print(f"third-party-licenses self-test: FAIL ({len(failed)} of {len(cases)})", file=sys.stderr)
            return 1
        print(f"third-party-licenses self-test: PASS ({len(cases)} cases)")
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main(argv: list[str]) -> int:
    if argv == ["--check"]:
        return check(ROOT)
    if argv == ["--self-test"]:
        return self_test()
    if argv[:1] == ["--generate"]:
        rest = argv[1:]
        if rest and (len(rest) != 2 or rest[0] != "--checkouts"):
            print(__doc__, file=sys.stderr)
            return 2
        return generate(ROOT, rest[1] if rest else None)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
