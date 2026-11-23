#!/usr/bin/env bash

# Hermetic fixture suite for the design ratchets: scripts/design-ratchet.sh,
# scripts/check-sheet-scaffold.sh and scripts/check-delete-ladder.sh.
#
# Every case builds a small screen tree under one temporary root with a copy of
# the real .swiftlint.yml, so the rule patterns under test are the ones the
# repository ships. Nothing outside the temporary root is written.
#
# No `set -e`: a case that fails is counted and reported, and the run goes on
# to the next case, so one broken check does not hide the others.

set -uo pipefail

TD_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TD_REPO="$(cd "$TD_SOURCE/.." && pwd)"
TD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hl-design-ratchet-test.XXXXXX")"
trap 'rm -rf -- "$TD_ROOT"' EXIT
TD_CASES=0
TD_FAILED=0

td_fail() {
    printf 'test-design-ratchets: FAIL %s\n' "$1" >&2
    if [[ -f "$TD_ROOT/case.log" ]]; then sed 's/^/    /' "$TD_ROOT/case.log" >&2; fi
    TD_FAILED=$((TD_FAILED + 1))
}

# td_run <expected status> <script> [arguments]: runs one entry point of the
# fixture tree and records its output in case.log.
td_run() {
    local expected="$1" script="$2" status=0
    shift 2
    "$TD_TREE/scripts/$script" "$@" >"$TD_ROOT/case.log" 2>&1 || status=$?
    TD_CASES=$((TD_CASES + 1))
    if [[ "$status" -ne "$expected" ]]; then
        td_fail "$TD_CASE: $script $* exited $status, wanted $expected"
        return 1
    fi
}

td_log_has() {
    grep -Eq -- "$1" "$TD_ROOT/case.log" || { td_fail "$TD_CASE: output lacks /$1/"; return 1; }
}

td_count() {   # td_count <package> <key>
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["counts"][sys.argv[2]])' \
        "$TD_TREE/scripts/design-ratchets/$1.json" "$2"
}

td_want_count() {   # td_want_count <package> <key> <value>
    local actual
    actual="$(td_count "$1" "$2")"
    [[ "$actual" == "$3" ]] || td_fail "$TD_CASE: $1 $2 is $actual, wanted $3"
}

td_digest() {
    find "$TD_TREE/scripts" -type f -print0 | sort -z | xargs -0 shasum | shasum
}

td_write() {   # td_write <relative path>, content on stdin
    mkdir -p "$(dirname "$TD_TREE/$1")"
    cat >"$TD_TREE/$1"
}

td_exceptions() {   # td_exceptions sheet|delete|page <json array>
    local name="check-sheet-scaffold-exceptions.json"
    [[ "$1" == "delete" ]] && name="check-delete-ladder-exceptions.json"
    [[ "$1" == "page" ]] && name="check-page-scaffold-exceptions.json"
    printf '{"schema": 1, "exceptions": %s}\n' "$2" >"$TD_TREE/scripts/$name"
}

# A fresh tree: three package directories, one finding of R8 in Settings, a
# finding in a comment that must not count, an onboarding-only button size and
# one sheet type without the scaffold.
td_fresh() {
    TD_CASE="$1"
    TD_TREE="$TD_ROOT/$1"
    mkdir -p "$TD_TREE/scripts"
    cp "$TD_REPO/.swiftlint.yml" "$TD_TREE/.swiftlint.yml"
    local script
    for script in design-ratchet.py design-ratchet.sh check-sheet-scaffold.sh check-delete-ladder.sh; do
        cp -p "$TD_SOURCE/$script" "$TD_TREE/scripts/$script"
    done
    td_exceptions sheet '[]'
    td_exceptions delete '[]'
    td_exceptions page '[]'
    td_write HealthLog/Screens/Settings/SettingsA.swift <<'SWIFT'
struct SettingsA: View {
    var body: some View {
        // HLSettingsCard( in a comment does not count
        HLSettingsCard(title: "a") { Text("x") }
        HLButton("Go", size: .large) {}
    }
}
SWIFT
    td_write HealthLog/Screens/Onboarding/StepA.swift <<'SWIFT'
struct StepA: View {
    var body: some View { HLButton("Go", size: .large) {} }
}
SWIFT
    td_write HealthLog/Screens/Mood/MoodEditSheet.swift <<'SWIFT'
struct MoodEditSheet: View {
    var body: some View { Text("\(value("}"))") }
}
SWIFT
}

