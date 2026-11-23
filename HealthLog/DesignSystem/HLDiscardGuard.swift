import SwiftUI

/// **Canonical unsaved-changes guard for editor sheets.**
///
/// Before this, `interactiveDismissDisabled` was gated only on `isSaving` (or
/// missing entirely on the Labs/Records editors), so a swipe-down on a filled
/// form silently discarded every field. This modifier standardises the fix:
///
///  1. `interactiveDismissDisabled(isDirty || isSaving)` blocks the accidental
///     swipe-to-dismiss the moment the form has unsaved edits (or is mid-save).
///  2. A discard confirmation — presented through the bound `isPresented` flag —
///     gives the operator an explicit "Änderungen verwerfen / Weiter bearbeiten"
///     choice instead of a silent data loss. Since R13-A1 (2026-08-23) it is
///     carried by ``View/hlConfirmDestructive(_:isPresented:message:confirm:confirmIdentifier:cancel:onCancel:action:)``
///     rather than built here, so all 12 call sites inherit the one centred,
///     anchorless shape instead of a second opinion about what a destructive
///     question looks like.
///
/// The sheet's Cancel button routes through ``View/hlDiscardCancel(isDirty:showDiscardConfirm:dismiss:)``
/// (or inlines the same logic): dirty → present the dialog; clean → dismiss
/// immediately. Mirrors the focus + save-outcome conventions already used by
/// `MeasureSheetView`.
struct HLDiscardGuard: ViewModifier {
    /// Whether the form currently holds unsaved edits (compared against its
    /// initial/prefilled state).
    let isDirty: Bool
    /// Whether a save is in flight — kept in the guard so the existing
    /// `isSaving` dismissal-lock is preserved.
    let isSaving: Bool
    /// Drives the discard-confirmation dialog. The Cancel button flips this on
    /// when `isDirty`.
    @Binding var isPresented: Bool
    /// Invoked when the operator confirms the discard — the caller dismisses.
    let onDiscard: () -> Void

    /// Optional so previews and tests without a router still render.
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty || isSaving)
            // A link from outside the app closes a form that holds nothing
            // yet, so its destination is not hidden under the sheet. One with
            // unsaved input stays: the link must not throw away an entry.
            .onChange(of: router?.deepLinkArrivalCount) { _, _ in
                if Self.closesForDeepLink(isDirty: isDirty, isSaving: isSaving) { dismiss() }
            }
            .hlConfirmDestructive(
                Text("form.discard.confirm.title"),
                isPresented: $isPresented,
                message: Text("form.discard.confirm.message"),
                confirm: Text("form.discard.confirm.discard"),
                cancel: Text("form.discard.confirm.keep"),
                action: onDiscard
            )
    }
}

extension HLDiscardGuard {
    nonisolated static func closesForDeepLink(isDirty: Bool, isSaving: Bool) -> Bool {
        !isDirty && !isSaving
    }
}

extension View {
    /// Applies the canonical unsaved-changes guard (Audit FORM-1). Pair it with a
    /// Cancel button that flips `isPresented` on when `isDirty`, else dismisses.
    ///
    /// - Parameters:
    ///   - isDirty: `true` once the form diverges from its initial state.
    ///   - isSaving: keeps the pre-existing in-flight dismissal-lock.
    ///   - isPresented: binding that drives the discard-confirmation dialog.
    ///   - onDiscard: run when the operator confirms discard (dismiss here).
    func hlDiscardGuard(
        isDirty: Bool,
        isSaving: Bool = false,
        isPresented: Binding<Bool>,
        onDiscard: @escaping () -> Void
    ) -> some View {
        modifier(HLDiscardGuard(
            isDirty: isDirty,
            isSaving: isSaving,
            isPresented: isPresented,
            onDiscard: onDiscard
        ))
    }
}
