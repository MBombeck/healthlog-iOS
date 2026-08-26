import Foundation

public struct CycleCustomSymptomDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let key: String
    public let label: String?
    public let icon: String?
    public let isActive: Bool
    public let custom: Bool

    public var id: String {
        key
    }

    public var displayLabel: String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        return label
    }

    /// Cycle custom icons are server-controlled. Keep their rendering local to
    /// this feature and degrade unknown values to a stable, visible SF Symbol.
    public var safeSystemImage: String {
        switch icon ?? "" {
        case "Activity": "figure.run"
        case "Heart": "heart"
        case "HeartPulse": "waveform.path.ecg"
        case "Brain": "brain.head.profile"
        case "Zap": "bolt"
        case "Flame": "flame"
        case "Snowflake": "snowflake"
        case "Droplet": "drop"
        case "CircleDot": "circle.circle"
        case "BatteryLow": "battery.25percent"
        case "MoonStar": "moon.stars"
        case "PersonStanding": "figure.stand"
        case "Drama": "theatermasks"
        case "Frown": "face.dashed"
        case "Cookie": "birthday.cake"
        case "Soup": "takeoutbag.and.cup.and.straw"
        case "Pill": "pill"
        case "Thermometer": "thermometer.medium"
        case "Stethoscope": "stethoscope"
        case "Tag": "tag"
        default: "tag"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? true
    }
}

public struct CycleCustomSymptomsResponse: Codable, Sendable, Equatable {
    public let symptoms: [CycleCustomSymptomDTO]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symptoms = try c.decodeIfPresent([CycleCustomSymptomDTO].self, forKey: .symptoms) ?? []
    }
}

public struct CycleCustomSymptomCreate: Encodable, Sendable, Equatable {
    public let label: String
    public let icon: String?
    public let categoryKey: String

    public init(label: String, icon: String? = nil, categoryKey: String = "custom") {
        self.label = label
        self.icon = icon
        self.categoryKey = categoryKey
    }
}

public struct CycleCustomSymptomPatch: Encodable, Sendable, Equatable {
    public let label: String?
    public let icon: RecordPatchField<String>
    public let isActive: Bool?

    public init(
        label: String? = nil,
        icon: RecordPatchField<String> = .unchanged,
        isActive: Bool? = nil
    ) {
        self.label = label
        self.icon = icon
        self.isActive = isActive
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(label, forKey: .label)
        try icon.encode(into: &c, forKey: .icon)
        try c.encodeIfPresent(isActive, forKey: .isActive)
    }

    private enum CodingKeys: String, CodingKey {
        case label, icon, isActive
    }
}

public struct CycleCustomSymptomDeleteResponse: Codable, Sendable, Equatable {
    public let key: String
    public let purged: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        purged = try c.decodeIfPresent(Bool.self, forKey: .purged) ?? false
    }
}
