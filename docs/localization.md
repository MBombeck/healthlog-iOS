# Localization

HealthLog speaks German, English and Dutch (Dutch thanks to the contribution in #29). This page describes how the app decides which language it speaks, what it tells the server, the rules for medical text, the on-device model, the doctor report, and how a new language gets in. The checklist at the end was walked through with Dutch in 1.5.

## How the app picks its language

`AppLanguage` (`HealthLog/Util/AppLanguage.swift`) is the one place that decides the interface language. It reads `Bundle.main.preferredLocalizations.first`, which iOS resolves against the languages the app ships (`CFBundleLocalizations`), so it is always the language the visible copy is in. A language the app does not ship reads English, the catalogs' `sourceLanguage` and the language iOS itself falls back to. A French iPhone therefore runs the English interface and gets English everywhere, never German.

`Locale.current` stays right for what is a property of the device: region, calendar, number and date formats, the hour cycle. It is wrong for the language, because it names the device language, which the app may not ship.

What `AppLanguage` offers:

| | Use |
|---|---|
| `AppLanguage.current` | the interface language (`de`, `en`, `nl`) |
| `serverCode` | the `locale` for every server route that takes all interface languages |
| `chatServerCode()` | the `locale` for the Coach and document chat bodies, see below |
| `regionTag` | `<language>-<REGION>` from the device region (`nl-BE`, `de-AT`, `en-PT`), for fields that take a free tag |
| `formattingLocale` | language plus device region when that pair is a real locale (`nl_BE`, `en_DE`), else the language's home locale (`nl` on a German phone formats as `nl_NL`) |
| `locale` | the bare language as a `Locale` |

The pinned day-month-year date preference uses a day-first locale in the interface language (`de_DE`, `en_GB`, `nl_NL`), so month names match the copy around them.

**The guard.** `scripts/i18n-guard.py` fails the lint step when app code outside `AppLanguage.swift` asks for `.languageCode`, `preferredLocalizations` or `Locale.preferredLanguages`. The exceptions live in `_LANGUAGE_ALLOWLIST` in the script, each with a reason and the exact number of hits; the list only shrinks. Today it holds only the support info (it reports the raw bundle localization and decides nothing). `python3 scripts/i18n-guard.py --self-test` shows the rule biting.

**A new language** starts as a new `case` in `AppLanguage`. Every exhaustive `switch` over it then fails to compile until it has an answer, and the tests that loop over `AppLanguage.allCases` say what else is missing.

## What the app tells the server

The app sends its language with each request. It never changes the account language (`PUT /api/auth/me/locale`): that setting also switches the web interface, and someone who reads the web in German and the phone in English would be surprised. Messages the server schedules on its own (reminders, digests) follow the language in the web profile.

| Route | Value | Older server |
|---|---|---|
| Insights narrative, metric status, prefetch, chart detail | `serverCode` | an unknown language falls back to the account language on the server |
| Doctor report PDF (`POST /api/export/health-record`, body `locale`) | the report language chosen on the sharing screen, by default the interface language; `nl` only from server 1.43.7 | the schema is a strict enum, so an older server would answer 422 to `nl`; the app asks for English instead |
| Coach chat, document chat (body `locale`) | `de` and `en` always; any other language only from server 1.46.2, else the field is left out | without the field the server uses the account language, then `Accept-Language` |
| Questionnaire (`locale`, `englishOriginal`) | `regionTag` (`nl-BE`, `de-AT`, `en-US`); `englishOriginal: true` only when the reader switched to the English original, and only to server 1.46.0 or newer | `locale` is free text on every server; older servers know fewer countries and answer with the international crisis set, and never see `englishOriginal` |

Server versions are read through `KnownServerVersion.isAtLeast(_:)`; an unknown version counts as too old.

## Questionnaires and crisis contacts

**Questionnaire text never lives in a string catalog.** The PHQ-9, GAD-7, WHO-5 and SCI items, their stems, answer labels and the PHQ-9 follow-up question are validated instruments: a changed word changes what they measure. The server keeps them in code, one module per instrument and language (`src/lib/mental-health/wording/<instrument>/<language>.ts`), each saying whether it reproduces a published validated translation (with its source) or is a translation written for HealthLog. The app bundles exactly that text:

```sh
scripts/l10n/sync-questionnaire-wording.py --server-ref v1.46.6          # write the files
scripts/l10n/sync-questionnaire-wording.py --server-ref v1.46.6 --check  # compare only
scripts/l10n/sync-questionnaire-wording.py --self-test
```

It reads the server repository at a tag (`--server-repo`, else `$HEALTHLOG_SERVER_REPO`, else `../../HealthLog` from the main checkout) and writes `HealthLog/Resources/Questionnaires/questionnaire-wording.<language>.json` for every `AppLanguage` case. Each file names the tag, the commit and the blob of every module it came from. A new language needs its modules on the server first; the script fails when one is missing. After a run, paste the SHA-256 values it prints into `QuestionnaireWordingLockstepTests`, which fails on any hand edit. `scripts/check-strings.sh` fails if a questionnaire key (`mentalHealth.items.*`, `stems`, `options`, `who5Options`, `sciOptions`, `functional`) comes back into the catalog.

**Punctuation.** The visible-punctuation gate allows no em dash, en dash, middle dot or arrow and gets no exception for questionnaires. Where a printed form uses one, the script applies a reasoned entry of its `PUNCTUATION` table (PHQ-9 item 6 in English and Dutch: the dash before "or"/"of" becomes a comma; item 8 in English: a colon) and turns a range between two numbers in the SCI answers into the language's range word ("46 to 60 min", "46 bis 60 Min.", "46 tot 60 min"). Every change is recorded in the file. A dash the table does not cover fails the run.

**Unvalidated translations.** Where the reader's text is HealthLog's own translation (server 1.46.6: the SCI in German and Dutch), the form says so in one line and offers a centred text link to the English original and back. A reader who answered in the original sends `englishOriginal: true` (server 1.46.0+). Results and history rows read `wording` from the server and say once when the answers were given in an unvalidated translation; a row without the field (before 1.46) looks as it did.

**Crisis contacts.** On a positive PHQ-9 item 9 the set in the server's response is shown. Offline, on a failed or older server, and when a flagged history row is reopened, the app resolves its bundled copy (`CrisisResourceFallback`), a line-for-line copy of `crisisResourcesForLocale` in `src/lib/mental-health/crisis-resources.ts` at v1.46.6 (`CrisisResourceFallbackLockstepTests`). Because the app sends `regionTag`, a Belgian Dutch reader gets 1813, a Dutch one 113, an Austrian 142, a US reader 988, and an English interface on a Portuguese phone the international set, never the Brazilian lines alone. The server derives a country only from German, Portuguese and Dutch tags or a bare country code; an English interface in Belgium gets the international set until the server reads the region of every tag. Resource names are medical keys (`mentalHealth.crisisResource.<id>.name`), taken word for word from the server's `messages/<language>.json`. A resource a newer server adds before the app knows its name shows its contact lines without a name, never a raw key.

To update: bump the tag in the script call and in `QuestionnaireWordingCatalog.serverRef`, rerun, re-pin the hashes, compare `crisis-resources.ts` with `CrisisResourceFallback` and update both the copy and the lockstep fixtures, then add the names of new resources in every language.

## Tests and screenshots

- `AppLanguageTests` and `AppLanguageRequestLocaleTests` pin the rules above, including a French device (resolved with the same algorithm iOS uses at launch) and the chat bodies against servers 1.46.1, 1.46.2 and an unknown one.
- `AppLanguage.$pinned.withValue(.nl) { ... }` runs code under another interface language inside a unit test. The unit suite itself runs German (`-testLanguage de -testRegion DE`), because it checks German copy.
- Catalog tests take their languages from `AppLanguage.allCases` and the gate status in `scripts/l10n/languages.json` (`HealthLogTests/Support/CatalogLanguages.swift`): `required` languages must be complete, `pending` ones are only checked for what is there.
- UI tests launch a language through `UITestLanguage` (`HealthLogUITests/Support/UITestLanguage.swift`): `de`, `en`, `nl`, and `pseudoDouble`, the English interface with every string doubled (`-NSDoubleLocalizedStrings YES`) to find truncation before a longer language exists. The screenshot sweep takes `HL_SWEEP_LANG=de|en|nl|pseudo`, the marketing rig `HL_MARKETING_LANG`.

## Medical text

1. Validated questionnaire items come only from the server's wording modules, never from a translation and never from the string catalog.
2. Crisis numbers come only from the server's crisis resources, never typed by hand.
3. Disclaimers, crisis names, questionnaire notes and anything with a threshold are medical keys (`scripts/l10n/medical-keys.json`). A value in any language other than German lands as `needs_review` (`scripts/xcstrings-add.py` sets it), and the release gate (`check-catalog-format.py --release`) stops while a required language still has one. A person signs it off by setting the state to `translated`, with name and date in the change that does it.
4. No diagnosis, recommendation or prediction, in any language. On-device text only runs in a language that has safety filter rows.
5. Word choice follows the server's `messages/<language>.json`; the app addresses the reader informally, like the German "du" (Dutch "je", not "u").

## The on-device model

Several features run on Apple's on-device model: the Mini-Coach, the on-device Coach, the daily briefing, trend observations, reminder phrases, mood tag suggestions and medication extraction. They follow the interface language, and each language has to bring the same safety net.

**Prompts.** Every prompt builder in `HealthLog/Services/AI/` resolves its language with `AppLanguage.resolve(locale)` and picks its text through `AppLanguage.pick(de:en:nl:)` (`AppLanguage+PromptCopy.swift`) or an exhaustive `switch`. A new language does not compile until every prompt has its text. Each instruction block carries the same rules in its own words: no diagnosis, no prediction, no dose or therapy advice, no drug-level interpretation, no causal claims, and a hand-off to a doctor in the wording the safety filter exempts.

**Safety filter.** `MDRSafetyFilter` checks every generated text before anyone sees it. German and English share the base rows in `MDRSafetyFilter.swift`, Dutch has its own twins in `MDRSafetyFilter+Dutch.swift`, and the exemptions (citing a guideline, handing off to a clinician, never as a wrapper around a dose or therapy) live in `MDRSafetyFilter+Exemptions.swift`. Every row runs on every text, so adding a language can only make the filter stricter. `MDRSafetyFilter.rows(for:)` names the rows per language, and `MiniCoachAskClassifier.denyLabels(for:)` names the Mini-Coach's refusal rows for advice, prediction and injection asks; both are exhaustive switches.

**Language gate.** `OnDeviceLanguageGate` decides whether an on-device feature runs at all. It needs both: rows in the safety filter and the classifier for the language, and `SystemLanguageModel.supportsLocale(_:)` saying yes for the language's home locale. If either is missing, the feature reports "not available" (`languageUnsupported`, or the hidden on-device card for the Coach). It never answers in English under a Dutch interface. The model check is a switch with a shipped default; `OnDeviceLanguageGateSimulatorTests` holds the evidence for it on the iOS 27.2 simulator.

**Tests a new language must pass.** `OnDeviceLanguageSafetyTests` runs over `AppLanguage.allCases`: each language needs filter and classifier rows, a refusal corpus of diagnosis, dose, therapy, prediction, causal and drug-level statements that both the full filter and the language's own rows refuse, allowed observations, citations and hand-offs, refused advice and injection asks, and guard marks in every prompt. A source check fails when a file under `Services/AI/` calls the model without the gate.

## The doctor report

The on-device doctor report (the PDF the sharing screen makes when the server cannot) prints its fixed words from its own table, `HealthLog/Resources/DoctorReport.xcstrings`, not from the app catalog. Each key is a case of `DoctorReportString` (`HealthLog/Services/PDF/DoctorReportStrings.swift`), and the value is read from the `<language>.lproj` of the **report language**, not the interface language. That is the point: someone with an English iPhone can print a German report for a doctor in Germany. Metric names come from the app catalog's table of the report language, numbers and dates use the report language's home locale (`de_DE`, `en_US`, `nl_NL`), never the device region, because the reader is someone else.

**Choosing the language.** The report starts in the interface language. Under "Advanced" below the practice card on the sharing screen, a picker lists every report language by its own name. The same value goes to the server report (`/api/export/health-record`, with English instead of Dutch for a server older than 1.43.7). The FHIR export stays German (German care context), and the ZIP package sends no language, as before.

**A new report language** follows from a new `AppLanguage` case: `ReportLocale` has an exhaustive initialiser from it, so the build fails until the report knows the language. Then translate the table (Xcode's catalog editor or `scripts/xcstrings-add.py --catalog HealthLog/Resources/DoctorReport.xcstrings`). The catalog gate (`check-catalog-format.py`) treats the table like the other five catalogs: a pending language needs a value or an English placeholder for every key (`fill-placeholders.py` writes them), and the format specifiers must match English. `DoctorReportLanguageTableTests` reads the built table of every `AppLanguage` and fails on a missing key, a key the code does not read, or a label that does not fill its arguments; it also renders a Dutch PDF and checks its text.

**Medical keys.** The disclaimer on every page (`report.disclaimer`), the adherence sentences (`report.adherence.`), the vitals heading and the medication headings are medical keys. A new value in any language but German lands as `needs_review` and needs a person's sign-off. The German and English values are the 1.4 wording moved into the table, so they stay `translated`; since 1.5 the German values are spelled with umlauts ("Einträge", "auf-Gerät") instead of the transliterations the hand-written report used, with no other change.

To look at the PDFs yourself, run the suite `DoctorReportLanguageTablePDFExport` with `TEST_RUNNER_HL_REPORT_PDF_DIR=<folder>` on the xcodebuild line; it writes `doctor-report-de.pdf`, `-en.pdf` and `-nl.pdf` there and nothing without the variable.

## A language that is not finished yet

A new language ships in steps. `scripts/l10n/languages.json` lists it as `pending` first, and only after its translation pass as `required`. A pending language is already in `CFBundleLocalizations`, so iOS picks it for a reader whose phone speaks it, while some keys still have no translation. Dutch went this way in 1.5: `pending` from L10N-NL, `required` since L10N-FINAL.

**Pending never means a raw key on screen.** The bundle looks a key up in the table of the interface language and does not fall back to English. A key without a Dutch value would show its identifier (`settings.foo.title`) on a Dutch phone. So every gap of a pending language carries an English placeholder: the English block of that key, copied, with every value in state `needs_review`. The screen reads English until the translation replaces it.

- `scripts/xcstrings-add.py` writes the placeholder for every pending language the input does not name, so a new key never opens a gap.
- `python3 scripts/l10n/fill-placeholders.py` fills every gap in all five catalogs. It changes nothing on a second run. Run it after merging a branch that added keys before the language was listed.
- `python3 scripts/l10n/check-catalog-format.py` fails on any key without a value in any listed language, pending or required. It counts the placeholders per pending language (for example "pending nl: 313 English placeholder(s)") and fails on any placeholder left in a required language. A placeholder is recognised by its shape: the same text as English in every value, every value `needs_review`. That is the work list for the translation pass, and the pass is done when a language turns `required` and the gate stays green.
- `PendingLanguageFallbackTests` reads the built bundle one language table at a time and fails on any dotted key that resolves to itself.

**Why `needs_review` and not a gap.** A gap is invisible to the reader only for keys that are English sentences; for a dotted key it is a raw identifier. A placeholder keeps the screen readable and stays visible to every tool: Xcode marks it for review, the gate counts it and refuses it in a required language. The price is that `needs_review` now has two meanings in a pending language, a medical value awaiting sign-off and an English placeholder; the placeholder is told apart by its English text. A medical sign-off must therefore never touch a placeholder: it translates first, then signs off.

**Exemptions.** `scripts/l10n/placeholder-exemptions.json` lists key prefixes whose gaps stay open, only for keys another change is removing or rewriting at the same time, where a placeholder would collide in the merge. Each prefix must still match a key with a gap; once that change is merged, the gate fails on the stale prefix and the entry goes. The list only shrinks.

## Medical sign-off

A medical value in a language other than German stays `needs_review` until a person has read it. Two ways out:

- **Server wording.** Where the server's `messages/<language>.json` has the same text under the same area (`mentalHealth.*`, `records.life.*` for `life.*`), the value is the server's, word for word, with placeholders rewritten (`{cutoff}` becomes `%lld`). It counts as approved by the server (plan, decision 16), is set to `translated`, and its catalog comment names the server version and key ("Approved as server wording (Decision 16): nl from server v1.47.0 messages `records.life.auditC.above`, word for word."). A text that only resembles the server's, or a short word the server uses elsewhere, does not count.
- **A person's sign-off.** Everything else is listed on the review sheet of the language (kept with the maintainer, for Dutch: German, English and Dutch side by side, with the origin). Once someone has read it:

```sh
python3 scripts/l10n/signoff-medical.py --language nl --by "Name" --date 2026-11-20 --dry-run   # what would change
python3 scripts/l10n/signoff-medical.py --language nl --by "Name" --date 2026-11-20
python3 scripts/l10n/signoff-medical.py --self-test
```

It sets the remaining medical `needs_review` values of that language to `translated` and appends a line to `scripts/l10n/medical-signoff.json`: name, date, number of values, and a SHA-256 fingerprint of exactly the text that was approved. It never signs an English placeholder (`l10n_common.is_placeholder`): it lists it and exits 2, because a placeholder is not a translation. After the sign-off, `check-catalog-format.py --release` (freeze pregates) passes for that language.

## Checklist: a new language

Walked through with Dutch in 1.5 (units L10N-CORE to L10N-FINAL). In order:

1. **Code.** A new `case` in `AppLanguage` (`HealthLog/Util/AppLanguage.swift`). The build then fails at every exhaustive `switch` until it has an answer: prompts (`AppLanguage.pick`), `MDRSafetyFilter.rows(for:)` and `MiniCoachAskClassifier.denyLabels(for:)` with their own rows, `ReportLocale`, the OCR order, the date preference. Add the refusal corpus of the language to `OnDeviceLanguageSafetyTests`.
2. **Server first.** The server needs `messages/<language>.json`, the questionnaire wording modules (`src/lib/mental-health/wording/<instrument>/<language>.ts`) and, if a country uses the language, its crisis set. Then `scripts/l10n/sync-questionnaire-wording.py --server-ref <tag>` and re-pin the hashes.
3. **List it as `pending`.** `scripts/l10n/languages.json` and `CFBundleLocalizations` of all five targets in `project.yml`. `python3 scripts/l10n/fill-placeholders.py` gives every gap its English placeholder, so no screen shows a raw key.
4. **Permission texts.** `HealthLog/Resources/<language>.lproj/InfoPlist.strings` with every purpose string English has (only the app target has them; `PermissionDeclarationTests` checks every listed language).
5. **Translate.** The work list is the placeholder count of `check-catalog-format.py`. Take the server's wording wherever it has the same text, keep the informal address, no "·", "—", "–", "→". Siri phrases live in `AppShortcuts.xcstrings` and must keep every `${…}` token; the in-app examples in `SettingsSiriShortcutsScreen` quote them. The doctor report has its own table (`DoctorReport.xcstrings`). Apple Health data types use the names the Health app shows in that language (the simulator runtime's `HealthKit.framework/<language>.lproj/Localizable-DataTypes.strings`).
6. **Medical keys.** Server wording word for word counts as approved; everything else stays `needs_review` and goes on the review sheet (section above).
7. **Fixtures.** The hermetic server (`HealthLog/App/HermeticFixtures+*`) answers prose in the interface language, as the real server does; add the language wherever it branches on `AppLanguage`.
8. **Make it `required`** once the placeholder count is 0. From then on every gap fails the gates and the catalog tests hold the language to completeness.
9. **Check.** The language suites with `-testLanguage <language>`, the screenshot sweep with `HL_SWEEP_LANG=<language>` (light, dark, `pseudo` and accessibility sizes), looking at every picture for raw keys, English and cut text. The unit suite itself stays German.
10. **Before the freeze.** A person reads the review sheet, `signoff-medical.py` records it, `check-catalog-format.py --release` passes. Then the App Store entry of the language (store texts, screenshots).

## Siri and Shortcuts phrases

App Shortcut phrases (`HealthLogAppShortcuts`) are localized only in `HealthLog/Resources/AppShortcuts.xcstrings`. The key is the English phrase with `${applicationName}` and `${parameter}` tokens (`Log ${kind} in ${applicationName}`); a value may reorder the tokens but must keep all of them, `${applicationName}` included. Siri never reads phrases from `Localizable.xcstrings`; until 1.5 they sat there and the German corpus in `Metadata.appintents/root.ssu.yaml` was English. The catalog is in `l10n_common.CATALOGS`, so `check-catalog-format.py` (including the token check) and `fill-placeholders.py` cover it, and `AppShortcutPhraseCatalogTests` fails when a phrase in code has no key or a key no phrase. Short titles stay in `Localizable`. The in-app examples in `SettingsSiriShortcutsScreen` quote the German phrases word for word; change both together.

## Merging string catalogs

The app ships six string catalogs (`*.xcstrings`). `scripts/xcstrings-add.py` adds new keys at the end of `"strings"`, so two branches that each add a key change the same lines, and git's line merge reports a conflict even though nothing actually collides.

`scripts/l10n/merge-xcstrings.py` is a git merge driver that merges catalogs by key instead:

- Keys from both sides are united. The result keeps our order and appends the keys only the other side has, in its order. That is exactly the file `xcstrings-add.py` would write after adding both sets of keys.
- A key changed on one side only takes that change, including a deletion.
- A key changed on both sides is merged per field and per language. Only the same language (or field) changed differently on both sides, or deleted on one side and changed on the other, is a conflict.
- On a conflict the driver lists every conflicting key and language, leaves git's usual conflict markers in the file and exits non-zero, so git reports the path as conflicted.
- The result keeps the separator style of the file (`"key": value` or Xcode's older `"key" : value`), so a merge with no changes is byte-identical.

`.gitattributes` assigns the driver with `*.xcstrings merge=xcstrings`. Git does not run drivers from the repository by itself, so register it once per clone (worktrees share the clone's config):

```sh
git config merge.xcstrings.name "string catalog merge"
git config merge.xcstrings.driver "python3 scripts/l10n/merge-xcstrings.py %O %A %B"
```

Without the registration git silently falls back to the line merge, so check it with `git config --get merge.xcstrings.driver`. To see the driver work end to end, including a real `git merge` in a scratch repository:

```sh
python3 scripts/l10n/merge-xcstrings.py --self-test
```

When the driver reports a conflict, resolve it in Xcode's catalog editor or by hand, then run `python3 scripts/l10n/check-catalog-format.py` and `scripts/check-strings.sh` before committing.
