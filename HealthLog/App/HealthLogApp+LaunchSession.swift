import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// What the process does for the stored account before any scene exists.
///
/// iOS starts the app without a scene for a HealthKit delivery, a background
/// task or a silent push. Until 1.7 the account was admitted, the sample
/// observers registered and the wakes requested only from view tasks, so after
/// the process had died every such launch was refused until someone opened
/// the app. `HealthLogApp.init` runs this once, synchronously, right after the
/// container is built; the view tasks still run later and find it done.
@MainActor
enum LaunchSessionActivation {
    struct Outcome: Equatable {
        /// An account is admitted for this process (restored here or before).
        var sessionAdmitted = false
        /// The background wakes were requested.
        var wakesScheduled = false
        /// The HealthKit sample observers were registered.
        var observersRequested = false
        /// The workout and heart-event importers and the ECG sweep were started.
        var importsStarted = false
    }

    /// The device and account facts and the effects of one launch.
    struct Steps {
        /// The device reads Apple Health at all (not the iPad).
        var readsHealthKit: Bool
        /// The account has seen the HealthKit sheet, the same gate the
        /// foreground activation and the wake scope use. Runs the marker
        /// migration of older installations first.
        var healthKitRequested: () -> Bool
        var scheduleWakes: () -> Void
        /// Registers the sample observers synchronously.
        var armObservers: () -> Void
        /// Starts the workout and heart-event importers and the ECG sweep.
        var startImports: () -> Void = {}
    }

    @discardableResult
    static func run(authStore: AuthStore, steps: Steps) -> Outcome {
        authStore.restoreStoredSessionAtLaunch()
        var outcome = Outcome()
        guard AuthStore.sessionOwner(in: authStore.phase) != nil else {
            HLLog.auth.notice("launch: no stored session admitted, nothing armed")
            return outcome
        }
        outcome.sessionAdmitted = true
        steps.scheduleWakes()
        outcome.wakesScheduled = true
        if steps.readsHealthKit, steps.healthKitRequested() {
            steps.armObservers()
            outcome.observersRequested = true
            steps.startImports()
            outcome.importsStarted = true
        }
        HLLog.auth.notice("launch: stored session admitted before any scene")
        return outcome
    }

    /// Before the first unlock after a restart the Keychain is sealed, so the
    /// restore admits nothing and the launch arms nothing. iOS posts
    /// `protectedDataDidBecomeAvailable` once it opens; on the first such
    /// signal the launch step runs again, unless something else (a scene's
    /// `bootstrap()`) has resolved the session meanwhile.
    ///
    /// - Returns: the outcome of the second run, or `nil` when none ran.
    @discardableResult
    static func retryWhenProtectedDataArrives(
        _ signal: AsyncStream<Void>,
        authStore: AuthStore,
        run: () -> Outcome
    ) async -> Outcome? {
        for await _ in signal {
            guard authStore.phase == .unknown else { return nil }
            HLLog.auth.notice("launch: protected data available, admitting the stored session again")
            return run()
        }
        return nil
    }

    /// The protected-data signal as a stream. Built off the main actor so the
    /// notification task inherits no isolation.
    nonisolated static func protectedDataSignal(named name: Notification.Name) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observation = Task {
                for await _ in NotificationCenter.default.notifications(named: name) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
}

#if canImport(UIKit)
    extension HealthLogApp {
        /// The launch step for the composed container, and its retry after
        /// the first unlock.
        static func activateStoredSession(container: AppContainer, readsHealthKit: Bool) {
            let steps = LaunchSessionActivation.Steps(
                readsHealthKit: readsHealthKit,
                healthKitRequested: { container.hkReadinessStore.migrateRequestedMarkerFromGrants() },
                scheduleWakes: {
                    Task { await container.backgroundSync.scheduleMissingBackgroundWakes() }
                },
                armObservers: {
                    #if canImport(HealthKit) && canImport(SpeziHealthKit)
                        HealthObserverLaunchArming.request()
                    #endif
                },
                startImports: {
                    Task { await container.startHealthImportsAtLaunch() }
                }
            )
            let authStore = container.authStore
            let outcome = LaunchSessionActivation.run(authStore: authStore, steps: steps)
            guard !outcome.sessionAdmitted, authStore.phase == .unknown else { return }
            let signal = LaunchSessionActivation.protectedDataSignal(
                named: UIApplication.protectedDataDidBecomeAvailableNotification
            )
            Task {
                await LaunchSessionActivation.retryWhenProtectedDataArrives(signal, authStore: authStore) {
                    LaunchSessionActivation.run(authStore: authStore, steps: steps)
                }
            }
        }
    }
#endif
