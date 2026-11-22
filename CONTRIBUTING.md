# Contributing to HealthLog iOS

Thanks for wanting to help. HealthLog iOS is the native client of the self-hosted [HealthLog server](https://github.com/MBombeck/HealthLog); most features need both sides, so it helps to know where a change belongs before you start.

## Where things go

- **A bug in the app**: open an issue with the bug template. Include the app version and build (Settings, About), the iOS version, the device and your server version.
- **A feature idea**: open an issue with the feature template. If it needs data the server does not provide yet, it starts on the server side.
- **A translation**: in Tolgee, see below. Not as a pull request.
- **A security problem**: never in public. See [SECURITY.md](SECURITY.md).
- **A question about running your own server**: the [documentation](https://docs.healthlog.dev) and the server project's discussions.

## Translations

Translations are made in Tolgee at **[translate.healthlog.dev](https://translate.healthlog.dev)**. The maintainer imports them into the string catalogs (`*.xcstrings`) before a release, where the catalog gates check placeholders, plural forms and punctuation. Please do not edit the catalogs in a pull request: the next import would overwrite the change, and two copies of the same text drift apart.

To get access, to propose a new language or to report a wrong translation, open an issue with the translation template. How the app chooses its language and what a new language needs beyond its strings is described in [docs/localization.md](docs/localization.md).

Medical wording is held to a stricter rule. Texts about values, ranges, medication or symptoms stay marked for review until someone who reads the language and knows the subject has checked them, and validated questionnaires are only used in their published validated translations. Machine translation is fine as a first draft; say in Tolgee or in the issue when a text has not been reviewed by a person.

## Code contributions

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach before you invest time.
2. Fork, branch from `main`, keep the change focused.
3. Generate the project with `xcodegen` and build with the pinned Xcode (see `project.yml` and [docs/runbook.md](docs/runbook.md)).
4. Run the gates before you push. [TESTING.md](TESTING.md) lists them; the short version is the unit tests, `swiftformat --lint .`, `scripts/lint-strict-baseline.sh`, the string gates and `scripts/scan-tracked-secrets.sh`. Fix what they find in the code, not in the gate.
5. Open the pull request against `main` and fill in the template.

Pull requests from forks run a reduced CI on a GitHub-hosted runner (build, unit tests, Release link check). The UI gate runs on the maintainer's machine after review.

House rules that apply to every change:

- Invented data only. No real names, health values, server addresses or tokens in code, fixtures, screenshots or examples.
- Text a person reads goes through the string catalogs and avoids the characters `·`, `—`, `–` and `→` (the punctuation gate enforces it).
- Commit messages describe the change in English. The git history knows authors, not tools: no assistant attribution trailers and no "generated with" lines (`scripts/git-hooks/commit-msg` and CI reject them). [CONTRIBUTING-AI.md](CONTRIBUTING-AI.md) covers working with AI tools.
- Follow the UI standard in [docs/design-handbook-v1.md](docs/design-handbook-v1.md) and [docs/UI-MANIFEST.md](docs/UI-MANIFEST.md).

## Licensing of contributions

HealthLog iOS is published under the [PolyForm Noncommercial License 1.0.0](LICENSE). The maintainer also distributes the app through the App Store, which is a commercial distribution. A contribution can only ship in that build if its author allows it, so by submitting a contribution (code, documentation, artwork, or a translation in Tolgee) you agree that:

1. you wrote it, or otherwise have the right to submit it, as set out in the [Developer Certificate of Origin 1.1](https://developercertificate.org/), and you say so with a `Signed-off-by:` line in each commit (`git commit -s`);
2. you grant MBombeck, the licensor named in LICENSE, a perpetual, worldwide, non-exclusive, royalty-free, irrevocable licence to use, reproduce, modify, distribute and sublicense the contribution as part of HealthLog, including in commercial distributions such as the App Store build; and
3. everyone else receives your contribution under the project licence.

You keep the copyright in your work. If you cannot agree to this, please say so in the pull request before it is merged.

## Code of conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
