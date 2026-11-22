import SwiftUI

/// Greeting + inline profile-avatar row for the Dashboard.
///
/// It is the dashboard's tab head and stays its own type: the greeting comes
/// from the server, fades while the avatar stays, opens the sync status on a
/// long press and is the static text `dashboard.greeting`. Its line is laid
/// out by the tab header's layout, with the tab header's measures: the same
/// top edge, indent and title line height, the avatar as large as a bar icon
/// button at every text size, and under the greeting in accessibility sizes.
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
/// - U1: the sync slot sits left of the avatar (the transient sync
///   glyph, or since INT-L a calm attention glyph instead of a badge on the
///   avatar), and the sync status panel opens below the row
///   (`DashboardSyncStatus.swift`).
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
    /// Greeting opacity driven by the
    /// Dashboard's scroll-parallax math. The header
    /// reads the live offset from the `@Observable` model itself (instead of
    /// receiving a pre-computed `greetingOpacity` Double from the screen
    /// body), so a scrolled frame invalidates only this small header — not
    /// the whole `DashboardScreen`. `nil` renders at full opacity (previews,
    /// snapshots, future re-use).
    var parallax: DashboardParallaxModel?

    /// Reduce-motion pins the greeting to full opacity (see
    /// `DashboardParallaxMath.greetingOpacity`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hlTabHeaderActionPlacement) private var requestedPlacement
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The inline sync status panel under the greeting. Opened from
    /// the slot glyph or a long-press on the avatar or the greeting; never on
    /// its own.
    @State private var showsSyncStatus = false

    /// The avatar grows with the text like a bar icon button.
    @ScaledMetric(relativeTo: .title3) private var avatarBase: CGFloat = HLLayout.iconButton
    /// The avatar's side in the bar at the standard text size.
    @ScaledMetric(relativeTo: .title3) private var barAvatarBase: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            greetingRow
            if showsSyncStatus {
                DashboardSyncStatusPanel { showsSyncStatus = false }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : HLMotion.spring, value: showsSyncStatus)
        // Keep the self-hosted avatar in sync with the profile's
        // `avatarUrl`. Loads through the authenticated, cert-pinned APIClient
        // (cache-first); a nil URL clears to the initials monogram.
        //
        // Key on `avatarReloadToken`, NOT the bare
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

    @ViewBuilder
    private var greetingRow: some View {
        if avatarPlacement == .bar {
            DashboardHeaderLine(title: salutation) {
                greeting
            } trailing: {
                EmptyView()
            }
            // In a regular width the actions stand in the system bar, like on
            // every tab: the sync slot and the avatar, which stays clear of
            // the greeting's fade. The bar draws no glass around a photo.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    syncAvatar(side: barAvatarSide)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            // In a compact width the avatar stands beside the greeting, so the
            // greeting keeps the top line like every tab's title. It stays
            // outside the fade; the sync glyph and the attention glyph share
            // one slot, see `DashboardSyncStatus.swift`.
            DashboardHeaderLine(title: salutation) {
                greeting
            } trailing: {
                syncAvatar(side: HLIconButton.side(forScaled: avatarBase))
            }
        }
    }

    /// Where the avatar stands, by the tab header's rule.
    private var avatarPlacement: HLTabHeaderActionPlacement {
        requestedPlacement.resolved(sizeClass: sizeClass)
    }

    private var greeting: some View {
        DashboardGreeting(salutation: salutation, date: formattedDate)
            .opacity(greetingOpacity)
            // A long-press on the greeting opens the sync
            // status too, like the one on the avatar. VoiceOver reaches it
            // through the avatar's "Sync-Status anzeigen" action.
            .contextMenu {
                Button {
                    showsSyncStatus.toggle()
                } label: {
                    Label("sync.activity.showStatus", systemImage: "arrow.triangle.2.circlepath")
                }
            }
    }

    private func syncAvatar(side: CGFloat) -> some View {
        DashboardSyncAvatar(showProfile: $showProfile, showsSyncStatus: $showsSyncStatus) {
            HLProfileAvatar(
                size: side,
                email: avatarEmail,
                initials: avatarInitials,
                image: avatarStore.image
            )
        }
    }

    /// The avatar as tall as a bar symbol button's circle, growing with the
    /// text up to the icon button's side.
    private var barAvatarSide: CGFloat {
        min(barAvatarBase, HLIconButton.side(forScaled: avatarBase))
    }

    /// Composite reload key: `<userId>|<avatarUrl>`. Changes both when the
    /// avatar URL flips (re-upload / removal) and when the authenticated
    /// identity changes (logout→re-login), so the `.task` above re-fetches on
    /// reauth even when the server hands back the same `avatarUrl`.
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
        // (was a raw string) and ALSO fires on an empty server salutation,
        // which would render a blank `.hlLargeTitle` row (reserved vertical
        // space, no text).
        guard let server = store.summary?.greeting.salutation, !server.isEmpty else {
            return String(localized: "Hi", comment: "Dashboard greeting fallback when the server sends none")
        }
        return server
    }

    private var formattedDate: String {
        // Locale-respektiert (Spec §8 Localization). System-Locale wird automatisch verwendet.
        HLDateFormat.weekdayDayMonth(store.summary?.greeting.date ?? .now)
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
        var user: User?
        if case let .authenticated(signedIn) = authStore.phase { user = signedIn }
        return UserProfile.initials(profile: settings.profile, user: user)
    }
}

/// The greeting and the date under it, set like a tab header's title and line.
struct DashboardGreeting: View {
    let salutation: String
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: HLTabHeaderMetrics.subtitleGap) {
            Text(salutation)
                .font(.hlLargeTitle)
                .foregroundStyle(HLText.primary)
                .accessibilityIdentifier("dashboard.greeting")
            Text(date)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
        }
    }
}

/// The dashboard's head line, laid out by the tab header's layout, so title
/// edge, title line and the place of what stands at the trailing edge match
/// every tab built on ``HLTabHeader``.
struct DashboardHeaderLine<Greeting: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let greeting: Greeting
    @ViewBuilder let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let longestWord = HLTabHeaderTitle.words(of: title)
            .map { HLTabHeaderMetrics.naturalWidth(of: $0, typeSize: dynamicTypeSize) }
            .max() ?? 0
        let hasTrailing = Trailing.self != EmptyView.self
        HLTabHeaderLayout(
            alwaysStacked: dynamicTypeSize.isAccessibilitySize,
            longestWordWidth: longestWord,
            hasActions: hasTrailing
        ) {
            greeting
                .frame(maxWidth: .infinity, minHeight: HLTabHeaderMetrics.titleLineHeight, alignment: .topLeading)
            if hasTrailing {
                HStack(spacing: HLTabHeaderMetrics.actionGap) {
                    trailing
                }
            }
        }
    }
}
