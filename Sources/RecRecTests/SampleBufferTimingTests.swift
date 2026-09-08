import CoreMedia
import RecRecCore

func registerSampleBufferTimingTests(_ r: TestRunner) {
    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 24_000) }

    r.test("audio layouts: mono interleaved vs non-interleaved are identical, rate or channel changes are not") {
        func description(_ sb: CMSampleBuffer) -> CMFormatDescription { CMSampleBufferGetFormatDescription(sb)! }
        let interleaved = description(SyntheticMedia.audioSampleBuffer(startTime: t(0), frames: 480, sampleRate: 24_000))
        let planar = description(SyntheticMedia.audioSampleBuffer(startTime: t(0), frames: 480, sampleRate: 24_000, nonInterleaved: true))
        let faster = description(SyntheticMedia.audioSampleBuffer(startTime: t(0), frames: 480, sampleRate: 48_000))
        try expectEqual(CMFormatDescriptionEqual(interleaved, otherFormatDescription: planar), false, "descriptions really differ")
        try expectEqual(AudioFormat.haveIdenticalLayout(interleaved, planar), true)
        try expectEqual(AudioFormat.haveIdenticalLayout(interleaved, faster), false)
        let rewrapped = AudioFormat.rewrapped(SyntheticMedia.audioSampleBuffer(startTime: t(3), frames: 480, sampleRate: 24_000, nonInterleaved: true), formatDescription: interleaved)!
        try expectEqual(CMFormatDescriptionEqual(CMSampleBufferGetFormatDescription(rewrapped)!, otherFormatDescription: interleaved), true)
        try expectEqual(CMSampleBufferGetNumSamples(rewrapped), 480)
        try expectNear(CMSampleBufferGetPresentationTimeStamp(rewrapped).seconds, 3, tolerance: 0.0001)
        try expectNear(CMSampleBufferGetDuration(rewrapped).seconds, 0.02, tolerance: 0.0001)
        try expectEqual(CMSampleBufferGetTotalSampleSize(rewrapped), 480 * 4)
    }

    r.test("shifting an audio buffer keeps the per-sample duration and moves the start") {
        // 480 frames at 24 kHz = 20 ms, like a Bluetooth headset microphone.
        let original = SyntheticMedia.audioSampleBuffer(startTime: t(10), frames: 480, sampleRate: 24_000)
        let shifted = SampleBufferTiming.shifted(original, toStartAt: t(10.5))!
        try expectEqual(CMSampleBufferGetNumSamples(shifted), 480)
        try expectNear(CMSampleBufferGetPresentationTimeStamp(shifted).seconds, 10.5, tolerance: 0.0001)
        try expectNear(CMSampleBufferGetDuration(shifted).seconds, 0.02, tolerance: 0.0001, "total duration must stay 20 ms")
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(shifted, at: 7, timingInfoOut: &timing)
        try expectNear(timing.duration.seconds, 1.0 / 24_000, tolerance: 1e-9, "per-sample duration must stay one sample")
        try expectNear(timing.presentationTimeStamp.seconds, 10.5 + 7.0 / 24_000, tolerance: 1e-6)
    }

    r.test("shifting backwards and by zero works; invalid times are rejected") {
        let original = SyntheticMedia.audioSampleBuffer(startTime: t(5), frames: 240, sampleRate: 24_000)
        let back = SampleBufferTiming.shifted(original, toStartAt: t(1))!
        try expectNear(CMSampleBufferGetPresentationTimeStamp(back).seconds, 1, tolerance: 0.0001)
        try expectNear(CMSampleBufferGetDuration(back).seconds, 0.01, tolerance: 0.0001)
        let same = SampleBufferTiming.shifted(original, toStartAt: t(5))!
        try expectNear(CMSampleBufferGetPresentationTimeStamp(same).seconds, 5, tolerance: 0.0001)
        try expect(SampleBufferTiming.shifted(original, toStartAt: .invalid) == nil)
    }
}
