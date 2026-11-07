import Foundation

/// MIRROR (1.5, #152, server #1272) — the server's own answer to "does the
/// app write this reading into Apple Health".
///
/// Since server 1.46.0 every stored measurement row carries `appleHealthMirror`
/// (`MeasurementResource` / `MeasurementRow` in `docs/api/openapi.yaml`): true for
/// WITHINGS, IMPORT and MANUAL, for an EXTERNAL row whatever the person chose for
/// the token that sent it, false otherwise. A server before 1.46.0 sends no key at
/// all, and neither does a synthesised list row.
///
/// The decode is by key presence, never by default value: a missing key is `nil`
/// and the app falls back to its own source rule
/// (`MeasurementSource.isServerMirrorEligible`). Decoding a missing key as `false`
/// would silently stop the Withings, imported and manual write-back against every
/// older server. A malformed value is `nil` too, never a lost row.
extension MeasurementWireDTO {
    private enum MirrorFlagKey: String, CodingKey {
        case appleHealthMirror
    }

    /// `appleHealthMirror` when the row carries the key as a boolean, else `nil`.
    static func decodeAppleHealthMirror(from decoder: Decoder) -> Bool? {
        guard let row = try? decoder.container(keyedBy: MirrorFlagKey.self),
              row.contains(.appleHealthMirror) else { return nil }
        // `try?` flattens `Bool??`: `null` or a non-boolean both land on `nil`.
        return try? row.decodeIfPresent(Bool.self, forKey: .appleHealthMirror)
    }

    /// The flag of a merged blood-pressure reading. Both halves come from the same
    /// writer, so they agree on a real server; if they ever do not, the stricter
    /// answer wins. One half without the key leaves the other half's answer.
    static func pairedAppleHealthMirror(_ sys: MeasurementWireDTO, _ dia: MeasurementWireDTO) -> Bool? {
        switch (sys.appleHealthMirror, dia.appleHealthMirror) {
        case let (sys?, dia?): sys && dia
        case let (sys?, nil): sys
        case let (nil, dia?): dia
        case (nil, nil): nil
        }
    }
}
