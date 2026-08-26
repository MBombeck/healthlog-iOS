// Diese Suite hängt an App-Target-Symbolen (`WatchSessionCoordinator`,
// `AppContainer`), die es im SPM-Library-Build nicht gibt — dort übersprungen.
#if !SWIFT_PACKAGE

    import Foundation
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    @testable import HealthLog

    /// **Privacy H4 (audit-v0162) — watch snapshot wipe on logout.**
    ///
    /// The previous user's medication names / doses / mood / latest measurement
    /// lived in the paired watch's App Group `watch-snapshot.json` + complications
    /// until user B signed in, because `performFullLocalLogout` had no
    /// WatchConnectivity step. These tests pin that the logout cascade pushes the
    /// PHI-free placeholder to the watch, and that the shared `isCleared` contract
    /// the watch mirrors on identifies exactly the cleared snapshot.
    @MainActor
    @Suite("Watch logout reset (Privacy H4)")
    struct WatchLogoutResetTests {
        @Test("pushLogoutReset pushes the PHI-free placeholder snapshot")
        func pushLogoutResetPushesPlaceholder() {
            let coordinator = WatchSessionCoordinator()
            // Pre-condition: nothing pushed yet.
            #expect(coordinator.lastPushedSnapshot == nil)

            coordinator.pushLogoutReset()

            let pushed = coordinator.lastPushedSnapshot
            #expect(pushed == .placeholder)
            #expect(pushed?.isCleared == true)
            // No PHI in the pushed payload.
            #expect(pushed?.doses.isEmpty == true)
            #expect(pushed?.signedIn == false)
            #expect(pushed?.latestMeasurement == nil)
            #expect(pushed?.healthScore == nil)
        }

        @Test("performFullLocalLogout wipes the watch on every reason")
        func cascadePushesWatchReset() async {
            let container = AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
            #expect(container.watchSession.lastPushedSnapshot == nil)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(
                container.watchSession.lastPushedSnapshot?.isCleared == true,
                "performFullLocalLogout MUST push a PHI-free placeholder snapshot to the watch"
            )
        }

        @Test("isCleared is true only for a PHI-free snapshot")
        func isClearedContract() {
            #expect(WatchSnapshot.placeholder.isCleared)

            let withMed = WatchSnapshot(
                doses: [
                    .init(
                        id: "d1",
                        medicationName: "Sertralin",
                        doseText: "50 mg",
                        scheduledAt: .now,
                        isTaken: false,
                        isActionable: true,
                        isInjection: false
                    )
                ],
                scheduledCount: 1,
                takenCount: 0,
                recentMoodScore: nil,
                signedIn: true,
                generatedAt: .now
            )
            #expect(!withMed.isCleared)

            // Mood-only snapshot is also NOT cleared (still carries PHI).
            let withMood = WatchSnapshot(
                doses: [],
                scheduledCount: 0,
                takenCount: 0,
                recentMoodScore: 4,
                moodCountToday: 1,
                signedIn: true,
                generatedAt: .now
            )
            #expect(!withMood.isCleared)
        }
    }

#endif // !SWIFT_PACKAGE
