import SwiftUI

/// #126 P2 (server v1.40.2) — how far back the Coach may read. The server
/// treats it as a real limit for every answer; `All` (its default) is none.
struct CoachWindowCard: View {
    let store: AICoachSettingsStore
    /// `stuck` is whether the chosen window held; `error` is the store's
    /// failure, shown by the screen when it did not.
    var onWriteFinished: (_ stuck: Bool, _ error: HLError?) -> Void = { _, _ in }

    var body: some View {
        // The one line under the picker stays for what the label
        // cannot say: older readings are kept, only out of the
        // Coach's reach. One row, one heading: the picker is labelled
        // "Reichweite des Coachs" and the card has no title over it.
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // Picker under its title at the accessibility sizes.
                HLAdaptiveStack(spacing: HLSpace.md) { _ in
                    HLRowTitle("settings.coach.window.title")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.isWindowWriteInFlight {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                    Picker(
                        String(localized: "settings.coach.window.title"),
                        selection: Binding(
                            get: { store.coachDefaultWindow ?? .allTime },
                            set: { newValue in
                                Task {
                                    await store.setCoachDefaultWindow(newValue)
                                    onWriteFinished(store.coachDefaultWindow == newValue, store.error)
                                }
                            }
                        )
                    ) {
                        ForEach(CoachDefaultWindow.allCases) { window in
                            Text(LocalizedStringKey(window.labelKey)).tag(window)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(store.coachDefaultWindow == nil || store.isWindowWriteInFlight)
                    .accessibilityIdentifier("settings.coach.windowPicker")
                }
                Text("settings.coach.window.description")
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await store.loadCoachDefaultWindow() }
    }
}
