import Foundation

/// #153 follow-up — typed `morePath` payload for the rows of
/// the Mehr tab itself, resolved in `MoreScreen`.
///
/// The privacy shield replaces the whole window while the scene is not active,
/// so every view-based push below the More stack was forgotten and the user
/// came back to the stack root. A value on `AppRouter.morePath` lives in the
/// container, in memory only, and the stack rebuilds itself from it. The rows
/// whose screen already had a route (`SettingsRoute.cycle`, `.checkups`,
/// `.appleHealthDetail`, `MentalWellbeingRoute`) push that one instead.
enum MoreRoute: Hashable {
    case shareWithDoctor
    case aboutMe
    case labs
    case illness
    /// The seizure diary (server v1.48.0), offered only while the server
    /// says the `seizures` module is on.
    case seizures
    case documents
    case nutrients
    case environment
    case medicalSources
    case personalRecords
    case achievements
    case workouts
    case measurements
    /// The timeline: lanes and values on one time axis.
    case timeline
    /// Pushed from "About me" when the server has
    /// `features.lifeCircumstances`.
    case lifeCircumstances
}
