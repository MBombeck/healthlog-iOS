import Foundation
@testable import HealthLog
import Testing

/// APNs liefert den Token als 32-Byte \`Data\`. Server's Zod-Schema erwartet
/// Hex-Encoding (\`/^[A-Fa-f0-9]+$/\`). Wir senden konsistent lowercase damit
/// Logs nach Diff-Vergleichen nicht zwischen Cases wackeln.
@Suite("Data hexEncodedString")
struct HexEncodingTests {
    @Test("Empty data → empty string")
    func emptyData() {
        let hex = Data().hexEncodedString()
        #expect(hex == "")
    }

    @Test("Known bytes → known lowercase hex")
    func knownBytes() {
        let data = Data([0x00, 0x01, 0x0F, 0x10, 0xFF, 0xAB])
        #expect(data.hexEncodedString() == "00010f10ffab")
    }

    @Test("32-byte Token-Pattern → 64 char lowercase hex")
    func realisticTokenSize() {
        // Echte APNs-Tokens sind 32 Byte → 64 Char hex.
        let bytes = (0 ..< 32).map { UInt8($0) }
        let hex = Data(bytes).hexEncodedString()
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        // Erstes Byte 0x00 → "00", letztes 0x1F → "1f".
        #expect(hex.hasPrefix("00"))
        #expect(hex.hasSuffix("1f"))
    }

    @Test("Roundtrip: encode then decode preserves bytes")
    func roundtrip() {
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
        let hex = original.hexEncodedString()
        // Manueller Decode (kein Standard \`Data(hex:)\`).
        let pairs = stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start ..< end])
        }
        let decoded = Data(pairs.compactMap { UInt8($0, radix: 16) })
        #expect(decoded == original)
    }
}
