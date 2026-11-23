import Foundation
import Observation

/// **Holds the answer to "does this device plan the local reminders?"**
///
/// The rule itself is ``ReminderDevicePolicy``; this owns its inputs and its
/// result. An iPhone or a Duo always plans and never asks the server anything.
/// An iPad asks `GET /api/auth/me/devices` (at most once per
/// ``refreshInterval`` unless forced), remembers the last answer so a background
/// wake that starts the process cold decides the same way the foreground did,
/// and calls ``onPlanningChanged`` when the answer flips so the planners arm or
/// purge at once.
///
/// Until the first answer an iPad that has never decided plans: better twice
/// than not at all.
@MainActor
@Observable
final class ReminderPlanningCoordinator {
    typealias DeviceLoader = @Sendable () async throws -> [ReminderDevice]

    static let lastDecisionKey = "hl.reminders.plansLocally.lastDecision"
    static let overrideKey = "hl.reminders.alsoOnThisPad"
    static let refreshInterval: TimeInterval = 15 * 60

    /// Whether the local planners arm reminders on this device.
    private(set) var plansLocally: Bool
    /// Whether another iPhone of the account was active at the last answer. The
    /// Notifications screen shows its note and switch only then, on an iPad.
    private(set) var otherPhoneIsActive = false

    /// The user's additive choice, "Auch auf diesem iPad erinnern". Local to
    /// this device, off by default.
    var alsoOnThisDevice: Bool {
        didSet {
            guard alsoOnThisDevice != oldValue, !isResetting else { return }
            defaults.set(alsoOnThisDevice, forKey: Self.overrideKey)
            apply(devices: lastDevices, now: clock())
        }
    }

    /// Called after the answer changed, on the main actor.
    @ObservationIgnored var onPlanningChanged: (@MainActor () -> Void)?

    @ObservationIgnored private let idiom: DeviceIdiom
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loadDevices: DeviceLoader
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var lastDevices: [ReminderDevice]?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var isResetting = false

    init(
        idiom: DeviceIdiom,
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { .now },
        loadDevices: @escaping DeviceLoader
    ) {
        self.idiom = idiom
        self.defaults = defaults
        self.clock = clock
        self.loadDevices = loadDevices
        let override = defaults.bool(forKey: Self.overrideKey)
        alsoOnThisDevice = override
        if idiom == .pad {
            plansLocally = override || (defaults.object(forKey: Self.lastDecisionKey) as? Bool ?? true)
        } else {
            plansLocally = true
        }
    }

    /// Whether this device is a pad, for the screen that explains the rule.
    var isPad: Bool {
        idiom == .pad
    }

    /// Re-reads the device list and re-decides. A phone returns at once.
    func refresh(force: Bool = false) async {
        guard idiom == .pad else { return }
        let now = clock()
        if !force, let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        if let inFlight {
            await inFlight.value
            return
        }
        lastRefresh = now
        let loader = loadDevices
        let task = Task { [weak self] in
            let devices = try? await loader()
            guard let self else { return }
            apply(devices: devices, now: clock())
            inFlight = nil
        }
        inFlight = task
        await task.value
    }

    /// Forgets everything that belonged to the signed-out account: the device
    /// list, the remembered answer and the switch. The next account decides
    /// afresh; until its first answer an iPad plans.
    func reset() {
        inFlight?.cancel()
        inFlight = nil
        lastDevices = nil
        lastRefresh = nil
        otherPhoneIsActive = false
        defaults.removeObject(forKey: Self.lastDecisionKey)
        defaults.removeObject(forKey: Self.overrideKey)
        isResetting = true
        alsoOnThisDevice = false
        isResetting = false
        plansLocally = true
    }

    /// Fire-and-forget refresh for callers that cannot await (store callbacks).
    func requestRefresh() {
        guard idiom == .pad else { return }
        Task { await refresh() }
    }

    private func apply(devices: [ReminderDevice]?, now: Date) {
        lastDevices = devices
        otherPhoneIsActive = devices.map { ReminderDevicePolicy.hasActivePhone($0, now: now) } ?? false
        let next = ReminderDevicePolicy.plansLocally(
            idiom: idiom,
            devices: devices,
            override: alsoOnThisDevice,
            now: now
        )
        // The remembered answer is the device-list answer, not the override:
        // switching the choice off must fall back to what the list says.
        let listAnswer = ReminderDevicePolicy.plansLocally(idiom: idiom, devices: devices, override: false, now: now)
        defaults.set(listAnswer, forKey: Self.lastDecisionKey)
        guard next != plansLocally else { return }
        plansLocally = next
        onPlanningChanged?()
    }
}
