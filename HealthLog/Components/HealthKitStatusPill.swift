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
    /// A status the host already derived (the Apple Health page also knows
    /// whether iOS would still show the permission sheet); `nil` reads the store.
    private let status: HKReadinessStore.SurfaceStatus?
    private let form: HLBadge.Form

    public init() {
        status = nil
        form = .capsule
    }

    init(status: HKReadinessStore.SurfaceStatus? = nil, form: HLBadge.Form) {
        self.status = status
        self.form = form
    }

    public var body: some View {
        switch status ?? readiness.surfaceStatus {
        case .checking:
            HLStatusPill(.unknown(label: String(localized: "Checking")), form: form)
        case .receiving:
            HLStatusPill(.connected(label: String(localized: "Connected")), form: form)
        case .notConnected:
            HLStatusPill(.disconnected(label: String(localized: "Not connected")), form: form)
        case .declined:
            HLStatusPill(.error(label: String(localized: "Declined")), form: form)
        }
    }
}
