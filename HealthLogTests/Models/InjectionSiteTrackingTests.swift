import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.11 — injection-site tracking adoption (server v1.8.5).
///
/// Covers: the server↔local enum bridge, default-tolerant medication decode
/// of the new `trackInjectionSites` / `allowedInjectionSites` fields, the
/// effective-allowed-set computation (allowed − globalExcluded, deny-wins),
/// and the write-gating predicate (site sent only when eligible).
@Suite("Injection-site tracking — v1.8.5")
struct InjectionSiteTrackingTests {
    // MARK: - Server enum bridge

    @Test("server enum strings round-trip through serverRawValue")
    func serverEnumRoundTrip() {
        for site in InjectionSite.allCases {
            let server = site.serverRawValue
            #expect(InjectionSite.fromServerRawValue(server) == site)
        }
    }

    @Test("all eight server enum values parse to a distinct local case")
    func parsesAllEightServerValues() {
        let serverValues = [
            "ABDOMEN_LEFT", "ABDOMEN_RIGHT", "ABDOMEN_UPPER_LEFT", "ABDOMEN_UPPER_RIGHT",
            "THIGH_LEFT", "THIGH_RIGHT", "UPPER_ARM_LEFT", "UPPER_ARM_RIGHT"
        ]
        let parsed = serverValues.compactMap(InjectionSite.parse)
        #expect(parsed.count == 8)
        #expect(Set(parsed).count == 8)
    }

    @Test("parse accepts legacy local lowercase AND server uppercase")
    func parseAcceptsBothTaxonomies() {
        // Legacy local raw value.
        #expect(InjectionSite.parse("abdomen_left_upper") == .abdomenLeftUpper)
        // Server enum string maps the abdomen taxonomy correctly:
        // ABDOMEN_UPPER_LEFT ↔ abdomenLeftUpper, ABDOMEN_LEFT ↔ abdomenLeftLower.
        #expect(InjectionSite.parse("ABDOMEN_UPPER_LEFT") == .abdomenLeftUpper)
        #expect(InjectionSite.parse("ABDOMEN_LEFT") == .abdomenLeftLower)
        // Whitespace + nil + unknown.
        #expect(InjectionSite.parse("  THIGH_LEFT ") == .thighLeft)
        #expect(InjectionSite.parse(nil) == nil)
        #expect(InjectionSite.parse("MARS") == nil)
    }

    // MARK: - Default-tolerant medication decode

    @Test("medication decodes new fields; older server omitting them → false/[]")
    func medicationDecodeDefaults() throws {
        // Older server: no injection-site keys at all.
        let legacy = """
        { "id": "m1", "name": "Aspirin", "dose": "100mg" }
        """
        let oldDTO = try JSONDecoder.hlDefault.decode(
            MedicationWireDTO.self,
            from: Data(legacy.utf8)
        )
        let oldDomain = oldDTO.toDomain()
        #expect(oldDomain.trackInjectionSites == false)
        #expect(oldDomain.allowedInjectionSites.isEmpty)
        #expect(oldDomain.injectionSiteCaptureEnabled == false)

        // v1.8.5 server: injection med with tracking on + a 2-site allow-list.
        let modern = """
        {
            "id": "m2", "name": "Ozempic", "dose": "0.5mg",
            "deliveryForm": "INJECTION",
            "trackInjectionSites": true,
            "allowedInjectionSites": ["ABDOMEN_LEFT", "THIGH_RIGHT"]
        }
        """
        let newDTO = try JSONDecoder.hlDefault.decode(
            MedicationWireDTO.self,
            from: Data(modern.utf8)
        )
        let domain = newDTO.toDomain()
        #expect(domain.trackInjectionSites == true)
        #expect(domain.isInjection == true)
        #expect(domain.injectionSiteCaptureEnabled == true)
        #expect(Set(domain.allowedInjectionSites) == [.abdomenLeftLower, .thighRight])
    }

    @Test("tracking on but non-injection route → capture NOT enabled")
    func captureGatedOnInjectionRoute() throws {
        let json = """
        {
            "id": "m3", "name": "Metformin", "dose": "500mg",
            "deliveryForm": "ORAL",
            "trackInjectionSites": true
        }
        """
        let domain = try JSONDecoder.hlDefault
            .decode(MedicationWireDTO.self, from: Data(json.utf8))
            .toDomain()
        #expect(domain.isInjection == false)
        #expect(domain.injectionSiteCaptureEnabled == false)
    }

    @Test("W47 — recognised GLP-1 is injectable + capture-eligible without explicit form/toggle")
    func glp1CaptureEnabledByDefault() throws {
        // Operator's Trulicity: server stamps treatmentClass = "GLP1" but
        // omits the explicit deliveryForm / trackInjectionSites — the GLP-1
        // class already implies the subcutaneous route. The take-sheet must
        // still offer the site picker so logged shots fill the history.
        let json = """
        { "id": "m5", "name": "Trulicity 7.5mg", "dose": "7.5mg",
          "treatmentClass": "GLP1" }
        """
        let domain = try JSONDecoder.hlDefault
            .decode(MedicationWireDTO.self, from: Data(json.utf8))
            .toDomain()
        #expect(domain.isInjection == true)
        #expect(domain.injectionSiteCaptureEnabled == true)

        // Regression guard: an oral non-GLP-1 pill must NOT surface the map,
        // even though it shares the default-omitted form/toggle shape.
        let pill = """
        { "id": "m6", "name": "Aspirin", "dose": "100mg" }
        """
        let pillDomain = try JSONDecoder.hlDefault
            .decode(MedicationWireDTO.self, from: Data(pill.utf8))
            .toDomain()
        #expect(pillDomain.isInjection == false)
        #expect(pillDomain.injectionSiteCaptureEnabled == false)
    }

