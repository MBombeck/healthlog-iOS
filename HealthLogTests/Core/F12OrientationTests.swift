// Reads the app bundle's Info.plist and drives the App-target delegates,
// which the SPM library build has no part of.
#if !SWIFT_PACKAGE && canImport(UIKit)

    @testable import HealthLog
    import Testing
    import UIKit

    /// The phone may turn at all (the plist), but only the timeline's full
    /// screen and the full-screen chart let it (the policy). On a device the
    /// scene's mask is cut with the plist, so a plist with portrait alone kept
    /// the timeline upright although the simulator turned it. In the
    /// serialized `OrientationPolicyTests` suite, so no other test reads the
    /// switch while these set it.
    extension OrientationPolicyTests {
        /// The raw values in the built bundle's Info.plist. Read from the file:
        /// on a phone the bundle answers `~ipad` keys with nothing.
        private static func orientations(_ key: String) throws -> Set<String> {
            let url = Bundle.main.bundleURL.appendingPathComponent("Info.plist")
            let data = try Data(contentsOf: url)
            let plist = try #require(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                "the built bundle's Info.plist does not read"
            )
            let values = try #require(plist[key] as? [String], "the built bundle has no \(key)")
            return Set(values)
        }

        @Test("the built bundle lets the phone stand upright and turn either way across, never upside down")
        func phonePlist() throws {
            let phone = try Self.orientations("UISupportedInterfaceOrientations")
            #expect(phone == [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ])
        }

        @Test("the built bundle lets the iPad turn every way")
        func padPlist() throws {
            let pad = try Self.orientations("UISupportedInterfaceOrientations~ipad")
            #expect(pad == [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ])
        }

        @Test("every screen but the two full screens keeps the phone upright")
        func otherScreensUpright() {
            #expect(!OrientationPolicy.allowsLandscape)
            let mask = OrientationPolicy.mask(isPad: false, allowsLandscape: OrientationPolicy.allowsLandscape)
            #expect(mask == .portrait)
            #expect(!mask.contains(.landscapeLeft))
            #expect(!mask.contains(.landscapeRight))
        }

        @Test("the app delegate answers the same mask as the policy, for iOS 26 where the scene is not asked")
        func appDelegateFollowsPolicy() {
            defer { OrientationPolicy.allowLandscape(false) }
            let delegate = AppDelegate()
            let isPad = OrientationPolicy.deviceIsPad
            #expect(delegate.application(.shared, supportedInterfaceOrientationsFor: nil)
                == OrientationPolicy.mask(isPad: isPad, allowsLandscape: false))
            OrientationPolicy.allowLandscape(true)
            #expect(delegate.application(.shared, supportedInterfaceOrientationsFor: nil)
                == OrientationPolicy.mask(isPad: isPad, allowsLandscape: true))
        }

        @Test("opening the timeline's cover allows the turn and asks for it; its X asks upright and takes it back")
        func coverTurnsAndReturns() {
            let log = F12TurnLog()
            let session = TimelineSession()
            session.turns = log.turns

            session.openAcross()
            #expect(log.moves == ["allow", "across"])
            // The permission is in place before the turn is asked for.
            #expect(OrientationPolicy.mask(isPad: false, allowsLandscape: log.allowed).contains(.landscapeRight))

            session.closeAcross()
            #expect(log.moves == ["allow", "across", "upright", "disallow"])
            #expect(OrientationPolicy.mask(isPad: false, allowsLandscape: log.allowed) == .portrait)
        }
    }

    /// Records the session's turns in order and the permission they leave.
    @MainActor
    private final class F12TurnLog {
        var moves: [String] = []
        var allowed = false

        var turns: TimelineTurns {
            TimelineTurns(
                allow: { [weak self] in
                    self?.allowed = $0
                    self?.moves.append($0 ? "allow" : "disallow")
                },
                requestAcross: { [weak self] in self?.moves.append("across") },
                requestUpright: { [weak self] in self?.moves.append("upright") }
            )
        }
    }

#endif
