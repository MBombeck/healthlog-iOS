import SwiftUI

/// Canonical sheet-presentation behaviour for HealthLog.
///
/// Before this token every `.sheet`/`.fullScreenCover` site re-spelled its own
/// `.presentationDetents([…])` + `.presentationDragIndicator(…)` pair, which had
/// drifted into four different combinations across ~27 files (some sheets had no
/// detent or no drag indicator at all). `HLSheetSize` + `hlSheetPresentation`
/// collapse that into a single, named contract so every sheet feels the same.
///
/// The named sizes encode *intent*, not raw detents — call-sites pick the
/// behaviour they want and the token maps it onto the right `PresentationDetent`
/// set, so a future detent-policy change is a one-line edit here.
public enum HLSheetSize {
    /// Opens at half-height, draggable to full. Use for quick pickers and
    /// short content where the underlying screen should stay visible behind
    /// (capture confirms, score detail, history detail).
    case standard

    /// Half-height only — single detent, not draggable to full. Use for
    /// compact pickers that should never grow.
    ///
    /// v0.14.1 W-CAPTURE-GAP note: the central Erfassen picker no longer uses
    /// this — a fixed `.medium` left a dead gap below its 3–4 short rows, so
    /// `CapturePickerSheet` now self-sizes to a content-fitted `.height`
    /// detent. Prefer that pattern for any other short, content-driven picker.
    case compact

    /// Full-height only — single detent. Use for long forms / editors where
    /// keyboard avoidance + multi-field layout would be cramped at `.medium`
    /// (medication editors, target editor, coach conversation). This is the
    /// app's default and matches Apple's own Health "Add Data" sheet.
    case form

    /// The presentation detents this size resolves to.
    public var detents: Set<PresentationDetent> {
        switch self {
        case .standard: [.medium, .large]
        case .compact: [.medium]
        case .form: [.large]
        }
    }
}

// MARK: - Sheet behavior tokens (post-v0.4.0 sheet-animation fix)

public enum HLSheet {
    /// v0.4.0 decision: present at .large only. Prevents the
    /// medium→keyboard-promote-to-large glitch reported by User-Report #4.
    /// Mirrors `HLSheetSize.form` — kept as a named alias for call-sites and
    /// the regression guard that anchor against the raw detent set.
    public static let detents: Set<PresentationDetent> = HLSheetSize.form.detents
    /// Drag-indicator visibility default for canonical sheets.
    public static let dragIndicator: Visibility = .visible
    /// Recommended focus delay so focus fires AFTER the sheet has settled.
    /// 600ms covers Apple's spring-settle window on real ProMotion devices.
    /// PA8 audit (2026-05-15): 350ms was simulator-tuned; on real iPhone 16
    /// Pro the spring takes ~400-550ms to settle, so focus fired mid-flight
    /// and the keyboard rise snapped the remaining travel — reproducing the
    /// "half-open → pause → full-with-keyboard" glitch of User-Report #4
    /// even after the v0.4.0 detent fix. 600ms is imperceptible to the
    /// user and anchors against real-device timing variance.
    public static let focusDelay: Duration = .milliseconds(600)
}

public extension View {
    /// Applies the canonical sheet presentation: the detents for `size` plus a
    /// visible drag indicator. Route every user-dismissible sheet through this
    /// so detents + the dismiss affordance stay consistent app-wide.
    ///
    /// Background / corner-radius treatment stays orthogonal — sites that need
    /// the opaque Home-Compliance platter keep their own
    /// `.presentationBackground(HLColor.surface)`.
    ///
    /// - Parameter size: the intent-named sheet size; defaults to `.form`
    ///   (full-height) to match the app's heavy-form default.
    func hlSheetPresentation(_ size: HLSheetSize = .form) -> some View {
        presentationDetents(size.detents)
            .presentationDragIndicator(HLSheet.dragIndicator)
    }
}
