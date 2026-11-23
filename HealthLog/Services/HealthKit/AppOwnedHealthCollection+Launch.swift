#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import Synchronization

    // MARK: - Observers armed when the process starts

    /// The sample observers at process start.
    ///
    /// HealthKit hands a background delivery only to an observer query that is
    /// registered again on every launch, while the launch is still running. A
    /// launch without a scene never reached the first pass that used to
    /// register them. So the launch does two things: ``request()`` registers
    /// every observer query synchronously, before it returns, and then starts
    /// the preparation (migration, one-time resets) off the main actor. A
    /// delivery that arrives in between waits for that preparation
    /// (``HealthSampleDeliveryGate``), never the registration.
    ///
    /// Nonisolated and lock-guarded, so the composition installs it while the
    /// container is built.
    enum HealthObserverLaunchArming {
        /// Registers the observer queries; answers how many were new.
        typealias Register = @Sendable () -> Int
        /// Prepares the collection and opens the deliveries; `false` when no
        /// account is admitted.
        typealias Prepare = @Sendable () async -> Bool

        private struct Steps {
            let register: Register
            let prepare: Prepare
        }

        private struct State {
            var steps: Steps?
            var requested = false
        }

        private static let state = Mutex(State())

        /// Installs the two steps. A launch that asked before the composition
        /// finished is served now, so the order of the two never matters.
        @discardableResult
        static func install(
            register: @escaping Register,
            prepare: @escaping Prepare
        ) -> Task<Bool, Never>? {
            let steps = Steps(register: register, prepare: prepare)
            let pending = state.withLock { state -> Bool in
                state.steps = steps
                defer { state.requested = false }
                return state.requested
            }
            return pending ? run(steps) : nil
        }

        /// Registers the observers of this process now and prepares the
        /// collection behind them, or remembers the request until
        /// ``install(register:prepare:)`` runs.
        @discardableResult
        static func request() -> Task<Bool, Never>? {
            let installed = state.withLock { state -> Steps? in
                if state.steps == nil { state.requested = true }
                return state.steps
            }
            guard let installed else { return nil }
            return run(installed)
        }

        #if DEBUG
            static func resetForTesting() {
                state.withLock { $0 = State() }
            }
        #endif

        private static func run(_ steps: Steps) -> Task<Bool, Never> {
            let registered = steps.register()
            HLLog.healthKit.notice("launch: \(registered) sample observers registered")
            return Task.detached(priority: .userInitiated) {
                let ready = await steps.prepare()
                if ready {
                    HLLog.healthKit.notice("launch: sample observers armed")
                } else {
                    HLLog.healthKit.notice("launch: no admitted account, deliveries wait for the first pass")
                }
                return ready
            }
        }
    }

    extension AppOwnedHealthCollectionCoordinator {
        /// The types the launch registers: the same set the first pass
        /// observes.
        static var launchObservedTypeIdentifiers: [String] {
            serverCollectable(observedTypeIdentifiers)
        }

        /// The pass preparation without the pass: migration, the one-time
        /// resets and the opening of the deliveries, under a fresh admission.
        /// `false` when no account is admitted; the deliveries then wait.
        func armAtLaunch() async -> Bool {
            guard let lease = try? admission() else { return false }
            await prepare(lease: lease, window: cutoff())
            return true
        }
    }
#endif
