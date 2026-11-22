import SwiftUI

/// What the Apple Health pages show on a device that reads no HealthKit (the
/// iPad, see ``HealthKitAvailabilityPolicy``): one quiet card instead of
/// switches that could never do anything. The data still arrives through the
/// server, written there by the iPhone.
struct AppleHealthPadNotice: View {
    var body: some View {
        HLPage {
            HLCard("health.padNotice.title") {
                Text("health.padNotice.body")
                    .hlText(.factLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("health.padNotice")
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
    }
}
