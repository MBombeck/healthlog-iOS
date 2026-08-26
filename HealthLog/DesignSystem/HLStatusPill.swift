import SwiftUI

/// 3-state status pill mirroring web `IntegrationStatusPill`
/// (`src/components/settings/integration-status-pill.tsx:69-135`).
///
/// Used in Settings sub-screens (Integrationen, KI-Auswertungen, API, About)
/// next to a card title to communicate connection state at a glance.
///
/// **Visual contract:**
///
/// - `.connected` — checkmark + label, `statusOK` fill at 15 % alpha,
///   `statusOK` foreground (mirrors web's `text-dracula-green`).
/// - `.error` — triangle + label, `statusBad` fill at 15 % alpha, `statusBad`
///   foreground (mirrors web's `text-destructive`).
/// - `.disconnected` — slash + label, neutral outline + `textSecondary`
///   foreground (mirrors web's bordered outline state).
///
/// Lives next to but distinct from `HLBadge`: the badge is a generic chip,
/// the status pill is specifically the 3-state integration / configuration
/// affordance used in Settings cards.
public struct HLStatusPill: View {
    public enum State: Equatable, Sendable {
        case connected(label: String)
        case error(label: String)
        case disconnected(label: String)
        case unknown(label: String)
    }

    private let state: State

    public init(_ state: State) {
        self.state = state
    }

    /// Convenience: connected with a default localized label.
    public static let connected = HLStatusPill(.connected(label: String(localized: "Connected")))
    /// Convenience: error with a default localized label.
    public static let error = HLStatusPill(.error(label: String(localized: "Error")))
    /// Convenience: disconnected with a default localized label.
    public static let disconnected = HLStatusPill(.disconnected(label: String(localized: "Not connected")))

    public var body: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: symbol)
                .font(.hlCaption2.weight(.semibold))
            Text(label)
                .font(.hlCaption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xs)
        .background(background)
        .overlay(border)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        switch state {
        case let .connected(label): label
        case let .error(label): label
        case let .disconnected(label): label
        case let .unknown(label): label
        }
    }

    private var symbol: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .disconnected: "circle.slash"
        case .unknown: "questionmark.circle"
        }
    }

    private var foreground: Color {
        switch state {
        case .connected: HLColor.statusOK
        case .error: HLColor.statusBad
        case .disconnected: HLText.secondary
        case .unknown: HLText.tertiary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .connected: Capsule().fill(HLColor.statusOK.opacity(0.15))
        case .error: Capsule().fill(HLColor.statusBad.opacity(0.15))
        case .disconnected: Capsule().fill(Color.clear)
        case .unknown: Capsule().fill(HLText.tertiary.opacity(0.1))
        }
    }

    @ViewBuilder
    private var border: some View {
        switch state {
        case .disconnected:
            Capsule().stroke(HLColor.separator, lineWidth: 0.5)
        default:
            Capsule().stroke(Color.clear, lineWidth: 0)
        }
    }
}

#Preview("HLStatusPill") {
    VStack(alignment: .leading, spacing: HLSpace.sm) {
        HLStatusPill(.connected(label: "Verbunden"))
        HLStatusPill(.error(label: "Token abgelaufen"))
        HLStatusPill(.disconnected(label: "Nicht verbunden"))
        HLStatusPill(.unknown(label: "Wird geprüft …"))
    }
    .padding()
    .background(HLColor.background)
}
