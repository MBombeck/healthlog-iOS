import SwiftUI

/// **1.5 BP-TOD (#161, server #1331)** — "Nach Tageszeit" on the blood
/// pressure page: the morning, midday and evening means of the chart's range
/// side by side, each with its reading count and pulse, and the
/// morning-minus-evening difference once the server gives one.
///
/// Every figure is the server's (`GET /api/measurements/blood-pressure/time-of-day`).
/// The server decides which part a reading belongs to, in the record's own
/// time zone, and withholds a mean below its reading floor; the app shows
/// "too few readings" with the count instead of a number. The only client
/// arithmetic is the display unit (mmHg or kPa, like every other number on
/// the page) and the `HH:59` end of an hour window.
///
/// One section, one card, no colours: the numbers are the person's own data
/// side by side, nothing here grades them.
struct BloodPressureTimeOfDaySection: View {
    let kind: MetricKind
    /// The chart's range in days, so the section and the chart read the
    /// same window.
    let days: Int

    @Environment(BackendAvailability.self) private var backend
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.appContainer) private var appContainer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The version the last `/api/version` probe recorded (``KnownServerVersion``),
    /// observed so the section appears as soon as the foreground probe lands,
    /// not only on the next visit to the page.
    @AppStorage(KnownServerVersion.defaultsKey) private var serverVersion: String?
    @State private var model: BloodPressureTimeOfDayModel?
    @State private var attempt = 0

    /// The section's placement gate, pure so the wiring is testable without a
    /// view host: the blood pressure page only, a paired server, and a server
    /// known to have the route. An unknown version answers no (Regel 10).
    nonisolated static func isAvailable(
        for kind: MetricKind,
        hasServer: Bool,
        serverVersion: String?
    ) -> Bool {
        guard kind == .bloodPressure, hasServer, let serverVersion else { return false }
        return ServerVersionInfo(version: serverVersion).isAtLeast(BloodPressureTimeOfDayRepository.minimumServerVersion)
    }

    /// The same gate read from the remembered version, as every other
    /// capability gate reads it.
    nonisolated static func isAvailable(
        for kind: MetricKind,
        hasServer: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        isAvailable(
            for: kind,
            hasServer: hasServer,
            serverVersion: defaults.string(forKey: KnownServerVersion.defaultsKey)
        )
    }

    var body: some View {
        if Self.isAvailable(for: kind, hasServer: backend.canShowCloudInsights, serverVersion: serverVersion) {
            section
                .task(id: LoadKey(days: days, attempt: attempt)) {
                    guard let model = resolvedModel() else { return }
                    await model.load(days: days)
                }
        }
    }

    @ViewBuilder
    private var section: some View {
        let phase = model?.phase ?? .loading
        if phase != .absent {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("insights.bpTimeOfDay.title", flush: true)
                content(phase)
            }
            .accessibilityIdentifier("insights.bpTimeOfDay")
        }
    }

    @ViewBuilder
    private func content(_ phase: BloodPressureTimeOfDayModel.Phase) -> some View {
        switch phase {
        case .loading:
            HLCard {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 88)
            }
            .accessibilityIdentifier("insights.bpTimeOfDay.loading")
        case let .loaded(summary):
            HLCard {
                if summary.isEmpty {
                    Text("insights.bpTimeOfDay.empty")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("insights.bpTimeOfDay.empty")
                } else {
                    loaded(summary)
                }
            }
            .opacity(model?.isRefreshing == true && model?.shownDays != days ? 0.6 : 1)
        case let .disabled(reason):
            FeatureDisabledCard(variant: .inline, reason: reason)
        case .failed:
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("insights.bpTimeOfDay.error")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HLButton("Retry", variant: .secondary) { attempt += 1 }
                        .accessibilityIdentifier("insights.bpTimeOfDay.retry")
                }
            }
            .accessibilityIdentifier("insights.bpTimeOfDay.failed")
        case .absent:
            EmptyView()
        }
    }

    // MARK: - Loaded

    private func loaded(_ summary: BloodPressureTimeOfDay) -> some View {
        let units = settingsStore.unitPreferences
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.md))
            : AnyLayout(HStackLayout(alignment: .top, spacing: HLSpace.md))
        return VStack(alignment: .leading, spacing: HLSpace.md) {
            layout {
                ForEach(summary.parts, id: \.part) { part in
                    column(part, units: units)
                }
            }
            if let difference = summary.morningEveningDifference {
                Text(Self.differenceLine(difference, units: units))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("insights.bpTimeOfDay.difference")
            }
        }
    }

    private func column(_ part: BloodPressureTimeOfDay.PartSummary, units: UnitPreferences) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(Self.name(part.part))
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            Text(Self.hours(part))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .monospacedDigit()
            if let pair = Self.pair(part, units: units) {
                // The pair never breaks ("134/8" over "6"); the unit moves
                // under it when a third of the card is too narrow for both.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.xxs) {
                        pairText(pair)
                        unitText(units)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        pairText(pair)
                        unitText(units)
                    }
                }
            } else {
                Text("insights.bpTimeOfDay.notEnough")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.readings(part.readingCount))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .monospacedDigit()
            if let pulse = part.pulse {
                Text("insights.bpTimeOfDay.pulse \(pulse)")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(Self.name(part.part)), \(Self.hours(part))"))
        .accessibilityValue(Text(verbatim: Self.spokenValue(part, units: units)))
        .accessibilityIdentifier("insights.bpTimeOfDay.part.\(part.part.rawValue)")
    }

    private func pairText(_ pair: String) -> some View {
        Text(verbatim: pair)
            .font(.hlMetric(.title3))
            .foregroundStyle(HLText.primary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func unitText(_ units: UnitPreferences) -> some View {
        Text(verbatim: units.bloodPressure.unitSuffix)
            .font(.hlCaption2)
            .foregroundStyle(HLText.secondary)
    }

    private func resolvedModel() -> BloodPressureTimeOfDayModel? {
        if let model { return model }
        guard let api = appContainer?.api else { return nil }
        let created = BloodPressureTimeOfDayModel(repository: BloodPressureTimeOfDayRepository(api: api))
        model = created
        return created
    }

    private struct LoadKey: Equatable {
        let days: Int
        let attempt: Int
    }
}

// MARK: - Wording (pure, testable)

extension BloodPressureTimeOfDaySection {
    nonisolated static func name(_ part: BloodPressureTimeOfDay.Part) -> String {
        switch part {
        case .morning: String(localized: "insights.bpTimeOfDay.part.morning")
        case .midday: String(localized: "insights.bpTimeOfDay.part.midday")
        case .evening: String(localized: "insights.bpTimeOfDay.part.evening")
        }
    }

    /// "04:00 bis 11:59" from the server's `[startHour, endHour)`.
    nonisolated static func hours(_ part: BloodPressureTimeOfDay.PartSummary) -> String {
        let start = String(format: "%02d:00", part.startHour)
        let end = String(format: "%02d:59", (part.endHour + 23) % 24)
        return String(localized: "insights.bpTimeOfDay.hours \(start) \(end)")
    }

    nonisolated static func readings(_ count: Int) -> String {
        count == 1
            ? String(localized: "insights.bpTimeOfDay.readings.one")
            : String(localized: "insights.bpTimeOfDay.readings \(count)")
    }

    /// The part's mean pair in the chosen unit, or `nil` below the floor.
    nonisolated static func pair(_ part: BloodPressureTimeOfDay.PartSummary, units: UnitPreferences) -> String? {
        guard let systolic = part.systolic, let diastolic = part.diastolic else { return nil }
        return MetricValueFormatter.formatBloodPressure(
            systolic: Double(systolic),
            diastolic: Double(diastolic),
            units: units
        )
    }

    /// "Morgens minus abends: +6/+3 mmHg." from the server's difference.
    nonisolated static func differenceLine(_ difference: BloodPressureTimeOfDay.Difference, units: UnitPreferences) -> String {
        let systolic = signed(difference.systolic, units: units)
        let diastolic = signed(difference.diastolic, units: units)
        let unit = units.bloodPressure.unitSuffix
        return String(localized: "insights.bpTimeOfDay.difference \(systolic) \(diastolic) \(unit)")
    }

    nonisolated static func signed(_ mmHg: Int, units: UnitPreferences) -> String {
        let value = units.convertBloodPressure(Double(mmHg))
        let digits = units.bloodPressure == .mmHg ? 0 : 1
        // The server's sign, spelled out for a rise; a fall keeps the
        // formatter's own minus, zero stays bare.
        let text = HLNumberFormat.decimal(mmHg == 0 ? 0 : value, fractionDigits: digits)
        return mmHg > 0 ? "+\(text)" : text
    }

    nonisolated static func spokenValue(_ part: BloodPressureTimeOfDay.PartSummary, units: UnitPreferences) -> String {
        var pieces: [String] = []
        if let systolic = part.systolic, let diastolic = part.diastolic {
            let digits = units.bloodPressure == .mmHg ? 0 : 1
            let sys = HLNumberFormat.decimal(units.convertBloodPressure(Double(systolic)), fractionDigits: digits)
            let dia = HLNumberFormat.decimal(units.convertBloodPressure(Double(diastolic)), fractionDigits: digits)
            pieces.append(String(localized: "insights.bpTimeOfDay.a11y.mean \(sys) \(dia) \(units.bloodPressure.unitSuffix)"))
        } else {
            pieces.append(String(localized: "insights.bpTimeOfDay.notEnough"))
        }
        pieces.append(readings(part.readingCount))
        if let pulse = part.pulse {
            pieces.append(String(localized: "insights.bpTimeOfDay.pulse \(pulse)"))
        }
        return pieces.joined(separator: ", ")
    }
}
