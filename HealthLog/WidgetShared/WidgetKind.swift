import Foundation

/// **v0.8.4 WWIDGET-2 — stable widget `kind` identifiers.**
///
/// Shared by the app (which reloads timelines by kind via
/// `WidgetCenter.shared.reloadTimelines(ofKind:)`) and the extension
/// (which declares each `Widget` with the matching `kind:`). Keeping the
/// strings here is the single source of truth so a reload and a widget
/// declaration can never disagree on the identifier.
public enum WidgetKind {
    /// The next-scheduled-dose widget (small / medium / Lock-Screen
    /// accessories) with the interactive "Genommen" button.
    public static let nextDose = "dev.healthlog.app.widgets.next-dose"

    /// Today's-adherence compliance-ring widget (small / accessoryCircular).
    public static let compliance = "dev.healthlog.app.widgets.compliance"

    /// **v0.8.4 WWIDGET-3** — the "Erfassen" Control Center / Action-Button
    /// control that opens the app's capture flow (``OpenCaptureIntent``).
    public static let captureControl = "dev.healthlog.app.widgets.control.capture"

    /// **v0.8.4 WWIDGET-3** — the "Nächste Dosis – Genommen" control that
    /// one-tap marks the next due dose taken (``MarkNextDoseTakenIntent``).
    public static let markNextDoseControl = "dev.healthlog.app.widgets.control.next-dose-taken"

    /// **v0.10.0 W-Mood-B** — the "Stimmung erfassen" Control Center /
    /// Action-Button control that opens the app's mood quick-entry sheet
    /// (``LogMoodControlIntent``).
    public static let logMoodControl = "dev.healthlog.app.widgets.control.log-mood"

    /// **v0.10.0 W-Mood-B** — the interactive Home / Lock-Screen mood widget
    /// (recent mood glance + a tap-a-face quick-log row).
    public static let mood = "dev.healthlog.app.widgets.mood"

    /// **v0.15 companion-#3** — the Personal Health Score ring widget
    /// (systemSmall + accessoryCircular). Paints the latest server score as a
    /// calm monochrome ring matching the in-app `HLScoreRing`.
    public static let healthScore = "dev.healthlog.app.widgets.health-score"

    /// **v0.15 companion-#3** — the latest-measurement glance widget
    /// (systemSmall + accessoryRectangular + accessoryInline). Shows the most
    /// recent reading for the default metric — value + unit + relative time.
    public static let latestMeasurement = "dev.healthlog.app.widgets.latest-measurement"
}
