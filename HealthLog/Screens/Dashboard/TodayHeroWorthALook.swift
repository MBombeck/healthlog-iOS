import SwiftUI

/// What a hint card offers to tap, decided from its actions alone.
enum PriorityRailCardAffordance: Equatable {
    /// Nothing to tap; a dismissible kind is swiped away.
    case none
    /// One action: the whole card is the button.
    case wholeCard(DailyPriorityItem.Action)
    /// Two or three actions (the coach check-in): buttons under the text.
    case buttons([DailyPriorityItem.Action])

    static func resolve(_ actions: [DailyPriorityItem.Action]) -> PriorityRailCardAffordance {
        switch actions.count {
        case 0: .none
        case 1: .wholeCard(actions[0])
        default: .buttons(actions)
        }
    }

    /// The former button title, now spoken as the card's hint.
    var accessibilityHint: String? {
        guard case let .wholeCard(action) = self else { return nil }
        return TodayHeroCopy.actionLabel(action.labelKey)
    }

    /// No hint card draws a chevron, whatever it offers: tappable cards
    /// elsewhere in the app carry none either.
    var rowIndicator: HLRowIndicator {
        .hidden
    }
}

/// The "worth a look" hints as a section of their own under the hero: the
/// section header, then one slim card per hint. An empty list draws nothing,
/// not even the header.
struct TodayHeroWorthALookSection: View {
    let items: [DailyPriorityItem]
    var coachActionInFlight: Bool = false
    let onAction: (DailyPriorityItem, DailyPriorityItem.Action) -> Void
    let onDismiss: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func isShown(_ items: [DailyPriorityItem]) -> Bool {
        !items.isEmpty
    }

    /// A stable identity per hint, so the cards below a dismissed one move
    /// up instead of being redrawn in its place.
    static func cardIDs(_ items: [DailyPriorityItem]) -> [String] {
        items.enumerated().map { index, item in
            if let key = item.itemKey, !key.isEmpty { return "key:\(key)" }
            return "index:\(index)"
        }
    }

    var body: some View {
        if Self.isShown(items) {
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                HLSectionHeader(verbatim: TodayHeroCopy.worthALook, rank: .area)
                ForEach(Array(zip(Self.cardIDs(items), items)), id: \.0) { _, item in
                    PriorityRailCard(
                        item: item,
                        actionsPending: item.kindToken == .coachCheckin && coachActionInFlight,
                        onAction: { action in onAction(item, action) },
                        onDismiss: onDismiss
                    )
                }
            }
            // The rest moves up after a card leaves; under Reduce Motion it
            // only fades.
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.3), value: Self.cardIDs(items))
            .hlContainerGap(HLLayout.cardGap)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dashboard.todayHero.worthALook")
        }
    }
}

// MARK: - Hint card

/// One hint: a plain card with the kind's symbol (the only place its status
/// colour shows), the title and the server's text under it. One action makes
/// the whole card the button, without a chevron; two or three keep their
/// buttons under the text. A dismissible hint is swiped away to either side
/// like a mail, or put away from its long-press menu or as a named
/// accessibility action; it carries no mark of its own.
struct PriorityRailCard: View {
    let item: DailyPriorityItem
    var actionsPending: Bool = false
    let onAction: (DailyPriorityItem.Action) -> Void
    let onDismiss: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var affordance: PriorityRailCardAffordance {
        .resolve(item.boundedActions)
    }

    private var dismissKey: String? {
        item.isDismissible ? item.itemKey : nil
    }

    var body: some View {
        card
            .hlSwipeToDismiss(isEnabled: dismissKey != nil) {
                if let dismissKey { onDismiss(dismissKey) }
            }
    }

