// Reads app-target screen symbols that the SPM library does not contain;
// the SPM test build skips the file (repo convention, as in
// `Phase8AccessibilityPolicyTests`).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **08-11 — what the celebration says, and to whom.**
    ///
    /// `Phase8AccessibilityPolicyTests.celebrationSemanticsMatchVisibleMetric`
    /// states the contract as source policy: no fixed English label replacing
    /// the children it hides. This suite states the content — the spoken label
    /// carries the localized metric and the printed figure, the figure follows
    /// the locale, and the two are one function rather than two formatters that
    /// can drift.
    ///
    /// Everything here is a pure `nonisolated static` on `CelebrationOverlay`,
    /// which is the point: the old label was a literal inside a `private var
    /// body`, so nothing but a human could ever check it.
    @Suite("Phase 08 celebration semantics")
    struct Phase8CelebrationSemanticsTests {
        /// The spoken label carries the localized metric name and the printed
        /// figure — the two things on screen — and is no longer the fixed
        /// English phrase that replaced them.
        @Test("the celebration speaks the metric and the value it prints")
        func celebrationSpeaksItsMetricAndValue() {
            let record = Self.dto(metricType: "WEIGHT", value: 78.2, unit: "kg")
            let spoken = CelebrationOverlay.spokenAchievement(for: record)

            #expect(spoken.contains(MetricTypeLocalisation.label(forType: "WEIGHT")))
            #expect(spoken.contains(CelebrationOverlay.valueText(for: record)))
            #expect(spoken != "New personal record!")
            #expect(!spoken.hasSuffix("record!"), "the fixed phrase must not survive as a suffix either")
        }

        /// An id this client build has never seen still produces a spoken label
        /// with a value in it. The celebration is fired from server truth, so an
        /// unknown metric type is an ordinary state and not a silent one.
        @Test("an unknown metric type still gets a spoken label")
        func unknownMetricTypeStillSpeaks() {
            let record = Self.dto(metricType: "SOMETHING_NEW", value: 12, unit: "x")
            let spoken = CelebrationOverlay.spokenAchievement(for: record)
            #expect(!spoken.isEmpty)
            #expect(spoken.contains(CelebrationOverlay.valueText(for: record)))
        }

        /// The figure: a whole number drops its fraction, a fractional one keeps
        /// exactly one digit, and both are formatted through the locale rather
        /// than assembled with a hard-coded separator. Asserted against
        /// `Locale.current.decimalSeparator`, so the claim holds on the German
        /// gate simulator and on an English one — a clause keyed to one
        /// language's punctuation is the defect 08-10 found in a UI case.
        @Test("the printed figure follows the locale and drops an empty fraction")
        func valueTextFollowsTheLocale() {
            let separator = Locale.current.decimalSeparator ?? "."
            let whole = CelebrationOverlay.valueText(for: Self.dto(value: 23412, unit: "Steps"))
            let fractional = CelebrationOverlay.valueText(for: Self.dto(value: 78.2, unit: "kg"))

            #expect(!whole.contains(separator), "a whole number must not print a decimal separator")
            #expect(whole.hasSuffix(" Steps"))
            #expect(fractional.contains(separator), "a fractional value must keep its digit")
            #expect(fractional.hasSuffix(" kg"))
        }

        /// Two boundaries the server can produce and the old label never met,
        /// because it printed no value at all: a unitless record, and a
        /// non-finite one. `inf` in a celebration is worse than no celebration.
        @Test("a unitless or non-finite record still prints something honest")
        func valueTextRefusesInfinityAndToleratesNoUnit() {
            #expect(CelebrationOverlay.valueText(for: Self.dto(value: 7, unit: "")) ==
                HLNumberFormat.decimal(7, fractionDigits: 0))
            #expect(CelebrationOverlay.valueText(for: Self.dto(value: .infinity, unit: "kg")) == "—")
            #expect(CelebrationOverlay.valueText(for: Self.dto(value: .nan, unit: "kg")) == "—")
        }

        /// The printed figure and the spoken one are the SAME call, not two
        /// formatters that agree today. Read from the production source, because
        /// "these two produce the same string for this fixture" is a weaker
        /// statement than "there is only one of them".
        @Test("the printed figure and the spoken one are one function")
        func printedAndSpokenValueShareOneSource() throws {
            let source = try Phase8SourceScan.stripped(Self.overlayPath)
            let announcement = try #require(
                Phase8SourceScan.member(named: "private var announcement: some View", in: source)
            )
            let body = try #require(Phase8SourceScan.member(named: "var body: some View", in: source))

            #expect(announcement.contains("Self.valueText(for: record.base)"))
            #expect(body.contains("Self.spokenAchievement(for: record.base)"))
            #expect(source.contains("valueText(for: dto)"), "the spoken label must compose the printed figure")
        }

        // MARK: - Fixtures

        private static let overlayPath = "HealthLog/Screens/PersonalRecords/CelebrationOverlay.swift"

        private static func dto(
            metricType: String = "ACTIVITY_STEPS",
            value: Double,
            unit: String
        ) -> PersonalRecordDTO {
            PersonalRecordDTO(
                id: "08-11.\(metricType)",
                userId: "u1",
                metricType: metricType,
                metricSlot: nil,
                direction: .max,
                value: value,
                unit: unit,
                achievedAt: Date(timeIntervalSince1970: 1_800_000_000),
                sourceMeasurementId: nil,
                source: "HEALTHLOG_CLIENT",
                externalId: nil,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
    }
#endif
