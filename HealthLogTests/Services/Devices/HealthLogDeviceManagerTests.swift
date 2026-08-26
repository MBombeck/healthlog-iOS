@testable import HealthLog
import Testing

/// Smoke coverage for `HealthLogDeviceManager` — **v0.5.6 F.1 scaffolding
/// invariant lock.**
///
/// F.1 ships the manager as an inert read-only facade: `pairedDevices` is
/// always `[]`. This suite encodes that contract so v0.5.6.1 (F.2) cannot
/// accidentally regress the "no BLE prompt on F.1" guarantee — the
/// `SettingsDevicesScreen` empty-state branch is conditioned on
/// `pairedDevices.isEmpty`, and if a future patch wires live state into
/// the F.1 build the screen would silently transition into a populated
/// surface, potentially showing a "Gerät hinzufügen" button that no longer
/// reflects the disabled-by-design F.1 contract.
///
/// When F.2 lands, this suite expands to cover the `bind(to:)` seam
/// (manager observing the `PairedDevices` module projection) and the
/// `disconnect()` symmetry for logout cleanup.
@MainActor
@Suite("HealthLogDeviceManager — F.1 inert scaffolding contract")
struct HealthLogDeviceManagerTests {
    @Test("init exposes an empty pairedDevices list")
    func initIsEmpty() {
        let manager = HealthLogDeviceManager()
        #expect(manager.pairedDevices.isEmpty)
    }

    @Test("repeated init stays empty (idempotent F.1 invariant)")
    func multipleInstancesStayEmpty() {
        let a = HealthLogDeviceManager()
        let b = HealthLogDeviceManager()
        #expect(a.pairedDevices.isEmpty)
        #expect(b.pairedDevices.isEmpty)
        // Sanity: distinct instances so F.2 can rely on per-screen
        // `@State` semantics until it promotes the manager to env.
        #expect(a !== b)
    }
}
