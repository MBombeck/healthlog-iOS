import Foundation
import Observation

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// **1.5 COACH-R (server v1.41) — the live trail, the proposals and the trail
/// read of the server Coach.**
///
/// What the person sees, and the one rule every piece of it follows: model text
/// reaches the screen only after the app's own MDR filter has passed it.
///
/// - **Status line.** While a turn runs, the latest `activity` frame becomes one
///   quiet line under the answer. It shows the reasoning title when the filter
///   passes it, else the server's catalog label (never model text). It replaces
///   itself and is gone when the turn ends, however it ends.
/// - **Streamed answer.** Every token is checked against the text so far before
///   it is painted. Once the filter trips, painting stops on the last clean text
///   and the final verdict on the whole reply decides what settles.
/// - **Proposals.** A `memoryNote` / `planProposal` frame becomes a proposal
///   under the answer. Nothing happens until the person answers; the answer
///   rides on the next turn as `memoryDecision` / `planDecision`.
/// - **Trail.** Loaded only when the person taps "How this answer came about",
///   each title, summary and recalled fact screened before it is listed.
@MainActor
@Observable
public final class CoachLiveTrail {
    /// One proposal under an answer.
    public struct Proposal: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case memory(CoachServerService.CoachMemoryNote)
            case plan(CoachServerService.CoachPlanProposal)
        }

        public enum State: Equatable, Sendable {
            case open
            case sending(accept: Bool)
            case answered(accept: Bool)
            /// A fact the Coach saved without asking (not a health fact).
            case saved
        }

        public let kind: Kind
        public let messageID: String
        public var state: State
    }

    /// The trail of one answer, as far as it has loaded.
    public enum TrailState: Equatable, Sendable {
        case loading
        case loaded([TrailRow])
        case empty
        case failed
    }

    /// One row of the trail list: what the step was (catalog label), and the
    /// screened model text that goes with it, if any passed.
    public struct TrailRow: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let detail: String?
    }

    /// The status line of the running turn, `nil` when no turn runs.
    public internal(set) var statusLine: String?
    /// Bumped when an answer has settled with what it brought (a proposal, a
    /// trail link). The transcript scrolls them into view above the keyboard.
    public internal(set) var settledRevision = 0
    public internal(set) var proposals: [UUID: Proposal] = [:]
    public internal(set) var trails: [UUID: TrailState] = [:]

    /// The live entries of the running turn, upserted by id.
    var running: [CoachServerService.CoachActivity] = []
    /// The catalog labels of each finished answer's trail, by entity. An answer
    /// shows the trail link only when it has some.
    var labelsByEntity: [UUID: [String: String]] = [:]
    /// The answer the next server turn carries, set by ``CoachConversationStore/answerProposal(for:accept:)``.
    var pendingDecision: CoachServerService.TurnDecision?
    private var turnIsRunning = false

    public init() {}

    /// `true` when the answer came with a trail the server can serve.
    public func hasTrail(_ entityID: UUID) -> Bool {
        !(labelsByEntity[entityID]?.isEmpty ?? true)
    }

    func beginTurn() {
        running = []
        statusLine = nil
        turnIsRunning = true
    }

    func endTurn() {
        turnIsRunning = false
        statusLine = nil
    }

    func clear() {
        endTurn()
        running = []
        proposals = [:]
        trails = [:]
        labelsByEntity = [:]
        pendingDecision = nil
    }

    /// Fold one `activity` frame in and repaint the status line.
    func apply(
        _ activity: CoachServerService.CoachActivity,
        filter: MDRSafetyFilter,
        defaults: UserDefaults = .standard
    ) async {
        if let index = running.firstIndex(where: { $0.id == activity.id }) {
            running[index] = activity
        } else {
            running.append(activity)
        }
        // POLISH-B B9 — past the Coach's reach: its own sentence, not "nothing here".
        var line = activity.label
        if let reach = CoachReachReason.sentence(for: activity.reason, defaults: defaults) {
            line = reach
        } else if let title = await Self.screened(activity.title, filter: filter) {
            line = title
        }
        // The turn may have ended while the filter ran.
        guard turnIsRunning else { return }
        statusLine = line.isEmpty ? nil : line
    }

    /// Text that may be shown, or `nil` when there is none or the filter trips.
    nonisolated static func screened(_ text: String?, filter: MDRSafetyFilter) async -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return await filter.containsForbiddenPattern(in: trimmed) ? nil : trimmed
    }

    /// A plan is offered only when every piece of its wording passes.
    nonisolated static func planIsClean(_ plan: CoachServerService.CoachPlanProposal, filter: MDRSafetyFilter) async -> Bool {
        for part in [plan.ifCue, plan.thenAction] + (plan.target.map { [$0] } ?? []) {
            guard await screened(part, filter: filter) != nil else { return false }
        }
        return true
    }

    /// Stash what the settled answer brought: its proposal and its trail labels.
    func settle(_ reply: CoachServerService.Reply, entityID: UUID, filter: MDRSafetyFilter) async {
        if !running.isEmpty {
            labelsByEntity[entityID] = Dictionary(running.map { ($0.id, $0.label) }, uniquingKeysWith: { _, last in last })
        }
        running = []
        defer { settledRevision &+= 1 }
        guard let messageID = reply.messageId else { return }
        if let plan = reply.planProposal, await Self.planIsClean(plan, filter: filter) {
            proposals[entityID] = Proposal(kind: .plan(plan), messageID: messageID, state: .open)
        } else if let note = reply.memoryNote, await Self.screened(note.fact, filter: filter) != nil {
            let isProposal = note.proposal && note.proposalId != nil
            proposals[entityID] = Proposal(kind: .memory(note), messageID: messageID, state: isProposal ? .open : .saved)
        }
    }
}

