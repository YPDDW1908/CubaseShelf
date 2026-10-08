import AVFoundation
import AudioToolbox

// Resolve the actual declared order; never infer LFE from a six-channel count.
enum LoudnessChannelLayout {
    static func weights(channels: Int, layout: AVAudioChannelLayout?) -> [Double]? {
        guard let layout else { return channels == 1 || channels == 2 ? Array(repeating:1,count:channels) : nil }
        let pointer = layout.layout
        let tag = pointer.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_Mono, channels == 1 { return [1] }
        if tag == kAudioChannelLayoutTag_Stereo, channels == 2 { return [1,1] }
        func labels(_ p: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel]? {
            guard Int(p.pointee.mNumberChannelDescriptions) == channels, channels <= 8 else { return nil }
            let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            let descriptions = UnsafeRawPointer(p).advanced(by:offset).assumingMemoryBound(to:AudioChannelDescription.self)
            return (0..<channels).map { descriptions[$0].mChannelLabel }
        }
        var names: [AudioChannelLabel]?
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions { names = labels(pointer) }
        else {
            var specifier = tag == kAudioChannelLayoutTag_UseChannelBitmap ? pointer.pointee.mChannelBitmap.rawValue : tag
            let property = tag == kAudioChannelLayoutTag_UseChannelBitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(property,4,&specifier,&size) == noErr,
                  size >= MemoryLayout<AudioChannelLayout>.size, size < 16384 else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount:Int(size),alignment:MemoryLayout<AudioChannelLayout>.alignment)
            defer { memory.deallocate() }
            guard AudioFormatGetProperty(property,4,&specifier,&size,memory) == noErr else { return nil }
            names = labels(UnsafePointer(memory.assumingMemoryBound(to:AudioChannelLayout.self)))
        }
        guard let names else { return nil }
        if channels == 1, names == [kAudioChannelLabel_Mono] || names == [kAudioChannelLabel_Center] { return [1] }
        if channels == 2, Set(names) == Set([kAudioChannelLabel_Left,kAudioChannelLabel_Right]) { return [1,1] }
        guard channels == 6, Set(names).count == 6 else { return nil }
        let front: Set<AudioChannelLabel> = [kAudioChannelLabel_Left,kAudioChannelLabel_Right,kAudioChannelLabel_Center,kAudioChannelLabel_LFEScreen]
        let rear = Set(names).subtracting(front)
        let surroundPairs: [Set<AudioChannelLabel>] = [
            [kAudioChannelLabel_LeftSurround,kAudioChannelLabel_RightSurround],
            [kAudioChannelLabel_RearSurroundLeft,kAudioChannelLabel_RearSurroundRight],
            [kAudioChannelLabel_LeftSurroundDirect,kAudioChannelLabel_RightSurroundDirect]
        ]
        guard front.isSubset(of:Set(names)), surroundPairs.contains(rear) else { return nil }
        return names.map { $0 == kAudioChannelLabel_LFEScreen ? 0 : (rear.contains($0) ? 1.41 : 1) }
    }
}
