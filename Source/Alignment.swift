import Foundation
import AVFoundation

struct AlignmentPlan {
    let gainDB: Double
    let requestedGainDB: Double
    let expectedLUFS: Double
    let limited: Bool
    var multiplier: Float { Float(pow(10, gainDB / 20)) }
    static func make(_ measurement: LoudnessResult?, target: Double) -> AlignmentPlan? {
        guard let m = measurement, let loudness = m.integrated, let peak = m.truePeak,
              loudness.isFinite, peak.isFinite, target.isFinite, (-30 ... -8).contains(target) else { return nil }
        let requested = target - loudness
        // Static gain only. Reserve 0.3 dB beyond the -1 dBTP ceiling for meter
        // tolerance; never use limiting/compression to force a target.
        let gain = min(requested, 12, -1.3 - peak)
        return AlignmentPlan(gainDB: gain, requestedGainDB: requested, expectedLUFS: loudness + gain, limited: gain < requested - 0.05)
    }
}

enum AlignedAudioRenderer {
    static func render(_ url: URL, gain: Float) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CubaseShelf-preview-\(UUID()).caf")
        do {
            let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = input.processingFormat
            let output = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard gain.isFinite, gain >= 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
                throw NSError(domain: "CubaseShelf", code: 7, userInfo: [NSLocalizedDescriptionKey: "无法建立试听缓存。"])
            }
            var offset: Int64 = 0
            while offset < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(16384,input.length-offset)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                    throw NSError(domain: "CubaseShelf", code: 8, userInfo: [NSLocalizedDescriptionKey: "音频读取不完整。"])
                }
                for c in 0..<Int(format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) {
                        guard channels[c][i].isFinite else { throw NSError(domain: "CubaseShelf", code: 9, userInfo: [NSLocalizedDescriptionKey: "音频含无效采样，未生成对齐缓存。"]) }
                        channels[c][i] *= gain
                    }
                }
                try output.write(from: buffer); offset += Int64(buffer.frameLength)
            }
            try Task.checkCancellation()
            return destination
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
