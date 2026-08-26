import SwiftUI

/// **CU-32 — der Verlauf einer Fakten-Art.**
///
/// Jede Zeile ist eine Fassung mit ihrem Gültigkeitszeitraum und ihrer
/// Provenienz. Eine **Korrektur** ist etwas anderes als eine Änderung: sie sagt
/// „das war schon vorher so, wir hatten es falsch notiert", nicht „ab jetzt
/// gilt etwas Neues". Deshalb steht das Abzeichen an der Zeile und wird nicht
/// verschluckt.
struct AnamnesisFactHistoryList: View {
    let revisions: [AnamnesisFactRevision]
    let kind: AnamnesisFactKind

    private var rows: [AnamnesisHistoryRow] {
        AnamnesisHistoryRow.rows(for: kind, from: revisions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            if rows.isEmpty {
                Text("anamnesis.history.empty")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(rows) { row in
                    rowView(row)
                }
                Text("anamnesis.history.footer")
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func rowView(_ row: AnamnesisHistoryRow) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: row.isCurrent ? "circle.fill" : "circle")
                .font(.hlCaption2)
                .foregroundStyle(row.isCurrent ? HLAccent.primary : HLText.secondary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HLSpace.xs) {
                    Text(LocalizedStringKey(row.labelKey))
                        .font(.hlFootnote.weight(row.isCurrent ? .semibold : .regular))
                        .foregroundStyle(HLText.primary)
                    if let provenanceKey = row.provenanceKey {
                        HLBadge(
                            String(localized: String.LocalizationValue(provenanceKey)),
                            tone: row.isCorrection ? .info : .neutral
                        )
                    }
                }
                Text(row.validityText)
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// **Die Render-Eingabe einer Verlaufszeile** — reine Projektion, ohne SwiftUI.
///
/// Der Verlauf ist die eigentliche Aussage dieser Fläche, also wird sein
/// Zustandekommen testbar gehalten statt im View-Body zu verschwinden. Die
/// Zeile trägt **Schlüssel und Rohdaten**, keine aufgelösten Texte — damit ein
/// Snapshot nicht an Locale oder Zeitzone hängt.
struct AnamnesisHistoryRow: Hashable, Identifiable {
    let id: String
    /// Katalog-Schlüssel der Beschriftung. Für eine unlesbare Fassung der
    /// „Nicht lesbar"-Schlüssel — die Zeile wird angezeigt, nicht versteckt:
    /// „da stand etwas, wir kommen nur nicht mehr dran" ist ehrlicher als eine
    /// Lücke im Verlauf.
    let labelKey: String
    /// `nil` bei unbekannter Provenienz — dann kein Abzeichen statt eines mit
    /// erfundener Bedeutung.
    let provenanceKey: String?
    let validFrom: Date
    let validUntil: Date?
    let isCurrent: Bool
    let isCorrection: Bool

    /// Neueste Gültigkeit zuerst — unabhängig von der Server-Sortierung.
    static func rows(
        for kind: AnamnesisFactKind,
        from revisions: [AnamnesisFactRevision]
    ) -> [AnamnesisHistoryRow] {
        revisions
            .filter { $0.kind == kind }
            .sorted { $0.validFrom > $1.validFrom }
            .map { revision in
                let labelKey: String = if let value = revision.value, !revision.unreadable {
                    kind.labelKey(for: value)
                } else {
                    AnamnesisCopy.unreadable
                }
                return AnamnesisHistoryRow(
                    id: revision.id,
                    labelKey: labelKey,
                    provenanceKey: revision.provenance.labelKey,
                    validFrom: revision.validFrom,
                    validUntil: revision.validUntil,
                    isCurrent: revision.isCurrent,
                    isCorrection: revision.isCorrection
                )
            }
    }

    /// „Gilt seit <von>" bzw. „<von> bis <bis>" — erst hier wird lokalisiert.
    var validityText: String {
        guard let validUntil else {
            return String(
                format: String(localized: String.LocalizationValue(AnamnesisCopy.validitySince)),
                HLDateFormat.date(validFrom)
            )
        }
        return String(
            format: String(localized: String.LocalizationValue(AnamnesisCopy.validityRange)),
            HLDateFormat.date(validFrom),
            HLDateFormat.date(validUntil)
        )
    }
}

extension AnamnesisFactRevision {
    /// Die Gültigkeitszeile der **aktuellen** Fassung auf der Karte. Dieselbe
    /// Formatierung wie im Verlauf — eine Quelle, kein zweiter Text.
    var validityText: String {
        AnamnesisHistoryRow.rows(for: kind, from: [self]).first?.validityText ?? ""
    }
}
