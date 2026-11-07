import CoreGraphics
import Foundation
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UIKit)

    /// Per-page CoreGraphics + UIKit drawing for the local doctor report.
    /// Lives outside the renderer-actor because UIKit drawing primitives
    /// (`NSAttributedString.draw`, `UIFont`) are thread-safe for the
    /// `UIGraphicsPDFRenderer` callback, which the actor calls into
    /// synchronously per page.
    ///
    /// **Boundary:** never mutates app state, never reads from a store, never
    /// touches the network. Inputs are `DoctorReportSpec.*` value types only.
    struct SectionDrawer {
        let spec: DoctorReportSpec
        /// Pre-rendered chart bitmaps (Commit 3) keyed by metric kind.
        /// Empty when the spec has no charts block.
        let chartImages: [ChartImage]

        init(spec: DoctorReportSpec, chartImages: [ChartImage] = []) {
            self.spec = spec
            self.chartImages = chartImages
        }

        // MARK: - Top-level dispatch

        func draw(element: PageElement, into context: CGContext, pageBounds: CGRect) {
            switch element {
            case let .cover(cover, footer):
                drawCover(cover, footer: footer, pageBounds: pageBounds)
            case let .vitals(vitals, footer):
                drawVitals(vitals, footer: footer, pageBounds: pageBounds)
            case let .charts(charts, footer):
                drawCharts(charts, footer: footer, pageBounds: pageBounds)
            case let .medications(meds, footer):
                drawMedications(meds, footer: footer, pageBounds: pageBounds)
            case let .adherence(adherence, footer):
                drawAdherence(adherence, footer: footer, pageBounds: pageBounds)
            case let .mood(mood, footer):
                drawMood(mood, footer: footer, pageBounds: pageBounds)
            }
            // Footer is the same on every page.
            drawFooter(spec.footer, pageBounds: pageBounds)
            _ = context // CGContext currently unused — kept so future low-
            // level drawing (per-cell rectangles) can hop in without
            // re-threading.
        }

        // MARK: - Cover page

        private func drawCover(_ cover: DoctorReportSpec.Cover, footer _: DoctorReportSpec.Footer, pageBounds: CGRect) {
            let titleFont = UIFont.systemFont(ofSize: 32, weight: .bold)
            let bodyFont = UIFont.systemFont(ofSize: 14, weight: .regular)
            let captionFont = UIFont.systemFont(ofSize: 11, weight: .regular)

            let title = LocaleText.coverTitle(for: cover.locale)
            let patientLabel = "\(LocaleText.coverPatientLabel(for: cover.locale)): \(cover.patientName)"
            let period = DateRangeFormatter.format(start: cover.periodStart, end: cover.periodEnd, locale: cover.locale)
            let periodLabel = "\(LocaleText.coverPeriodLabel(for: cover.locale)): \(period)"
            let generated = DateRangeFormatter.formatSingle(date: cover.generatedAt, locale: cover.locale)
            let generatedLabel = "\(LocaleText.coverGeneratedLabel(for: cover.locale)): \(generated)"
            let versionLabel = "\(LocaleText.coverVersionLabel(for: cover.locale)): \(cover.appVersion)"

            var y = pageBounds.midY - 140
            draw(text: title, at: CGPoint(x: PDFPage.margin, y: y), font: titleFont, color: .label)
            y += 56
            draw(text: patientLabel, at: CGPoint(x: PDFPage.margin, y: y), font: bodyFont, color: .label)
            y += 22
            // v0.10.0 — extended patient-identity lines. Each is drawn only
            // when the spec carries a non-empty value (the builder already
            // trims + nils empties), so a user who left the field blank sees
            // no orphan label. The KVNR is plaintext (operator's own data,
            // matches the web cover) and is never logged.
            if let fullName = cover.fullName, !fullName.isEmpty {
                let label = "\(LocaleText.coverFullNameLabel(for: cover.locale)): \(fullName)"
                draw(text: label, at: CGPoint(x: PDFPage.margin, y: y), font: bodyFont, color: .label)
                y += 22
            }
            if let insurer = cover.insurerName, !insurer.isEmpty {
                let label = "\(LocaleText.coverInsurerLabel(for: cover.locale)): \(insurer)"
                draw(text: label, at: CGPoint(x: PDFPage.margin, y: y), font: bodyFont, color: .label)
                y += 22
            }
            if let kvnr = cover.insuranceNumber, !kvnr.isEmpty {
                let label = "\(LocaleText.coverInsuranceNumberLabel(for: cover.locale)): \(kvnr)"
                draw(text: label, at: CGPoint(x: PDFPage.margin, y: y), font: bodyFont, color: .label)
                y += 22
            }
            draw(text: periodLabel, at: CGPoint(x: PDFPage.margin, y: y), font: bodyFont, color: .label)
            y += 22
            draw(text: generatedLabel, at: CGPoint(x: PDFPage.margin, y: y), font: bodyFont, color: .label)
            y += 22
            draw(text: versionLabel, at: CGPoint(x: PDFPage.margin, y: y), font: captionFont, color: .secondaryLabel)
        }

        // MARK: - Vitals summary

        private func drawVitals(
            _ vitals: DoctorReportSpec.VitalsSummary,
            footer _: DoctorReportSpec.Footer,
            pageBounds: CGRect
        ) {
            drawSectionHeader(LocaleText.vitalsTitle(for: spec.cover.locale), at: pageBounds)
            let headerHeight: CGFloat = 80

            // Column layout: kind | n | mean | median | min | max.
            let columns: [(title: String, width: CGFloat)] = [
                // L10N-REPORT — the name column takes the rest of the 540 pt
                // content width: Dutch and German metric names run long.
                (LocaleText.colKind(for: spec.cover.locale), 190),
                (LocaleText.colCount(for: spec.cover.locale), 50),
                (LocaleText.colMean(for: spec.cover.locale), 80),
                (LocaleText.colMedian(for: spec.cover.locale), 80),
                (LocaleText.colMin(for: spec.cover.locale), 70),
                (LocaleText.colMax(for: spec.cover.locale), 70)
            ]

            let tableFont = UIFont.systemFont(ofSize: 11, weight: .regular)
            let headerFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
            var y = headerHeight

            drawTableRow(
                columns.map(\.title),
                widths: columns.map(\.width),
                y: y,
                font: headerFont,
                color: .secondaryLabel
            )
            y += 20

            // #115 B5 / P2 — glucose, weight, temperature and waist print in
            // the account's unit.
            let units = spec.printUnits
            // L10N-REPORT — decimals in the report language ("72,4" in DE/NL).
            let numbers = spec.cover.locale.formattingLocale
            for row in vitals.rows {
                let primaryMean = ValueFormatter.format(row.mean, kind: row.kind, units: units, locale: numbers)
                let secondaryMean = ValueFormatter.format(
                    row.secondaryMean ?? 0,
                    kind: row.kind,
                    units: UnitPreferences(glucose: .mgdL),
                    locale: numbers
                )
                // "121/81 mmHg": the unit once, after the pair (it used to print
                // "121 mmHg/81 mmHg" and run into the median column).
                let displayMean = row.kind == .bloodPressure
                    ? "\(Self.droppingUnit(primaryMean, of: row.kind))/\(secondaryMean)"
                    : primaryMean
                drawTableRow(
                    [
                        DoctorReportStrings.metricName(row.kind, spec.cover.locale),
                        String(row.count),
                        displayMean,
                        ValueFormatter.format(row.median, kind: row.kind, units: units, locale: numbers),
                        ValueFormatter.format(row.min, kind: row.kind, units: units, locale: numbers),
                        ValueFormatter.format(row.max, kind: row.kind, units: units, locale: numbers)
                    ],
                    widths: columns.map(\.width),
                    y: y,
                    font: tableFont,
                    color: .label
                )
                y += 18
            }
        }

        // MARK: - Charts (Commit 3 — small-multiples ImageRenderer output).

        private func drawCharts(
            _ charts: DoctorReportSpec.ChartsBlock,
            footer _: DoctorReportSpec.Footer,
            pageBounds: CGRect
        ) {
            drawSectionHeader(LocaleText.chartsTitle(for: spec.cover.locale), at: pageBounds)
            var y: CGFloat = 80
            let tileWidth = PDFPage.contentWidth
            let tileHeight: CGFloat = 110
            let imageByKind: [MetricKind: UIImage] = chartImages.reduce(into: [:]) { acc, item in
                if let image = item.image {
                    acc[item.kind] = image
                }
            }
            for series in charts.series {
                let rect = CGRect(x: PDFPage.margin, y: y, width: tileWidth, height: tileHeight)
                if let image = imageByKind[series.kind] {
                    image.draw(in: rect)
                } else {
                    // Fallback: when ImageRenderer returned nil (rare —
                    // happens in unit-test contexts that pre-empt the
                    // main run-loop). Lays down a text caption so the
                    // doctor still sees the series exists.
                    let labelFont = UIFont.systemFont(ofSize: 11, weight: .regular)
                    let caption = LocaleText.dataPoints(
                        DoctorReportStrings.metricName(series.kind, spec.cover.locale),
                        count: series.points.count,
                        locale: spec.cover.locale
                    )
                    draw(
                        text: caption,
                        at: CGPoint(x: PDFPage.margin, y: y),
                        font: labelFont,
                        color: .label
                    )
                }
                y += tileHeight + 12
                if y + tileHeight > pageBounds.height - 60 {
                    // Crude single-page truncation; a follow-up could
                    // overflow into a second charts page. The cover-letter
                    // small-multiples grid (6 metrics @ 110 pt) fits cleanly
                    // on a single A4/Letter page so this branch is rare in
                    // practice.
                    break
                }
            }
        }

        // MARK: - Medications

        private func drawMedications(
            _ meds: DoctorReportSpec.MedicationsBlock,
            footer _: DoctorReportSpec.Footer,
            pageBounds: CGRect
        ) {
            drawSectionHeader(LocaleText.medicationsTitle(for: spec.cover.locale), at: pageBounds)
            var y: CGFloat = 80
            let nameFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
            let metaFont = UIFont.systemFont(ofSize: 11, weight: .regular)
            for med in meds.active {
                draw(text: med.name, at: CGPoint(x: PDFPage.margin, y: y), font: nameFont, color: .label)
                y += 16
                let metaLine = "\(med.dose), \(med.schedule)" +
                    (med.treatmentClass.map { " (\($0))" } ?? "")
                draw(text: metaLine, at: CGPoint(x: PDFPage.margin, y: y), font: metaFont, color: .secondaryLabel)
                y += 22
            }
            if !meds.archived.isEmpty {
                y += 14
                draw(
                    text: LocaleText.medicationsArchived(for: spec.cover.locale),
                    at: CGPoint(x: PDFPage.margin, y: y),
                    font: nameFont,
                    color: .secondaryLabel
                )
                y += 18
                for med in meds.archived {
                    draw(text: "\(med.name), \(med.dose)", at: CGPoint(x: PDFPage.margin, y: y), font: metaFont, color: .secondaryLabel)
                    y += 16
                }
            }
            _ = pageBounds
        }

        // MARK: - Adherence

        private func drawAdherence(
            _ adherence: DoctorReportSpec.AdherenceBlock,
            footer _: DoctorReportSpec.Footer,
            pageBounds: CGRect
        ) {
            drawSectionHeader(LocaleText.adherenceTitle(for: spec.cover.locale), at: pageBounds)
            var y: CGFloat = 80
            let labelFont = UIFont.systemFont(ofSize: 12, weight: .regular)
            let noteFont = UIFont.systemFont(ofSize: 11, weight: .regular)
            let locale = spec.cover.locale
            // #115 · 1.2 — every line below is the server's; the notes say
            // which window the figures cover, or why there are none.
            // L10N-REPORT — notes and rows wrap inside the content width; the
            // Dutch source note ran off the right edge of the page.
            for note in LocaleText.adherenceNotes(for: adherence, locale: locale) {
                y += drawWrapped(text: note, y: y, font: noteFont, color: .secondaryLabel) + 4
            }
            if !adherence.perMedication.isEmpty { y += 8 }
            for row in adherence.perMedication {
                let line = LocaleText.adherenceRow(row, windowDays: adherence.windowDays, locale: locale)
                y += drawWrapped(text: line, y: y, font: labelFont, color: .label) + 4
            }
        }

        // MARK: - Mood

        private func drawMood(
            _ mood: DoctorReportSpec.MoodBlock,
            footer _: DoctorReportSpec.Footer,
            pageBounds: CGRect
        ) {
            drawSectionHeader(LocaleText.moodTitle(for: spec.cover.locale), at: pageBounds)
            var y: CGFloat = 80
            let labelFont = UIFont.systemFont(ofSize: 12, weight: .regular)
            // The report locale's decimal separator ("3,5" in DE/NL), not the device's.
            let summary = LocaleText.moodSummary(count: mood.count, average: mood.averageScore, locale: spec.cover.locale)
            draw(text: summary, at: CGPoint(x: PDFPage.margin, y: y), font: labelFont, color: .label)
            y += 22
            if !mood.dominantTags.isEmpty {
                let tagsLine = LocaleText.moodTagsLabel(for: spec.cover.locale) + ": " +
                    mood.dominantTags.map {
                        "\(DoctorReportStrings.moodTagName($0.tag, spec.cover.locale)) (\($0.count))"
                    }.joined(separator: ", ")
                _ = drawWrapped(text: tagsLine, y: y, font: labelFont, color: .secondaryLabel)
            }
        }

        // MARK: - Footer

        private func drawFooter(_ footer: DoctorReportSpec.Footer, pageBounds: CGRect) {
            let font = UIFont.systemFont(ofSize: 9, weight: .regular)
            let y = pageBounds.height - 24
            draw(text: footer.disclaimer, at: CGPoint(x: PDFPage.margin, y: y), font: font, color: .secondaryLabel)
        }

        // MARK: - Drawing primitives

        private func draw(text: String, at point: CGPoint, font: UIFont, color: UIColor) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            (text as NSString).draw(at: point, withAttributes: attrs)
        }

        /// Draws `text` at the left margin, wrapped to the content width, and
        /// returns the height it took.
        private func drawWrapped(text: String, y: CGFloat, font: UIFont, color: UIColor) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let bounds = CGSize(width: PDFPage.contentWidth, height: .greatestFiniteMagnitude)
            let height = ceil((text as NSString).boundingRect(
                with: bounds,
                options: [.usesLineFragmentOrigin],
                attributes: attrs,
                context: nil
            ).height)
            let rect = CGRect(x: PDFPage.margin, y: y, width: PDFPage.contentWidth, height: height)
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
            return max(height, 14)
        }

        private func drawSectionHeader(_ title: String, at _: CGRect) {
            let font = UIFont.systemFont(ofSize: 20, weight: .bold)
            draw(text: title, at: CGPoint(x: PDFPage.margin, y: PDFPage.margin), font: font, color: .label)
        }

        private func drawTableRow(
            _ cells: [String],
            widths: [CGFloat],
            y: CGFloat,
            font: UIFont,
            color: UIColor
        ) {
            var x = PDFPage.margin
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            for (index, cell) in cells.enumerated() where index < widths.count {
                // A cell never runs into its neighbour: what does not fit
                // ends in an ellipsis inside its own column.
                let rect = CGRect(x: x, y: y, width: widths[index] - 6, height: font.lineHeight + 2)
                (cell as NSString).draw(
                    with: rect,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: attrs,
                    context: nil
                )
                x += widths[index]
            }
        }

        /// `value` without the trailing unit of `kind` ("121 mmHg" to "121").
        static func droppingUnit(_ value: String, of kind: MetricKind) -> String {
            let suffix = " \(kind.unit)"
            guard !kind.unit.isEmpty, value.hasSuffix(suffix) else { return value }
            return String(value.dropLast(suffix.count))
        }
    }

