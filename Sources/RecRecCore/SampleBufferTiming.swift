import CoreMedia

public enum SampleBufferTiming {
    /// Returns a copy of `sampleBuffer` whose timestamps are shifted so that it starts at `presentationTime`,
    /// preserving every per-sample duration. Passing a single timing entry whose duration is the buffer's
    /// *total* duration would instead declare that duration for each sample (a 20 ms audio buffer would claim
    /// 9.6 s), which makes AVAssetWriter starve the audio input while it waits for video to catch up.
    public static func shifted(_ sampleBuffer: CMSampleBuffer, toStartAt presentationTime: CMTime) -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard original.isValid, presentationTime.isValid else { return nil }
        let delta = CMTimeSubtract(presentationTime, original)

        var entryCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &entryCount) == noErr,
              entryCount > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: entryCount)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: entryCount, arrayToFill: &timings, entriesNeededOut: &entryCount) == noErr else {
            return nil
        }
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, delta)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, delta)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                                            sampleTimingEntryCount: entryCount, sampleTimingArray: &timings,
                                                            sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}
