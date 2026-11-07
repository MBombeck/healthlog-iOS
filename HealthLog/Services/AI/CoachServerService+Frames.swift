import Foundation

/// **1.5 COACH-R (server v1.41)** — what the Coach stream added for its live
/// trail and its proposals, and the trail read.
///
/// The frames: `activity` (one entry of the live trail, upserted by `id`),
/// `memoryNote` (a fact the Coach saved or proposes) and `planProposal` (an
/// if-then plan it proposes). All three are optional on the wire: a server
/// older than v1.41 sends none of them and the turn reads exactly as before.
/// A malformed payload decodes to `nil` (``LenientFrameValue``) and never costs
/// the rest of the frame or the turn.
///
/// Model text in here (`title`, `text`, the facts, the plan wording) is screened
/// on the server and screened again in the app before it is shown
/// (`CoachConversationStore+Reasoning.swift`).
public extension CoachServerService {
    /// One entry of the live trail. `label` comes from the server's closed
    /// catalog in the request language and is never model text; `title` and
    /// `text` are model text.
    struct CoachActivity: Sendable, Equatable, Decodable, Identifiable {
        public let id: String
        public let phase: String?
        public let status: String
        public let label: String
        public let title: String?
        public let text: String?
        /// POLISH-B B9 (v1.47.1): `outside_reach` on a settled fetch whose
        /// readings all lie past the Coach's lookback limit. Unknown, absent
        /// or malformed reads as `nil`.
        public let reason: String?

        public init(
            id: String,
            phase: String? = nil,
            status: String,
            label: String,
            title: String? = nil,
            text: String? = nil,
            reason: String? = nil
        ) {
            self.id = id
            self.phase = phase
            self.status = status
            self.label = label
            self.title = title
            self.text = text
            self.reason = reason
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            phase = try container.decodeIfPresent(String.self, forKey: .phase)
            status = try container.decode(String.self, forKey: .status)
            label = try container.decode(String.self, forKey: .label)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        }

        private enum CodingKeys: String, CodingKey {
            case id, phase, status, label, title, text, reason
        }
    }

    /// A fact the Coach saved (`proposal == false`) or asks to save
    /// (`proposal == true`, answered with `memoryDecision`).
    struct CoachMemoryNote: Sendable, Equatable, Decodable {
        public let proposal: Bool
        public let proposalId: String?
        public let category: String
        public let fact: String

        public init(proposal: Bool, proposalId: String?, category: String, fact: String) {
            self.proposal = proposal
            self.proposalId = proposalId
            self.category = category
            self.fact = fact
        }
    }

    /// An if-then plan the Coach proposes, answered with `planDecision`.
    struct CoachPlanProposal: Sendable, Equatable, Decodable {
        public let planId: String
        public let reviewInDays: Int
        public let ifCue: String
        public let thenAction: String
        public let target: String?

        public init(planId: String, reviewInDays: Int, ifCue: String, thenAction: String, target: String? = nil) {
            self.planId = planId
            self.reviewInDays = reviewInDays
            self.ifCue = ifCue
            self.thenAction = thenAction
            self.target = target
        }
    }

    /// The person's answer to a proposal. It rides on the next chat turn; the
    /// server answers it with a catalog line and no model call.
    enum TurnDecision: Sendable, Equatable {
        case memory(MemoryAnswer)
        case plan(PlanAnswer)
    }

    struct MemoryAnswer: Sendable, Equatable, Encodable {
        public let messageId: String
        public let proposalId: String
        public let accept: Bool
    }

    struct PlanAnswer: Sendable, Equatable, Encodable {
        public let messageId: String
        public let planId: String
        public let accept: Bool
    }

    /// The text of one answer's trail (`GET …/messages/{id}/trail`).
    struct CoachTrail: Sendable, Equatable, Decodable {
        public struct Entry: Sendable, Equatable, Decodable, Identifiable {
            public let id: String
            public let title: String?
            public let text: String?
            /// POLISH-B B9 (v1.47.1): mirrors ``CoachActivity/reason``.
            public let reason: String?

            public init(id: String, title: String? = nil, text: String? = nil, reason: String? = nil) {
                self.id = id
                self.title = title
                self.text = text
                self.reason = reason
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                title = try container.decodeIfPresent(String.self, forKey: .title)
                text = try container.decodeIfPresent(String.self, forKey: .text)
                reason = try? container.decodeIfPresent(String.self, forKey: .reason)
            }

            private enum CodingKeys: String, CodingKey {
                case id, title, text, reason
            }
        }

        public let entries: [Entry]
        public let recalled: [String]

        public init(entries: [Entry], recalled: [String] = []) {
            self.entries = entries
            self.recalled = recalled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = (try? container.decodeIfPresent([Entry].self, forKey: .entries)) ?? []
            recalled = (try? container.decodeIfPresent([String].self, forKey: .recalled)) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case entries
            case recalled
        }
    }

    /// Loads one answer's trail. `nil` when the message has none or nothing in
    /// it may be served. Called only when the person opens the trail.
    func trail(conversationID: String, messageID: String) async throws -> CoachTrail? {
        guard Self.isPathSafe(conversationID), Self.isPathSafe(messageID) else {
            throw CoachServerError.decode("unsafe trail id")
        }
        let request: APIRequest<CoachTrailPayload> = .get(
            "/api/insights/chat/\(conversationID)/messages/\(messageID)/trail"
        )
        return try await api.send(request).trail
    }

    /// Server ids are cuid-style tokens; anything else never reaches a path.
    internal nonisolated static func isPathSafe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// The unwrapped `data` of the trail read. `trail` is `null` when there is none.
struct CoachTrailPayload: Decodable, Sendable {
    let trail: CoachServerService.CoachTrail?
}

/// Decodes a frame's payload without ever throwing: a malformed object reads
/// as `nil`, so one bad field never drops the frame it rides on.
struct LenientFrameValue<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// **POLISH-B B9 (1.5, server v1.47.1, COACH-R point 6).** A read whose
/// readings all lie past the lookback limit set for the Coach carries
/// `reason: "outside_reach"` on its activity and trail entry. Until v1.47.0
/// the server reported it as an empty window, so the app could not tell the
/// two apart. Where the reason arrives the status line and the trail say so
/// in their own quiet sentence; without it the wording stays as it was.
public enum CoachReachReason {
    public static let outsideReach = "outside_reach"
    public static let minimumServerVersion = "1.47.1"

    /// A server known to be v1.47.1 or newer (unknown means no).
    public static func serverSendsReach(defaults: UserDefaults = .standard) -> Bool {
        KnownServerVersion.isAtLeast(minimumServerVersion, defaults: defaults)
    }

    /// The sentence for `reason`, or `nil` for any other reason, no reason,
    /// or a server not known to be v1.47.1 or newer.
    public static func sentence(for reason: String?, serverSendsReach: Bool) -> String? {
        guard reason == outsideReach, serverSendsReach else { return nil }
        return String(localized: "coach.reach.outsideReach")
    }

    public static func sentence(for reason: String?, defaults: UserDefaults = .standard) -> String? {
        sentence(for: reason, serverSendsReach: serverSendsReach(defaults: defaults))
    }
}
