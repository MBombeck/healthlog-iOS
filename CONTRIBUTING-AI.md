# Contributing with AI tooling

HealthLog iOS is built with AI assistance, and contributions made the same way are welcome. Like the [server project's policy](https://github.com/MBombeck/HealthLog/blob/main/CONTRIBUTING-AI.md), this file does not try to legislate which tools you use — it says where the real conventions live and what holds regardless of tooling.

## Where the real conventions live

- [`docs/architecture.md`](docs/architecture.md) is the walk through the codebase: stores, repositories, the SWR cache, the session lease model, and why they are shaped the way they are.
- [`docs/design-handbook-v1.md`](docs/design-handbook-v1.md) and [`docs/UI-MANIFEST.md`](docs/UI-MANIFEST.md) carry the UI standard. Surfaces that drift from it get reverted by the next standards pass — build with it, not around it.
- [`TESTING.md`](TESTING.md) and [`docs/testing.md`](docs/testing.md) explain the test layout, the hermetic fixtures, and the baseline gates under `scripts/`.
- The wire contract belongs to the server: [`docs/CONTRIBUTING-CLIENTS.md`](https://github.com/MBombeck/HealthLog/blob/main/docs/CONTRIBUTING-CLIENTS.md) covers building a client against it, and the server's `docs/api/openapi.yaml` is generated from its schemas and always accurate for the commit it sits in. [`docs/api-contract.md`](docs/api-contract.md) records how this app consumes it.

## Ground rules, whatever tooling you use

- The human who commits a change has read it and stands behind it. The git history knows authors, not tools: no AI attribution trailers, no assistant vocabulary in commit messages, PR text, or release notes.
- No real names of users or reporters in committed text, and no live health figures anywhere, including fixtures, screenshots, and examples. Invent data.
- No secrets in code, fixtures, or docs, and nothing secret-shaped either — `scripts/scan-tracked-secrets.sh` is the gate; run it before pushing.
- Run the gates before pushing — `xcodegen generate`, the test suite, `scripts/lint-strict-baseline.sh`, the strings gates — and fix what they find rather than suppressing it. The lint baseline only ratchets down; a guard that fails is telling you something, and the fix goes in the code, not in the guard.
- Tests describe the world the app actually runs in. A suite that pre-seeds the very state whose absence it should catch proves nothing — when you change launch, session, or update behaviour, test from a pre-existing installation, not a fresh one.
