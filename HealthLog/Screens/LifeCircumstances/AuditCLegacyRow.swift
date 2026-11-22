import SwiftUI

/// The one-word alcohol answer asked before AUDIT-C
/// (`ALCOHOL_PATTERN`), shown in the alcohol section as the web does
/// (`audit-c-panel.tsx`, v1.47.0): "Earlier answer: Weekly", one line on what
/// it is, and a bin that asks before the answer leaves the record.
/// The wording is the server's `records.life.auditC.legacy*`.
struct AuditCLegacyRow: View {
    let revision: AnamnesisFactRevision
    let store: LifeCircumstancesStore
    @Bindable var model: AuditCModel

    /// The answer in this kind's own words (`NONE` reads "I don't drink
    /// alcohol", not a bare "None").
    static func valueLabel(_ revision: AnamnesisFactRevision) -> String {
        guard let value = revision.value else { return "" }
        return String(localized: String.LocalizationValue(AnamnesisFactKind.alcoholPattern.labelKey(for: value)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(verbatim: String(localized: "life.auditC.legacy.label \(Self.valueLabel(revision))"))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("life.auditC.legacy.hint")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("life.auditC.legacy")
                HLDeleteButton(
                    "life.auditC.legacy.remove",
                    form: .icon,
                    action: .confirmed(
                        title: "life.auditC.legacy.removeConfirmTitle",
                        message: "life.auditC.legacy.removeConfirmBody",
                        word: "life.auditC.legacy.remove"
                    ) {
                        model.askLegacyRemoval()
                        await model.removeLegacy(store: store)
                    }
                )
                .disabled(model.isRemovingLegacy)
                .accessibilityIdentifier("life.auditC.legacy.remove")
            }
            if model.isConfirmingLegacyRemoval, let error = model.legacyRemoveError {
                HLFormErrorText(error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
