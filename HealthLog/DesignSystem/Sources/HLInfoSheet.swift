import SwiftUI

/// **1.4 B2 — what a screen's (i) explains.**
///
/// One value per screen, built by the screen: what the screen shows ("Was ist
/// das?"), one section per card that has its own method or terms, the
/// references behind all of it, and the public guide to read more. The
/// "Sources & method" sheet of 1.0.3 (App Review 1.4.1) is the same sheet with
/// a single method section, see ``sources(_:)``.
struct HLInfoContent: Equatable {
    /// One explained card or term: a title and its paragraphs, already
    /// localized. A section with a ``topic`` adds that topic's references to
    /// the sheet's list.
    struct Section: Equatable, Identifiable {
        let title: String
        let paragraphs: [String]
        var topic: MedicalSourceTopic?

        var id: String {
            title
        }

        /// A card whose method the citation catalog already explains: the
        /// topic's method title (or the card's own `title`), an optional
        /// `lead` paragraph in the screen's words, then the method text. `nil`
        /// for a topic without a method.
        static func method(topic: MedicalSourceTopic, title: String? = nil, lead: String? = nil) -> Section? {
            guard let key = MedicalSourceCatalog.methodologyKey(for: topic) else { return nil }
            let titleKey = key.replacingOccurrences(of: "sources.method.", with: "sources.methodTitle.")
            return Section(
                title: title ?? String(localized: String.LocalizationValue(titleKey)),
                paragraphs: [lead, String(localized: String.LocalizationValue(key))].compactMap(\.self),
                topic: topic
            )
        }
    }

    /// The sheet's navigation title, usually the screen's own title.
    let title: String
    /// Accessibility identifier of the sheet's page.
    let identifier: String
    /// "Was ist das?": one plain paragraph about the screen or the metric.
    var about: String?
    /// The citation topic behind ``about``. Its references lead the list.
    var topic: MedicalSourceTopic?
    var sections: [Section] = []
    /// A ``HLLearnLinks`` concept for the "Mehr erfahren" row.
    var learnMoreConcept: String?

    /// Every topic whose references the sheet lists, in order, once each.
    var referenceTopics: [MedicalSourceTopic] {
        var seen: [MedicalSourceTopic] = []
        for topic in [topic] + sections.map(\.topic) {
            if let topic, !seen.contains(topic) { seen.append(topic) }
        }
        return seen
    }

    var references: [MedicalSource] {
        var seen: Set<MedicalSourceID> = []
        return referenceTopics
            .flatMap { MedicalSourceCatalog.sources(for: $0) }
            .filter { seen.insert($0.id).inserted }
    }

    var dynamicReferences: [MedicalSourceCatalog.DynamicSource] {
        referenceTopics.flatMap { MedicalSourceCatalog.dynamicSources(for: $0) }
    }

    /// Medical content carries the standing "general information, not an
    /// assessment of you" footer; a glossary of app terms does not.
    var isMedical: Bool {
        !referenceTopics.isEmpty
    }

    var showsHubLink: Bool {
        referenceTopics.contains(where: \.showsHubLink)
    }

    /// Nothing to explain: the (i) renders nothing rather than an empty sheet.
    var isEmpty: Bool {
        about == nil && sections.isEmpty && references.isEmpty && dynamicReferences.isEmpty
            && learnMoreConcept.flatMap(HLLearnLinks.guide(forConcept:)) == nil
    }

    /// The 1.0.3 "Sources & method" sheet behind ``HLSourcesLink``: the
    /// topic's method under "So wird das berechnet", then its references.
    static func sources(_ topic: MedicalSourceTopic) -> HLInfoContent {
        let method = MedicalSourceCatalog.methodologyKey(for: topic).map { key in
            Section(
                title: String(localized: "sources.sheet.methodTitle"),
                paragraphs: [String(localized: String.LocalizationValue(key))]
            )
        }
        return HLInfoContent(
            title: String(localized: "sources.sheet.title"),
            identifier: "sources.sheet.\(topic.accessibilitySuffix)",
            topic: topic,
            sections: method.map { [$0] } ?? []
        )
    }
}

// MARK: - Presentation

