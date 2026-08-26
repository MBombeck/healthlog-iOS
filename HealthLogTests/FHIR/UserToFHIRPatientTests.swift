//
//  UserToFHIRPatientTests.swift
//  HealthLogTests
//
//  Created 2026-05-22 — v0.6.0 H.2 coverage for `UserToFHIRPatient`.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

@Suite("UserToFHIRPatient — v0.6.0 H.2 mapper")
struct UserToFHIRPatientTests {
    private func makeUser(
        id: String = "u-1",
        email: String? = nil,
        username: String? = nil,
        displayName: String? = nil
    ) -> User {
        User(id: id, email: email, username: username, displayName: displayName, createdAt: nil)
    }

    private func makeProfile(
        displayName: String? = nil,
        email: String? = nil,
        dateOfBirth: Date? = nil,
        gender: String? = nil
    ) -> UserProfile {
        UserProfile(
            username: nil,
            displayName: displayName,
            email: email,
            dateOfBirth: dateOfBirth,
            gender: gender,
            heightCm: nil,
            locale: nil,
            timezone: nil
        )
    }

    @Test("Patient.id = User.id")
    func patientIDFromUserID() {
        let patient = UserToFHIRPatient.map(makeUser(id: "abc-42"))
        #expect(patient.id?.value?.string == "abc-42")
    }

    @Test("Display name 'Anna Schmidt' → family=Schmidt + given=[Anna]")
    func displayNameSplit() throws {
        let user = makeUser(displayName: "Anna Schmidt")
        let patient = UserToFHIRPatient.map(user)
        let name = try #require(patient.name?.first)
        #expect(name.family?.value?.string == "Schmidt")
        #expect(name.given?.compactMap(\.value?.string) == ["Anna"])
        #expect(name.text?.value?.string == "Anna Schmidt")
    }

    @Test("Multi-token name 'Anna Maria Schmidt' → family=Schmidt + given=[Anna, Maria]")
    func multiGivenSplit() throws {
        let patient = UserToFHIRPatient.map(makeUser(displayName: "Anna Maria Schmidt"))
        let name = try #require(patient.name?.first)
        #expect(name.family?.value?.string == "Schmidt")
        #expect(name.given?.compactMap(\.value?.string) == ["Anna", "Maria"])
    }

    @Test("Single-token name 'Cher' → given=[Cher], family=nil")
    func singleTokenName() throws {
        let patient = UserToFHIRPatient.map(makeUser(displayName: "Cher"))
        let name = try #require(patient.name?.first)
        #expect(name.family == nil)
        #expect(name.given?.compactMap(\.value?.string) == ["Cher"])
    }

    @Test("Falls back to username when displayName is nil")
    func usernameFallback() throws {
        let patient = UserToFHIRPatient.map(makeUser(username: "anna-s"))
        let name = try #require(patient.name?.first)
        #expect(name.given?.compactMap(\.value?.string) == ["anna-s"])
    }

    @Test("No name when both displayName and username are nil")
    func nameAbsentWhenNoSource() {
        let patient = UserToFHIRPatient.map(makeUser())
        #expect(patient.name == nil)
    }

    @Test("Email populates telecom with system=email")
    func emailTelecom() throws {
        let patient = UserToFHIRPatient.map(makeUser(email: "anna@example.com"))
        let telecom = try #require(patient.telecom?.first)
        #expect(telecom.value?.value?.string == "anna@example.com")
        #expect(telecom.system?.value == .email)
    }

    @Test("Empty email is omitted (not encoded as empty telecom)")
    func emptyEmailOmitted() {
        let patient = UserToFHIRPatient.map(makeUser(email: ""))
        #expect(patient.telecom == nil)
    }

    @Test("birthDate from UserProfile.dateOfBirth")
    func birthDateEncoded() throws {
        let dob = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 1985, month: 6, day: 14)))
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(dateOfBirth: dob))
        let bd = try #require(patient.birthDate?.value)
        #expect(bd.year == 1985)
        #expect(bd.month == 6)
        #expect(bd.day == 14)
    }

    @Test("nil dateOfBirth → no birthDate field")
    func noBirthDateWhenNil() {
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(dateOfBirth: nil))
        #expect(patient.birthDate == nil)
    }

    @Test("Gender 'male' → AdministrativeGender.male")
    func genderMale() {
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(gender: "male"))
        #expect(patient.gender?.value == .male)
    }

    @Test("Gender 'female' → AdministrativeGender.female")
    func genderFemale() {
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(gender: "female"))
        #expect(patient.gender?.value == .female)
    }

    @Test("Gender 'other' → AdministrativeGender.other")
    func genderOther() {
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(gender: "other"))
        #expect(patient.gender?.value == .other)
    }

    @Test("Gender 'unknown' → AdministrativeGender.unknown")
    func genderUnknown() {
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(gender: "unknown"))
        #expect(patient.gender?.value == .unknown)
    }

    @Test("Gender = nil → no Patient.gender field")
    func genderAbsentWhenNil() {
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(gender: nil))
        #expect(patient.gender == nil)
    }

    @Test("Unrecognised gender 'space-alien' is omitted (not coerced to .unknown)")
    func unrecognisedGenderOmitted() {
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(gender: "space-alien"))
        #expect(patient.gender == nil)
    }

    @Test("German gender token 'männlich' → .male")
    func germanGender() {
        let patient = UserToFHIRPatient.map(makeUser(), profile: makeProfile(gender: "männlich"))
        #expect(patient.gender?.value == .male)
    }

    @Test("Patient encodes + decodes cleanly via FHIRModels JSON coder")
    func jsonRoundTrip() throws {
        let dob = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 1990, month: 3, day: 1)))
        let user = makeUser(id: "rt-1", email: "rt@example.com", displayName: "Round Trip")
        let profile = makeProfile(dateOfBirth: dob, gender: "female")
        let patient = UserToFHIRPatient.map(user, profile: profile)

        let data = try JSONEncoder().encode(patient)
        let decoded = try JSONDecoder().decode(Patient.self, from: data)
        #expect(decoded.id?.value?.string == "rt-1")
        #expect(decoded.gender?.value == .female)
        #expect(decoded.telecom?.first?.value?.value?.string == "rt@example.com")
        #expect(decoded.birthDate?.value?.year == 1990)
        #expect(decoded.name?.first?.family?.value?.string == "Trip")
    }
}
