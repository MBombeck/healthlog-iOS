# Compliance

What HealthLog iOS declares to Apple and to its users, why, and which gate keeps each declaration true. When a change touches any of the rows below, the declaration changes in the same pull request.

| Topic | Declared in | Kept true by |
| --- | --- | --- |
| Required-reason APIs, per binary | `PrivacyInfo.xcprivacy` of the app, the widget and the notification service extension | `scripts/check-privacy-manifests.py` (hygiene workflow), `PrivacyManifestTests`, `AppReviewConfigurationTests` |
| Collected data and tracking | the same manifests, App Store Connect "App Privacy" | `Phase8PrivacyDeltaTests`, this page, review on every new data flow |
| Export compliance | `ITSAppUsesNonExemptEncryption` in `project.yml` | `AppReviewConfigurationTests`, `scripts/third-party-licenses.py --check` (no bundled crypto library) |
| Third-party licenses | [third-party-licenses.md](third-party-licenses.md) | `scripts/third-party-licenses.py --check` |
| Accessibility | App Store Connect "Accessibility" | the accessibility UI tests and the audit below |
| Secrets and tooling trailers | none, by construction | gitleaks with `.gitleaks.toml`, `scripts/scan-tracked-secrets.sh`, `scripts/git-hooks/commit-msg` |
| Workflow supply chain | `.github/workflows/*.yml` | `scripts/test-workflow-hygiene.sh`, actionlint, CodeQL for Actions |

## Privacy manifests

Apple checks every binary of an upload on its own (ITMS-91053), so each one declares what its own sources call. The table is the state `scripts/check-privacy-manifests.py` requires; 1C8F.1 and SystemBootTime were missing until the 1.7 manifest fix. The watch app and its complications call none of the listed APIs and ship without a manifest; the gate fails the day one of them does.

| Binary | Category | Reasons | Where |
| --- | --- | --- | --- |
| App | UserDefaults | CA92.1, 1C8F.1 | app preferences and sync cursors (`.standard`); the App Group suite `group.dev.healthlog.app` shared with the extensions |
| App | FileTimestamp | C617.1, DDA9.1 | the temp sweepers read `contentModificationDate` of their own files; diagnostics show timestamps on the device |
| App | SystemBootTime | 35F9.1 | `ProcessInfo.systemUptime` measures the time budget of background HealthKit passes |
| Widget | UserDefaults | CA92.1, 1C8F.1 | consent flags (`.standard`); account, lock-screen and medication contract flags from the App Group suite |
| Widget | FileTimestamp | C617.1, DDA9.1 | the compiled `DoctorReportTmpSweeper` |
| Notification service | UserDefaults | CA92.1, 1C8F.1 | relay template list (`.standard`); lock-screen privacy, dose ledger and relay flags from the App Group suite |

Collected data types (all linked to the person, none used for tracking, purpose App Functionality): Name, Email Address, User ID, Device ID, Health, Fitness, Precise Location (workout routes, opt-in), Photos or Videos (avatar, document vault), Other User Content, Sensitive Info.

## App Store privacy answers

The App Privacy section in App Store Connect must say the same as the manifest. The 1.7 features change no category, but each one should be checked against the live answers before submission:

- **Health Records (lab results).** Apple counts data from the Clinical Health Records API as *Health & Fitness, Health*. Already declared; the purpose string `NSHealthClinicalHealthRecordsShareUsageDescription` and the `health-records` entitlement are in place. Health Records data goes to the person's own server only.
- **Push relay.** Opt-in. The relay run by the maintainer stores the APNs token, a hash of the binding key and the consent version and day, linked to the server instance. That is *Identifiers, Device ID*, linked, App Functionality, collected by the developer. Notification content is HPKE-encrypted end to end and is not collected.
- **Device ID.** The random `X-Device-Id` (Keychain) goes to the person's own server for session binding; same category as above.
- **Bring-your-own-key AI.** Prompts go from the phone to the provider the person chose, with the person's key, after a consent screen. The data types involved (Health, Other User Content, Sensitive Info) are declared already.

