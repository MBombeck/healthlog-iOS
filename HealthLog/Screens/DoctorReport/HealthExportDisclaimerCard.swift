import SwiftUI

/// R1 (A360-6 App Store) — shared, user-visible "not a medical document"
/// disclaimer for the health-export surfaces (FHIR export + Doctor Report).
///
/// App Review 1.4.1 / medical-app scrutiny: shipping a structured FHIR export
/// and a "Doctor Report" PDF with no on-screen caveat that the artifact is
/// informational — not validated for clinical decision-making — is the kind of
/// over-claim framing reviewers flag for health apps. The disclaimer previously
/// lived only in a code comment (and, for the local PDF, in the locked footer
/// line). This card surfaces it to the user before they share.
///
/// Reuses the existing `appstore.disclaimer.*` xcstrings keys for the title +
/// the consult-a-doctor line; the focused export caveat carries the
/// not-a-certified-document / not-for-diagnostic-use wording.
struct HealthExportDisclaimerCard: View {
    static let accessibilityIdentifier = "healthExport.disclaimer"

    var body: some View {
        HLSettingsCard(
            icon: "exclamationmark.shield",
            title: "appstore.disclaimer.card_title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("export.disclaimer.not_certified")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("appstore.disclaimer.consult_doctor")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}
