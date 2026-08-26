import SwiftUI

/// SwiftUI-only iconography for `AIProvider`. Lives in the DesignSystem
/// layer so the data model in `Models/Insight.swift` stays pure
/// `Foundation` and doesn't drag SwiftUI into every consumer of the enum
/// (e.g. tests, Server-DTO encoders).
public extension AIProvider {
    /// Tint used for the provider's icon-chip + chain visualisation.
    ///
    /// **v0.6.1 mono refresh:** every configured provider routes through
    /// `HLText.primary` so the chip stays inside the monochrome key.
    /// Differentiation comes from the SF Symbol per provider, not from a
    /// per-vendor hue.
    var iconTint: Color {
        switch self {
        case .unconfigured: HLText.tertiary
        case .anthropic, .openai, .local, .openaiCompatible: HLText.primary
        }
    }
}
