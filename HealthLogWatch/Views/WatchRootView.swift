import SwiftUI

/// Root of the watch app: a paged TabView across the three wrist tasks the
/// companion is for — confirm today's medication intakes, quick-log a mood, and
/// quick-capture a manual measurement (weight / blood pressure / glucose /
/// pulse). Each funnels through the phone's existing server-first write path.
struct WatchRootView: View {
    @Environment(WatchConnectivityClient.self) private var client

    /// The selected wrist tab. Driven by the complication deep links
    /// (`onOpenURL`) so tapping a watch-face complication opens the app to the
    /// matching task: next-dose → Medications, latest-measurement → Log.
    @State private var tab: WatchTab = .medications

    var body: some View {
        TabView(selection: $tab) {
            WatchMedicationsView()
                .tabItem { Label("Medications", systemImage: "pills.fill") }
                .tag(WatchTab.medications)
            WatchMoodView()
                .tabItem { Label("Mood", systemImage: "face.smiling") }
                .tag(WatchTab.mood)
            WatchMeasureView()
                .tabItem { Label("Log", systemImage: "plus.circle") }
                .tag(WatchTab.measure)
        }
        .onOpenURL { url in
            if let target = WatchTab(deepLink: url) { tab = target }
        }
    }
}

/// The three wrist tabs, addressable by the complication deep links. The host
/// portion of the `healthlog://…` URL selects the tab (mirrors the phone's
/// `healthlog://` deep-link scheme, but resolved entirely on the watch — the
/// complication opens the WATCH app, never the phone).
enum WatchTab: Hashable {
    case medications
    case mood
    case measure

    /// Resolve via the shared `WatchDeepLinkTarget` (Foundation-only, tested in
    /// `HealthLogTests`) so the tab routing has one source of truth.
    init?(deepLink url: URL) {
        switch WatchDeepLinkTarget(url: url) {
        case .medications: self = .medications
        case .mood: self = .mood
        case .measure: self = .measure
        case nil: return nil
        }
    }
}

/// Calm, single-message state for syncing / signed-out / all-done — never an
/// empty box (matches the app's self-suppress-empty doctrine).
struct WatchMessageState: View {
    let title: LocalizedStringKey
    var systemImage: String = "applewatch"

    var body: some View {
        VStack(spacing: HLSpace.sm) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(LAColor.textSecondary)
            Text(title)
                .font(.hlFootnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(LAColor.textSecondary)
        }
        .padding(HLSpace.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
