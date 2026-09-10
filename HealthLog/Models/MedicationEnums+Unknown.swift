import Foundation

// Audit B-4 (2026-09-10) — the tolerant halves of the two medication-family
// wire enums: `MedicationContainerType` and `ScheduleType`.
//
// MARK: - MedicationContainerType

//
// The container type is the one enum in the set whose cost was the PARENT, not the row.
// `MedicationInventoryListDTO.items` is a plain array with no lossy wrapper, so
// a container form the server adds after this build did not remove one pen from
// the shelf: it threw inside `decodeIfPresent` (which swallows a missing key,
// never a throw from the element decoder), failed the whole `GET .../inventory`
// response as `HLError.decoding`, and left an error where every one of the
// person's containers should have been.
//
// An unrecognised form now lands on `.unknown`. The container keeps its id, its
// state, its unit counts, its expiry dates and its pen detail — everything the
// supply screen actually renders — and the type contributes only a generic box
// glyph and an "Unknown" label. It also takes the conservative expiry arm: the
// first-use clock runs for PEN and AMPOULE, and a form nobody has read is not
// known to be either, so the printed date alone is the rule that gets stated.

public extension MedicationContainerType {
    /// Audit B-4 — decodes an unrecognised container form onto ``unknown``
    /// instead of throwing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let known = MedicationContainerType(rawValue: raw), known != .unknown else {
            UnknownServerEnumLog.noteFirstSighting(
                of: raw, vocabulary: "container type", consequence: "container kept, printed-date expiry rule stated"
            )
            self = .unknown
            return
        }
        self = known
    }

    /// Audit B-4 — refuses to put ``unknown`` back on the wire.
    ///
    /// `containerType` rides the inventory `POST` body, and the route validates
    /// it against `MEDICATION_CONTAINER_TYPE_VALUES`. The register sheet only
    /// ever offers ``serverCases``, so this throw is the tripwire behind that —
    /// and the reason a decoded row is never re-posted verbatim.
    func encode(to encoder: Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "MedicationContainerType.unknown is a decode-only sentinel and must never be sent."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - ScheduleType

// Audit B-4 — the tolerant half of `ScheduleType`, the cadence discriminator.
//
// This one never threw and never lost a row. What it did was answer `.scheduled`
// for a tag nobody had read, and `.scheduled` is a statement — "this is a
// calendar / rolling / legacy cadence" — where the truth was an absence. The
// sentinel replaces the claim; the dispatch is deliberately unchanged, because
// silencing a medication reminder is the one degradation that would be worse
// than the claim it replaces.

public extension ScheduleType {
    /// Audit B-4 — lenient decode: an unrecognised tag lands on ``unknown``
    /// instead of throwing OR of claiming ``scheduled``.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let known = ScheduleType(rawValue: raw), known != .unknown else {
            UnknownServerEnumLog.noteFirstSighting(
                of: raw, vocabulary: "schedule type", consequence: "row kept, dispatched on the fields it carries"
            )
            self = .unknown
            return
        }
        self = known
    }

    /// Audit B-4 — every tag the SERVER can actually send.
    static var serverCases: [ScheduleType] {
        [.scheduled, .prn, .cyclic]
    }

    /// Audit B-4 — refuses to put ``unknown`` back on the wire.
    ///
    /// A schedule write is composed from a local ``Cadence``, which can only
    /// produce a named tag, and `MedicationScheduleDTO.encode(to:)` drops the
    /// sentinel before it reaches here. This is the tripwire behind that guard.
    func encode(to encoder: Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "ScheduleType.unknown is a decode-only sentinel and must never be sent."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
