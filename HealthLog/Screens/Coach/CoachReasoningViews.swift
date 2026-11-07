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

/// What sits under one finished server answer: its proposal, then the trail link.
struct CoachAnswerExtras: View {
    let store: CoachConversationStore
    let entityID: UUID

    var body: some View {
        let proposal = store.live.proposals[entityID]
        let hasTrail = store.live.hasTrail(entityID)
        if proposal != nil || hasTrail {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if let proposal {
                    CoachProposalView(
                        proposal: proposal,
                        isBusy: store.isResponding,
                        answer: { accept in Task { await store.answerProposal(for: entityID, accept: accept) } }
                    )
                }
                if hasTrail {
                    CoachTrailDisclosure(store: store, entityID: entityID)
                }
            }
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

    private var card: some View {
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
            HStack(spacing: HLSpace.sm) {
                HLButton("coach.proposal.accept", variant: .primary, size: .compact) { answer(true) }
                    .accessibilityIdentifier("coach.proposal.accept")
                HLButton("coach.proposal.dismiss", variant: .secondary, size: .compact) { answer(false) }
                    .accessibilityIdentifier("coach.proposal.dismiss")
                if case .sending = proposal.state {
                    ProgressView()
                }
            }
            .disabled(isBusy || proposal.state != .open)
        }
        .padding(HLSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.proposal")
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

/// The centred text link „So kam die Antwort zustande" and, once tapped, the
/// steps as a list. The trail is fetched on the first tap, never before.
struct CoachTrailDisclosure: View {
    let store: CoachConversationStore
    let entityID: UUID
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Button {
                withHLAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                if expanded, store.live.trails[entityID] == nil || store.live.trails[entityID] == .failed {
                    Task { await store.loadTrail(for: entityID) }
                }
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Text("coach.trail.link")
                        .font(.hlSubhead.weight(.semibold))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.hlIcon(HLIconSize.sm))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(HLText.secondary)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("coach.trail.link")
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded {
                content
                    .padding(.horizontal, HLSpace.md)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
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
                HLButton("Try again", variant: .secondary, size: .compact) {
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
