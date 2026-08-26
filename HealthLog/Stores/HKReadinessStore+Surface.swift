import Foundation

/// Ableitung des **Verbindungs-Zustands für die Oberfläche** — als eigene Datei
/// nach der `file_length`-Disziplin aus `PROJECT_GUIDE.md` (reine Verschiebung der in
/// H1 neu hinzugekommenen Ableitung, kein Verhalten in `HKReadinessStore.swift`
/// geändert).
public extension HKReadinessStore {
    /// Was eine Verbindungsfläche über Apple Health sagen soll — **eine**
    /// Ableitung für jede Statusanzeige.
    ///
    /// Vorher leitete jede Fläche ihren eigenen Fall aus `state` ab, und die
    /// Ableitungen liefen auseinander: `AppleHealthIntegrationDetailScreen`
    /// fragte `isConnected` zuerst, `SettingsIntegrationsScreen` malte
    /// `.partiallyGranted` unbesehen rot. Derselbe Zustand las sich auf der
    /// Integrationen-Liste als Fehler und eine Ebene tiefer als „Verbunden“.
    ///
    /// Die Fallunterscheidung folgt der Frage „was soll der Nutzer tun?“:
    /// - ``receiving`` — Daten kommen an (bzw. der Sheet lief und wurde nicht
    ///   abgelehnt). Ob beim **Zurückschreiben** Typen fehlen, ist eine andere
    ///   Geschichte und steht als eigene Zeile auf der Detailseite; es macht
    ///   die Verbindung nicht kaputt und färbt sie deshalb nicht rot.
    /// - ``declined`` — jeder Schreibtyp abgelehnt **und** nichts angekommen.
    ///   Das ist der einzige Fall, in dem ohne Zutun des Nutzers nichts
    ///   funktioniert — und damit der einzige rote.
    enum SurfaceStatus: Equatable, Sendable {
        /// Vor dem ersten `refresh()`.
        case checking
        /// Verbindung steht — Empfang läuft bzw. ist eingerichtet.
        case receiving
        /// Der Sheet lief nie; nichts eingerichtet.
        case notConnected
        /// Aktiv abgelehnt und nachweislich nichts angekommen.
        case declined
    }

    /// Kanonische Ableitung für jede Statusanzeige (siehe ``SurfaceStatus``).
    var surfaceStatus: SurfaceStatus {
        if case .unknown = state { return .checking }
        if isConnected { return .receiving }
        if case .denied = state { return .declined }
        return .notConnected
    }

    /// Die HK-Identifier der Schreibtypen, die **nicht** `.sharingAuthorized`
    /// sind — dieselbe Liste, die `.partiallyGranted(missing:)` trägt, nur ohne
    /// Pattern-Match am Aufrufer. Leer in jedem anderen Zustand.
    var missingWriteTypeIdentifiers: [String] {
        if case let .partiallyGranted(missing) = state { return missing }
        return []
    }
}
