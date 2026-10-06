import SwiftUI

/// A one-button "OK" alert that tells the person something happened and runs
/// `onAcknowledge` when they close it. Stateless: it unmounts with whatever it
/// is attached to, so a presentation from an authenticated screen goes away
/// with the authenticated shell.
///
/// **#115 R3 (server v1.39.7)** — first used by the two mood editors: the server
/// drops tag and rated-factor keys it does not know or has archived, saves the
/// entry anyway, and from v1.39.7 names them in `droppedTagKeys` /
/// `droppedFactorKeys`. The editors read `MoodStore.lastWriteDroppedKeys` after
/// their save and show `mood.droppedKeys.title` / `.message` before they close.
/// That copy names no keys: they are catalog keys (`worked_out`), not labels,
/// and an archived key may have no label left in the catalog at all.
///
/// Lives in `DesignSystem/` as a shared carrier, the same way `HLButton`'s push
/// form carries the deny-list push (Phase 06 presentation inventory, 17-10).
struct HLAcknowledgeAlert: ViewModifier {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @Binding var isPresented: Bool
    let onAcknowledge: () -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            Button("OK") { onAcknowledge() }
        } message: {
            Text(message)
        }
    }
}

extension View {
    /// See ``HLAcknowledgeAlert``.
    func hlAcknowledgeAlert(
        _ title: LocalizedStringKey,
        message: LocalizedStringKey,
        isPresented: Binding<Bool>,
        onAcknowledge: @escaping () -> Void
    ) -> some View {
        modifier(HLAcknowledgeAlert(title: title, message: message, isPresented: isPresented, onAcknowledge: onAcknowledge))
    }
}
