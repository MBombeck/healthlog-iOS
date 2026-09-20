import Foundation

/// **1.0.3 (App Review 1.4.1) — the medical-source registry.**
///
/// Mirror of the server's `CITATIONS` (`src/lib/medical-citations.ts`, 30
/// entries, ids identical) plus the sources the iOS surfaces need that the
/// server does not cite (lab seeds, questionnaires, pharmacology, device
/// documentation). Every URL is checked by `MedicalSourceCatalogTests` for
/// scheme and checked for reachability.
public enum MedicalSourceCatalog {
    private static func make(_ id: MedicalSourceID, _ name: String, _ year: Int, _ url: String) -> MedicalSource {
        // Force-unwrap is safe: every literal below is a static, test-covered URL.
        // swiftlint:disable:next force_unwrapping
        MedicalSource(id: id, name: name, year: year, url: URL(string: url)!)
    }

    public static let all: [MedicalSource] = [
        // ── server-mirrored ──
        make(
            .esh2023Hypertension,
            "ESH 2023",
            2023,
            "https://journals.lww.com/jhypertension/fulltext/2023/12000/2023_esh_guidelines_for_the_management_of_arterial.2.aspx"
        ),
        make(.stepsSaintMaurice2020, "Saint-Maurice JAMA 2020", 2020, "https://jamanetwork.com/journals/jama/fullarticle/2763292"),
        make(.who2020PhysicalActivity, "WHO 2020 Physical Activity", 2020, "https://www.who.int/publications/i/item/9789240015128"),
        make(.bts2017EmergencyOxygen, "BTS 2017 Emergency Oxygen", 2017, "https://thorax.bmj.com/content/72/Suppl_1/ii1"),
        make(.niceNg115Copd, "NICE NG115", 2018, "https://www.nice.org.uk/guidance/ng115"),
        make(.ada2024Glycemic, "ADA 2024 Standards of Care", 2024, "https://diabetesjournals.org/care/article/47/Supplement_1/S111/153957"),
        make(.ispad2022Pediatric, "ISPAD 2022", 2022, "https://onlinelibrary.wiley.com/doi/10.1111/pedi.13455"),
        make(
            .aceBodyFatStandards,
            "ACE Body-Fat Standards",
            2009,
            "https://www.acefitness.org/resources/everyone/blog/112/what-are-the-guidelines-for-percentage-of-body-fat-loss/"
        ),
        make(
            .aasm2015AdultSleep,
            "AASM 2015 Adult Sleep Duration",
            2015,
            "https://aasm.org/resources/pdf/pressroom/adult-sleep-duration-consensus.pdf"
        ),
        make(.watson1980Tbw, "Watson 1980 TBW formula", 1980, "https://pubmed.ncbi.nlm.nih.gov/6986753/"),
        make(.icrp89ReferenceMan, "ICRP 89 Reference Man", 2002, "https://www.icrp.org/publication.asp?id=ICRP%20Publication%2089"),
        make(
            .aha2024Rhr,
            "AHA 2024 Heart Rate",
            2024,
            "https://www.heart.org/en/health-topics/high-blood-pressure/the-facts-about-high-blood-pressure/all-about-heart-rate-pulse"
        ),
        make(.statpearlsPulseOx, "StatPearls Pulse Oximetry", 2023, "https://www.ncbi.nlm.nih.gov/books/NBK470348/"),
        make(.accAha2017Bp, "ACC/AHA 2017", 2017, "https://www.ahajournals.org/doi/10.1161/HYP.0000000000000065"),
        make(.esc2024Bp, "ESC 2024", 2024, "https://academic.oup.com/eurheartj/article/45/38/3912/7741010"),
        make(.statpearlsPulsePressure, "StatPearls Pulse Pressure", 2023, "https://www.ncbi.nlm.nih.gov/books/NBK482408/"),
        make(.statpearlsMap, "StatPearls Mean Arterial Pressure", 2023, "https://www.ncbi.nlm.nih.gov/books/NBK538226/"),
        make(.escEsh2018Pwv, "ESC/ESH 2018", 2018, "https://academic.oup.com/eurheartj/article/39/33/3021/5079119"),
        make(
            .fda2024PulseOx,
            "FDA 2024 Pulse Oximeter Review",
            2024,
            "https://www.fda.gov/medical-devices/products-and-medical-procedures/pulse-oximeters"
        ),
        make(.jgim2019Temperature, "J Gen Intern Med 2019", 2019, "https://link.springer.com/article/10.1007/s11606-019-05148-7"),
        make(.rcp2017News2, "RCP NEWS2 2017", 2017, "https://www.rcp.ac.uk/improving-care/resources/national-early-warning-score-news-2/"),
        make(.alaRespiratoryRate, "American Lung Association", 2024, "https://www.lung.org/blog/respiratory-rate-vital-signs"),
        make(.vatImagingThreshold, "VAT imaging literature", 2025, "https://pubmed.ncbi.nlm.nih.gov/24008002/"),
        make(.wilcox2000FertileWindow, "Wilcox BMJ 2000", 2000, "https://www.bmj.com/content/321/7271/1259"),
        make(
            .acogCo6512015,
            "ACOG CO 651 2015",
            2015,
            "https://www.acog.org/clinical/clinical-guidance/committee-opinion/articles/2015/12/menstruation-in-girls-and-adolescents-using-the-menstrual-cycle-as-a-vital-sign"
        ),
        make(.phillips2017Sri, "Phillips Sci Rep 2017", 2017, "https://www.nature.com/articles/s41598-017-03171-4"),
        make(.cdc2024Sleep, "CDC 2024 Sleep", 2024, "https://www.cdc.gov/sleep/about/index.html"),
        make(.who2000Bmi, "WHO 2000 BMI", 2000, "https://iris.who.int/items/933e09aa-64f9-46e9-8dbb-78d8cddf1a3d"),
        make(
            .whoIdf2006Glucose,
            "WHO/IDF 2006",
            2006,
            "https://www.who.int/publications/i/item/definition-and-diagnosis-of-diabetes-mellitus-and-intermediate-hyperglycaemia"
        ),
        make(.escNaspe1996Hrv, "ESC/NASPE HRV Standards 1996", 1996, "https://www.ahajournals.org/doi/10.1161/01.CIR.93.5.1043"),
        // ── iOS additions ──
        make(.benjaminiHochberg1995, "Benjamini & Hochberg 1995", 1995, "https://doi.org/10.1111/j.2517-6161.1995.tb02031.x"),
        make(.escEas2019Dyslipidaemia, "ESC/EAS 2019 Dyslipidaemias", 2019, "https://doi.org/10.1093/eurheartj/ehz455"),
        make(.eas2022Lpa, "EAS 2022 Lipoprotein(a) Consensus", 2022, "https://doi.org/10.1093/eurheartj/ehac361"),
        make(.kdigo2012Ckd, "KDIGO 2012 CKD", 2012, "https://kdigo.org/guidelines/ckd-evaluation-and-management/"),
        make(.matthews1985HomaIr, "Matthews 1985 (HOMA)", 1985, "https://doi.org/10.1007/BF00280883"),
        make(.harris2004Omega3Index, "Harris & von Schacky 2004 (Omega-3 Index)", 2004, "https://doi.org/10.1016/j.ypmed.2004.02.030"),
        make(.kroenke2001Phq9, "Kroenke 2001 (PHQ-9)", 2001, "https://doi.org/10.1046/j.1525-1497.2001.016009606.x"),
        make(.spitzer2006Gad7, "Spitzer 2006 (GAD-7)", 2006, "https://doi.org/10.1001/archinte.166.10.1092"),
        make(.topp2015Who5, "Topp 2015 (WHO-5)", 2015, "https://doi.org/10.1159/000376585"),
        make(.espie2014Sci, "Espie 2014 (Sleep Condition Indicator)", 2014, "https://doi.org/10.1136/bmjopen-2013-004183"),
        make(.roenneberg2003Mctq, "Roenneberg 2003 (MCTQ)", 2003, "https://doi.org/10.1177/0748730402239679"),
        make(.wittmann2006SocialJetlag, "Wittmann 2006 (Social Jetlag)", 2006, "https://doi.org/10.1080/07420520500545979"),
        make(.tudorLocke2011Steps, "Tudor-Locke 2011 (Steps)", 2011, "https://doi.org/10.1186/1479-5868-8-79"),
        make(.hirshkowitz2015NsfSleep, "Hirshkowitz 2015 (NSF Sleep Duration)", 2015, "https://doi.org/10.1016/j.sleh.2014.12.010"),
        make(.cdcNhanes, "CDC NHANES", 2020, "https://www.cdc.gov/nchs/nhanes/"),
        make(.efsaDrv, "EFSA Dietary Reference Values", 2019, "https://www.efsa.europa.eu/en/topics/topic/dietary-reference-values"),
        make(.who2020Ferritin, "WHO 2020 Ferritin Guideline", 2020, "https://www.who.int/publications/i/item/9789240000124"),
        make(.holick2011VitaminD, "Endocrine Society 2011 (Vitamin D)", 2011, "https://doi.org/10.1210/jc.2011-0385"),
        make(.jonklaas2014AtaThyroid, "ATA 2014 Hypothyroidism", 2014, "https://doi.org/10.1089/thy.2014.0028"),
        make(.pearson2003Crp, "AHA/CDC 2003 (hs-CRP)", 2003, "https://doi.org/10.1161/01.CIR.0000052939.59093.45"),
        make(.who2024Haemoglobin, "WHO 2024 Haemoglobin Cut-offs", 2024, "https://www.who.int/publications/i/item/9789240088542"),
        make(
            .abimLabReferenceRanges,
            "ABIM Laboratory Test Reference Ranges",
            2026,
            "https://www.abim.org/Media/bfijryql/laboratory-reference-ranges.pdf"
        ),
        make(.frid2016InjectionTechnique, "Frid 2016 (Injection Technique, FITTER)", 2016, "https://doi.org/10.1016/j.mayocp.2016.06.010"),
        make(.nes2011FitnessAge, "Nes 2011 (HUNT Fitness Age)", 2011, "https://doi.org/10.1249/MSS.0b013e31821d3f6f"),
        make(.who2011Waist, "WHO 2011 Waist Circumference", 2011, "https://www.who.int/publications/i/item/9789241501491"),
        make(.leong2015Grip, "Leong 2015 (Grip Strength, PURE)", 2015, "https://doi.org/10.1016/S0140-6736(14)62000-6"),
        make(.ats2002SixMinuteWalk, "ATS 2002 (Six-Minute Walk Test)", 2002, "https://doi.org/10.1164/ajrccm.166.1.at1102"),
        make(
            .who2018Noise,
            "WHO 2018 Environmental Noise Guidelines",
            2018,
            "https://www.who.int/europe/publications/i/item/9789289053563"
        ),
        make(.appleEcg, "Apple Support — ECG app", 2024, "https://support.apple.com/en-us/HT208955"),
        make(.appleIrregularRhythm, "Apple Support — Irregular rhythm notification", 2024, "https://support.apple.com/en-us/HT208931"),
        make(.appleWalkingSteadiness, "Apple Support — Walking Steadiness", 2024, "https://support.apple.com/en-us/102504"),
        make(.appleSleepApnea, "Apple Support — Sleep apnea notifications", 2024, "https://support.apple.com/en-us/120031"),
        make(.studenski2011GaitSpeed, "Studenski 2011 (Gait Speed)", 2011, "https://doi.org/10.1001/jama.2010.1923")
    ]

    private static let byID: [MedicalSourceID: MedicalSource] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func source(_ id: MedicalSourceID) -> MedicalSource {
        // Every case is in `all`; the test pins it. Crash here would be a catalog bug.
        // swiftlint:disable:next force_unwrapping
        byID[id]!
    }

    /// Public `/learn` guides, for the hub's "Further reading" section.
    public static let learnGuides: [HLLearnGuide] = HLLearnLinks.guides
}