td_init() {
    td_run 0 design-ratchet.sh --init || return 1
}

# ---------------------------------------------------------------------------

td_fresh init-and-check
if td_init; then
    td_want_count C1 hl_no_settingscard 1
    td_want_count C1 hl_button_large_only_onboarding 1
    td_want_count C3 hl_button_large_only_onboarding 0
    td_want_count C4 sheet_without_scaffold 1
    before="$(td_digest)"
    td_run 0 design-ratchet.sh --check && td_log_has 'design-ratchet: PASS'
    [[ "$(td_digest)" == "$before" ]] || td_fail "$TD_CASE: --check changed a file"
fi

td_fresh growth-fails
if td_init; then
    before="$(td_digest)"
    printf 'let more = HLSettingsCard(title: "b") {}\n' >>"$TD_TREE/HealthLog/Screens/Settings/SettingsA.swift"
    td_run 1 design-ratchet.sh && td_log_has 'C1 hl_no_settingscard 1 -> 2 GREW'
    [[ "$(td_digest)" == "$before" ]] || td_fail "$TD_CASE: a grown count was written"
    td_run 1 design-ratchet.sh --check && td_log_has 'GREW'
    [[ "$(td_digest)" == "$before" ]] || td_fail "$TD_CASE: --check wrote after growth"
fi

td_fresh lowering-rewrites
if td_init; then
    sed -i '' '/HLSettingsCard(title: "a")/d' "$TD_TREE/HealthLog/Screens/Settings/SettingsA.swift"
    before="$(td_digest)"
    td_run 1 design-ratchet.sh --check && td_log_has 'C1 hl_no_settingscard 1 -> 0 STALE'
    [[ "$(td_digest)" == "$before" ]] || td_fail "$TD_CASE: --check wrote a lowered count"
    td_run 0 design-ratchet.sh && td_log_has 'C1 hl_no_settingscard 1 -> 0 lowered'
    td_want_count C1 hl_no_settingscard 0
    td_run 0 design-ratchet.sh --check
fi

td_fresh missing-file-needs-init
if td_init; then
    rm "$TD_TREE/scripts/design-ratchets/C2.json"
    td_run 1 design-ratchet.sh && td_log_has 'C2.json is missing'
    [[ ! -e "$TD_TREE/scripts/design-ratchets/C2.json" ]] || td_fail "$TD_CASE: a missing file was recreated"
fi

td_fresh hand-edit-is-not-canonical
if td_init; then
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); open(p,"w").write(json.dumps(d))' \
        "$TD_TREE/scripts/design-ratchets/C3.json"
    td_run 1 design-ratchet.sh --check && td_log_has 'not in canonical form'
fi

td_fresh unassigned-directory
td_write HealthLog/Screens/Brandnew/NewScreen.swift <<'SWIFT'
struct NewScreen: View { var body: some View { Text("x") } }
SWIFT
td_run 2 design-ratchet.sh --init && td_log_has 'Brandnew belongs to no package'

