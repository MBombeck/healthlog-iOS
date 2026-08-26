//
//  UserToFHIRPatient.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  Created 2026-05-22 — v0.6.0 H.2 User+UserProfile → FHIR R4 Patient
//  mapper. Pairs with `MeasurementToFHIRObservation` so the H.3 bundle
//  builder can fold both into one transaction Bundle keyed by
//  `Patient.id`.
//
//  Domain → FHIR field map (all opt-in per UserProfile shape):
//    User.id           → Patient.id
//    User.email        → Patient.telecom[0]  (system=.email)
//    UserProfile.displayName / username → Patient.name[0]
//                          (parsed family + given via naive whitespace split)
//    UserProfile.dateOfBirth → Patient.birthDate
//    UserProfile.gender → Patient.gender (parsed "male"/"female"/"other"/
//                          "unknown" → AdministrativeGender; unrecognised
//                          values omit the field per FHIR best-practice
//                          rather than coercing to `.unknown`).
//
//  Nil-tolerance: every field on `UserProfile` is optional on the wire
//  (server's `/api/user/profile` may omit any of dateOfBirth / gender /
//  heightCm / locale / timezone). The mapper produces a valid Patient
//  with **only** the populated fields, leaving the rest unset.
//

import Foundation
import ModelsR4

/// Maps domain `User` (+ optional `UserProfile`) to a FHIR R4
/// `ModelsR4.Patient` resource.
enum UserToFHIRPatient {
    /// Maps the given user (and optionally their profile) to a FHIR
    /// `Patient` resource. The returned resource is always valid —
    /// missing fields stay unset rather than being filled with
    /// placeholders.
    static func map(_ user: User, profile: UserProfile? = nil) -> Patient {
        let patient = Patient()
        patient.id = FHIRString(user.id).asPrimitive()

        if let name = makeHumanName(
            displayName: profile?.displayName ?? user.displayName,
            username: profile?.username ?? user.username
        ) {
            patient.name = [name]
        }

        if let email = profile?.email ?? user.email, !email.isEmpty {
            let contact = ContactPoint()
            contact.system = ContactPointSystem.email.asPrimitive()
            contact.value = FHIRString(email).asPrimitive()
            patient.telecom = [contact]
        }

        if let dob = profile?.dateOfBirth {
            patient.birthDate = makeFHIRDate(from: dob).asPrimitive()
        }

        if let genderString = profile?.gender,
           let gender = parseGender(genderString)
        {
            patient.gender = gender.asPrimitive()
        }

        return patient
    }

    // MARK: - Helpers

    /// Naive whitespace-split: "Anna Maria Schmidt" → given=["Anna",
    /// "Maria"], family="Schmidt". Falls back to a single-given name if
    /// no whitespace is present. Returns `nil` when both displayName and
    /// username are empty/nil (no name data to emit).
    private static func makeHumanName(displayName: String?, username: String?) -> HumanName? {
        let raw = (displayName?.isEmpty == false ? displayName : username)
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: " ").map(String.init)
        let name = HumanName()
        name.text = FHIRString(raw).asPrimitive()
        if parts.count >= 2, let last = parts.last {
            name.family = FHIRString(last).asPrimitive()
            let given = parts.dropLast().map { FHIRString($0).asPrimitive() }
            name.given = Array(given)
        } else {
            // Single token: treat as given name only (FHIR allows this).
            name.given = [FHIRString(raw).asPrimitive()]
        }
        return name
    }

    private static func makeFHIRDate(from date: Date) -> FHIRDate {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month: UInt8? = components.month.map { UInt8(clamping: $0) }
        let day: UInt8? = components.day.map { UInt8(clamping: $0) }
        return FHIRDate(year: year, month: month, day: day)
    }

    /// Parse the server's free-form gender string into a FHIR
    /// `AdministrativeGender`. Unrecognised inputs return `nil` so the
    /// mapper can omit the field rather than coerce to `.unknown`.
    private static func parseGender(_ raw: String) -> AdministrativeGender? {
        switch raw.lowercased() {
        case "male", "m", "männlich", "maennlich":
            .male
        case "female", "f", "weiblich":
            .female
        case "other", "divers", "non-binary", "nonbinary", "nb":
            .other
        case "unknown", "unbekannt":
            .unknown
        default:
            nil
        }
    }
}
