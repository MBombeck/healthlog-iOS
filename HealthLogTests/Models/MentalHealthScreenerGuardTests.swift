import Foundation
@testable import HealthLog
import Testing

/// Unknown future screeners must never be scored as a known instrument. The
/// decoder accepts the four instruments in the current server registry and the
/// lossy history envelope drops only rows carrying future tokens.
@Suite("MentalHealthInstrument — unknown-instrument guard")
struct MentalHealthInstrumentDecodeGuardTests {
    private func decodeInstrument(_ raw: String) throws -> MentalHealthInstrument {
        let json = Data("\"\(raw)\"".utf8)
        return try JSONDecoder.hlDefault.decode(MentalHealthInstrument.self, from: json)
    }

    @Test("The four modelled instruments decode")
    func knownInstrumentsDecode() throws {
        #expect(try decodeInstrument("PHQ9") == .phq9)
        #expect(try decodeInstrument("GAD7") == .gad7)
        #expect(try decodeInstrument("WHO5") == .who5)
        #expect(try decodeInstrument("SCI") == .sci)
    }

    @Test("An unknown future instrument throws instead of becoming PHQ-9")
    func unknownInstrumentThrows() {
        #expect(throws: (any Error).self) {
            try decodeInstrument("FUTURE_SCREEN")
        }
    }

    /// The list decoder drops the future row and keeps every current instrument.
    @Test("History decode skips only the unknown future row")
    func historySkipsUnknownRowOnly() throws {
        let json = Data("""
        {
          "assessments": [
            {
              "id": "a1", "instrument": "PHQ9", "locale": "de", "version": "standard",
              "totalScore": 12, "severityBand": "moderate", "item9Flagged": false,
              "crisisShownAt": null, "takenAt": "2026-07-01T09:00:00Z",
              "createdAt": "2026-07-01T09:00:00Z"
            },
            {
              "id": "a2", "instrument": "SCI", "locale": "en", "version": "standard",
              "totalScore": 21, "severityBand": "aboveThreshold", "item9Flagged": false,
              "crisisShownAt": null, "takenAt": "2026-07-02T09:00:00Z",
              "createdAt": "2026-07-02T09:00:00Z"
            },
            {
              "id": "future", "instrument": "FUTURE_SCREEN", "locale": "en", "version": "standard",
              "totalScore": 99, "severityBand": "future", "item9Flagged": false,
              "crisisShownAt": null, "takenAt": "2026-07-03T09:00:00Z",
              "createdAt": "2026-07-03T09:00:00Z"
            },
            {
              "id": "a3", "instrument": "GAD7", "locale": "de", "version": "standard",
              "totalScore": 5, "severityBand": "mild", "item9Flagged": false,
              "crisisShownAt": null, "takenAt": "2026-07-04T09:00:00Z",
              "createdAt": "2026-07-04T09:00:00Z"
            }
          ]
        }
        """.utf8)

        let history = try JSONDecoder.hlDefault.decode(MentalHealthHistoryResponse.self, from: json)

        #expect(history.assessments.map(\.id) == ["a1", "a2", "a3"])
        #expect(history.assessments.map(\.instrument) == [.phq9, .sci, .gad7])
        #expect(!history.assessments.contains { $0.id == "future" })
    }

    /// An ABSENT instrument key is a different case from an unknown VALUE: the
    /// wire predates the multi-instrument era, where PHQ-9 was the only screener.
    /// That default stays.
    @Test("An absent instrument key still defaults to PHQ-9")
    func absentInstrumentKeyDefaults() throws {
        let json = Data("""
        {
          "id": "a1", "locale": "de", "version": "standard",
          "totalScore": 4, "severityBand": "minimal", "item9Flagged": false,
          "crisisShownAt": null, "takenAt": "2026-07-01T09:00:00Z",
          "createdAt": "2026-07-01T09:00:00Z"
        }
        """.utf8)
        let dto = try JSONDecoder.hlDefault.decode(MentalHealthAssessmentDTO.self, from: json)
        #expect(dto.instrument == .phq9)
    }
}

