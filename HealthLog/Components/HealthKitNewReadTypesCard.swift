import SwiftUI

/// **HK-NEW (1.5)** — the one-time dashboard card that explains the new Apple
/// Health types before iOS asks for them.
///
/// Up to 1.4 a read type that joined later (RMSSD, waist) was asked on the next
/// foreground, straight into the system sheet. Five at once, after an update,
/// would be exactly the unexplained surprise HIG warns about. So the server-v1.44
/// read types are "announced" (`HKReadinessStore.LateReadType.announced`): the
/// foreground path leaves them alone and this card says what is new. "Continue"
/// opens the one system sheet; the ✕ means "not now" and the card does not come
/// back. The Apple Health settings page keeps a quiet way back while iOS still
/// calls the types unanswered (`AppleHealthNewReadTypesLink`).
///
/// Shown only to someone who went through the HealthKit sheet before and whose
/// server stores the types; a new install gets them in the onboarding sheet.
/// It sits in the slot of `HealthKitUpdateNoticeCard` and only when that card
/// has nothing to say, so Today never stacks two Apple Health cards.
struct HealthKitNewReadTypesCard: View {
    @Environment(HKReadinessStore.self) private var readiness
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The announced types still open, in table order. `nil` until asked.
    @State private var pending: [String]?
    @State private var isRequesting = false

    var body: some View {
        Group {
            // The connect banner owns a person who is not connected at all; its
            // sheet asks for these types too.
            if let pending, !pending.isEmpty, !(readiness.state.shouldShowBanner && !readiness.isConnected) {
                HealthKitNewReadTypesCardContent(
                    pending: pending,
                    isRequesting: isRequesting,
                    onContinue: {
                        Task {
                            isRequesting = true
                            await readiness.requestAnnouncedReadAuthorization()
                            isRequesting = false
                            await refresh()
                        }
                    },
                    onNotNow: {
                        Task {
                            await readiness.declineAnnouncedReadTypes()
                            await refresh()
                        }
                    }
                )
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: pending)
        .task(id: readiness.state) { await refresh() }
    }

    private func refresh() async {
        pending = await readiness.pendingAnnouncedReadTypes()
    }

    /// The explanation, naming exactly the types iOS will list, with the
    /// transparency page's names.
    static func body(for pending: [String]) -> String {
        let names = pending.map { HealthAccessTypeNaming.displayName(for: $0) }
        return String(localized: "healthkit.newTypes.body \(names.formatted(.list(type: .and)))")
    }

    static let continueButtonIdentifier = "healthkitNewTypes.continueButton"
    static let notNowButtonIdentifier = "healthkitNewTypes.notNowButton"
}

/// The card itself, without the store, so a test can render every state.
/// Same layout as `HealthKitUpdateNoticeCard`: icon, title, text, one text
/// button, and the ✕ as its own accessibility element.
struct HealthKitNewReadTypesCardContent: View {
    let pending: [String]
    var isRequesting = false
    let onContinue: () -> Void
    let onNotNow: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HLCard(style: .elevated) {
            // POLISH-B (SHOTS F-HKNEW-1) — beside the icon and the ✕ the text
            // shrank to a narrow column at the accessibility sizes and split
            // words ("Stehminu-ten"); there the icon and the ✕ share a row
            // above the text, which then takes the card's full width.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HStack(alignment: .top) {
                        icon
                        Spacer(minLength: 0)
                        notNowButton
                    }
                    textColumn
                }
            } else {
                HStack(alignment: .top, spacing: HLSpace.md) {
                    icon
                    textColumn
                    Spacer(minLength: 0)
                    notNowButton
                }
            }
        }
    }

    private var icon: some View {
        Image(systemName: "sparkles")
            .font(.hlIcon(HLIconSize.lg, weight: .bold))
            .foregroundStyle(.tint)
            .frame(width: 36, height: 36)
            .background(.tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
            .accessibilityHidden(true)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text("healthkit.newTypes.title")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(HealthKitNewReadTypesCard.body(for: pending))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            continueButton
                .padding(.top, HLSpace.xs)
        }
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            HStack(spacing: HLSpace.xs) {
                if isRequesting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Text("healthkit.newTypes.continue")
                    .font(.hlSubhead.weight(.semibold))
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .disabled(isRequesting)
        .accessibilityHint(Text("healthkit.newTypes.continue.hint"))
        .accessibilityIdentifier(HealthKitNewReadTypesCard.continueButtonIdentifier)
    }

    private var notNowButton: some View {
        Button(action: onNotNow) {
            Image(systemName: "xmark")
                .font(.hlIcon(HLIconSize.sm, weight: .semibold))
                .foregroundStyle(HLText.tertiary)
                .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("healthkit.newTypes.notNow"))
        .accessibilityIdentifier(HealthKitNewReadTypesCard.notNowButtonIdentifier)
    }
}
