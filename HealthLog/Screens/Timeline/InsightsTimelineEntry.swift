import SwiftUI

/// The quiet way from the Insights overview to the timeline: one row at the
/// foot of the column, after everything the overview says itself. Offered
/// only by a server that has the timeline.
struct InsightsTimelineEntry: View {
    let onOpen: () -> Void

    @AppStorage(KnownServerVersion.defaultsKey) private var serverVersion: String?

    var body: some View {
        if TimelineRepository.isTimelineAvailable(serverVersion: serverVersion) {
            Button(action: onOpen) {
                HLCard {
                    HLRowLayout(title: "timeline.title", subtitle: "timeline.insights.subtitle", indicator: .disclosure) {
                        EmptyView()
                    } leading: {
                        HLSettingsIconChip(symbol: "calendar.day.timeline.left", tint: HLAccent.userBrandTint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hlRow)
            .hoverEffect(.lift)
            .accessibilityIdentifier("insights.timeline.entry")
        }
    }
}
