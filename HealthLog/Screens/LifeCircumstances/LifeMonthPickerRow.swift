import SwiftUI

/// **LIFE (1.5.0), Server #1334** — "When you stopped", picked as a month.
///
/// The contract stores the quit date as `quitMonth: "YYYY-MM"`, so the app
/// asks for exactly that: a month and a year, nothing finer, nothing typed.
/// On the web the field was a text box that threw away every keystroke short
/// of a whole `YYYY-MM` (Server #1334); here there is nothing to type.
///
/// The row shows the chosen month (or "No answer"). A tap unfolds a month
/// wheel and a year wheel inline beneath it, the way the system date picker
/// looks; opening an unanswered row starts at this month, and "No answer"
/// clears it again. A month after this one is never stored.
///
/// Why two wheels and not `DatePicker`: SwiftUI's `DatePicker` has no month
/// precision, and UIKit's `UIDatePicker` in `.yearAndMonth` mode drew its
/// wheels outside its frame when hosted inline in the card (first screenshots
/// of this unit), covering the row above it.
struct LifeMonthPickerRow: View {
    let label: String
    @Binding var value: LifeYearMonth?
    var earliestYear = LifeTobaccoDetail.earliestStartYear
    var identifier: String
    @State private var isExpanded = false
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Button {
                if !isExpanded, value == nil { value = LifeYearMonth(date: .now) }
                withHLAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                LifeAdaptiveRow(label: label) {
                    Text(verbatim: display)
                        .font(.hlBody)
                        .foregroundStyle(isExpanded ? HLAccent.userBrandTint : HLText.secondary)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: display))
            .accessibilityHint(Text("life.quitMonth.hint"))
            .accessibilityIdentifier(identifier)

            if isExpanded {
                wheels
                Button {
                    value = nil
                    withHLAnimation(.easeInOut(duration: 0.2)) { isExpanded = false }
                } label: {
                    Text("life.noAnswer")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                        .frame(minHeight: 44)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier).clear")
            }
        }
    }

    private var wheels: some View {
        HStack(spacing: 0) {
            Picker(selection: monthBinding) {
                ForEach(1 ... 12, id: \.self) { month in
                    Text(verbatim: monthName(month)).tag(month)
                }
            } label: {
                Text("life.month")
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityLabel(Text("life.month"))
            .accessibilityIdentifier("\(identifier).month")

            Picker(selection: yearBinding) {
                ForEach(Array((earliestYear ... Self.thisMonth.year).reversed()), id: \.self) { year in
                    Text(verbatim: String(year)).tag(year)
                }
            } label: {
                Text("life.year")
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityLabel(Text("life.year"))
            .accessibilityIdentifier("\(identifier).year")
        }
        .frame(height: 160)
    }

    // MARK: - Values

    static var thisMonth: LifeYearMonth {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: .now)
        return LifeYearMonth(checkedYear: parts.year ?? 2026, month: parts.month ?? 1)
    }

    private var current: LifeYearMonth {
        value ?? Self.thisMonth
    }

    private var monthBinding: Binding<Int> {
        Binding(get: { current.month }, set: { value = Self.clamped(year: current.year, month: $0) })
    }

    private var yearBinding: Binding<Int> {
        Binding(get: { current.year }, set: { value = Self.clamped(year: $0, month: current.month) })
    }

    /// A month after this one becomes this month: a quit date lies behind us.
    static func clamped(year: Int, month: Int, now: LifeYearMonth = thisMonth) -> LifeYearMonth? {
        let picked = LifeYearMonth(year: year, month: month)
        guard let picked else { return nil }
        return picked > now ? now : picked
    }

    private func monthName(_ month: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.standaloneMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : String(month)
    }

    private var display: String {
        guard let value, let date = value.date() else { return String(localized: "life.noAnswer") }
        return date.formatted(.dateTime.month(.wide).year().locale(locale))
    }
}