td_fresh sheet-scaffold-counts-done
td_write HealthLog/Screens/Mood/MoodNoteSheet.swift <<'SWIFT'
struct MoodNoteSheet: View {
    var body: some View { HLSheetScaffold("t") { Text("x") } }
}
SWIFT
td_write HealthLog/Screens/Mood/MoodPickSheet.swift <<'SWIFT'
struct MoodPickSheet: View {
    let value: Int
}
SWIFT
td_write HealthLog/Screens/Mood/MoodPickSheet+Body.swift <<'SWIFT'
extension MoodPickSheet {
    var body: some View { HLSheetScaffold("t") { Text("x") } }
}
SWIFT
if td_init; then
    td_want_count C4 sheet_without_scaffold 1
    td_run 0 check-sheet-scaffold.sh && td_log_has 'open HealthLog/Screens/Mood/MoodEditSheet.swift:1 MoodEditSheet'
    td_run 1 check-sheet-scaffold.sh --strict && td_log_has '1 sheet types without HLSheetScaffold'
fi

td_fresh sheet-exception
td_exceptions sheet '[{"type": "MoodEditSheet", "reason": "Pflichtbestätigung ohne Abbrechen."}]'
if td_init; then
    td_want_count C4 sheet_without_scaffold 0
    td_run 0 check-sheet-scaffold.sh --strict
fi

td_fresh sheet-exception-without-reason
td_exceptions sheet '[{"type": "MoodEditSheet", "reason": "ok"}]'
td_run 1 check-sheet-scaffold.sh && td_log_has 'has no reason'
td_run 1 design-ratchet.sh --init && td_log_has 'has no reason'
[[ ! -e "$TD_TREE/scripts/design-ratchets/C1.json" ]] || td_fail "$TD_CASE: an invalid list still wrote"

td_fresh sheet-exception-stale
td_exceptions sheet '[{"type": "GoneSheet", "reason": "Gibt es nicht mehr im Baum."}]'
td_run 0 check-sheet-scaffold.sh && td_log_has 'STALE sheet exception GoneSheet'
td_run 1 check-sheet-scaffold.sh --strict && td_log_has 'ERROR sheet exception GoneSheet'

td_fresh delete-ladder
td_write HealthLog/Screens/Settings/DeleteRows.swift <<'SWIFT'
struct DeleteRows: View {
    var body: some View {
        Button(role: .destructive) { remove() } label: { Text("a") }
        HLDeleteButton(action: .confirmed(title: "t") { Button(role: .destructive) {} })
        // hl-delete-ladder: stage-3 eigener Bestätigungsbildschirm für das Konto
        HLSettingsActionRow(title: "x", role: .destructive) {}
        Button("b", role: .destructive) {} // role: .destructive in a comment
        Button("c", role: .destructive) {}
    }
}
SWIFT
td_exceptions delete '[{"path": "HealthLog/Screens/Settings/DeleteRows.swift", "anchor": "remove()", "reason": "Abmelden löscht keine Daten."}]'
if td_init; then
    td_want_count C1 delete_without_ladder 2
    td_run 0 check-delete-ladder.sh && td_log_has 'C1 5 destructive roles, 1 in the ladder, 1 stage 3, 1 exceptions, 2 open'
    td_run 1 check-delete-ladder.sh --strict && td_log_has 'outside the ladder'
fi

td_fresh delete-from-a-menu
td_write HealthLog/Screens/Settings/DeleteMenu.swift <<'SWIFT'
struct DeleteMenu: View {
    var body: some View {
        Menu {
            Button("Edit") {}
            HLDeleteMenuItem(.confirmed(title: "t") { Button(role: .destructive) {} })
            HLDeleteMenuItem(.undoable { remove() })
        } label: { Text("a") }
        Menu {
            Button(role: .destructive) { remove() } label: { Text("b") }
        } label: { Text("c") }
    }
}
SWIFT
if td_init; then
    td_want_count C1 delete_without_ladder 1
    td_run 0 check-delete-ladder.sh && td_log_has 'C1 2 destructive roles, 1 in the ladder, 0 stage 3, 0 exceptions, 1 open'
    td_log_has 'open HealthLog/Screens/Settings/DeleteMenu.swift:9'
    td_run 1 check-delete-ladder.sh --strict && td_log_has 'outside the ladder'
fi

