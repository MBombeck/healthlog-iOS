import Foundation
import ModelsR4

/// **v0.14.2 (FW5-C) — server FHIR `$everything` fetcher (server B3).**
///
/// Pulls the server-canonical `GET /api/fhir/Patient/$everything` searchset
/// Bundle and flattens its pages into one combined Bundle. This is the **server
/// arm** of the FHIR-export-prefer-server selection (`FHIREverythingSource`):
/// when the user is paired + online we hand the doctor the server's canonical
/// FHIR, reducing the maintenance-parity drift between the iOS-local emitter and
/// the server.
///
/// **CU-13 (server v1.34.2) — the route moved.** `GET /api/fhir/$everything` is
/// gone and 404s; the operation now hangs off the Patient type as
/// `GET /api/fhir/Patient/$everything`. The move came with a semantic change
/// that matters more than the path: the Bundle is **scoped to the owner's saved
/// report selection**, so an account that never saved one gets an empty Bundle
/// with a perfectly healthy `200`. That is why ``fetchEverything()`` reports the
/// entry count instead of only the bytes — an empty Bundle is a state the caller
/// has to name to the user, not a silent zero-resource export.
///
/// **Contract (B3):**
/// - Bearer with `fhir:read` / `*` (the `APIClient` attaches the session token;
///   the server accepts a wildcard scope too). `Accept: application/fhir+json`.
/// - Paged via `_count` (default 50, hard-clamped ≤ 200) + `_offset`. The
///   `searchset` Bundle carries `total` (full unpaged count) and `self` / `next`
///   links. We follow `next` until it is absent, accumulating `entry[]`.
/// - 429 → a FHIR `OperationOutcome` (code `throttled`), which `APIClient` already
///   surfaces as ``HLError/rateLimited(retryAfter:)``. The caller treats any throw
///   as "fall back to the local emitter", so the rate-limit is behaviourally safe.
///
/// **Why combine pages into one Bundle?** The export artefact is a single file the
/// user shares with a doctor. We decode each page's `searchset` Bundle, concatenate
/// the entries, and re-emit one `searchset` Bundle carrying the server's `total`.
/// We never mutate resource content — only the envelope is rebuilt.
public actor ServerFHIREverythingService {
    /// The combined `$everything` Bundle as Sendable bytes, plus how many
    /// entries went into it.
    ///
    /// The count travels alongside the JSON because the caller runs on the
    /// MainActor and deliberately does not import `ModelsR4` (it would shadow
    /// the `Observation` framework the `@Observable` macro needs), so it cannot
    /// re-decode the envelope just to ask whether the server sent anything.
    public struct EverythingBundle: Sendable, Equatable {
        /// The JSON-encoded combined `searchset` Bundle.
        public let json: Data
        /// Total `entry` items accumulated across all pages.
        public let entryCount: Int

        public init(json: Data, entryCount: Int) {
            self.json = json
            self.entryCount = entryCount
        }

        /// The server served no resources at all. Since v1.34.2 the usual cause
        /// is an owner who has never saved a report selection — the scope the
        /// Bundle is restricted to — not an empty health record.
        public var isEmpty: Bool {
            entryCount == 0
        }
    }

    private let api: APIClientProtocol
    private let decoder: JSONDecoder

    /// Safety cap on page-follows so a pathological `next` cycle can't loop
    /// forever. 200 pages × 200/page = 40k resources — far beyond any real export.
    private static let maxPages = 200
    private static let pageCount = 200

    public init(api: APIClientProtocol, decoder: JSONDecoder = JSONDecoder()) {
        self.api = api
        self.decoder = decoder
    }

    /// Fetch the full `$everything` Bundle, following `next` links, and return
    /// the JSON-encoded combined `searchset` Bundle plus its entry count.
    /// Returns bytes (not the non-`Sendable` `ModelsR4.Bundle` class) so the
    /// result can cross the actor boundary back to the MainActor caller. Throws
    /// on any transport / decode / rate-limit failure so the caller can fall
    /// back to the local emitter.
    public func fetchEverything() async throws -> EverythingBundle {
        let combined = try await fetchEverythingBundle()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try EverythingBundle(
            json: encoder.encode(combined),
            entryCount: combined.entry?.count ?? 0
        )
    }

    /// Fetch + combine into one `searchset` Bundle. `private` — the Bundle class is
    /// non-`Sendable`, so it never crosses the actor boundary; callers (and tests)
    /// use ``fetchEverythingJSON()`` and decode the `Data` if they need the Bundle.
    private func fetchEverythingBundle() async throws -> ModelsR4.Bundle {
        var accumulatedEntries: [BundleEntry] = []
        var total: FHIRPrimitive<FHIRUnsignedInteger>?
        var nextQuery: [(String, String)]? = [("_count", String(Self.pageCount)), ("_offset", "0")]
        var pages = 0
        // Defensive offset-progress guard: a server `next` that repeats the
        // just-fetched `_offset` would otherwise re-fetch identical pages until
        // `maxPages`, accumulating duplicate entries. Break as soon as the next
        // page's offset fails to advance past the one we just requested.
        var lastOffset: Int?

        while let query = nextQuery, pages < Self.maxPages {
            pages += 1
            let page = try await fetchPage(query: query)
            if total == nil { total = page.total }
            accumulatedEntries.append(contentsOf: page.entry ?? [])
            let currentOffset = query.first { $0.0 == "_offset" }.flatMap { Int($0.1) }
            if let currentOffset, currentOffset == lastOffset { break }
            lastOffset = currentOffset
            nextQuery = Self.nextPageQuery(from: page)
        }

        // Re-emit one searchset Bundle carrying the server's `total` + all entries.
        let combined = ModelsR4.Bundle(type: BundleType.searchset.asPrimitive())
        combined.total = total
        combined.entry = accumulatedEntries.isEmpty ? nil : accumulatedEntries
        return combined
    }

    private func fetchPage(query: [(String, String)]) async throws -> ModelsR4.Bundle {
        let request = APIRequest<Data>(
            method: .get,
            // CU-13: type-level operation since server v1.34.2. The bare
            // `/api/fhir/$everything` is deleted and 404s.
            path: "/api/fhir/Patient/$everything",
            query: query,
            extraHeaders: ["Accept": "application/fhir+json"],
            // A 429 is a FHIR OperationOutcome, not the retriable envelope; we
            // don't want the in-request backoff loop hammering it — one shot, then
            // fall back to local at the call site.
            maxRetries: 0
        )
        let (data, _) = try await api.download(request)
        return try decoder.decode(ModelsR4.Bundle.self, from: data)
    }

    /// Extracts the `_count` / `_offset` query for the next page from a searchset
    /// Bundle's `next` link, or `nil` when there is no further page.
    ///
    /// `nonisolated static` — pure function of its `Bundle` input so the test can
    /// exercise the `next`-follow logic without standing up the actor or a session.
    nonisolated static func nextPageQuery(from bundle: ModelsR4.Bundle) -> [(String, String)]? {
        guard let links = bundle.link else { return nil }
        guard let next = links.first(where: { $0.relation.value?.string.lowercased() == "next" }),
              let urlString = next.url.value?.url.absoluteString else { return nil }
        // The `next` URL may be absolute or relative; we only need its query
        // params (`_count` / `_offset`) — the path stays the canonical
        // `Patient/$everything` route the request factory already targets.
        guard let comps = URLComponents(string: urlString),
              let items = comps.queryItems, !items.isEmpty else { return nil }
        let pairs: [(String, String)] = items.compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }
        return pairs.isEmpty ? nil : pairs
    }
}
