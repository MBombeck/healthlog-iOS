// Diese Suite haengt an `AppContainer` (App-Target-only) — im SPM-Library-Build
// gibt es weder AppContainer noch die App-Target-Stores, also wird die Datei
// dort uebersprungen.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    /// **D-12-05-A — Research Mode is retired server-side; prove iOS followed.**
    ///
    /// The server deleted `/api/auth/me/research-mode` on 2026-08-08 in
    /// `0160052289e4` ("retire Research Mode — the switch governed nothing") and
    /// dropped the three user columns in
    /// `prisma/migrations/0321_drop_research_mode_columns`. Its own words say what
    /// replaced the capability: *"The chart stopped consulting the flag several
    /// releases ago and has painted for every account since… The curve is simply
    /// part of the medication page now."* No handler exists at the accepted pin
    /// `v1.37.24` (`e00d013459d8`) and `researchMode` / `research-mode` occur zero
    /// times in its OpenAPI, so nothing took the capability over — the **gate** is
    /// what went away, not the curve.
    ///
    /// **Why this suite is written the way it is.** A removal cannot be proved by a
    /// test that names the removed symbols: such a test stops compiling the moment
    /// the removal lands, so it can only ever run against the broken tree. Every
    /// assertion here is therefore expressed over things that survive the
    /// removal — the source tree read as data, the composition read by reflection,
    /// the string catalogue, the device's persisted domain and its on-disk cache.
    /// All six cases compile and run before *and* after, which is what makes four
    /// of them honest behavioural RED.
    ///
    /// **Why the update path and not a fresh start.** A fresh install carries no
    /// state from the previous build, so a removal that strands old state passes
    /// every fresh-install test while every real device stays broken. The fixture
    /// below is an *installation*: the previous build's residue planted in the
    /// persisted defaults domain, and a SwiftData cache store written by one
    /// `SWRCache` and reopened by another — previous build writes, new build reads.
    /// The medication in that cache is a catalogue-recognised GLP-1 brand, because
    /// that is the only case that renders the drug-level section at all.
    @MainActor
    @Suite("Research Mode retirement — the update path (D-12-05-A)", .serialized)
    struct ResearchModeRetirementUpdatePathTests {
        // MARK: - 1. The route

        /// The defect itself: the shipped app addresses a route that has answered
        /// 404 on every live instance since 2026-08-08.
        @Test("no shipped source addresses the retired research-mode route")
        func noShippedSourceAddressesTheRetiredRoute() throws {
            let offenders = try Self.shippedSourcesContaining(Self.retiredRoute)
            if !offenders.isEmpty {
                Self.markRed(
                    case: "retired-route",
                    detail: "still addressed by \(offenders.joined(separator: ", "))"
                )
            }
            #expect(
                offenders.isEmpty,
                "D-12-05-A the shipped app still addresses the retired research-mode route"
            )
        }

        // MARK: - 2. The composition

        /// An orphaned store is the other half of the same defect: a member that
        /// can only ever talk to a route that is gone. The sweep is by reflection
        /// over the real composition root, so it cannot be satisfied by deleting a
        /// mention in a comment.
        @Test("the composition carries no research-mode store or repository")
        func compositionCarriesNoResearchModeMember() throws {
            let container = try Self.makeContainer()
            let offenders = Mirror(reflecting: container).children.compactMap { child -> String? in
                let label = child.label ?? "<unlabelled>"
                let typeName = String(describing: type(of: child.value))
                let names = label.lowercased().contains("research")
                    || typeName.lowercased().contains("researchmode")
                return names ? "\(label): \(typeName)" : nil
            }
            if !offenders.isEmpty {
                Self.markRed(
                    case: "orphaned-composition",
                    detail: "AppContainer still exposes \(offenders.joined(separator: ", "))"
                )
            }
            #expect(
                offenders.isEmpty,
                "D-12-05-A the composition root still exposes a research-mode member"
            )
        }

        // MARK: - 3. The surfaces

        /// Two identifiers, two dead surfaces: the Settings switch whose POST 404s,
        /// and the load-failed card with the retry that can never succeed. Both are
        /// asserted by their accessibility identifiers, because those are what a UI
        /// test would still be able to reach if the views were merely hidden.
        @Test("no shipped surface declares the research-mode toggle or its failure card")
        func noShippedSurfaceDeclaresTheRetiredControls() throws {
            var offenders: [String] = []
            for identifier in Self.retiredAccessibilityIdentifiers {
                let files = try Self.shippedSourcesContaining(identifier)
                if !files.isEmpty {
                    offenders.append("\(identifier) in \(files.joined(separator: ", "))")
                }
            }
            if !offenders.isEmpty {
                Self.markRed(
                    case: "retired-controls",
                    detail: offenders.joined(separator: " | ")
                )
            }
            #expect(
                offenders.isEmpty,
                "D-12-05-A a retired research-mode control is still declared"
            )
        }

        // MARK: - 4. The copy

        /// Removing a control means removing its words too, in every language the
        /// catalogue actually carries — measured here rather than assumed, so a
        /// third locale added later cannot be silently skipped.
        @Test("the string catalogue carries no research-mode copy in any language present")
        func stringCatalogueCarriesNoResearchModeCopy() throws {
            let catalogue = try Self.stringCatalogue()
            let languages = Self.languages(in: catalogue)
            #expect(
                languages == ["de", "en"],
                "the catalogue's language set moved; extend this census before shipping"
            )

            var offenders: [String] = []
            for (key, entry) in catalogue {
                var texts = [key]
                let localizations = (entry["localizations"] as? [String: Any]) ?? [:]
                for (_, value) in localizations {
                    if let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any],
                       let text = unit["value"] as? String
                    {
                        texts.append(text)
                    }
                }
                if texts.contains(where: Self.namesTheRetiredControl) {
                    offenders.append(String(key.prefix(60)))
                }
            }
            if !offenders.isEmpty {
                Self.markRed(
                    case: "retired-copy",
                    detail: "\(offenders.count) key(s): \(offenders.sorted().joined(separator: " / "))"
                )
            }
            #expect(
                offenders.isEmpty,
                "D-12-05-A the catalogue still carries copy for the retired research-mode control"
            )
        }

        // MARK: - 5. The update path proper

        /// The case the operator's standing rule exists for. An installation that
        /// carried the previous build's state must reach a working drug-level
        /// screen, and none of that state may be read back by the new code.
        ///
        /// Green in both directions by construction — it is the guard that a later
        /// "cleanup" cannot start reading the residue, and that the removal did not
        /// take the cached medication row with it.
        @Test("the previous build's persisted state is carried, unread, to a working curve")
        func previousBuildResidueIsNeverReadBack() async throws {
            let defaults = UserDefaults.standard
            for (key, value) in Self.previousBuildResidue {
                defaults.set(value, forKey: key)
            }
            defer { Self.previousBuildResidue.keys.forEach(defaults.removeObject(forKey:)) }

            // The update: the new build's composition root opens on a device that
            // already holds the previous build's domain.
            _ = try Self.makeContainer()

            // (a) Nothing read it, so nothing changed it.
            for (key, expected) in Self.previousBuildResidue {
                #expect(
                    String(describing: defaults.object(forKey: key) ?? "<absent>") == String(describing: expected),
                    "the new build modified a key it should not even know about: \(key)"
                )
            }

            // (b) Nothing can read it: no shipped source names any residue key.
            for key in Self.previousBuildResidue.keys {
                let readers = try Self.shippedSourcesContaining(key)
                #expect(readers.isEmpty, "a shipped source reads retired persisted state \(key): \(readers)")
            }

            // (c) The new build writes no research-mode key of its own.
            let ownKeys = defaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix("hl.") && Self.namesTheRetiredControl($0) }
                .filter { Self.previousBuildResidue[$0] == nil }
                .sorted()
            #expect(ownKeys.isEmpty, "the new build persists research-mode state of its own: \(ownKeys)")

            // (d) The cached medication row written by the previous build is still
            //     readable by the new build, and still resolves to the chart's
            //     precondition: a catalogue-recognised GLP-1 drug with dose events.
            let storeURL = try Self.freshCacheStoreURL()
            defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

            let previousBuild = try SWRCoordinator(
                cache: Self.openCache(at: storeURL),
                reachability: StubOfflineReachability()
            )
            await previousBuild.writeThrough(.medicationsList, value: [Self.glp1Medication])

            let newBuild = try Self.openCache(at: storeURL)
            let carried = await newBuild.read(.medicationsList, as: [Medication].self)
            let medications = try #require(carried?.value, "the update lost the previous build's cached medication list")
            let medication = try #require(medications.first)

            let detail = try MedicationDetailStore(
                medication: medication,
                repo: MedicationsRepository(api: OfflineStubAPIClient(), outbox: OutboxQueue(inMemory: true))
            )
            detail._testInject(intakes: [
                PaginatedIntakeEvent(
                    id: "carried-intake",
                    takenAt: Date(timeIntervalSince1970: 1_770_000_000),
                    skipped: false,
                    scheduledFor: Date(timeIntervalSince1970: 1_770_000_000)
                )
            ])
            #expect(detail.isGLP1Recognised, "the carried medication must still render the drug-level section")
            #expect(detail.drug != nil)
            #expect(detail.pkDoseEvents().isEmpty == false, "the curve has its doses without any server gate")
        }

        // MARK: - 6. The regulatory ceiling

        /// The disclaimer is the half of this feature that must NOT be deleted with
        /// the gate. The server kept exactly this sentence
        /// (`medications.researchMode.chart.estimateNote`) when it dropped the
        /// dialog, and the y-axis stays unit-less.
        @Test("the drug-level disclaimer and the unit-less axis survive the removal")
        func disclaimerSurvivesTheRemoval() throws {
            let catalogue = try Self.stringCatalogue()
            for key in Self.survivingChartCopy {
                let entry = try #require(catalogue[key], "the MDR chart copy was deleted with the gate: \(key)")
                let localizations = try #require(entry["localizations"] as? [String: Any])
                #expect(
                    Set(localizations.keys) == ["de", "en"],
                    "the MDR chart copy lost a language: \(key)"
                )
            }
            let caption = try #require(catalogue[Self.estimateNoteKey])
            let localizations = try #require(caption["localizations"] as? [String: Any])
            for (language, value) in localizations {
                let text = ((value as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                #expect(text.contains("EMA"), "the EMA attribution is missing in \(language)")
            }
            let axis = try #require(catalogue[Self.axisLabelKey])
            let axisLocalizations = try #require(axis["localizations"] as? [String: Any])
            for (language, value) in axisLocalizations {
                let text = ((value as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                for unit in ["ng/mL", "ng/ml", "µg/L", "ug/L", "mol/L", "mg/L"] {
                    #expect(!text.contains(unit), "the y-axis caption gained a unit token in \(language): \(unit)")
                }
            }
        }
    }

    // MARK: - Fixtures

    @MainActor
    extension ResearchModeRetirementUpdatePathTests {
        static let retiredRoute = "/api/auth/me/research-mode"

        static let retiredAccessibilityIdentifiers = [
            "settings.advanced.researchModeToggle",
            "med.researchMode.loadFailed"
        ]

        /// What the previous build's installation carries into the update. iOS
        /// never persisted research-mode state — these keys are planted so the
        /// assertion is fail-closed rather than vacuous: if a fix ever starts
        /// reading local acknowledgment state, the census names the reader.
        static let previousBuildResidue: [String: String] = [
            "hl.researchMode.enabled": "true",
            "hl.researchMode.acknowledgedVersion": "2026-05-14.1",
            "hl.researchMode.acknowledgedAt": "2026-02-01T00:00:00Z",
            "hl.mdr.disclaimerAcknowledgedVersion": "2026-05-14.1"
        ]

        static let estimateNoteKey =
            "Educational estimate from EMA-published population pharmacokinetics. Not a measurement."
        static let axisLabelKey = "Estimated level (relative)"
        static var survivingChartCopy: [String] {
            [estimateNoteKey, axisLabelKey, "Estimated drug level"]
        }

        static let glp1Medication = Medication(
            id: "med_carried_from_previous_build",
            name: "Trulicity 7.5 mg",
            dose: "7.5 mg",
            treatmentClass: "GLP1",
            schedule: MedicationSchedule(times: [], weekdays: nil)
        )

        /// Needles that name the retired control rather than the surviving curve.
        /// Deliberately does not include "drug level" or "Wirkstoffspiegel": the
        /// chart keeps both, and a census that convicted them would push a fix
        /// toward deleting the thing the server kept.
        static func namesTheRetiredControl(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return lowered.contains("research mode")
                || lowered.contains("researchmode")
                || lowered.contains("forschungsmodus")
                || lowered.contains("drug-level view")
        }

        static func markRed(case identifier: String, detail: String) {
            print("EXPECTED_RED: case=\(identifier) reason=\(detail)")
        }
    }

    // MARK: - Reading the tree as data

    @MainActor
    extension ResearchModeRetirementUpdatePathTests {
        /// Every shipped Swift source of the app target, comment-stripped. Comments
        /// are dropped on purpose: this suite judges what the binary does, and a
        /// historical note that names the retired route is prose, not a request.
        static func shippedSourcesContaining(_ needle: String) throws -> [String] {
            var hits: [String] = []
            for relativePath in try shippedSourcePaths() {
                let source = try Phase8SourceScan.stripped(relativePath)
                if source.contains(needle) { hits.append(relativePath) }
            }
            return hits.sorted()
        }

        static func shippedSourcePaths() throws -> [String] {
            let root = Phase8SourceScan.repositoryRoot.appendingPathComponent("HealthLog", isDirectory: true)
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw CensusFailure.unreadableSourceRoot
            }
            var paths: [String] = []
            for case let url as URL in walker where url.pathExtension == "swift" {
                paths.append("HealthLog/" + url.path.replacingOccurrences(
                    of: root.path + "/",
                    with: ""
                ))
            }
            // A census that read nothing would pass every assertion in this file.
            guard paths.count > 400 else { throw CensusFailure.implausibleSourceCount(paths.count) }
            return paths.sorted()
        }

        static func stringCatalogue() throws -> [String: [String: Any]] {
            let url = Phase8SourceScan.repositoryRoot
                .appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
            let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let root = parsed as? [String: Any],
                  let strings = root["strings"] as? [String: [String: Any]],
                  strings.count > 4000 else
            {
                throw CensusFailure.unreadableCatalogue
            }
            return strings
        }

        static func languages(in catalogue: [String: [String: Any]]) -> [String] {
            var found: Set<String> = []
            for (_, entry) in catalogue {
                guard let localizations = entry["localizations"] as? [String: Any] else { continue }
                found.formUnion(localizations.keys)
            }
            return found.sorted()
        }

        enum CensusFailure: Error {
            case unreadableSourceRoot
            case implausibleSourceCount(Int)
            case unreadableCatalogue
        }
    }

    // MARK: - The installation fixture

    @MainActor
    extension ResearchModeRetirementUpdatePathTests {
        static func makeContainer() throws -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
        }

        /// A cache store on disk, in a directory of this run's own, so "previous
        /// build" and "new build" are two openings of one file rather than two
        /// in-memory stores that never met.
        static func freshCacheStoreURL() throws -> URL {
            let base = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("hl-12-10-update-path-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("cache.sqlite")
        }

        static func openCache(at url: URL) throws -> SWRCache {
            let schema = Schema(versionedSchema: CacheSchemaV1.self)
            let configuration = ModelConfiguration(
                "HealthLogCache.updatePath",
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            return try SWRCache(
                modelContainer: ModelContainer(
                    for: schema,
                    migrationPlan: nil,
                    configurations: [configuration]
                )
            )
        }
    }

    /// Offline on purpose: the update path this suite models is a device opening a
    /// medication it already has, and the retired route is unreachable anyway.
    private final class StubOfflineReachability: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { continuation in
                    continuation.yield(false)
                    continuation.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            false
        }

        func confirmedReachable() async -> Bool {
            false
        }
    }

    private final class OfflineStubAPIClient: APIClientProtocol, @unchecked Sendable {
        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.canceled
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            throw HLError.canceled
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

#endif // !SWIFT_PACKAGE
