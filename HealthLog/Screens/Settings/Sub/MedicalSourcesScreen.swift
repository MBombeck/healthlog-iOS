import SwiftUI

/// **1.0.3 (App Review 1.4.1) — "Medical sources" hub.**
///
/// Reachable from More → Health & care, Settings → About → Links, and the
/// first-launch disclaimer sheet. Lists every methodology paragraph and every
/// reference in the catalog, grouped, each with a link to the original.
struct MedicalSourcesScreen: View {
    /// A sidebar tab root on a regular-width window, a page pushed onto More
    /// everywhere else.
    @Environment(\.hlIsTabRoot) private var isTabRoot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The methodology paragraphs that are open.
    @State private var expandedMethods: Set<String> = []

    var body: some View {
        HLPage {
            // As a tab root the page title is the tab header, like on every
            // other tab; pushed, the bar names the page inline.
            if isTabRoot {
                HLTabHeader("sources.hub.title", titleIdentifier: "sources.hub.header.title")
            }
            // The intro ("this page lists where every one of
            // them comes from") is gone; the title and the cards say it.
            // The disclaimer at the end stays (App Review 1.4.1).
            methodsSection
            ForEach(Group.allCases) { group in
                referencesSection(group)
            }
            learnSection
            Text("sources.sheet.footer")
                .hlText(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle(isTabRoot ? Text(verbatim: "") : Text("sources.hub.title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sources.hub")
    }

    /// A Settings section heading is the `HLCard` title, not a free-floating
    /// uppercase label. The card shape (background, radius, padding) below is
    /// `HLCard`'s, not a hand-rolled one.
    private var methodsSection: some View {
        // The app's unfolding row (the chevron turns, in the tone of every
        // other row's indicator) on the row grid of a row card. The system
        // disclosure drew a dark chevron and taller rows than every other
        // list.
        HLCard("sources.hub.methodsTitle", layout: .rows) {
            ForEach(MedicalSourceCatalog.allMethodologyKeys, id: \.bodyKey) { entry in
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HLRowButton {
                        withAnimation(reduceMotion ? nil : .default) { toggle(entry.bodyKey) }
                    } label: {
                        HLRow(
                            title: Text(LocalizedStringKey(entry.titleKey)),
                            accessory: .expand(expandedMethods.contains(entry.bodyKey))
                        )
                    }
                    .accessibilityIdentifier("sources.hub.method.\(entry.bodyKey)")
                    if expandedMethods.contains(entry.bodyKey) {
                        Text(LocalizedStringKey(entry.bodyKey))
                            .hlText(.note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if expandedMethods.contains(key) {
            expandedMethods.remove(key)
        } else {
            expandedMethods.insert(key)
        }
    }

    private func referencesSection(_ group: Group) -> some View {
        let items = MedicalSourceCatalog.all.filter { group.contains($0.id) }
        return HLCard(group.titleKey) {
            ForEach(items) { s in
                HLSourceRow(name: s.name, year: s.year, caveatKey: s.caveatKey, url: s.url)
            }
        }
        .accessibilityIdentifier("sources.hub.group.\(group.rawValue)")
    }

    private var learnSection: some View {
        HLCard("sources.hub.learnTitle") {
            ForEach(MedicalSourceCatalog.learnGuides, id: \.slug) { guide in
                // The title and the article in the app's language.
                HLSourceRow(name: guide.localizedTitle, year: nil, caveatKey: nil, url: guide.localizedURL)
            }
        }
    }

    /// Display grouping of the catalog. Every id belongs to exactly one group;
    /// `MedicalSourcesScreenTests` asserts the partition is complete.
    enum Group: String, CaseIterable, Identifiable {
        case guidelines, ranges, questionnaires, pharmacology, methods, devices, other
        var id: String {
            rawValue
        }

        /// Audit (minor) — every card used to wear `text.book.closed`, which
        /// made nine stacked cards read as one undifferentiated block. Each
        /// group now carries the glyph of what it cites, so the hub can be
        /// skimmed.
        var icon: String {
            switch self {
            case .guidelines: "doc.text"
            case .ranges: "testtube.2"
            case .questionnaires: "list.clipboard"
            case .pharmacology: "pills"
            case .methods: "chart.xyaxis.line"
            case .devices: "applewatch"
            case .other: "person.3"
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .guidelines: "sources.hub.group.guidelines"
            case .ranges: "sources.hub.group.ranges"
            case .questionnaires: "sources.hub.group.questionnaires"
            case .pharmacology: "sources.hub.group.pharmacology"
            case .methods: "sources.hub.group.methods"
            case .devices: "sources.hub.group.devices"
            case .other: "sources.hub.group.other"
            }
        }

        static func of(_ id: MedicalSourceID) -> Group {
            switch id {
            case .esh2023Hypertension, .accAha2017Bp, .esc2024Bp, .escEsh2018Pwv, .ada2024Glycemic, .ispad2022Pediatric,
                 .whoIdf2006Glucose, .who2000Bmi, .who2011Waist, .who2020PhysicalActivity, .aasm2015AdultSleep,
                 .hirshkowitz2015NsfSleep, .cdc2024Sleep, .bts2017EmergencyOxygen, .niceNg115Copd, .rcp2017News2,
                 .escEas2019Dyslipidaemia, .eas2022Lpa, .kdigo2012Ckd, .jonklaas2014AtaThyroid, .holick2011VitaminD,
                 .pearson2003Crp, .who2020Ferritin, .who2024Haemoglobin, .acogCo6512015, .who2018Noise, .escNaspe1996Hrv,
                 .trinka2015StatusEpilepticus, .niceNg217Epilepsies, .beniczky2025IlaeSeizures, .cdcSeizureFirstAid:
                .guidelines
            case .abimLabReferenceRanges, .harris2004Omega3Index, .matthews1985HomaIr, .efsaDrv, .aceBodyFatStandards, .vatImagingThreshold:
                .ranges
            case .kroenke2001Phq9, .spitzer2006Gad7, .topp2015Who5, .espie2014Sci:
                .questionnaires
            case .frid2016InjectionTechnique:
                .pharmacology
            case .benjaminiHochberg1995, .roenneberg2003Mctq, .wittmann2006SocialJetlag, .phillips2017Sri:
                .methods
            case .appleEcg, .appleIrregularRhythm, .appleWalkingSteadiness, .appleSleepApnea, .fda2024PulseOx:
                .devices
            case .stepsSaintMaurice2020, .tudorLocke2011Steps, .cdcNhanes, .aha2024Rhr, .statpearlsPulseOx,
                 .statpearlsPulsePressure, .statpearlsMap, .jgim2019Temperature, .alaRespiratoryRate, .watson1980Tbw,
                 .icrp89ReferenceMan, .wilcox2000FertileWindow, .nes2011FitnessAge, .leong2015Grip,
                 .ats2002SixMinuteWalk, .studenski2011GaitSpeed:
                .other
            }
        }

        func contains(_ id: MedicalSourceID) -> Bool {
            Self.of(id) == self
        }
    }
}
