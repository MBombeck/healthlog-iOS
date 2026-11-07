import SwiftUI

/// **LIFE (1.5.0)** — the questions of one section.
///
/// Follow-up questions appear only where they apply: cigarettes per day only
/// with cigarettes, the quit month only for a former smoker, night work only
/// with shift work. A kind whose current answer this build cannot read in
/// full is shown locked (``LifeSectionDraft`` never writes it). The derived
/// lines are the server's numbers and verdicts, word for word. The alcohol
/// section holds no facts: its content is AUDIT-C (``AuditCSection``).
struct LifeSectionFields: View {
    let section: LifeSection
    let derived: LifeDerived
    @Binding var draft: LifeSectionDraft
    /// The alcohol section's AUDIT-C, `nil` for every other section and on a
    /// server without it.
    var alcohol: AuditCSection?

    var body: some View {
        switch section.key {
        case .tobacco: tobacco
        case .alcohol: alcohol
        case .activity: activity
        case .work: work
        case .habits: habits
        case .goals: goals
        }
    }

    private func locked(_ kind: LifeFactKind) -> Bool {
        section.fact(kind)?.value == .unsupported
    }

    private func id(_ name: String) -> String {
        "life.\(section.key.rawValue).\(name)"
    }

    // MARK: - Tobacco

    @ViewBuilder
    private var tobacco: some View {
        LifeChoiceRow(
            label: String(localized: "life.field.smokingStatus"),
            options: AnamnesisFactKind.smokingStatus.allowedValues,
            title: LifeCopy.smoking,
            selection: $draft.smokingStatus,
            identifier: id("status")
        )
        .disabled(locked(.smokingStatus))
        Group {
            if draft.asksTobaccoDetails {
                LifeMultiChoiceRows(
                    label: String(localized: "life.field.products"),
                    options: LifeTobaccoProduct.allCases,
                    title: LifeCopy.product,
                    selection: $draft.tobacco.products,
                    identifier: id("products")
                )
                if draft.asksCigarettesPerDay {
                    LifeNumberRow(
                        label: String(localized: "life.field.cigarettesPerDay"),
                        range: LifeTobaccoDetail.cigarettesRange,
                        value: $draft.tobacco.cigarettesPerDay,
                        identifier: id("cigarettes")
                    )
                }
                LifeYearRow(
                    label: String(localized: "life.field.startYear"),
                    earliest: LifeTobaccoDetail.earliestStartYear,
                    value: $draft.tobacco.startYear,
                    identifier: id("startYear")
                )
            }
            if draft.asksQuitMonth {
                LifeMonthPickerRow(
                    label: String(localized: "life.field.quitMonth"),
                    value: $draft.tobacco.quitMonth,
                    identifier: id("quitMonth")
                )
            }
            LifeBoolRow(
                label: String(localized: "life.field.secondhandSmoke"),
                value: $draft.tobacco.secondhandSmoke,
                identifier: id("secondhand")
            )
        }
        .disabled(locked(.tobaccoDetail))
        packYears
    }

