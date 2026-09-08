import CoreMedia

public enum AudioFormat {
    /// True when two LPCM descriptions describe byte-identical sample data, even if the descriptions differ.
    /// Capture pipelines are seen switching between "interleaved" and "non-interleaved" for mono streams
    /// (flags 9 vs 41), which changes the description but not a single byte.
    public static func haveIdenticalLayout(_ a: CMFormatDescription, _ b: CMFormatDescription) -> Bool {
        guard let x = CMAudioFormatDescriptionGetStreamBasicDescription(a)?.pointee,
              let y = CMAudioFormatDescriptionGetStreamBasicDescription(b)?.pointee else { return false }
        guard x.mFormatID == y.mFormatID, x.mSampleRate == y.mSampleRate, x.mChannelsPerFrame == y.mChannelsPerFrame,
              x.mBitsPerChannel == y.mBitsPerChannel, x.mBytesPerFrame == y.mBytesPerFrame,
              x.mBytesPerPacket == y.mBytesPerPacket, x.mFramesPerPacket == y.mFramesPerPacket else { return false }
        let ignorable: AudioFormatFlags = x.mChannelsPerFrame == 1 ? kAudioFormatFlagIsNonInterleaved : 0
        return (x.mFormatFlags & ~ignorable) == (y.mFormatFlags & ~ignorable)
    }

    /// The same samples and timing under a different (layout-identical) format description.
    public static func rewrapped(_ sampleBuffer: CMSampleBuffer, formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        guard let data = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var timingCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount) == noErr else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: &timingCount) == noErr else { return nil }
        var sizeCount: CMItemCount = 0
        guard CMSampleBufferGetSampleSizeArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount) == noErr else { return nil }
        var sizes = [Int](repeating: 0, count: sizeCount)
        guard CMSampleBufferGetSampleSizeArray(sampleBuffer, entryCount: sizeCount, arrayToFill: &sizes, entriesNeededOut: &sizeCount) == noErr else { return nil }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: formatDescription,
                                               sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
                                               sampleTimingEntryCount: timingCount, sampleTimingArray: &timings,
                                               sampleSizeEntryCount: sizeCount, sampleSizeArray: &sizes, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}
