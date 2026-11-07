// HealthLogTests/Compliance/PermissionDeclarationTests.swift
//
// 1.0.3 / App Review audit row 26 (5.1.1(ii)) — a permission string the app can
// never show is a promise it does not keep, and Apple reads the Info.plist as a
// statement of intent. These two tests pin the declarations to the code that
// would actually trigger the prompt, so the plist cannot drift back into
// promising more than the binary does.
//
// Separate from `AppReviewConfigurationTests` only because that file already
// sits two lines under the 600-line lint ceiling.
import Foundation
@testable import HealthLog
import Testing

@Suite("Permission declarations match the code that would prompt")
struct PermissionDeclarationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 1.0.3 / audit row 26 (5.1.1(ii)) — over-declared permissions.
    ///
    /// `NSPhotoLibraryUsageDescription` is gone because every photo entry point
    /// is the out-of-process SwiftUI picker, which never asks for library
    /// authorization. The grep is part of the assertion on purpose: the day
    /// someone reaches for `PHPhotoLibrary`, `PHPickerViewController`,
    /// `UIImagePickerController` or `import Photos`, this test fails and the key
    /// has to come back before that code ships.
    @Test("no photo-library permission is declared while every picker is out-of-process")
    func photoLibraryPermissionStaysUndeclared() throws {
        let project = try text("project.yml")
        let purposeFiles = try CatalogLanguages.listed.map { try text("HealthLog/Resources/\($0).lproj/InfoPlist.strings") }
        for file in [project] + purposeFiles {
            #expect(!file.contains("NSPhotoLibraryUsageDescription: ") && !file.contains("\"NSPhotoLibraryUsageDescription\" ="))
        }

        let sourceRoot = Self.root.appendingPathComponent("HealthLog")
        let enumerator = try #require(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in body.split(separator: "\n") {
                // Skip prose: only a real call site or import counts.
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                for symbol in ["PHPhotoLibrary", "PHPickerViewController", "UIImagePickerController(", "import Photos"]
                    where line.contains(symbol) && !line.contains("import PhotosUI")
                {
                    offenders.append("\(url.lastPathComponent): \(symbol)")
                }
            }
        }
        #expect(offenders.isEmpty, "an in-process photo API appeared — restore NSPhotoLibraryUsageDescription: \(offenders)")
    }

    /// 1.0.3 / audit row 26 — the Bluetooth purpose string may promise only the
    /// device families the app actually registers a discovery profile for.
    @Test("the Bluetooth purpose string promises only what is registered")
    func bluetoothPurposeMatchesRegisteredProfiles() throws {
        let delegate = try text("HealthLog/Services/HealthKit/HealthLogSpeziDelegate.swift")
        #expect(delegate.contains("OmronBloodPressureCuff.self"))
        #expect(!delegate.contains("WeightScale"), "a scale profile appeared — widen the Bluetooth purpose string")
        #expect(!delegate.contains("GlucoseMeter"), "a glucose profile appeared — widen the Bluetooth purpose string")

        let german = try text("HealthLog/Resources/de.lproj/InfoPlist.strings")
        let english = try text("HealthLog/Resources/en.lproj/InfoPlist.strings")
        #expect(german.contains("Omron"))
        #expect(english.contains("Omron"))
        #expect(!german.contains("Glukose-Sensoren und Waagen"))
        #expect(!english.contains("glucose sensors, and scales"))
        for language in CatalogLanguages.listed {
            #expect(try text("HealthLog/Resources/\(language).lproj/InfoPlist.strings").contains("Omron"), "\(language) omits Omron")
        }
    }

    /// 1.5 L10N-NL — a language in `CFBundleLocalizations` without its own
    /// purpose string shows the English one in the system prompt. Every
    /// listed language (also a `pending` one) carries every key English has.
    @Test("every listed language declares the same purpose strings as English")
    func everyListedLanguageHasEveryPurposeString() throws {
        let english = try purposeKeys("en")
        #expect(english.count >= 9)
        #expect(CatalogLanguages.listed.contains("nl"))
        for language in CatalogLanguages.listed {
            #expect(try purposeKeys(language) == english, "\(language).lproj/InfoPlist.strings differs from English")
        }
    }

    private func purposeKeys(_ language: String) throws -> Set<String> {
        let body = try text("HealthLog/Resources/\(language).lproj/InfoPlist.strings")
        return Set(body.split(separator: "\n").compactMap { line in
            line.hasPrefix("\"") ? line.split(separator: "\"").first.map(String.init) : nil
        })
    }
}
