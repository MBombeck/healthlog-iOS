import Foundation
@testable import HealthLog
import Testing

/// **iOS 1.4 B4-c — medications, mood, cycle, illness and notifications, polished.**
///
/// Pins the polish decisions that are logic rather than layout: which pill and
/// which card still render, how a day key and a month key read, which letters
/// the calendars carry, and that the screenshot fixtures answer every route the
/// walk reaches through the real DTOs, with nothing taken before it was due.
@MainActor
@Suite("B4-c — medications, mood, cycle, illness, notifications")
struct AreaMedsPolishTests {
    private static let german = Locale(identifier: "de_DE")
    private static let english = Locale(identifier: "en_US")

    // MARK: - Medications

    @Test("The category pill only for a category that tells something")
    func categoryPill() {
        #expect(MedicationCard.categoryPillLabel(category: nil, label: nil) == nil)
        #expect(MedicationCard.categoryPillLabel(category: "", label: nil) == nil)
        #expect(MedicationCard.categoryPillLabel(category: "OTHER", label: nil) == nil)
        #expect(
            MedicationCard.categoryPillLabel(category: "SUPPLEMENT", label: nil)
                == String(localized: "medications.categorySupplement")
        )
        #expect(MedicationCard.categoryPillLabel(category: "custom:abc", label: "Augentropfen") == "Augentropfen")
    }

    @Test("The adherence tile opens the history only behind a number")
    func adherenceDisclosure() {
        #expect(ComplianceKPISection.discloses(.server(.init(rate: 80, taken: 24, expected: 30))))
        #expect(!ComplianceKPISection.discloses(.pending))
        #expect(!ComplianceKPISection.discloses(.unavailable))
        #expect(!ComplianceKPISection.discloses(.notTracked))
        #expect(!ComplianceKPISection.discloses(.notApplicable))
    }

    // MARK: - Mood

    @Test("The trend card needs two different days")
    func trendNeedsTwoDays() {
        let calendar = Calendar(identifier: .gregorian)
        let morning = Date(timeIntervalSince1970: 1_790_000_000)
        let sameDay = [
            MoodTrendChart.Entry(date: morning, score: 3),
            MoodTrendChart.Entry(date: morning.addingTimeInterval(3600), score: 4)
        ]
        #expect(!MoodTrendPresence.isShown([], calendar: calendar))
        #expect(!MoodTrendPresence.isShown(sameDay, calendar: calendar))
        #expect(MoodTrendPresence.isShown(
            sameDay + [MoodTrendChart.Entry(date: morning.addingTimeInterval(86400), score: 2)],
            calendar: calendar
        ))
    }

    @Test("The year grid names every other weekday, starting with Monday")
    func yearGridLabels() {
        #expect((0 ..< 7).filter(MoodHeatmapSection.showsYearLabel(row:)) == [0, 2, 4, 6])
    }

    // MARK: - Cycle

    @Test("Cycle history bars carry the start in words, with the year only when two would read alike")
    func cycleHistoryLabels() {
        #expect(CycleHistoryChartModel.axisLabels(for: ["2026-05-13", "2026-06-10"], locale: Self.german)
            == ["13. Mai", "10. Juni"])
        #expect(CycleHistoryChartModel.axisLabels(for: ["2026-05-13"], locale: Self.english) == ["May 13"])
        let twice = CycleHistoryChartModel.axisLabels(for: ["2025-05-13", "2026-05-13"], locale: Self.german)
        #expect(Set(twice).count == 2)
        #expect(twice[0].contains("25") && twice[1].contains("26"))
        #expect(CycleHistoryChartModel.axisLabels(for: ["not-a-day"], locale: Self.german) == ["not-a-day"])
    }

    @Test("The cycle calendar's weekday letters follow the language")
    func cycleWeekdays() {
        #expect(CycleCalendarGrid.weekdaySymbols(locale: Self.german) == ["M", "D", "M", "D", "F", "S", "S"])
        #expect(CycleCalendarGrid.weekdaySymbols(locale: Self.english) == ["M", "T", "W", "T", "F", "S", "S"])
    }

    @Test("The most notable pattern stands alone only when the phase rows do not list it")
    func cycleHeadline() throws {
        let row = """
        {"metricKey":"restingHeartRate","display":"bpm","lutealDays":61,"follicularDays":58,
         "lutealAvg":62.4,"follicularAvg":59.9,"delta":2.5,"pValue":0.01,"qValue":0.03,"confidence":"high"}
        """
        let listed = try JSONDecoder.hlDefault.decode(
            CycleInsightsDTO.self,
            from: Data(#"{"rows":[\#(row)],"headline":\#(row),"symptomPatterns":[]}"#.utf8)
        )
        #expect(CycleInsightsSection.standaloneHeadline(listed) == nil)
        let alone = try JSONDecoder.hlDefault.decode(
            CycleInsightsDTO.self,
            from: Data(#"{"rows":[],"headline":\#(row),"symptomPatterns":[]}"#.utf8)
        )
        #expect(CycleInsightsSection.standaloneHeadline(alone)?.metricKey == "restingHeartRate")
    }

    // MARK: - Illness

    @Test("The by-month tally reads a month in words")
    func illnessMonths() {
        #expect(IllnessInsightsScreen.monthLabel("2026-10", locale: Self.german) == "Oktober 2026")
        #expect(IllnessInsightsScreen.monthLabel("2026-01", locale: Self.english) == "January 2026")
        #expect(IllnessInsightsScreen.monthLabel("unknown", locale: Self.german) == "unknown")
    }

    // MARK: - Screenshot fixtures

    @Test("The medication history holds nothing taken before it was due, and the list agrees with it")
    func fixtureHistoryIsInThePast() throws {
        let now = Date.now
        for id in [AreaMedsDetailFixtures.lisinoprilID, AreaMedsDetailFixtures.naproxenID, AreaMedsDetailFixtures.trulicityID] {
            let slots = AreaMedsDetailFixtures.slots(medicationID: id, now: now)
            #expect(!slots.isEmpty, "\(id) has a history")
            #expect(slots.allSatisfy { $0.scheduledFor <= now && ($0.takenAt ?? now) <= now })
        }
        let body = try #require(AreaMedsFixtures.response(forPath: "/api/medications", method: "GET")?.body)
        let medications = try JSONDecoder.hlDefault.decode([MedicationWireDTO].self, from: body).map { $0.toDomain() }
        #expect(medications.count == 4)
        for medication in medications {
            #expect((medication.lastTakenAt ?? now) <= now, "\(medication.name) was not taken in the future")
        }
    }

    @Test("Every medication route the walk reaches decodes through the real DTO")
    func fixtureMedicationRoutes() throws {
        let decoder = JSONDecoder.hlDefault
        func body(_ path: String, _ query: [URLQueryItem] = []) throws -> Data {
            try #require(AreaMedsFixtures.response(forPath: path, method: "GET", query: query)?.body, "\(path)")
        }
        let lisinopril = "/api/medications/\(AreaMedsDetailFixtures.lisinoprilID)"
        let page = try decoder.decode(PaginatedIntakeEnvelope.self, from: body(
            "\(lisinopril)/intake",
            [URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "offset", value: "0")]
        ))
        #expect(page.events.count == min(30, page.meta.total ?? 0))
        let compliance = try decoder.decode(MedicationCompliancePayload.self, from: body("\(lisinopril)/compliance"))
        #expect(compliance.isApplicable)
        #expect(compliance.complianceDisplay?.shortDays == 7)
        // The figure and the "N von M" under it come from one count, as on the
        // server: skipped doses leave the denominator.
        let window = compliance.compliance30
        let expected = window.taken + window.missed
        #expect(window.rate == Int((Double(window.taken) / Double(max(expected, 1)) * 100).rounded()))
        let record = try decoder.decode(
            MedicationCompliancePayload.self,
            from: body("/api/medications/\(AreaMedsFixtures.recordOnlyMedicationID)/compliance")
        )
        #expect(record.notApplicableReason == .intakeNotTracked)
        let report = try decoder.decode(MedicationComplianceListWire.self, from: body("/api/medications/compliance")).report
        #expect(report.entries.count == 4)
        let glp1 = try decoder.decode(
            Glp1DetailsDTO.self,
            from: body("/api/medications/\(AreaMedsDetailFixtures.trulicityID)/glp1")
        )
        #expect(glp1.doseChanges.isEmpty)
        let efficacy = try decoder.decode(MedicationEfficacyDTO.self, from: body("\(lisinopril)/efficacy"))
        #expect(efficacy.eligible)
        #expect(efficacy.targets.first?.beforeAfter.isRenderable == true)
        let today = try decoder.decode([MedicationIntake].self, from: body("/api/medications/intake"))
        #expect(today.allSatisfy { ($0.takenAt ?? .now) <= .now })
    }

    @Test("The notification settings decode: one push channel, no relay set up")
    func fixtureNotifications() throws {
        let decoder = JSONDecoder.hlDefault
        func body(_ path: String) throws -> Data {
            try #require(AreaMedsFixtures.response(forPath: path, method: "GET")?.body, "\(path)")
        }
        let preferences = try decoder.decode(NotificationPreferencesPayload.self, from: body("/api/notifications/preferences"))
        #expect(preferences.channels.map(\.type) == ["APNS"])
        #expect(preferences.preferences.count == preferences.eventTypes.count)
        let status = try decoder.decode(NotificationStatusPayload.self, from: body("/api/notifications/status"))
        #expect(status.channels.first?.state == .active)
        #expect(try !decoder.decode(NtfyConfig.self, from: body("/api/settings/ntfy")).enabled)
        #expect(try !decoder.decode(TelegramConfig.self, from: body("/api/settings/telegram")).enabled)
        #expect(try decoder.decode(WebhookConfig.self, from: body("/api/settings/webhook")).format == .generic)
        #expect(try decoder.decode(GlobalServicesFlags.self, from: body("/api/settings/global-services")) == .allEnabled)
    }
}
