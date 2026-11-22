import Foundation

#if canImport(UserNotifications) && canImport(UIKit)

    /// Where a plain tap on a push lands when no earlier
    /// branch of `dispatchAction` claimed it (mood reminder, preventive-care
    /// reminder, a medication with its id).
    ///
    /// The server's top-level `url` wins: every visible push carries one since
    /// v1.43, and a Guardian or discreet delivery carries `/` so it opens home.
    /// The older `deepLink` (only local banners still set it) is the fallback.
    extension NotificationService {
        /// What a body tap opens.
        enum BodyTapTarget: Equatable {
            case route(DeepLinkRoute)
            case link(URL)
        }

        nonisolated static func bodyTapTarget(for payload: APNsPayload) -> BodyTapTarget? {
            if let path = payload.url {
                return .route(DeepLinkRoute.fromPushPath(path))
            }
            if let link = payload.deepLink {
                return .link(link)
            }
            // Server 1.49.0: a notable value opens its metric's page. A sealed
            // relay envelope has no `url` and names the type in `d.metric`;
            // without one it opens Insights.
            if payload.eventType == measurementAnomalyEvent {
                return .route(.insights(metric: insightsSlug(forMeasurementType: payload.metric)))
            }
            return nil
        }

        /// The Insights slug of a server `MeasurementType` (`RESTING_HEART_RATE`
        /// opens `resting-pulse`); `nil` for an unknown type or one without a
        /// page of its own, which opens the overview.
        nonisolated static func insightsSlug(forMeasurementType raw: String?) -> String? {
            guard let raw, let kind = ServerMeasurementType(rawValue: raw)?.metricKind else { return nil }
            return InsightsLayoutTileId.slug(forKind: kind)
        }

        /// The push type of a sustained level shift in a vital (server 1.49.0,
        /// opt-in, off by default).
        nonisolated static let measurementAnomalyEvent = "MEASUREMENT_ANOMALY"

        @MainActor
        func routeBodyTap(_ payload: APNsPayload) {
            switch Self.bodyTapTarget(for: payload) {
            case let .route(route): deepLinks.handle(route)
            case let .link(url): deepLinks.handle(url)
            case nil: break
            }
        }
    }

#endif
