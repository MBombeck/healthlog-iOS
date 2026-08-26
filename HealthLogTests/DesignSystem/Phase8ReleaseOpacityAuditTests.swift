// Reads app-target sources and the app-target opacity policy; the SPM test
// build contains neither, so it skips the file (repo convention).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Plan 08-12 — the last audited call sites, and then the whole tree.**
    ///
    /// 08-04 built the seams, 08-14 converted the Coach and document-chat
    /// family by name, and this plan converts the six surfaces 08-02's
    /// `reduceTransparencyPrecedesGlassAvailability` and 08-14's handoff left
    /// standing. That is the first case below.
    ///
    /// The second case is the one that outlives the plan. Every clause written
    /// in this phase so far scans a *list* of files, so the contract has been
    /// exactly as good as somebody's memory: 08-14's own deferred note says the
    /// unaudited Coach files "carry no material literal", and
    /// `AskCoachSheet+ServerFallback.swift` carried two. A list cannot see the
    /// file nobody put on it. `noSurfaceOutsideTheDesignSystemPaintsRawGlass`
    /// therefore walks every `.swift` file under `HealthLog/` and allows the raw
    /// primitives only in the two seams that implement them.
    @Suite("Phase 08 release opacity audit")
    struct Phase8ReleaseOpacityAuditTests {
        // MARK: - The surfaces this plan converted

        /// The six files 08-12 routes through the shared policy: the three that
        /// 08-02's RED names, the shared sync banner both shells mount, the
        /// Insights glass tile chrome (the tree's last direct `glassEffect`),
        /// and the Coach server-fallback shelves 08-14's file list missed.
        static let releaseSurfaces = [
            "HealthLog/Screens/Documents/DocumentBulkBar.swift",
            "HealthLog/Screens/Onboarding/WelcomeStep.swift",
            "HealthLog/Screens/Onboarding/HealthKitPermissionStep.swift",
            "HealthLog/DesignSystem/HLSyncBanner.swift",
            "HealthLog/Screens/Insights/Sub/InsightsTileSurface.swift",
            "HealthLog/Screens/Coach/AskCoachSheet+ServerFallback.swift"
        ]

        /// The two files that *implement* the policy. A raw material or a raw
        /// glass call is correct here and nowhere else — this is the allowlist
        /// the plan's `<interfaces>` calls "the central design-system
        /// implementation", written down rather than described.
        static let policySeams = [
            "HealthLog/DesignSystem/AccessibilityModifiers.swift",
            "HealthLog/DesignSystem/LiquidGlass.swift"
        ]

        /// Every file outside the seams that reads the preference for itself,
        /// sorted as the tree walk returns them, and why each one is allowed to:
        ///
        /// - `AchievementDetailSheet` / `AchievementMedallion` suppress an
        ///   accent-hued drop *shadow* on an unlocked medallion. A shadow is not
        ///   a translucent surface and there is no painting helper to route it
        ///   through, so the environment read is the whole implementation.
        /// - `HLFloatingPeriodControl` branches to a solid capsule ahead of
        ///   `hlGlassEffect`. Redundant rather than wrong — the helper resolves
        ///   to the identical `HLSurface.secondary` capsule on that path — and
        ///   it is DesignSystem code that predates the seams. Recorded here so
        ///   the redundancy is a known fact rather than an unexamined one.
        static let preferenceReaders = [
            "HealthLog/DesignSystem/HLFloatingPeriodControl.swift",
            "HealthLog/Screens/Achievements/AchievementDetailSheet.swift",
            "HealthLog/Screens/Achievements/AchievementMedallion.swift"
        ]

        @Test("the audited release surfaces resolve every material and glass through the central policy")
        func releaseSurfacesUseCentralOpacityPolicy() throws {
            var violations: [String] = []
            for path in Self.releaseSurfaces {
                violations += try Phase8MaterialCallSiteTests.policyViolations(in: path)
            }

            // Preservation: the seam every clause above points at still answers
            // the preference before it asks which iOS it is running on.
            #expect(
                HLSurfaceOpacity.resolve(reduceTransparency: true, glassAvailable: true) == .opaque,
                "the shared policy must still answer opaque when the preference is set on an iOS-26 device"
            )

            // Preservation: the standard presentation is unchanged. An
            // opaque-everywhere "fix" passes every structural clause above and
            // silently changes the app for users who never asked for it, so each
            // surface is pinned to the material it has always painted.
            let bulk = try Phase8SourceScan.stripped("HealthLog/Screens/Documents/DocumentBulkBar.swift")
            #expect(bulk.contains(".ultraThinMaterial"), "the bulk bar must still paint the ultra-thin material")
            #expect(
                bulk.contains("RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)"),
                "the bulk bar must keep its card-radius shape now that the material no longer carries it"
            )
            #expect(
                bulk.contains(".stroke(HLColor.separator, lineWidth: 1)"),
                "the bulk bar must keep the hairline overlay the frozen presentation ledger owns"
            )
            for step in ["WelcomeStep", "HealthKitPermissionStep"] {
                let source = try Phase8SourceScan.stripped("HealthLog/Screens/Onboarding/\(step).swift")
                #expect(source.contains(".thinMaterial"), "\(step)'s pinned CTA shelf must still be a thin material")
                #expect(source.contains(".safeAreaInset(edge: .bottom)"), "\(step)'s shelf must stay pinned")
            }

            // Preservation: the Insights tile keeps its availability branch. It
            // decides which *treatment* the tile gets — glass, or a material
            // with a border and a shadow the glass path deliberately does not
            // draw — so collapsing it would hand every iOS 18-25 user a
            // different tile, which is not what honouring a preference means.
            let tile = try Phase8SourceScan.stripped("HealthLog/Screens/Insights/Sub/InsightsTileSurface.swift")
            #expect(
                Phase8SourceScan
                    .member(named: "private struct GlassTileSurfaceChrome", in: tile)?
                    .contains("#available(iOS 26.0, *)") == true,
                "the tile chrome must still choose its treatment per OS"
            )
            #expect(
                tile.contains(".ultraThinMaterial"),
                "the iOS 18-25 tile must still be the ultra-thin material it always was"
            )

            #expect(
                violations.isEmpty,
                "audited release surfaces bypassed the central opacity policy: \(violations)"
            )
        }

        // MARK: - The whole tree

        @Test("no surface outside the two policy seams paints a raw material or raw glass")
        func noSurfaceOutsideTheDesignSystemPaintsRawGlass() throws {
            let audited = try Self.auditableSources()

            // A scan that finds nothing because it looked nowhere is the failure
            // mode this clause is most exposed to, so the census is asserted
            // first and the seams are asserted to be *in* it.
            #expect(
                audited.count > 300,
                "the tree walk found only \(audited.count) sources — it looked in the wrong place"
            )
            for seam in Self.policySeams {
                #expect(audited.contains(seam), "\(seam) is not where the allowlist says it is")
            }

            var violations: [String] = []
            var readers: [String] = []
            for path in audited where !Self.policySeams.contains(path) {
                violations += try Self.paintingViolations(in: path)
                if try Phase8SourceScan.stripped(path).contains("accessibilityReduceTransparency") {
                    readers.append(path)
                }
            }

            // The fourth clause of 08-14's set — "nothing outside the seams
            // re-derives the preference" — is deliberately NOT applied as a
            // violation here, because tree-wide it is false for an honest
            // reason: two Achievements surfaces read the preference to suppress
            // a decorative *shadow*, which paints no translucency and has no
            // helper to route through. Stating the membership exactly is the
            // version of the clause that is both true and load-bearing: a new
            // file that starts reading the preference has to justify itself
            // here, and cannot arrive silently.
            #expect(
                readers == Self.preferenceReaders,
                "the set of files reading Reduce Transparency outside the seams changed: \(readers)"
            )

            // Preservation: the allowlist is not vacuous either. Both seams do
            // paint the raw primitives, which is exactly why they are the only
            // two files allowed to — if one stopped, the policy moved and this
            // list is stale rather than satisfied.
            let modifiers = try Phase8SourceScan.stripped("HealthLog/DesignSystem/AccessibilityModifiers.swift")
            #expect(modifiers.contains(".ultraThinMaterial"), "the material seam must still name a material")
            let glass = try Phase8SourceScan.stripped("HealthLog/DesignSystem/LiquidGlass.swift")
            #expect(glass.contains("glassEffect("), "the glass seam must still call the SwiftUI glass API")
            #expect(
                glass.contains("HLSurfaceOpacity.resolve"),
                "the glass seam must still resolve the preference before the availability branch"
            )

            #expect(
                violations.isEmpty,
                "raw material/glass primitives outside the design-system seams: \(violations)"
            )
        }

        // MARK: - Clauses

        /// The three *painting* clauses of 08-14's set, applied to one file: a
        /// raw material literal outside `HLMaterialBackground(`, a direct call
        /// into the SwiftUI glass APIs, and a glass opt-in that never says what
        /// the surface becomes when the preference sends it opaque.
        ///
        /// The fourth ("nothing re-derives the preference") is a question about
        /// *readers* rather than about paint, and is answered by an exact
        /// membership assertion in the caller instead.
        static func paintingViolations(in path: String) throws -> [String] {
            let source = try Phase8SourceScan.stripped(path)
            let file = Phase8MaterialCallSiteTests.name(of: path)
            var violations: [String] = []

            for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let material = Phase8MaterialCallSiteTests.materials
                    .first(where: { line.contains(".\($0)") }) else { continue }
                if !line.contains("HLMaterialBackground(") {
                    violations.append("\(file):\(offset + 1) paints a bare .\(material) no opaque fallback can reach")
                }
            }

            var withoutWrappers = source
            for wrapper in Phase8MaterialCallSiteTests.wrappers {
                withoutWrappers = withoutWrappers.replacingOccurrences(of: wrapper, with: "")
            }
            if withoutWrappers.contains("glassEffect(") {
                violations.append("\(file) calls SwiftUI glassEffect(…) directly, ahead of the preference")
            }
            if withoutWrappers.contains("GlassEffectContainer(") {
                violations.append("\(file) builds a raw GlassEffectContainer instead of HLGlassEffectContainer")
            }

            for call in Phase8MaterialCallSiteTests.fallbackBearingCalls {
                let arguments = Phase8MaterialCallSiteTests.callArguments(of: call, in: source)
                for argument in arguments where !argument.contains("fallback:") {
                    violations.append("\(file) opts into \(call)…) without naming the surface it becomes when opaque")
                }
            }

            return violations
        }

        // MARK: - Reading

        /// Every tracked `.swift` file under `HealthLog/`, relative to the
        /// repository root. Previews and `#if DEBUG` fixtures are included on
        /// purpose: a bare material behind a debug flag still ships in the debug
        /// build the gates render.
        static func auditableSources() throws -> [String] {
            let root = Phase8SourceScan.repositoryRoot
            let base = root.appendingPathComponent("HealthLog")
            guard let walker = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            let prefix = root.standardizedFileURL.path + "/"
            var found: [String] = []
            for case let url as URL in walker where url.pathExtension == "swift" {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { continue }
                found.append(String(path.dropFirst(prefix.count)))
            }
            return found.sorted()
        }
    }
#endif
