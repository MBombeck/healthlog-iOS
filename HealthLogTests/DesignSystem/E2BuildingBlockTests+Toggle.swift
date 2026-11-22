@testable import HealthLog
import SwiftUI
import Testing
import UIKit

extension E2BuildingBlockTests {
    @Test("a switch that is on shows the system green, in light and dark", arguments: [UIUserInterfaceStyle.light, .dark])
    func toggleOnIsGreen(style: UIUserInterfaceStyle) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let tint = UIColor(HLToggleStyle.onTint).resolvedColor(with: traits)
        let green = UIColor.systemGreen.resolvedColor(with: traits)
        #expect(tint.isEqual(green) || tint.cgColor.components == green.cgColor.components)
    }
}