td_fresh delete-marker-without-reason
td_write HealthLog/Screens/Settings/DeleteRows.swift <<'SWIFT'
struct DeleteRows: View {
    var body: some View {
        Button(role: .destructive) {} // hl-delete-ladder: stage-3
    }
}
SWIFT
td_run 1 check-delete-ladder.sh && td_log_has 'stage 3 marker without a reason'
td_run 1 design-ratchet.sh --init && td_log_has 'stage 3 marker without a reason'

td_fresh delete-exception-checks
td_exceptions delete '[{"path": "HealthLog/Screens/Settings/SettingsA.swift", "anchor": "signOut", "reason": "Steht im Baum nicht mehr, ist veraltet."}]'
td_run 0 check-delete-ladder.sh && td_log_has 'STALE delete exception .* covers no open destructive role'
td_run 1 check-delete-ladder.sh --strict
td_exceptions delete '[{"path": "HealthLog/Screens/Settings/SettingsA.swift", "anchor": "signOut"}]'
td_run 1 check-delete-ladder.sh && td_log_has 'has no reason'
td_write HealthLog/Screens/Settings/TwoRows.swift <<'SWIFT'
struct TwoRows: View {
    var body: some View {
        Button(role: .destructive) { signOut() } label: { Text("a") }
        Text("between")
        Text("between")
        Button(role: .destructive) { signOut() } label: { Text("b") }
    }
}
SWIFT
td_exceptions delete '[{"path": "HealthLog/Screens/Settings/TwoRows.swift", "anchor": "signOut", "reason": "Ein Anker, der zwei Stellen trifft."}]'
td_run 1 check-delete-ladder.sh && td_log_has 'covers 2 destructive roles'
td_write HealthLog/Screens/Settings/TwoRows.swift <<'SWIFT'
struct TwoRows: View {
    var body: some View {
        Button(role: .destructive) { a() } label: { Text("a") }
        Text("signOut")
        Button(role: .destructive) { b() } label: { Text("b") }
    }
}
SWIFT
td_run 1 check-delete-ladder.sh && td_log_has 'line 4 is as close to line 3 as to 5'

td_fresh init-only-once
if td_init; then
    td_run 1 design-ratchet.sh --init && td_log_has '--init only creates missing files'
    td_run 0 design-ratchet.sh --force-init && td_log_has 'wrote scripts/design-ratchets/C1.json'
fi

td_fresh grew-message-names-the-code
if td_init; then
    printf 'let more = HLSettingsCard(title: "b") {}\n' >>"$TD_TREE/HealthLog/Screens/Settings/SettingsA.swift"
    td_run 1 design-ratchet.sh --check && td_log_has 'fix the code'
    if grep -q 'commit the lowered files' "$TD_ROOT/case.log"; then td_fail "$TD_CASE: GREW suggests committing"; fi
fi

# R1 and R2 are bound to HLButton(: other builders with a size do not count,
# a call over several lines and with nested parentheses does, a comment line
# does not, and a comment between the arguments does not hide the call.
td_fresh button-binding
td_write HealthLog/Screens/Settings/Buttons.swift <<'SWIFT'
struct Buttons: View {
    var body: some View {
        HLSheetScaffold("x", size: .compact) { Text("x") }
        HLDashboardTile(size: .large) { Text("x") }
        HLValueText(1, unit: .kilogram, size: .large)
        HLButton("a", size: .compact) {}
        HLButton(
            String(localized: "b \(format(value(1)))"),
            // a note between the arguments
            variant: .ghost
        ) {}
        // HLButton("c", size: .compact)
        HLButton("d", variant: .primary) {}
    }
}
SWIFT
if td_init; then
    td_want_count C1 hl_no_rejected_button_variant 2
    td_want_count C1 hl_button_large_only_onboarding 1
fi

