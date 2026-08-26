import SwiftUI

/// **v0.5.4-NF-1 → v0.6.2 W-SEC-A.** Round profile-avatar used as the
/// Dashboard's inline header avatar and as the hero in `ProfileScreen`.
///
/// ## v0.8.0 W11 — self-hosted avatar restored (privacy-preserving)
///
/// A real profile photo is back — but served from the OWN server, not a
/// third party. When the caller passes a non-nil `image` (resolved by
/// `AvatarStore` through the authenticated, owner-scoped, cert-pinned
/// `APIClient` — see `AvatarRepository`), the view renders it clipped to the
/// circle. `image == nil` (no upload, 404, or load failure) keeps the exact
/// initials-monogram fallback below — the monogram remains fully functional
/// as the always-available default. No bare `AsyncImage(url:)` is ever used;
/// that would carry neither the Bearer token nor the SPKI pin.
///
/// ## v0.6.2 — Gravatar removed (privacy posture)
///
/// Earlier revisions (v0.5.4.3 HP1 / v0.5.5 W-UX-1 / v0.5.5.2
/// W-IMPL-GRAVATAR-V2) routed the avatar through the Gravatar CDN: the
/// operator's email was MD5-hashed locally and the hash was sent to
/// `www.gravatar.com/avatar/<hash>`. That request is observable to a
/// third party (Automattic) and lets them correlate the same hash with
/// other Gravatar-using sites — a tracker-shaped data egress that
/// contradicts HealthLog's privacy-first stance and is awkward to defend
/// in App Store Review.
///
/// W-SEC-A drops the network leg entirely. The avatar now renders the
/// initials gradient unconditionally — no MD5, no URL construction, no
/// outbound request, no on-disk PNG. The `email` parameter is retained
/// for source-compatibility with existing call sites (DashboardHeader,
/// ProfileScreen) but is no longer consulted by the renderer.
///
/// ## Fallback ladder (post-W-SEC-A)
///
/// 1. **Initials gradient (eager).** The 2-stop purple gradient + 1-2
///    uppercased letters identifies the operator the moment the surface
///    mounts. Same primitive `AvatarBadge` uses elsewhere in the app.
/// 2. **`"?"` glyph.** When initials are empty, the gradient circle
///    paints a centred question mark — never an unlabeled blob.
///
/// ## Privacy
///
/// No network request is ever issued from this view. No PII (email,
/// email hash, anything derived) leaves the device.
///
/// ## Reduce-motion
///
/// The initials gradient is static — there is no animated cross-fade
/// since the network branch is gone.
struct HLProfileAvatar: View {
    /// Toolbar-default 36pt (≥ 44pt hit-area handled by the wrapping
    /// toolbar `Button`). HIG-compliant.
    let size: CGFloat
    /// **Retained for source-compatibility, no longer consulted.** Earlier
    /// revisions used this to drive the Gravatar GET; v0.6.2 W-SEC-A
    /// dropped the third-party fetch and the parameter is now effectively
    /// `_email: String?`. Kept in the signature so callers (DashboardHeader,
    /// ProfileScreen) don't churn — a follow-up cleanup can rename the
    /// argument label once the avatar surface has settled.
    let email: String?
    /// 1-2 letters rendered in the initials-fallback layer. Pass an empty
    /// string to render `"?"`.
    let initials: String
    /// **v0.8.0 W11.** Resolved self-hosted avatar image, or `nil` to render
    /// the initials monogram. The caller (`AvatarStore`) fetches the bytes
    /// through the authenticated, cert-pinned `APIClient` and hands the
    /// decoded `Image` here — this view never issues a network request.
    let image: Image?

    init(size: CGFloat = 36, email: String?, initials: String, image: Image? = nil) {
        self.size = size
        self.email = email
        self.initials = initials
        self.image = image
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(HLColor.separator.opacity(0.4), lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            image
                .resizable()
                .scaledToFill()
        } else {
            initialsLayer
        }
    }

    private var initialsLayer: some View {
        // v0.6.1 mono refresh — see AvatarBadge for the matching change.
        HLSurface.tertiary
            .overlay {
                // Intentional fixed size:
                // Initials must scale with the avatar diameter (`size`),
                // not Dynamic Type — otherwise letters overflow the circle.
                Text(renderedInitials)
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(HLText.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .allowsTightening(true)
            }
    }

    private var renderedInitials: String {
        let trimmed = initials.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : trimmed
    }
}

#Preview("HLProfileAvatar — sizes & states") {
    HStack(spacing: HLSpace.lg) {
        HLProfileAvatar(size: 36, email: nil, initials: "AF")
        HLProfileAvatar(size: 36, email: "noone@example.invalid", initials: "M")
        HLProfileAvatar(size: 36, email: nil, initials: "")
        HLProfileAvatar(size: 56, email: nil, initials: "AF")
        HLProfileAvatar(size: 56, email: nil, initials: "AF", image: Image(systemName: "person.crop.circle.fill"))
    }
    .padding()
    .background(HLColor.background)
}
