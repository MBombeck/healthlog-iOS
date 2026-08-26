import SwiftUI

/// Top-of-Dashboard banner that surfaces when HealthKit is not (fully) connected.
///
/// **Why it exists** (F1-Diagnose §R1):
/// User mit ältern Onboarded-Accounts können in einem State landen, in dem
/// HealthLog keinen HK-Read mehr hat (Permission abgelaufen, Type abgelehnt,
/// oder "Später"-Tap im Onboarding). Es gab bisher keinen In-App-Pfad,
/// das zu reparieren. Dieser Banner ist der Recovery-Affordance.
///
/// Surface-Rules (siehe `HKReadinessStore.shouldShowDashboardBanner`):
/// - `.notRequested` → "Apple Health nicht verbunden" + Connect-CTA.
/// - `.partiallyGranted` → "Apple Health nicht verbunden" + Connect-CTA
///   (re-prompted für die fehlenden Types).
/// - `.denied` → "Apple Health nicht verbunden" + Connect-CTA (HK system sheet
///   öffnet nach explizitem Denied nicht mehr; der Tap führt den User implizit
///   zum re-request, das System reagiert dann durch Aufruf der Einstellungen).
/// - `.fullyGranted` / `.unknown` → Banner versteckt.
///
/// Dismissal: "Nicht jetzt"-Tap setzt einen 24h-Cooldown im Store; der Banner
/// erscheint danach automatisch wieder, bis der User wirklich verbindet.
public struct HealthKitConnectBanner: View {
    @Environment(HKReadinessStore.self) private var readiness
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        if readiness.shouldShowDashboardBanner {
            HLCard(style: .elevated) {
                HStack(alignment: .top, spacing: HLSpace.md) {
                    icon
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        Text(title)
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: HLSpace.sm) {
                            connectButton
                            dismissButton
                        }
                        .padding(.top, HLSpace.xs)
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text("Apple Health not connected. HealthLog cannot read your Apple Health data. Tap to connect.")
            )
            .accessibilityHint(Text("Tap to open the system permission dialog"))
            .accessibilityAddTraits(.isButton)
            .transition(transition)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: readiness.shouldShowDashboardBanner)
        }
    }

    private var transition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top))
    }

    private var icon: some View {
        // v0.5.5.2 (W-IMPL-UI-COLOR-MOOD): operator real-device feedback
        // v0.5.5.1 — der HK-Connect-Prompt las sich als Error-Banner
        // ("rote Felder"), war aber als Opt-in-Einladung gedacht. Wir
        // tönen das Heart-Glyph + die Chip-Fläche jetzt im User-Accent
        // (`.tint`-Env am Scene-Root), damit die Einladung semantisch
        // als positive Affordance liest.
        Image(systemName: "heart.fill")
            // Audit-01 M1 — off-scale 18pt pulled onto `HLIconSize.lg` (20pt).
            .font(.hlIcon(HLIconSize.lg, weight: .bold))
            .foregroundStyle(.tint)
            .frame(width: 36, height: 36)
            .background(.tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
            .accessibilityHidden(true)
    }

    private var title: String {
        String(localized: "Apple Health not connected")
    }

    private var subtitle: String {
        switch readiness.state {
        case let .partiallyGranted(missing):
            // Pluralised — N=1 reads natürlich ("1 Typ fehlt"), N>1 nicht ("3 Typen fehlen").
            if missing.count == 1 {
                String(localized: "HealthLog has no access to one data type. Tap to connect.")
            } else {
                String(localized: "HealthLog has no access to \(missing.count) data types. Tap to connect.")
            }
        case .denied:
            String(localized: "You declined Apple Health. Tap to allow it in iPhone Settings.")
        default:
            String(localized: "HealthLog can't read your Apple Health data. Tap to connect.")
        }
    }

    private var connectButton: some View {
        // v0.5.2-A8: `.foregroundStyle(.tint)` reads the inherited `.tint(...)`
        // bound at the scene root in `HealthLogApp.body`, so the connect
        // affordance picks up the user's HLTint pick instead of staying
        // pinned to brand Dracula-Purple regardless of the accent picker.
        // ProgressView omits an explicit `.tint(...)` for the same reason —
        // SwiftUI infers it from the env value via the parent style.
        Button {
            Task { await readiness.requestAuthorization() }
        } label: {
            HStack(spacing: HLSpace.xs) {
                if readiness.isRequestingAuthorization {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Text(connectButtonLabel)
                    .font(.hlSubhead.weight(.semibold))
            }
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.connectButtonIdentifier)
        .disabled(readiness.isRequestingAuthorization)
    }

    private var connectButtonLabel: String {
        if case .denied = readiness.state {
            return String(localized: "Open settings")
        }
        return String(localized: "Connect")
    }

    private var dismissButton: some View {
        Button {
            readiness.dismissBanner()
        } label: {
            Text(String(localized: "Not now"))
                .font(.hlSubhead)
                .foregroundStyle(HLText.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.dismissButtonIdentifier)
    }

    public static let connectButtonIdentifier = "healthkitConnectBanner.connectButton"
    public static let dismissButtonIdentifier = "healthkitConnectBanner.dismissButton"
}
