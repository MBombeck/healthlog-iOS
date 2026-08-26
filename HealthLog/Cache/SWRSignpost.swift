import Foundation
import os

/// **Phase 21 (21-01) — first-paint instrumentation for the SWR layer.**
///
/// `SWRCache` is a `@ModelActor`: every SWR-backed surface awaits `read`
/// before it can yield `.cached` or `.empty`, so every surface's first paint
/// queues on one serial executor. Before Phase 21 moved anything, it had to
/// become possible to *say* how long each surface waited there and how much of
/// that wait was its own work rather than somebody else's — 21-01 measures,
/// 21-02 changes, 21-02 re-measures against this same instrument.
///
/// **Two witnesses, deliberately:**
///
/// 1. `OSSignposter` intervals, readable in Instruments on a device or
///    simulator with no test harness in the picture at all. That is the
///    witness that survives this phase and serves whatever asks next.
/// 2. A DEBUG-only in-process recorder, because an `OSSignposter` writes into
///    a trace buffer that nothing can read back in-process — and a measurement
///    nobody can assert is a measurement nobody can regress. The recorder
///    keeps *begin and end instants*, not just durations, because the claim
///    under test is about **overlap**: two keys that never overlap are
///    serialized, and a duration alone cannot say that.
///
/// **Why this is not `HLPerfSignpost`.** `HealthLog/Cache/` is compiled into
/// the platform-free SPM `Core` target (`Package.swift`, the bare `"Cache"`
/// entry) and `HLPerfSignpost` lives in `DesignSystem/` and imports SwiftUI.
/// Reusing it would break the module-purity gate that 09-15 found had never
/// actually run. Foundation + `os` only, here — the same envelope
/// `Services/Logger.swift` already compiles under in Core.
///
/// **Zero behavioural effect.** `OSSignposter` compiles to a no-op when
/// nothing is tracing; the recorder is `#if DEBUG` and `nil` unless a test
/// installs one; and every interval closes from a `defer`, so a throwing or
/// cancelled body cannot leave one open (an interval that never closes is
/// worse than no interval — it silently poisons everything around it).
public enum SWRSignpost {
    /// Own category rather than `.pointsOfInterest`: these fire once per cache
    /// read, which is far too often to belong in the timeline ribbon that the
    /// first-paint budgets use.
    static let signposter = OSSignposter(subsystem: "dev.healthlog.app", category: "SWR")

    /// Named intervals so call-sites stay typo-safe and a trace reads cleanly.
    ///
    /// The raw value is a `String` (the recorder filters on it) and
    /// ``signpostName`` repeats it as a `StaticString` (what `OSSignposter`
    /// takes). They cannot be the same declaration: an enum cannot carry a
    /// `StaticString` raw type here, because `RawRepresentable` synthesis needs
    /// an `Equatable` raw type and `StaticString` is not one. `HLPerfSignpost`
    /// gets away with it only because it is app-target-only; `Cache/` also
    /// compiles into the widget extension, where the synthesis is demanded.
    public enum Interval: String, Sendable, CaseIterable {
        /// The `modelContext.fetch` inside `SWRCache.read` — actor-confined by
        /// SwiftData and therefore **not** movable.
        case readFetch = "swr.read.fetch"
        /// The `JSONDecoder.decode` of the fetched payload — pure, `Sendable`
        /// in and out, and therefore the one thing 21-02 can move.
        case readDecode = "swr.read.decode"
        /// One `sweepOlderThan` / `sweepKeepingNewest` — two `fetchCount`
        /// scans, a batch delete and a `save()`, on the same serial executor
        /// as every surface's first read.
        case sweep = "swr.sweep"

        var signpostName: StaticString {
            switch self {
            case .readFetch: "swr.read.fetch"
            case .readDecode: "swr.read.decode"
            case .sweep: "swr.sweep"
            }
        }
    }

    /// Run `work` inside a balanced interval.
    ///
    /// The `defer` is the only exit, so the interval closes on return, on
    /// `throw` and on cancellation alike. Non-escaping and synchronous on
    /// purpose: it is called from inside `@ModelActor` methods, and a closure
    /// that changed the isolation of the work would change the thing being
    /// measured.
    ///
    /// `key` is a `CacheKey.canonicalString` — enum-shaped canonical paths
    /// carrying no user data, which is why the rest of this file treats them
    /// as operator-grade the way `SWRCache`'s own log lines already do.
    @inline(__always)
    static func measure<T>(
        _ interval: Interval,
        key: String,
        bytes: Int = 0,
        _ work: () throws -> T
    ) rethrows -> T {
        let state = signposter.beginInterval(interval.signpostName, id: signposter.makeSignpostID())
        #if DEBUG
            let started = DispatchTime.now().uptimeNanoseconds
        #endif
        defer {
            signposter.endInterval(interval.signpostName, state)
            #if DEBUG
                recorder?.record(
                    Record(
                        interval: interval.rawValue,
                        key: key,
                        bytes: bytes,
                        startedAt: started,
                        endedAt: DispatchTime.now().uptimeNanoseconds
                    )
                )
            #endif
        }
        return try work()
    }

    // MARK: - Test observation

    #if DEBUG
        /// One closed interval, as observed by a test.
        ///
        /// `startedAt`/`endedAt` are `DispatchTime` uptime nanoseconds:
        /// monotonic, and comparable across threads and executors, which is
        /// the whole point — the question this instrument answers is whether
        /// two keys' intervals ever overlap.
        public struct Record: Sendable, Equatable {
            public let interval: String
            public let key: String
            public let bytes: Int
            public let startedAt: UInt64
            public let endedAt: UInt64

            public var durationNanos: UInt64 {
                endedAt &- startedAt
            }

            public var durationMillis: Double {
                Double(durationNanos) / 1_000_000
            }

            /// True when the two intervals were in flight at the same instant.
            /// Serialization is exactly the absence of this.
            public func overlaps(_ other: Record) -> Bool {
                startedAt < other.endedAt && other.startedAt < endedAt
            }
        }

        /// Collects closed intervals. Install one with ``installRecorder(_:)``
        /// and remove it in the same test.
        public final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [Record] = []

            public init() {}

            /// Synchronous on purpose: it is called from `defer` blocks inside
            /// actor-isolated functions, where awaiting is unavailable.
            func record(_ record: Record) {
                lock.lock()
                defer { lock.unlock() }
                storage.append(record)
            }

            public var records: [Record] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }

            public func records(for interval: Interval) -> [Record] {
                records.filter { $0.interval == interval.rawValue }
            }

            public func reset() {
                lock.lock()
                defer { lock.unlock() }
                storage.removeAll()
            }
        }

        private final class RecorderBox: @unchecked Sendable {
            private let lock = NSLock()
            private var current: Recorder?

            func install(_ recorder: Recorder?) {
                lock.lock()
                defer { lock.unlock() }
                current = recorder
            }

            func value() -> Recorder? {
                lock.lock()
                defer { lock.unlock() }
                return current
            }
        }

        private static let recorderBox = RecorderBox()

        private static var recorder: Recorder? {
            recorderBox.value()
        }

        /// Install (or, with `nil`, remove) the test recorder.
        public static func installRecorder(_ recorder: Recorder?) {
            recorderBox.install(recorder)
        }
    #endif
}
