import SwiftUI

// **1.5 COACH-R (server v1.41)** — the pieces under a server Coach answer: the
// quiet status line while it runs, a proposal to answer, and the trail behind
// the answer. Everything here renders text the store already screened
// (`CoachConversationStore+Reasoning.swift`); nothing is decided in a view.

/// One quiet line under the running answer. It replaces itself with every
/// `activity` frame and is gone when the answer is.
struct CoachLiveStatusLine: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .lineLimit(2)
            .padding(.horizontal, HLSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            .hlAnimation(.easeInOut(duration: 0.2), value: text)
            .accessibilityIdentifier("coach.live.status")
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// What sits under one finished server answer after its row: the proposal.
struct CoachAnswerExtras: View {
    let store: CoachConversationStore
    let entityID: UUID

    var body: some View {
        if let proposal = store.live.proposals[entityID] {
            CoachProposalView(
                proposal: proposal,
                isBusy: store.isResponding,
                answer: { accept in Task { await store.answerProposal(for: entityID, accept: accept) } }
            )
        }
    }
}

/// A fact or plan the Coach offers. Nothing happens until one of the two
/// buttons is tapped; a fact it saved on its own shows as one settled line.
struct CoachProposalView: View {
    let proposal: CoachLiveTrail.Proposal
    let isBusy: Bool
    let answer: (Bool) -> Void

    var body: some View {
        switch proposal.state {
        case .saved:
            if case let .memory(note) = proposal.kind {
                Label(String(localized: "coach.proposal.memory.saved \(note.fact)"), systemImage: "checkmark.circle")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.md)
            }
        case .answered:
            EmptyView()
        case .open, .sending:
            card
        }
    }

    private var isSending: Bool {
        if case .sending = proposal.state { return true }
        return false
    }

    /// An offer inside the transcript, so the outlined card: it belongs to
    /// the answer above it and does not stand as content of its own.
    private var card: some View {
        HLCard(style: .outline) {
            cardContent
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.proposal")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text(verbatim: CoachProposalCopy.heading(proposal.kind))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            ForEach(CoachProposalCopy.lines(proposal.kind), id: \.self) { line in
                Text(verbatim: line)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HLButtonPair {
                HLButton("coach.proposal.accept", isLoading: isSending) { answer(true) }
                    .accessibilityIdentifier("coach.proposal.accept")
            } secondary: {
                HLButton("coach.proposal.dismiss", variant: .secondary) { answer(false) }
                    .accessibilityIdentifier("coach.proposal.dismiss")
            }
            .disabled(isBusy || proposal.state != .open)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pure copy for ``CoachProposalView`` (tests pin both languages).
enum CoachProposalCopy {
    static func heading(_ kind: CoachLiveTrail.Proposal.Kind) -> String {
        switch kind {
        case .memory: String(localized: "coach.proposal.memory.title")
        case .plan: String(localized: "coach.proposal.plan.title")
        }
    }

    static func lines(_ kind: CoachLiveTrail.Proposal.Kind) -> [String] {
        switch kind {
        case let .memory(note):
            [note.fact]
        case let .plan(plan):
            [String(localized: "coach.proposal.plan.ifThen \(plan.ifCue) \(plan.thenAction)")]
                + (plan.target.map { [String(localized: "coach.proposal.plan.target \($0)")] } ?? [])
                + [String(localized: "coach.proposal.plan.review \(plan.reviewInDays)")]
        }
    }
}

/// The one disclosure in the row under an answer, „So kam die Antwort
/// zustande". It reads like the sources link beside it: the same font, weight
/// and ink, so the two are equals in one line.
struct CoachAnswerDisclosureToggle: View {
    @Binding var expanded: Bool
    /// Runs when the disclosure opens.
    let onExpand: () -> Void

    var body: some View {
        Button {
            withHLAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
            if expanded { onExpand() }
        } label: {
            HStack(spacing: HLSpace.xxs) {
                Text("coach.trail.link")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.hlCaption2)
                    .accessibilityHidden(true)
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .frame(minHeight: HLHitTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        // Pressed like every tappable surface; it keeps the sources link's
        // caption form beside it.
        .buttonStyle(.hlRow)
        .accessibilityIdentifier("coach.trail.link")
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
    }
}

/// What the disclosure opens: the evidence first, then the steps.
struct CoachAnswerDetails: View {
    let store: CoachConversationStore
    let entityID: UUID
    let provenance: CoachServerService.CoachProvenance?
    let showsTrail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            if let provenance {
                CoachProvenanceBody(provenance: provenance)
            }
            if showsTrail {
                CoachTrailSteps(store: store, entityID: entityID)
            }
        }
    }
}

/// The steps behind an answer. Fetched when the disclosure first opens, never
/// before.
struct CoachTrailSteps: View {
    let store: CoachConversationStore
    let entityID: UUID

    var body: some View {
        switch store.live.trails[entityID] {
        case .loading, nil:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("coach.trail.loading"))
        case .empty:
            Text("coach.trail.empty")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("coach.trail.failed")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                HLButton(HLControlWord.retry.key, variant: .secondary) {
                    Task { await store.loadTrail(for: entityID) }
                }
                .accessibilityIdentifier("coach.trail.retry")
            }
        case let .loaded(rows):
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.label)
                            .font(.hlFootnote)
                            .foregroundStyle(HLText.primary)
                        if let detail = row.detail {
                            Text(verbatim: detail)
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("coach.trail.list")
        }
    }
}
