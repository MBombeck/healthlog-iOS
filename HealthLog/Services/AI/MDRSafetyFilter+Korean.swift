import Foundation

/// **Korean (ko) twins of the MDR matrix.**
///
/// Each row is the `_ko` twin of a Dutch row family
/// (`MDRSafetyFilter+Dutch.swift`): same `matrixRow`, same exemptions, the same
/// unsafe shape written the way a model writes Korean, in the polite 해요체 and
/// the formal 합니다체 alike. Five more rows (`dose_amount_ko` to
/// `predictive_present_ko`) close shapes a Korean red-team found that the twins
/// let through: a dose by number or by pill, permission to stop, the bare
/// assertion of a condition, and a forecast in the present tense. Lives in
/// its own file only for the `file_length` cap; `MDRSafetyFilter.patterns`
/// concatenates it after the other rows, and like every other row it runs on
/// every text regardless of language, so it can only make the filter stricter.
///
/// Korean attaches particles to the noun ("고혈압이", "약을"), so a word
/// boundary after a Hangul token never matches; these rows carry no `\b`. The
/// vocabulary follows the server's Korean outbound screen
/// (`src/lib/ai/safety/outbound-screen/locales/ko.ts`), cut to this matrix's
/// rows: an imperative counts only where the stem meets its ending directly,
/// so the prohibitive "줄이지 마세요" never matches, and no digit may stand
/// between a medication word and its verb, so "약 2주" ("about two weeks") is
/// not a medication.
extension MDRSafetyFilter {
    static let koreanPatterns: [Pattern] = // swiftlint:disable force_try
        [
            // Row 7 — Predictive language ("오를 거예요", "상승이 예상돼요", "높아질 수 있어요")
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(오를|올라갈|내려갈|떨어질|높아질|낮아질|늘어날|줄어들|상승할|하락할|증가할|감소할|좋아질|나빠질)"#
                        + #"\s*(것|거|겁니다|가능성|전망|수\s*(있|도))|"#
                        + #"(상승|하락|증가|감소|악화|개선)(이|가)?\s*(예상|예측|전망)(돼|됩|된|이에요|입니다)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "predictive_ko"
            ),
            // Row 8 — recommendation verbs. Same pair as `prescriptive`: a
            // cited body ("가이드라인은 … 권장합니다") and the hand-off are
            // excused, never around a dose, medication or therapy.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(권해요|권합니다|권해\s*드려요|권해\s*드립니다|권장해요|권장합니다|권장드려요|"#
                        + #"추천해요|추천합니다|추천드려요|권고해요|권고합니다)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "prescriptive_ko",
                exemptions: [citationExemption, handOffExemption]
            ),
            // Row 9 — Diagnostic claim ("이 수치는 고혈압을 시사해요").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(고혈압|저혈압|당뇨|부정맥|심방세동|갑상선\s*기능\s*(항진|저하)|수면\s*무호흡)"#
                        + #"[^.!?]{0,40}(시사|의심|진단|징후|신호)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_ko"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"진단(을|이)?\s*(내리|내려|드리|드려|돼요|됩니다|된\s*것|할\s*수\s*있)|"#
                        + #"(으로|로)\s*진단|앓고\s*(있|계)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_direct_ko"
            ),
            // Row 11 — Causal medical claim. "때문에" counts only after a
            // metric, and never after missing data, so "혈압 기록이 없기
            // 때문에 평균을…" passes.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(혈압|스트레스|맥박|심박|수면|체중)[^.!?]{0,15}"#
                        + #"(?<!없기\s|없었기\s|부족하기\s|않기\s|않았기\s)(때문|탓|으로\s*인해|로\s*인해)|"#
                        + #"(혈압|스트레스|맥박|심박|수면|체중)[^.!?]{0,30}(유발|초래|야기|원인)|"#
                        + #"(유발|초래|야기|원인)[^.!?]{0,30}(혈압|스트레스|맥박|심박|수면|체중)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 11,
                label: "causal_ko"
            ),
            // Row 14 — Drug-level interpretation (GROUND RULE 10/15 universal)
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"약물\s*농도|혈중\s*약물\s*농도|약효가?\s*(가장\s*)?(최고|정점)|최고\s*농도|최저\s*농도"#,
                    options: .caseInsensitive
                ),
                matrixRow: 14,
                label: "drug_level_ko"
            ),
            // Row 9 (extended) — "병에 걸리셨어요" diagnostic shorthand
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(아프신|아픈|병이\s*있는|병에\s*걸린)\s*(거예요|겁니다|것\s*같|상태)|"#
                        + #"병에\s*걸리(셨|었)|건강에\s*이상이\s*(있|생기)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "sick_claim_ko"
            ),
            // Row 8 (extended) — a therapy or dose change by imperative
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(치료|처방|복용량|용량|약을|약은|약물을|약물은)[^.!?\d]{0,10}"#
                        + #"((바꾸|변경하|조절하|조정하|늘리|줄이|올리|낮추|중단하|끊으)(세요|십시오|셔야|는\s*(게|것이)\s*좋)|"#
                        + #"(바꿔|변경해|조절해|조정해|늘려|줄여|올려|낮춰|중단해|끊어)\s*(보세요|주세요|야\s*(해요|합니다)))"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "therapy_change_ko"
            ),
            // Row 7 (extended) — future-tense risk claim ("뇌졸중 위험")
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(뇌졸중|심근경색|심장마비|심부전|심혈관\s*질환|심장\s*질환)[^.!?]{0,10}(위험|확률|가능성)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "future_risk_ko"
            ),
            // Row 9 (extended) — values pointing at something
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(수치|값|측정값|기록|결과)(이|가|은|는|를|을)?[^.!?]{0,30}(시사|가리키|가리켜|암시)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "values_indicate_ko"
            ),
            // Row 11 (extended) — "증가로 이어졌어요"
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(상승|하락|증가|감소)(으로|로)\s*(이어|연결)|"#
                        + #"(높아지게|낮아지게|올라가게|내려가게|오르게|떨어지게)\s*(해요|합니다|만들|했)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 11,
                label: "leads_to_ko"
            ),
            // Row 8 (extended) — "지금 바로 … 드세요"
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"지금\s*(바로\s*)?[^.!?]{0,10}(드셔야|복용하셔야|드세요|복용하세요|먹어야|드십시오|복용하십시오)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "must_take_now_ko"
            ),
            // Row 14 (extended) — interpret half-life / PK
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(반감기|약동학|혈장\s*농도)[^.!?]{0,30}(의미|시사|나타내|해석|보여|뜻)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 14,
                label: "pharmacokinetic_ko"
            ),
            // Row 9 (extended) — direct condition assertion ("당뇨가 있으세요")
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(고혈압|저혈압|당뇨|부정맥|심방세동|수면\s*무호흡|질환|질병)(이|가)\s*"#
                        + #"(있으세요|있으시네요|있어요|있습니다|있네요|있는\s*것\s*같|맞아요|맞습니다)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "direct_condition_ko"
            ),
            // Row 8 (Mini-Coach C2 twin) — softened advice ("줄여 보세요",
            // "하시면 좋겠어요").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(줄여|늘려|바꿔|낮춰|올려|조절해)\s*보(세요|시는\s*(건|게)|는\s*(건|게)|면)|"#
                        + #"(하시면|하면)\s*(좋겠|좋을\s*것|도움이\s*될\s*것)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "implicit_advice_ko"
            ),
            // Row 9 (Mini-Coach C2 twin) — the condition floated as a
            // possibility ("수면 무호흡일 수 있어요").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(고혈압|저혈압|당뇨|부정맥|무호흡|질환|결핍|장애)[^.!?]{0,20}(일\s*수|있을\s*수|가능성|의심)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_suggestive_ko",
                // R19b — see `reflective_suggestive_de`.
                exemptions: [handOffExemptionUnguarded]
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(혹시|아마|어쩌면)[^.!?]{0,20}(있으실|있을|앓고\s*계실|걸리셨을|걸렸을)\s*(수|지|것|거)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_possibly_ko"
            ),
            // Row 8 (R21 twin) — the Korean "you should": "~해야 해요",
            // "~하는 게 좋아요", "제안해요". "있어야 해요" ("there have to
            // be", as in more readings) names no action and passes. Carries
            // the hand-off exemption like its twins.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(?<!있어)야\s*(해요|합니다|돼요|됩니다)|"#
                        + #"(는|은)\s*(게|것이)\s*(좋아요|좋겠어요|좋습니다|좋을\s*거예요|바람직해요|바람직합니다)|"#
                        + #"(제안해요|제안합니다|제안드려요)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "bare_prescriptive_ko",
                exemptions: [handOffExemption]
            ),
            // Row 8 (extended) — an amount, then a dose verb ("복용량을 10mg으로
            // 늘리세요", "하루 2정 드세요"). A measured value ("물을 500ml
            // 마셨어요", "72.4kg이에요") names no imperative and passes.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"[\d.,]+\s*(mg|mcg|µg|IU|단위|유닛|캡슐|정(?!상|도|확|말)|알(?!레)|ml|cc)(?![A-Za-z]|\s*/\s*(dl|l|min|mmol))"#
                        + #"[^.!?]{0,25}"#
                        + #"((늘리|올리|높이|줄이|내리|낮추|증량하|감량하|중단하|끊으|복용하|드시|드|투여하|맞으|주사하|바꾸|변경하|추가하)"#
                        + #"(세요|십시오|셔야|셔도\s*(돼|됩)|는\s*(게|것이)\s*좋)|"#
                        + #"(늘려|올려|높여|줄여|내려|낮춰|드셔|복용해|투여해|증량해|감량해|추가해)\s*(보세요|주세요|야\s*(해요|합니다)))"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "dose_amount_ko"
            ),
            // Row 8 (extended) — a multiple or an extra pill ("혈압약을 두 배로
            // 드세요", "한 알 더 드시면 좋겠어요").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(약|혈압약|약물|복용량|용량|알약|정제|인슐린)[^.!?\d]{0,12}"#
                        + #"(두\s*배|절반|반\s*알|추가로|(한|두|세)\s*(알|정|캡슐)\s*더|한\s*번\s*더)[^.!?]{0,8}"#
                        + #"(드세요|드십시오|드시면|드시는\s*게|복용하세요|복용하시면|드셔\s*보세요|맞으세요|투여하세요)|"#
                        + #"(반|한|두|세)\s*(알|정)(만|씩|을|를)?\s*(더\s*)?(드세요|드십시오|드시면|드시는\s*게|복용하세요|드셔\s*보세요)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "dose_multiplier_ko"
            ),
            // Row 8 (extended) — permission to stop or change ("약을 끊으셔도 돼요").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(약|약물|복용|투약|치료)[^.!?\d]{0,12}"#
                        + #"(끊으|중단하|건너뛰|줄이|늘리|그만\s*드시|안\s*드시)셔도\s*(돼|됩|괜찮)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "stop_permission_ko"
            ),
            // Row 9 (extended) — the condition asserted outright ("고혈압입니다",
            // "당뇨 상태로 보여요").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(고혈압|저혈압|당뇨|부정맥|심방세동|수면\s*무호흡)"#
                        + #"(입니다|이에요|예요|이세요|이시네요|인\s*것\s*같|\s*상태(로|예요|입니다|이에요))"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_assert_ko"
            ),
            // Row 7 (extended) — a forecast in the present tense ("내일 혈압은
            // 150까지 올라갑니다").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(내일|앞으로|계속|이대로|다음\s*(주|달)|곧)[^.!?]{0,30}"#
                        + #"(올라갑니다|올라가요|높아집니다|높아져요|내려갑니다|내려가요|낮아집니다|낮아져요|떨어집니다|떨어져요|"#
                        + #"늘어납니다|늘어나요|줄어듭니다|줄어들어요|안정될|회복될|좋아질|나빠질|정상화될)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "predictive_present_ko"
            ),
            // R4 §5 (Mini-Coach C2 twin) — prompt-injection marker.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(이전|앞의|앞선|모든|위의)\s*(지시|지침|규칙|명령|프롬프트)[^.!?]{0,6}(무시|잊)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 0,
                label: "prompt_injection_marker_ko"
            )
        ]
    // swiftlint:enable force_try
}
