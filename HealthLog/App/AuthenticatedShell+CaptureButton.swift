import SwiftUI

// MARK: - Log as the "+" of the tab roots (regular)

/// Which tab root's "+" is on screen and which one the open capture picker
/// hangs on. In a regular window Log is no place of the sidebar: it is the
/// "+" in the navigation bar of Dashboard, Medications and Insights, and the
/// popover points at it. Without a "+" on screen (a diary page, More, a
/// pushed page) ⌘N or a link opens the popover at the top centre of the
/// window.
@MainActor
@Observable
final class ShellCaptureAnchor {
    /// The tab root whose "+" is on screen, if any.
    var visibleTab: AuthenticatedShell.TabIdentifier?
    /// The tab root whose "+" the open picker hangs on; `nil` hangs it at the
    /// top of the window.
    var presentingTab: AuthenticatedShell.TabIdentifier?

    /// The tab roots that carry the "+".
    nonisolated static let roots: Set<AuthenticatedShell.TabIdentifier> = [.home, .meds, .insights]

    /// Where a picker opened now hangs: on the "+" of the selected tab root
    /// while that "+" is on screen; else at the top of the window. A sheet
    /// (compact) hangs nowhere.
    nonisolated static func presentingTab(
        form: UserInterfaceSizeClass,
        visibleTab: AuthenticatedShell.TabIdentifier?,
        selectedTab: AuthenticatedShell.TabIdentifier
    ) -> AuthenticatedShell.TabIdentifier? {
        guard form == .regular, let visibleTab, visibleTab == selectedTab, roots.contains(visibleTab) else { return nil }
        return visibleTab
    }
}

/// What the "+" of a tab root needs from the shell.
struct ShellCaptureEntry {
    let anchor: ShellCaptureAnchor
    let open: () -> Void
    let isPresented: (AuthenticatedShell.TabIdentifier) -> Binding<Bool>
    let picker: () -> AnyView
    let didDismiss: () -> Void
}

extension EnvironmentValues {
    /// Set by the shell in a regular window only; compact keeps the Log tab.
    @Entry var hlShellCapture: ShellCaptureEntry?
}

extension View {
    /// The "+" of a tab root in a regular window: Log, with the capture
    /// picker as a popover pointing at it. Compact adds nothing.
    func hlShellCaptureItem(_ tab: AuthenticatedShell.TabIdentifier) -> some View {
        modifier(ShellCaptureItemModifier(tab: tab))
    }
}

private struct ShellCaptureItemModifier: ViewModifier {
    let tab: AuthenticatedShell.TabIdentifier
    @Environment(\.hlShellCapture) private var entry

    func body(content: Content) -> some View {
        content.toolbar {
            if let entry {
                ToolbarItem(placement: .topBarTrailing) {
                    ShellCaptureButton(tab: tab, entry: entry)
                }
            }
        }
    }
}

private struct ShellCaptureButton: View {
    let tab: AuthenticatedShell.TabIdentifier
    let entry: ShellCaptureEntry
    /// The detail keeps visited pages mounted behind the chosen one; their
    /// "+" never disappears, so the front decides which "+" is on screen.
    @Environment(\.hlShellPlaceIsFront) private var isFront

    var body: some View {
        Button(action: entry.open) {
            Label("Log", systemImage: "plus.circle")
        }
        .accessibilityLabel(Text("Add measurement"))
        .accessibilityIdentifier("shell.capture.button")
        .popover(isPresented: entry.isPresented(tab), arrowEdge: .top) {
            entry.picker()
                .frame(minWidth: CapturePickerPopover.minimumWidth, idealWidth: CapturePickerPopover.idealWidth)
                .presentationCompactAdaptation(.sheet)
                // A popover has no dismiss callback; its content leaving is
                // the same moment for the sheet gate.
                .onDisappear(perform: entry.didDismiss)
        }
        .onAppear { if isFront { entry.anchor.visibleTab = tab } }
        .onDisappear {
            if entry.anchor.visibleTab == tab { entry.anchor.visibleTab = nil }
        }
        .onChange(of: isFront) { _, front in
            if front {
                entry.anchor.visibleTab = tab
            } else if entry.anchor.visibleTab == tab {
                entry.anchor.visibleTab = nil
            }
        }
    }
}
