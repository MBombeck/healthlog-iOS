import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **Audit B-4 (2026-09-10) — the remaining server enums that still decode hard.**
///
/// W3 made the two measurement wire enums and `IntakeStatus` tolerant. These are
/// the ones it left: five closed `String` enums whose `init(from:)` throws on a
/// value the server added after this build, plus two coercions that answered an
/// unrecognised token with a NAMED case — a claim, not a degradation.
///
/// Every case here states the same contract in a different vocabulary: a list
/// carrying ONE row this build cannot name and ONE it can must decode to TWO
/// rows. The unknown one keeps its identity and its numbers, states nothing
/// beyond that, and never goes back on the wire.
@Suite("Audit B-4 — the remaining server enums degrade instead of dropping")
struct UnknownServerEnumToleranceTests {
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - 1. ServerMoodLevel — the whole mood entry used to drop

    @Test("A mood list with one unnameable level and one known level decodes to two entries")
    func moodListKeepsUnknownLevelRow() throws {
        // `MoodEntry.init(from:)` decodes `mood` with a plain `try c.decode`, and
        // the history arrives as ONE array: a level the server adds after this
        // build threw mid-row and took the whole PAGE with it.
        let json = """
        [
          {"id":"m-unknown","mood":"FANTASTISCH","moodLoggedAt":"2026-09-01T08:00:00Z","tags":[]},
          {"id":"m-known","mood":"GUT","moodLoggedAt":"2026-09-01T20:00:00Z","tags":[]}
        ]
        """
        let entries = try Self.decoder().decode([MoodEntry].self, from: Data(json.utf8))

        #expect(entries.count == 2, "The unnameable level must cost its own label, never the page.")
        let unknown = try #require(entries.first { $0.id == "m-unknown" })
        #expect(unknown.mood == .unknown)
        #expect(entries.first { $0.id == "m-known" }?.mood == .good)
    }

