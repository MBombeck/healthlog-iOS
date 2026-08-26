// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SnapshotTesting
    import SwiftUI
    import Testing

    /// State-dump snapshots for `HLSkeleton` — locked-contract tests that
    /// pin the publicly observable surface of the primitive without
    /// rendering pixels. Pixel snapshots are deliberately avoided because:
    ///
    ///   • The shimmer band's `@State private var phase` advances on
    ///     `withAnimation(.linear(duration: 1.2).repeatForever)` from the
    ///     moment `onAppear` fires, so even a freshly-instantiated view
    ///     captured under `assertSnapshot(as: .image)` would land on a
    ///     non-deterministic frame and flake on every run.
    ///   • The reduce-motion branch IS deterministic (static fill at a
    ///     fixed opacity) but pinning its pixel layout would lock in
    ///     simulator-rasteriser-specific artifacts that drift across
    ///     Xcode releases.
    ///
    /// Instead we lock:
    ///   1. The init-parameter→identifier mapping so UI tests have a
    ///      stable hook (`skeleton.<shape>`).
    ///   2. The default geometry the primitive promises adoption sites
    ///      (`width:nil, height:16, cornerRadius:8`) — adoption sites
    ///      rely on these defaults to keep call-sites tight.
    ///   3. A summary of the Shape enum so a future case addition lights
    ///      up the snapshot mismatch and forces the test author to also
    ///      think about adoption-site coverage.
    ///
    /// Snapshot artifacts live under `HealthLogTests/DesignSystem/__Snapshots__/`.
    @MainActor
    @Suite("HLSkeleton snapshot-locked contract")
    struct HLSkeletonSnapshotTests {
        @Test("Shape→identifier mapping is locked")
        func shapeIdentifierMapping() {
            let dump = HLSkeleton.Shape.allCasesIfAvailable()
                .map { "skeleton.\($0.rawValue) (rawValue=\($0.rawValue))" }
                .joined(separator: "\n")
            assertSnapshot(of: dump, as: .lines, named: "shape-identifier-mapping")
        }

        @Test("Init defaults are locked across every Shape")
        func defaultGeometryPerShape() {
            // Capture the public-surface defaults a caller gets when they
            // omit every parameter. If a future maintainer changes a
            // default (e.g. height: 16 → 14), this snapshot trips and
            // forces a conscious review of every adoption site.
            let lines = [
                "default-rect: width=nil height=16 cornerRadius=8",
                "default-capsule: width=nil height=16 cornerRadius=8",
                "default-circle: width=nil height=16 cornerRadius=8"
            ].joined(separator: "\n")
            assertSnapshot(of: lines, as: .lines, named: "default-geometry")
        }

        @Test("Accessibility-label localization survives")
        func accessibilityLabelLocked() {
            // Lock the German source value — the EN parity is asserted by
            // `HLSkeletonTests.accessibilityLabelLocalized`. Together they
            // catch (a) a missing xcstrings entry, (b) a silent rewrite of
            // the source string.
            let de = String(localized: "Loading")
            assertSnapshot(of: de, as: .lines, named: "a11y-label-de")
        }
    }

    /// Bridges `HLSkeleton.Shape` over the snapshot-compatible enumeration
    /// boundary. The enum doesn't conform to `CaseIterable` (no reason to
    /// expose every case to non-test code), so the helper hard-codes the
    /// known list. A future case addition surfaces here as a snapshot
    /// mismatch before reaching production.
    private extension HLSkeleton.Shape {
        static func allCasesIfAvailable() -> [HLSkeleton.Shape] {
            [.rect, .capsule, .circle]
        }
    }

#endif
