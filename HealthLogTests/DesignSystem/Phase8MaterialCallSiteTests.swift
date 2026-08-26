// Reads app-target screen sources and the app-target opacity policy; the SPM
// test build contains neither, so it skips the file (repo convention).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Plan 08-14 — the bounded Coach / document-chat call-site family.**
    ///
    /// Plan 08-04 put the one decision in one place: `HLSurfaceOpacity.resolve`
    /// reads `accessibilityReduceTransparency` *before* it asks whether iOS 26
    /// glass exists, and every painting `.hlGlass*` helper routes through it.
    /// What 08-04 could not do was reach the call sites, because they live in
    /// screens other plans own. This suite is the statement for the surfaces
    /// this plan owns.
    ///
    /// Four clauses, all read from comment-stripped source, because the defect
    /// is structural rather than visual — a surface that paints a bare
    /// `Material`, calls SwiftUI's `glassEffect` directly, re-derives the
    /// preference for itself, or opts into glass without ever saying what it
    /// looks like when the user turns transparency off, is wrong in a way no
    /// screenshot on this simulator can show (the gate runs on iOS 26 with the
    /// preference off, which is exactly the cell that always looks right).
    @Suite("Phase 08 material call sites")
    struct Phase8MaterialCallSiteTests {
        // MARK: - The audited family

        /// The five Coach surfaces named in `08-14-PLAN.md`'s `files_modified`.
        static let coachSurfaces = [
            "HealthLog/Screens/Coach/AskCoachSheet.swift",
            "HealthLog/Screens/Coach/AskCoachSheet+InputRow.swift",
            "HealthLog/Screens/Coach/AskCoachSheet+Transcript.swift",
            "HealthLog/Screens/Coach/AskCoachHeroCard.swift",
            "HealthLog/Screens/Coach/MiniCoachOnboardingSheet.swift"
        ]

        /// The document-chat half of the family — the one surface of this plan
        /// that also carries an 08-02 violation of its own.
        static let documentChatSurface = "HealthLog/Screens/Documents/DocumentChatSheet.swift"

        /// The same four literals `Phase8AccessibilityPolicyTests` scans for, so
        /// the two contracts cannot disagree about what "a bare Material" is.
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

        // MARK: - Coach

        @Test("Coach surfaces resolve every material and glass through the central opacity policy")
        func coachSurfacesUseCentralOpacityPolicy() throws {
            var violations: [String] = []
            for path in Self.coachSurfaces {
                violations += try Self.policyViolations(in: path)
            }

            // Preservation: the policy this plan routes into still puts the
            // preference ahead of availability. Every clause above is worthless
            // if the seam it points at stops answering `.opaque`.
            #expect(
                HLSurfaceOpacity.resolve(reduceTransparency: true, glassAvailable: true) == .opaque,
                "the shared policy must still answer opaque when the preference is set on an iOS-26 device"
            )
            #expect(
                HLSurfaceOpacity.resolve(reduceTransparency: false, glassAvailable: true) == .glass,
                "the standard iOS-26 presentation must still be the glass enhancement"
            )
            #expect(
                HLSurfaceOpacity.resolve(reduceTransparency: false, glassAvailable: false) == .material,
                "the iOS 18-25 baseline must still be the material treatment"
            )

            // Preservation: the iOS-26 composer morph is a *mounting* decision,
            // not a painting one. It predates this plan and must survive it —
            // the send button still appears and dissolves inside one shared
            // glass container.
            let inputRow = try Phase8SourceScan.stripped("HealthLog/Screens/Coach/AskCoachSheet+InputRow.swift")
            #expect(
                inputRow.contains("HLGlassEffectContainer(spacing: HLSpace.sm)"),
                "the composer must still group its glass shapes in one container"
            )
            #expect(
                Phase8SourceScan
                    .member(named: "private var showSendButton: Bool", in: inputRow)?
                    .contains("#available(iOS 26.0, *)") == true,
                "the send button must still be mounted conditionally so the glass system can morph it"
            )

            // Preservation: the composer's transparent iOS-26 row backing is
            // only legible because nothing translucent sits behind it. The row
            // is a layout sibling of the transcript, not a float over it, and
            // the sheet itself paints an opaque presentation background. Both
            // facts are asserted here so the backing decision cannot rot
            // silently underneath a later layout change.
            let transcript = try Phase8SourceScan.stripped("HealthLog/Screens/Coach/AskCoachSheet+Transcript.swift")
            let transcriptBody = Phase8SourceScan.member(named: "var body: some View", in: transcript)
            #expect(
                transcriptBody?.contains("CoachInputRow(") == true,
                "the transcript must still compose the composer itself"
            )
            #expect(
                transcriptBody?.contains("VStack(spacing: 0)") == true,
                "the composer must stay a stacked sibling of the transcript"
            )
            #expect(
                transcriptBody?.contains(".safeAreaInset") == false,
                "a composer floated over the transcript would need its own opaque backing"
            )
            let sheet = try Phase8SourceScan.stripped("HealthLog/Screens/Coach/AskCoachSheet.swift")
            #expect(
                sheet.contains(".presentationBackground(HLColor.surface)"),
                "the coach sheet must keep the opaque presentation background the clear row backing rests on"
            )

            #expect(
                violations.isEmpty,
                "Coach surfaces bypassed the central opacity policy: \(violations)"
            )
        }

        // MARK: - Document chat

        @Test("document chat resolves its material through the central opacity policy")
        func documentChatUsesCentralOpacityPolicy() throws {
            var violations = try Self.policyViolations(in: Self.documentChatSurface)

            // The family-wide half of the claim, stated once over both halves of
            // the plan: no surface here re-derives the preference for itself and
            // none reaches past the wrappers. A Coach file therefore cannot
            // regress quietly while the document-chat clause stays green.
            for path in Self.coachSurfaces + [Self.documentChatSurface] {
                let source = try Phase8SourceScan.stripped(path)
                let file = Self.name(of: path)
                if source.contains("accessibilityReduceTransparency") {
                    violations.append("\(file) re-derives the Reduce Transparency preference")
                }
                var withoutWrappers = source
                for wrapper in Self.wrappers {
                    withoutWrappers = withoutWrappers.replacingOccurrences(of: wrapper, with: "")
                }
                if withoutWrappers.contains("glassEffect(") {
                    violations.append("\(file) calls SwiftUI glassEffect(…) directly, ahead of the preference")
                }
            }

            // Preservation: this plan changes the chat row's backing and nothing
            // the user types into, taps or hears. The field keeps its own
            // surface fill, the send button keeps its label, and the screen keeps
            // the opaque background the composer is measured against.
            let chat = try Phase8SourceScan.stripped(Self.documentChatSurface)
            #expect(
                chat.contains(".background(HLSurface.tertiary)"),
                "the chat field must keep its tertiary surface fill"
            )
            #expect(
                chat.contains("documents.chat.send"),
                "the chat send button must keep its accessibility label"
            )
            #expect(
                chat.contains(".hlScreenBackground()"),
                "the chat screen must keep the opaque background behind the composer"
            )

            // Preservation: the standard presentation is still the material. An
            // opaque-everywhere "fix" would pass every clause above and change
            // the app for users who never asked for it.
            #expect(
                chat.contains(".thinMaterial"),
                "the standard presentation must still be the thin material"
            )

            #expect(
                violations.isEmpty,
                "document chat bypassed the central opacity policy: \(violations)"
            )
        }

        // MARK: - Clauses

        /// The four structural clauses, applied to one file.
        static func policyViolations(in path: String) throws -> [String] {
            let source = try Phase8SourceScan.stripped(path)
            let file = name(of: path)
            var violations: [String] = []

            // 1. A raw material literal is only allowed as an argument to the
            //    preference-aware background. Anything else paints a
            //    translucency the user asked not to see.
            for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let material = materials.first(where: { line.contains(".\($0)") }) else { continue }
                if !line.contains("HLMaterialBackground(") {
                    violations.append("\(file):\(offset + 1) paints a bare .\(material) no opaque fallback can reach")
                }
            }

            // 2. The SwiftUI glass APIs are reachable only through the
            //    DesignSystem wrappers, which resolve the preference first.
            //    A direct call is availability-first by construction.
            var withoutWrappers = source
            for wrapper in wrappers {
                withoutWrappers = withoutWrappers.replacingOccurrences(of: wrapper, with: "")
            }
            if withoutWrappers.contains("glassEffect(") {
                violations.append("\(file) calls SwiftUI glassEffect(…) directly, ahead of the preference")
            }
            if withoutWrappers.contains("GlassEffectContainer(") {
                violations.append("\(file) builds a raw GlassEffectContainer instead of HLGlassEffectContainer")
            }

            // 3. Nothing here re-derives the preference for itself. One reader
            //    per helper is the whole point of 08-04's plumbing; a second
            //    one in a screen is a second place to forget it.
            if source.contains("accessibilityReduceTransparency") {
                violations.append("\(file) re-derives the Reduce Transparency preference")
            }

            // 4. Every glass opt-in states its own opaque answer. The default
            //    `HLColor.backgroundEleva` is a design-system default, not a
            //    decision this surface made — and the cell it governs
            //    (iOS 26 + preference on) is the one no default was chosen for.
            for call in fallbackBearingCalls {
                for arguments in callArguments(of: call, in: source) where !arguments.contains("fallback:") {
                    violations.append("\(file) opts into \(call)…) without naming the surface it becomes when opaque")
                }
            }

            return violations
        }

        // MARK: - Reading

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
