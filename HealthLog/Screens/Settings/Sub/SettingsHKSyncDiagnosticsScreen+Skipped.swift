import SwiftUI

// #113 / 0.3 — the refusals a person can see.
//
// Until 1.0.4 a reading the server refused left no trace on the phone: the
// cursor moved past it and the diagnostics counted it as uploaded. The skip
// register keeps it; this card is where it becomes visible — how many, which
// ones (a push to the list), and a way to offer them again right now instead of
// waiting for the next app update.

extension SettingsHKSyncDiagnosticsScreen {
    var skippedCard: some View {
        // 1.4 B2-c — what happens to a refused reading is in the (i).
        HLSettingsCard(
            icon: "exclamationmark.arrow.triangle.2.circlepath",
            title: "settings.hkdiag.skipped_title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                if let snapshot = skippedSnapshot, !snapshot.rows.isEmpty {
                    statRow(label: "settings.hkdiag.skipped_count", value: "\(snapshot.rows.count)")
                    if snapshot.overflow > 0 {
                        statRow(label: "settings.hkdiag.skipped_overflow", value: "\(snapshot.overflow)")
                    }
                    HLSettingsActionRow(title: "settings.hkdiag.skipped_open", presents: .push) {
                        SettingsHKSkippedRowsScreen(rows: snapshot.rows)
                    }
                    .accessibilityIdentifier("settings.hkdiag.skippedList")
                    // INT-A — the re-offer posts measurement rows; a list of
                    // nutrient refusals alone has nothing it could send.
                    if snapshot.rows.contains(where: { $0.entry != nil }) {
                        HLSettingsActionRow(
                            icon: "arrow.clockwise",
                            title: "settings.hkdiag.skipped_resend",
                            presents: .confirm
                        ) {
                            Task { await resendSkipped() }
                        }
                        .disabled(isResending)
                        .accessibilityIdentifier("settings.hkdiag.skippedResend")
                    }
                } else {
                    Text("settings.hkdiag.skipped_none")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let resendSummary {
                    Text(Self.resendResultText(resendSummary))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Register rows per `MetricKind`, for the per-kind warning.
    var registeredSkips: [MetricKind: Int] {
        guard let snapshot = skippedSnapshot else { return [:] }
        var byKind: [MetricKind: Int] = [:]
        for (identifier, count) in snapshot.countsByIdentifier {
            guard let kind = HKSyncDiagnostics.metricKind(for: identifier) else { continue }
            byKind[kind, default: 0] += count
        }
        return byKind
    }

    func loadSkipped() async {
        skippedSnapshot = await HealthKitSkippedRowAccess.snapshot()
    }

    func resendSkipped() async {
        guard !isResending else { return }
        isResending = true
        defer { isResending = false }
        resendSummary = await HealthKitSkippedRowAccess.resend()
        await loadSkipped()
    }

    static func resendResultText(_ summary: HealthKitSkippedRowReoffer.Summary) -> String {
        if summary.transportFailed {
            return String(localized: "settings.hkdiag.skipped_resend_failed")
        }
        return String(localized: "settings.hkdiag.skipped_resend_result \(summary.stored) \(summary.stillRefused)")
    }
}

/// The refused readings, newest first: what, when, which value, why.
struct SettingsHKSkippedRowsScreen: View {
    let rows: [HealthKitSkippedRow]

    var body: some View {
        HLSettingsPage(title: "settings.hkdiag.skipped_list_title") {
            HLSettingsCard(
                icon: "list.bullet.rectangle",
                title: "settings.hkdiag.skipped_list_title",
                footer: "settings.hkdiag.skipped_list_footer"
            ) {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(rows) { row in
                        rowView(row)
                        if row.id != rows.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .navigationTitle("settings.hkdiag.skipped_list_title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rowView(_ row: HealthKitSkippedRow) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.md) {
                Text(Self.kindTitle(row))
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Spacer()
                Text(Self.valueText(row))
                    .font(.hlBody.monospacedDigit())
                    .foregroundStyle(HLText.primary)
            }
            HStack(spacing: HLSpace.md) {
                Text(Self.dateText(row))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Spacer()
                Text(Self.reasonText(row))
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusWarn)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }

    /// The HealthKit identifiers whose value is a 0..1 fraction on the wire;
    /// shown as the percent the Health app shows.
    static let percentFractionIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierOxygenSaturation",
        "HKQuantityTypeIdentifierBodyFatPercentage",
        "HKQuantityTypeIdentifierWalkingAsymmetryPercentage",
        "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",
        "HKQuantityTypeIdentifierAppleWalkingSteadiness"
    ]

    static func kindTitle(_ row: HealthKitSkippedRow) -> String {
        if let nutrient = row.nutrient {
            return NutrientDisplay.name(for: nutrient.nutrient, rawCode: nutrient.nutrient.rawValue)
        }
        if row.mood != nil { return String(localized: "health.permissions.type.stateOfMind") }
        return kindTitle(row.hkIdentifier)
    }

    static func kindTitle(_ identifier: String) -> String {
        if let kind = HKSyncDiagnostics.metricKind(for: identifier) {
            return String(localized: kind.descriptor.title)
        }
        // A type the diagnostics table does not name yet: the HealthKit name
        // without its prefix is still better than hiding the row.
        return identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
    }

    /// A measurement with its time; a nutrient day total with its server day
    /// (noon UTC names that day, shown in UTC so it never shifts).
    static func dateText(_ row: HealthKitSkippedRow) -> String {
        guard row.nutrient != nil else { return row.measuredAt.formatted(date: .abbreviated, time: .shortened) }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return row.measuredAt.formatted(style)
    }

    static func valueText(_ row: HealthKitSkippedRow) -> String {
        if let nutrient = row.nutrient {
            return NutrientDisplay.formatted(amount: nutrient.amount, wireUnit: nutrient.unit)
        }
        // The 1–5 score the importer posts for the sample's valence.
        if let mood = row.mood { return "\(mood.score)/5" }
        guard let entry = row.entry else { return "" }
        return valueText(entry)
    }

    /// The reading as HealthKit holds it — not a server value.
    static func valueText(_ entry: HealthKitBatchEntryDTO) -> String {
        if percentFractionIdentifiers.contains(entry.hkIdentifier), entry.value <= 1 {
            // F1 — the locale's percent sign ("97 %" de, "97%" en), not an
            // ordinary space in every language.
            let number = (entry.value * 100).formatted(.number.precision(.fractionLength(0 ... 1)))
            return HLNumberFormat.percent(formattedNumber: number)
        }
        return entry.value.formatted(.number.precision(.fractionLength(0 ... 2))) + " " + entry.unit
    }

    /// 1.5 FIX-DATA (#126) — an out-of-range refusal says which value the
    /// server checked and which band it broke, when the server said so (v1.39.1);
    /// without that detail the general sentence stays.
    static func reasonText(_ row: HealthKitSkippedRow) -> String {
        guard row.reason == MeasurementBatchAcceptance.Reason.valueOutOfRange, let detail = row.detail else {
            return reasonText(row.reason)
        }
        let unit = detail.range?.unit ?? ""
        switch (detail.convertedValue, detail.range) {
        case let (value?, range?):
            let shown = bandText(value, unit: unit)
            let low = bandText(range.min, unit: unit)
            let high = bandText(range.max, unit: unit)
            return String(localized: "settings.hkdiag.skipped_reason_out_of_range_detail \(shown) \(low) \(high)")
        case let (nil, range?):
            let low = bandText(range.min, unit: unit)
            let high = bandText(range.max, unit: unit)
            return String(localized: "settings.hkdiag.skipped_reason_out_of_range_band \(low) \(high)")
        case let (value?, nil):
            return String(localized: "settings.hkdiag.skipped_reason_out_of_range_value \(bandText(value, unit: unit))")
        case (nil, nil):
            return reasonText(row.reason)
        }
    }

    /// A value in the server's stored unit, as the server named it.
    static func bandText(_ value: Double, unit: String) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0 ... 2)))
        if unit == "%" { return HLNumberFormat.percent(formattedNumber: number) }
        return unit.isEmpty ? number : number + " " + unit
    }

    static func reasonText(_ reason: String) -> String {
        switch reason {
        case MeasurementBatchAcceptance.Reason.valueOutOfRange:
            String(localized: "settings.hkdiag.skipped_reason_out_of_range")
        case MeasurementBatchAcceptance.Reason.unstableExternalId:
            String(localized: "settings.hkdiag.skipped_reason_unstable_id")
        case OutboxReplayService.notConfirmedReason:
            String(localized: "settings.hkdiag.skipped_reason_not_confirmed")
        case _ where reason.hasPrefix("unclassified_4xx:"):
            String(localized: "settings.hkdiag.skipped_reason_unclassified")
        case _ where reason.hasSuffix(":" + MeasurementBatchInvalid.code):
            String(localized: "settings.hkdiag.skipped_reason_invalid")
        case MoodStateOfMindUnreadable.reason:
            String(localized: "settings.hkdiag.skipped_reason_unreadable")
        default:
            String(localized: "settings.hkdiag.skipped_reason_other \(reason)")
        }
    }
}
