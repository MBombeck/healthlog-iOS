#if DEBUG
    import SwiftUI

    /// The action forms F1 to F9 on a page of their own, each once, for the
    /// screenshot sweep: main and secondary action, the quick actions of an
    /// object card, removing, the quiet link in its places, loading more,
    /// symbol buttons, the stepper, choices, the empty state, the composer and
    /// the bar of a pushed page. The block page shows it instead of itself
    /// when the app also gets ``launchArgument``. Its texts are specimens, not
    /// product copy.
    struct HLActionBlockGallery: View {
        static let launchArgument = "-uitest-building-blocks-actions"

        @State private var single = "PDF"
        @State private var multiple: Set<String> = ["Blutdruck"]
        @State private var expanded = false
        @State private var draft = "Wie war mein Schlaf diese Woche?"
        @State private var note = "Kontrolle beim Hausarzt"
        @State private var segment = "week"
        @State private var chip = "Puls"
        @State private var filterOn = true

        var body: some View {
            NavigationStack {
                HLPage {
                    HLSectionHeader(verbatim: "F1 Hauptaktion, F2 Sekundäraktion")
                        .accessibilityIdentifier(HLBuildingBlockGallery.readyIdentifier)
                    HLButton(Text(verbatim: "Verbinden")) {}
                    HLButton(verbatim: "Jetzt synchronisieren", icon: "arrow.triangle.2.circlepath", variant: .secondary) {}
                    HLButtonPair(order: .reading) {
                        HLButton(verbatim: "Alles auswählen", variant: .secondary) {}
                    } secondary: {
                        HLButton(verbatim: "Auswahl leeren", variant: .secondary) {}
                    }

                    HLSectionHeader(verbatim: "Schnellaktionen einer Objektkarte")
                    HLCard {
                        VStack(alignment: .leading, spacing: HLSpace.md) {
                            Text(verbatim: "Lisinopril 5 mg")
                                .font(.hlHeadline)
                                .foregroundStyle(HLText.primary)
                            HLTileActions([
                                HLTileAction.Item("med.card.action.taken", icon: "checkmark") {},
                                HLTileAction.Item("med.card.action.skipped", icon: "forward.end") {}
                            ])
                        }
                    }

                    HLSectionHeader(verbatim: "F3 Zeile entfernen")
                    HLCard(layout: .rows) {
                        ForEach(["08:00", "20:00"], id: \.self) { time in
                            HStack(spacing: HLSpace.sm) {
                                HLDeleteButton(form: .remove, action: .undoable {})
                                HLRowLayout(title: Text(verbatim: time))
                            }
                        }
                    }

                    HLSectionHeader(verbatim: "F4 Textlink: unter der Karte, in der Karte, im Fließtext")
                    HLCard(layout: .rows) {
                        HLRowLayout(title: Text(verbatim: "Blutdruck"), indicator: .disclosure)
                    }
                    HLLinkButton(Text(verbatim: "Erweitert"), isExpanded: expanded) { expanded.toggle() }
                    HLCard {
                        VStack(alignment: .leading, spacing: HLSpace.xs) {
                            Text(verbatim: "Schlaf und Ruhepuls hängen zusammen.")
                                .font(.hlBody)
                                .foregroundStyle(HLText.primary)
                            HLLinkButton(Text(verbatim: "Den Coach fragen"), systemImage: "sparkles", alignment: .leading) {}
                            HStack(spacing: HLSpace.xs) {
                                Text(verbatim: "Wetterdaten von")
                                HLTextLink(verbatim: "Open-Meteo.com", destination: Self.sourceURL)
                            }
                            .font(.hlFootnote)
                            .foregroundStyle(HLText.secondary)
                        }
                    }

                    HLSectionHeader(verbatim: "Mehr laden: Link und Laden")
                    HLLoadMoreRow(hasMore: true, isLoading: false) {}
                    HLLoadMoreRow(hasMore: true, isLoading: true) {}

                    HLSectionHeader(verbatim: "F5 Symbolknopf, Vor und Zurück")
                    HLCard {
                        VStack(spacing: HLSpace.md) {
                            HLStepperHeader(
                                verbatim: "Dienstag, 12. November",
                                subtitle: Text(verbatim: "Ruhepuls 58"),
                                canGoNext: false,
                                previous: {},
                                next: {}
                            )
                            HStack(spacing: HLSpace.md) {
                                HLIconButton(systemImage: "sparkles", label: "Ask the coach", isLoading: true) {}
                                HLIconButton(systemImage: "sparkles", label: "Ask the coach") {}
                                Spacer(minLength: 0)
                                Text(verbatim: "Kopfschmerz")
                                    .font(.hlBody)
                                    .foregroundStyle(HLText.primary)
                                HLIconButton(systemImage: "xmark.circle.fill", label: "Remove", size: .inline) {}
                            }
                        }
                    }

                    HLSectionHeader(verbatim: "F7 Auswahl: eine und mehrere")
                    HLCard(layout: .rows) {
                        ForEach(["PDF", "CSV"], id: \.self) { format in
                            HLChoiceRow(title: Text(verbatim: format), isSelected: single == format) { single = format }
                        }
                    }
                    HLCard(layout: .rows) {
                        ForEach(["Blutdruck", "Gewicht"], id: \.self) { record in
                            HLChoiceRow(
                                title: Text(verbatim: record),
                                detail: Text(verbatim: "12 Einträge"),
                                isSelected: multiple.contains(record),
                                mode: .multiple
                            ) {
                                if multiple.contains(record) { multiple.remove(record) } else { multiple.insert(record) }
                            }
                        }
                    }

                    HLSectionHeader(verbatim: "F8 Leerzustand ohne Knopf (Plus in der Leiste)")
                    HLEmptyState(
                        icon: "bell",
                        title: Text(verbatim: "Noch keine Erinnerungen"),
                        message: Text(verbatim: "Mit dem Plus oben legst du die erste an.")
                    )

                    HLSectionHeader(verbatim: "Texte und Felder")
                    HLCard {
                        VStack(alignment: .leading, spacing: HLSpace.md) {
                            HLWholeWordText("Niedrigdosis-CT der Lunge zur Früherkennung", font: .hlHeadline)
                                .foregroundStyle(HLText.primary)
                            HLTextField(title: "Titel", text: $note, kind: .text)
                            HLAdaptiveSegmentedPicker(
                                "Time range",
                                selection: $segment,
                                labels: ["This week", "Last week"],
                                values: ["week", "last"]
                            ) {
                                Text("This week").tag("week")
                                Text("Last week").tag("last")
                            }
                            HLInlineProgress("Loading")
                        }
                    }
                    HLCard(layout: .rows) {
                        HLSettingsStatRow(label: Text(verbatim: "Server"), value: "uitest.hermetic.local", isIdentifier: true)
                        HLSettingsStatRow(label: Text(verbatim: "Letzter Abgleich"), value: "vor 5 Minuten")
                    }

                    HLSectionHeader(verbatim: "Chipleiste mit Randblende")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: HLSpace.sm) {
                            ForEach(["Übersicht", "Puls", "Blutdruck", "Gewicht", "Schlaf", "Schritte"], id: \.self) { name in
                                HLChip(verbatim: name, isSelected: chip == name) { chip = name }
                            }
                        }
                        .padding(.horizontal, HLLayout.pageMargin)
                    }
                    .padding(.horizontal, -HLLayout.pageMargin)
                    .hlEdgeFade()

                    HLSectionHeader(verbatim: "F9 Eingabezeile")
                    HLComposerBar(text: $draft, prompt: Text(verbatim: "Frag etwas …")) {}

                    Text(verbatim: "Ende der Aktionsseite")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier(HLBuildingBlockGallery.endIdentifier)
                }
                .navigationTitle(Text(verbatim: "Aktionen"))
                .navigationBarTitleDisplayMode(.inline)
                .hlPageActions([
                    .filter(isSelected: filterOn) {
                        Toggle(isOn: $filterOn) { Text(verbatim: "Nur offene") }
                    },
                    .more {
                        Button {} label: { Label(HLControlWord.edit.key, systemImage: "pencil") }
                    },
                    .add(label: HLControlWord.add.key) {}
                ])
            }
        }

        // swiftlint:disable:next force_unwrapping
        private static let sourceURL = URL(string: "https://open-meteo.com")!
    }
#endif
