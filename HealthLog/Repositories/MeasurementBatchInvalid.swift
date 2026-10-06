import Foundation

// E1 — `measurement.batch.invalid` (server v1.39.1).
//
// Up to v1.39.0 `POST /api/measurements/batch` answered a body that failed its
// schema with a 422 and no code. The app could not tell that from any other
// 4xx, so it held the anchor (heart events: five sweeps, then the register) or
// parked the queued page and sent the same batch again on every pass.
//
// v1.39.1 names the refusal (`meta.errorCode: "measurement.batch.invalid"`) and
// documents it as final "for the batch as sent" — and it lists every issue under
// `details.issues`, each with the dotted Zod `path` of the field it is about
// (`entries.3.value`, `src/lib/api-response.ts::sanitiseZodIssues`). That makes
// the refusal splittable: the entries the issues name are refused, every other
// entry of the batch is fine and can be sent again on its own.
//
// Only an issue path of the form `entries.<n>…` names an entry. An issue about
// the envelope (`syncTrigger`, an empty `entries`) refuses the batch as a whole;
// then no entry is named and the whole batch is the refusal (sending halves of
// it would meet the same envelope issue again).

/// A whole-batch schema refusal of `POST /api/measurements/batch`, with the
/// entries the server named. Thrown by `APIClient` for exactly that route and
/// that code; every other refusal keeps arriving as `HLError.server`.
struct MeasurementBatchInvalid: Error, Sendable, Equatable {
    static let code = "measurement.batch.invalid"
    static let routeSuffix = "/api/measurements/batch"

    let status: Int
    /// Indexes into the posted `entries` the issues name, ascending and unique;
    /// `nil` when any issue is about the envelope rather than an entry, or when
    /// the body names no issue at all.
    let entryIndexes: [Int]?

    /// The skip-register reason of a row this refusal names: `<status>:<code>`,
    /// the shape every named refusal in the register already has.
    var reason: String {
        "\(status):\(Self.code)"
    }

    /// The typed refusal for this response, or `nil` when it is not one.
    static func from(path: String, status: Int, code: String?, body: Data) -> Self? {
        guard path.hasSuffix(routeSuffix), code == Self.code else { return nil }
        let issues = (try? JSONDecoder().decode(Body.self, from: body))?.details?.issues ?? []
        return Self(status: status, entryIndexes: entryIndexes(of: issues.map { $0.path ?? "" }))
    }

    /// `entries.<n>[.<field>…]` → `n`. Any other path (or none) → `nil` overall.
    static func entryIndexes(of paths: [String]) -> [Int]? {
        guard !paths.isEmpty else { return nil }
        var indexes = Set<Int>()
        for path in paths {
            let parts = path.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0] == "entries", let index = Int(parts[1]), index >= 0 else { return nil }
            indexes.insert(index)
        }
        return indexes.sorted()
    }

    private struct Body: Decodable {
        struct Details: Decodable {
            let issues: [Issue]?
        }

        /// `path` as the server sends it (`"entries.3.value"`), or as a Zod
        /// segment array (`["entries", 3, "value"]`) joined the same way. An
        /// unreadable path reads as none, which names no entry.
        struct Issue: Decodable {
            let path: String?

            private enum CodingKeys: String, CodingKey { case path }

            private enum Segment: Decodable {
                case text(String)
                case index(Int)

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let index = try? container.decode(Int.self) {
                        self = .index(index)
                    } else {
                        self = try .text(container.decode(String.self))
                    }
                }

                var text: String {
                    switch self {
                    case let .text(value): value
                    case let .index(value): String(value)
                    }
                }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let dotted = try? container.decode(String.self, forKey: .path) {
                    path = dotted
                } else if let segments = try? container.decode([Segment].self, forKey: .path) {
                    path = segments.map(\.text).joined(separator: ".")
                } else {
                    path = nil
                }
            }
        }

        let details: Details?
    }
}

// MARK: - Splitting a refused batch

extension MeasurementBatchInvalid {
    /// What one refused batch leaves once the named entries are set aside.
    ///
    /// The named entries go into the owner's skip register first — visible in
    /// Sync Diagnostics, offered again per build — and only then is the rest
    /// sent, ONCE, through `send` (the caller's own wire path, rate limit and
    /// lease). The answer for the rest and the refusals are folded back into one
    /// response indexed like the original batch: every named entry `skipped`
    /// with ``reason``. The rest's response has already passed the acceptance
    /// gate; the refused indexes are terminal because they are in the register.
    ///
    /// Throws `self` — the whole batch stays a refusal for the caller's existing
    /// path — when nothing is named, an index is out of range, there is no
    /// owner to register under, or the register write does not verify. A
    /// failure of the second request is thrown as is; the named rows are already
    /// registered, and a resend (the caller's durable retry) splits again.
    func split(
        _ entries: [HealthKitBatchEntryDTO],
        ownerID: String?,
        send: @Sendable ([HealthKitBatchEntryDTO]) async throws -> HealthKitBatchResponseDTO
    ) async throws -> HealthKitBatchResponseDTO {
        guard let named = entryIndexes, !named.isEmpty, named.allSatisfy(entries.indices.contains),
              let ownerID else { throw self }
        let refused = Set(named)
        do {
            try await HealthKitSkippedRowRegister.current.record(
                named.map { HealthKitSkippedEntry(entry: entries[$0], reason: reason) },
                ownerID: ownerID,
                build: HealthKitSkipRegisterBuild.current
            )
        } catch {
            throw self
        }
        let total = entries.count
        // Counts only — no identifier, no value.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.info("HK batch invalid — \(named.count, privacy: .public)/\(total, privacy: .public) registered")

        let kept = entries.indices.filter { !refused.contains($0) }
        let restResponse: HealthKitBatchResponseDTO? = kept.isEmpty ? nil : try await send(kept.map { entries[$0] })
        if let restResponse {
            try MeasurementBatchAcceptance.validate(
                postedCount: kept.count,
                postedExternalIds: kept.map { entries[$0].externalId },
                response: restResponse,
                policy: .deployedMeasurementRoute
            )
        }
        return Self.merge(restResponse, keptIndexes: kept, refused: named, reason: reason)
    }

    /// The rest's response re-indexed onto the original batch, plus one
    /// `skipped` verdict per refused index.
    static func merge(
        _ rest: HealthKitBatchResponseDTO?,
        keptIndexes kept: [Int],
        refused: [Int],
        reason: String
    ) -> HealthKitBatchResponseDTO {
        func original(_ index: Int) -> Int? {
            kept.indices.contains(index) ? kept[index] : nil
        }
        let restEntries = (rest?.entries ?? []).compactMap { entry in
            original(entry.index).map {
                HealthKitBatchResponseDTO.EntryResult(index: $0, status: entry.status, reason: entry.reason)
            }
        }
        let restSkipped = (rest?.skipped ?? []).compactMap { skipped in
            original(skipped.index).map { HealthKitBatchResponseDTO.SkippedEntry(index: $0, reason: skipped.reason) }
        }
        let refusedSkipped = refused.map { HealthKitBatchResponseDTO.SkippedEntry(index: $0, reason: reason) }
        let refusedEntries = refused.map {
            HealthKitBatchResponseDTO.EntryResult(index: $0, status: .skipped, reason: reason)
        }
        return HealthKitBatchResponseDTO(
            processed: (rest?.processed ?? 0) + refused.count,
            inserted: rest?.inserted ?? 0,
            duplicates: rest?.duplicates ?? 0,
            skipped: restSkipped + refusedSkipped,
            entries: (restEntries + refusedEntries).sorted { $0.index < $1.index }
        )
    }
}
