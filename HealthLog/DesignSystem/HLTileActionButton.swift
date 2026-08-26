import SwiftUI

/// The tile-action tokens, in a plain namespace rather than on the view.
///
/// `HLTileActionButton` is a `View` and therefore main-actor isolated, which would make
/// its statics unreachable from the `nonisolated` context a contract test runs in. The
/// values are pure data; they live where data can be read.
enum HLTileAction {
    /// The load-bearing design tokens, as comparable values rather than as
    /// rendered pixels.
    ///
    /// A contract test can hold two surfaces to the same shape without
    /// screenshotting either, and — the point — it keeps holding when the copy,
    /// the icon or the layout around the button changes. Tokens are identities
    /// (`FontToken`, `InkToken`), not `Font`/`Color` values, because those are
    /// not usefully comparable and a test that cannot compare is a test that
    /// cannot fail.
    struct Tokens: Equatable, Sendable {
        /// The HIG floor the button never leaves. 44, never 48, never 56.
        let minHeight: CGFloat
        /// Never larger than a card heading (`.hlHeadline`).
        let font: FontToken
        /// Monochrome. Never the user's accent pick, never the primary ink.
        let ink: InkToken
        /// No `.tint` slab — the tile leads, the button does not.
        let hasFill: Bool
    }

    /// Typography token identity.
    enum FontToken: String, Equatable, Sendable {
        case hlSubhead
    }

    /// Ink token identity.
    enum InkToken: String, Equatable, Sendable {
        case textSecondary
    }

    /// **The canonical tile-action shape.** Both twins render from this and the
    /// parity contract test compares against it by name.
    ///
    /// The numbers are the same three `HLButton.restrainedContract` has carried
    /// since W-BUTTONS — that variant is where this shape was first written
    /// down, and `HLButtonRestrainedContractTests` pins that the standard's text
    /// and these values still agree.
    static let tokens = Tokens(
        minHeight: 44,
        font: .hlSubhead,
        ink: .textSecondary,
        hasFill: false
    )
}

/// **UI-Standard R9/E2-A1 — die Kachel-Aktion (quiet tile action).**
///
/// The one carrier for an action that sits *inside* a list/feed tile and must
/// not out-shout the tile it belongs to. Its tokens are written into the
/// standard (`.planning/ux/STANDARD-ui.md`, R9 Amendment A1, 2026-08-23) and
/// mirrored here: 44 pt height class, `.hlSubhead`, monochrome
/// `HLText.secondary` ink, no fill, 1 pt hairline.
///
/// **Why this exists as a shared primitive rather than as good intentions.**
/// The Vorsorge tiles were matched to the medication tiles twice — b210
/// (`4c11938b`, 2026-07-05, „exakt wie die Medikamenten-Karten") and b215
/// (`b84adbe0`, 2026-07-07) — and both deliveries MIRRORED the medication
/// card's inline button rather than sharing it, because b210 judged
/// `MedicationCard` not reusable. That mirroring is the channel the drift came
/// down: on 2026-07-31 the standards sweep `d06174e6` translated three
/// `.restrained` call sites to `.secondary`, correctly under the
/// wording that existed, and the Vorsorge button silently became
/// 48 pt/`.hlHeadline`/`HLText.primary` while its comment went on claiming
/// parity. One surface moved; the other could not, because there was nothing
/// holding them together.
///
/// Now there is. Two surfaces that must look identical render from one type.
///
/// **Not `HLButton`.** `HLButton` is the full-width flow CTA
/// (`.primary`/`.secondary`/`.destructive`). Its `.secondary` at `size:
/// .compact` hits the height and the font of a tile action but paints
/// `HLText.primary`, which fails the ink row of R9/E2-A1 — and reviving the
/// retired `.restrained` variant for this would raise
/// `hl_button_legacy_variant` (38 → 41) and fail the `UIStandardBaseline`
/// ratchet. A separate primitive is the shape that is correct *and* costs the
/// ratchet nothing.
struct HLTileActionButton: View {
    private let titleKey: LocalizedStringResource
    private let icon: String?
    private let action: () -> Void

    /// - Parameters:
    ///   - titleKey: catalogue resource; resolved once so the visible label and
    ///     the accessibility label cannot drift apart.
    ///   - icon: optional SF Symbol, rendered in the same monochrome ink.
    init(_ titleKey: LocalizedStringResource, icon: String? = nil, action: @escaping () -> Void) {
        self.titleKey = titleKey
        self.icon = icon
        self.action = action
    }

    var body: some View {
        let label = String(localized: titleKey)
        return Button(action: action) {
            HStack(spacing: HLSpace.sm) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(label)
                    .font(.hlSubhead)
            }
            .frame(minHeight: HLTileAction.tokens.minHeight)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HLSpace.lg)
            .foregroundStyle(HLText.secondary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                    .strokeBorder(HLText.tertiary.opacity(0.25), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

#Preview("HLTileActionButton") {
    VStack(spacing: HLSpace.md) {
        HStack(spacing: HLSpace.sm) {
            HLTileActionButton("med.card.action.taken", icon: "checkmark") {}
            HLTileActionButton("med.card.action.skipped", icon: "forward.end") {}
        }
    }
    .padding()
    .background(HLSurface.primary)
}
