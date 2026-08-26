import Foundation

/// **v0.14.2 (FW5-C) — FHIR export source selection (server B3, A11 P3 dedup).**
///
/// The app has TWO FHIR emitters: the server-canonical
/// `GET /api/fhir/Patient/$everything` (CU-13 — the bare `/api/fhir/$everything`
/// was deleted in server v1.34.2) and the iOS-local
/// `DoctorReportToFHIRBundle`. To reduce the maintenance-parity
/// drift between them, the export path **prefers the server** when the user is
/// paired + online, and keeps the local emitter as the offline / standalone
/// fallback (it is never deleted — it is the offline path).
///
/// This enum names the resolved source so the screen, the report, and the test can
/// branch on a single value rather than re-deriving the decision inline.
public enum FHIRExportSource: String, Sendable, Equatable {
    /// Server-canonical `Patient/$everything` (paired + authenticated + online).
    case server
    /// iOS-local emitter (standalone, offline, unauthenticated, or a server-fetch
    /// failure that fell back).
    case local

    /// The pure selection rule. We prefer the server **iff** the backend is
    /// reachable right now — i.e. paired, authenticated, and online (exactly
    /// `BackendAvailability.isReachable`). Everything else uses the local emitter.
    ///
    /// Note this is the *intent*; an actual server fetch that throws (network
    /// hiccup, 429 throttle, decode) still falls back to ``local`` at the call
    /// site — this rule only decides which source to *try first*.
    public static func preferred(isBackendReachable: Bool) -> FHIRExportSource {
        isBackendReachable ? .server : .local
    }
}
