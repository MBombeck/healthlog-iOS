import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The dashboard keeps its own head, but on the tab header's measures: the
/// same title line and the same place for what stands at its trailing edge,
/// at the standard size and in accessibility sizes.
@MainActor
@Suite("The dashboard's head stands like a tab header")
struct DashboardHeaderContractTests {
    private static let greeting = "Hallo Alex"
    private static let date = "Donnerstag, 12. Nov."

    private func dashboardLine() -> some View {
        DashboardHeaderLine(title: Self.greeting) {
            DashboardGreeting(salutation: Self.greeting, date: Self.date)
        } trailing: {
            HLIconButton(systemImage: "person.crop.circle", label: "Profile", style: .bar) {}
        }
    }

    private func tabHeader() -> some View {
        HLTabHeader(
            LocalizedStringResource(String.LocalizationValue(Self.greeting)),
            subtitle: LocalizedStringKey(Self.date)
        ) {
            HLIconButton(systemImage: "person.crop.circle", label: "Profile", style: .bar) {}
        }
        // The inline form of the header, the one that has a trailing place.
        .environment(\.hlTabHeaderActionPlacement, .inline)
    }

    /// The form the app ships: the dashboard's line without a trailing
    /// element (its avatar stands in the bar) against a tab header whose
    /// actions stand in the bar.
    private func shippedDashboardLine() -> some View {
        DashboardHeaderLine(title: Self.greeting) {
            DashboardGreeting(salutation: Self.greeting, date: Self.date)
        } trailing: {
            EmptyView()
        }
    }

    private func shippedTabHeader() -> some View {
        HLTabHeader(
            LocalizedStringResource(String.LocalizationValue(Self.greeting)),
            subtitle: LocalizedStringKey(Self.date)
        ) {
            HLIconButton(systemImage: "gearshape", label: "Settings", style: .bar) {}
        }
        .environment(\.hlTabHeaderActionPlacement, .bar)
    }

    @Test("as shipped, the dashboard's head is as high as a tab header with its actions in the bar", arguments: [
        DynamicTypeSize.large, .accessibility3
    ])
    func shippedSameLine(typeSize: DynamicTypeSize) throws {
        let dashboard = try DesignContractMeasure.size(of: shippedDashboardLine(), width: 390, typeSize: typeSize)
        let header = try DesignContractMeasure.size(of: shippedTabHeader(), width: 390, typeSize: typeSize)
        #expect(dashboard == header)
    }

    @Test("title line and trailing place match the tab header", arguments: [DynamicTypeSize.large, .accessibility3])
    func sameLine(typeSize: DynamicTypeSize) throws {
        let dashboard = try DesignContractMeasure.size(of: dashboardLine(), width: 390, typeSize: typeSize)
        let header = try DesignContractMeasure.size(of: tabHeader(), width: 390, typeSize: typeSize)
        #expect(dashboard == header)
    }

    @Test("without a line under it the greeting is one tab header line high")
    func titleLineHeight() throws {
        let line = DashboardHeaderLine(title: "Hallo") {
            Text(verbatim: "Hallo").font(.hlLargeTitle)
        } trailing: {
            HLIconButton(systemImage: "person.crop.circle", label: "Profile", style: .bar) {}
        }
        let size = try DesignContractMeasure.size(of: line, width: 390)
        #expect(size.height == HLTabHeaderMetrics.titleLineHeight)
    }

    @Test("the date under the greeting reads as before, in de, en and nl", arguments: ["de_DE", "en_US", "nl_NL"])
    func dateLine(identifier: String) throws {
        let locale = Locale(identifier: identifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9)))
        let before = date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.wide).day().month()
        )
        #expect(HLDateFormat.weekdayDayMonth(date, locale: locale, calendar: calendar) == before)
        let expected = ["de_DE": "Donnerstag", "en_US": "Thursday", "nl_NL": "donderdag"][identifier]
        #expect(try before.contains(#require(expected)))
    }
}