    @Test("An unnameable mood level claims no score and never leaves the device")
    func unknownMoodLevelClaimsNothing() throws {
        // `.unknown` is a BUCKET: two entries on it may carry two different
        // server levels, so any number derived across it is a number about
        // nothing. There is no honest 1…5 for it, and the type says so.
        #expect(ServerMoodLevel.unknown.score == nil)
        #expect(ServerMoodLevel.good.score == 4)
        #expect(!ServerMoodLevel.serverCases.contains(.unknown))
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(ServerMoodLevel.unknown)
        }
        // The picker only ever offers named levels, so a write can never carry
        // the sentinel in the first place.
        #expect(ServerMoodLevel.serverCases.count == 5)
    }

    @Test("An unnameable mood level is excluded from an average, never averaged as a middle")
    func unknownMoodLevelIsExcludedFromAverages() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            MoodEntry(id: "a", mood: .great, tags: [], moodLoggedAt: base),
            MoodEntry(id: "b", mood: .unknown, tags: [], moodLoggedAt: base.addingTimeInterval(60)),
            MoodEntry(id: "c", mood: .great, tags: [], moodLoggedAt: base.addingTimeInterval(120))
        ]

        // Three rows on screen, two scores in the mean — 5, not 5 diluted by a
        // fabricated middle and not 5 diluted by a zero.
        #expect(entries.count == 3)
        #expect(MoodEntry.averageScore(of: entries) == 5)
        #expect(MoodEntry.scored(entries).count == 2)
        #expect(MoodEntry.averageScore(of: [entries[1]]) == nil)
    }

    // MARK: - 2. NutrientCode — the nutrient row used to drop

    @Test("A nutrient overview with one unnameable code and one known code decodes to two rows")
    func nutrientOverviewKeepsUnknownCodeRow() throws {
        // The list wrapper is lossy by construction, so the unknown code cost
        // exactly the row it named — silently, with no gap where it had been.
        let json = """
        {"windowDays":14,"nutrients":[
          {"nutrient":"omega_3","unit":"mg","latestDay":"2026-09-01","latestAmount":900,"daysWithData":7},
          {"nutrient":"iron","unit":"mg","latestDay":"2026-09-01","latestAmount":12,"daysWithData":9}
        ]}
        """
        let overview = try Self.decoder().decode(NutrientOverviewDTO.self, from: Data(json.utf8))

        #expect(overview.nutrients.count == 2, "The unnameable code must cost its label, not its row.")
        let unknown = try #require(overview.nutrients.first { $0.nutrient == .unknown })
        // The DATA is intact — degrading the LABEL must not degrade the numbers.
        #expect(unknown.latestAmount == 900)
        #expect(unknown.unit == "mg")
        // …and the raw server code is kept, so the row can name itself.
        #expect(unknown.rawNutrient == "omega_3")
        #expect(NutrientDisplay.name(for: .unknown, rawCode: "omega_3") == "omega_3")
        // Two unnameable codes are two rows, not one collapsed onto a shared id.
        #expect(overview.nutrients.map(\.id).count == Set(overview.nutrients.map(\.id)).count)
    }

    @Test("An unnameable nutrient code is never offered and never sent")
    func unknownNutrientCodeClaimsNothing() {
        #expect(!NutrientCode.serverCases.contains(.unknown))
        #expect(NutrientCode.serverCases.count == NutrientCode.allCases.count - 1)
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(NutrientCode.unknown)
        }
    }

    // MARK: - 3. InjectionSite — the allow-list used to lose its restriction

    @Test("A medication whose allow-list names one unnameable site keeps both sites")
    func medicationKeepsUnknownAllowedInjectionSite() throws {
        let json = """
        {"id":"med-1","name":"Ozempic","dose":"0.5 mg","trackInjectionSites":true,
         "allowedInjectionSites":["ABDOMEN_LEFT","EAR_LOBE"]}
        """
        let wire = try Self.decoder().decode(MedicationWireDTO.self, from: Data(json.utf8))
        let med = wire.toDomain()

        #expect(med.allowedInjectionSites.count == 2, "A site this build cannot name is still a restriction.")
        #expect(med.allowedInjectionSites.contains(.unknown))
        #expect(med.allowedInjectionSites.contains(.abdomenLeftLower))
    }

    @Test("An allow-list of only unnameable sites offers no site, not all eight")
    func unknownOnlyAllowListOffersNothing() {
        // The real cost of dropping the row: an allow-list that compact-mapped
        // to EMPTY meant "no restriction", so the picker offered all eight sites
        // the server had just restricted away.
        let effective = InjectionSiteEffectiveSet.effective(allowed: [.unknown], globalExcluded: [])
        #expect(effective.isEmpty, "An empty picker is honest; all eight is a fabricated permission.")
        #expect(!InjectionSiteEffectiveSet.effective(allowed: [], globalExcluded: []).isEmpty)
        // Still filtered out when it rides alongside a named site.
        let mixed = InjectionSiteEffectiveSet.effective(allowed: [.unknown, .thighLeft], globalExcluded: [])
        #expect(mixed == [.thighLeft])
    }

    @Test("The unnameable site is never written back into an allow-list PATCH")
    func unknownSiteNeverReachesTheAllowListPatch() {
        // The edit sheet rebuilds `allowedInjectionSites` from the local set on
        // every save, so a sentinel with a wire spelling would invent a server
        // enum member. It has none.
        #expect(InjectionSite.unknown.serverRawValue == nil)
        #expect(InjectionSite.thighLeft.serverRawValue == "THIGH_LEFT")
        #expect(!InjectionSite.serverCases.contains(.unknown))
        let written = Set<InjectionSite>([.unknown, .armLeft]).compactMap(\.serverRawValue).sorted()
        #expect(written == ["UPPER_ARM_LEFT"])
    }

    // MARK: - 4a. MedicationContainerType — the whole supply LIST used to fail

    @Test("A supply list with one unnameable container and one known one decodes to two items")
    func inventoryListKeepsUnknownContainerRow() throws {
        // `MedicationInventoryListDTO.items` has no lossy wrapper: an unknown
        // `containerType` threw inside `decodeIfPresent`, failed the whole
        // response as `HLError.decoding`, and the supply screen showed an error
        // where the person's containers should have been.
        let json = """
        {"items":[
          {"id":"i-1","userId":"u","medicationId":"m","state":"ACTIVE","unitsTotal":30,
           "unitsRemaining":30,"containerType":"CARTRIDGE"},
          {"id":"i-2","userId":"u","medicationId":"m","state":"IN_USE","unitsTotal":10,
           "unitsRemaining":4,"containerType":"PEN"}
        ],"meta":{"total":2}}
        """
        let list = try Self.decoder().decode(MedicationInventoryListDTO.self, from: Data(json.utf8))

        #expect(list.items.count == 2, "One unnameable container must not cost the whole shelf.")
        #expect(list.items.first { $0.id == "i-1" }?.containerType == .unknown)
        #expect(list.items.first { $0.id == "i-2" }?.containerType == .pen)
    }

    @Test("An unnameable container claims no expiry rule, no picker row and no write")
    func unknownContainerClaimsNothing() {
        // The first-use expiry clock runs for PEN and AMPOULE only. A container
        // this build cannot name is not known to be one of them, and the
        // conservative answer is the printed date alone.
        #expect(!MedicationContainerType.unknown.usesFirstUseExpiryClock)
        #expect(!MedicationContainerType.serverCases.contains(.unknown))
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(MedicationContainerType.unknown)
        }
    }

    // MARK: - 4b. ScheduleType — the cadence tag that claimed SCHEDULED

    @Test("An unnameable schedule type decodes to the sentinel, not to SCHEDULED")
    func unknownScheduleTypeIsNotClaimedAsScheduled() throws {
        let decoded = try JSONDecoder().decode(ScheduleType.self, from: Data("\"FLEX_WINDOW\"".utf8))
        #expect(decoded == .unknown, "Answering `SCHEDULED` was a claim about a cadence nobody had read.")
        #expect(try JSONDecoder().decode(ScheduleType.self, from: Data("\"PRN\"".utf8)) == .prn)
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(ScheduleType.unknown)
        }
    }

    @Test("A schedule row tagged with an unnameable type still dispatches on the fields it carries")
    func unknownScheduleTypeFallsBackToFieldPresence() {
        // The sentinel changes what the app CLAIMS, not what it does: dispatch
        // falls through to the same field-presence ladder `.scheduled` uses, so
        // a readable rrule still projects and still reminds.
        let dto = MedicationScheduleDTO(
            windowStart: "08:00",
            timesOfDay: ["08:00"],
            rrule: "FREQ=DAILY",
            scheduleType: .unknown
        )
        let entry = ScheduleEntry.fromDTO(dto, oneShot: false)
        #expect(entry.cadence == .daily)
    }

    // MARK: - 4c. SideEffectKind — an unmapped entry used to read as NAUSEA

    @Test("A side-effect entry this build cannot map is never read back as nausea")
    func unmappedSideEffectEntryIsNotNausea() {
        // The worst claim of the set: `?? .nausea` turned every server
        // side-effect taxonomy entry this build had not mapped into a specific
        // reported SYMPTOM, in a medication logbook.
        #expect(SideEffectKind.from(serverEntry: "PALPITATIONS") == .unknown)
        #expect(SideEffectKind.from(serverEntry: "NAUSEA") == .nausea)
        #expect(SideEffectKind.unknown.serverEntry == nil)
        #expect(SideEffectKind.nausea.serverEntry == "NAUSEA")
        #expect(!SideEffectKind.pickerCases.contains(.unknown))
    }
}

// swiftlint:enable force_unwrapping