# F9: R19 and R20 count free fonts and text colours outside comments and
# onboarding, an icon font is free; R21 counts a ladder step from 16 pt on
# and not a role; S3 counts a titled scroll page without the page scaffold
# until it is listed with a reason.
td_fresh f9-roles
td_write HealthLog/Screens/Settings/Roles.swift <<'SWIFT'
struct Roles: View {
    var body: some View {
        ScrollView {
            Text("a").font(.hlHeadline).foregroundStyle(HLText.primary)
            // Text("b").font(.hlBody)
            Image(systemName: "x").font(.hlIcon(13))
            Text("c").hlText(.rowTitle)
            VStack(spacing: HLSpace.lg) {}
            VStack(spacing: HLLayout.cardGap) {}
            Text("d").padding(.top, HLSpace.xxl)
        }
        .navigationTitle("Roles")
    }
}
SWIFT
td_write HealthLog/Screens/Onboarding/Free.swift <<'SWIFT'
struct Free: View {
    var body: some View { Text("a").font(.hlLargeTitle) }
}
SWIFT
if td_init; then
    td_want_count C1 hl_free_font 1
    td_want_count C1 hl_free_text_color 1
    td_want_count C1 hl_free_page_spacing 2
    td_want_count C1 page_without_scaffold 1
    td_exceptions page '[{"path": "HealthLog/Screens/Settings/Roles.swift", "reason": "full-bleed camera preview"}]'
    td_run 1 design-ratchet.sh --check && td_log_has 'C1 page_without_scaffold 1 -> 0 STALE'
    td_exceptions page '[{"path": "HealthLog/Screens/Settings/Gone.swift", "reason": "full-bleed camera preview"}]'
    td_run 1 design-ratchet.sh --check && td_log_has 'ERROR page exception HealthLog/Screens/Settings/Gone.swift names no open page'
fi

# R4 counts Button( only, over several lines, and not the cancel role of a
# dialog. R11 counts upper case only as display, R13 leaves clock formats to
# R12, R15 also knows "Retry".
td_fresh pattern-edges
td_write HealthLog/Screens/Settings/Edges.swift <<'SWIFT'
struct Edges: View {
    var body: some View {
        Button("Cancel", role: .cancel) {}
        Button(String(localized: "Cancel"), role: .cancel) {}
        Button(
            "Save"
        ) {}
        HLButton("Cancel", variant: .secondary) {}
        Text(label.uppercased())
        if code.uppercased() == "X" { Text("y") }
        Text(String(format: "%02d:%02d", h, m))
        Text(String(format: "%.1f", v))
        Text(date.formatted(
            .dateTime.day()))
        HLButton("Retry", variant: .secondary) {}
    }
}
SWIFT
if td_init; then
    td_want_count C1 hl_no_literal_sheet_verbs 1
    td_want_count C1 hl_no_uppercase_header 1
    td_want_count C1 hl_number_via_helper 1
    td_want_count C1 hl_date_via_helper 2
    td_want_count C1 hl_single_retry_key 1
fi

# The base: a package file raised by hand passes the plain check and fails
# against the commit it started from; a base without the files falls back.
td_git_commit() {
    git -C "$TD_TREE" add -A
    git -C "$TD_TREE" -c user.name=t -c user.email=t@example.invalid commit -q -m "$1"
}
td_fresh base-comparison
git -C "$TD_TREE" init -q
td_git_commit before
base_without="$(git -C "$TD_TREE" rev-parse HEAD)"
if td_init; then
    td_git_commit ratchets
    printf 'let more = HLSettingsCard(title: "b") {}\n' >>"$TD_TREE/HealthLog/Screens/Settings/SettingsA.swift"
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["counts"]["hl_no_settingscard"]+=1; open(p,"w").write(json.dumps(d,indent=2,ensure_ascii=False)+"\n")' \
        "$TD_TREE/scripts/design-ratchets/C1.json"
    td_run 0 design-ratchet.sh --check && td_log_has 'no base given'
    td_run 1 design-ratchet.sh --check --base HEAD && td_log_has 'C1 hl_no_settingscard is 2, above 1 at base HEAD'
    td_run 0 design-ratchet.sh --check --base "$base_without" && td_log_has 'C1.json is not at base'
    td_run 2 design-ratchet.sh --check --base no-such-ref && td_log_has 'is not a commit'
