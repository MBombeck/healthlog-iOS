import SwiftUI

// MARK: - Whole-row link

public extension View {
    /// The whole row pushes `destination`: press feedback of every tappable
    /// surface, a button for VoiceOver, and no chevron. For data rows (a
    /// value, an entry, an object); a menu row takes `HLRow(accessory:
    /// .chevron)` and the same modifier.
    ///
    /// In a card (`HLCard(layout: .rows)`) the row is the link itself. In a
    /// `List` pass `inList: true`: there the system draws a chevron on every
    /// `NavigationLink`, so the link stays invisible under the row and the
    /// list cell takes the tap.
    func hlRowLink(
        inList: Bool = false,
        @ViewBuilder destination: @escaping () -> some View
    ) -> some View {
        modifier(HLRowLinkModifier(inList: inList, destination: destination))
    }
}

public extension View {
    /// The same whole-row link, pushing a value. The destination is the
    /// `navigationDestination(for:)` of the screen's root, so the pushed page
    /// does not hang on the row (or on the pane the row stands in) that opened
    /// it: a change of width that removes the row leaves the page where it is.
    func hlRowLink(inList: Bool = false, value: some Hashable) -> some View {
        modifier(HLRowValueLinkModifier(inList: inList, value: value))
    }
}

private struct HLRowValueLinkModifier<Value: Hashable>: ViewModifier {
    let inList: Bool
    let value: Value

    func body(content: Content) -> some View {
        if inList {
            ZStack(alignment: .leading) {
                NavigationLink(value: value) { EmptyView() }
                    .opacity(0)
                content
            }
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
        } else {
            NavigationLink(value: value) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.hlRow)
            .accessibilityAddTraits(.isButton)
        }
    }
}

private struct HLRowLinkModifier<Destination: View>: ViewModifier {
    let inList: Bool
    let destination: () -> Destination

    func body(content: Content) -> some View {
        if inList {
            ZStack(alignment: .leading) {
                NavigationLink(destination: destination) { EmptyView() }
                    .opacity(0)
                content
            }
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
        } else {
            NavigationLink(destination: destination) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.hlRow)
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - History row

/// One entry of a history: when, where from, what (Z22).
///
/// The title is the date with its time (15 pt semibold), the detail line
/// the source, a note or the context (12 pt, one line), on the right the
/// value with at most one status line. All entries of a history stand in
/// one `HLCard(layout: .rows)`; days are grouped by `HLSectionHeader(.group)`,
/// never one card per entry, and empty days do not appear.
public struct HLHistoryRow: View {
    private let date: Text
    private let detail: Text?
    private let value: Text
    private let status: HLRowStatus?

    /// - Parameter date: the moment of the entry, set with date and time in
    ///   the person's date and time format.
    public init(date: Date, detail: Text? = nil, value: Text, status: HLRowStatus? = nil) {
        self.init(date: Text(verbatim: HLDateFormat.dateTime(date)), detail: detail, value: value, status: status)
    }

    /// A date line that is already a text ("Heute, 08:15").
    public init(date: Text, detail: Text? = nil, value: Text, status: HLRowStatus? = nil) {
        self.date = date
        self.detail = detail
        self.value = value
        self.status = status
    }

    public var body: some View {
        HLRow(title: date, detail: detail, value: value, status: status)
    }
}

// MARK: - Drill row

/// The menu row at the end of a detail page's history that opens the full
/// list ("Alle Messungen anzeigen"), the one form on every page.
///
/// Title, a detail line that says what is behind it ("30 Einträge im
/// Zeitraum", or "Einträge außerhalb des Zeitraums" when the chosen period
/// is empty but the list is not) and the chevron. No value on the right: the
/// row leads somewhere, it does not report a figure. The caller attaches the
/// destination with ``SwiftUI/View/hlRowLink(inList:destination:)``.
public struct HLDrillRow: View {
    /// What the detail line says.
    public enum Detail: Equatable, Sendable {
        /// Entries inside the chosen period.
        case inPeriod(Int)
        /// None in the period, but the full list has some.
        case outsidePeriod
        /// Nothing recorded at all.
        case empty
        /// The number is not known yet: no detail line.
        case unknown

        /// The detail for a count in the period. `nil` while it is unknown.
        public static func of(count: Int?, hasEntriesOutsidePeriod: Bool = false) -> Detail {
            guard let count else { return .unknown }
            if count > 0 { return .inPeriod(count) }
            return hasEntriesOutsidePeriod ? .outsidePeriod : .empty
        }

        var text: Text? {
            switch self {
            case let .inPeriod(count): Text("\(count) entries in the period")
            case .outsidePeriod: Text("Entries outside the period")
            case .empty: Text("No entries")
            case .unknown: nil
            }
        }
    }

    private let title: Text
    public let detail: Detail

    /// - Parameters:
    ///   - count: the entries in the chosen period, or `nil` while unknown.
    ///   - hasEntriesOutsidePeriod: the list behind the row has entries
    ///     although none fall in the period.
    public init(_ title: LocalizedStringKey, count: Int?, hasEntriesOutsidePeriod: Bool = false) {
        self.title = Text(title)
        detail = .of(count: count, hasEntriesOutsidePeriod: hasEntriesOutsidePeriod)
    }

    /// A title that is already a text.
    public init(title: Text, count: Int?, hasEntriesOutsidePeriod: Bool = false) {
        self.title = title
        detail = .of(count: count, hasEntriesOutsidePeriod: hasEntriesOutsidePeriod)
    }

    public var body: some View {
        HLRow(title: title, detail: detail.text, accessory: .chevron)
    }
}

#Preview("HLHistoryRow, HLDrillRow") {
    NavigationStack {
        HLPage {
            HLCard(layout: .rows) {
                HLHistoryRow(
                    date: Text(verbatim: "Heute, 08:15"),
                    detail: Text(verbatim: "Apple Health"),
                    value: Text(verbatim: "128/82 mmHg")
                )
                .hlRowLink { Text(verbatim: "Eintrag") }
                HLHistoryRow(
                    date: Text(verbatim: "Gestern, 21:40"),
                    detail: Text(verbatim: "Manuell, nach dem Sport"),
                    value: Text(verbatim: "141/90 mmHg"),
                    status: HLRowStatus("Erhöht", icon: "arrow.up", tone: .warning)
                )
                HLDrillRow(title: Text(verbatim: "Alle Messungen anzeigen"), count: 248)
                    .hlRowLink { Text(verbatim: "Liste") }
            }
        }
    }
}
