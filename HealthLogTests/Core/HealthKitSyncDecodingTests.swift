import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks `GET /api/integrations/healthkit` shape against server v1.4.26
/// `src/app/api/integrations/healthkit/route.ts` + `DEFAULT_HEALTHKIT_ENTRIES`.
///
/// **Pre-v0.4.0 drift (A4-Audit rows 6 + 7):**
/// - `direction` rejected `"disabled"` (whole config decode failed for
///   anyone who toggled an entry off).
/// - `kind` was typed as the domain `MetricKind` enum, throwing
///   `dataCorrupted` on `"bodyMass"`, `"heartRate"`, `"stepCount"`,
///   `"sleepAnalysis"` (every default entry → broken integration screen
///   since v0.3.0).
@Suite("HealthKitSync wire shape (server v1.4.26)")
struct HealthKitSyncDecodingTests {
    @Test("Default-entries fixture decodes — bodyMass / heartRate / stepCount / sleepAnalysis")
    func defaultEntriesDecode() throws {
        // Shape mirrors src/app/api/integrations/healthkit/route.ts:45-67 +
        // the route response wrapping `{ entries: [...], lastSyncedAt }`.
        let json = Data(#"""
        {
            "entries": [
                {"id": "weight", "kind": "bodyMass", "direction": "bidirectional", "enabled": true},
                {"id": "bloodPressure", "kind": "bloodPressure", "direction": "bidirectional", "enabled": true},
                {"id": "bloodGlucose", "kind": "bloodGlucose", "direction": "bidirectional", "enabled": true},
                {"id": "heartRate", "kind": "heartRate", "direction": "readOnly", "enabled": true},
                {"id": "stepCount", "kind": "stepCount", "direction": "readOnly", "enabled": true},
                {"id": "sleep", "kind": "sleepAnalysis", "direction": "readOnly", "enabled": true}
            ],
            "lastSyncedAt": "2026-05-15T10:00:00.000Z"
        }
        """#.utf8)
        let config = try JSONDecoder.hlDefault.decode(HealthKitSyncConfig.self, from: json)
        #expect(config.entries.count == 6)
        #expect(config.entries[0].kind == "bodyMass")
        #expect(config.entries[3].kind == "heartRate")
        #expect(config.entries[5].kind == "sleepAnalysis")
    }

    @Test("Direction 'disabled' decodes (A4-Audit row 6)")
    func disabledDirectionDecodes() throws {
        let json = Data(#"""
        {
            "id": "stepCount",
            "kind": "stepCount",
            "direction": "disabled",
            "enabled": false
        }
        """#.utf8)
        let entry = try JSONDecoder.hlDefault.decode(HealthKitSyncEntry.self, from: json)
        #expect(entry.direction == .disabled)
    }

    @Test("All four direction values round-trip")
    func allDirections() throws {
        for raw in ["readOnly", "writeOnly", "bidirectional", "disabled"] {
            let json = Data("\"\(raw)\"".utf8)
            let direction = try JSONDecoder.hlDefault.decode(SyncDirection.self, from: json)
            let encoded = try JSONEncoder().encode(direction)
            #expect(String(data: encoded, encoding: .utf8) == "\"\(raw)\"")
        }
    }

    @Test("kindDisplayName translation covers known HK identifiers")
    func displayNames() {
        let cases: [(String, String)] = [
            ("bodyMass", "Weight"),
            ("bloodPressure", "Blood pressure"),
            ("bloodGlucose", "Blood glucose"),
            ("heartRate", "Pulse"),
            ("stepCount", "Steps"),
            ("sleepAnalysis", "Sleep")
        ]
        for (kind, label) in cases {
            let entry = HealthKitSyncEntry(id: kind, kind: kind, direction: .readOnly, enabled: true)
            #expect(entry.kindDisplayName == label)
        }
    }

    @Test("Unknown HK kind falls back to raw string (forward-compat)")
    func unknownKindFallback() {
        let entry = HealthKitSyncEntry(id: "x", kind: "futureKind_v999", direction: .readOnly, enabled: true)
        #expect(entry.kindDisplayName == "futureKind_v999")
    }
}
