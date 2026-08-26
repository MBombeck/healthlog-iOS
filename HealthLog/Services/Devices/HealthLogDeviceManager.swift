#if canImport(SpeziDevices)
    import Observation
    import SpeziDevices

    /// `@MainActor @Observable` thin facade over Spezi's `PairedDevices`
    /// module — **F.2 complete (wired + reachable)**.
    ///
    /// **What this does today:**
    /// `bind(to:forwarder:)` binds the running `PairedDevices` module and the
    /// `DeviceReadingForwarder` actor; `pairedDevices` projects the live
    /// `PairedDevices.pairedDevices` snapshot the Settings → Geräte screen
    /// renders. `AppContainer+SpeziDevices.resolveSpeziDevicesIfAvailable`
    /// resolves the module out of `SpeziAppDelegate.spezi` after boot and
    /// calls `bind(to:forwarder:)`; `SettingsDevicesScreen` mounts the
    /// `AccessorySetupSheet` and forwards readings through the real
    /// `DeviceReadingForwarder`. Reachable via `SettingsScreen` →
    /// `.devices`.
    ///
    /// **Why not let the screen read `@Environment(PairedDevices.self)`
    /// directly?**
    /// `PairedDevices` is a Spezi `Module` and is reachable via the
    /// environment after `.spezi(_:)` runs, but the screen must compile +
    /// render even in test or preview contexts where the Spezi delegate has
    /// not booted. A thin manager keeps the read-side stable: the screen
    /// always reads `manager.pairedDevices`, and the binding swaps in the
    /// live `Module` projection without churning every call-site.
    ///
    /// **Concurrency:**
    /// `@MainActor @Observable` matches the rest of the app's store layer
    /// (`SettingsStore`, `AuthStore`, etc.) and lines up with
    /// `PairedDevices.pairedDevices` which is annotated `@MainActor public
    /// var` upstream. No `@unchecked Sendable` escape hatch needed.
    ///
    /// **`#else` build-stub branch:** on platforms where `SpeziDevices` is
    /// not linkable the manager compiles to an inert stub (empty
    /// `pairedDevices`, no-op `refreshPairedDevices()`) so the screen still
    /// renders the unavailable state.
    @MainActor
    @Observable
    public final class HealthLogDeviceManager {
        /// Snapshot of paired devices the Settings → Geräte screen renders.
        /// F.2: mirror the live `PairedDevices.pairedDevices` projection
        /// after `bind(to:forwarder:)` runs. Until then this stays empty
        /// (preserves the F.1 "no BLE prompt on launch" invariant).
        public private(set) var pairedDevices: [PairedDeviceInfo] = []

        /// Reading forwarder this manager hands off to when the operator
        /// confirms a measurement on the `MeasurementsRecordedSheet`.
        /// `nil` until `bind(to:forwarder:)` runs (test contexts + the
        /// pre-Spezi-boot paint phase).
        public private(set) var forwarder: DeviceReadingForwarder?

        /// Resolved `PairedDevices` module reference held weakly via
        /// `@ObservationIgnored` since the upstream type is its own
        /// `@Observable` — observing the same field through two layers
        /// would just double-up SwiftUI updates without adding info.
        @ObservationIgnored private var pairedDevicesModule: PairedDevices?

        /// Nonisolated so callers in non-MainActor contexts (e.g. the
        /// SwiftUI `@State private var manager = HealthLogDeviceManager()`
        /// stored-property initializer, which runs in the implicit nonisolated
        /// init of the host `View` struct unless the View itself is
        /// `@MainActor`) can construct the facade without an `await`.
        /// The body of this init touches no MainActor state — the
        /// `pairedDevices` property is initialised to an empty literal at
        /// the declaration site and the `@Observable` macro's storage
        /// allocation is `Sendable`.
        public nonisolated init() {}

        /// Wire the manager to the running `PairedDevices` Spezi module
        /// + the `DeviceReadingForwarder` so the Settings → Geräte screen
        /// can render the live paired list and the `MeasurementsRecorded-
        /// Sheet` save callback can forward through the same uploader the
        /// rest of the HK pipeline already uses.
        ///
        /// Idempotent — re-calling overwrites both refs. Safe to call from
        /// `AppContainer+SpeziDevices.resolveSpeziDevicesIfAvailable`
        /// every cold launch (matches the `attachSpeziStandardUploader`
        /// shape exactly).
        public func bind(
            to pairedDevices: PairedDevices,
            forwarder: DeviceReadingForwarder
        ) {
            pairedDevicesModule = pairedDevices
            self.forwarder = forwarder
            self.pairedDevices = pairedDevices.pairedDevices ?? []
        }

        /// Refresh the cached paired-list snapshot from the bound
        /// `PairedDevices` module. The screen calls this on
        /// `.task { ... }` / `.onChange(of: scenePhase)` so the SwiftUI
        /// tree picks up additions from the `AccessorySetupSheet` pair
        /// flow without a full re-bind cycle.
        ///
        /// No-op when no module is bound (test / preview contexts).
        public func refreshPairedDevices() {
            guard let pairedDevicesModule else { return }
            pairedDevices = pairedDevicesModule.pairedDevices ?? []
        }
    }
#else
    import Foundation
    import Observation

    /// Build-stub for SDK / CI contexts without `SpeziDevices` linked.
    /// Mirrors the public surface so the screen + DI extension compile
    /// unconditionally. Real implementation lives in the `#if canImport`
    /// branch above.
    @MainActor
    @Observable
    public final class HealthLogDeviceManager {
        /// Placeholder type the stub branch returns. Source-compatible with
        /// the real `PairedDeviceInfo` for the read-only F.1 surface (the
        /// screen only checks `isEmpty`).
        public struct PairedDeviceInfo: Sendable {}

        public private(set) var pairedDevices: [PairedDeviceInfo] = []

        /// Stub-branch forwarder placeholder (always `nil`). The real
        /// branch holds a `DeviceReadingForwarder?`; the stub branch only
        /// has to keep the property visible on the public surface so the
        /// screen can render its disabled state identically across both
        /// build configurations.
        public private(set) var forwarder: DeviceReadingForwarderStub?

        public nonisolated init() {}

        public func refreshPairedDevices() {}
    }

    /// Stub forwarder type so non-Spezi build configurations can still
    /// name `manager.forwarder` without bringing the HealthKit + Spezi
    /// dependency surface into the compilation unit.
    public struct DeviceReadingForwarderStub: Sendable {}
#endif
