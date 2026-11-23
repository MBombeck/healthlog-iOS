# Privacy

The binding privacy policy for HealthLog, the server and this iOS app, is published at **[healthlog.dev/privacy](https://healthlog.dev/privacy)**. This page is the short version for people reading the code, with pointers to where each statement is enforced.

## Where your data goes

- **Your own HealthLog server.** Everything you record or sync, including what the app reads from Apple Health and, if you switch it on, the lab results from your Health Records, goes to the server address you enter on first launch. The app ships without a built-in server. Whoever runs that server is responsible for the data on it.
- **Apple Health.** The app reads and writes only the types you grant, and only after you grant them. Health Records are read only after you switch the lab import on.
- **The push relay, only if you switch it on.** Push notifications from a self-hosted server can be delivered through a relay operated by the HealthLog maintainer. The relay stores the device's push token, a hash of its binding key and the version and day of your consent, linked to your server instance. Notification content is end-to-end encrypted (HPKE) between your server and your device; the relay cannot read it. You can withdraw from the app at any time, which deletes the binding at the relay.
- **An AI provider, only if you choose one.** With your own API key, the Coach talks to the provider you selected, directly from the phone, after a consent screen that names the provider. The on-device Coach (Apple Intelligence) sends nothing anywhere.

## What the app does not do

- No analytics, advertising or tracking SDKs, no tracking domains, no cross-app identifiers. `NSPrivacyTracking` is false in every privacy manifest.
- No iCloud copy of health data made by the app. Its own stores are excluded from backups and never use CloudKit.
- No contact with the maintainer's infrastructure unless you enable the push relay.

## Where this is declared and checked

- Privacy manifests: `HealthLog/Resources/PrivacyInfo.xcprivacy`, `HealthLogWidgets/Resources/PrivacyInfo.xcprivacy`, `NotificationServiceExtension/Resources/PrivacyInfo.xcprivacy`. `scripts/check-privacy-manifests.py` checks in CI that each binary declares the required-reason APIs its own sources call.
- App Store privacy answers, export compliance and the accessibility declaration: [docs/compliance.md](docs/compliance.md).
- Security model: [docs/security.md](docs/security.md). Reporting a problem: [SECURITY.md](SECURITY.md).
