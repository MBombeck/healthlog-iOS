import Foundation

/// Display resolution for the ECG surface — the ONE place the recording
/// device's verdict becomes user-facing copy.
///
/// **Regulatory framing (load-bearing — do NOT soften).** Every string here
/// describes the RECORDING DEVICE's own certified on-device result. HealthLog
/// re-classifies nothing and interprets nothing; the result label is always
/// paired with ``attribution(for:)``, which names the device as its author.
/// An unrecognised literal is shown VERBATIM rather than mapped, guessed at, or
/// dropped — the app must never invent a meaning for a verdict it does not know.
///
/// Copy is the web catalogue's (`insights.ecg.result.*` /
/// `insights.ecg.resultAttribution`), which is a copy contract shared with the
/// server and the web app.
enum EcgPresentation {
    /// The device's result, as a display string. Never a HealthLog assessment.
    static func resultLabel(for classification: EcgClassification) -> String {
        switch classification {
        case .irregular: String(localized: "insights.ecg.result.irregular")
        case .notDetected: String(localized: "insights.ecg.result.notDetected")
        case .inconclusive: String(localized: "insights.ecg.result.inconclusive")
        case .none: String(localized: "insights.ecg.result.none")
        // CU-16 — the three EVENT verdicts of the shared `RhythmClassification`
        // enum. They describe the notification the device raised, not a rhythm
        // finding, so the copy states exactly that and stops. Rendering them as
        // a cardiac result would be an invention; rendering the raw token
        // ("VERY_LOW") would be an untranslated wire artefact.
        case .low: String(localized: "insights.ecg.result.low")
        case .veryLow: String(localized: "insights.ecg.result.veryLow")
        case .fired: String(localized: "insights.ecg.result.fired")
        // Verbatim: an unknown device literal is data, not something to
        // reinterpret.
        case let .unknown(raw): raw
        }
    }

    /// The result line, explicitly attributed to the recording device.
    static func attribution(for classification: EcgClassification) -> String {
        String(localized: "insights.ecg.resultAttribution \(resultLabel(for: classification))")
    }

    /// Whether the "discuss this with a clinician" note belongs on this
    /// recording. A routing decision about the DEVICE's verdict only.
    static func showsClinicianNote(for classification: EcgClassification) -> Bool {
        classification.isNonNormalDeviceResult
    }

    /// Whether a list row may be tapped into the detail. A `ts-` fallback event
    /// carries a verdict but no signal, so its row must not navigate anywhere
    /// (no dead push).
    static func isOpenable(_ recording: EcgRecordingDTO) -> Bool {
        recording.hasWaveform
    }

    // MARK: - Metadata values (verbatim, never recomputed)

    /// `"30 s"`, or the honest unknown dash.
    static func durationValue(_ seconds: Double?) -> String {
        guard let seconds else { return String(localized: "insights.ecg.meta.unknown") }
        return String(localized: "insights.ecg.meta.durationValue \(Int(seconds.rounded()))")
    }

    /// `"62 bpm"`, or the honest unknown dash.
    static func bpmValue(_ bpm: Double?) -> String {
        guard let bpm else { return String(localized: "insights.ecg.meta.unknown") }
        return String(localized: "insights.ecg.meta.bpmValue \(Int(bpm.rounded()))")
    }

    /// `"300 Hz"`, or the honest unknown dash.
    static func hzValue(_ hz: Double?) -> String {
        guard let hz else { return String(localized: "insights.ecg.meta.unknown") }
        return String(localized: "insights.ecg.meta.hzValue \(Int(hz.rounded()))")
    }

    /// The lead label. A single-lead strip reads as the web's "Single lead
    /// (Lead I)"; anything else is shown verbatim.
    static func leadValue(_ lead: String?) -> String {
        guard let lead, !lead.isEmpty else { return String(localized: "insights.ecg.meta.unknown") }
        if lead.uppercased() == "I" { return String(localized: "insights.ecg.meta.leadSingle") }
        return lead
    }
}
