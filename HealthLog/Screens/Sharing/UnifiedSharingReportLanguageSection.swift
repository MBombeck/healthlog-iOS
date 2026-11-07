import SwiftUI

/// **L10N-REPORT (1.5) — the report language, under "Advanced".**
///
/// Few people print for a doctor in another language, so the choice is one
/// quiet centred text link under the PDF's practice card that unfolds the
/// picker beneath it (the same pattern as the access headers in onboarding).
/// The report starts in the interface language; a choice that differs from it
/// keeps the section open, so the reader sees what the PDF will be written in.
struct UnifiedSharingReportLanguageSection: View {
    @Bindable var store: UnifiedSharingStore

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Label beside the value; at an accessibility text size, above it, so
    /// neither breaks mid-word.
    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xs))
            : AnyLayout(HStackLayout(spacing: HLSpace.sm))
    }

    var body: some View {
        VStack(spacing: HLSpace.md) {
            advancedToggle
            if isExpanded {
                HLSettingsCard {
                    // A menu picker shows only its value; the row names it.
                    rowLayout {
                        Text("sharing.unified.reportLanguage.label")
                            .font(.hlBody)
                            .foregroundStyle(HLText.primary)
                            .accessibilityHidden(true)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: HLSpace.sm) }
                        Picker(selection: $store.reportLanguage) {
                            ForEach(ReportLocale.allCases, id: \.self) { language in
                                Text(verbatim: language.endonym).tag(language)
                            }
                        } label: {
                            Text("sharing.unified.reportLanguage.label")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel(Text("sharing.unified.reportLanguage.label"))
                        .accessibilityIdentifier("sharing.unified.reportLanguage")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            if store.reportLanguage != ReportLocale(AppLanguage.current) { isExpanded = true }
        }
    }

    private var advancedToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: HLSpace.xs) {
                Text("Advanced")
                    .font(.hlSubhead.weight(.semibold))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.hlIcon(HLIconSize.sm))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(HLText.secondary)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sharing.unified.advanced")
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
    }
}
