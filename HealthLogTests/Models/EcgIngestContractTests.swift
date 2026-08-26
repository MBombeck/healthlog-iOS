import Foundation
@testable import HealthLog
import Testing

// MARK: - The conversion

/// **Die gefährlichste Zeile der Einheit, einzeln festgenagelt.**
///
/// HealthKit liefert Volt, die Route will ganzzahlige Mikrovolt — dieselbe
/// Einheit, die der Archiv-Parser des Servers erzeugt, damit beide Türen
/// dieselben Zahlen ergeben.
@Suite("EcgSampleScale — Volt zu ganzzahligen Mikrovolt")
struct EcgSampleScaleTests {
    @Test(
        "Bekannte Werte",
        arguments: [
            (0.0, 0),
            (0.001, 1000), //  1 mV  — die klassische EKG-Kalibrierzacke
            (-0.001, -1000),
            (0.000012, 12), // die drei Beispielwerte aus dem Server-Vertrag
            (-0.000007, -7),
            (0.000003, 3),
            (0.0015, 1500), // ~R-Zacken-Höhe
            (0.000_000_5, 1), // halber Mikrovolt: von der Null weg gerundet
            (-0.000_000_5, -1), // …und zwar symmetrisch
            (0.000_000_4, 0),
            (0.005, 5000) // physiologische Obergrenze eines Oberflächen-EKGs
        ]
    )
    func knownValues(volts: Double, microvolts: Int) {
        #expect(EcgSampleScale.microvolts(fromVolts: volts) == microvolts)
    }

    @Test("Der Faktor ist eine Million, nicht ein Tausend")
    func scaleFactorIsMicro() {
        #expect(EcgSampleScale.microvoltsPerVolt == 1_000_000)
        // Ein Millivolt sind tausend Mikrovolt. Ein Faktor 1000 statt 1e6
        // ergäbe hier 1 — und ein EKG, dessen Amplituden um drei
        // Zehnerpotenzen daneben liegen, sieht auf einer Kurve immer noch
        // plausibel aus. Genau deshalb steht dieser Test hier.
        #expect(EcgSampleScale.microvolts(fromVolts: 0.001) == 1000)
    }

    @Test("Nicht darstellbare Werte ergeben nil statt einer erfundenen Null")
    func nonFiniteYieldsNil() {
        #expect(EcgSampleScale.microvolts(fromVolts: .nan) == nil)
        #expect(EcgSampleScale.microvolts(fromVolts: .infinity) == nil)
        #expect(EcgSampleScale.microvolts(fromVolts: -.infinity) == nil)
        #expect(EcgSampleScale.microvolts(fromVolts: .greatestFiniteMagnitude) == nil)
    }

    @Test("Eine Kurve mit einem unlesbaren Wert ergibt keine Teilkurve")
    func arrayIsAllOrNothing() {
        #expect(EcgSampleScale.microvolts(fromVolts: [0.001, 0.002]) == [1000, 2000])
        #expect(EcgSampleScale.microvolts(fromVolts: [0.001, .nan, 0.002]) == nil)
        #expect(EcgSampleScale.microvolts(fromVolts: []) == [])
    }
}

// MARK: - The enum that must not be shared

/// **GH #75 — die Drift, vor der das Server-Team ausdrücklich gewarnt hat.**
///
/// Die Datenbank-Aufzählung `RhythmClassification` hat sechs Mitglieder, weil
/// Gehstetigkeits- und neutrale Ereignis-Urteile dieselbe Spalte teilen. Auf
/// einer EKG-Zeile können nur drei davon stehen; die anderen drei erscheinen
/// auf `GET /api/insights/rhythm-events`. Eine gemeinsame Aufzählung an beiden
/// Stellen ist genau der Fehler, der hier verhindert wird.
@Suite("EcgIngestClassification — drei Werte, getrennt von der Lesefläche")
struct EcgIngestClassificationTests {
    @Test("Genau drei Schreibwerte, und zwar die drei kardialen")
    func exactlyThreeWriteValues() {
        #expect(EcgIngestClassification.allCases.count == 3)
        #expect(Set(EcgIngestClassification.allCases.map(\.rawValue)) == ["IRREGULAR", "NOT_DETECTED", "INCONCLUSIVE"])
    }

    @Test("Die Ereignis-Urteile der Leseseite sind hier nicht erzeugbar")
    func eventVerdictsAreNotWritable() {
        // `LOW` / `VERY_LOW` / `FIRED` sind Gehstetigkeits- bzw. neutrale
        // Ereignis-Urteile. Sie können auf `rhythm-events` ankommen, aber die
        // ECG-Route lehnt sie ab — und der Client kann sie gar nicht erst
        // bilden.
        for raw in ["LOW", "VERY_LOW", "FIRED", "", "SINUS", "AFIB"] {
            #expect(EcgIngestClassification(rawValue: raw) == nil, "\(raw) darf kein Schreibwert sein")
        }
    }

    @Test("Die Leseaufzählung bleibt sechswertig — sie muss zeigen, was ankommt")
    func readEnumStaysWide() {
        // Der Beweis, dass die beiden Typen NICHT dieselben sind: die Leseseite
        // kennt die drei Ereignis-Urteile weiterhin und rendert sie ehrlich.
        #expect(EcgClassification(raw: "LOW") == .low)
        #expect(EcgClassification(raw: "VERY_LOW") == .veryLow)
        #expect(EcgClassification(raw: "FIRED") == .fired)
        #expect(EcgClassification(raw: "IRREGULAR") == .irregular)
    }

    @Test("Nur APPLE_HEALTH als Quelle")
    func onlyAppleHealthSource() {
        #expect(EcgIngestRequestDTO.appleHealthSource == "APPLE_HEALTH")
        let payload = EcgIngestRequestDTO(
            externalRecordingId: "x",
            recordedAt: Date(timeIntervalSince1970: 0),
            samplingFrequency: 512,
            samples: [1],
            lead: "I",
            averageHeartRate: nil,
            classification: nil
        )
        #expect(payload.source == "APPLE_HEALTH")
    }

    @Test("Die Serverzahlen stehen als Konstanten im Vertrag")
    func limitsArePinned() {
        #expect(EcgIngestRequestDTO.maxSamples == 32768)
        #expect(EcgIngestRequestDTO.maxBodyBytes == 2 * 1024 * 1024)
    }
}
