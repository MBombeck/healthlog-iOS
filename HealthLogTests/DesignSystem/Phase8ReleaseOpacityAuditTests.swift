// Reads app-target sources and the app-target opacity policy; the SPM test
// build contains neither, so it skips the file (repo convention).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// Reduce Transparency is honoured app-wide only if no surface paints a raw
    /// material or raw glass past the design-system seams. A list of audited
    /// files cannot see the file nobody put on it, so this walks every `.swift`
    /// file under `HealthLog/` and allows the raw primitives only in the two
    /// seams that implement the policy.
    @Suite("Phase 08 release opacity audit")
    struct Phase8ReleaseOpacityAuditTests {
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

            // The clause "nothing outside the seams re-derives the preference" is deliberately NOT applied as a
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

        /// The three painting clauses, applied to one file: a raw material literal outside `HLMaterialBackground(`, a direct call
        /// into the SwiftUI glass APIs, and a glass opt-in that never says what
        /// the surface becomes when the preference sends it opaque.
        ///
        /// The fourth ("nothing re-derives the preference") is a question about
        /// *readers* rather than about paint, and is answered by an exact
        /// membership assertion in the caller instead.
        static func paintingViolations(in path: String) throws -> [String] {
            let source = try Phase8SourceScan.stripped(path)
            let file = Self.name(of: path)
            var violations: [String] = []

            for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let material = Self.materials
                    .first(where: { line.contains(".\($0)") }) else { continue }
                if !line.contains("HLMaterialBackground(") {
                    violations.append("\(file):\(offset + 1) paints a bare .\(material) no opaque fallback can reach")
                }
            }

            var withoutWrappers = source
            for wrapper in Self.wrappers {
                withoutWrappers = withoutWrappers.replacingOccurrences(of: wrapper, with: "")
            }
            if withoutWrappers.contains("glassEffect(") {
                violations.append("\(file) calls SwiftUI glassEffect(…) directly, ahead of the preference")
            }
            if withoutWrappers.contains("GlassEffectContainer(") {
                violations.append("\(file) builds a raw GlassEffectContainer instead of HLGlassEffectContainer")
            }

            for call in Self.fallbackBearingCalls {
                let arguments = Self.callArguments(of: call, in: source)
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

        /// The four material literals that count as "a bare Material".
        static let materials = ["ultraThinMaterial", "thinMaterial", "regularMaterial", "thickMaterial"]

        /// The DesignSystem wrappers that consult `HLSurfaceOpacity`. Stripped
        /// out before the raw-API scan so `hlGlassEffect(…)` is never mistaken
        /// for the SwiftUI symbol it wraps.
        static let wrappers = [
            "hlGlassEffectID",
            "hlGlassEffect",
            "hlGlassBackground",
            "HLGlassEffectContainer"
        ]

        /// The wrapper calls that take a `fallback:` — the argument that decides
        /// what the surface is under Reduce Transparency.
        static let fallbackBearingCalls = ["hlGlassEffect(", "hlGlassBackground("]

        static func name(of path: String) -> String {
            String(path.split(separator: "/").last ?? "")
        }

        /// The balanced argument list of every `call` in `source`. A call's
        /// arguments routinely wrap across lines, so a line-wise scan would
        /// report a missing `fallback:` on every multi-line call site.
        static func callArguments(of call: String, in source: String) -> [String] {
            var found: [String] = []
            var searchStart = source.startIndex
            while let opening = source.range(of: call, range: searchStart ..< source.endIndex) {
                var depth = 1
                var index = opening.upperBound
                var arguments = ""
                while index < source.endIndex, depth > 0 {
                    let character = source[index]
                    if character == "(" { depth += 1 }
                    if character == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    arguments.append(character)
                    index = source.index(after: index)
                }
                found.append(arguments)
                searchStart = opening.upperBound
            }
            return found
        }
    }
#endif
