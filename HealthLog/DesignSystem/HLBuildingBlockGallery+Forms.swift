#if DEBUG
    import SwiftUI

    /// The target forms of rows, values, status, facts and empty notes on
    /// the building block page.
    extension HLBuildingBlockGallery {
        @ViewBuilder
        var listRows: some View {
            HLSectionHeader(verbatim: "Listenzeile: Datenzeilen ohne Pfeil, Menüzeile mit Pfeil")
            HLCard(layout: .rows) {
                HLRowButton {} label: {
                    HLRow(
                        title: Text(verbatim: "Befund Hausarztpraxis Dr. Mustermann, Blutbild und Urin"),
                        detail: HLRowDetail.text(["12.11.2026", "PDF", "240 KB", "Hausarzt", "verknüpft mit Besuch"])
                    ) {
                        HLRowGlyph(symbol: "doc.text")
                    }
                }
                HLRow(
                    title: Text(verbatim: "INR"),
                    detail: HLRowDetail.text(["2 Werte", "zuletzt 03.11."]),
                    value: Text(verbatim: "1,3"),
                    status: HLRowStatus("Über Bereich", icon: "arrow.up", tone: .warning)
                )
                HLRow(
                    title: Text(verbatim: "Magnesium"),
                    detail: HLRowDetail.text(["Heute", "Ziel 350 mg"]),
                    value: Text(verbatim: "212 mg")
                )
                HLRow(
                    title: Text(verbatim: "iPhone von Alex"),
                    detail: HLRowDetail.text(["Diese Sitzung", "Bochum"]),
                    accessory: .menu
                ) {
                    HLRowGlyph(symbol: "iphone")
                }
                HLRow(
                    title: Text(verbatim: "Benachrichtigungen"),
                    detail: HLRowDetail.text(["Medikamente", "Messungen", "Wochenbericht"]),
                    accessory: .chevron
                ) {
                    HLSettingsIconChip(symbol: "bell.badge.fill", tint: HLAccent.userBrandTint)
                }
                HLRow(title: Text(verbatim: "Wochenbericht"), detail: Text(verbatim: "Montags, 08:00"), accessory: .toggle(.constant(true)))
            }
        }

        @ViewBuilder
        var historyRows: some View {
            HLSectionHeader(verbatim: "Verlauf, Drill-Zeile und Zubehör")
            HLCard(layout: .rows) {
                HLHistoryRow(
                    date: Text(verbatim: "Heute, 08:15"),
                    detail: Text(verbatim: "Apple Health"),
                    value: Text(verbatim: "128/82 mmHg")
                )
                HLHistoryRow(
                    date: Text(verbatim: "Gestern, 21:40"),
                    detail: Text(verbatim: "Manuell, nach dem Sport"),
                    value: Text(verbatim: "141/90 mmHg"),
                    status: HLRowStatus("Erhöht", icon: "arrow.up", tone: .warning)
                )
                HLDrillRow(title: Text(verbatim: "Alle Messungen anzeigen"), count: 248)
            }
            HLCard(layout: .rows) {
                HLRow(title: Text(verbatim: "Datenschutzerklärung"), accessory: .external) {
                    HLRowGlyph(symbol: "hand.raised")
                }
                HLRow(title: Text(verbatim: "Weitere Werte"), detail: Text(verbatim: "3 ausgeblendet"), accessory: .expand(false))
                HLRow(title: Text(verbatim: "Weniger Werte"), accessory: .expand(true))
            }
        }

        @ViewBuilder
        var valueRows: some View {
            HLSectionHeader(verbatim: "Zeile mit Wert und Status")
            HLCard(layout: .rows) {
                HLRowLayout(title: Text(verbatim: "INR"), subtitle: Text(verbatim: "2 Werte")) {
                    HLRowValue(
                        "1,3",
                        status: HLRowStatus("Über Bereich", icon: "arrow.up", tone: .warning)
                    )
                }
                HLRowLayout(title: Text(verbatim: "C-reaktives Protein"), subtitle: Text(verbatim: "5 Werte")) {
                    HLRowValue(
                        "2,1 mg/L",
                        status: HLRowStatus("Im Bereich", icon: "checkmark", tone: .success)
                    )
                }
                HLRowLayout(title: Text(verbatim: "Blutdruck"), subtitle: Text(verbatim: "Heute, 08:15")) {
                    HLValueText(128, 82, unit: .millimetersOfMercury)
                }
                HLListRow(title: "Ruhepuls", subtitle: "Ø 30 Tage 58 bpm", value: "56 bpm")
            }
            HLCard {
                VStack(spacing: HLSpace.sm) {
                    HLSettingsStatRow(label: Text(verbatim: "Version"), value: "1.6.0")
                    HLSettingsStatRow(label: Text(verbatim: "Bundle-ID"), value: "dev.healthlog.app")
                }
            }
        }

        @ViewBuilder
        var glyphColumn: some View {
            HLSectionHeader(verbatim: "Symbolspalte")
            HLCard(layout: .rows) {
                HLRowLayout(
                    title: Text(verbatim: "Blutdruck messen"),
                    subtitle: Text(verbatim: "Seit drei Tagen kein Wert")
                ) {
                    EmptyView()
                } leading: {
                    HLRowGlyph(symbol: "heart.fill", tint: HLAccent.userBrandTint)
                }
                HLRowLayout(title: Text(verbatim: "Mehr bewegen"), subtitle: Text(verbatim: "Schritte unter deinem Mittel")) {
                    EmptyView()
                } leading: {
                    HLRowGlyph(symbol: "figure.walk")
                }
                HLRowLayout(title: Text(verbatim: "Ohne Symbol"), subtitle: Text(verbatim: "Der Text beginnt trotzdem hier")) {
                    EmptyView()
                } leading: {
                    HLRowGlyph(symbol: nil)
                }
                HLRowLayout(title: Text(verbatim: "Mit Symbolkachel"), indicator: .disclosure) {
                    EmptyView()
                } leading: {
                    HLSettingsIconChip(symbol: "bell.badge.fill", tint: HLAccent.userBrandTint)
                }
            }
        }

        @ViewBuilder
        var statusForms: some View {
            HLSectionHeader(verbatim: "Status als Text und als Kapsel")
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLBadge("Im Bereich", icon: "checkmark", tone: .success, form: .text)
                    HLBadge("Unter Bereich", icon: "arrow.down", tone: .warning, form: .text)
                    HLBadge("Kritisch", icon: "exclamationmark.triangle.fill", tone: .critical, form: .text)
                    HLStatusPill(.disconnected(label: "Nicht verbunden"), form: .text)
                    HLFlowLayout(spacing: HLSpace.sm) {
                        HLStatusPill(.connected(label: "Verbunden"))
                        HLStatusPill(.warning(label: "Verzögert"))
                        HLStatusPill(.error(label: "Token abgelaufen"))
                        HLBadge(String(localized: "Weekly"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @ViewBuilder
        var facts: some View {
            HLSectionHeader(verbatim: "Fakten")
            HLCard {
                HLFactGroup {
                    HLFactRow(label: Text(verbatim: "Letzte Einnahme"), value: Text(verbatim: "heute, 08:05"))
                    HLFactRow(label: Text(verbatim: "Nächste Einnahme"), value: Text(verbatim: "morgen, 08:00"))
                    HLFactRow(label: Text(verbatim: "Vorrat"), value: Text(verbatim: "24 Stück, reicht 12 Tage"))
                }
            }
        }

        @ViewBuilder
        var values: some View {
            HLSectionHeader(verbatim: "Kennzahl, Kachel, Rasterzelle")
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    HLValueText(72.4, unit: .kilograms, size: .hero)
                    HLValueText(83, unit: .percent, size: .tile)
                    pairLayout {
                        compactCell("Minimum", value: 71.2)
                        compactCell("Mittel", value: 72.0)
                        compactCell("Maximum", value: 73.1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @ViewBuilder
        var emptyNote: some View {
            HLSectionHeader(verbatim: "Leer in einer Karte")
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLCardLabel(verbatim: "Verlauf")
                    HLEmptyNote(verbatim: "Noch keine Einnahmen erfasst.")
                }
            }
        }

        func compactCell(_ label: String, value: Double) -> some View {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(verbatim: label)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                HLValueText(value, unit: .kilograms, size: .compact, fractionDigits: 1 ... 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
#endif