#endif

// MARK: - Formatters

enum ValueFormatter {
    /// `value` is canonical; glucose is converted into `glucoseUnit` and
    /// labelled with it (#115 B5 — it was always mg/dL). Every other kind prints
    /// in its canonical unit, as before.
    static func format(_ value: Double, kind: MetricKind, glucoseUnit: GlucoseUnit = .mgdL) -> String {
        format(value, kind: kind, units: UnitPreferences(glucose: glucoseUnit))
    }

    /// #115 P2 — `value` is canonical; converted families print in `units`.
    /// L10N-REPORT — `locale` is the report language's; the default keeps the
    /// device's, as before, for callers outside the report.
    static func format(_ value: Double, kind: MetricKind, units: UnitPreferences, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = DoctorReportGlucoseDisplay.fractionDigits(for: kind, units: units)
            ?? digits(for: kind)
        formatter.minimumFractionDigits = 0
        let shown = DoctorReportGlucoseDisplay.value(value, kind: kind, units: units)
        let raw = formatter.string(from: NSNumber(value: shown)) ?? String(shown)
        let unit = DoctorReportGlucoseDisplay.unit(for: kind, units: units)
        return unit.isEmpty ? raw : "\(raw) \(unit)"
    }

    private static func digits(for kind: MetricKind) -> Int {
        switch kind {
        case .steps: 0
        case .pulse, .bloodPressure, .glucose, .restingHeartRate, .hrv,
             .respiratoryRate, .audioExposureEnvironment, .audioExposureHeadphone: 0
        // v0.8.3 W-D — kcal / flights / meters / minutes all render as whole numbers.
        case .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight: 0
        case .weight, .bodyFat, .bodyTemperature, .spo2, .bodyWater, .boneMass, .sleep,
             .vo2Max, .walkingAsymmetry, .walkingDoubleSupport, .walkingSteadiness, .bmi: 1
        case .walkingSpeed, .walkingStepLength: 2
        // v0.11 W21 — web-parity additions: cardio/age/rating render whole;
        // body-composition masses + temps + PWV one decimal.
        case .vascularAge, .visceralFat, .walkingHeartRate: 0
        case .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature, .pulseWaveVelocity, .fatMass: 1
        // v0.13.1 IC — v1.10.0 additive signals. Counts + recovery bpm + 6MWT
        // metres render whole; stair speeds two decimals; wrist temp one.
        case .falls, .breathingDisturbances, .cardioRecovery, .sixMinuteWalk: 0
        case .stairAscentSpeed, .stairDescentSpeed: 2
        case .wristTemperature: 1
        // v0.14.6 — v1.12.8 WHOOP-native: bpm + counts render whole.
        case .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount: 0
        // v0.14.1 W-B189 — v1.17.1 source-fixed signals (#23). Cardio-load /
        // sleep-score render whole; ANS-charge + the signed body-temperature
        // deviation render one decimal.
        case .cardioLoad, .sleepScore: 0
        case .ansCharge, .bodyTemperatureDeviation: 1
        // v0158 — v1.25 clinical types. Pain NRS is a whole 0–10 score; grip /
        // waist render one decimal; waist-to-height ratio two decimals.
        case .painNRS: 0
        case .gripStrength, .waistCircumference: 1
        case .waistToHeight, .stateOfMindValence: 2
        // Build 3 / item 3.3 — the 21 decoder catch-up types. Screener sums,
        // wearable scores, sleep percentages, sleep-need minutes, kJ and the
        // categorical events are all whole numbers; only HRV-RMSSD and the two
        // 0–21 WHOOP strain readings carry a meaningful decimal.
        case .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore,
             .sleepPerformance, .sleepEfficiency, .sleepConsistency,
             .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent, .bodyBattery, .stressLevel, .trainingReadiness, .acuteTrainingLoad,
             .exerciseMinutes, .standMinutes, .standHours, .mindfulMinutes,
             // Build 7 / item 7.3 — mood is a whole-number daily score.
             .mood,
             // Audit B-4 — the audio-exposure event is a whole occurrence count.
             .audioExposureEvent: 0
        // Audit B-4 — `.unknown` has no known precision; one decimal matches its
        // descriptor's `.decimal1` and is the least-claiming default. The arm
        // is unreachable from the report itself: `DoctorReportSpecBuilder`
        // skips the sentinel explicitly in BOTH aggregators (`makeVitalsSummary`
        // and `makeCharts`), so no unknown row reaches this formatter. It stays
        // because the formatter is a general helper, not because the report
        // happens not to build such a row.
        case .hrvRMSSD, .dayStrain, .workoutStrain, .afibBurden, .unknown: 1
        }
    }
}

enum DateRangeFormatter {
    static func format(start: Date, end: Date, locale: ReportLocale) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale.foundationIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return LocaleText.periodRange(formatter.string(from: start), formatter.string(from: end), locale: locale)
    }

    static func formatSingle(date: Date, locale: ReportLocale) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale.foundationIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
