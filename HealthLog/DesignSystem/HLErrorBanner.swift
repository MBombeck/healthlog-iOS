import SwiftUI

/// Top-anchored error banner with optional retry CTA.
///
/// Pattern: any `Store` that exposes `error: HLError?` should attach this
/// banner via `.overlay(alignment: .top)` so the error becomes immediately
/// visible without disturbing the loaded content underneath. Auto-hides
/// when the store clears `error` after a successful refresh.
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

    public var body: some View {
        if let error {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(error.userFacingDescription)
                    .font(.hlCaption)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    func hlErrorBannerOverlay(error: HLError?, retry: (() -> Void)? = nil) -> some View {
        overlay(alignment: .top) {
            ErrorBanner(error: error, retry: retry)
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
