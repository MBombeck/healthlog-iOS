// Renders app-target design-system symbols that the SPM library does not
// contain; the SPM test build skips the file (repo convention).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// **Phase 08 Wave 0 — the four shared accessibility policies, as failing
    /// contracts.**
    ///
    /// Adaptive layout, hit region, opaque surface and spoken semantics are
    /// written here once so the Wave-1/3 plans that touch Settings, Insights,
    /// Documents, onboarding and the celebration are all measured against the
    /// same statement rather than each inventing its own.
    ///
    /// Two doctrines are followed deliberately. Rendered coverage stays at the
    /// repo's measure-don't-pixel line (`HLSettingsToggleRowLayoutTests`,
    /// `HLSkeletonSnapshotTests`): a layout claim is proven by a *differential*
    /// measurement — the same primitive at two type sizes, or with two subtitle
    /// lengths — never by a bitmap that an SDK bump can invalidate. And every
    /// source clause reads comment-stripped text bounded to one declaration,
    /// because Phase 07 and Plan 08-01 each lost an assertion to a range that
    /// matched something it was written to exclude.
    @MainActor
    @Suite("Phase 08 accessibility policy")
    struct Phase8AccessibilityPolicyTests {
        // MARK: RED — accessibility sizes must be allowed to reflow

        /// `HLSettingsRow` caps its subtitle at `.lineLimit(1)` unconditionally,
        /// a v0.15 W1-4 density decision taken for standard sizes and never
        /// revisited for the accessibility ones. At `.accessibility5` the hint
        /// is still one truncated line, so the row grows without ever saying
        /// more — the text is bigger and the information is smaller.
        ///
        /// Measured differentially: a long subtitle and a short one, rendered at
        /// the same width and the same type size. A row that wraps is taller for
        /// the long one; a row that truncates is exactly as tall for both.
        @Test("Settings rows wrap their hint at accessibility sizes")
        func settingsRowsWrapAtAccessibilitySizes() throws {
            var violations: [String] = []

            let shortHint: LocalizedStringKey = "On"
            let longHint: LocalizedStringKey =
                "Sync every measurement with the paired server whenever the app returns to the foreground."

            let shortAX = try Self.height(of: Self.settingsRow(subtitle: shortHint), size: .accessibility5)
            let longAX = try Self.height(of: Self.settingsRow(subtitle: longHint), size: .accessibility5)
            let shortDefault = try Self.height(of: Self.settingsRow(subtitle: shortHint), size: .large)
            let longDefault = try Self.height(of: Self.settingsRow(subtitle: longHint), size: .large)

            if longAX <= shortAX + 1 {
                violations.append(
                    "at accessibility5 the long hint occupies the same \(Int(longAX))pt as the short one"
                )
            }
            if let row = try Phase8SourceScan.member(
                named: "public var body: some View",
                in: Phase8SourceScan.stripped("HealthLog/DesignSystem/HLSettingsRow.swift")
            ), row.contains(".lineLimit(1)"), !row.contains("dynamicTypeSize") {
                violations.append("HLSettingsRow caps its subtitle at one line without consulting the type size")
            }

            // Preservation: standard sizes keep today's single-line density, and
            // the type size is honoured at all — so the defect above is the
            // wrapping decision, not a dead Dynamic Type path.
            #expect(abs(longDefault - shortDefault) < 1, "standard sizes must keep the current one-line density")
            #expect(longDefault < 90, "a standard-size Settings row must stay compact")
            #expect(shortAX > shortDefault, "accessibility5 must already scale the row's type")
            #expect(violations.isEmpty, "EXPECTED_RED: 08-02 accessibility Settings row did not wrap")
        }

        /// The Insights score tiles and the recovery tiles are pinned to two
        /// fixed flexible columns. At `.accessibility5` a half-width tile is
        /// narrower than its own number, and nothing in either declaration reads
        /// the type size to fall back to one column.
        @Test("Insights score grids fall back to one column at accessibility sizes")
        func insightsUseOneColumnAtAccessibilitySizes() throws {
            var violations: [String] = []

            for path in Self.twoUpGridFiles {
                let source = try Phase8SourceScan.stripped(path)
                let declaration = Phase8SourceScan.member(
                    named: "private let columns = [",
                    in: source,
                    closing: "]"
                )
                guard let columns = declaration else {
                    violations.append("\(path) no longer declares `columns` — restate this contract")
                    continue
                }
                if columns.components(separatedBy: "GridItem(").count - 1 == 2, !source.contains("dynamicTypeSize") {
                    violations.append("\(path) pins two columns without consulting the type size")
                }
            }

            // Preservation: the reflow shape the grids must copy already ships.
            let anchor = try Phase8SourceScan.stripped("HealthLog/Screens/Mood/MoodStabilitySection.swift")
            #expect(anchor.contains("dynamicTypeSize >= .accessibility1"), "the reflow anchor must stay")
            #expect(violations.isEmpty, "EXPECTED_RED: 08-02 accessibility Insights grid did not become one column")
        }

        // MARK: RED — a 44pt region, without a 44pt glyph

        /// Three interactive icons this phase owns declare their own hit region
        /// and every one of them is short of 44 points in at least one
        /// direction: the onboarding back chevron at 44×32, the Documents bulk
        /// bar at 36×32, and the score-card edit button at 28×28. Nothing in the
        /// token set names a minimum region, so each surface has been guessing.
        @Test("phase-touched interactive icons resolve to at least 44 by 44")
        func minimumHitRegionIsFortyFourPoints() throws {
            var violations: [String] = []

            for control in Self.hitRegionControls {
                let source = try Phase8SourceScan.stripped(control.path)
                let dimensions: [String: Double]? = if let member = control.member {
                    Phase8SourceScan.member(named: member, in: source)
                        .map { Phase8SourceScan.frameDimensions(Self.frameLabels, in: $0) }
                } else {
                    Phase8SourceScan.frameDimensionsBefore(anchor: control.anchor, in: source)
                }
                guard let dimensions, let smallest = dimensions.values.min() else {
                    violations.append("\(control.name) no longer declares a frame — restate this contract")
                    continue
                }
                if smallest < 44 {
                    violations.append("\(control.name) declares a \(Int(smallest))pt hit region")
                }
            }

            let tokens = try Phase8SourceScan.stripped("HealthLog/DesignSystem/Tokens+Layout.swift")
            if !tokens.contains("44") {
                violations.append("the layout tokens name no minimum hit region for anything to share")
            }

            // Preservation: the glyphs themselves are far below 44pt, so the
            // policy can only be met by growing the region, never the icon.
            let glyph = try Self.height(
                of: Image(systemName: "chevron.left").font(.hlTitle3),
                width: 44,
                size: .large
            )
            #expect(glyph < 44, "a title3 chevron must stay well under the hit region it needs")
            #expect(violations.isEmpty, "EXPECTED_RED: 08-02 accessibility hit region was below forty four points")
        }

        // MARK: RED — Reduce Transparency outranks the OS version

        /// `LiquidGlass.swift` decides on `#available(iOS 26.0, *)` and nothing
        /// else, so on an iOS-26 device Reduce Transparency cannot reach any
        /// glass surface at all. The four Phase-8 screens that paint a bare
        /// `Material` bypass the one helper that does honour the setting.
        @Test("Reduce Transparency is decided before Liquid Glass availability")
        func reduceTransparencyPrecedesGlassAvailability() throws {
            var violations: [String] = []

            let glass = try Phase8SourceScan.stripped("HealthLog/DesignSystem/LiquidGlass.swift")
            let availabilityBranches = glass.components(separatedBy: "#available(iOS 26").count - 1
            if availabilityBranches > 0, !glass.contains("accessibilityReduceTransparency") {
                violations.append(
                    "\(availabilityBranches) glass availability branches never consult Reduce Transparency"
                )
            }

            for path in Self.rawMaterialSurfaces {
                let source = try Phase8SourceScan.stripped(path)
                let paintsMaterial = Self.materials.contains { source.contains(".\($0)") }
                if paintsMaterial, !source.contains("HLMaterialBackground") {
                    violations.append("\(path) paints a bare Material with no opaque fallback")
                }
            }

            // Preservation: the one helper that resolves correctly still does,
            // and it is what everything above has to route through.
            #expect(
                Self.isOpaque(Self.resolvedMaterial(reduceTransparency: true)),
                "Reduce Transparency must still resolve to an opaque surface"
            )
            #expect(
                !Self.isOpaque(Self.resolvedMaterial(reduceTransparency: false)),
                "the default appearance must still be the translucent material"
            )
            #expect(
                violations.isEmpty,
                "EXPECTED_RED: 08-02 accessibility glass availability overrode Reduce Transparency"
            )
        }

        // MARK: RED — spoken labels come from the visible model

        /// The onboarding indicator speaks a hand-tuned constant. `progress` is
        /// a ten-case table of magic fractions, the label says "Step 1 of 6" as
        /// an English literal on a flow that branches to five, six or eight
        /// steps, and the value is an untranslated `"\(percent) percent"`.
        /// Neither is reachable without a view tree — both are `private var` on
        /// the `View` — so nothing but a human can currently check them.
        @Test("onboarding progress semantics are derived from the resolved route")
        func onboardingProgressSemanticsMatchVisibleRoute() throws {
            var violations: [String] = []
            // 16-01 — the flow's pure route seams moved out of the view file
            // (`OnboardingFlowRoute.swift`) under the same 600-line discipline
            // that already produced `OnboardingRouteProgress.swift`, so this
            // contract reads BOTH of the flow's sources. Amended deliberately
            // and by name: the clause is "a pure seam exists", not "a pure seam
            // lives in one particular file", and a contract that a move can
            // satisfy — in either direction — is not a contract.
            let view = try Phase8SourceScan.stripped("HealthLog/Screens/Onboarding/OnboardingFlow.swift")
            let route = try Phase8SourceScan.stripped("HealthLog/Screens/Onboarding/OnboardingFlowRoute.swift")
            let source = view + "\n" + route

            if let indicator = Phase8SourceScan.member(named: "private struct ProgressIndicator", in: view) {
                if indicator.contains("percent\")") {
                    violations.append("the spoken progress value is an untranslated English literal")
                }
                if !indicator.contains("let accessibilityValue") {
                    violations.append("the spoken value is composed in the view instead of supplied by the model")
                }
            } else {
                violations.append("ProgressIndicator no longer exists — restate this contract")
            }
            if source.contains("String(localized: \"Step 1 of 6") {
                violations.append("the spoken step count is a literal that no route length produces")
            }
            if !source.contains("static func progress(") {
                violations.append("no pure seam maps a resolved route to its progress and label")
            }

            // Preservation: the route resolution itself is already pure and
            // testable, which is the seam the semantics have to be built on.
            #expect(
                OnboardingFlow.resolveStep(.auth, chosenMode: nil, hasServerAddress: false) == .serverURL,
                "the resolved route must still be a pure function"
            )
            #expect(
                OnboardingFlow.resolveStep(.healthKit, chosenMode: nil, hasServerAddress: true) == .healthKit,
                "an addressed flow must still resolve to itself"
            )
            #expect(
                violations.isEmpty,
                "EXPECTED_RED: 08-02 accessibility onboarding progress did not match the route"
            )
        }

        /// `CelebrationOverlay` shows the record's metric name and then combines
        /// its children under a fixed `"New personal record!"` label, which
        /// replaces them — so VoiceOver is told that something happened and
        /// never which metric it happened to. The visible copy is localised; the
        /// spoken copy is an English literal.
        @Test("the celebration speaks the metric it shows")
        func celebrationSemanticsMatchVisibleMetric() throws {
            var violations: [String] = []
            let source = try Phase8SourceScan.stripped("HealthLog/Screens/PersonalRecords/CelebrationOverlay.swift")

            guard let body = Phase8SourceScan.member(named: "var body: some View", in: source) else {
                throw Phase8PolicyFailure.missingMember("CelebrationOverlay.body")
            }
            if body.contains("accessibilityElement(children: .combine)"), body.contains("accessibilityLabel(Text(\"") {
                violations.append("a fixed label replaces the combined children, dropping the visible metric")
            }
            if !body.contains("MetricTypeLocalisation"), !body.contains("record.") {
                violations.append("the spoken label names no value from the record it celebrates")
            }
            if source.contains("accessibilityLabel(Text(\"New personal record!\"))") {
                violations.append("the spoken label is an untranslated English literal")
            }

            // Preservation: the visible metric label is already pure, localised
            // and never empty — it is exactly what the announcement must carry.
            #expect(MetricTypeLocalisation.label(forType: "WEIGHT") == "Weight")
            #expect(!MetricTypeLocalisation.label(forType: "SOMETHING_NEW").isEmpty, "unknown types still get a label")
            #expect(violations.isEmpty, "EXPECTED_RED: 08-02 accessibility celebration omitted its visible metric")
        }

        // MARK: - Descriptors

        private struct HitRegionControl {
            let name: String
            let path: String
            /// Either the control's own declaration…
            let member: String?
            /// …or a unique identifier the declared frame sits directly above.
            let anchor: String
        }

        private static let hitRegionControls = [
            HitRegionControl(
                name: "the onboarding back chevron",
                path: "HealthLog/Screens/Onboarding/OnboardingFlow.swift",
                member: nil,
                anchor: "accessibilityIdentifier(\"onboarding.backButton\")"
            ),
            HitRegionControl(
                name: "the Documents bulk-bar action",
                path: "HealthLog/Screens/Documents/DocumentBulkBar.swift",
                member: "private func bulkIcon(",
                anchor: ""
            ),
            HitRegionControl(
                name: "the score-card edit button",
                path: "HealthLog/Screens/Insights/Sub/InsightsScoreCardsBlock.swift",
                member: nil,
                anchor: "accessibilityIdentifier(\"insights.scoreCards.edit\")"
            )
        ]

        private static let twoUpGridFiles = [
            "HealthLog/Screens/Insights/Sub/InsightsScoreCardsBlock.swift",
            "HealthLog/Screens/Insights/Sub/InsightsRecoveryPage.swift"
        ]

        private static let rawMaterialSurfaces = [
            "HealthLog/Screens/Documents/DocumentBulkBar.swift",
            "HealthLog/Screens/Documents/DocumentChatSheet.swift",
            "HealthLog/Screens/Onboarding/WelcomeStep.swift",
            "HealthLog/Screens/Onboarding/HealthKitPermissionStep.swift"
        ]

        private static let materials = ["ultraThinMaterial", "thinMaterial", "regularMaterial", "thickMaterial"]

        private static let frameLabels = ["minWidth", "minHeight", "width", "height"]

        // MARK: - Rendering

        private static func settingsRow(subtitle: LocalizedStringKey) -> some View {
            HLSettingsRow(icon: "arrow.triangle.2.circlepath", title: "Sync", subtitle: subtitle)
        }

        /// The laid-out height of a view at a fixed width and type size. A
        /// measurement, not a bitmap — the value that changes when a layout
        /// reflows and stays put when it truncates.
        private static func height(
            of view: some View,
            width: CGFloat = 320,
            size: DynamicTypeSize
        ) throws -> CGFloat {
            let renderer = ImageRenderer(
                content: view
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(size)
            )
            renderer.scale = 1
            guard let image = renderer.uiImage else {
                throw Phase8PolicyFailure.renderFailed
            }
            return image.size.height
        }

        private static func resolvedMaterial(reduceTransparency: Bool) -> some View {
            HLMaterialBackground.resolved(
                reduceTransparency: reduceTransparency,
                material: .regularMaterial,
                solidColor: .red
            )
            .frame(width: 40, height: 40)
            .background(Color.white)
        }

        /// True when the rendered surface is dominated by the injected opaque
        /// colour — the unambiguous signal that the solid fallback painted.
        private static func isOpaque(_ view: some View) -> Bool {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let cg = renderer.uiImage?.cgImage else { return false }
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            guard let context = CGContext(
                data: &pixels,
                width: cg.width,
                height: cg.height,
                bitsPerComponent: 8,
                bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            var solid = 0
            for index in stride(from: 0, to: pixels.count, by: 4)
                where pixels[index] > 180 && pixels[index + 1] < 90
                && pixels[index + 2] < 90 && pixels[index + 3] > 200
            {
                solid += 1
            }
            return solid > (cg.width * cg.height) / 2
        }
    }

    private enum Phase8PolicyFailure: Error {
        case renderFailed
        case missingMember(String)
    }
#endif
