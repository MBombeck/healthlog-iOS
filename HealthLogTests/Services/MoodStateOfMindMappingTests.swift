import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

/// **v0.10.0 W-Mood-B** — pins the HealthLog ↔ `HKStateOfMind` mapping:
/// score↔valence anchors + bucketing, the tag→`Label`/`Association` best-effort
/// table, and the documented round-trip stability for our own writes.
@Suite("Mood — State of Mind mapping")
struct MoodStateOfMindMappingTests {
    // MARK: - score → valence

    @Test("score 1…5 maps to the evenly-spaced valence anchors")
    func scoreToValence() {
        #expect(MoodStateOfMindMapping.valence(forScore: 1) == -1.0)
        #expect(MoodStateOfMindMapping.valence(forScore: 2) == -0.5)
        #expect(MoodStateOfMindMapping.valence(forScore: 3) == 0.0)
        #expect(MoodStateOfMindMapping.valence(forScore: 4) == 0.5)
        #expect(MoodStateOfMindMapping.valence(forScore: 5) == 1.0)
    }

    @Test("out-of-range scores clamp to the end anchors")
    func scoreToValenceClamps() {
        #expect(MoodStateOfMindMapping.valence(forScore: 0) == -1.0)
        #expect(MoodStateOfMindMapping.valence(forScore: 9) == 1.0)
    }

    // MARK: - valence → score (bucketing)

    @Test("valence buckets into score 1…5 at the ±0.25 / ±0.75 cutpoints")
    func valenceToScore() {
        #expect(MoodStateOfMindMapping.score(forValence: -1.0) == 1)
        #expect(MoodStateOfMindMapping.score(forValence: -0.8) == 1)
        #expect(MoodStateOfMindMapping.score(forValence: -0.5) == 2)
        #expect(MoodStateOfMindMapping.score(forValence: 0.0) == 3)
        #expect(MoodStateOfMindMapping.score(forValence: 0.5) == 4)
        #expect(MoodStateOfMindMapping.score(forValence: 1.0) == 5)
    }

    @Test("our own writes round-trip score → valence → score exactly")
    func roundTripStableForOurWrites() {
        for score in 1 ... 5 {
            let valence = MoodStateOfMindMapping.valence(forScore: score)
            #expect(MoodStateOfMindMapping.score(forValence: valence) == score)
        }
    }

    @Test("cutpoint boundaries land in the expected buckets")
    func cutpointBoundaries() {
        // Exactly -0.75 is NOT < -0.75 → bucket 2 (the boundary belongs up).
        #expect(MoodStateOfMindMapping.score(forValence: -0.75) == 2)
        #expect(MoodStateOfMindMapping.score(forValence: -0.25) == 3)
        #expect(MoodStateOfMindMapping.score(forValence: 0.25) == 4)
        #expect(MoodStateOfMindMapping.score(forValence: 0.75) == 5)
    }

    // MARK: - tag → Label / Association (best-effort)

    #if canImport(HealthKit)
        @available(iOS 18.0, *)
        @Test("German + English tags map to the expected emotion labels")
        func tagsToLabels() {
            #expect(MoodStateOfMindMapping.labels(forTags: ["gestresst"]) == [.stressed])
            #expect(MoodStateOfMindMapping.labels(forTags: ["Dankbar"]) == [.grateful])
            #expect(MoodStateOfMindMapping.labels(forTags: ["anxious"]) == [.anxious])
        }

        @available(iOS 18.0, *)
        @Test("German + English tags map to the expected context associations")
        func tagsToAssociations() {
            #expect(MoodStateOfMindMapping.associations(forTags: ["arbeit"]) == [.work])
            #expect(MoodStateOfMindMapping.associations(forTags: ["Family"]) == [.family])
            #expect(MoodStateOfMindMapping.associations(forTags: ["schlaf"]) == [.selfCare])
        }

        @available(iOS 18.0, *)
        @Test("unmatched tags are dropped (not round-tripped)")
        func unmatchedTagsDropped() {
            #expect(MoodStateOfMindMapping.labels(forTags: ["xyzzy", "frei-text"]).isEmpty)
            #expect(MoodStateOfMindMapping.associations(forTags: ["xyzzy"]).isEmpty)
        }

        @available(iOS 18.0, *)
        @Test("duplicate matched tags dedupe")
        func duplicateTagsDedupe() {
            #expect(MoodStateOfMindMapping.labels(forTags: ["stressed", "gestresst"]) == [.stressed])
        }
    #endif
}
