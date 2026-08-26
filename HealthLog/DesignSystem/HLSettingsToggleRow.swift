import SwiftUI

/// **S1 (v0.15.2 felt-wave) — the ONE canonical "title + description + Toggle"
/// settings row.**
///
/// Operator b198 walkthrough: Settings → Datenschutz & Sicherheit →
/// Forschermodus rendered the heading + help paragraph crammed into ~1/3 of the
/// row width with a huge horizontal gap to the switch. Root cause: the
/// hand-rolled `HStack { VStack(title + description); Spacer; Toggle }` rows
/// across Settings never pinned the text block with
/// `.fixedSize(horizontal: false, vertical: true)`, so once the trailing
/// `Toggle` claimed its intrinsic width the text VStack collapsed to its
/// minimum and wrapped narrow — title and Fließtext squeezed into a sliver, a
/// wide dead gap to the switch.
///
/// **Desired anatomy (this primitive):** the title sits on its own line(s)
/// full-width, the help/description Fließtext directly beneath it (both
/// `.fixedSize` vertical so they take all the width they need and wrap only
/// when the row itself is narrow), then the `Toggle` trailing with NORMAL
/// spacing — a single `HLSpace.md` gutter, not an elastic gap. The text block
/// carries `layoutPriority(1)` so it wins the available width over the
/// fixed-size switch.
///
/// **Server-first / render-only.** This primitive owns layout only. The `isOn`
/// binding is the caller's — typically a server-owned value with an intercept
/// in the setter (e.g. presenting an acknowledgment sheet before enabling). An
/// optional `isBusy` flag renders a mini `ProgressView` between the text and the
/// switch (the in-flight pattern the server-synced toggles already used), and
/// `isEnabled` disables the control while a write is in flight or the server
/// value hasn't loaded yet.
///
/// Use this for every Settings `Toggle` paired with a description so the row
/// geometry stays identical app-wide (Forschermodus, Diabetes, module gates,
/// notification opt-ins, …). A bare `Toggle` with no description does not need
/// this primitive.
struct HLSettingsToggleRow: View {
    /// Row title — short, on its own line(s), full-width.
    let title: LocalizedStringKey
    /// Optional help/description Fließtext rendered directly beneath the title.
    /// `nil` ⇒ title-only row (still correctly laid out).
    let description: LocalizedStringKey?
    /// The toggle's binding. The caller owns the value (often server-backed) and
    /// may intercept the setter (e.g. to present an acknowledgment sheet).
    @Binding var isOn: Bool
    /// When `true`, a mini `ProgressView` renders between the text and the
    /// switch — the in-flight indicator for a server-synced write.
    var isBusy: Bool = false
    /// When `false`, the switch is disabled (write in flight, or the server
    /// value hasn't resolved yet). Defaults to enabled.
    var isEnabled: Bool = true
    /// Accessibility identifier forwarded onto the `Toggle` so UI tests keep
    /// targeting the control by the same id as the hand-rolled rows did.
    var accessibilityID: String?

    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(title)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let description {
                    Text(description)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The text block wins the available width over the fixed-size
            // switch — this is what kills the "1/3 width + wide gap" collapse.
            .layoutPriority(1)
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(!isEnabled)
                .modifier(OptionalAXIdentifier(identifier: accessibilityID))
        }
        // The whole row is one VoiceOver element: the title + description read
        // as the toggle's label, with the switch's own value/trait.
        .accessibilityElement(children: .combine)
    }
}

/// Applies an `.accessibilityIdentifier` only when one is supplied — keeps the
/// `HLSettingsToggleRow` call-site free of an empty-string fallback that would
/// clobber an inherited id.
private struct OptionalAXIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

#Preview("HLSettingsToggleRow") {
    @Previewable @State var research = false
    @Previewable @State var compact = true
    return VStack(spacing: HLSpace.lg) {
        // R11 / E4 — das Primitive liefert KEINEN Inhalt. Die Preview zeigt
        // deshalb Platzhaltertext, nicht den früheren Forschungsmodus-Satz
        // (der als eingebauter Default-Text gelesen wurde und an genau einer
        // Aufrufstelle wortgleich dupliziert war).
        HLSettingsToggleRow(
            title: "Row title",
            description: "Row description",
            isOn: $research,
            accessibilityID: "preview.research"
        )
        Divider()
        HLSettingsToggleRow(
            title: "Compact layout",
            description: nil,
            isOn: $compact
        )
    }
    .padding()
    .background(HLSurface.secondary)
}
