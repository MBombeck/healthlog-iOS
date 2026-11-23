#!/usr/bin/env python3
"""GitHub dependency-graph snapshot of the resolved Swift packages.

GitHub's dependency graph reads a `Package.resolved` only next to a
`Package.swift` that declares the dependencies. HealthLog's packages are
declared in `project.yml` (XcodeGen) and resolved into the Xcode project, so
the graph sees the GitHub Actions and nothing else, and Dependabot can raise
no alert for a vulnerable Swift package. This script turns the committed
resolved file into a dependency submission
(https://docs.github.com/rest/dependency-graph/dependency-submission); the
`dependency-graph` job in `.github/workflows/hygiene.yml` posts it on every
push to `main`.

  scripts/dependency-snapshot.py              # print the snapshot JSON
  scripts/dependency-snapshot.py --self-test  # prove the mapping

The snapshot reads GITHUB_SHA, GITHUB_REF, GITHUB_RUN_ID, GITHUB_WORKFLOW and
GITHUB_JOB from the environment, as the job provides them.
"""

from __future__ import annotations

import datetime
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOLVED = "HealthLog.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# Resolved for the test targets only; everything else ships or builds the app.
DEVELOPMENT = {"swift-snapshot-testing"}


def purl(location: str, version: str) -> str:
    path = location.removesuffix(".git").split("://", 1)[-1]
    return f"pkg:swift/{path}@{version}"


def direct_urls(root: str) -> set[str]:
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        return set()
    with open(os.path.join(root, "project.yml"), encoding="utf-8") as handle:
        project = yaml.safe_load(handle)
    return {
        package["url"].removesuffix(".git").lower()
        for package in (project.get("packages") or {}).values()
        if package and package.get("url")
    }


def snapshot(root: str, env: dict[str, str]) -> dict:
    with open(os.path.join(root, RESOLVED), encoding="utf-8") as handle:
        pins = json.load(handle).get("pins", [])
    direct = direct_urls(root)
    resolved = {}
    for pin in pins:
        version = pin.get("state", {}).get("version")
        if not version:
            continue  # a branch or revision pin has no advisory range to match
        location = pin["location"]
        resolved[pin["identity"]] = {
            "package_url": purl(location, version),
            "relationship": "direct" if location.removesuffix(".git").lower() in direct else "indirect",
            "scope": "development" if pin["identity"] in DEVELOPMENT else "runtime",
        }
    return {
        "version": 0,
        "sha": env["GITHUB_SHA"],
        "ref": env["GITHUB_REF"],
        "job": {
            "correlator": f"{env.get('GITHUB_WORKFLOW', 'hygiene')}-{env.get('GITHUB_JOB', 'dependency-graph')}",
            "id": env.get("GITHUB_RUN_ID", "0"),
        },
        "detector": {
            "name": "healthlog-dependency-snapshot",
            "version": "1",
            "url": "https://github.com/MBombeck/healthlog-iOS/blob/main/scripts/dependency-snapshot.py",
        },
        "scanned": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "manifests": {
            RESOLVED: {
                "name": "Package.resolved",
                "file": {"source_location": RESOLVED},
                "resolved": resolved,
            }
        },
    }


def self_test() -> int:
    env = {"GITHUB_SHA": "0" * 40, "GITHUB_REF": "refs/heads/main", "GITHUB_RUN_ID": "1"}
    data = snapshot(ROOT, env)
    entries = data["manifests"][RESOLVED]["resolved"]
    cases = [
        ("purl drops the scheme and .git", purl("https://github.com/apple/swift-nio.git", "2.100.0")
         == "pkg:swift/github.com/apple/swift-nio@2.100.0"),
        ("every versioned pin is submitted", len(entries) > 0),
        ("a project.yml package is direct", entries.get("spezihealthkit", {}).get("relationship") == "direct"),
        ("a transitive package is indirect", entries.get("swift-nio", {}).get("relationship") == "indirect"),
        ("the snapshot test helper is development scope",
         entries.get("swift-snapshot-testing", {}).get("scope") == "development"),
        ("the payload carries sha and ref", data["sha"] == env["GITHUB_SHA"] and data["ref"] == env["GITHUB_REF"]),
    ]
    for name, ok in cases:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    failed = [name for name, ok in cases if not ok]
    if failed:
        print(f"dependency-snapshot self-test: FAIL ({len(failed)} of {len(cases)})", file=sys.stderr)
        return 1
    print(f"dependency-snapshot self-test: PASS ({len(cases)} cases)")
    return 0


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()
    if argv:
        print(__doc__, file=sys.stderr)
        return 2
    missing = [key for key in ("GITHUB_SHA", "GITHUB_REF") if not os.environ.get(key)]
    if missing:
        print(f"dependency-snapshot: {', '.join(missing)} not set", file=sys.stderr)
        return 2
    json.dump(snapshot(ROOT, dict(os.environ)), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
