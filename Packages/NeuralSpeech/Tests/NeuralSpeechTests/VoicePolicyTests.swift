import Foundation
import Testing
@testable import NeuralSpeech

@Suite struct VoicePolicyTests {
    @Test func oneOutlierDoesNotMoveTheMedian() {
        var tracker = SynthesisSpeedTracker(capacity: 9)
        for rtf in [0.55, 0.58, 0.54, 0.6, 0.57] { let accepted = tracker.record(rtf: rtf, audioSeconds: 6); #expect(accepted) }
        // The calibration taken while the phone was locked (seen on the device: 1.4566) is just one more sample.
        let outlier = tracker.record(rtf: 1.4566, audioSeconds: 7.6)
        #expect(outlier)
        let median = try! #require(tracker.median)
        #expect(median < 0.62)
        #expect(VoiceSpeedClass(rtf: median) == .realtime)
    }

    @Test func unusableSamplesAreIgnored() {
        var tracker = SynthesisSpeedTracker()
        let notANumber = tracker.record(rtf: .nan, audioSeconds: 5)
        let tooShort = tracker.record(rtf: 0.5, audioSeconds: 0.4)      // too short to say anything about steady speed
        let zero = tracker.record(rtf: 0, audioSeconds: 5)
        let absurd = tracker.record(rtf: 40, audioSeconds: 5)
        #expect(!notANumber && !tooShort && !zero && !absurd)
        #expect(tracker.median == nil)
        #expect(VoiceSpeedClass(rtf: tracker.median) == .unmeasured)
    }

    @Test func capacityKeepsOnlyRecentSamples() {
        var tracker = SynthesisSpeedTracker(capacity: 3)
        for rtf in [2.0, 2.0, 2.0, 0.5, 0.5, 0.5] { tracker.record(rtf: rtf, audioSeconds: 5) }
        #expect(tracker.samples == [0.5, 0.5, 0.5])
        #expect(tracker.median == 0.5)
    }

    @Test func slowDevicesGetLongerLeadButNeverAnotherVoice() {
        #expect(PlaybackLeadPolicy.lead(rtf: nil) == PlaybackLeadPolicy.minimum)
        #expect(PlaybackLeadPolicy.lead(rtf: 0.5) == PlaybackLeadPolicy.minimum)
        let slightly = PlaybackLeadPolicy.lead(rtf: 0.8), slow = PlaybackLeadPolicy.lead(rtf: 1.4)
        #expect(slightly > PlaybackLeadPolicy.minimum && slow > slightly)
        #expect(PlaybackLeadPolicy.lead(rtf: 9, extra: 9) == PlaybackLeadPolicy.maximum)
        #expect(PlaybackLeadPolicy.lead(rtf: .infinity) == PlaybackLeadPolicy.minimum)
        // Extra lead after an underrun is bounded.
        #expect(PlaybackLeadPolicy.lead(rtf: 0.5, extra: 99) == PlaybackLeadPolicy.minimum + PlaybackLeadPolicy.maximumExtra)
    }

    @Test func retiredVoicesResolveToLivingVoices() {
        let living = ["moss-yunshu", "moss-shuyao", "moss-laofu", "moss-ajing"]
        for (old, new) in LegacyVoiceMigration.mapping {
            #expect(LegacyVoiceMigration.isLegacy(old))
            #expect(living.contains(new))
            #expect(LegacyVoiceMigration.resolve(stored: old, available: living, fallback: "moss-yunshu") == new)
        }
        #expect(LegacyVoiceMigration.resolve(stored: "moss-laofu", available: living, fallback: "moss-yunshu") == "moss-laofu")
        #expect(LegacyVoiceMigration.resolve(stored: nil, available: living, fallback: "x") == "moss-yunshu")
        #expect(LegacyVoiceMigration.resolve(stored: "zf_999", available: living, fallback: "x") == "moss-yunshu")
        #expect(LegacyVoiceMigration.resolve(stored: "whatever", available: [], fallback: "moss-yunshu") == "moss-yunshu")
    }

    @Test func everyRetiredArtifactIsListedForCleanup() {
        #expect(LegacyVoiceMigration.artifactIDs.contains("kokoro-82m-coreml"))
        #expect(LegacyVoiceMigration.artifactIDs.contains("kokoro-voice-zm_014"))
        #expect(!LegacyVoiceMigration.artifactIDs.contains("kokoro-voice-zf_001"))   // zf_001/zf_003 lived in the base package
        #expect(Set(LegacyVoiceMigration.artifactIDs).count == LegacyVoiceMigration.artifactIDs.count)
        #expect(VoicePreviewText.chunks.count == 2)
    }
}

@Suite struct DownloadSpeedMeterTests {
    @Test func needsTwoSamplesBeforeClaimingASpeed() {
        var meter = DownloadSpeedMeter()
        meter.update(bytes: 0, at: 0)
        #expect(meter.bytesPerSecond == nil)
        meter.update(bytes: 500_000, at: 0.4)           // too soon to say anything
        #expect(meter.bytesPerSecond == nil)
        meter.update(bytes: 2_000_000, at: 2)
        #expect(meter.bytesPerSecond == 1_000_000)
        let eta = try! #require(meter.secondsRemaining(done: 2_000_000, total: 5_000_000))
        #expect(abs(eta - 3) < 0.001)
    }

    @Test func aRestartedDownloadDropsTheOldSpeed() {
        var meter = DownloadSpeedMeter()
        meter.update(bytes: 0, at: 0); meter.update(bytes: 3_000_000, at: 3)
        #expect(meter.bytesPerSecond != nil)
        meter.update(bytes: 100, at: 5)
        #expect(meter.bytesPerSecond == nil)
        #expect(meter.secondsRemaining(done: 100, total: 1000) == nil)
    }
}
