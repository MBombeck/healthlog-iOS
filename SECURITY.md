# Security Policy

HealthLog iOS handles health data, so a report about it gets read the day it arrives. Thank you for taking the time.

## Supported versions

| Version | Supported |
| --- | --- |
| The current App Store release | Yes |
| The current TestFlight build | Yes |
| Older releases | No, please update first and check whether the issue is still there |

The app requires iOS 26 or later from 1.6 on. Devices on iOS 18 to 25 keep 1.5.x, which receives no further fixes.

## Reporting a vulnerability

**Please do not open a public issue, discussion or pull request for a security problem.**

Report it privately, in this order of preference:

1. Through GitHub's private vulnerability reporting: [Report a vulnerability](https://github.com/MBombeck/healthlog-iOS/security/advisories/new).
2. By email to **security@bombeck.io**.

Helpful to include: the app version and build (Settings, About), the iOS version and device, the steps to reproduce, what an attacker gains, and a proposed fix if you have one. Please use invented data in any example. Never send real health records, tokens or someone else's account details.

## What happens next

- Acknowledgement within 72 hours.
- A first assessment within one week.
- A fix and a coordinated disclosure, typically within 30 days. Fixes ship through TestFlight and the App Store; the advisory is published once the fixed build is available.

You will be credited in the advisory unless you ask not to be.

## Scope

In scope, for this repository:

- The iOS app, its widget and notification service extensions, and the Apple Watch app.
- Session, token and Keychain handling, certificate pinning, the log sanitizer.
- The push relay client: device binding keys, the HPKE envelope and the replay protection.
- How the app stores, caches, exports and deletes health data on the device.
- HealthKit and Health Records access beyond what the person granted.

Out of scope:

- The HealthLog server and its web app. Please report those to the [server project](https://github.com/MBombeck/HealthLog/security/advisories/new) (same email address).
- Vulnerabilities in third-party packages; please report them upstream. A way to reach one through HealthLog is in scope.
- Attacks that need a jailbroken device, or physical access to an unlocked device.
- Denial of service against a self-hosted server and social engineering.

## Safe harbour

Research done in good faith, within this policy, against your own account on your own server, is welcome. Please do not test against the public demo server or anyone else's instance, do not access or change other people's data, and give us a reasonable time to fix an issue before you talk about it publicly.

## Security architecture

How the app protects data at rest and in transit, including the pinning model, is described in [docs/security.md](docs/security.md).