    @ViewBuilder
    private var card: some View {
        switch affordance {
        case let .wholeCard(action):
            SwipeAwareButton {
                onAction(action)
            } label: {
                HLCard { row }
            }
            .hlPressable(hover: .lift)
            .disabled(action.href == nil && actionsPending)
            .accessibilityHint(Text(verbatim: affordance.accessibilityHint ?? ""))
            .accessibilityIdentifier("dashboard.todayHero.worthALook.card")
        case let .buttons(actions):
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    row
                    actionsRow(actions)
                }
            }
            .accessibilityElement(children: .contain)
        case .none:
            HLCard { row }
        }
    }

    /// How many lines a hint's title and text may take. A hint is no data
    /// row: its text is a sentence whose statement must not be cut, so it
    /// gets two lines under a one-line title; only a third line ends in
    /// "…". At the accessibility sizes nothing is cut.
    struct LineLimits: Equatable {
        let title: Int?
        let body: Int?

        static func resolve(isAccessibilitySize: Bool) -> LineLimits {
            isAccessibilitySize ? LineLimits(title: nil, body: nil) : LineLimits(title: 1, body: 2)
        }
    }

    /// Symbol, title and text on the shared row measures (symbol column,
    /// gap, title and detail faces).
    /// The symbol stands in the fixed row column, an empty one when the kind
    /// has none, so every hint's text starts at the same edge. At the
    /// accessibility sizes the symbol stands above the text, like every row.
    private var row: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    glyph
                    labels
                }
            } else {
                HStack(alignment: .top, spacing: HLRowMetrics.gap) {
                    glyph
                    labels
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: HLRowMetrics.minHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var glyph: some View {
        HLRowGlyph(symbol: Self.symbol(for: item.kindToken), tint: statusTint)
    }

    private var labels: some View {
        let limits = LineLimits.resolve(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
        return VStack(alignment: .leading, spacing: HLRowMetrics.labelSpacing) {
            Text(verbatim: item.title)
                .font(HLRowTitle.font)
                .foregroundStyle(HLText.primary)
                .lineLimit(limits.title)
                .fixedSize(horizontal: false, vertical: true)
            if let body = item.body, !body.isEmpty {
                Text(verbatim: body)
                    .hlText(.rowSubtitle)
                    .lineLimit(limits.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The coach check-in's two or three answers: one row of equal small
    /// buttons, 44 pt high, stacked when the words no longer fit side by side.
    private func actionsRow(_ actions: [DailyPriorityItem.Action]) -> some View {
        HLButtonRow(size: .small) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                HLButton(Text(verbatim: TodayHeroCopy.actionLabel(action.labelKey)), variant: .secondary) {
                    onAction(action)
                }
                .disabled(action.href == nil && actionsPending)
            }
        }
    }

    /// Deterministic SF Symbol per kind (the icon the serialisable item can't
    /// carry). Unknown kind → no icon, the column stays empty.
    static func symbol(for kind: DailyPriorityItem.Kind?) -> String? {
        switch kind {
        case .doseWindow: "pills.fill"
        case .preventiveCare: "calendar.badge.clock"
        case .syncIssue: "arrow.triangle.2.circlepath"
        case .coachCheckin: "message"
        case .milestone: "medal"
        case .ecgNewRecording: "waveform.path.ecg"
        case .tensionWindow: "waveform.path"
        // Same-time baseline: the day's cumulative standing against the
        // usual day at this hour. Steps-only on the rail, hence the walk glyph.
        case .sameTimeBaseline: "figure.walk"
        case .none: nil
        }
    }

    /// Status → a restrained HL semantic tone, on the symbol only. Info and
    /// unknown stay neutral per the monochrome doctrine.
    private var statusTint: Color {
        switch item.statusToken {
        case .success: HLColor.statusOK
        case .warning: HLColor.statusWarn
        case .destructive: HLColor.statusBad
        case .info, .none: HLText.secondary
        }
    }
}

/// The whole-card button of a hint. It sits inside the swipeable card and
/// reads its state there: the touch that ends a sideways swipe is no tap.
private struct SwipeAwareButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.hlSwipeIsActive) private var swipeIsActive

    var body: some View {
        Button {
            guard !swipeIsActive else { return }
            action()
        } label: {
            label()
        }
    }
}
