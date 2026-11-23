import Foundation
import Observation

/// **Single source of truth** for whether cycle tracking is offered to the
/// current user. Future callers (the "Erfassen" capture picker, the Settings
/// cycle entry, the calendar surface) read `isCycleTrackingAvailable` from
/// THIS gate — never a scattered `if gender == "female"` check.
///
/// `@MainActor @Observable` so SwiftUI surfaces can read it during `body`
/// evaluation without a hop. The pure truth-table is delegated to
/// ``CycleGateResolver`` (HealthLogCore) so it is unit-tested platform-free.
///
/// **No HealthKit coupling here.** The biological-sex fallback is supplied by
/// an injected `@Sendable` closure (`biologicalSexProvider`) that AppContainer
/// wires to a *no-prompt* read of an already-granted characteristic. The gate
/// NEVER triggers a permission prompt and NEVER reads biological sex for men —
/// it only consults the closure, and the closure returns `.unknown` whenever
/// HK auth was not independently granted (see `RESEARCH-cycle.md` §2).
@MainActor
@Observable
public final class CycleGate {
    /// The resolved decision. Read by capture-picker / settings / calendar.
    /// Recomputed via ``refresh()`` after profile load + on foreground.
    public private(set) var isCycleTrackingAvailable: Bool = false

    private let settings: SettingsStore
    /// Server-authoritative module gate. When the `modules` map is
    /// present AND carries a `cycle` key, that value WINS (server is the single
    /// source of truth). When the map is absent (older server / not loaded),
    /// the gate falls back to the local gender/opt-in resolution below — so
    /// nothing changes for prod ≤ v1.17.1 until the #30 deploy goes live.
    private let moduleGate: ModuleGate?
    /// No-prompt biological-sex read. Returns `.unknown` unless HK auth was
    /// already granted independently. Async + injected so the gate stays HK-free
    /// (the closure hops to the HealthKit actor, which reads the *cached*
    /// characteristic without ever prompting). The resolved signal is cached in
    /// ``cachedBiologicalSex`` so the synchronous ``recompute()`` can read it.
    private let biologicalSexProvider: @Sendable () async -> CycleGateResolver.BiologicalSexSignal
    /// Last resolved biological-sex signal. `.unknown` until the first
    /// ``refreshAsync()`` populates it (so the gate never blocks `body`).
    private var cachedBiologicalSex: CycleGateResolver.BiologicalSexSignal = .unknown

    public init(
        settings: SettingsStore,
        moduleGate: ModuleGate? = nil,
        biologicalSexProvider: @escaping @Sendable () async -> CycleGateResolver.BiologicalSexSignal = { .unknown }
    ) {
        self.settings = settings
        self.moduleGate = moduleGate
        self.biologicalSexProvider = biologicalSexProvider
        recompute()
    }

    /// Recompute the gate from the current inputs. Cheap + synchronous — call
    /// after `SettingsStore.load()` resolves and on app-foreground.
    public func refresh() {
        recompute()
    }

    /// Refresh the cached biological-sex signal (no-prompt HK read), then
    /// recompute. Call from the async gate-lifecycle pass so resolution path #3
    /// (server gender unknown → HK `biologicalSex == .female`) can fire.
    public func refreshAsync() async {
        cachedBiologicalSex = await biologicalSexProvider()
        recompute()
    }

    private func recompute() {
        // Server module map WINS when present. A `cycle` key explicitly
        // set to `false` hides the feature regardless of gender/opt-in. When
        // the map is absent (older server / not yet loaded) the local
        // gender/opt-in resolution below is the fallback — unchanged behaviour
        // until the #30 deploy goes live.
        if let moduleGate, let map = moduleGate.modules, let serverCycle = map[ModuleKey.cycle.wireKey] {
            isCycleTrackingAvailable = serverCycle
            return
        }

        let input = CycleGateResolver.Input(
            profileGender: settings.profile?.gender,
            biologicalSex: cachedBiologicalSex,
            explicitOptIn: settings.cycleTrackingOptIn
        )
        isCycleTrackingAvailable = CycleGateResolver.isAvailable(input)
    }
}
