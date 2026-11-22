import Foundation
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// The device class the app runs on, reduced to what device logic needs.
///
/// A Duo is a `.phone`; only an iPad is `.pad`. Anything the system reports
/// that is neither (Mac Catalyst, unspecified) behaves like a phone, because
/// the phone is the shape every rule was written for.
public enum DeviceIdiom: Sendable, Equatable {
    case phone
    case pad
}

/// Who and what this device is, read **once** at the app boundary
/// (``current()``) and injected from there: into the container for policies,
/// into the SwiftUI environment for screens. Layout never asks it anything;
/// it exists for device logic (HealthKit availability, which device plans
/// reminders) and for the support text.
public struct DeviceProfile: Sendable, Equatable {
    public let idiom: DeviceIdiom
    /// `UIDevice.model`: the model class ("iPhone", "iPad"), never the name the
    /// owner gave the device. It is also what the app registers with the server.
    public let model: String
    public let systemName: String
    public let systemVersion: String

    public init(idiom: DeviceIdiom, model: String, systemName: String = "iOS", systemVersion: String = "") {
        self.idiom = idiom
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
    }

    /// The neutral value for tests, previews and views outside the app root.
    public static let phone = DeviceProfile(idiom: .phone, model: "iPhone")

    /// The one place the app asks UIKit what device this is.
    @MainActor
    public static func current() -> DeviceProfile {
        #if canImport(UIKit)
            let device = UIDevice.current
            return DeviceProfile(
                idiom: device.userInterfaceIdiom == .pad ? .pad : .phone,
                model: device.model,
                systemName: device.systemName,
                systemVersion: device.systemVersion
            )
        #else
            return .phone
        #endif
    }
}

private struct DeviceProfileKey: EnvironmentKey {
    static let defaultValue = DeviceProfile.phone
}

public extension EnvironmentValues {
    /// Injected once by the app root from ``DeviceProfile/current()``.
    var deviceProfile: DeviceProfile {
        get { self[DeviceProfileKey.self] }
        set { self[DeviceProfileKey.self] = newValue }
    }
}
