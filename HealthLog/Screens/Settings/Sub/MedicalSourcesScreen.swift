import SwiftUI

/// **1.0.3 (App Review 1.4.1) — "Medical sources" hub.**
///
/// Reachable from More → Health & care, Settings → About → Links, and the
/// first-launch disclaimer sheet. Lists every methodology paragraph and every
/// reference in the catalog, grouped, each with a link to the original.
struct MedicalSourcesScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                Text("sources.hub.intro")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                methodsSection
                ForEach(Group.allCases) { group in
                    referencesSection(group)
                }
                learnSection
                Text("sources.sheet.footer")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.vertical, HLSpace.xl)
        }
        .hlScreenBackground()
        .navigationTitle(Text("sources.hub.title"))
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("sources.hub")
    }

    /// R12 (`hl_no_sectionlabel_in_settings`, error severity) forbids
    /// `HLSectionLabel` under `Screens/Settings/`: a Settings section heading is
    /// the `HLSettingsCard` title, not the free-floating uppercase label the
    /// brief's draft used. The card shape (background, radius, padding) below
    /// is `HLSettingsCard`'s, not a hand-rolled one.
    private var methodsSection: some View {
        HLSettingsCard(icon: "function", title: "sources.hub.methodsTitle") {
            ForEach(MedicalSourceCatalog.allMethodologyKeys, id: \.bodyKey) { entry in
                DisclosureGroup {
                    Text(LocalizedStringKey(entry.bodyKey))
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, HLSpace.xs)
                } label: {
                    Text(LocalizedStringKey(entry.titleKey))
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        // M1 — a `Text` inside a DisclosureGroup label centres
                        // its wrapped lines by default.
                        .multilineTextAlignment(.leading)
                        // Audit (minor) — a disclosure label is the tap target
                        // for the whole row, so it carries the 44pt floor the
                        // HIG asks of one.
                        .frame(minHeight: 44, alignment: .leading)
                }
                .tint(HLText.secondary)
                .accessibilityIdentifier("sources.hub.method.\(entry.bodyKey)")
            }
        }
    }

    private func referencesSection(_ group: Group) -> some View {
        let items = MedicalSourceCatalog.all.filter { group.contains($0.id) }
        return HLSettingsCard(icon: group.icon, title: group.titleKey) {
            ForEach(items) { s in
                HLSourceRow(name: s.name, year: s.year, caveatKey: s.caveatKey, url: s.url)
            }
        }
        .accessibilityIdentifier("sources.hub.group.\(group.rawValue)")
    }

    private var learnSection: some View {
        HLSettingsCard(icon: "book", title: "sources.hub.learnTitle") {
            Text("sources.hub.learnBody")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MedicalSourceCatalog.learnGuides, id: \.slug) { guide in
                HLSourceRow(name: guide.title, year: nil, caveatKey: nil, url: guide.url)
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
                 .pearson2003Crp, .who2020Ferritin, .who2024Haemoglobin, .acogCo6512015, .who2018Noise, .escNaspe1996Hrv:
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