public extension CoachConversationStore {
    /// One server turn with the 1.5 additions: the pending decision goes out,
    /// tokens paint only while the filter passes them, and `activity` frames
    /// drive the status line. The status line is cleared on every way out.
    internal func respondOnServer(
        _ server: CoachServerService,
        userText: String,
        conversationID: String?,
        scope: CoachScopeWire?,
        render: ServerStreamRender
    ) async throws -> CoachServerService.Reply {
        let live = live
        let filter = safetyFilter
        let decision = live.pendingDecision
        live.pendingDecision = nil
        live.beginTurn()
        defer { live.endTurn() }
        return try await server.respond(
            message: userText,
            conversationId: conversationID,
            locale: serverLocaleCode(),
            scope: scope,
            decision: decision,
            onToken: { [weak self] token in
                guard let self, !Task.isCancelled, !render.isHeld else { return }
                render.append(token)
                // Nothing the filter would refuse is ever painted: the bubble
                // stays on the last clean text, and the final verdict decides.
                if await filter.containsForbiddenPattern(in: render.text) {
                    render.hold()
                    return
                }
                if Task.isCancelled { return }
                upsertStreamingAssistant(render.text, isFirstPartial: render.isFirstPartial)
                render.markAppended()
            },
            onActivity: { activity in
                if Task.isCancelled { return }
                await live.apply(activity, filter: filter)
            }
        )
    }

    /// A turn that broke off mid-stream (network gone, app sent away, a stall)
    /// leaves no half answer standing: the partial bubble goes, the person's
    /// own turn stays, and the error line offers the way on.
    internal func dropPartialAnswer(_ render: ServerStreamRender) {
        guard render.didAppend else { return }
        #if canImport(SpeziChat)
            if chat.last?.role == .assistant { chat.removeLast() }
        #else
            if chat.last?.hasPrefix("assistant: ") == true { chat.removeLast() }
        #endif
    }

    /// Answer a proposal under an answer. The label goes out as the person's
    /// message (web parity), the decision beside it; the server replies with a
    /// catalog line. A turn that fails leaves the proposal open to try again.
    func answerProposal(for entityID: UUID, accept: Bool) async {
        guard var proposal = live.proposals[entityID], proposal.state == .open, !isResponding else { return }
        let decision: CoachServerService.TurnDecision
        let label: String
        switch proposal.kind {
        case let .memory(note):
            guard let proposalID = note.proposalId else { return }
            decision = .memory(.init(messageId: proposal.messageID, proposalId: proposalID, accept: accept))
            label = String(localized: accept ? "coach.proposal.memory.accept" : "coach.proposal.memory.decline")
        case let .plan(plan):
            decision = .plan(.init(messageId: proposal.messageID, planId: plan.planId, accept: accept))
            label = String(localized: accept ? "coach.proposal.plan.accept" : "coach.proposal.plan.decline")
        }
        proposal.state = .sending(accept: accept)
        live.proposals[entityID] = proposal
        live.pendingDecision = decision
        await send(label)
        // Not consumed (another arm took the turn, or it never started).
        live.pendingDecision = nil
        proposal.state = lastError == nil ? .answered(accept: accept) : .open
        live.proposals[entityID] = proposal
    }

    /// Load the trail of one answer. Only ever called from the tap.
    func loadTrail(for entityID: UUID) async {
        guard let serverService, let conversationID = serverConversationID,
              let messageID = feedback.messageID(forEntity: entityID) else
        {
            live.trails[entityID] = .empty
            return
        }
        if case .loading? = live.trails[entityID] { return }
        live.trails[entityID] = .loading
        let labels = live.labelsByEntity[entityID] ?? [:]
        do {
            let trail = try await serverService.trail(conversationID: conversationID, messageID: messageID)
            let rows = await Self.trailRows(trail, labels: labels, filter: safetyFilter)
            live.trails[entityID] = rows.isEmpty ? .empty : .loaded(rows)
        } catch {
            HLLog.api.error("Coach trail failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)")
            live.trails[entityID] = .failed
        }
    }

    /// The trail as rows: each entry under its catalog label, with the title
    /// and summary that pass the filter; recalled facts after them.
    nonisolated static func trailRows(
        _ trail: CoachServerService.CoachTrail?,
        labels: [String: String],
        filter: MDRSafetyFilter,
        serverSendsReach: Bool = CoachReachReason.serverSendsReach()
    ) async -> [CoachLiveTrail.TrailRow] {
        guard let trail else { return [] }
        var rows: [CoachLiveTrail.TrailRow] = []
        for entry in trail.entries {
            let title = await CoachLiveTrail.screened(entry.title, filter: filter)
            let text = await CoachLiveTrail.screened(entry.text, filter: filter)
            // The catalog label heads the row; without one the title does.
            let catalog = labels[entry.id]
            guard let label = catalog ?? title else { continue }
            let reach = CoachReachReason.sentence(for: entry.reason, serverSendsReach: serverSendsReach)
            let detail = ((catalog == nil ? [text] : [title, text]) + [reach]).compactMap(\.self).joined(separator: "\n")
            rows.append(.init(id: entry.id, label: label, detail: detail.isEmpty ? nil : detail))
        }
        for (index, fact) in trail.recalled.enumerated() {
            guard let screened = await CoachLiveTrail.screened(fact, filter: filter) else { continue }
            rows.append(.init(id: "recalled-\(index)", label: String(localized: "coach.trail.recalled"), detail: screened))
        }
        return rows
    }
}
