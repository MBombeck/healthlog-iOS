import Foundation
@testable import HealthLog
import Testing

/// **v0.12 P2 — watch contract round-trip.** The phone + watch exchange a
/// single JSON blob under a plist-safe key. These guard the wire format
/// against drift (a break here would silently stop the watch updating /
/// acting).
@Suite("WatchTransport")
struct WatchTransportTests {
    @Test("Snapshot round-trips through encode/decode")
    func snapshotRoundTrip() throws {
        let snapshot = WatchSnapshot(
            doses: [
                WatchSnapshot.Dose(
                    id: "intake-1",
                    medicationName: "Lisinopril",
                    doseText: "5 mg",
                    scheduledAt: Date(timeIntervalSince1970: 1_700_000_000),
                    isTaken: false,
                    isActionable: true,
                    isInjection: false
                ),
                WatchSnapshot.Dose(
                    id: "synth:med-2:123",
                    medicationName: "Trulicity",
                    doseText: "2.5 mg",
                    scheduledAt: Date(timeIntervalSince1970: 1_700_003_600),
                    isTaken: true,
                    isActionable: false,
                    isInjection: true
                )
            ],
            scheduledCount: 2,
            takenCount: 1,
            recentMoodScore: 4,
            signedIn: true,
            generatedAt: Date(timeIntervalSince1970: 1_700_010_000)
        )

        let payload = WatchTransport.encode(snapshot: snapshot)
        #expect(payload[WatchTransport.snapshotKey] != nil)

        let decoded = try #require(WatchTransport.decodeSnapshot(payload))
        #expect(decoded == snapshot)
        #expect(decoded.doses.first?.id == "intake-1")
        #expect(decoded.doses.last?.isInjection == true)
    }

    @Test("Action round-trips through encode/decode", arguments: [
        WatchAction.markIntake(intakeId: "intake-1", status: .taken, at: Date(timeIntervalSince1970: 1_700_000_000)),
        WatchAction.markIntake(intakeId: "synth:med-2:9", status: .skipped, at: Date(timeIntervalSince1970: 1_700_000_500)),
        WatchAction.markIntake(intakeId: "intake-3", status: .snoozed, at: Date(timeIntervalSince1970: 1_700_001_000)),
        WatchAction.logMood(score: 3, at: Date(timeIntervalSince1970: 1_700_002_000)),
        WatchAction.logMeasurement(kind: .weight, value: 72.4, at: Date(timeIntervalSince1970: 1_700_002_500)),
        WatchAction.logMeasurement(kind: .glucose, value: 105, at: Date(timeIntervalSince1970: 1_700_002_600)),
        WatchAction.logMeasurement(kind: .pulse, value: 64, at: Date(timeIntervalSince1970: 1_700_002_700)),
        WatchAction.logMeasurement(
            kind: .bloodPressure, value: 124, secondary: 81, at: Date(timeIntervalSince1970: 1_700_002_800)
        )
    ])
    func actionRoundTrip(action: WatchAction) throws {
        let payload = WatchTransport.encode(action: action)
        #expect(payload[WatchTransport.actionKey] != nil)
        let decoded = try #require(WatchTransport.decodeAction(payload))
        #expect(decoded == action)
    }

    @Test("Decoding the wrong key returns nil (no cross-talk)")
    func wrongKeyIsNil() {
        let snapshotPayload = WatchTransport.encode(snapshot: .placeholder)
        #expect(WatchTransport.decodeAction(snapshotPayload) == nil)

        let actionPayload = WatchTransport.encode(action: .logMood(score: 5, at: Date()))
        #expect(WatchTransport.decodeSnapshot(actionPayload) == nil)
    }

    @Test("Empty / garbage dictionaries decode to nil, never crash")
    func garbageIsNil() {
        #expect(WatchTransport.decodeSnapshot([:]) == nil)
        #expect(WatchTransport.decodeAction(["unrelated": 42]) == nil)
        #expect(WatchTransport.decodeSnapshot([WatchTransport.snapshotKey: "not-data"]) == nil)
    }

    @Test("Watch status raw values bridge 1:1 to IntakeStatus")
    func statusBridge() {
        #expect(WatchIntakeStatus.taken.intakeStatus == .taken)
        #expect(WatchIntakeStatus.skipped.intakeStatus == .skipped)
        #expect(WatchIntakeStatus.snoozed.intakeStatus == .snoozed)
    }

    // MARK: - Watch quick-capture measurement bridge

    @Test("Measurement kind raw values bridge 1:1 to MetricKind")
    func measurementKindBridge() {
        #expect(WatchMeasurementKind.weight.metricKind == .weight)
        #expect(WatchMeasurementKind.bloodPressure.metricKind == .bloodPressure)
        #expect(WatchMeasurementKind.glucose.metricKind == .glucose)
        #expect(WatchMeasurementKind.pulse.metricKind == .pulse)
    }

