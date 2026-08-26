import SwiftUI

/// **CU-35 (1) — the sentence under the "Sync now" button.**
///
/// Shared by every integration surface that can trigger a manual pull
/// (`OAuthIntegrationScreen` for Oura / Polar / Fitbit / Strava,
/// `NightscoutIntegrationScreen`), so the four providers can never drift into
/// four different readings of the same server answer.
///
/// **The point of this view is that the three outcomes differ in what they
/// SAY, not merely in what colour they are.** A user who cannot read the colour
/// — or who reads it as "red = I broke something" — still has to get the right
/// idea from the words:
///
///  - **429** is not an error. It says "you just did", and it names that it
///    works again shortly. Neutral icon, secondary text, no failure tone.
///  - **502** names the **provider** as the place the fault sits, because the
///    user cannot fix it and must not go looking. It is a warning, not a defect
///    report about HealthLog.
///  - **`outcome == .empty`** is a normal ending: nothing new over there. It
///    gets a calm confirmation, never the failure register — a green tick with
///    a "0" would be just as dishonest in the other direction, so it gets its
///    own quiet line instead.
struct ManualSyncStatusRow: View {
    let state: ManualSyncState
    /// Provider display name, interpolated into the upstream sentence so the
    /// copy can name where the fault actually sits.
    let providerName: String

    var body: some View {
        if state.hasMessage {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Image(systemName: icon)
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("integration.sync.status")
        }
    }

    // MARK: - Copy

    /// Already-localized sentence for the current state. `verbatim` throughout
    /// because every branch either interpolates a runtime value (the provider
    /// name, the import count) or forwards server-derived text — a re-resolved
    /// `LocalizedStringKey` would look for a key that does not exist.
    private var message: String {
        switch state {
        case .idle, .running:
            ""
        case let .rateLimited(retryAfter):
            Self.rateLimitedMessage(retryAfter: retryAfter)
        case .upstreamUnavailable:
            String(
                format: NSLocalizedString(
                    "integration.sync.upstreamUnavailable",
                    comment: "502 on a manual sync; %@ is the provider name."
                ),
                providerName
            )
        case let .finished(result):
            Self.finishedMessage(result)
        case let .failed(text):
            text
        }
    }

    /// A 429 is the one message that changes shape with data we may not have:
    /// the transport reads `X-RateLimit-Reset` when the server sends it, and
    /// `nil` simply means we stay unspecific rather than inventing a number.
    private static func rateLimitedMessage(retryAfter: TimeInterval?) -> String {
        guard let retryAfter, retryAfter > 0 else {
            return String(localized: "integration.sync.rateLimited")
        }
        return String(
            format: NSLocalizedString(
                "integration.sync.rateLimited.seconds",
                comment: "429 on a manual sync; %lld is the wait in seconds."
            ),
            Int(retryAfter.rounded(.up))
        )
    }

    /// The server's verdict, stated plainly. `imported` is always named — a
    /// count the user can check is what makes the tone believable.
    private static func finishedMessage(_ result: ManualSyncResult) -> String {
        switch result.outcome {
        case .empty:
            String(localized: "integration.sync.empty")
        case .success:
            String(localized: "integration.sync.success \(result.imported)")
        case .partial:
            String(localized: "integration.sync.partial \(result.imported)")
        case .failed:
            String(localized: "integration.sync.nothingLanded")
        }
    }

    // MARK: - Chrome

    private var icon: String {
        switch state {
        case .idle, .running: "arrow.triangle.2.circlepath"
        case .rateLimited: "clock"
        case .upstreamUnavailable: "antenna.radiowaves.left.and.right.slash"
        case .failed: "exclamationmark.triangle.fill"
        case let .finished(result):
            switch result.outcome {
            case .success: "checkmark.circle.fill"
            case .empty: "checkmark.circle"
            case .partial: "exclamationmark.triangle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    /// Colour REINFORCES the sentence, it never carries it alone. The 429 tint
    /// is deliberately the neutral secondary ink and not a warning colour: it
    /// is not a problem, so it must not look like one.
    private var tint: Color {
        switch state {
        case .idle, .running: HLText.tertiary
        case .rateLimited: HLText.secondary
        case .upstreamUnavailable: HLColor.statusWarn
        case .failed: HLColor.statusBad
        case let .finished(result):
            switch result.outcome {
            case .success: HLColor.statusOK
            case .empty: HLText.secondary
            case .partial: HLColor.statusWarn
            case .failed: HLColor.statusBad
            }
        }
    }
}
