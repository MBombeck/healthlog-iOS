import Foundation
@testable import HealthLog
import Testing

/// **CU-32 — Modell + Katalog der Anamnese-Fläche.**
///
/// Zwei Dinge werden hier festgenagelt: die Wertemengen der diskriminierten
/// Union (damit ein Tippfehler nicht erst als 422 auf dem Gerät auffällt) und
/// die Vollständigkeit der Beschriftungen in beiden Sprachen.
@Suite("AnamnesisFact — Modell + Katalog")
struct AnamnesisFactTests {
    // MARK: - Wertemengen

    @Test("each kind carries exactly the server's value set, in server order")
    func valueSetsMatchTheWire() {
        #expect(AnamnesisFactKind.smokingStatus.allowedValues.map(\.rawValue)
            == ["NEVER", "FORMER", "CURRENT"])
        #expect(AnamnesisFactKind.alcoholPattern.allowedValues.map(\.rawValue)
            == ["NONE", "OCCASIONAL", "WEEKLY", "MOST_DAYS"])
        #expect(AnamnesisFactKind.shiftSchedule.allowedValues.map(\.rawValue)
            == ["NONE", "FIXED_SHIFT", "ROTATING"])
        #expect(AnamnesisFactKind.allCases.map(\.rawValue)
            == ["SMOKING_STATUS", "ALCOHOL_PATTERN", "SHIFT_SCHEDULE"])
    }

    /// `NONE` gehört zu zwei Arten, `NEVER` nur zu einer. Die Union ist hart
    /// gekoppelt — `{kind: SMOKING_STATUS, value: ROTATING}` ist ein 422.
    @Test("the union is hard-coupled: NONE is shared, NEVER is not, cross-kind is rejected")
    func unionIsDiscriminated() {
        #expect(AnamnesisFactKind.alcoholPattern.allows(.declaredNone))
        #expect(AnamnesisFactKind.shiftSchedule.allows(.declaredNone))
        #expect(!AnamnesisFactKind.smokingStatus.allows(.declaredNone))

        #expect(AnamnesisFactKind.smokingStatus.allows(.never))
        #expect(!AnamnesisFactKind.alcoholPattern.allows(.never))
        #expect(!AnamnesisFactKind.smokingStatus.allows(.rotating))
        #expect(!AnamnesisFactKind.shiftSchedule.allows(.weekly))
    }

    @Test("an unknown literal round-trips through rawValue without loss")
    func unknownValueRoundTrips() {
        let value = AnamnesisFactValue(rawValue: "VAPING_ONLY")
        #expect(value == .unknown("VAPING_ONLY"))
        #expect(value.rawValue == "VAPING_ONLY")
        #expect(value.isUnknown)
        #expect(!AnamnesisFactValue.never.isUnknown)
    }

    @Test("provenance decodes tolerantly and an unknown one shows no badge")
    func provenanceIsTolerant() {
        #expect(AnamnesisFactProvenance(rawValue: "USER_REPORTED") == .userReported)
        #expect(AnamnesisFactProvenance(rawValue: "USER_CORRECTION") == .userCorrection)
        #expect(AnamnesisFactProvenance(rawValue: "IMPORTED") == .unknown("IMPORTED"))
        #expect(AnamnesisFactProvenance.unknown("IMPORTED").labelKey == nil)
        #expect(AnamnesisFactProvenance.userCorrection.labelKey != nil)
    }

    // MARK: - Abwesenheit ist nicht NONE

    @Test("a missing current key and an explicit NONE are different states")
    func absenceIsNotNone() {
        let noneRevision = AnamnesisFactRevision(
            id: "rev-1",
            kind: .alcoholPattern,
            value: .declaredNone,
            unreadable: false,
            validFrom: Date(timeIntervalSince1970: 0),
            validUntil: nil,
            provenance: .userReported,
            supersededByRevisionId: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let payload = AnamnesisFactsPayload(
            current: [.alcoholPattern: noneRevision], history: [noneRevision]
        )

        #expect(payload.state(for: .alcoholPattern) == .recorded(noneRevision, .declaredNone))
        #expect(payload.state(for: .smokingStatus) == .neverRecorded)
        #expect(payload.state(for: .alcoholPattern) != payload.state(for: .smokingStatus))
        #expect(payload.state(for: .smokingStatus).value == nil)
        #expect(payload.state(for: .alcoholPattern).value == .declaredNone)
        // Nur der erfasste Zustand hat eine Revisions-ID — nur er kann PATCHen.
        #expect(payload.state(for: .alcoholPattern).revision != nil)
        #expect(payload.state(for: .smokingStatus).revision == nil)
    }

    @Test("a null value with unreadable:true is its own state, not an absence")
    func unreadableIsItsOwnState() {
        let revision = AnamnesisFactRevision(
            id: "rev-1",
            kind: .smokingStatus,
            value: nil,
            unreadable: true,
            validFrom: Date(timeIntervalSince1970: 0),
            validUntil: nil,
            provenance: .userReported,
            supersededByRevisionId: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let payload = AnamnesisFactsPayload(current: [.smokingStatus: revision], history: [revision])

        #expect(payload.state(for: .smokingStatus) == .unreadable(revision))
        #expect(payload.state(for: .smokingStatus).isRecorded)
        #expect(payload.state(for: .smokingStatus).value == nil)
        #expect(payload.state(for: .smokingStatus) != .neverRecorded)
    }

    @Test("isCurrent mirrors the server's partial unique index predicate")
    func isCurrentMatchesTheIndex() {
        func revision(validUntil: Date?, superseded: String?) -> AnamnesisFactRevision {
            AnamnesisFactRevision(
                id: "r", kind: .smokingStatus, value: .never, unreadable: false,
                validFrom: Date(timeIntervalSince1970: 0), validUntil: validUntil,
                provenance: .userReported, supersededByRevisionId: superseded,
                createdAt: Date(timeIntervalSince1970: 0)
            )
        }
        #expect(revision(validUntil: nil, superseded: nil).isCurrent)
        #expect(!revision(validUntil: Date(), superseded: nil).isCurrent)
        #expect(!revision(validUntil: nil, superseded: "r2").isCurrent)
    }

    // MARK: - Fehlerabbildung

    @Test("named failures reload, value failures do not")
    func reloadBehaviour() {
        #expect(AnamnesisFactFailure.conflict.requiresReload)
        #expect(AnamnesisFactFailure.staleRevision.requiresReload)
        #expect(AnamnesisFactFailure.currentExists.requiresReload)
        #expect(!AnamnesisFactFailure.invalidValue.requiresReload)
        #expect(!AnamnesisFactFailure.requestInFlight.requiresReload)
    }

    @Test("HLError.server maps onto the named failures by status + errorCode")
    func failureMapping() {
        #expect(AnamnesisFactFailure.from(
            HLError.server(status: 409, code: "anamnesis.fact.conflict", message: "x")
        ) == .conflict)
        #expect(AnamnesisFactFailure.from(
            HLError.server(status: 409, code: "anamnesis.fact.currentExists", message: "x")
        ) == .currentExists)
        #expect(AnamnesisFactFailure.from(
            HLError.server(status: 422, code: "anamnesis.fact.invalidValue", message: "x")
        ) == .invalidValue)
        // Zod-422 ohne errorCode sagt dasselbe.
        #expect(AnamnesisFactFailure.from(
            HLError.server(status: 422, code: nil, message: "Validation failed")
        ) == .invalidValue)
        #expect(AnamnesisFactFailure.from(
            HLError.server(status: 404, code: nil, message: "x")
        ) == .staleRevision)
        // 409 ohne errorCode = Idempotenz-Wrapper.
        #expect(AnamnesisFactFailure.from(
            HLError.server(status: 409, code: nil, message: "already in progress")
        ) == .requestInFlight)
        #expect(AnamnesisFactFailure.from(HLError.offline) == .other(.offline))
    }

    /// Der Store übersetzt ein zweites Mal, was der Repository schon übersetzt
    /// hat. Wäre `from` nicht idempotent, fiele jedes benannte Fehlerbild dabei
    /// auf den generischen Text zurück.
    @Test("from() is idempotent — a translated failure survives a second pass")
    func failureMappingIsIdempotent() {
        for failure in [
            AnamnesisFactFailure.conflict,
            .staleRevision,
            .invalidValue,
            .currentExists,
            .requestInFlight,
            .other(.offline)
        ] {
            #expect(AnamnesisFactFailure.from(failure) == failure)
        }
    }

    // MARK: - Katalog-Vollständigkeit

    @Test("every anamnesis key exists with a non-empty de AND en value")
    func catalogIsComplete() throws {
        let catalog = try ParityCatalog.load()
        var keys = AnamnesisCopy.all
        for kind in AnamnesisFactKind.allCases {
            keys.append(kind.titleKey)
            keys.append(kind.subtitleKey)
            keys.append(contentsOf: kind.allLabelKeys)
        }
        keys.append(AnamnesisFactProvenance.userReported.labelKey ?? "")
        keys.append(AnamnesisFactProvenance.userCorrection.labelKey ?? "")

        var missing: [String] = []
        for key in keys {
            guard let entry = catalog.strings[key] else {
                missing.append("\(key) [absent]")
                continue
            }
            for language in ["de", "en"] where ParityCatalog.value(entry, language: language) == nil {
                missing.append("\(key) [\(language)]")
            }
        }
        #expect(missing.isEmpty, "Fehlende Katalog-Einträge: \(missing)")
    }

    /// `NONE` teilt sich das Wire-Literal zwischen zwei Arten, bedeutet dort
    /// aber Verschiedenes — deshalb hängen die Beschriftungen an der Art. Wären
    /// die beiden Texte identisch, wäre die Trennung sinnlos.
    @Test("the shared NONE literal gets a different label per kind")
    func noneReadsDifferentlyPerKind() throws {
        let catalog = try ParityCatalog.load()
        let alcoholKey = AnamnesisFactKind.alcoholPattern.labelKey(for: .declaredNone)
        let shiftKey = AnamnesisFactKind.shiftSchedule.labelKey(for: .declaredNone)
        #expect(alcoholKey != shiftKey)

        let alcoholEntry = try #require(catalog.strings[alcoholKey])
        let shiftEntry = try #require(catalog.strings[shiftKey])
        for language in ["de", "en"] {
            let alcohol = ParityCatalog.value(alcoholEntry, language: language)
            let shift = ParityCatalog.value(shiftEntry, language: language)
            #expect(alcohol != nil)
            #expect(shift != nil)
            #expect(alcohol != shift, "NONE muss je Art anders lauten (\(language))")
        }
    }

    /// „Nie erfasst" darf nirgends denselben Text tragen wie eine der beiden
    /// `NONE`-Beschriftungen — das ist die Regel, um die es dieser Fläche geht.
    @Test("the 'never recorded' copy is distinct from every NONE label")
    func absenceCopyNeverReadsAsNone() throws {
        let catalog = try ParityCatalog.load()
        let absence = try #require(catalog.strings[AnamnesisCopy.neverRecorded])
        let noneKeys = [
            AnamnesisFactKind.alcoholPattern.labelKey(for: .declaredNone),
            AnamnesisFactKind.shiftSchedule.labelKey(for: .declaredNone)
        ]
        var noneEntries: [ParityCatalog.Entry] = []
        for key in noneKeys {
            try noneEntries.append(#require(catalog.strings[key]))
        }
        for language in ["de", "en"] {
            let absenceValue = ParityCatalog.value(absence, language: language)
            #expect(absenceValue != nil)
            for entry in noneEntries {
                #expect(absenceValue != ParityCatalog.value(entry, language: language))
            }
        }
    }

    /// Die Effektiv-Datierung muss beide Platzhalter mitbringen, sonst
    /// verschluckt `String(format:)` das Enddatum.
    @Test("the effective-dating formats carry their positional placeholders")
    func validityFormatsCarryPlaceholders() throws {
        let catalog = try ParityCatalog.load()
        let sinceEntry = try #require(catalog.strings[AnamnesisCopy.validitySince])
        let rangeEntry = try #require(catalog.strings[AnamnesisCopy.validityRange])
        for language in ["de", "en"] {
            let since = try #require(ParityCatalog.value(sinceEntry, language: language))
            #expect(since.contains("%@"))
            let range = try #require(ParityCatalog.value(rangeEntry, language: language))
            #expect(range.contains("%1$@"))
            #expect(range.contains("%2$@"))
        }
    }
}
