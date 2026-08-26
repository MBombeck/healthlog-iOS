import Foundation

// **CU-32 — Beschriftungen der Anamnese-Fläche.**
//
// Reine Schlüssel-Ableitung, kein SwiftUI: die Oberfläche und die
// Katalog-Tests greifen auf dieselben Konstanten zu, damit ein fehlender
// Katalog-Eintrag im Test auffällt und nicht erst auf dem Gerät.
//
// **Warum die Wert-Beschriftung an der Art hängt und nicht am Wert:** `NONE`
// kommt in zwei Wertemengen vor und bedeutet dort Verschiedenes — beim Alkohol
// „trinke keinen", beim Schichtplan „arbeite nicht in Schichten". Eine
// gemeinsame Beschriftung „Keine" wäre in beiden Fällen falsch genug, um
// missverstanden zu werden.

public extension AnamnesisFactKind {
    var titleKey: String {
        "anamnesis.kind.\(rawValue).title"
    }

    var subtitleKey: String {
        "anamnesis.kind.\(rawValue).subtitle"
    }

    var symbolName: String {
        switch self {
        case .smokingStatus: "smoke.fill"
        case .alcoholPattern: "wineglass.fill"
        case .shiftSchedule: "clock.arrow.2.circlepath"
        }
    }

    /// Katalog-Schlüssel der Beschriftung eines Wertes **in dieser Art**.
    /// Für ein unbekanntes Literal gibt es einen eigenen, ehrlichen Schlüssel —
    /// der Rohwert wird nicht als Beschriftung durchgereicht.
    func labelKey(for value: AnamnesisFactValue) -> String {
        value.isUnknown ? "anamnesis.value.unknown" : "anamnesis.value.\(rawValue).\(value.rawValue)"
    }

    /// Alle Beschriftungs-Schlüssel dieser Art — Testgrundlage für die
    /// Katalog-Vollständigkeit.
    var allLabelKeys: [String] {
        allowedValues.map { labelKey(for: $0) }
    }
}

public extension AnamnesisFactProvenance {
    /// `nil` für ein unbekanntes Literal — dann wird gar kein Abzeichen
    /// gezeigt, statt eines mit erfundener Bedeutung.
    var labelKey: String? {
        switch self {
        case .userReported: "anamnesis.provenance.userReported"
        case .userCorrection: "anamnesis.provenance.userCorrection"
        case .unknown: nil
        }
    }
}

/// Katalog-Schlüssel, die keine Ableitung sind. Gebündelt, damit der
/// i18n-Test sie ohne Stringliterale im Testkörper prüfen kann.
public enum AnamnesisCopy {
    public static let title = "anamnesis.title"
    public static let subtitle = "anamnesis.subtitle"
    public static let footer = "anamnesis.footer"

    public static let neverRecorded = "anamnesis.state.neverRecorded"
    public static let neverRecordedHint = "anamnesis.state.neverRecorded.hint"
    public static let unreadable = "anamnesis.state.unreadable"
    public static let unreadableHint = "anamnesis.state.unreadable.hint"
    public static let unknownValue = "anamnesis.value.unknown"

    public static let validitySince = "anamnesis.validity.since"
    public static let validityRange = "anamnesis.validity.range"

    public static let historyTitle = "anamnesis.history.title"
    public static let historyEmpty = "anamnesis.history.empty"
    public static let historyFooter = "anamnesis.history.footer"

    public static let actionRemove = "anamnesis.action.remove"
    public static let errorDismiss = "anamnesis.error.dismiss"

    public static let loadFailed = "anamnesis.loadFailed"
    public static let aboutMeSubtitle = "anamnesis.aboutMe.subtitle"

    public static let errorConflict = "anamnesis.error.conflict"
    public static let errorStale = "anamnesis.error.stale"
    public static let errorInvalidValue = "anamnesis.error.invalidValue"
    public static let errorCurrentExists = "anamnesis.error.currentExists"
    public static let errorInFlight = "anamnesis.error.inFlight"

    /// Jeder Schlüssel dieser Fläche, der nicht aus einer Art abgeleitet wird.
    public static let all: [String] = [
        title, subtitle, footer,
        neverRecorded, neverRecordedHint, unreadable, unreadableHint, unknownValue,
        validitySince, validityRange,
        historyTitle, historyEmpty, historyFooter,
        actionRemove, errorDismiss,
        loadFailed, aboutMeSubtitle,
        errorConflict, errorStale, errorInvalidValue, errorCurrentExists, errorInFlight
    ]
}
