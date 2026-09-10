import Foundation

// Audit B-4 (2026-09-10) — the tolerant half of `NutrientCode`.
//
// The 26 cases matched the server catalogue exactly at the time of writing.
// That is a snapshot of one afternoon, not a contract: the catalogue is a
// server-side list that has grown before and will grow again. Until now a
// growth cost the row it named — `NutrientOverviewRowDTO` decoded `nutrient`
// with a plain `try c.decode`, the lossy list wrapper caught the throw, and the
// nutrient simply was not in the list, with no gap where it had been. The
// `/daily` shape had no wrapper at all and failed whole.
//
// An unrecognised code now lands on `.unknown` and the row survives with its
// unit, its amount and its day count. It also keeps the RAW server code, which
// is what lets it name itself: `.unknown` alone is a bucket that two different
// nutrients could share, so the raw string is both the row's label fallback and
// its list identity. What the row does NOT get is a reference band, a
// percent-of-target or a place in a total — this build knows the amount, not
// what the amount is of.

public extension NutrientCode {
    /// Audit B-4 — decodes an unrecognised catalogue code onto ``unknown``
    /// instead of throwing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(tolerant: raw)
    }

    /// Audit B-4 — resolves a raw catalogue string onto a case, noting the
    /// first sighting of anything unrecognised.
    ///
    /// Split out of ``init(from:)`` because the read DTOs decode the raw string
    /// themselves (they keep it for the label and the row id) and then resolve
    /// it through here.
    init(tolerant raw: String) {
        guard let known = NutrientCode(rawValue: raw), known != .unknown else {
            UnknownServerEnumLog.noteFirstSighting(
                of: raw, vocabulary: "nutrient code", consequence: "row kept, no reference or target derived from it"
            )
            self = .unknown
            return
        }
        self = known
    }

    /// Audit B-4 — every code the SERVER can actually send: `allCases` minus the
    /// decode-only ``unknown`` sentinel. The HealthKit catalogue map and the
    /// manual add surfaces read this, so the sentinel is never offered.
    static var serverCases: [NutrientCode] {
        allCases.filter { $0 != .unknown }
    }

    /// Audit B-4 — refuses to put ``unknown`` back on the wire. It rides the
    /// `POST /api/nutrients/batch` body and the `/daily` query string, and a
    /// client that sent `__UNKNOWN__` there would be inventing a catalogue
    /// member (the route validates against the server enum and answers 400).
    func encode(to encoder: Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "NutrientCode.unknown is a decode-only sentinel and must never be sent."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
