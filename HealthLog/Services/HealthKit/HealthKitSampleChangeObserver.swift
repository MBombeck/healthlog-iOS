#if canImport(HealthKit)
    import Foundation
    import HealthKit
    import Synchronization

    // MARK: - Deliveries wait until the collection is ready

    /// Holds a HealthKit delivery until the collection behind it is ready.
    ///
    /// HealthKit hands a background delivery only to an observer query the
    /// process registered while it launched. The account migration and the
    /// one-time cursor resets must still run before the first page is read, and
    /// they are asynchronous. So the queries are registered at once and their
    /// deliveries wait here until ``open(_:)`` passes the handler in. A delivery
    /// that arrives after ``close()`` is dropped; its HealthKit receipt fires on
    /// its own deadline.
    final class HealthSampleDeliveryGate: Sendable {
        typealias Handler = @Sendable (String) async -> Void

        private struct State {
            var handler: Handler?
            var waiting: [CheckedContinuation<Handler?, Never>] = []
        }

        private let state = Mutex(State())

        var isOpen: Bool {
            state.withLock { $0.handler != nil }
        }

        /// Deliveries waiting for the handler.
        var waitingCount: Int {
            state.withLock { $0.waiting.count }
        }

        /// The collection is ready: every waiting delivery and every later one
        /// goes to `handler`.
        func open(_ handler: @escaping Handler) {
            let waiting = state.withLock { state in
                state.handler = handler
                defer { state.waiting = [] }
                return state.waiting
            }
            for delivery in waiting {
                delivery.resume(returning: handler)
            }
        }

        /// Observing stopped (sign-out): waiting deliveries are dropped.
        func close() {
            let waiting = state.withLock { state in
                state.handler = nil
                defer { state.waiting = [] }
                return state.waiting
            }
            for delivery in waiting {
                delivery.resume(returning: nil)
            }
        }

        /// One delivery for `typeIdentifier`, handled once the gate is open.
        func deliver(_ typeIdentifier: String) async {
            let handler = await withCheckedContinuation { (delivery: CheckedContinuation<Handler?, Never>) in
                state.withLock { state in
                    if let handler = state.handler {
                        delivery.resume(returning: handler)
                    } else {
                        state.waiting.append(delivery)
                    }
                }
            }
            await handler?(typeIdentifier)
        }
    }

    // MARK: - The production observer

    /// Source-targeted `HKObserverQuery` subscriptions, one per type, plus the
    /// background-delivery arming the app declared per type.
    ///
    /// ``register(_:)`` is synchronous so the launch can call it before it
    /// ends, as HealthKit requires for a background delivery. Nonisolated on
    /// purpose: every HealthKit callback closure is built here, off the main
    /// actor, so none of them inherits an isolation it would trap on.
    ///
    /// `@unchecked Sendable` with `NSLock`: the queries and sample types are not
    /// `Sendable`, and the lock is what proves they are touched one at a time.
    final class HealthKitSampleChangeObserver: HealthSampleChangeObserving, @unchecked Sendable {
        private let store: HKHealthStore
        private let gate = HealthSampleDeliveryGate()
        private let lock = NSLock()
        private var queries: [String: HKObserverQuery] = [:]
        private var backgroundArmed: [String: HKSampleType] = [:]

        init(store: HKHealthStore) {
            self.store = store
        }

        /// Registers the observer query of every type not yet registered and
        /// asks for its background delivery. Returns the number of queries
        /// registered by this call.
        @discardableResult
        func register(_ typeIdentifiers: [String]) -> Int {
            var registered = 0
            for identifier in typeIdentifiers {
                guard let sampleType = HealthKitSampleTypeResolver.sampleType(for: identifier) else { continue }
                let query: HKObserverQuery? = lock.withLock {
                    guard queries[identifier] == nil else { return nil }
                    let query = makeQuery(sampleType, identifier: identifier)
                    queries[identifier] = query
                    return query
                }
                guard let query else { continue }
                store.execute(query)
                registered += 1
                armBackgroundDelivery(sampleType, identifier: identifier)
            }
            return registered
        }

        func startObserving(
            _ typeIdentifiers: [String],
            onChange: @escaping @Sendable (String) async -> Void
        ) async {
            register(typeIdentifiers)
            gate.open(onChange)
        }

        func stopObserving() async {
            gate.close()
            let (stoppedQueries, armedTypes) = lock.withLock {
                defer {
                    queries = [:]
                    backgroundArmed = [:]
                }
                return (Array(queries.values), Array(backgroundArmed.values))
            }
            for query in stoppedQueries {
                store.stop(query)
            }
            for sampleType in armedTypes {
                try? await store.disableBackgroundDelivery(for: sampleType)
            }
        }

        private func makeQuery(_ sampleType: HKSampleType, identifier: String) -> HKObserverQuery {
            let gate = gate
            return HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                // The completion handler is HealthKit's own delivery receipt.
                // It is called exactly once on every path, including the
                // error path, so a transient failure does not stop future
                // deliveries. After the delivery was collected and its sweeps
                // ran, not before: until 1.1.1 it was called at once and iOS
                // could suspend the process with the work still in flight. The
                // deadline keeps a slow network, or a collection that is not
                // ready yet, from holding it past HealthKit's patience.
                HealthKitDeliveryReceipt.deliver(error: error, completionHandler: completionHandler) {
                    await gate.deliver(identifier)
                }
            }
        }

        private func armBackgroundDelivery(_ sampleType: HKSampleType, identifier: String) {
            guard HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: identifier) else { return }
            lock.withLock { backgroundArmed[identifier] = sampleType }
            store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, _ in
                guard !success else { return }
                // A refused arming is a reachability fact about this device,
                // not a data fault: the type still collects on every pull
                // trigger. The identifier is a fixed HealthKit constant, never
                // a value and never an account.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.info(
                    "background delivery unavailable [\(identifier, privacy: .public)] — pull triggers still collect"
                )
            }
        }
    }
#endif
