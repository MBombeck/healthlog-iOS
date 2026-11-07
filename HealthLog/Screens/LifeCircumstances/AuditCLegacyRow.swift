import SwiftUI

/// **POLISH-C (C7)** — the one-word alcohol answer asked before AUDIT-C
/// (`ALCOHOL_PATTERN`), shown in the alcohol section as the web does
/// (`audit-c-panel.tsx`, v1.47.0): "Earlier answer: Weekly", one line on what
/// it is, and a bin that asks in place before the answer leaves the record.
/// The wording is the server's `records.life.auditC.legacy*`.
struct AuditCLegacyRow: View {
    let revision: AnamnesisFactRevision
    let store: LifeCircumstancesStore
    @Bindable var model: AuditCModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                Button {
                    withHLAnimation(.easeInOut(duration: 0.2)) { model.askLegacyRemoval() }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(HLColor.statusBad)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isRemovingLegacy)
                .accessibilityLabel(Text("life.auditC.legacy.remove"))
                .accessibilityIdentifier("life.auditC.legacy.remove")
            }
            if model.isConfirmingLegacyRemoval {
                confirmation
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("life.auditC.legacy.removeConfirmTitle")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Text("life.auditC.legacy.removeConfirmBody")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.legacyRemoveError {
                HLFormErrorText(error)
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.sm))
                : AnyLayout(HStackLayout(spacing: HLSpace.lg))
            layout {
                Button(role: .destructive) {
                    Task { await model.removeLegacy(store: store) }
                } label: {
                    Text("life.auditC.legacy.remove")
                        .fontWeight(.semibold)
                        .foregroundStyle(HLColor.statusBad)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("life.auditC.legacy.confirm")
                Button {
                    withHLAnimation(.easeInOut(duration: 0.2)) { model.isConfirmingLegacyRemoval = false }
                } label: {
                    Text("Cancel")
                        .foregroundStyle(.tint)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("life.auditC.legacy.cancel")
                if model.isRemovingLegacy {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.hlSubhead)
            .buttonStyle(.plain)
            .disabled(model.isRemovingLegacy)
        }
        .padding(.leading, HLSpace.sm)
    }
}
