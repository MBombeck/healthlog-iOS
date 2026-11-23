// Optimistic placeholder builders, split out of `LabsStore.swift` (pure move,
// W-FILELEN) when #130 added the marker overview to the store. Same bodies, same
// transient-placeholder contract; only `private` became module-internal so the
// host file can still reach them across the file boundary.
import Foundation

extension LabsStore {
    /// Build an optimistic in-memory lab row for an offline-queued create
    /// (audit H-2). Mirrors `AllergiesStore.optimisticAllergy`: carries a
    /// temporary `optimistic-…` id so it never collides with a server id, and a
    /// NEUTRAL `.unknown` range verdict because the server has not resolved one
    /// yet (the store never invents a range). The next online `load()` replaces
    /// the whole snapshot with the server rows (under the same idempotency key),
    /// so the placeholder is transient.
    static func optimisticLab(from body: LabResultCreate) -> LabResultDTO {
        let now = ISO8601DateFormatter().string(from: Date.now)
        return LabResultDTO(
            id: "optimistic-\(UUID().uuidString)",
            biomarkerId: body.biomarkerId,
            panel: body.panel,
            analyte: body.analyte ?? "",
            value: body.value,
            // Carry the qualitative result into the optimistic row so
            // an offline-queued "negativ" doesn't show as an empty measurement
            // until the next online load.
            valueText: body.valueText,
            unit: body.unit ?? "",
            referenceLow: body.referenceLow,
            referenceHigh: body.referenceHigh,
            takenAt: body.takenAt,
            source: body.source ?? "MANUAL",
            hasNote: !(body.note ?? "").isEmpty,
            rangeStatus: .unknown,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Build an optimistic in-memory catalog row for an offline-queued biomarker
    /// create (audit H-2). Same transient-placeholder contract as
    /// ``optimisticLab(from:)``.
    static func optimisticBiomarker(from body: BiomarkerCreate) -> BiomarkerDTO {
        let now = ISO8601DateFormatter().string(from: Date.now)
        return BiomarkerDTO(
            id: "optimistic-\(UUID().uuidString)",
            name: body.name,
            unit: body.unit,
            lowerBound: body.lowerBound,
            upperBound: body.upperBound,
            panel: body.panel,
            hasContext: !(body.context ?? "").isEmpty,
            context: body.context,
            createdAt: now,
            updatedAt: now
        )
    }
}
