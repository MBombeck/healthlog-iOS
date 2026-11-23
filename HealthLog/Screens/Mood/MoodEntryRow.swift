import SwiftUI

/// One logged mood in the row form of every list: the level as the title,
/// when and what was noted as the one detail line, the face in the symbol
/// column.
struct MoodEntryRow: View {
    let entry: MoodEntry
    /// Resolves structured tag keys and rated factors to their labels.
    @Environment(MoodTagCatalogStore.self) private var tagCatalog
    /// The mood face takes the symbol column of every row and grows with it.
    @ScaledMetric(relativeTo: .subheadline) private var glyphSide: CGFloat = HLLayout.rowIcon

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Rated factors as "Arbeit: gut", inverse-aware like the capture slider.
    /// An unknown key (factor retired server-side) keeps a humanized key.
    private var ratedReadbacks: [String] {
        entry.ratedFactors.map { factor in
            let dto = tagCatalog.catalog.categories
                .flatMap(\.tags)
                .first { $0.key == factor.key }
            let label = dto?.localizedLabel ?? MoodTagCatalogL10n.resolve(factor.key)
            let resolveDTO = dto ?? MoodTagDTO(key: factor.key, labelKey: factor.key, icon: nil, kind: .rated)
            let quality = MoodRatedQuality.resolve(rating: factor.rating, factor: resolveDTO)
            return String(localized: "mood.readback.ratedValue \(label) \(quality.localizedWord)")
        }
    }

    /// Structured tag keys as their labels; an unknown key keeps its raw form.
    private var tagLabels: [String] {
        entry.tagKeys.map { tagCatalog.label(forTagKey: $0) ?? MoodTagCatalogL10n.resolve($0) }
    }

    var body: some View {
        HLRow(
            title: Text(MoodCopy.levelLabel(entry.score)),
            detail: HLRowDetail.text(Self.detailParts(
                when: Self.relativeFormatter.localizedString(for: entry.recordedAt, relativeTo: .now),
                rated: ratedReadbacks,
                tags: tagLabels,
                freeTags: entry.tags,
                note: entry.note
            ))
        ) {
            face
        }
        .accessibilityElement(children: .combine)
    }

    /// No glyph from the five-icon pack for a level this build cannot name;
    /// a neutral mark, sized the same.
    private var face: some View {
        let side = HLRowGlyph.columnWidth(forScaled: glyphSide)
        return Group {
            if let score = entry.score {
                Image(MoodCopy.iconName(for: score))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(HLText.tertiary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// The row's one detail line: when, then what was rated and tagged, then
    /// the note, in that order. The row cuts it at its end; the entry sheet
    /// shows all of it.
    nonisolated static func detailParts(
        when: String,
        rated: [String],
        tags: [String],
        freeTags: [String],
        note: String?
    ) -> [String?] {
        let shownFreeTags = freeTags.filter { !$0.hasPrefix("note:") }
        let flatNote = note?
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        let fixed: [String?] = [when] + rated + tags + shownFreeTags
        return fixed + [flatNote]
    }
}
