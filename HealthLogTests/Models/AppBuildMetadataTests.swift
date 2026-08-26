import Foundation
@testable import HealthLog
import Testing

/// **08-07 — About may state the build it is, and nothing else.**
///
/// The defect this suite pins down shipped for eleven releases: About composed
/// the displayed version as `CFBundleShortVersionString + "." +
/// (CFBundleVersion - 40)`, so the screen named a four-segment release that
/// exists in no tag and no archive, and then claimed — with no check of any
/// kind, against any store or any server — that the installation was current.
///
/// Both halves are contract here. The exactness cases prove nothing is
/// computed; ``aboutRowsAreReadFromTheBundleKeys()`` proves About's seam reads
/// the two Apple keys into two separate rows; and
/// ``noCurrencyClaimSurvivesInTheCatalogue()`` keeps the currency claim from
/// returning through the catalogue after the view code stopped saying it.
@Suite("08-07 — exact release metadata")
struct AppBuildMetadataTests {
    // MARK: - Exactness

    @Test("both bundle values are returned verbatim, never composed")
    func exactValuesAreReturnedUntouched() {
        let metadata = AppBuildMetadata(marketingVersion: "0.19.0", build: "263")
        #expect(metadata.marketingVersion == "0.19.0")
        #expect(metadata.build == "263")
        #expect(metadata.marketingVersionText(unknown: "?") == "0.19.0")
        #expect(metadata.buildText(unknown: "?") == "263")
        #expect(metadata.isComplete)
    }

    /// The shipped defect, replayed exactly: `0.6.1` with build `41` rendered
    /// as `0.6.1.1`, because `41 - 40 == 1`. Both values are chosen so any
    /// surviving arithmetic would be visible in the result.
    @Test("no arithmetic relates the marketing version to the build")
    func versionIsNeverComposedFromTheBuild() {
        let metadata = AppBuildMetadata(marketingVersion: "0.6.1", build: "41")
        #expect(metadata.marketingVersionText(unknown: "?") == "0.6.1")
        #expect(metadata.buildText(unknown: "?") == "41")
        #expect(metadata.marketingVersionText(unknown: "?").split(separator: ".").count == 3)
        #expect(!metadata.marketingVersionText(unknown: "?").contains("41"))
    }

    /// A marketing version is an opaque string to this app: it may carry a
    /// pre-release suffix, one segment or four. Whatever the bundle says is
    /// what the archive was built as, and reformatting it would be the same
    /// class of invention as the arithmetic.
    @Test("an unusual but real bundle string is passed through unchanged")
    func unusualValuesArePassedThrough() {
        let metadata = AppBuildMetadata(marketingVersion: "1.0.0-rc.2", build: "263.1")
        #expect(metadata.marketingVersion == "1.0.0-rc.2")
        #expect(metadata.build == "263.1")
    }

    // MARK: - Missing values

    @Test("an absent, blank or non-string value is unknown rather than guessed")
    func missingValuesBecomeUnknown() {
        let absent = AppBuildMetadata(marketingVersion: nil, build: nil)
        #expect(absent.marketingVersion == nil)
        #expect(absent.build == nil)
        #expect(!absent.isComplete)

        let blank = AppBuildMetadata(marketingVersion: "", build: "   \n ")
        #expect(blank == absent, "a value that names no version is the same fact as no value")

        // `object(forInfoDictionaryKey:)` is untyped, so a plist that stores a
        // number or an array under either key is representable. Reading such a
        // value as a version would be a guess about what its author meant.
        let mistypedVersion: Any? = 19
        let mistypedBuild: Any? = ["263"]
        #expect(AppBuildMetadata(marketingVersion: mistypedVersion, build: mistypedBuild) == absent)

        #expect(absent.marketingVersionText(unknown: "Unbekannt") == "Unbekannt")
        #expect(absent.buildText(unknown: "Unbekannt") == "Unbekannt")
    }

    @Test("one known value neither completes the identity nor borrows the other")
    func partialIdentityStaysPartial() {
        let versionOnly = AppBuildMetadata(marketingVersion: "0.19.0", build: nil)
        #expect(!versionOnly.isComplete)
        #expect(versionOnly.marketingVersionText(unknown: "Unknown") == "0.19.0")
        #expect(versionOnly.buildText(unknown: "Unknown") == "Unknown")

        let buildOnly = AppBuildMetadata(marketingVersion: " ", build: "263")
        #expect(!buildOnly.isComplete)
        #expect(buildOnly.marketingVersionText(unknown: "Unknown") == "Unknown")
        #expect(buildOnly.buildText(unknown: "Unknown") == "263")
    }

    @Test("surrounding whitespace is the only normalisation applied")
    func whitespaceIsTheOnlyNormalisation() {
        let metadata = AppBuildMetadata(marketingVersion: "  0.19.0\n", build: "\t263 ")
        #expect(metadata.marketingVersion == "0.19.0")
        #expect(metadata.build == "263")
    }

    // MARK: - The About seam

    /// The one impure step, asserted against the running host bundle: About
    /// must read `CFBundleShortVersionString` into the version row and
    /// `CFBundleVersion` into the build row — not one of them twice, and not a
    /// value derived from either.
    @Test("About reads both bundle keys, and reads each into its own row")
    @MainActor
    func aboutRowsAreReadFromTheBundleKeys() throws {
        let metadata = SettingsAboutScreen.buildMetadata()
        let version = try #require(metadata.marketingVersion, "the host bundle carries no marketing version")
        let build = try #require(metadata.build, "the host bundle carries no build number")

        #expect(version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        #expect(version != build, "the two rows must not display the same value")
        #expect(metadata.isComplete)
        // Apple caps the marketing version at three segments, which is what
        // made the old `short + "." + (build - 40)` string impossible.
        #expect(version.split(separator: ".").count <= 3, "a marketing version has at most three segments")
    }

    // MARK: - The claims that must not return

    /// Deleting the view code does not retire a claim: the catalogue outlives
    /// the screen, so a re-added `Text(...)` would resolve a still-present key
    /// straight back into "Aktuelle Version installiert". The replacement and
    /// the unknown fallback are checked for DE **and** EN in the same pass,
    /// because a fallback that renders its key is not a localized fallback.
    @Test("no currency claim survives in the catalogue, and both replacements are translated")
    func noCurrencyClaimSurvivesInTheCatalogue() throws {
        let catalog = try ParityCatalog.load()
        #expect(
            catalog.strings["Current version installed."] == nil,
            "the currency claim must leave the catalogue with the row that stated it"
        )

        let replacement = try #require(catalog.strings["settings.about.updates.no_version_check"])
        let de = try #require(ParityCatalog.value(replacement, language: "de"))
        let en = try #require(ParityCatalog.value(replacement, language: "en"))
        #expect(de.contains("nicht"), "the DE row must state that no check happens")
        #expect(en.localizedCaseInsensitiveContains("does not check"))

        let unknown = try #require(catalog.strings["Unknown"], "the About rows need a localized unknown fallback")
        #expect(ParityCatalog.value(unknown, language: "de") != nil)
        #expect(ParityCatalog.value(unknown, language: "en") != nil)
    }
}
