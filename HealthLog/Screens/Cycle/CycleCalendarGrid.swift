import SwiftUI

/// **Phase C5 — the cycle calendar (one month).**
///
/// A monochrome month grid of logged + predicted cycle days. Warm phase tints
/// are sparse highlights only: a logged period day gets a filled warm dot, a
/// predicted period day a soft ringed dot, the fertile window a delicate tinted
/// underline, predicted ovulation a small ring accent. Logged symptoms / flow
/// surface as a tiny marker. Tapping a day calls `onSelectDay` (→ the C4 capture
/// sheet seeded to that date).
///
/// Pure-presentation: it owns no store, only the `[CalendarDayDTO]` for the
/// month + the visible month. The parent drives month paging.
struct CycleCalendarGrid: View {
    /// All calendar days (any range) — the grid filters to `month`.
    let days: [CalendarDayDTO]
    /// First day of the visible month (any time on that day).
    let month: Date
    let today: String
    /// When true (still learning, `< CycleMaturity.minCyclesForFertility`
    /// confirmed cycles) the fertile-window wash and the predicted-ovulation ring
    /// are NOT painted, and their a11y labels are dropped — those are
    /// population-prior guesses, not facts. Period markers + logged symptoms
    /// always stay. Defaults to `false` so other call sites keep full markers.
    var suppressFertility: Bool = false
    let onSelectDay: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: HLSpace.xs), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            weekdayHeader
            LazyVGrid(columns: Self.columns, spacing: HLSpace.sm) {
                ForEach(gridCells, id: \.id) { cell in
                    cellView(cell)
                }
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: HLSpace.xs) {
            ForEach(Self.weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: GridCell) -> some View {
        switch cell.kind {
        case .blank:
            Color.clear.frame(height: 40)
        case let .day(key, dto):
            CycleDayCell(
                dayNumber: cell.dayNumber,
                key: key,
                dto: dto,
                isToday: key == today,
                suppressFertility: suppressFertility,
                scheme: colorScheme
            )
            .frame(height: 40)
            .contentShape(Rectangle())
            .onTapGesture { onSelectDay(key) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.accessibilityLabel(
                dayNumber: cell.dayNumber, dto: dto, suppressFertility: suppressFertility
            )))
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: - Grid model

    struct GridCell: Identifiable {
        enum Kind {
            case blank
            case day(key: String, dto: CalendarDayDTO?)
        }

        let id: String
        let dayNumber: Int
        let kind: Kind
    }

    private var byDate: [String: CalendarDayDTO] {
        Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
    }

    private var gridCells: [GridCell] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday — matches the weekday header below.
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let first = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let lookup = byDate
        var cells: [GridCell] = []
        for i in 0 ..< leading {
            cells.append(GridCell(id: "blank-\(i)", dayNumber: 0, kind: .blank))
        }
        for day in range {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: first) else { continue }
            let key = Self.dayKey(date)
            cells.append(GridCell(id: key, dayNumber: day, kind: .day(key: key, dto: lookup[key])))
        }
        return cells
    }

    // MARK: - Helpers

    static func accessibilityLabel(
        dayNumber: Int,
        dto: CalendarDayDTO?,
        suppressFertility: Bool = false
    ) -> String {
        guard let dto else { return "\(dayNumber)" }
        var parts = ["\(dayNumber)"]
        if dto.isPeriodLogged {
            parts.append(String(localized: "cycle.calendar.a11y.periodLogged"))
        } else if dto.isPredictedPeriod {
            parts.append(String(localized: "cycle.calendar.a11y.predictedPeriod"))
        }
        // Fertile/ovulation a11y labels follow the painted markers: dropped while
        // still learning so VoiceOver doesn't announce a guess as a fact.
        if !suppressFertility {
            if dto.isPredictedOvulation {
                parts.append(String(localized: "cycle.calendar.a11y.ovulation"))
            } else if dto.isFertileWindow {
                parts.append(String(localized: "cycle.calendar.a11y.fertile"))
            }
        }
        if dto.hasSymptoms {
            parts.append(String(localized: "cycle.calendar.a11y.symptoms"))
        }
        return parts.joined(separator: ", ")
    }

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static let weekdaySymbols: [String] = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        // Rotate so Monday leads.
        return Array(symbols[1...] + symbols[...0])
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Day cell