private struct HLSheetStackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` inside a sheet's own `NavigationStack`: an (i) or a "Sources"
    /// control there pushes its page into that stack instead of stacking a
    /// second sheet on top of the sheet (HIG, Sheets).
    var hlInsideSheetStack: Bool {
        get { self[HLSheetStackKey.self] }
        set { self[HLSheetStackKey.self] = newValue }
    }
}

extension View {
    /// Marks the content of a sheet's `NavigationStack`. Apply it inside the
    /// stack, on the root view: every ``HLInfoButton`` and ``HLSourcesLink``
    /// below then pushes instead of presenting.
    func hlSheetStack() -> some View {
        environment(\.hlInsideSheetStack, true)
    }
}

/// The info sheet: ``HLInfoPage`` in its own stack, with "Fertig".
struct HLInfoSheet: View {
    let content: HLInfoContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HLInfoPage(content: content)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .hlSheetPresentation(.form)
        .presentationBackground(HLColor.surface)
    }
}

/// The page itself: sheet content, or pushed as is into a sheet's own stack.
/// Links open in Safari, never in an in-app web view (A360-3).
struct HLInfoPage: View {
    let content: HLInfoContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                if let about = content.about {
                    sectionCard(title: String(localized: "info.sheet.about"), paragraphs: [about])
                }
                ForEach(content.sections) { section in
                    sectionCard(title: section.title, paragraphs: section.paragraphs)
                }
                if !content.references.isEmpty || !content.dynamicReferences.isEmpty {
                    referencesCard
                }
                if content.showsHubLink {
                    hubLink
                }
                if let concept = content.learnMoreConcept, let guide = HLLearnLinks.guide(forConcept: concept) {
                    learnMoreRow(guide)
                }
                if content.isMedical {
                    Text("sources.sheet.footer")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.vertical, HLSpace.xl)
        }
        .hlScreenBackground()
        .navigationTitle(Text(verbatim: content.title))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(content.identifier)
    }

    private func sectionCard(title: String, paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel(verbatim: title)
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.lg)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
    }

    /// **1.0.3 (App Review 1.4.1, audit row 6)** — the way on from the
    /// assistant's own six references into the full catalog. Pushes inside the
    /// sheet's stack. Only `.aiAssistant` shows it.
    private var hubLink: some View {
        NavigationLink {
            MedicalSourcesScreen()
        } label: {
            rowLabel(systemImage: "books.vertical", trailing: "chevron.right") {
                Text("settings.about.medicalSources")
            }
        }
        .buttonStyle(.plain)
        .modifier(RowChrome())
        .accessibilityIdentifier("sources.sheet.hubLink")
    }

    /// The public guide for the topic, the sheet's last stop.
    private func learnMoreRow(_ guide: HLLearnGuide) -> some View {
        Link(destination: guide.localizedURL) {
            rowLabel(systemImage: "book", trailing: "arrow.up.right") {
                Text("common.learnMore")
            }
        }
        .buttonStyle(.plain)
        .modifier(RowChrome())
        .accessibilityLabel(Text("learnMore.a11y \(guide.localizedTitle)"))
        .accessibilityIdentifier("learnMore.\(guide.slug)")
    }

    private func rowLabel(systemImage: String, trailing: String, @ViewBuilder title: () -> Text) -> some View {
        HStack(spacing: HLSpace.md) {
            Image(systemName: systemImage)
                .font(.hlIcon(HLIconSize.md))
                .foregroundStyle(HLText.secondary)
                .hlInfoIconColumn()
                .accessibilityHidden(true)
            title()
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer()
            Image(systemName: trailing)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var referencesCard: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            HLSectionLabel("sources.sheet.referencesTitle")
            ForEach(content.references) { source in
                HLSourceRow(name: source.name, year: source.year, caveatKey: source.caveatKey, url: source.url)
            }
            ForEach(content.dynamicReferences) { source in
                HLSourceRow(name: source.name, year: nil, caveatKey: nil, url: source.url)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.lg)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
    }
}

/// The card chrome of the sheet's link rows.
private struct RowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HLSpace.lg)
            .padding(.vertical, HLSpace.sm)
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

    /// 1.4 B4 — the year beside the name, unless the name already carries it
    /// ("ESH 2023", "Kroenke 2001 (PHQ-9)"): those rows read "ESH 2023 2023".
    nonisolated static func visibleYear(name: String, year: Int?) -> Int? {
        guard let year, !name.contains(String(year)) else { return nil }
        return year
    }

    var body: some View {
        Link(destination: url) {
            HStack(alignment: .top, spacing: HLSpace.md) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                        Text(verbatim: name)
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.primary)
                            // 1.4 B2 — a long name wraps left-aligned, like
                            // its caveat (M1), not centred inside the Link.
                            .multilineTextAlignment(.leading)
                        if let year = Self.visibleYear(name: name, year: year) {
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
