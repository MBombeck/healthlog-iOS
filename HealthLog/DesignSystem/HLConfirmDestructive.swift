import SwiftUI

/// **R13-A1 — die eine zentrierte, ankerlose Form für jede destruktive Rückfrage.**
///
/// Der Betreiber hat destruktive Bestätigungen „generell zentriert und
/// ordentlich designt" verlangt. *Generell* heißt app-weit: nicht die drei
/// Stellen, an denen es am schlimmsten aussieht, sondern jede.
///
/// ## Warum die Form ein `alert` ist und kein `confirmationDialog`
///
/// Zentriert **und** ankerlos ist auf dem iPhone genau eine System-Präsentation.
/// Ein `confirmationDialog` ist per Konstruktion ein Anker — unter iOS 18–25 ein
/// Aktionsblatt an der Unterkante, unter iOS 26 eine Blase an der
/// Interaktionsquelle — und kann „zentriert" gar nicht liefern.
///
/// Genau daran ist **b174** gescheitert. Der Fix dazu ist nicht fremd, sondern
/// der **eigene des Betreibers**: `cf3f8777` („Lösch-Bestätigung im Med-Verlauf
/// unten verankert statt Popover auf Zeilenhöhe", 2026-06-11) hat die Blase an
/// zwei Stellen absichtlich an die Unterkante genagelt, weil sie unter iOS 26
/// sonst mitten im Bildschirm an willkürlicher Stelle ankerte — was schlechter
/// aussah als die Blase. Dieser Fix ist mit R13-A1 aufgehoben, **nicht
/// vergessen**: er steht hier, damit die Blase in einem Jahr eine Entscheidung
/// bleibt und nicht als Versehen gelesen wird.
///
/// Ein `alert` hat **keine Präsentationsquelle**, an der er fehl-ankern könnte.
/// Das ist der eigentliche Grund, warum diese Ersatzform b174 *löst*, statt es
/// erneut zu riskieren — und nicht bloß eine zweite Wette auf das SDK.
///
/// ## Was der Träger übernimmt und was die Aufrufstelle behält
///
/// Der Träger entscheidet das **Substrat** und die **Rollen**: die Antwort
/// bleibt `.destructive`, das Abbrechen ist `.cancel` und existiert immer.
/// Zwei der abgelösten Aufrufstellen hatten gar keinen Abbrechen-Knopf — sie
/// lehnten sich an den impliziten des `confirmationDialog`. Ein `alert` legt
/// keinen dazu, also legt ihn der Träger an; ein destruktiver Dialog ohne
/// Ausweg wäre eine Falle.
///
/// Die Aufrufstelle behält ihren Text, ihren Zustand, ihre
/// Accessibility-Identifier und ihre Abbrechen-Nebenwirkung. Der Träger nimmt
/// ihr die Form ab, nicht ihre Bedeutung.
///
/// ## Warum das Verzeichnis das mitbekommt
///
/// `scripts/phase06-presentation-hit-scan.swift` kennt `.hlConfirmDestructive(`
/// als eigene Präsentationsart. Der Rumpf wohnt hier, in `DesignSystem/`, das
/// der Scanner nicht abtastet — wäre auch die Aufrufstelle unsichtbar, hätte
/// das PHI-Präsentationsverzeichnis 31 Präsentationen verloren, weil die App
/// einheitlicher geworden ist. Stattdessen bleibt die Aufrufstelle sichtbar,
/// und genau das macht die Disposition `RELOCATED_TO_SHARED_CARRIER`
/// überprüfbar statt behauptet.
enum HLConfirmDestructive {
    /// Fällt ein, wo die Aufrufstelle keinen eigenen Identifier mitgibt. Ein
    /// benannter Vorgabewert ist besser als ein leerer String: eine
    /// Geräte-Zeile oder ein UI-Test findet die Antwort auch dort, wo niemand
    /// daran gedacht hat, sie auszeichnen zu wollen.
    static let confirmIdentifier = "hlConfirmDestructive.confirm"
    static let cancelIdentifier = "hlConfirmDestructive.cancel"
}

extension View {
    /// Eine destruktive Rückfrage, zentriert und ankerlos.
    ///
    /// - Parameters:
    ///   - title: Die Frage. Kurz, in der Sprache des Aufrufers.
    ///   - isPresented: Steuerbindung der Aufrufstelle.
    ///   - message: Was die Handlung wirklich tut — insbesondere, ob sie
    ///     umkehrbar ist. `nil`, wo der Titel allein die Wahrheit sagt.
    ///   - confirm: Beschriftung der destruktiven Antwort.
    ///   - confirmIdentifier: Accessibility-Identifier, wo ein Test oder eine
    ///     Geräte-Zeile ihn braucht.
    ///   - cancel: Beschriftung des Abbrechens.
    ///   - cancelIdentifier: Accessibility-Identifier des Abbrechens.
    ///   - onCancel: Nebenwirkung des Abbrechens (Zustand zurücksetzen).
    ///   - action: Die destruktive Handlung.
    func hlConfirmDestructive(
        _ title: Text,
        isPresented: Binding<Bool>,
        message: Text? = nil,
        confirm: Text,
        confirmIdentifier: String? = nil,
        cancel: Text = Text("Cancel"),
        cancelIdentifier: String? = nil,
        onCancel: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(role: .destructive, action: action) { confirm }
                .accessibilityIdentifier(confirmIdentifier ?? HLConfirmDestructive.confirmIdentifier)
            Button(role: .cancel) { onCancel?() } label: { cancel }
                .accessibilityIdentifier(cancelIdentifier ?? HLConfirmDestructive.cancelIdentifier)
        } message: {
            if let message { message }
        }
    }

    /// Dieselbe Form für eine Rückfrage, die sich auf ein bestimmtes Objekt
    /// bezieht — die Zeile, die gelöscht wird, das Medikament, das archiviert
    /// wird.
    ///
    /// SwiftUI hält das Objekt über die Ausblendanimation hinweg am Leben,
    /// weshalb hier `presenting:` benutzt wird statt der optionale Zustand
    /// direkt: sonst verschwände die Beschriftung eine Zehntelsekunde vor dem
    /// Dialog.
    func hlConfirmDestructive<Item>(
        _ title: Text,
        presenting item: Binding<Item?>,
        message: ((Item) -> Text)? = nil,
        confirm: Text,
        confirmIdentifier: String? = nil,
        cancel: Text = Text("Cancel"),
        cancelIdentifier: String? = nil,
        onCancel: (() -> Void)? = nil,
        action: @escaping (Item) -> Void
    ) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            presenting: item.wrappedValue
        ) { value in
            Button(role: .destructive) { action(value) } label: { confirm }
                .accessibilityIdentifier(confirmIdentifier ?? HLConfirmDestructive.confirmIdentifier)
            Button(role: .cancel) { onCancel?() } label: { cancel }
                .accessibilityIdentifier(cancelIdentifier ?? HLConfirmDestructive.cancelIdentifier)
        } message: { value in
            if let message { message(value) }
        }
    }
}
