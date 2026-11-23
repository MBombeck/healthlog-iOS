import SwiftUI

/// The connection state of an integration or a configuration, at a glance.
///
/// It is a thin wrapper around ``HLBadge``: the state picks the symbol and
/// the tone, the badge draws them, so a status pill and a badge of the same
/// meaning look the same.
///
/// - `.connected`: checkmark, success tone.
/// - `.error`: triangle, critical tone.
/// - `.disconnected`: slash, neutral tone.
/// - `.unknown`: question mark, neutral tone.
/// - `.warning`: clock, warning tone. A connection that works but is limited
///   or delayed (`health.state` `limited` / `degraded`), which is neither
///   healthy nor broken.
///
/// In a card head it is a capsule; in a row or next to a value it takes
/// `form: .text`.
public struct HLStatusPill: View {
    public enum State: Equatable, Sendable {
        case connected(label: String)
        case error(label: String)
        case disconnected(label: String)
        case unknown(label: String)
        case warning(label: String)
    }

    private let state: State
    private let form: HLBadge.Form

    public init(_ state: State, form: HLBadge.Form = .capsule) {
        self.state = state
        self.form = form
    }

    /// Convenience: connected with a default localized label.
    public static let connected = HLStatusPill(.connected(label: String(localized: "Connected")))
    /// Convenience: error with a default localized label.
    public static let error = HLStatusPill(.error(label: String(localized: "Error")))
    /// Convenience: disconnected with a default localized label.
    public static let disconnected = HLStatusPill(.disconnected(label: String(localized: "Not connected")))

    public var body: some View {
        HLBadge(label, icon: symbol, tone: tone, form: form)
    }

    var label: String {
        switch state {
        case let .connected(label): label
        case let .error(label): label
        case let .disconnected(label): label
        case let .unknown(label): label
        case let .warning(label): label
        }
    }

    var symbol: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .disconnected: "circle.slash"
        case .unknown: "questionmark.circle"
        case .warning: "clock.badge.exclamationmark"
        }
    }

    var tone: HLBadge.Tone {
        switch state {
        case .connected: .success
        case .error: .critical
        case .disconnected, .unknown: .neutral
        case .warning: .warning
        }
    }
}

#Preview("HLStatusPill") {
    VStack(alignment: .leading, spacing: HLSpace.sm) {
        HLStatusPill(.connected(label: "Verbunden"))
        HLStatusPill(.error(label: "Token abgelaufen"))
        HLStatusPill(.disconnected(label: "Nicht verbunden"))
        HLStatusPill(.unknown(label: "Wird geprüft …"))
        HLStatusPill(.warning(label: "Verzögert"))
        HLStatusPill(.connected(label: "Verbunden"), form: .text)
    }
    .padding()
    .background(HLColor.background)
}
