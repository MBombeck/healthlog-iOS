import Foundation
import Network

public protocol ReachabilityProviding: Sendable {
    var isOnlineStream: AsyncStream<Bool> { get async }
    func isCurrentlyOnline() async -> Bool
    /// Interface-up **and** server-confirmed reachable. See
    /// ``Reachability/confirmedReachable()`` for the captive-portal rationale.
    func confirmedReachable() async -> Bool
}

public extension ReachabilityProviding {
    /// Default conformance so existing test doubles + previews that only
    /// model interface state keep compiling: fall back to the interface
    /// signal. Production ``Reachability`` overrides this with the
    /// `/api/health` probe gate.
    func confirmedReachable() async -> Bool {
        await isCurrentlyOnline()
    }
}

public actor Reachability: ReachabilityProviding {
    private let monitor = NWPathMonitor()
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var currentlyOnline: Bool = true
    private var started = false

    /// Server-liveness probe injected after the APIClient exists (the
    /// composition root builds `Reachability` before `APIClient`). When
    /// `nil`, ``confirmedReachable()`` degrades to the interface signal so
    /// the app never blocks on an un-wired probe.
    private var probe: (@Sendable () async -> Bool)?
    /// Debounce window — a successful probe result is reused for this long
    /// so a burst of reachability edges (rapid background↔foreground, or
    /// several stores asking at once) does not fan out into a probe storm.
    private let probeTTL: TimeInterval
    private var lastProbeResult: Bool?
    private var lastProbeAt: Date?
    private var clock: @Sendable () -> Date

    public init(
        probeTTL: TimeInterval = 10,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.probeTTL = probeTTL
        self.clock = clock
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.update(path: path) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.healthlog.app.reachability", qos: .utility))
    }

    private func update(path: NWPath) {
        let online = path.status == .satisfied
        currentlyOnline = online
        // An interface transition invalidates any cached probe verdict —
        // the next `confirmedReachable()` re-probes the new path.
        lastProbeResult = nil
        lastProbeAt = nil
        for cont in continuations.values {
            cont.yield(online)
        }
    }

    public var isOnlineStream: AsyncStream<Bool> {
        get async {
            startIfNeeded()
            let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
            let id = UUID()
            register(id: id, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
            return stream
        }
    }

    private func register(id: UUID, continuation: AsyncStream<Bool>.Continuation) {
        continuations[id] = continuation
        continuation.yield(currentlyOnline)
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    public func isCurrentlyOnline() async -> Bool {
        startIfNeeded()
        return currentlyOnline
    }

    /// Composition-root setter — `AppContainer` wires the `/api/health`
    /// probe here after the `APIClient` is built. Idempotent.
    public func setProbe(_ probe: @escaping @Sendable () async -> Bool) {
        self.probe = probe
    }

    /// Interface-up **and** the server actually answered.
    ///
    /// `NWPathMonitor` reports `.satisfied` behind a captive portal even
    /// though API traffic is blocked, so the Outbox replay loop used to
    /// fire writes that hang until the URLSession timeout and then fail
    /// (QoL-3-H-3). This gate first checks the cheap interface state and
    /// only then runs the injected `/api/health` probe, debounced for
    /// `probeTTL` seconds so concurrent callers / reachability bursts do
    /// not produce a probe storm.
    ///
    /// Degrades to the interface signal when no probe is wired, so the
    /// gate is always safe to call (it can only ever be *more* strict than
    /// the raw interface state).
    public func confirmedReachable() async -> Bool {
        startIfNeeded()
        guard currentlyOnline else { return false }
        guard let probe else { return true }

        let now = clock()
        if let result = lastProbeResult,
           let at = lastProbeAt,
           now.timeIntervalSince(at) < probeTTL
        {
            return result
        }

        let result = await probe()
        // The path may have flipped while the probe was in flight; only
        // cache a verdict that still matches the current interface state.
        if currentlyOnline {
            lastProbeResult = result
            lastProbeAt = clock()
        }
        return result && currentlyOnline
    }
}
