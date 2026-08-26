import CoreGraphics
import Foundation
@testable import HealthLog
import SwiftUI
import Testing

@MainActor
@Suite("Phase 06 terminal privacy composition")
struct PrivacyBoundaryCompositionTests {
    private func repoSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Already-open PHI sheets unmount before an inactive snapshot")
    func alreadyOpenPHISheetUnmountsBeforeInactiveSnapshot() throws {
        let source = try repoSource("HealthLog/App/RootView.swift")
        let structuralGatePrecedesContent = source.contains("RootPrivacyShieldPolicy.resolve(")
            && source.contains("case let .protected(reason):")
            && source.contains("case .unprotected:")
        #expect(
            structuralGatePrecedesContent,
            "EXPECTED_RED: already-open PHI sheet remained mounted"
        )
    }

    @Test("Celebration and undo state cannot outrank biometric protection")
    func alreadyOpenCelebrationAndUndoCannotOutrankBiometricShield() throws {
        let root = try repoSource("HealthLog/App/RootView.swift")
        let shell = try repoSource("HealthLog/App/AuthenticatedShell.swift")
        let hasTerminalOrdering = !root.contains("greatestFiniteMagnitude")
            && !root.contains("LockOverlay(")
            && shell.contains("HLUndoToast(")
        #expect(
            hasTerminalOrdering,
            "EXPECTED_RED: health overlay outranked biometric shield"
        )
    }

    @Test("Protected pixels are opaque and contain no saturated PHI sentinel")
    func shieldPixelsAreOpaque() throws {
        let view = ZStack {
            Color(red: 1, green: 0, blue: 1)
            RootPrivacyShield(reason: .biometricLocked, onUnlock: {}, onSignOut: {})
        }
        .frame(width: 240, height: 320)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.colorScheme, .dark)
        .transaction { transaction in transaction.disablesAnimations = true }

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "privacy fixture did not render")
        let cgImage = try #require(image.cgImage, "privacy fixture produced no CGImage")
        let metrics = try pixelMetrics(cgImage)
        let source = try repoSource("HealthLog/App/RootView.swift")

        #expect(
            metrics.sentinelPixels == 0 && metrics.minimumAlpha == 255
                && !source.contains("ultraThinMaterial"),
            "EXPECTED_RED: protected pixels exposed PHI sentinel"
        )
    }

    private func pixelMetrics(_ image: CGImage) throws -> (sentinelPixels: Int, minimumAlpha: UInt8) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sentinelPixels = 0
        var minimumAlpha = UInt8.max
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            let alpha = pixels[index + 3]
            minimumAlpha = min(minimumAlpha, alpha)
            if red > 220, green < 40, blue > 220, alpha > 240 {
                sentinelPixels += 1
            }
        }
        return (sentinelPixels, minimumAlpha)
    }
}