/// One calendar day: the number, plus sparse warm markers for its state.
private struct CycleDayCell: View {
    let dayNumber: Int
    let key: String
    let dto: CalendarDayDTO?
    let isToday: Bool
    /// While still learning, the fertile wash + predicted-ovulation ring are not
    /// drawn (population-prior guess, not the user's data). Period + symptom
    /// markers are unaffected.
    let suppressFertility: Bool
    let scheme: ColorScheme

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                background
                Text("\(dayNumber)")
                    .font(.hlSubhead.monospacedDigit())
                    .foregroundStyle(isToday ? HLText.primary : HLText.secondary)
                    .fontWeight(isToday ? .bold : .regular)
            }
            .frame(width: 30, height: 30)
            markers
        }
    }

    @ViewBuilder
    private var background: some View {
        // The day's background marker is drawn by the SHARED `CycleMarkerSwatch`
        // primitive so the legend swatch and the calendar cell are pixel-identical.
        // Period = clay fill (logged) or dashed clay ring (predicted); ovulation =
        // solid honey ring; fertile = soft honey wash.
        if dto?.isPeriodLogged == true {
            CycleMarkerSwatch.shape(.periodLogged, scheme: scheme)
        } else if dto?.isPredictedPeriod == true {
            CycleMarkerSwatch.shape(.predictedPeriod, scheme: scheme)
        } else if !suppressFertility, dto?.isPredictedOvulation == true {
            CycleMarkerSwatch.shape(.ovulation, scheme: scheme)
        } else if !suppressFertility, dto?.isFertileWindow == true {
            CycleMarkerSwatch.shape(.fertile, scheme: scheme)
        }
        if isToday {
            CycleMarkerSwatch.shape(.today, scheme: scheme)
        }
    }

    /// Symptoms surface as a hollow grey diamond below the number — a different
    /// SHAPE (not a dot), so it never blends into the round period/fertile markers
    /// and stays distinct under colour-blindness.
    @ViewBuilder
    private var markers: some View {
        if dto?.hasSymptoms == true {
            SymptomGlyph()
                .stroke(HLText.secondary, lineWidth: 1)
                .frame(width: 6, height: 6)
        } else {
            Color.clear.frame(height: 6)
        }
    }
}

// MARK: - Shared marker swatch

/// The single source of truth for how each cycle marker looks. Both the calendar
/// day cell and the legend render through this, so a legend swatch is guaranteed
/// to be the exact shape / colour / dash the calendar paints — no drift.
struct CycleMarkerSwatch: View {
    enum Kind: CaseIterable {
        case periodLogged
        case predictedPeriod
        case fertile
        case ovulation
        case symptoms
        case today
    }

    let kind: Kind
    let scheme: ColorScheme

    var body: some View {
        Self.shape(kind, scheme: scheme)
    }

    /// Draws the marker filling the available space. Diamond (symptoms) is the
    /// only non-circular marker — a deliberately different SHAPE.
    @ViewBuilder
    static func shape(_ kind: Kind, scheme: ColorScheme) -> some View {
        switch kind {
        case .periodLogged:
            Circle().fill(menstrual(scheme).opacity(scheme == .dark ? 0.42 : 0.32))
        case .predictedPeriod:
            Circle().stroke(menstrual(scheme).opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5]))
        case .fertile:
            Circle().fill(fertile(scheme).opacity(scheme == .dark ? 0.24 : 0.20))
        case .ovulation:
            Circle().stroke(fertile(scheme).opacity(0.95), lineWidth: 1.8)
        case .symptoms:
            SymptomGlyph().stroke(HLText.secondary, lineWidth: 1.2).padding(2)
        case .today:
            Circle().stroke(HLText.primary.opacity(0.6), lineWidth: 1.3)
        }
    }

    private static func menstrual(_ scheme: ColorScheme) -> Color {
        CyclePhasePalette.tint(for: .menstrual, scheme: scheme)
    }

    private static func fertile(_ scheme: ColorScheme) -> Color {
        // Honey / follicular tint — the warm yellow family for the whole fertile
        // window, deliberately apart from the clay period and the grey symptom glyph.
        CyclePhasePalette.tint(for: .follicular, scheme: scheme)
    }
}

// MARK: - Symptom glyph

/// A small diamond outline — the distinct SHAPE used for a "symptoms logged"
/// marker so it never blends into the round fertile/period dots (also reads under
/// colour-blindness, where hue alone wouldn't separate the markers).
struct SymptomGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
