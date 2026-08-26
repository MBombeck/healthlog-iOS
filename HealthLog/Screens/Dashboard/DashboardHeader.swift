import SwiftUI

/// **v0.5.4.1.** Greeting + inline profile-avatar row for the Dashboard.
///
/// Extracted into its own file so `DashboardScreen.swift` stays under the
/// 600-line file-length lint budget after the avatar moved out of the
/// `topBarTrailing` toolbar slot and into this header row.
///
/// **Layout rules:**
/// - Left: greeting (`Hi, <salutation>`) on the first line, locale-
///   formatted full date on the second.
/// - Right: 44pt `HLProfileAvatar` aligned to the centre of the row.
///   Tap flips the parent's `showProfile` binding which drives the
///   `navigationDestination` push to `ProfileScreen` (see
///   `DashboardProfileToolbar.swift`).
///
/// **Why a binding instead of a router?** Keeping the push declarative
/// at the call site means SwiftUI's pop-the-navigation-stack affordances
/// (back swipe, back button) flip the same binding back to `false`
/// without an extra observer.
struct DashboardHeader: View {
    @Environment(DashboardStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(AuthStore.self) private var authStore
    @Environment(AvatarStore.self) private var avatarStore
    @Binding var showProfile: Bool
    /// W-IMPL-MOTION-POLISH (v0.5.5.1) — greeting opacity driven by the
    /// Dashboard's scroll-parallax math. v0.14.8 AUDIT-HOME M11: the header
    /// reads the live offset from the `@Observable` model itself (instead of
    /// receiving a pre-computed `greetingOpacity` Double from the screen
    /// body), so a scrolled frame invalidates only this small header — not
    /// the whole `DashboardScreen`. `nil` renders at full opacity (previews,
    /// snapshots, future re-use).
    var parallax: DashboardParallaxModel?

    /// Reduce-motion pins the greeting to full opacity (see
    /// `DashboardParallaxMath.greetingOpacity`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(salutation)
                    .font(.hlLargeTitle)
                    .foregroundStyle(HLText.primary)
                    .accessibilityIdentifier("dashboard.greeting")
                Text(formattedDate)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
            .opacity(greetingOpacity)
            Spacer(minLength: HLSpace.sm)
            // (avatar intentionally outside the fade — only the greeting
            // dims while scrolling)
            Button {
                showProfile = true
            } label: {
                HLProfileAvatar(
                    size: 44,
                    email: avatarEmail,
                    initials: avatarInitials,
                    image: avatarStore.image
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("dashboard.toolbar.profile.accessibilityLabel")))
            .accessibilityIdentifier("dashboard.profile.avatar")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // v0.8.0 W11 — keep the self-hosted avatar in sync with the profile's
        // `avatarUrl`. Loads through the authenticated, cert-pinned APIClient
        // (cache-first); a nil URL clears to the initials monogram.
        //
        // v0.14.1 (#138) — key on `avatarReloadToken`, NOT the bare
        // `avatarUrl`. After a logout→re-login as the SAME user the server
        // returns the identical `avatarUrl`; keying on the URL alone meant the
        // `.task` id was unchanged, so SwiftUI never re-ran `load` and (because
        // `clearOnLogout()` wiped the in-memory bytes) the avatar stayed blank.
        // Folding the authenticated user id into the token flips the id across
        // the sign-out/in cycle, forcing a re-fetch.
        .task(id: avatarReloadToken) {
            await avatarStore.load(avatarURLPath: settings.profile?.avatarUrl)
        }
    }

    /// Composite reload key: `<userId>|<avatarUrl>`. Changes both when the
    /// avatar URL flips (re-upload / removal) and when the authenticated
    /// identity changes (logout→re-login), so the `.task` above re-fetches on
    /// reauth even when the server hands back the same `avatarUrl` (#138).
    private var avatarReloadToken: String {
        let urlPart = settings.profile?.avatarUrl ?? ""
        let idPart: String = {
            if case let .authenticated(user) = authStore.phase { return user.id }
            return ""
        }()
        return "\(idPart)|\(urlPart)"
    }

    /// Live parallax fade for the greeting block. Reading
    /// `parallax?.scrollOffset` here scopes the per-frame Observation
    /// invalidation to this header view.
    private var greetingOpacity: Double {
        guard let parallax else { return 1.0 }
        return DashboardParallaxMath.greetingOpacity(
            for: parallax.scrollOffset,
            reduceMotion: reduceMotion
        )
    }

    private var salutation: String {
        // v0.14.8 AUDIT-HOME L13a/M9 — the fallback is now a catalog key
        // (was a raw string) and ALSO fires on an empty server salutation:
        // the standalone-mode summary builder stamps `salutation: ""`, which
        // previously rendered a blank `.hlLargeTitle` row (reserved vertical
        // space, no text).
        guard let server = store.summary?.greeting.salutation, !server.isEmpty else {
            return String(localized: "Hi", comment: "Dashboard greeting fallback when the server sends none")
        }
        return server
    }

    private var formattedDate: String {
        // Locale-respektiert (Spec §8 Localization). System-Locale wird automatisch verwendet.
        (store.summary?.greeting.date ?? .now)
            .formatted(.dateTime.weekday(.wide).day().month())
    }

    /// Email source for the avatar's Gravatar lookup. Mirrors the ladder
    /// `DashboardProfileToolbarModifier` used pre-v0.5.4.1: server profile
    /// email first, fall through to the cold-launch authenticated-user
    /// email so the avatar paints before the profile round-trip lands.
    private var avatarEmail: String? {
        if let email = settings.profile?.email, !email.isEmpty {
            return email
        }
        if case let .authenticated(user) = authStore.phase, let email = user.email, !email.isEmpty {
            return email
        }
        return nil
    }

    private var avatarInitials: String {
        if let profile = settings.profile {
            return profile.avatarInitials
        }
        if case let .authenticated(user) = authStore.phase {
            return user.avatarInitials
        }
        return "?"
    }
}
