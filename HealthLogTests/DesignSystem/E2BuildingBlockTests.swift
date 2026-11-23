@testable import HealthLog
import SwiftUI
import Testing

/// The building blocks that many pages share, held to the target forms: a
/// card label in sentence case, an empty state at the top of its page, a
/// statistic whose cells keep one height, identifiers that break only where
/// they may, form pickers that stack at the accessibility sizes. Each block's
/// cases stand in an extension of their own.
@MainActor
@Suite("E2 building blocks")
struct E2BuildingBlockTests {}
