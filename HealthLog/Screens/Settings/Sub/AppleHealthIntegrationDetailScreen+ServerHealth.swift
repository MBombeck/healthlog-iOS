import SwiftUI

extension AppleHealthIntegrationDetailScreen {
    /// What the server says about this phone's deliveries
    /// (`health` on `GET /api/integrations/healthkit`), one sentence per
    /// reason. No button: the device-side permission flow is the connect
    /// button of the same card. Nothing on a server before v1.42.4.
    @ViewBuilder
    var serverHealthLine: some View {
        if let health = store.hkConfig?.health {
            ConnectionHealthSection(health: health)
        }
    }
}
