//
//  FHIRDecimal+SafeServer.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  Crash-/corruption-safe construction of a FHIR `Decimal` from a server- or
//  HealthKit-supplied `Double`. Mirrors `Int(safeServer:)` (Util/Int+SafeServer.swift)
//  for the FHIR-export path — the one place the existing finite-guard discipline
//  was not extended (AUD-4 M1).
//

import Foundation
import ModelsR4

public extension FHIRDecimal {
    /// Crash-/corruption-safe construction of a `FHIRDecimal` from a server-
    /// supplied `Double`.
    ///
    /// **Why this exists (AUD-4 M1):** measurement scalars decode unsanitised
    /// from the server / HealthKit. A `1e400` → `+inf`, a server divide-by-zero
    /// `NaN`, or a junk HK sample reaching `FHIRDecimal(floatLiteral:)` →
    /// `Decimal(floatLiteral:)` produces a **garbage/undefined Decimal** for a
    /// non-finite value (a corrupt `Quantity.value` silently written into the
    /// exported bundle), and a `NaN` Decimal **throws** `EncodingError.invalidValue`
    /// when the bundle is JSON-encoded → the whole FHIR export aborts
    /// mid-serialization.
    ///
    /// This factory returns `nil` instead, so the mapper can DROP the
    /// measurement from the bundle (return `nil` / skip the row) rather than
    /// emit garbage or abort — consistent with how `Int(safeServer:)` returns
    /// `nil` for an unrepresentable value.
    ///
    /// Contract (mirrors `Int(safeServer:)`):
    /// - non-finite (`NaN`, `+inf`, `-inf`) → `nil`
    /// - finite but outside the safe magnitude window (`> 1e15`) → `nil`
    ///   (FHIR R4 Quantity values are physiological magnitudes; a value beyond
    ///   1e15 is junk, not a real reading, and risks `Decimal` precision loss)
    /// - otherwise → the wrapped `Decimal`
    init?(safeServer value: Double) {
        guard value.isFinite else { return nil }
        // Physiological / lab values never exceed this magnitude; anything beyond
        // is corrupt input, not a real measurement. Keeps the Decimal in the
        // exact-representable band and rejects absurd server/HK junk.
        guard abs(value) <= 1e15 else { return nil }
        self.init(floatLiteral: value)
    }
}
