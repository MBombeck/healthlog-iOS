import SwiftUI

/// Top-anchored error banner with optional retry CTA.
///
/// Pattern: any `Store` that exposes `error: HLError?` attaches this banner via
/// ``SwiftUI/View/hlErrorBannerOverlay(error:retry:)``, or, at the older call
/// sites that mount it in their own `.overlay`, pairs that overlay with
/// ``SwiftUI/View/hlReserveErrorBannerSpace(_:)``. Auto-hides when the store
/// clears `error` after a successful refresh.
///
/// **K1 — the banner makes room instead of covering.** It used to sit in an
/// `.overlay(alignment: .top)`, on top of the first card. In a real failure —
/// a refresh that fails offline while the cached list stays on screen — that
/// hid exactly what the user was looking at (H2: the medication name on the
/// detail screen, the first Settings row). The content now starts below the
/// banner and still scrolls: the shared modifier mounts it as a top safe-area
/// inset, and the call-site overlays reserve its height the same way.
///
/// At accessibility text sizes the retry button moves below the message: side
/// by side, H2 photographed „Daten konn-ten nicht…" and „Erneut versu-chen"
/// broken inside the capsule.
///
/// Audit ref: `audit-v021/ux-hig.md` C5 — silent error swallowing on
/// Charts / Insights / Medications / Mood / Achievements.
public struct ErrorBanner: View {
    public let error: HLError?
    public let retry: (() -> Void)?

    public init(error: HLError?, retry: (() -> Void)? = nil) {
        self.error = error
        self.retry = retry
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public var body: some View {
        if let error {
            let stacked = dynamicTypeSize.isAccessibilitySize
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.sm))
                : AnyLayout(HStackLayout(alignment: .top, spacing: HLSpace.sm))
            layout {
                HStack(alignment: .top, spacing: HLSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(error.userFacingDescription)
                        .font(.hlCaption)
                        .lineLimit(stacked ? nil : 3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: stacked)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let retry {
                    Button(action: retry) {
                        Text("Try again")
                            .font(.hlCaption.weight(.semibold))
                            .padding(.horizontal, HLSpace.sm)
                            .padding(.vertical, HLSpace.xs)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Try again"))
                    .accessibilityHint(Text("Reloads the data from the server."))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                    .fill(HLColor.statusBad)
            )
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hl.errorBanner")
            .accessibilityLabel(Text("Error"))
            .accessibilityValue(Text(error.userFacingDescription))
        }
    }
}

public extension View {
    /// Top-anchored `ErrorBanner` overlay **with the animation driver baked
    /// in** — v0.12 W3-3.
    ///
    /// `ErrorBanner` already declares a `.transition(.move(edge:.top)…)`, but
    /// a transition only plays if the *mount* is wrapped in an `.animation(_,
    /// value:)` whose value changes when the banner appears/disappears.
    /// Every call-site previously attached the raw banner via
    /// `.overlay(alignment:.top){ ErrorBanner(error:…) }` with **no** such
    /// driver, so the banner popped in/out instantly (correct pattern lives
    /// at `RootView.swift` — a top-level `.animation(.easeInOut, value:)`).
    /// This helper folds the overlay + the 0.3s ease driver into one modifier
    /// so the banner slides instead of pops, and so the fix can't drift
    /// again at the next mount-site.
    ///
    /// Reduce-motion: `.animation(_, value:)` on a `.move`+`.opacity`
    /// transition is governed by the system Reduce-Motion setting at the
    /// transition layer (SwiftUI substitutes a cross-fade / cut when motion
    /// is reduced), so no explicit `reduceMotion` branch is required here.
    ///
    /// **K1 — an inset, not an overlay.** The name is kept so the call sites
    /// stay put, but the banner is mounted with `safeAreaInset(edge: .top)`:
    /// the content below it moves down by the banner's height instead of
    /// being covered. A scroll view keeps scrolling underneath, as it does
    /// under the navigation bar. With no error the inset is empty and takes
    /// no space.
    func hlErrorBannerOverlay(error: HLError?, retry: (() -> Void)? = nil) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ErrorBanner(error: error, retry: retry)
                .padding(.bottom, error == nil ? 0 : HLSpace.sm)
        }
        .animation(.easeInOut(duration: 0.3), value: error)
    }

    /// **K1 — room for a banner that is mounted as an overlay at the call site.**
    ///
    /// Ten screens attach `ErrorBanner` themselves in an `.overlay(alignment:
    /// .top)`. That overlay is a counted presentation in the Phase-06 PHI
    /// presentation inventory, whose identity includes the presenter's kind, so
    /// turning it into an inset at the call site would be a census change, not
    /// a layout fix. Those sites keep the overlay and put this modifier directly
    /// before it: a hidden copy of the same banner as a top safe-area inset, so
    /// the content starts below the banner's height and the visible overlay
    /// lands exactly on that reserved band. Hidden, the copy is neither drawn
    /// nor read by VoiceOver; with no error it takes no space.
    ///
    /// Must sit *inside* (before) the `.overlay`, so the overlay's own safe
    /// area does not include the reserved band and the banner is drawn over it.
    func hlReserveErrorBannerSpace(_ error: HLError?) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ErrorBanner(error: error)
                .hidden()
                .padding(.bottom, error == nil ? 0 : HLSpace.sm)
        }
        .animation(.easeInOut(duration: 0.3), value: error)
    }
}

// `HLError.userFacingDescription` lives in `Util/HLError.swift` so the
// translation layer is co-located with the error type and unit-testable
// without importing the DesignSystem module.

#if DEBUG
    #Preview("Error + retry") {
        ZStack(alignment: .top) {
            HLColor.background.ignoresSafeArea()
            ErrorBanner(error: .offline) { /* retry */ }
        }
    }

    #Preview("Error read-only") {
        ZStack(alignment: .top) {
            HLColor.background.ignoresSafeArea()
            ErrorBanner(error: .server(status: 500, code: "INTERNAL", message: "Konnte nicht laden."))
        }
    }
#endif
