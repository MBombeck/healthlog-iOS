// Reads the app bundle's license file and renders App-target screens; neither
// exists in the SPM library build.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// Settings > About > Licenses (1.7).
    ///
    /// The bundle carries a license entry for every package `Package.resolved`
    /// pins, each with its text, and both pages paint. The generator's own
    /// `--check` guards the same file statically; this suite proves the file
    /// that reached the built app.
    @MainActor
    @Suite("Settings licenses", .serialized)
    struct SettingsLicensesScreenTests {
        private static func resolvedIdentities() throws -> Set<String> {
            // `RepoDocs.root` counts its levels from the caller's file; this
            // file sits one folder deeper than `Support/`.
            let url = RepoDocs.root().deletingLastPathComponent()
                .appendingPathComponent("HealthLog.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
            struct Resolved: Decodable {
                struct Pin: Decodable {
                    let identity: String
                }

                let pins: [Pin]
            }
            return try Set(JSONDecoder().decode(Resolved.self, from: Data(contentsOf: url)).pins.map(\.identity))
        }

        @Test("the bundle names every resolved package")
        func bundleCoversEveryResolvedPackage() throws {
            let resolved = try Self.resolvedIdentities()
            let bundled = Set(ThirdPartyLicenseCatalog.load(bundle: .main).map(\.identity))
            #expect(!resolved.isEmpty)
            #expect(resolved.subtracting(bundled).isEmpty, "missing from the bundle: \(resolved.subtracting(bundled).sorted())")
            #expect(bundled.subtracting(resolved).isEmpty, "no longer resolved: \(bundled.subtracting(resolved).sorted())")
        }

        @Test("every entry has a name, a version, a license and its full text")
        func entriesAreComplete() {
            let packages = ThirdPartyLicenseCatalog.all
            #expect(packages.count == Set(packages.map(\.identity)).count, "an identity appears twice")
            for package in packages {
                #expect(!package.name.isEmpty, "\(package.identity) has no name")
                #expect(!package.version.isEmpty, "\(package.identity) has no version")
                #expect(!package.license.isEmpty, "\(package.identity) has no license")
                #expect(package.text.count > 200, "\(package.identity) carries no full license text")
                #expect(package.sourceURL != nil, "\(package.identity) has no source URL")
                if let notice = package.notice {
                    #expect(!notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(package.identity) has an empty NOTICE")
                }
            }
        }

        @Test("Apache packages that ship a NOTICE carry it")
        func noticesTravel() throws {
            let nio = try #require(ThirdPartyLicenseCatalog.all.first { $0.identity == "swift-nio" })
            #expect(nio.license == "Apache-2.0")
            #expect(nio.notice?.contains("SwiftNIO") == true)
        }

        @Test("hard-wrapped paragraphs run on, structure keeps its lines")
        func reflow() {
            let text = """
            The SwiftNIO Project
            ====================

            Permission is hereby granted,
               free of charge, to any person.

            Copyright (c) 2020 A
            Copyright (c) 2021 B
            * first item
              * nested item
            1. Definitions follow
               on two lines.
            """
            let expected = """
            The SwiftNIO Project
            ====================

            Permission is hereby granted, free of charge, to any person.

            Copyright (c) 2020 A
            Copyright (c) 2021 B
            * first item
              * nested item
            1. Definitions follow on two lines.
            """
            #expect(ThirdPartyLicense.reflowed(text) == expected)
        }

        @Test("reflowing changes line breaks only, never a word")
        func reflowKeepsEveryWord() {
            for package in ThirdPartyLicenseCatalog.all {
                for text in [package.text, package.notice].compactMap(\.self) {
                    let words = text.split(whereSeparator: \.isWhitespace)
                    let reflowedWords = ThirdPartyLicense.reflowed(text).split(whereSeparator: \.isWhitespace)
                    #expect(words == reflowedWords, "\(package.identity) lost or changed a word")
                }
            }
        }

        @Test("a broken file decodes to no entries instead of trapping")
        func brokenFileIsEmpty() {
            #expect(ThirdPartyLicenseCatalog.decode(Data("{".utf8)).isEmpty)
            #expect(ThirdPartyLicenseCatalog.decode(Data(#"{"packages":[]}"#.utf8)).isEmpty)
        }

        @Test("the app's own license and source code are named")
        func appLicense() {
            #expect(HealthLogAppLicense.requiredNotice.hasPrefix("Required Notice: Copyright"))
            #expect(HealthLogAppLicense.licenseURL?.absoluteString == "https://polyformproject.org/licenses/noncommercial/1.0.0")
            #expect(HealthLogAppLicense.sourceCodeURL?.host() == "github.com")
        }

        @Test("the list renders")
        func listRenders() throws {
            let image = try render(NavigationStack { SettingsLicensesScreen() })
            #expect(Self.hasInk(image), "the licenses list painted nothing")
        }

        @Test("a detail page renders its text")
        func detailRenders() throws {
            let package = try #require(ThirdPartyLicenseCatalog.all.first { $0.identity == "swift-nio" })
            let image = try render(NavigationStack { SettingsLicenseDetailScreen(package: package) })
            #expect(Self.hasInk(image), "the license detail painted nothing")
        }

        // MARK: - Rendering

        /// The frame-based `UIWindow` init is deprecated from iOS 26; the test keeps the shipped behaviour.
        @diagnose(DeprecatedDeclaration, as: ignored)
        private func render(_ view: some View) throws -> UIImage {
            let size = CGSize(width: 393, height: 800)
            let host = UIHostingController(rootView: AnyView(view))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window.windowScene = scene
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            return image
        }

        /// Contrast anywhere in the lower two thirds: text painted below the bar.
        private static func hasInk(_ image: UIImage) -> Bool {
            guard let cg = image.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return false }
            let bpr = cg.bytesPerRow
            let bpp = cg.bitsPerPixel / 8
            var minLum = 255
            var maxLum = 0
            for y in stride(from: cg.height / 3, to: cg.height, by: 3) {
                for x in stride(from: 0, to: cg.width, by: 4) {
                    let p = y * bpr + x * bpp
                    let lum = (Int(ptr[p]) + Int(ptr[p + 1]) + Int(ptr[p + 2])) / 3
                    minLum = min(minLum, lum)
                    maxLum = max(maxLum, lum)
                }
            }
            return (maxLum - minLum) > 25
        }
    }
#endif
