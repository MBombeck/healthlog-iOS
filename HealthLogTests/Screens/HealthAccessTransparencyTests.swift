// Diese Suite liest App-Target-Symbole (`SettingsHealthAccessScreen`,
// `HealthKitService`), die in der SPM-Library nicht enthalten sind.
#if !SWIFT_PACKAGE

    import Foundation
    #if canImport(HealthKit)
        import HealthKit
    #endif
    @testable import HealthLog
    import Testing

    /// **Phase 16 Plan 03 — the 5.1.3(i) page moves with the type sets.**
    ///
    /// This is the Auflage the operator attached to his own E2 answer, in his
    /// own words: a larger first permission dialog with an unchanged
    /// transparency page would be a review risk, not a detail. So the two halves
    /// ship together, and "the page still renders" is explicitly not evidence.
    ///
    /// What is evidence is **derivation**: the page's read and write lists must
    /// come out of `HealthKitService.defaultReadTypes` / `defaultWriteTypes` —
    /// the same two sets handed to `requestAuthorization(read:write:)` — with
    /// nothing added by a toggle and nothing listed twice. Before this plan the
    /// ECG and State-of-Mind identifiers reached the page through conditional
    /// joins that existed *because* the types were opt-in-only; leaving that
    /// scaffolding standing next to an unconditional membership would double-list
    /// both types the moment a user turned either switch on.
    ///
    /// The reproductive/cycle set stays conditional and is asserted to stay
    /// conditional: it is a separate opt-in with its own legal surface, men are
    /// never prompted for it, and E2 says nothing about it.
    @Suite("Phase 16 — the 5.1.3(i) page derives from the enlarged type sets")
    struct HealthAccessTransparencyTests {
        #if canImport(HealthKit)

            @Test("the transparency page lists ECG and State of Mind unconditionally and exactly once")
            func transparencyListsTheEnlargedSetOnce() throws {
                let ecg = HKObjectType.electrocardiogramType().identifier
                let mood = HKObjectType.stateOfMindType().identifier

                var violations: [String] = []

                // The unconditional half — the sets the system sheet is built
                // from are the sets the page is built from.
                let read = HealthKitService.defaultReadTypes.map(\.identifier)
                let write = HealthKitService.defaultWriteTypes.map(\.identifier)
                if !read.contains(ecg) { violations.append("the page cannot list an ECG the read set does not ask for") }
                if !read.contains(mood) { violations.append("the page cannot list a mood read the set does not ask for") }
                if !write.contains(mood) { violations.append("the page cannot list a mood write the set does not ask for") }

                // The conditional scaffolding — it exists only because the two
                // types were opt-in-only, and it must be gone rather than left
                // lying next to an unconditional membership.
                let page = try Self.strippedSource(Self.pagePath)
                if page.contains("moodSyncTypeIdentifiers") {
                    violations.append("the page still joins State of Mind through a toggle-gated helper")
                }
                if page.contains("ecgTypeIdentifiers") {
                    violations.append("the page still joins the ECG type through a toggle-gated helper")
                }

                // And the doc comments must stop describing the old world: a
                // page whose prose says a type is "deliberately kept OUT of the
                // default sets" while the set contains it is a review risk
                // written down.
                let prose = try Self.rawSource(Self.pagePath)
                if prose.contains("deliberately kept OUT of the default sets (the") {
                    violations.append("the page's own comments still call State of Mind a settings-only opt-in")
                }

                #expect(
                    violations.isEmpty,
                    "EXPECTED_RED: the 5.1.3(i) page still derives ECG/mood conditionally"
                )
            }

            /// **The derivation itself, not the rendering.** E2's Auflage is
            /// that this page moves with the type sets, and "it still renders"
            /// would satisfy a page that hard-listed the old roster. What is
            /// asserted here is that the page's own list-building seam returns
            /// exactly the authorization sets, so a type added to the sheet
            /// tomorrow appears here without anyone editing this file.
            @Test("both lists are the authorization sets, element for element")
            func listsAreDerivedFromTheAuthorizationSets() {
                let read = SettingsHealthAccessScreen.readTypeIdentifiers(cycleIdentifiers: [])
                let write = SettingsHealthAccessScreen.writeTypeIdentifiers(cycleIdentifiers: [])

                #expect(Set(read) == Set(HealthKitService.defaultReadTypes.map(\.identifier)))
                #expect(Set(write) == Set(HealthKitService.defaultWriteTypes.map(\.identifier)))
                #expect(read.count == Set(read).count, "no identifier reaches the page twice")
                #expect(write.count == Set(write).count)

                // The two types E2 moved, present exactly once each on the list
                // that asks for them.
                let ecg = HKObjectType.electrocardiogramType().identifier
                let mood = HKObjectType.stateOfMindType().identifier
                #expect(read.filter { $0 == ecg }.count == 1)
                #expect(read.filter { $0 == mood }.count == 1)
                #expect(write.filter { $0 == mood }.count == 1)
                #expect(!write.contains(ecg), "the app never writes a waveform back")

                // And the rows the page actually renders carry them, resolved
                // to names rather than raw identifiers.
                let rows = SettingsHealthAccessScreen.rows(identifiers: read, statuses: [:], showsStatus: false)
                #expect(rows.filter { $0.id == ecg }.count == 1)
                #expect(rows.filter { $0.id == mood }.count == 1)
                for row in rows where row.id == ecg || row.id == mood {
                    #expect(row.name != row.id, "the 5.1.3(i) page must not show a raw identifier: \(row.id)")
                }

                // The gated set still joins when the gate is open, and still
                // only then — the mechanism survives for the type it is for.
                let withCycle = SettingsHealthAccessScreen.readTypeIdentifiers(
                    cycleIdentifiers: CycleHealthKitImporter.readCategoryTypes().map(\.identifier)
                )
                #expect(withCycle.count > read.count)
            }

            @Test("the cycle set stays conditional — E2 said nothing about it")
            func cycleSetStaysConditional() throws {
                let page = try Self.strippedSource(Self.pagePath)
                #expect(
                    page.contains("cycleTypeIdentifiers"),
                    """
                    The reproductive set is a separate opt-in with its own legal surface and men are never \
                    prompted for it (`CycleGate.isCycleTrackingAvailable`). E2 moved EKG and Stimmung; it \
                    did not move this.
                    """
                )
                // It is also still outside the default sets, which is what makes
                // the conditional join necessary rather than duplicative.
                let defaults = Set(
                    HealthKitService.defaultReadTypes.map(\.identifier)
                        + HealthKitService.defaultWriteTypes.map(\.identifier)
                )
                for identifier in CycleHealthKitImporter.readCategoryTypes().map(\.identifier) {
                    #expect(!defaults.contains(identifier), "a cycle type leaked into the always-on sheet: \(identifier)")
                }
            }

            @Test("every identifier the page can show resolves to a localised name")
            func enlargedSetIsFullyNamed() {
                let identifiers = HealthKitService.defaultReadTypes.map(\.identifier)
                    + HealthKitService.defaultWriteTypes.map(\.identifier)
                for identifier in identifiers {
                    #expect(
                        HealthAccessTypeNaming.localizationKey(for: identifier) != nil,
                        "the enlarged set puts a raw identifier on the 5.1.3(i) page: \(identifier)"
                    )
                }
            }

        #endif

        // MARK: - Source access

        private static let pagePath = "HealthLog/Screens/Settings/Sub/SettingsHealthAccessScreen.swift"

        private static let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        static func rawSource(_ relativePath: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }

        static func strippedSource(_ relativePath: String) throws -> String {
            try stripLineComments(from: stripBlockComments(from: rawSource(relativePath)))
        }

        private static func stripBlockComments(from source: String) -> String {
            var out = ""
            var rest = Substring(source)
            while let open = rest.range(of: "/*") {
                out += rest[..<open.lowerBound]
                guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
                rest = rest[close.upperBound...]
            }
            return out + rest
        }

        private static func stripLineComments(from source: String) -> String {
            source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                var quoted = false
                var previous: Character = " "
                for (offset, character) in line.enumerated() {
                    if character == "\"", previous != "\\" { quoted.toggle() }
                    if !quoted, character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                    previous = character
                }
                return String(line)
            }.joined(separator: "\n")
        }
    }

#endif
