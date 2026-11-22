#if DEBUG
    import SwiftUI

    /// Action rows, form rows, identifiers, meters and the empty page on the
    /// building block page.
    extension HLBuildingBlockGallery {
        @ViewBuilder
        var actionRows: some View {
            HLSectionHeader(verbatim: "Aktionszeilen: Sheet, Anlegen, extern")
            HLCard(layout: .rows) {
                HLSettingsActionRow(icon: "person.crop.circle", title: "Profile", presents: .sheet) {}
                HLSettingsActionRow(title: "Create token", presents: .create) {}
                HLSettingsActionRow(icon: "hand.raised", title: "Privacy policy", presents: .external) {}
                HLDrillRow(title: Text(verbatim: "Alle Messungen anzeigen"), count: 0, hasEntriesOutsidePeriod: true)
            }
            HLCard {
                VStack(spacing: HLSpace.sm) {
                    HLButton(Text(verbatim: "Sichern")) {}
                        .disabled(true)
                    HLButton(Text(verbatim: "Weiter"), systemImage: "chevron.right", variant: .destructive) {}
                        .disabled(true)
                    HLButton(Text(verbatim: "Weiter"), systemImage: "chevron.right", variant: .destructive) {}
                }
            }
        }

        @ViewBuilder
        var formRows: some View {
            HLSectionHeader(verbatim: "Formularzeile mit Menü")
            HLCard(layout: .rows) {
                HLFormPicker(
                    title: Text(verbatim: "Ziel"),
                    selection: .constant("Allgemeine Gesundheit"),
                    options: ["Allgemeine Gesundheit", "Schwangerschaft planen"]
                ) { Text(verbatim: $0) }
                HLRow(title: Text(verbatim: "Vorhersagen"), accessory: .toggle(.constant(true)))
                HLRow(title: Text(verbatim: "Rohdatenmodus"), accessory: .toggle(.constant(false)))
            }
        }

        @ViewBuilder
        var identifiers: some View {
            HLSectionHeader(verbatim: "Kennungen ohne Silbentrennung")
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLIdentifierText("https://uitest.hermetic.local/mcp")
                    HLIdentifierText("console.anthropic.com")
                    HLIdentifierText("hlk_sweep_example_token", style: .footnote, monospaced: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @ViewBuilder
        var meters: some View {
            HLSectionHeader(verbatim: "Therapietreue, Zielschiene, Statistik")
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    HLComplianceBar(label: "30-Tage-Therapietreue", rate: 92)
                    RangeBandRow(band: RangeBand(lowerLabel: "61,9", upperLabel: "64,0", unit: "kg", pctInRange: 100))
                    HLStatGrid(cells: [
                        HLStatCell(label: "Ø Länge", value: "28", unit: "Tage"),
                        HLStatCell(label: "Schwankung", value: "1", unit: "Tage"),
                        HLStatCell(label: "Ø Periode", value: "5", unit: "Tage"),
                        HLStatCell(label: "Längster Zyklus im Jahr", value: "31", unit: "Tage")
                    ])
                }
            }
        }

        @ViewBuilder
        var emptyPage: some View {
            HLSectionHeader(verbatim: "Leere Seite")
            HLEmptyState(
                icon: "figure.run",
                title: Text(verbatim: "Noch keine Workouts"),
                message: Text(verbatim: "Workouts erscheinen hier, sobald Apple Watch oder Withings sie liefern.")
            )
            .frame(height: 260)
        }
    }
#endif
