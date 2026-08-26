import Foundation

/// Wraps `GET /api/insights/narrative?period=week|month` (server v1.11.0 W3,
/// route at `src/app/api/insights/narrative/route.ts`).
///
/// **What it serves.** The "Zeitraum im Rückblick" period-retrospective prose
/// for the calling user — read-only stale-while-revalidate, served verbatim.
/// See ``NarrativeDTO`` for the full wire contract + the display-only posture.
///
/// **Cache strategy:** daily SWR per period+locale. The narrative is warmed at
/// most ~once per period server-side, so the read routes through the
/// Berlin-day-anchored `.insightsNarrative(period:locale:day:)` ladder
/// (cache-first on disk, single-flighted revalidation) — the retrospective card
/// paints cache-first on launch + the key flips to a structural miss on day
/// rollover.
///
/// **`nil` arms:** a `404` (route not deployed) or `422` (unknown period
/// rejected by the closed enum) maps to `nil` so the card hides gracefully — it
/// is never an error. A `200` body with `narrative: null` decodes normally and
/// the card renders its calm empty state.
public actor NarrativeRepository {
    private let api: APIClientProtocol
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Fetches the period narrative, or `nil` on a `404`/`422`. `locale` is the
    /// query override (`de`/`en`); the server still narrows from the session
    /// when omitted, but passing it keeps the cache key + prose locale aligned.
    public func fetch(period: NarrativeDTO.Period, locale: String) async throws -> NarrativeDTO? {
        let api = api
        let periodValue = period.rawValue
        @Sendable func networkFetch() async throws -> NarrativeDTO {
            let req: APIRequest<NarrativeDTO> = .get(
                "/api/insights/narrative",
                query: [("period", periodValue), ("locale", locale)]
            )
            return try await api.send(req)
        }
        do {
            if let swr {
                return try await swr.fetchCachingFirst(
                    .insightsNarrative(period: periodValue, locale: locale, day: BerlinDayKey.string()),
                    decoding: NarrativeDTO.self,
                    fetch: networkFetch
                )
            }
            return try await networkFetch()
        } catch let HLError.server(status, _, _) where status == 404 || status == 422 || status == 403 {
            // Route absent / unknown period rejected / assistant surface gated
            // off (403 `requireAssistantSurface` → `assistant.disabled.*`) →
            // hide the card with the calm empty state, never an error.
            // v0.14.3 B5: a provider-less account previously landed in the
            // card's error arm and showed nothing; a 403 now maps to nil.
            return nil
        } catch HLError.assistantDisabled {
            // The APIClient intercepts a 403 + `assistant.disabled.<surface>`
            // and re-throws it as `HLError.assistantDisabled(flag)` BEFORE the
            // `.server(403,…)` arm above can see it — so map that surfaced shape
            // to nil too (v0.14.3 B5). Provider-less ⇒ calm empty, not error.
            return nil
        } catch HLError.decoding {
            // v0.14.7 A2 defence-in-depth: a payload-shape drift (the
            // `provenance` String→object change that caused the recurring
            // "Rückblick konnte nicht geladen werden" error) must degrade to the
            // calm empty state, never the card's error arm. The DTO no longer
            // models `provenance` so this should not fire — but if the envelope
            // drifts again, hide gracefully rather than alarm the user.
            return nil
        }
    }
}