fi

# Stage 3 markers: listed with file and line, held by the limit, and the
# limit itself cannot be raised against the base.
td_fresh stage3-limit
td_write HealthLog/Screens/Settings/Stage3.swift <<'SWIFT'
struct Stage3: View {
    var body: some View {
        // hl-delete-ladder: stage-3 eigener Bildschirm zum Löschen des Kontos
        HLSettingsActionRow(title: "a", role: .destructive) {}
        // hl-delete-ladder: stage-3 eigener Bildschirm zum Zurücksetzen aller Daten
        HLSettingsActionRow(title: "b", role: .destructive) {}
    }
}
SWIFT
git -C "$TD_TREE" init -q
if td_init; then
    td_git_commit ratchets
    td_run 0 design-ratchet.sh --check && td_log_has 'C1 stage-3 HealthLog/Screens/Settings/Stage3.swift:3'
    td_write HealthLog/Screens/Settings/Stage3b.swift <<'SWIFT'
struct Stage3b: View {
    var body: some View {
        // hl-delete-ladder: stage-3 noch ein eigener Bildschirm, einer zu viel
        HLSettingsActionRow(title: "c", role: .destructive) {}
    }
}
SWIFT
    td_run 1 design-ratchet.sh --check && td_log_has 'C1 has 3 stage 3 markers, the limit is 2'
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["limits"]["delete_stage3"]=3; open(p,"w").write(json.dumps(d,indent=2,ensure_ascii=False)+"\n")' \
        "$TD_TREE/scripts/design-ratchets/C1.json"
    td_run 0 design-ratchet.sh --check
    td_run 1 design-ratchet.sh --check --base HEAD && td_log_has 'C1 limit delete_stage3 is 3, above 2 at base HEAD'
fi

td_fresh stage3-elsewhere
td_write HealthLog/Screens/Mood/MoodStage3.swift <<'SWIFT'
struct MoodStage3: View {
    var body: some View {
        // hl-delete-ladder: stage-3 hier gibt es keinen eigenen Bildschirm
        Button(role: .destructive) {}
    }
}
SWIFT
td_run 1 design-ratchet.sh --init && td_log_has 'C4 has 1 stage 3 markers, the limit is 0'

# The UI standard baseline is an upper bound that only the central refresh
# lowers: growth fails and writes nothing, a lower count is written, --check
# never writes.
td_fresh ui-standard-baseline
mkdir -p "$TD_TREE/HealthLogTests/DesignSystem" "$TD_TREE/HealthLogTests/Resources"
cp "$TD_REPO/HealthLogTests/DesignSystem/UIStandardBaselineTests.swift" "$TD_TREE/HealthLogTests/DesignSystem/"
cp -p "$TD_SOURCE/refresh-ui-standard-baseline.py" "$TD_TREE/scripts/"
td_write HealthLog/Screens/Settings/Toggles.swift <<'SWIFT'
struct Toggles: View {
    var body: some View {
        Toggle("a", isOn: $a)
        Toggle("b", isOn: $b)
    }
}
SWIFT
td_ui_baseline() {   # td_ui_baseline <allowed toggles in Toggles.swift>
    printf '{"rules": {"hl_no_handmade_chevron": {}, "hl_no_system_buttonstyle": {}, "hl_no_raw_toggle": {"HealthLog/Screens/Settings/Toggles.swift": %s}, "hl_card_both_slots": {}}}\n' \
        "$1" >"$TD_TREE/HealthLogTests/Resources/UIStandardBaseline.json"
}
td_ui_digest() { shasum "$TD_TREE/HealthLogTests/Resources/UIStandardBaseline.json"; }
td_ui_baseline 1
before="$(td_ui_digest)"
td_run 1 refresh-ui-standard-baseline.py && td_log_has 'Toggles.swift 1 -> 2 GREW'
[[ "$(td_ui_digest)" == "$before" ]] || td_fail "$TD_CASE: a grown UI baseline was written"
td_ui_baseline 3
before="$(td_ui_digest)"
td_run 0 refresh-ui-standard-baseline.py --check && td_log_has '3 -> 2 could be lowered'
[[ "$(td_ui_digest)" == "$before" ]] || td_fail "$TD_CASE: --check wrote the UI baseline"
td_run 0 refresh-ui-standard-baseline.py && td_log_has '3 -> 2 lowered'
grep -q '"HealthLog/Screens/Settings/Toggles.swift": 2' "$TD_TREE/HealthLogTests/Resources/UIStandardBaseline.json" ||
    td_fail "$TD_CASE: the lowered count was not written"

