import Foundation
import Synchronization

// Audit B-4 (2026-09-10) — the tolerant half of the two measurement wire
// enums, `ServerMeasurementType` and `ServerMeasurementSource`.
//
// The server's `MeasurementType` enum grows: 76 members when the app last
// caught up, 77 today, and PR #109 spent three commits proving what a closed
// String enum costs on the read path. Every value the client had not yet heard
// of threw inside `MeasurementWireDTO`, `TolerantMeasurementWire` caught the
// throw and discarded the whole row, and the measurements were simply absent
// from lists and charts with nothing said. That happened to `COMPUTED`,
// `STRAVA`/`OURA`/`POLAR`/`NIGHTSCOUT`, `TELEGRAM`/`MCP` and `EXTERNAL` in
// turn — each one live on the server for releases before iOS noticed.
//
// So the enum stops being closed. An unrecognised raw value lands on
// `.unknown`, the row survives with its id, value, timestamp and source
// intact, and `MetricKind.unknown` renders it as a generic entry that no
// calculation, axis, export or health assessment reads. Naming the type
// remains a real piece of work — a typed case gives the row its unit, its
// range and its chart — but until someone does it the honest degradation is a
// row the user can see, not a row nobody knows was lost.

public extension ServerMeasurementType {
    /// Audit B-4 — decodes an unrecognised server token onto ``unknown``
    /// instead of throwing.
    ///
    /// This is the seam, not the list wrapper: a single-measurement decode
    /// (`POST` / `PATCH` response, `GET /api/measurements/{id}`) has no
    /// tolerant wrapper around it at all and used to fail whole as
    /// `HLError.decoding`. Both paths are covered here.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let known = ServerMeasurementType(rawValue: raw), known != .unknown else {
            UnknownMeasurementTypeLog.noteFirstSighting(of: raw)
            self = .unknown
            return
        }
        self = known
    }

    /// Audit B-4 — every value the SERVER can actually send: `allCases` minus
    /// the decode-only ``unknown`` sentinel. Anything enumerating the wire
    /// vocabulary (round-trip locks, the category fallback map, a set-difference
    /// against the Prisma enum) reads this, because `__UNKNOWN__` is not a
    /// server `MeasurementType` and never was.
    static var serverCases: [ServerMeasurementType] {
        allCases.filter { $0 != .unknown }
    }

    /// Audit B-4 — refuses to put ``unknown`` back on the wire.
    ///
    /// `__UNKNOWN__` is not a server `MeasurementType` and a client that sent
    /// it would be inventing one. No production path encodes a
    /// `MeasurementWireDTO` (it is a response shape; writes go through
    /// `MeasurementCreateDTO`), so this throw is a tripwire for a future
    /// caller, not a live branch.
    func encode(to encoder: Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "ServerMeasurementType.unknown is a decode-only sentinel and must never be sent."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension ServerMeasurementSource {
    /// Audit B-4 — decodes an unrecognised server source onto ``unknown``
    /// instead of throwing.
    ///
    /// `MeasurementWireDTO.source` is `decodeIfPresent`, which does NOT swallow
    /// a throw from the element decoder — an unknown literal threw mid-row and
    /// the tolerant list wrapper discarded the whole measurement. That is the
    /// failure this file exists for, and the one the source enum has hit most.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let known = ServerMeasurementSource(rawValue: raw), known != .unknown else {
            UnknownMeasurementTypeLog.noteFirstSighting(of: raw, kind: "source")
            self = .unknown
            return
        }
        self = known
    }

    /// Audit B-4 — every value the SERVER can actually send.
    static var serverCases: [ServerMeasurementSource] {
        allCases.filter { $0 != .unknown }
    }

    /// Audit B-4 — refuses to put ``unknown`` back on the wire. A create/update
    /// body naming `__UNKNOWN__` would be a source the app invented.
    func encode(to encoder: Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "ServerMeasurementSource.unknown is a decode-only sentinel and must never be sent."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Audit B-4 — logs each unrecognised measurement token **once per process**.
///
/// A 400-row page of one new type would otherwise write 400 identical
/// warnings. The token is a server enum name (`ACTIVITY_STEPS`-shaped) — never
/// a value, a note or an identifier — so it is operator-grade and logged
/// `.public`, exactly like the "Dropping … unsupported type" line it replaces
/// (`MeasurementDTO.swift`). That is the point of the log: an operator reading
/// a sysdiagnose has to be able to see WHICH type to name next, and a redacted
/// token cannot tell them.
enum UnknownMeasurementTypeLog {
    private static let seen = Mutex<Set<String>>([])

    static func noteFirstSighting(of raw: String, kind: StaticString = "type") {
        let isNew = seen.withLock { $0.insert("\(kind):\(raw)").inserted }
        guard isNew else { return }
        // The kind discriminator stays out of the message on purpose: the raw
        // token already says which vocabulary it came from.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.api.warning(
            "Unknown measurement wire value \(raw, privacy: .public) — row kept, nothing computed from it"
        )
    }
}
