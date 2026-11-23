import SwiftUI

// MARK: - Keyboard commands

/// The shell's hardware-keyboard commands: Cmd-N opens the capture picker
/// under the Log tab's own title and symbol, Cmd-1 to Cmd-5 pick the bar
/// slots by position (Cmd-3, the Log slot, is Cmd-N, so it is not listed
/// twice), Cmd-R refreshes the page on screen. Esc and Cmd-. in sheets come
/// from the system through each sheet's `.cancellationAction`.
struct ShellKeyCommands: View {
    let router: AppRouter

    var body: some View {
        Group {
            if let log = AuthenticatedShell.tabDescriptors.first(where: \.isAction) {
                Button(LocalizedStringKey(log.titleKey), systemImage: log.systemImage) {
                    router.requestCapture()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            ForEach(Self.tabSlots, id: \.tab.id) { slot in
                Button(LocalizedStringKey(slot.tab.titleKey), systemImage: slot.tab.systemImage) {
                    router.selectResolved(slot.tab.id)
                }
                .keyboardShortcut(slot.key, modifiers: .command)
            }

            Button("shell.command.refresh", systemImage: "arrow.clockwise") {
                router.requestRefresh()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        // The commands live in the key-command responder chain and the
        // keyboard shortcut overlay, not on screen.
        .labelStyle(.titleAndIcon)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The destination tabs with the digit of their bar slot ("1" for the
    /// first, "5" for the last). The Log action slot is left out.
    static var tabSlots: [TabSlot] {
        AuthenticatedShell.tabDescriptors.enumerated().compactMap { index, tab in
            tab.isAction ? nil : TabSlot(tab: tab, digit: Character(String(index + 1)))
        }
    }

    struct TabSlot {
        let tab: AuthenticatedShell.TabDescriptor
        let digit: Character

        var key: KeyEquivalent {
            KeyEquivalent(digit)
        }
    }
}

// MARK: - Menu bar

extension FocusedValues {
    /// The router of the shell in the key window, for the menu bar.
    @Entry var hlShellRouter: AppRouter?
}

/// The shell's commands in the iPadOS menu bar: "New" holds Log (Cmd-N),
/// a "Go" menu the bar tabs (Cmd-1 to Cmd-5), "View" the refresh (Cmd-R).
/// The same entries as ``ShellKeyCommands``, which keeps them working where
/// there is no menu bar; the menu bar shows what the keyboard can do.
struct ShellCommands: Commands {
    @FocusedValue(\.hlShellRouter) private var router

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if let log = AuthenticatedShell.tabDescriptors.first(where: \.isAction) {
                Button(LocalizedStringKey(log.titleKey), systemImage: log.systemImage) {
                    router?.requestCapture()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(router == nil)
            }
        }
        CommandMenu("shell.menu.go") {
            ForEach(ShellKeyCommands.tabSlots, id: \.tab.id) { slot in
                Button(LocalizedStringKey(slot.tab.titleKey), systemImage: slot.tab.systemImage) {
                    router?.selectResolved(slot.tab.id)
                }
                .keyboardShortcut(slot.key, modifiers: .command)
                .disabled(router == nil)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("shell.command.refresh", systemImage: "arrow.clockwise") {
                router?.requestRefresh()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(router == nil)
        }
    }
}

// MARK: - Cmd-R

extension View {
    /// Runs `action` on Cmd-R while this page is on screen. Attached by the
    /// pull-to-refresh blocks, so every page that refreshes by pulling also
    /// refreshes from the keyboard, with the same work.
    func hlRefreshCommand(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(RefreshCommandModifier(action: action))
    }
}

private struct RefreshCommandModifier: ViewModifier {
    let action: @MainActor () async -> Void
    @Environment(AppRouter.self) private var router: AppRouter?
    /// Inside the Insights pager the neighbouring pages are on screen too;
    /// only the pager's active page refreshes. Asks "in the pager" through
    /// the constant ``EnvironmentValues/insightsInPager``, not through the
    /// strip context, which changes on every page change and would run this
    /// modifier on every built page each time.
    @Environment(\.insightsInPager) private var insightsInPager
    @Environment(\.insightsPageIsActive) private var insightsPageIsActive
    @State private var isOnScreen = false

    private var refreshesOnCommand: Bool {
        isOnScreen && (!insightsInPager || insightsPageIsActive)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .onChange(of: router?.refreshRequestCount) { oldValue, newValue in
                guard refreshesOnCommand, let oldValue, let newValue, newValue > oldValue else { return }
                Task { await action() }
            }
    }
}