    /// Pack-years only as the server computed them, or the server's "missing"
    /// sentence for a smoker whose inputs are incomplete.
    @ViewBuilder
    private var packYears: some View {
        if let pack = derived.packYears {
            if pack.status == .computed, let value = pack.value {
                LifeDerivedLine(
                    text: String(localized: "life.derived.packYears \(value.formatted(.number.precision(.fractionLength(1))))"),
                    identifier: "life.derived.packYears"
                )
            } else if pack.status == .missingInputs,
                      let status = draft.smokingStatus, status != .never
            {
                LifeDerivedLine(
                    text: String(localized: "life.derived.packYearsMissing"),
                    secondary: true,
                    identifier: "life.derived.packYearsMissing"
                )
            }
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private var activity: some View {
        Group {
            LifeChoiceRow(
                label: String(localized: "life.field.moderateDaysPerWeek"),
                options: Array(0 ... 7),
                title: { String($0) },
                selection: $draft.activity.moderateDaysPerWeek,
                identifier: id("days")
            )
            LifeNumberRow(
                label: String(localized: "life.field.moderateMinutesPerDay"),
                range: 0 ... 600,
                value: $draft.activity.moderateMinutesPerDay,
                identifier: id("minutes")
            )
            LifeHalfHourRow(
                label: String(localized: "life.field.sittingHoursWorkday"),
                value: $draft.activity.sittingHoursWorkday,
                identifier: id("sitting")
            )
        }
        .disabled(locked(.activityHabit))
        if let minutes = derived.activityMinutesPerWeek {
            if let value = minutes.value {
                LifeDerivedLine(
                    text: String(localized: "life.derived.activityMinutes \(value)"),
                    identifier: "life.derived.activityMinutes"
                )
                if let meets = minutes.meetsWho150 {
                    LifeDerivedLine(
                        text: meets ? String(localized: "life.derived.meetsWho") : String(localized: "life.derived.belowWho"),
                        identifier: "life.derived.who"
                    )
                    LifeSourceLink(source: MedicalSourceCatalog.source(.who2020PhysicalActivity))
                }
            }
            if minutes.measuredStepsAvailable {
                LifeDerivedLine(text: String(localized: "life.derived.measuredSteps"), secondary: true)
            }
        }
    }

    // MARK: - Work

    @ViewBuilder
    private var work: some View {
        Group {
            LifeChoiceRow(
                label: String(localized: "life.field.situation"),
                options: LifeWorkSituation.allCases,
                title: LifeCopy.situation,
                selection: $draft.work.situation,
                identifier: id("situation")
            )
            LifeChoiceRow(
                label: String(localized: "life.field.physicalNature"),
                options: LifeWorkPhysicalNature.allCases,
                title: LifeCopy.physicalNature,
                selection: $draft.work.physicalNature,
                identifier: id("nature")
            )
        }
        .disabled(locked(.workContext))
        LifeChoiceRow(
            label: String(localized: "life.field.shiftSchedule"),
            options: AnamnesisFactKind.shiftSchedule.allowedValues,
            title: LifeCopy.shift,
            selection: $draft.shiftSchedule,
            identifier: id("shift")
        )
        .disabled(locked(.shiftSchedule))
        Group {
            if draft.asksNightWork {
                LifeBoolRow(
                    label: String(localized: "life.field.nightWork"),
                    value: $draft.work.nightWork,
                    identifier: id("nightWork")
                )
            }
            LifeMultiChoiceRows(
                label: String(localized: "life.field.exposures"),
                options: LifeWorkExposure.allCases,
                title: LifeCopy.exposure,
                selection: $draft.work.exposures,
                identifier: id("exposures")
            )
        }
        .disabled(locked(.workContext))
        LifeMultiChoiceRows(
            label: String(localized: "life.field.freeWeekdays"),
            hint: draft.freeWeekdays.isEmpty ? String(localized: "life.derived.freeDaysDefault") : nil,
            options: LifeWeekday.allCases,
            title: LifeCopy.weekday,
            selection: $draft.freeWeekdays.days,
            identifier: id("freeDays")
        )
        .disabled(locked(.freeWeekdays))
    }

    // MARK: - Habits

    private var habits: some View {
        Group {
            LifeBoolRow(
                label: String(localized: "life.field.napRegularly"),
                value: $draft.habits.napRegularly,
                identifier: id("nap")
            )
            LifeBoolRow(
                label: String(localized: "life.field.snoringReported"),
                value: $draft.habits.snoringReported,
                identifier: id("snoring")
            )
            LifeChoiceRow(
                label: String(localized: "life.field.dietPattern"),
                options: LifeDietPattern.allCases,
                title: LifeCopy.diet,
                selection: $draft.habits.dietPattern,
                identifier: id("diet")
            )
            LifeMultiChoiceRows(
                label: String(localized: "life.field.dietSpecifics"),
                options: LifeDietSpecific.allCases,
                title: LifeCopy.dietSpecific,
                selection: $draft.habits.dietSpecifics,
                identifier: id("dietSpecifics")
            )
            LifeChoiceRow(
                label: String(localized: "life.field.lateMealsPerWeek"),
                options: Array(0 ... 7),
                title: { String($0) },
                selection: $draft.habits.lateMealsPerWeek,
                identifier: id("lateMeals")
            )
            LifeNumberRow(
                label: String(localized: "life.field.fruitVegPortionsPerDay"),
                range: 0 ... 15,
                value: $draft.habits.fruitVegPortionsPerDay,
                identifier: id("fruitVeg")
            )
            LifeNumberRow(
                label: String(localized: "life.field.caffeineDrinksPerDay"),
                range: 0 ... 20,
                value: $draft.habits.caffeineDrinksPerDay,
                identifier: id("caffeine")
            )
            LifeChoiceRow(
                label: String(localized: "life.field.latestCaffeine"),
                options: LifeLatestCaffeine.allCases,
                title: LifeCopy.caffeine,
                selection: $draft.habits.latestCaffeine,
                identifier: id("latestCaffeine")
            )
        }
        .disabled(locked(.habits))
    }

    // MARK: - Goals

    private var goals: some View {
        LifeMultiChoiceRows(
            label: String(localized: "life.field.goals"),
            hint: String(localized: "life.field.goalsHint"),
            options: LifeHealthGoal.allCases,
            title: LifeCopy.goal,
            selection: $draft.goals.goals,
            limit: LifeHealthGoal.maximum,
            identifier: id("goals")
        )
        .disabled(locked(.healthGoals))
    }
}

/// One derived sentence of the server, as delivered.
struct LifeDerivedLine: View {
    let text: String
    var secondary = false
    var identifier: String?

    var body: some View {
        Text(verbatim: text)
            .font(secondary ? .hlCaption : .hlSubhead)
            .foregroundStyle(secondary ? HLText.secondary : HLText.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier ?? "")
    }
}

/// "Source: …" as a link, for a verdict that names a guideline.
struct LifeSourceLink: View {
    let label: String
    let url: URL?

    init(source: MedicalSource) {
        label = source.name
        url = source.url
    }

    init(label: String, url: URL?) {
        self.label = label
        self.url = url
    }

    var body: some View {
        let text = String(localized: "life.source \(label)")
        if let url {
            Link(destination: url) {
                Text(verbatim: text)
                    .font(.hlCaption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(HLAccent.userBrandTint)
        } else {
            Text(verbatim: text)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