# E3: the action-form rules are held per file. A file can only lower its own
# count; a finding in a new file is growth; menus keep their Label buttons.
td_e3() {   # td_e3 <key> <relative file>
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["counts"][sys.argv[2]].get(sys.argv[3], 0))' \
        "$TD_TREE/scripts/design-ratchets/E3.json" "$1" "$2"
}
td_want_e3() {   # td_want_e3 <key> <relative file> <value>
    local actual
    actual="$(td_e3 "$1" "$2")"
    [[ "$actual" == "$3" ]] || td_fail "$TD_CASE: E3 $1 $2 is $actual, wanted $3"
}

td_fresh e3-per-file
td_write HealthLog/Screens/Mood/MoodRows.swift <<'SWIFT'
struct MoodRows: View {
    var body: some View {
        // .buttonStyle(.plain) in a comment does not count
        Button {} label: { Text("a") }.buttonStyle(.plain)
        Button {} label: { Text("b") }.buttonStyle(.plain)
        Menu { Button { go() } label: { Label("Edit", systemImage: "pencil") } } label: { Text("m") }
        Button { add() } label: { Label("Add", systemImage: "plus") }
    }
}
SWIFT
if td_init; then
    td_want_e3 hl_no_plain_buttonstyle HealthLog/Screens/Mood/MoodRows.swift 2
    td_want_e3 hl_no_form_label_button HealthLog/Screens/Mood/MoodRows.swift 1
    td_run 0 design-ratchet.sh --check
    printf 'let other = Button {} label: { Text("c") }.buttonStyle(.plain)\n' >"$TD_TREE/HealthLog/Screens/Mood/MoodMore.swift"
    td_run 1 design-ratchet.sh && td_log_has 'E3 hl_no_plain_buttonstyle HealthLog/Screens/Mood/MoodMore.swift 0 -> 1 GREW'
    rm "$TD_TREE/HealthLog/Screens/Mood/MoodMore.swift"
    sed -i '' '/Text("b")/d' "$TD_TREE/HealthLog/Screens/Mood/MoodRows.swift"
    td_run 1 design-ratchet.sh --check && td_log_has 'MoodRows.swift 2 -> 1 STALE'
    td_run 0 design-ratchet.sh && td_log_has 'wrote scripts/design-ratchets/E3.json'
    td_want_e3 hl_no_plain_buttonstyle HealthLog/Screens/Mood/MoodRows.swift 1
    rm "$TD_TREE/scripts/design-ratchets/E3.json"
    td_run 1 design-ratchet.sh --check && td_log_has 'E3.json is missing'
    td_run 0 design-ratchet.sh --init && td_log_has 'wrote scripts/design-ratchets/E3.json'
fi

td_fresh usage
td_run 2 design-ratchet.sh --check --init
td_run 2 design-ratchet.sh --init --force-init
td_run 2 check-sheet-scaffold.sh --check

if [[ "$TD_FAILED" -ne 0 ]]; then
    printf 'test-design-ratchets: FAIL (%d of %d checks)\n' "$TD_FAILED" "$TD_CASES" >&2
    exit 1
fi
printf 'test-design-ratchets: PASS (%d runs)\n' "$TD_CASES"
