import SwiftUI

/// Die **eine** Statusanzeige für „wie steht es um Apple Health?“.
///
/// **Warum ein eigener Baustein.** Vorher leitete jede Fläche ihren Pill-Fall
/// selbst aus `HKReadinessStore.state` ab. Die Ableitungen liefen auseinander:
/// `AppleHealthIntegrationDetailScreen` fragte zuerst `isConnected` (die
/// Empfangs-Wahrheit) und malte deshalb grün, `SettingsIntegrationsScreen`
/// schaltete `.partiallyGranted` unbesehen auf `HLStatusPill(.error(…))`.
/// Derselbe Zustand las sich auf der Integrationen-Liste als roter Fehler und
/// eine Ebene tiefer als „Verbunden“ — der Betreiber-Befund „das kann ja jetzt
/// nicht teilweise erlaubt angezeigt in rot“.
///
/// Jetzt gibt es genau eine Ableitung (`HKReadinessStore.surfaceStatus`) und
/// genau einen Maler. Rot bleibt dem einen Fall vorbehalten, in dem ohne Zutun
/// des Nutzers nichts funktioniert: alles abgelehnt und nachweislich nichts
/// angekommen. „Teilweise erlaubt“ ist eine Aussage über das **Zurückschreiben**
/// und lebt als eigene Zeile auf der Apple-Health-Detailseite, nicht als
/// Fehlerfarbe an der Verbindung.
public struct HealthKitStatusPill: View {
    @Environment(HKReadinessStore.self) private var readiness

    public init() {}

    public var body: some View {
        switch readiness.surfaceStatus {
        case .checking:
            HLStatusPill(.unknown(label: String(localized: "Checking")))
        case .receiving:
            HLStatusPill(.connected(label: String(localized: "Connected")))
        case .notConnected:
            HLStatusPill(.disconnected(label: String(localized: "Not connected")))
        case .declined:
            HLStatusPill(.error(label: String(localized: "Declined")))
        }
    }
}
