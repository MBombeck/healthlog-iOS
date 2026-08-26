@testable import HealthLog
import Testing

/// Locks the per-provider connected-badge derivation for the Settings →
/// Integrations list (`IntegrationConnectedState`). R5: Withings + WHOOP must
/// show the "Connected" badge when actually connected — not Apple-Health-only —
/// and must NOT flash a false "Connected" before status loads.
@Suite("IntegrationConnectedState")
struct IntegrationConnectedStateTests {
    // MARK: - WHOOP (configured && connected)

    @Test("WHOOP configured + connected → badge shown")
    func whoopConfiguredAndConnected() {
        let status = WhoopStatus(
            connected: true,
            configured: true,
            lastSyncedAt: nil,
            connectedAt: nil,
            tokenExpired: nil,
            tokenExpiresAt: nil,
            backfillCompleted: nil,
            scope: nil
        )
        #expect(IntegrationConnectedState.whoop(status) == true)
    }

    @Test("WHOOP configured but not connected → badge hidden")
    func whoopConfiguredNotConnected() {
        let status = WhoopStatus(
            connected: false,
            configured: true,
            lastSyncedAt: nil,
            connectedAt: nil,
            tokenExpired: nil,
            tokenExpiresAt: nil,
            backfillCompleted: nil,
            scope: nil
        )
        #expect(IntegrationConnectedState.whoop(status) == false)
    }

    @Test("WHOOP connected but not configured → not connected")
    func whoopConnectedNotConfigured() {
        let status = WhoopStatus(
            connected: true,
            configured: false,
            lastSyncedAt: nil,
            connectedAt: nil,
            tokenExpired: nil,
            tokenExpiresAt: nil,
            backfillCompleted: nil,
            scope: nil
        )
        #expect(IntegrationConnectedState.whoop(status) == false)
    }

    @Test("WHOOP no status loaded → unknown (nil), no false badge")
    func whoopUnloaded() {
        #expect(IntegrationConnectedState.whoop(nil) == nil)
    }

    // MARK: - Withings (connected)

    @Test("Withings connected → badge shown")
    func withingsConnected() {
        let status = WithingsStatus(
            connected: true,
            configured: true,
            lastSyncedAt: nil,
            connectedAt: nil,
            tokenExpired: nil,
            tokenRefreshFailed: nil,
            tokenExpiresAt: nil,
            scope: nil,
            hasActivityScope: nil
        )
        #expect(IntegrationConnectedState.withings(status) == true)
    }

    @Test("Withings not connected → badge hidden")
    func withingsNotConnected() {
        let status = WithingsStatus(
            connected: false,
            configured: false,
            lastSyncedAt: nil,
            connectedAt: nil,
            tokenExpired: nil,
            tokenRefreshFailed: nil,
            tokenExpiresAt: nil,
            scope: nil,
            hasActivityScope: nil
        )
        #expect(IntegrationConnectedState.withings(status) == false)
    }

    @Test("Withings no status loaded → unknown (nil), no false badge")
    func withingsUnloaded() {
        #expect(IntegrationConnectedState.withings(nil) == nil)
    }
}