/// **Parity 1.6b — the offline crisis card must match the online one.**
///
/// `User.locale` is a bare short code, so the server deliberately serves the
/// COMBINED DE/AT/CH set for "de" (`crisis-resources.ts`): an Austrian or Swiss
/// user is indistinguishable from a German one, and the German freephone numbers
/// do not connect from their country. The bundled offline fallback served
/// Germany-only, so the two surfaces disagreed — offline, in a crisis, on the
/// one card where being wrong is least acceptable.
@Suite("CrisisResourceFallback — locale resolution parity")
struct CrisisResourceFallbackLocaleTests {
    private func ids(_ set: CrisisResourceSet) -> [String] {
        set.resources.map(\.id)
    }

    @Test("A bare 'de' resolves to the combined DE/AT/CH set, as the server does")
    func bareGermanResolvesCombinedSet() {
        let set = CrisisResourceFallback.forLocale("de")
        #expect(ids(set) == [
            "telefonSeelsorge",
            "nummerGegenKummer",
            "krisenchat",
            "telefonSeelsorgeAt",
            "dargeboteneHand",
            "findahelpline"
        ])
        // 112 reaches emergency services in all three countries.
        #expect(set.emergencyNumber == "112")
        // The worldwide directory appears exactly once, at the end.
        #expect(ids(set).filter { $0 == "findahelpline" }.count == 1)
        #expect(ids(set).last == "findahelpline")
    }

    @Test("Every Austrian and Swiss line is reachable from a bare 'de'")
    func combinedSetCarriesAllThreeCountriesContacts() {
        let contacts = CrisisResourceFallback.forLocale("de")
            .resources.flatMap(\.contacts)
        #expect(contacts.contains("0800 111 0 111")) // DE
        #expect(contacts.contains("142")) // AT
        #expect(contacts.contains("143")) // CH
    }

    @Test("A region-qualified German tag resolves to that country's own set")
    func qualifiedGermanTagsResolveToCountrySets() {
        #expect(ids(CrisisResourceFallback.forLocale("de-AT")) == ["telefonSeelsorgeAt", "findahelpline"])
        #expect(ids(CrisisResourceFallback.forLocale("de_ch")) == ["dargeboteneHand", "findahelpline"])
        #expect(ids(CrisisResourceFallback.forLocale("at")) == ["telefonSeelsorgeAt", "findahelpline"])
        #expect(ids(CrisisResourceFallback.forLocale("ch")) == ["dargeboteneHand", "findahelpline"])
    }

    /// Untouched by this change, pinned so the branch reordering did not shift
    /// them.
    @Test("US and international resolution are unchanged")
    func nonGermanLocalesUnchanged() {
        #expect(CrisisResourceFallback.forLocale("en-us").emergencyNumber == "911")
        #expect(ids(CrisisResourceFallback.forLocale("en-us")).contains("lifeline988"))
        // Plain "en" must NOT get the US 988 line.
        #expect(!ids(CrisisResourceFallback.forLocale("en")).contains("lifeline988"))
        #expect(CrisisResourceFallback.forLocale("en").emergencyNumber == "112")
        #expect(CrisisResourceFallback.forLocale(nil).emergencyNumber == "112")
    }

    /// Every resource id the fallback can surface needs a name in the string
    /// catalog — a missing key renders the raw dotted key on the crisis card,
    /// which is what `3cea342f` fixed for the two AT/CH ids. Raising the "de"
    /// branch to the combined set is only safe while this holds.
    @Test("Every resolvable resource id has a catalog name")
    func everyResourceIdIsLocalized() {
        let allIds = Set(
            ["de", "de-at", "de-ch", "en", "en-us", "at", "ch"]
                .flatMap { ids(CrisisResourceFallback.forLocale($0)) }
        )
        for id in allIds {
            let key = "mentalHealth.crisisResource.\(id).name"
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(resolved != key, "Missing catalog entry for \(key)")
        }
    }
}
