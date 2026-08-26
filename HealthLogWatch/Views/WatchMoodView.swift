import SwiftUI
import WatchKit

/// Mood quick-log from the wrist. Multi-log: the picker is ALWAYS primary when
/// signed in — tapping a level logs immediately (durable, server-first via the
/// phone), flashes a brief checkmark on that row + a success haptic, increments
/// the quiet "N today" subhead, then returns to the picker so the next check-in
/// is one tap away. No day-level lock, no "Change" gate. Uses the canonical
/// `Mood1…Mood5` icon pack (same glyphs as the phone), not emoji.
struct WatchMoodView: View {
    @Environment(WatchConnectivityClient.self) private var client

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Mood")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !client.hasReceived {
            WatchMessageState(title: "Syncing…", systemImage: "arrow.triangle.2.circlepath")
        } else if !client.signedIn {
            WatchMessageState(title: "Sign in on your iPhone", systemImage: "iphone")
        } else {
            picker
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(spacing: HLSpace.xs) {
                Text("How are you?")
                    .font(.hlHeadline)
                    .foregroundStyle(LAColor.text)
                Text("\(client.moodCountToday) today")
                    .font(.hlCaption)
                    .foregroundStyle(LAColor.textSecondary)
                    .padding(.bottom, HLSpace.xs)
                    .contentTransition(.numericText())
                    .animation(.default, value: client.moodCountToday)
                ForEach(WatchMoodLevel.all) { level in
                    moodButton(level)
                }
                footer
                    .padding(.top, HLSpace.xs)
            }
            .padding(.vertical, HLSpace.xs)
        }
    }

    private func moodButton(_ level: WatchMoodLevel) -> some View {
        let justLogged = client.justLoggedScore == level.score
        return Button {
            client.logMood(score: level.score)
            WKInterfaceDevice.current().play(.success)
        } label: {
            HStack(spacing: HLSpace.xs) {
                ZStack {
                    Image(WatchMoodLevel.iconName(for: level.score))
                        .resizable()
                        .scaledToFit()
                        .opacity(justLogged ? 0 : 1)
                    if justLogged {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(LAColor.success)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
                Text(level.title)
                    .font(.hlBody)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(LAColor.text)
        .animation(.easeInOut(duration: 0.2), value: justLogged)
        .accessibilityLabel(Text(level.title))
        .accessibilityHint(Text("Logs this mood"))
    }

    /// Quiet, non-blocking last-action footer — never gates the next log. Only
    /// surfaces when the most-recent log is queued ("will sync") or failed
    /// ("not saved — tap to retry"). A `.saved`/`nil` state shows nothing.
    @ViewBuilder
    private var footer: some View {
        switch client.lastMoodActionState {
        case .queued:
            Label("Last: will sync", systemImage: "clock.badge.checkmark")
                .font(.hlCaption)
                .foregroundStyle(LAColor.warn)
                .labelStyle(.titleAndIcon)
        case .failed:
            Button {
                client.retryMood()
                WKInterfaceDevice.current().play(.retry)
            } label: {
                Label("Last: not saved — retry", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.hlCaption)
            }
            .buttonStyle(.borderless)
            .tint(LAColor.warn)
        default:
            EmptyView()
        }
    }
}
