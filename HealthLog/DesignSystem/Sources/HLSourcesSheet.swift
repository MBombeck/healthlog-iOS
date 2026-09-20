import SwiftUI

/// **1.0.3 (App Review 1.4.1) — "Sources & method" sheet.**
///
/// Methodology paragraph (when the topic has one) + the references with a
/// `Link` each (Safari, never an in-app web view — A360-3) + the standing
/// footer. Presentation mirrors `BenchmarkSourceSheet`.
struct HLSourcesSheet: View {
    let topic: MedicalSourceTopic

    private var sources: [MedicalSource] {
        MedicalSourceCatalog.sources(for: topic)
    }

    private var dynamic: [MedicalSourceCatalog.DynamicSource] {
        MedicalSourceCatalog.dynamicSources(for: topic)
    }

    private var methodologyKey: String? {
        MedicalSourceCatalog.methodologyKey(for: topic)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.xl) {
                    if let methodologyKey {
                        methodCard(methodologyKey)
                    }
                    if !sources.isEmpty || !dynamic.isEmpty {
                        referencesCard
                    }
                    if topic.showsHubLink {
                        hubLink
                    }
                    Text("sources.sheet.footer")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.vertical, HLSpace.xl)
            }
            .hlScreenBackground()
            .navigationTitle(Text("sources.sheet.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .hlSheetPresentation(.form)
        .presentationBackground(HLColor.surface)
        .accessibilityIdentifier("sources.sheet.\(topic.accessibilitySuffix)")
    }

    private func methodCard(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("sources.sheet.methodTitle")
            Text(LocalizedStringKey(key))
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.lg)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
    }

    /// **1.0.3 (App Review 1.4.1, audit row 6)** — the way on from the
    /// assistant's own six references into the full catalog. The sheet is a
    /// `NavigationStack`, so this pushes rather than stacking a second sheet.
    /// Only `.aiAssistant` shows it (``MedicalSourceTopic/showsHubLink``).
    private var hubLink: some View {
        NavigationLink {
            MedicalSourcesScreen()
        } label: {
            HStack(spacing: HLSpace.md) {
                Image(systemName: "books.vertical")
                    .font(.hlCallout.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("settings.about.medicalSources")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HLSpace.lg)
        .padding(.vertical, HLSpace.sm)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
        .accessibilityIdentifier("sources.sheet.hubLink")
    }

    private var referencesCard: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            HLSectionLabel("sources.sheet.referencesTitle")
            ForEach(sources) { source in
                HLSourceRow(name: source.name, year: source.year, caveatKey: source.caveatKey, url: source.url)
            }
            ForEach(dynamic) { source in
                HLSourceRow(name: source.name, year: nil, caveatKey: nil, url: source.url)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.lg)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
    }
}

/// One reference: canonical name (verbatim), year, localized caveat, link.
/// Shared by the sheet and the hub.
struct HLSourceRow: View {
    let name: String
    let year: Int?
    let caveatKey: String?
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(alignment: .top, spacing: HLSpace.md) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    HStack(spacing: HLSpace.xs) {
                        Text(verbatim: name)
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.primary)
                        if let year {
                            Text(verbatim: String(year))
                                .font(.hlCaption)
                                .foregroundStyle(HLText.tertiary)
                                .monospacedDigit()
                        }
                    }
                    if let caveatKey {
                        Text(LocalizedStringKey(caveatKey))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            // M1 — a `Text` inside a `Link` label centres its
                            // wrapped lines by default; caveats are prose.
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: HLSpace.sm)
                Image(systemName: "arrow.up.right.square")
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("sources.sheet.openLink"))
        .accessibilityValue(Text(verbatim: name))
        .accessibilityIdentifier("sources.ref.\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}