    @Test("medication domain Codable round-trips the injection fields (SWR cache)")
    func domainCodableRoundTrip() throws {
        let original = Medication(
            id: "m4",
            name: "Wegovy",
            dose: "1mg",
            schedule: MedicationSchedule(times: []),
            deliveryForm: "INJECTION",
            trackInjectionSites: true,
            allowedInjectionSites: [.abdomenLeftLower, .armRight]
        )
        let data = try JSONEncoder.hlDefault.encode(original)
        let decoded = try JSONDecoder.hlDefault.decode(Medication.self, from: data)
        #expect(decoded.trackInjectionSites == true)
        #expect(Set(decoded.allowedInjectionSites) == [.abdomenLeftLower, .armRight])
    }

    // MARK: - Effective-set computation (deny always wins)

    @Test("empty allow-list = all eight, minus the global deny-list")
    func effectiveEmptyAllowMinusDeny() {
        let effective = InjectionSiteEffectiveSet.effective(
            allowed: [],
            globalExcluded: [.thighLeft, .thighRight]
        )
        #expect(effective.count == 6)
        #expect(!effective.contains(.thighLeft))
        #expect(!effective.contains(.thighRight))
        // Order-stable (allCases order).
        #expect(effective == InjectionSite.allCases.filter { $0 != .thighLeft && $0 != .thighRight })
    }

    @Test("deny always wins over a per-med preferred site")
    func denyWinsOverPreferred() {
        // Medication explicitly prefers two sites; the user globally excludes one.
        let effective = InjectionSiteEffectiveSet.effective(
            allowed: [.abdomenLeftLower, .thighRight],
            globalExcluded: [.thighRight]
        )
        #expect(effective == [.abdomenLeftLower])
    }

    @Test("excluding every allowed site yields an empty effective set")
    func effectiveCanBeEmpty() {
        let effective = InjectionSiteEffectiveSet.effective(
            allowed: [.armLeft],
            globalExcluded: [.armLeft]
        )
        #expect(effective.isEmpty)
    }

    // MARK: - Write-gating: site sent only when eligible

    @Test("IntakeUpdate carries site only on a taken write, never a skip")
    func intakeUpdateGatesSiteOnTaken() throws {
        // Encode the wire body the repo builds for a taken vs skipped write.
        let taken = MedicationsRepository.IntakeUpdate(
            intakeId: "e1", status: IntakeStatus.taken.rawValue, takenAt: .now,
            injectionSite: InjectionSite.thighLeft.serverRawValue
        )
        let takenJSON = try encodeToObject(taken)
        #expect(takenJSON["injectionSite"] as? String == "THIGH_LEFT")

        // The repo passes nil for a skip — the wire body then omits/null the key.
        let skipped = MedicationsRepository.IntakeUpdate(
            intakeId: "e1", status: IntakeStatus.skipped.rawValue, takenAt: .now,
            injectionSite: nil
        )
        let skippedJSON = try encodeToObject(skipped)
        #expect(skippedJSON["injectionSite"] == nil || skippedJSON["injectionSite"] is NSNull)
    }

    @Test("BulkIntakeEntry default-tolerant decode keeps older outbox payloads replayable")
    func bulkEntryDecodeTolerant() throws {
        // An outbox payload persisted before v1.8.5 had no injectionSite key.
        let legacy = """
        {
            "medicationId": "m1", "scheduledFor": null,
            "takenAt": "2026-05-31T08:00:00Z", "skipped": false,
            "idempotencyKey": "k1"
        }
        """
        let entry = try JSONDecoder.hlDefault.decode(
            MedicationsRepository.BulkIntakeEntry.self,
            from: Data(legacy.utf8)
        )
        #expect(entry.injectionSite == nil)
        #expect(entry.medicationId == "m1")
    }

    // MARK: - User deny-list DTO

    @Test("injection-site-prefs DTO decodes, and tolerates an omitted key")
    func prefsDTODecode() throws {
        let full = """
        { "globalExcludedInjectionSites": ["THIGH_LEFT", "UPPER_ARM_RIGHT"] }
        """
        let dto = try JSONDecoder.hlDefault.decode(
            InjectionSitePrefsDTO.self, from: Data(full.utf8)
        )
        #expect(dto.globalExcludedInjectionSites == ["THIGH_LEFT", "UPPER_ARM_RIGHT"])

        // Older server: key absent → empty deny-list (fail-open), not an error.
        let empty = "{}"
        let emptyDTO = try JSONDecoder.hlDefault.decode(
            InjectionSitePrefsDTO.self, from: Data(empty.utf8)
        )
        #expect(emptyDTO.globalExcludedInjectionSites.isEmpty)
    }

    // MARK: - Helpers

    private func encodeToObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
}
