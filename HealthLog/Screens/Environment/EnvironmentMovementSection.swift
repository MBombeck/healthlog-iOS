import SwiftUI

/// **1.5 MOVE (#133)** — "Unterwegs" on the environment screen: one day of
/// movement from Dawarich, as `GET /api/day/{date}` reports it in its
/// `movement` block (server v1.43).
///
/// A plain day switcher (back, forward, never into the future) over the
/// rows the server filled: distance in total, by car and by train in the
/// server's unit, places visited, time away from home and a travel day with
/// its country. A `null` is never shown as zero; its row is left out. No new
/// navigation: the section lives in the screen's own list.
struct EnvironmentMovementSection: View {
    let store: MovementStore

    var body: some View {
        switch store.phase {
        case .hidden:
            EmptyView()
        case .loading:
            Section(header: header) {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("environment.movement.loading")
            }
        case .notConnected:
            Section(header: header) {
                note("environment.movement.notConnected")
                    .accessibilityIdentifier("environment.movement.notConnected")
            }
        case .noData:
            Section(header: header) {
                note("environment.movement.noData")
                    .accessibilityIdentifier("environment.movement.noData")
            }
        case .failed:
            Section(header: header) {
                failedRow
            }
        case .ready:
            Section(header: header) {
                switcher
                dayContent
            }
        }
    }

    private var header: some View {
        Text("environment.movement.section")
    }

    // MARK: - Switcher

    /// ‹ day › with 44 pt arrows, like the sleep night header; an arrow that
    /// would leave the stored range or reach past today is dimmed and off.
    private var switcher: some View {
        HStack(spacing: HLSpace.sm) {
            arrow("chevron.left", label: "environment.movement.previousDay", enabled: store.canGoBack, id: "previous") {
                Task { await store.step(by: -1) }
            }
            Text(verbatim: store.selectedDay.map(Self.dayTitle) ?? "")
                .font(.hlBody.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("environment.movement.day")
            arrow("chevron.right", label: "environment.movement.nextDay", enabled: store.canGoForward, id: "next") {
                Task { await store.step(by: 1) }
            }
        }
    }

    private func arrow(
        _ systemName: String,
        label: LocalizedStringResource,
        enabled: Bool,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.hlBody.weight(.semibold))
                .foregroundStyle(enabled ? HLText.primary : HLText.tertiary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("environment.movement.\(id)")
    }

    // MARK: - Day

    @ViewBuilder
    private var dayContent: some View {
        switch store.dayPhase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        case .failed:
            failedRow
        case let .loaded(movement):
            if let movement, movement.hasValues {
                ForEach(Self.rows(movement)) { row in
                    HLSettingsStatRow(label: Text(row.label), value: row.value)
                        .accessibilityIdentifier("environment.movement.row.\(row.id)")
                }
            } else {
                note("environment.movement.dayEmpty")
                    .accessibilityIdentifier("environment.movement.dayEmpty")
            }
        }
    }

    private var failedRow: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("environment.movement.error")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HLButton("Retry", variant: .secondary) {
                Task { await store.retry() }
            }
            .accessibilityIdentifier("environment.movement.retry")
        }
        .padding(.vertical, HLSpace.xxs)
        .accessibilityIdentifier("environment.movement.failed")
    }

    private func note(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.hlSubhead)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, HLSpace.xxs)
    }
}

// MARK: - Wording (pure, testable)

extension EnvironmentMovementSection {
    /// One shown row: what it is, and the server's value as text.
    struct Row: Identifiable, Equatable {
        let id: String
        let label: LocalizedStringResource
        let value: String
    }

    /// The rows of one day, in a fixed order; every `nil` is left out.
    nonisolated static func rows(_ movement: DayMovement, locale: Locale = AppLanguage.current.formattingLocale) -> [Row] {
        var rows: [Row] = []
        if let distance = movement.distance {
            let legs: [Row?] = [
                distance.total.map { Row(
                    id: "total",
                    label: "environment.movement.distance.total",
                    value: Self.distance($0, unit: distance.unit, locale: locale)
                ) },
                distance.driving.map { Row(
                    id: "driving",
                    label: "environment.movement.distance.driving",
                    value: Self.distance($0, unit: distance.unit, locale: locale)
                ) },
                distance.train.map { Row(
                    id: "train",
                    label: "environment.movement.distance.train",
                    value: Self.distance($0, unit: distance.unit, locale: locale)
                ) }
            ]
            rows += legs.compactMap(\.self)
        }
        if let places = movement.placesVisited {
            rows.append(Row(id: "places", label: "environment.movement.places", value: places.formatted(.number.locale(locale))))
        }
        if let minutes = movement.awayFromHomeMinutes {
            rows.append(Row(id: "away", label: "environment.movement.away", value: Self.duration(minutes: minutes, locale: locale)))
        }
        if let travel = movement.travel, travel.isTravelDay {
            rows.append(Row(id: "travel", label: "environment.movement.travelDay", value: Self.country(travel.countryCode, locale: locale)))
        }
        return rows
    }

    /// The server's figure to one decimal, as it was rounded, with its unit.
    nonisolated static func distance(_ value: Double, unit: String, locale: Locale) -> String {
        HLNumberFormat.decimal(value, fractionDigits: 1, locale: locale) + "\u{00A0}" + unit
    }

    /// Minutes as hours and minutes in the interface language ("3 Std., 20 Min.").
    nonisolated static func duration(minutes: Int, locale: Locale) -> String {
        Duration.seconds(max(minutes, 0) * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))
    }

    /// The country's name in the interface language, the code itself when
    /// the name is unknown, and "yes" when the server names no country.
    nonisolated static func country(_ code: String?, locale: Locale) -> String {
        guard let code, !code.isEmpty else {
            return String(localized: "environment.movement.travelDay.yes")
        }
        return locale.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    /// The switcher's title: weekday and date of the server's day key.
    nonisolated static func dayTitle(_ key: String) -> String {
        dayTitle(key, locale: AppLanguage.current.formattingLocale)
    }

    nonisolated static func dayTitle(_ key: String, locale: Locale) -> String {
        guard let date = MovementDay.date(key) else { return key }
        var style = Date.FormatStyle(date: .complete, time: .omitted).locale(locale)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return date.formatted(style)
    }
}
