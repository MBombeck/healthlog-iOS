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

    /// **#154 (MIRROR, 1.5)** — welche Handlung die Apple-Health-Karte anbietet.
    ///
    /// Bis 1.4.1 standen „Mit Apple Health verbinden“ und „In Apple Health
    /// öffnen“ immer da, solange nicht jeder Schreibtyp erteilt war. Mit
    /// teilweise erteiltem Schreibzugriff sagte die Pille also „Verbunden“ und
    /// der Primärknopf darunter „Verbinden“. Jetzt gibt es genau eine Handlung,
    /// passend zum Zustand.
    enum ConnectionAction: Equatable, Sendable {
        /// Nichts zu tun: alles erteilt, oder der Zustand ist noch unbekannt.
        case none
        /// Der Systemdialog ist unbeantwortet: Primärknopf „Verbinden“.
        case connect
        /// Empfang steht oder der Dialog ist beantwortet, aber Schreibtypen
        /// fehlen: Link „Schreibzugriff prüfen“ neben dem Hinweis.
        case reviewWriteAccess
        /// Abgelehnt und nichts angekommen: „In Apple Health öffnen“ als
        /// Primärknopf, denn iOS fragt nie zweimal.
        case openHealthApp
    }

    /// Reine Ableitung, damit jeder Zustand ohne HealthKit testbar ist.
    /// `sheetAnswered` ist ``authorizationSheetAnswered(shareIdentifiers:readIdentifiers:)``:
    /// `false` heißt, iOS würde den Dialog zeigen; `nil` heißt, die Plattform
    /// kann es nicht sagen, dann gilt ohne Beleg für Empfang die Regel von 1.4.
    static func connectionAction(
        state: ConnectionState,
        isConnected: Bool,
        sheetAnswered: Bool?
    ) -> ConnectionAction {
        switch state {
        case .unknown, .fullyGranted:
            return .none
        case .notRequested, .partiallyGranted, .denied:
            break
        }
        if sheetAnswered == false { return .connect }
        if case .denied = state, !isConnected { return .openHealthApp }
        if sheetAnswered == true || isConnected { return .reviewWriteAccess }
        return .connect
    }

    /// Die Handlung für den aktuellen Zustand dieses Stores.
    func connectionAction(sheetAnswered: Bool?) -> ConnectionAction {
        Self.connectionAction(state: state, isConnected: isConnected, sheetAnswered: sheetAnswered)
    }

    /// #10 — welcher Zeitpunkt unter "Last synced" steht.
    ///
    /// Zuerst der eigene Stempel dieses Geräts (``lastSyncedAt``), sonst der des
    /// Servers (`GET /api/integrations/healthkit` → `lastSyncedAt`, gestempelt bei
    /// jedem angenommenen HealthKit-Batch). Der Rückfall trägt die Anzeige über
    /// eine Neuinstallation, die den lokalen Stempel mit den `UserDefaults`
    /// verliert, und über die Zeit bis zum ersten Upload nach einer Anmeldung.
    ///
    /// **Nur für die Anzeige.** ``isConnected`` liest den Server-Wert bewusst
    /// nicht: er ist kontoweit und wird auch von einem anderen Gerät desselben
    /// Kontos gestempelt, beweist also nicht, dass **dieses** Gerät Apple Health
    /// lesen darf — genau das soll die Abgelehnt-Warnung aber beantworten.
    func displayedLastSyncedAt(serverLastSyncedAt: Date?) -> Date? {
        lastSyncedAt ?? serverLastSyncedAt
    }
}