    @Test("Scalar kinds build a .scalar value; BP folds systolic+diastolic")
    func measurementValueBridge() {
        #expect(WatchMeasurementKind.weight.measurementValue(value: 72.4, secondary: nil) == .scalar(72.4))
        #expect(WatchMeasurementKind.pulse.measurementValue(value: 64, secondary: nil) == .scalar(64))
        #expect(
            WatchMeasurementKind.bloodPressure.measurementValue(value: 124, secondary: 81)
                == .bloodPressure(systolic: 124, diastolic: 81)
        )
    }

    @Test("logMeasurement action round-trips with its BP pair intact")
    func measurementActionRoundTrip() throws {
        let action = WatchAction.logMeasurement(
            kind: .bloodPressure, value: 130, secondary: 85, at: Date(timeIntervalSince1970: 1_700_005_000)
        )
        let decoded = try #require(WatchTransport.decodeAction(WatchTransport.encode(action: action)))
        #expect(decoded == action)
        if case let .logMeasurement(kind, value, secondary, _) = decoded.kind {
            #expect(kind == .bloodPressure)
            #expect(value == 130)
            #expect(secondary == 85)
        } else {
            Issue.record("expected a logMeasurement action")
        }
    }

    // MARK: - WW/F2 — action id + ack

    @Test("Action carries a stable id that survives the round-trip")
    func actionIdRoundTrip() throws {
        let action = WatchAction(kind: .logMood(score: 5, at: Date(timeIntervalSince1970: 1_700_000_000)))
        let decoded = try #require(WatchTransport.decodeAction(WatchTransport.encode(action: action)))
        #expect(decoded.id == action.id)
        #expect(decoded.kind == action.kind)
        #expect(decoded == action)
    }

    @Test("Two actions get distinct ids")
    func actionIdsDistinct() {
        let a = WatchAction(kind: .logMood(score: 3, at: Date()))
        let b = WatchAction(kind: .logMood(score: 3, at: Date()))
        #expect(a.id != b.id)
    }

    @Test("Ack round-trips, keyed by action id", arguments: [
        WatchAckOutcome.saved, .queued, .failed
    ])
    func ackRoundTrip(outcome: WatchAckOutcome) throws {
        let ack = WatchAck(id: "action-42", outcome: outcome, at: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = WatchTransport.encode(ack: ack)
        #expect(payload[WatchTransport.ackKey] != nil)
        let decoded = try #require(WatchTransport.decodeAck(payload))
        #expect(decoded == ack)
        #expect(decoded.id == "action-42")
        #expect(decoded.outcome == outcome)
    }

    @Test("Ack / action / snapshot keys don't cross-talk")
    func ackNoCrossTalk() {
        let ackPayload = WatchTransport.encode(ack: WatchAck(id: "x", outcome: .saved))
        #expect(WatchTransport.decodeAction(ackPayload) == nil)
        #expect(WatchTransport.decodeSnapshot(ackPayload) == nil)

        let actionPayload = WatchTransport.encode(action: .logMood(score: 2, at: Date()))
        #expect(WatchTransport.decodeAck(actionPayload) == nil)
    }

    // MARK: - WW/F4 — canLog / signedIn back-compat

    @Test("A snapshot's signedIn flag survives via both canLog and signedIn keys")
    func canLogBackCompat() throws {
        // New build encodes BOTH keys; a decoder reading either must agree.
        let snap = WatchSnapshot(
            doses: [], scheduledCount: 0, takenCount: 0,
            recentMoodScore: nil, signedIn: true, generatedAt: Date(timeIntervalSince1970: 1)
        )
        let payload = WatchTransport.encode(snapshot: snap)
        let decoded = try #require(WatchTransport.decodeSnapshot(payload))
        #expect(decoded.signedIn == true)

        // An OLD blob that only has `signedIn` still decodes (forward-tolerant).
        let legacy = #"{"doses":[],"scheduledCount":0,"takenCount":0,"signedIn":true,"generatedAt":"1970-01-01T00:00:01Z"}"#
        let legacyDecoded = try #require(
            WatchTransport.decodeSnapshot([WatchTransport.snapshotKey: Data(legacy.utf8)])
        )
        #expect(legacyDecoded.signedIn == true)
    }

    @Test("A legacy flat action blob (no id) still decodes with a synthesised id")
    func legacyFlatActionDecodes() throws {
        // The pre-WW wire shape was the bare enum: {"logMood":{"score":4,"at":...}}.
        let legacy = #"{"logMood":{"score":4,"at":"1970-01-01T00:00:01Z"}}"#
        let decoded = try #require(
            WatchTransport.decodeAction([WatchTransport.actionKey: Data(legacy.utf8)])
        )
        #expect(decoded.kind == .logMood(score: 4, at: Date(timeIntervalSince1970: 1)))
        #expect(!decoded.id.isEmpty)
    }
}
