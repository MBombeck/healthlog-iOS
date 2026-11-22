import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// Top-anchored error banner with optional retry CTA.
///
/// Pattern: any `Store` that exposes `error: HLError?` attaches this banner via
/// ``SwiftUI/View/hlErrorBannerOverlay(error:retry:)``, or, at the older call
/// sites that mount it in their own `.overlay`, pairs that overlay with
/// ``SwiftUI/View/hlReserveErrorBannerSpace(_:)``. Auto-hides when the store
/// clears `error` after a successful refresh.
///
/// **The banner makes room instead of covering.** It used to sit in an
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
///
/// **The error id.** On a 5xx or an unreadable answer the banner names
/// the server's request id in its short form („Fehler-ID 3f9a2c1b“) with a
/// copy button, read from ``RecentFailureLog``. No id, no line: older servers
/// and failures the server never answered show the banner as before.
public struct ErrorBanner: View {
    public let error: HLError?
    public let retry: (() -> Void)?
    private let failureLog: RecentFailureLog

    public init(error: HLError?, retry: (() -> Void)? = nil, failureLog: RecentFailureLog = .shared) {
        self.error = error
        self.retry = retry
        self.failureLog = failureLog
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The id last copied from this banner, so the button can say so.
    @State private var copiedID: String?

    public var body: some View {
        if let error {
            let errorID = failureLog.displayID(for: error)
            let stacked = dynamicTypeSize.isAccessibilitySize
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.sm))
                : AnyLayout(HStackLayout(alignment: .top, spacing: HLSpace.sm))
            layout {
                HStack(alignment: .top, spacing: HLSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(retry == nil ? error.userFacingDescription : error.retryBannerDescription)
                            .font(.hlCaption)
                            .lineLimit(stacked ? nil : 3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: stacked)
                        if let errorID {
                            errorIDButton(errorID)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let retry {
                    Button(action: retry) {
                        retryLabel(stacked: stacked)
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
            .accessibilityValue(accessibilityValue(error, errorID: errorID))
            .accessibilityActions {
                if let errorID {
                    Button("error.id.copy") { copy(errorID) }
                }
            }
        }
    }

    /// Side by side a capsule around one line. Stacked, the button takes the
    /// banner's width and a rounded rectangle that grows with the words: a
    /// capsule around two lines cut into „Erneut" and „versuchen".
    @ViewBuilder
    private func retryLabel(stacked: Bool) -> some View {
        let title = Text("Try again")
            .font(.hlCaption.weight(.semibold))
            .padding(.horizontal, HLSpace.sm)
            .padding(.vertical, HLSpace.xs)
        if stacked {
            title
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: HLHitTarget.minimum)
                .background(
                    Color.white.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous)
                )
                .contentShape(Rectangle())
        } else {
            title
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
        }
    }

    /// Small and secondary: the id is for a support conversation, not the
    /// headline. The whole line is the button, at least 44 pt tall.
    private func errorIDButton(_ errorID: String) -> some View {
        Button {
            copy(errorID)
        } label: {
            HStack(spacing: HLSpace.xs) {
                Text("error.id.label")
                    .font(.hlCaption2)
                Text(verbatim: ServerErrorID.short(errorID))
                    .font(.hlCaption2.monospaced())
                Image(systemName: copiedID == errorID ? "checkmark" : "doc.on.doc")
                    .font(.hlCaption2)
                    .accessibilityHidden(true)
            }
            .opacity(0.9)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("error.id.copy"))
        .accessibilityIdentifier("hl.errorBanner.errorID")
    }

    /// The full id goes on the clipboard; the operator's log search takes it
    /// as well as the short form.
    private func copy(_ errorID: String) {
        #if canImport(UIKit)
            UIPasteboard.general.string = errorID
        #endif
        copiedID = errorID
    }

    private func accessibilityValue(_ error: HLError, errorID: String?) -> String {
        guard let errorID else { return error.userFacingDescription }
        let idLabel = String(localized: "error.id.label")
        return "\(error.userFacingDescription), \(idLabel) \(ServerErrorID.short(errorID))"
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
    /// **An inset, not an overlay.** The name is kept so the call sites
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

    /// **Room for a banner that is mounted as an overlay at the call site.**
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
    /// The copy carries a retry button like the overlays do (`withRetry`),
    /// so the band is as high as the banner drawn over it: at the
    /// accessibility sizes the button stands on its own line, and a band
    /// without it let the banner cover the first row.
    ///
    /// Must sit *inside* (before) the `.overlay`, so the overlay's own safe
    /// area does not include the reserved band and the banner is drawn over it.
    func hlReserveErrorBannerSpace(_ error: HLError?, withRetry: Bool = true) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ErrorBanner(error: error, retry: withRetry ? {} : nil)
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