The public policy at [healthlog.dev/privacy](https://healthlog.dev/privacy) has to describe the same flows. Checked on 2026-11-22 (policy version 1.48.0) it does not yet name the push relay operated by the maintainer, does not mention reading Health Records through HealthKit in the app (only through an Apple Health export), and gives the iOS bundle identifier as `io.bombeck.healthlog` instead of `dev.healthlog.app`. All three need fixing on the website before 1.7 is submitted.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false`. The reasoning, so that it can be revisited when the code changes:

- All cryptography comes from Apple's operating system: TLS through `URLSession`, the Keychain, and CryptoKit for the push relay (HPKE with X25519, HKDF-SHA256 and ChaCha20-Poly1305 to open notification envelopes; Ed25519 signatures for the device binding), PKCE hashing and cache keys. No resolved package brings its own cryptography, and `scripts/third-party-licenses.py --check` fails if one is added.
- No proprietary or non-standard algorithm is implemented in the app.
- App Store Connect asks whether the app implements encryption algorithms "instead of, or in addition to, using or accessing the encryption within Apple's operating system". For HealthLog the answer is no, and for that answer Apple asks for no documentation and no French declaration; the key `false` records the same answer in the build, so the question is not asked per upload.
- Independently of Apple's form, the HPKE envelope is encryption for confidentiality, not only authentication. Under the US EAR that is mass-market software (5D992.c, License Exception ENC 740.17(b)(1)), which since 2021 needs no classification request and no self-classification report for an app like this. Under the EU dual-use regulation (EU 2021/821) the cryptography note (Note 3, Category 5 Part 2) releases mass-market software of this kind from control.

Revisit the answer when a package with its own cryptography is added, when the app implements an algorithm itself, or when it starts to offer encryption as a feature to other apps.

## Third-party licenses

All 50 resolved packages are under MIT, BSD or Apache-2.0 ([third-party-licenses.md](third-party-licenses.md)). Those licenses ask that their copyright notices and license texts travel with the binary, and Apache-2.0 packages with a `NOTICE` file ask the same for that file. The App Store build does not show them yet. It needs an acknowledgements screen (Settings, About, Licenses) generated from the inventory, or a `Settings.bundle` with the license texts.

## Accessibility

App Store Connect lets an app declare the accessibility features its common tasks support. Evidence in the code today: VoiceOver labels, values and chart descriptors on the main surfaces, Dynamic Type throughout, a dark appearance, and Reduce Motion handled in the animations, with UI tests for the accessibility of the main flows (`Phase8AccessibilityUITests*`). Differentiate Without Color and Increase Contrast are handled in only a few places, and Voice Control has no dedicated input labels.

Declare VoiceOver, Larger Text, Dark Interface and Reduced Motion once a device pass has confirmed the common tasks (log a reading, mark a dose, read a chart, change a setting) with each of them. Leave Sufficient Contrast, Differentiate Without Color and Voice Control undeclared until they have been audited. Captions and Audio Descriptions do not apply.

## Licence and App Store distribution

The code is published under the PolyForm Noncommercial License 1.0.0. The licence binds people who receive the code, not its copyright holder, so the maintainer selling the app in the App Store is compatible with it as far as the maintainer's own code goes. Two consequences need attention:

- **Contributions.** Code and translations by others are licensed to the maintainer under the project licence too, which does not permit commercial use. [CONTRIBUTING.md](../CONTRIBUTING.md) therefore asks every contributor for a Developer Certificate of Origin sign-off and an additional licence that covers the App Store build. Contributions that came in before that rule need the same permission from their authors, in writing.
- **Wording.** PolyForm Noncommercial is source-available, not an open-source licence in the OSI sense. Public texts should say "source available" or "public source" rather than "open source".
