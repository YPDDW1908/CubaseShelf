import Foundation
import AVFoundation

enum EnhancementTests {
    static func run(root: URL) throws {
        func be(_ n: UInt64, _ count: Int = 8) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded:n >> ($0*8)) }) }
        func field(_ key: String, _ type: UInt64, _ bits: UInt64) -> Data {
            be(UInt64(key.utf8.count+1),4) + Data((key+"\0").utf8) + be(type,2) + be(bits)
        }
        func attribute(_ name: String, _ type: UInt64, _ value: UInt64) -> Data {
            Data("StMedia::PStringIDMediaAttribute\0".utf8) + Data(repeating:0,count:16) + Data("ID\0\0\u{8}".utf8) + be(UInt64(name.utf8.count+1),4) + Data((name+"\0").utf8) + field("Type",1,type) + field("Flags",1,2) + field(type == 4 ? "Float" : "Long",type,value)
        }
        func signature(_ n: UInt64, _ d: UInt64, _ bar: UInt64) -> Data {
            Data("MTimeSignatureEvent\0".utf8) + Data(repeating:0,count:14) + field("Flags",1,8) + field("Start",4,Double(bar*1920).bitPattern) + field("Length",4,Double(1).bitPattern) + field("Bar",1,bar) + field("Numerator",1,n) + field("Denominator",1,d)
        }
        func track(_ bytes: Data) -> Data { Data("MSignatureTrackEvent\0".utf8) + be(3,2) + be(UInt64(bytes.count)) + bytes }
        let attr = attribute("AudioSampleRate",4,Double(48000).bitPattern) + attribute("AudioSampleSize",1,24)
        let data = Data("RIF2".utf8) + attr + track(signature(4,4,0)+signature(3,4,8))
        let info = CPRMetadataReader.parse(data)
        Tests.expect(info.sampleRate == 48000 && info.bitDepth == 24, "Typed CPR audio attributes decode 48 kHz / 24 bit")
        Tests.expect(info.signatures?.map(\.text) == ["4/4","3/4"] && info.signatures?.last?.bar == 8, "Signature changes preserve zero-based bar positions")
        let conflict = CPRMetadataReader.parse(data + attribute("AudioSampleRate",4,Double(44100).bitPattern))
        Tests.expect(conflict.sampleRate == nil && conflict.bitDepth == 24, "Conflicting CPR sample rates stay unknown instead of picking first")
        Tests.expect(CPRMetadataReader.parse(Data("RIF2 <SampleRate>96000</SampleRate> Numerator=7".utf8)).sampleRate == nil, "Preset text cannot masquerade as typed audio attributes")
        Tests.expect(CPRMetadataReader.parse(Data("RIF2".utf8)+signature(7,8,0)).signatures == nil, "Time signatures outside signature-track boundary are ignored")
        Tests.expect(CPRMetadataReader.parse(Data("RIF2".utf8)+track(signature(4,3,0))).signatures == nil, "Invalid signature denominator is rejected")
        Tests.expect(CPRMetadataReader.parse(Data("RIF2".utf8)+track(signature(4,4,0)+signature(7,8,0))).signatures == nil, "Conflicting signature variations are not silently combined")
        for end in stride(from:4,to:data.count,by:7) { _ = CPRMetadataReader.parse(Data(data.prefix(end))) }
        Tests.expect(true, "Truncated attribute/signature structures remain bounded")
        let old = Data("{\"tempos\":[],\"channelNames\":[],\"pluginNames\":[]}".utf8)
        let legacy = try JSONDecoder().decode(ProjectMetadata.self,from:old)
        Tests.expect(legacy.parserRevision == nil && legacy.sampleRate == nil, "Legacy metadata loads and requests parser cache upgrade")

        let orderA = LoudnessChannelLayout.weights(channels:6,layout:AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_MPEG_5_1_A))
        let orderB = LoudnessChannelLayout.weights(channels:6,layout:AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_MPEG_5_1_B))
        Tests.expect(orderA == [1,1,1,0,1.41,1.41] && orderB == [1,1,1.41,1.41,1,0], "5.1 layouts locate LFE and surround weights by declared order")
        Tests.expect(LoudnessChannelLayout.weights(channels:6,layout:nil) == nil, "Six channels without speaker labels remain unsupported")
        Tests.expect(LoudnessChannelLayout.weights(channels:2,layout:AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_MidSide)) == nil, "Mid/side is not silently interpreted as stereo L/R")
        func tone(channels: Int, active: Int, weights: [Double]?, block: Int = 4096, invalid: Bool = false) -> LoudnessResult {
            let meter = LoudnessMeter(rate:48000,channels:channels,weights:weights)
            let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity:channels)
            for c in 0..<channels { pointers[c] = .allocate(capacity:block) }
            defer { for c in 0..<channels { pointers[c].deallocate() }; pointers.deallocate() }
            var offset = 0
            while offset < 161760 {
                let n = min(block,161760-offset)
                for c in 0..<channels { for i in 0..<n { pointers[c][i] = c == active ? Float(0.1*sin(2 * .pi * 1000 * Double(offset+i)/48000)) : 0 } }
                if invalid && offset == 0 { pointers[active][0] = .nan }
                meter.consume(pointers,count:n); offset += n
            }
            let first = meter.finish(), second = meter.finish()
            Tests.expect(first.range == second.range && first.truePeak == second.truePeak, "Repeated finish returns the same measurement")
            return first
        }
        let mono = tone(channels:1,active:0,weights:nil)
        let center = tone(channels:6,active:2,weights:orderA)
        let rear = tone(channels:6,active:4,weights:orderA)
        let lfe = tone(channels:6,active:3,weights:orderA)
        Tests.expect(abs(mono.integrated! - center.integrated!) < 0.001, "Center-only 5.1 has the same loudness as mono")
        Tests.expect(abs(rear.integrated! - mono.integrated! - 10*log10(1.41)) < 0.001, "Surround energy uses the BS.1770 1.41 weight")
        Tests.expect(lfe.integrated == nil && lfe.truePeak != nil, "LFE contributes to peak measurement but not integrated loudness")
        let split = tone(channels:1,active:0,weights:nil,block:997)
        Tests.expect(abs(split.integrated! - mono.integrated!) < 1e-9 && abs(split.range! - mono.range!) < 1e-9 && abs(split.truePeak! - mono.truePeak!) < 1e-9, "Partial file tail and arbitrary decoder block sizes give invariant analysis")
        Tests.expect(mono.momentaryMax != nil && mono.shortTermMax != nil, "Maximum momentary and short-term loudness are available")
        let invalid = tone(channels:1,active:0,weights:nil,invalid:true)
        Tests.expect(invalid.invalidSamples == 1 && invalid.integrated == nil && invalid.truePeak == nil && AlignmentPlan.make(invalid,target:-18) == nil, "Nonfinite PCM is flagged and cannot produce alignment gain")

        let layout = AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_MPEG_5_1_B)!
        let format = AVAudioFormat(standardFormatWithSampleRate:48000,channelLayout:layout)
        let fileURL = root.appendingPathComponent("surround-source.caf")
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength = 48000
        for c in 0..<6 { for i in 0..<48000 {
            buffer.floatChannelData![c][i] = Float(0.01*Double(c+1)*sin(2 * .pi * 1000 * Double(i)/48000))
        } }
        do {
            let output = try AVAudioFile(forWriting:fileURL,settings:format.settings,commonFormat:.pcmFormatFloat32,interleaved:false)
            try output.write(from:buffer)
        }
        let sourceBytes = try Data(contentsOf:fileURL)
        let measured = try WaveformReader.read(fileURL)
        let rendered = try AlignedAudioRenderer.render(fileURL,gain:2)
        defer { try? FileManager.default.removeItem(at:rendered) }
        let aligned = try WaveformReader.read(rendered)
        Tests.expect(measured.loudness?.layoutSupported == true && aligned.loudness?.layoutSupported == true && aligned.channels == 6, "5.1 CAF rendering retains recognized multichannel layout")
        Tests.expect(abs(aligned.loudness!.integrated! - measured.loudness!.integrated! - 20*log10(2)) < 0.001, "5.1 aligned preview has the intended measured gain")
        let reread = try AVAudioFile(forReading:rendered,commonFormat:.pcmFormatFloat32,interleaved:false)
        let readBuffer = AVAudioPCMBuffer(pcmFormat:reread.processingFormat,frameCapacity:128)!
        try reread.read(into:readBuffer,frameCount:128)
        Tests.expect((0..<6).allSatisfy { abs(readBuffer.floatChannelData![$0][12] - buffer.floatChannelData![$0][12]*2) < 0.000001 }, "Rendering preserves every declared channel position")
        let unchanged = try Data(contentsOf:fileURL)
        Tests.expect(unchanged == sourceBytes, "5.1 analysis and rendering leave original audio unchanged")
    }
}
