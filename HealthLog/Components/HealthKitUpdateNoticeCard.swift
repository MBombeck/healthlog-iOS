import SwiftUI

/// **25-01 (decision E-2026-08-28).** The one-time dashboard card that tells
/// an *existing* installation what an update changed about Apple Health.
///
/// Why this is a second surface beside `HealthKitConnectBanner` rather than a
/// banner change: the banner's rule is pinned (12-12) and deliberately
/// refuses on `isConnected` first — correct for read-only users whose data
/// demonstrably flows (K10), and exactly the latch that left the field
/// device with no connect affordance at all. This card carries its own rule
/// (`HealthKitUpdateNotice.visibleVariant`): armed once per install by the
/// launch prologue's update evidence, dismissed once by the ✕, rendered from
/// the readiness state — and, since 25-02 (E-2026-08-29 #5), gone the moment
/// the SYSTEM says its sheet was answered (`getRequestStatusForAuthorization`,
/// the one API that speaks for read types too). A completed sheet removes the
/// card in the same session and across launches, with no local memory.
///
/// The two buttons stay individually addressable — deliberately NO
/// `.accessibilityElement(children: .combine)`: 12-12 measured that the
/// banner's merge makes both child identifiers unresolvable (D-12-12-B),
/// which silently disarmed a sibling test's dismissal.
struct HealthKitUpdateNoticeCard: View {
    @Environment(HKReadinessStore.self) private var readiness
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Mirrors `HealthKitUpdateNotice.dismissedDefaultsKey` reactively so the
    /// ✕ removes the card in place; the persisted rule itself stays owned by
    /// `HealthKitUpdateNotice`.
    @AppStorage(HealthKitUpdateNotice.dismissedDefaultsKey) private var dismissed = false

    /// **25-02 (E-2026-08-29 #5) — the system's answer, asked and re-asked,
    /// never remembered.** `nil` until the first query returns (the card
    /// renders nothing rather than flashing an answer it does not have yet).
    /// Queried on every appearance keyed to the readiness state — a fresh
    /// launch asks the system instead of trusting anything cached — and
    /// re-queried right after the card's own Verbinden flow returns, so a
    /// completed sheet removes the card in the same session. This is the
    /// detection the shipped `.fullyGranted`-only rule could not do: Apple
    /// never re-asks a decided write type and never reports read grants, so
    /// a partially-granted install could never clear the card (the operator's
    /// build-270 field report).
    @State private var sheetStatus: HealthKitUpdateNotice.SheetStatus?

    var body: some View {
        Group {
            if !dismissed, let sheetStatus, let variant = HealthKitUpdateNotice.visibleVariant(
                state: readiness.state,
                statuses: readiness.writeAuthorizationStatuses,
                sheetStatus: sheetStatus
            ) {
                card(for: variant)
                    .transition(transition)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: dismissed)
            }
        }
        .task(id: readiness.state) { await refreshSheetStatus() }
    }

    /// Ask the system whether the sheet for the CANDIDATE variant's request
    /// set is still to be answered: the E2 delta (State of Mind share+read,
    /// ECG read) for new-types, the full default sets for connect. Both are
    /// subsets of the shipped defaults — no type-set pin can move here.
    private func refreshSheetStatus() async {
        let candidate = HealthKitUpdateNotice.variant(
            state: readiness.state,
            statuses: readiness.writeAuthorizationStatuses
        )
        let answered: Bool? = switch candidate {
        case .none:
            nil
        case .newTypes:
            await readiness.authorizationSheetAnswered(
                shareIdentifiers: HealthKitUpdateNotice.newTypeShareIdentifiers,
                readIdentifiers: HealthKitUpdateNotice.newTypeReadIdentifiers
            )
        case .connect:
            await readiness.authorizationSheetAnswered()
        }
        sheetStatus = switch answered {
        case .some(true): .answered
        case .some(false): .open
        case .none: .unknown
        }
    }

    private func card(for variant: HealthKitUpdateNotice.Variant) -> some View {
        HLCard(style: .elevated) {
            HStack(alignment: .top, spacing: HLSpace.md) {
                icon(for: variant)
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text(title(for: variant))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle(for: variant))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    connectButton
                        .padding(.top, HLSpace.xs)
                }
                Spacer(minLength: 0)
                dismissButton
            }
        }
    }

    private var transition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top))
    }

    private func icon(for variant: HealthKitUpdateNotice.Variant) -> some View {
        Image(systemName: variant == .newTypes ? "sparkles" : "heart.fill")
            .font(.hlIcon(HLIconSize.lg, weight: .bold))
            .foregroundStyle(.tint)
            .frame(width: 36, height: 36)
            .background(.tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
            .accessibilityHidden(true)
    }

    private func title(for variant: HealthKitUpdateNotice.Variant) -> String {
        switch variant {
        case .connect:
            String(localized: "Connect to Apple Health")
        case .newTypes:
            String(localized: "New: ECG and mood can sync")
        }
    }

    private func subtitle(for variant: HealthKitUpdateNotice.Variant) -> String {
        switch variant {
        case .connect:
            String(localized: """
            HealthLog has no access to your Apple Health data on this device. \
            Connect it so your values arrive automatically.
            """)
        case .newTypes:
            String(localized: """
            This update can also sync ECGs and mood from Apple Health. \
            Allow access to turn both on.
            """)
        }
    }

    /// The SAME connect flow the banner's CTA uses — the recovery path over
    /// the default sets. No set changes ride on this card, so the 5.1.3(i)
    /// transparency page cannot move with it, and medications stay behind
    /// their per-object settings toggle (the SIGABRT fence).
    private var connectButton: some View {
        Button {
            Task {
                await readiness.requestAuthorization()
                // 25-02 — the flow completed; ask the system again NOW so an
                // answered sheet takes the card off this session's screen
                // (the store's own readiness refresh already ran inside
                // `requestAuthorization()`).
                await refreshSheetStatus()
            }
        } label: {
            HStack(spacing: HLSpace.xs) {
                if readiness.isRequestingAuthorization {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Text(connectButtonLabel)
                    .font(.hlSubhead.weight(.semibold))
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.connectButtonIdentifier)
        .disabled(readiness.isRequestingAuthorization)
    }

    private var connectButtonLabel: String {
        if case .denied = readiness.state {
            return String(localized: "Open settings")
        }
        return String(localized: "Connect")
    }

    /// The ✕: per install, permanent, and deliberately its own accessibility
    /// element.
    private var dismissButton: some View {
        Button {
            HealthKitUpdateNotice.markDismissed()
        } label: {
            Image(systemName: "xmark")
                .font(.hlIcon(HLIconSize.sm, weight: .semibold))
                .foregroundStyle(HLText.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Hide"))
        .accessibilityIdentifier(Self.dismissButtonIdentifier)
    }

    static let connectButtonIdentifier = "healthkitUpdateNotice.connectButton"
    static let dismissButtonIdentifier = "healthkitUpdateNotice.dismissButton"
}
