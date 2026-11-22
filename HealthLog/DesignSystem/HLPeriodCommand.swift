import SwiftUI

/// The periods of the page on screen, for the "Period" menu of the menu bar.
///
/// Every page with a period bar publishes one through
/// ``SwiftUI/View/hlPeriodBar(selection:label:isShown:)``, so the menu and its
/// shortcuts exist exactly where a period can be chosen.
struct HLPeriodCommand {
    struct Option: Identifiable {
        let id: Int
        /// The full name ("Week"), as the menu shows it.
        let title: String
        let isSelected: Bool
        /// Option-Command and the option's place, 1 for the first.
        let key: KeyEquivalent?
    }

    let options: [Option]
    let select: (Int) -> Void

    /// Shortcuts by place: Option-Command 1 to 9, none past nine.
    nonisolated static func key(forIndex index: Int) -> KeyEquivalent? {
        (0 ..< 9).contains(index) ? KeyEquivalent(Character(String(index + 1))) : nil
    }

    @MainActor
    init<Option: HLRangeOption>(selection: Binding<Option>) where Option.AllCases: RandomAccessCollection {
        let all = Array(Option.allCases)
        options = all.enumerated().map { index, option in
            HLPeriodCommand.Option(
                id: index,
                title: option.rangeAccessibilityLabel,
                isSelected: option == selection.wrappedValue,
                key: Self.key(forIndex: index)
            )
        }
        select = { index in
            guard all.indices.contains(index) else { return }
            selection.wrappedValue = all[index]
        }
    }
}

extension FocusedValues {
    /// The periods of the page in the key window.
    @Entry var hlPeriodCommand: HLPeriodCommand?
}

/// The "Period" menu: one entry per period of the page on screen, the
/// chosen one checked. Empty, and so hidden, on a page without periods.
struct HLPeriodCommands: Commands {
    @FocusedValue(\.hlPeriodCommand) private var period

    var body: some Commands {
        CommandMenu("Period") {
            if let period {
                ForEach(period.options) { option in
                    Toggle(isOn: Binding(get: { option.isSelected }, set: { _ in period.select(option.id) })) {
                        Text(verbatim: option.title)
                    }
                    .modifier(HLOptionalKey(key: option.key))
                }
            }
        }
    }
}

private struct HLOptionalKey: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: [.command, .option])
        } else {
            content
        }
    }
}

/// Publishes a page's periods to the menu bar while the page is the one on
/// screen: shown, not covered by a pushed page, and in the Insights pager the
/// active page. The same condition as Cmd-R's refresh.
///
/// Only in a regular width, where the menu bar is: a compact window (the
/// phone) has no menu to fill, and publishing there changed the scene's
/// focused values on every page change of the Insights pager, a measured
/// share of the cost of each swipe.
struct HLPeriodCommandPublisher: ViewModifier {
    let command: HLPeriodCommand
    let isShown: Bool
    @Environment(\.insightsInPager) private var inPager
    @Environment(\.insightsPageIsActive) private var insightsPageIsActive
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isOnScreen = false

    /// Whether a page publishes its periods. Pure, so the rule is tested.
    nonisolated static func publishes(
        isShown: Bool,
        isOnScreen: Bool,
        inPager: Bool,
        isActivePage: Bool,
        sizeClass: UserInterfaceSizeClass? = .regular
    ) -> Bool {
        sizeClass == .regular && isShown && isOnScreen && (!inPager || isActivePage)
    }

    func body(content: Content) -> some View {
        let publishes = Self.publishes(
            isShown: isShown,
            isOnScreen: isOnScreen,
            inPager: inPager,
            isActivePage: insightsPageIsActive,
            sizeClass: sizeClass
        )
        content
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .focusedSceneValue(\.hlPeriodCommand, publishes ? command : nil)
    }
}
