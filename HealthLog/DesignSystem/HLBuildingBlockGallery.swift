#if DEBUG
    import SwiftUI

    /// The building blocks side by side on one page, for the screenshot sweep.
    ///
    /// A picture in light, dark and at the largest text size shows what a
    /// contract test cannot: whether a block still looks right. The page stands
    /// in for the root when the app launches with ``launchArgument``. Its texts
    /// are specimens, not product copy, so none of them is a catalogue key.
    struct HLBuildingBlockGallery: View {
        static let launchArgument = "-uitest-building-blocks"
        static let readyIdentifier = "blocks.ready"
        static let plainSheetIdentifier = "blocks.sheet.plain"
        static let actionSheetIdentifier = "blocks.sheet.action"
        static let endIdentifier = "blocks.end"

        enum Specimen: String, Identifiable {
            case plain, action

            var id: String {
                rawValue
            }
        }

        @State private var shownSheet: Specimen?
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        /// Two tiles side by side, one above the other at the accessibility
        /// sizes, as the tile grids of the app lay them out.
        var pairLayout: AnyLayout {
            dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.md))
                : AnyLayout(HStackLayout(alignment: .top, spacing: HLSpace.md))
        }

        private var question: HLDeleteAction {
            .confirmed(verbatim: "Eintrag löschen?", message: "Der Eintrag wird entfernt.") {}
        }

        var body: some View {
            if ProcessInfo.processInfo.arguments.contains(HLActionBlockGallery.launchArgument) {
                HLActionBlockGallery()
            } else {
                mainPage
            }
        }

        private var mainPage: some View {
            NavigationStack {
                HLPage {
                    buttonRows
                    deleteForms
                    rows
                    listRows
                    historyRows
                    valueRows
                    glyphColumn
                    statusForms
                    facts
                    actionRows
                    formRows
                    identifiers
                    meters
                    values
                    emptyNote
                    rings
                    tileHeads
                    labels
                    emptyPage
                    Text(verbatim: "Ende der Bausteinseite")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier(Self.endIdentifier)
                }
                .navigationTitle(Text(verbatim: "Bausteine"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HLDeleteButton(form: .bar, action: question)
                    }
                }
            }
            .sheet(item: $shownSheet) { specimen in
                sheet(specimen)
            }
        }

        // MARK: - Sections

        @ViewBuilder
        private var buttonRows: some View {
            HLSectionHeader(verbatim: "Knopfzeile mit zwei Knöpfen")
                .accessibilityIdentifier(Self.readyIdentifier)
            HLButtonRow {
                HLButton(Text(verbatim: "Sheet ohne Aktion"), variant: .secondary) { shownSheet = .plain }
                    .accessibilityIdentifier(Self.plainSheetIdentifier)
                HLButton(Text(verbatim: "Sheet mit Aktion")) { shownSheet = .action }
                    .accessibilityIdentifier(Self.actionSheetIdentifier)
            }
            HLSectionHeader(verbatim: "Knopfzeile mit drei Knöpfen")
            HLButtonRow {
                HLButton(Text(verbatim: "Überspringen"), variant: .secondary) {}
                HLButton(Text(verbatim: "Später erinnern"), variant: .secondary) {}
                HLButton(Text(verbatim: "Einnahme bestätigen")) {}
            }
            HLCard {
                HLButtonRow(size: .small) {
                    ForEach([250, 500, 750], id: \.self) { amount in
                        HLButton(Text(verbatim: "+\(amount) ml"), variant: .secondary) {}
                    }
                }
            }
        }

        @ViewBuilder
        private var deleteForms: some View {
            HLSectionHeader(verbatim: "Löschen: Zeile, Zeichen, Seite")
            HLCard(layout: .rows) {
                HLDeleteButton(form: .row, action: question)
                HLRowLayout(title: Text(verbatim: "Blutdruck"), subtitle: Text(verbatim: "Montag, 08:15")) {
                    HLDeleteButton(form: .icon, action: question)
                }
            }
            HLDeleteButton(form: .page, action: question)
        }

        @ViewBuilder
        private var rows: some View {
            HLSectionHeader(verbatim: "Zeile mit Symbol und langem Titel")
            HLCard(layout: .rows) {
                HLRowLayout(
                    title: Text(verbatim: "Benachrichtigungen und Erinnerungen"),
                    subtitle: Text(verbatim: "Medikamente, Messungen, Wochenbericht"),
                    indicator: .disclosure
                ) {
                    EmptyView()
                } leading: {
                    HLSettingsIconChip(symbol: "bell.badge.fill", tint: HLAccent.userBrandTint)
                }
                HLRowLayout(
                    title: Text(verbatim: "Gesundheitsdaten exportieren"),
                    indicator: .symbol("square.and.arrow.up")
                ) {
                    EmptyView()
                } leading: {
                    HLSettingsIconChip(symbol: "heart.text.square.fill", tint: HLAccent.userBrandTint)
                }
            }
        }

        @ViewBuilder
        private var rings: some View {
            HLSectionHeader(verbatim: "Ring ohne Wort")
            HLCard {
                HStack(spacing: HLSpace.lg) {
                    HLScoreRing(fraction: 0.72, value: "72", accessibilityLabel: "Gesundheitsscore 72")
                        .frame(width: 96, height: 96)
                    HLScoreRing(fraction: 0.4, value: "+4", accessibilityLabel: "Plus 4 Punkte")
                        .frame(width: 96, height: 96)
                }
                .frame(maxWidth: .infinity)
            }
        }

        @ViewBuilder
        private var tileHeads: some View {
            HLSectionHeader(verbatim: "Kachelkopf")
            pairLayout {
                tile(icon: "waveform.path.ecg", title: "Herzfrequenzvariabilität", value: "48 ms")
                tile(icon: "figure.walk", title: "Schritte", value: "8.412")
            }
        }

        @ViewBuilder
        private var labels: some View {
            HLSectionHeader(verbatim: "Etikett mit langem Wort")
            pairLayout {
                labelled("Herzfrequenzvariabilität", value: "48 ms")
                labelled("Puls", value: "62 /min")
            }
        }

        // MARK: - Pieces

        private func tile(icon: String, title: String, value: String) -> some View {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    // The trailing sign of a tile is its trend, straight up or
                    // down; `arrow.up.right` belongs to rows that leave the app.
                    HLTileHeaderRow(icon: icon, title: Text(verbatim: title)) {
                        Image(systemName: "arrow.up")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: value)
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private func labelled(_ label: String, value: String) -> some View {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HLCardLabel(verbatim: label)
                    Text(verbatim: value)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @ViewBuilder
        private func sheet(_ specimen: Specimen) -> some View {
            switch specimen {
            case .plain:
                HLSheetScaffold(verbatim: "Hinweis zur Messung") {
                    sheetBody
                }
            case .action:
                HLSheetScaffold(verbatim: "Blutdruck eintragen", action: .save { true }) {
                    sheetBody
                }
            }
        }

        private var sheetBody: some View {
            Form {
                Section {
                    HLRowLayout(title: Text(verbatim: "Systolisch")) {
                        Text(verbatim: "128 mmHg").foregroundStyle(HLText.secondary)
                    }
                    HLRowLayout(title: Text(verbatim: "Diastolisch")) {
                        Text(verbatim: "82 mmHg").foregroundStyle(HLText.secondary)
                    }
                }
                .hlFormRowSurface()
                // The same rows as in a card: action, choice, remove.
                Section {
                    HLSettingsActionRow(title: "Create token", presents: .create) {}
                    HLChoiceRow(title: Text(verbatim: "Linker Arm"), isSelected: true) {}
                    HLChoiceRow(title: Text(verbatim: "Rechter Arm"), isSelected: false) {}
                    HStack(spacing: HLSpace.sm) {
                        HLDeleteButton(form: .remove, action: .undoable {})
                        HLRowLayout(title: Text(verbatim: "08:00"))
                    }
                }
                .hlFormRowSurface()
            }
        }
    }
#endif
