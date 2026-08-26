import Foundation
@testable import HealthLog
import Testing

/// v0.14.1 — locks the subtle sync-caption state machine
/// (`SyncStatusCaption.resolve`). The caption is the discreet last-synced line
/// at the bottom of the Dashboard + Insights scroll content; it must pick
/// first-login-preparing over in-flight over the settled timestamp, and show
/// nothing before the first handshake lands.
///
/// b177 W-SYNCPROGRESS extends the ladder with honest quantities: an in-flight
/// sync carries the outstanding-work count, a settled outbox backlog renders
/// "N ausstehend", and a just-drained outbox gets the short
/// "Daten übermittelt ✓" beat. The pre-b177 self-suppression contract is
/// unchanged — every new arm is gated on a landed handshake.
@Suite("SyncStatusCaption — state resolution")
struct SyncStatusCaptionResolveTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("first-login preparing wins over everything")
    func preparingWins() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: true,
            isInFlight: true,
            activeSyncCount: 7,
            showsDrainConfirmation: true,
            lastHandshakeAt: stamp
        )
        #expect(state == .preparing)
    }

    @Test("in-flight without counts shows the plain syncing line")
    func syncingWhenInFlight() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            isInFlight: true,
            lastHandshakeAt: stamp
        )
        #expect(state == .syncing(pending: 0))
    }

    @Test("in-flight with outstanding work carries the honest count")
    func syncingCarriesCount() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            isInFlight: true,
            activeSyncCount: 23,
            queuedWriteCount: 5,
            lastHandshakeAt: stamp
        )
        #expect(state == .syncing(pending: 23))
    }

    @Test("post-drain confirmation beats the settled timestamp")
    func transmittedAfterDrain() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            isInFlight: false,
            showsDrainConfirmation: true,
            lastHandshakeAt: stamp
        )
        #expect(state == .transmitted)
    }

    @Test("post-drain confirmation stays suppressed before the first handshake")
    func transmittedSuppressedWithoutHandshake() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            isInFlight: false,
            showsDrainConfirmation: true,
            lastHandshakeAt: nil
        )
        #expect(state == .hidden)
    }

    @Test("settled outbox backlog renders the queued count")
    func queuedBacklogWhenSettled() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            isInFlight: false,
            queuedWriteCount: 4,
            lastHandshakeAt: stamp
        )
        #expect(state == .queued(4))
    }

    @Test("queued backlog stays suppressed before the first handshake (standalone)")
    func queuedSuppressedWithoutHandshake() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            isInFlight: false,
            queuedWriteCount: 4,
            lastHandshakeAt: nil
        )
        #expect(state == .hidden)
    }

    // MARK: - b178 W-SYNCVIS — handshake phase machine

    @Test("phase .syncing forces the in-flight line even after the GET landed")
    func phaseSyncingForcesInFlightLine() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            phase: .syncing,
            isInFlight: false,
            activeSyncCount: 3,
            lastHandshakeAt: stamp
        )
        #expect(state == .syncing(pending: 3))
    }

    @Test("phase .done shows the transmitted beat — also read-only (no drain confirmation)")
    func phaseDoneShowsTransmittedReadOnly() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            phase: .done,
            isInFlight: false,
            showsDrainConfirmation: false,
            lastHandshakeAt: stamp
        )
        #expect(state == .transmitted)
    }

    @Test("phase .syncing wins over .done-adjacent flags (most-specific ladder)")
    func phaseSyncingWinsOverDrainConfirmation() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            phase: .syncing,
            isInFlight: false,
            showsDrainConfirmation: true,
            lastHandshakeAt: stamp
        )
        #expect(state == .syncing(pending: 0))
    }

    @Test("phase .idle leaves the pre-b178 ladder untouched")
    func phaseIdleKeepsLegacyLadder() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            phase: .idle,
            isInFlight: false,
            lastHandshakeAt: stamp
        )
        #expect(state == .lastSynced(stamp))
    }

    @Test("settled shows the last-synced timestamp")
    func lastSyncedWhenSettled() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            isInFlight: false,
            lastHandshakeAt: stamp
        )
        #expect(state == .lastSynced(stamp))
    }

    @Test("nothing before the first handshake")
    func hiddenWithoutHandshake() {
        let state = SyncStatusCaption.resolve(
            firstLoginPreparing: false,
            isInFlight: false,
            lastHandshakeAt: nil
        )
        #expect(state == .hidden)
    }
}
