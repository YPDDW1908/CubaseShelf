import Foundation
import AVFoundation

enum AlignmentTests {
    @MainActor static func run(root: URL) async throws {
        func measurement(_ lufs: Double, _ peak: Double) -> LoudnessResult { LoudnessResult(integrated:lufs,range:4,truePeak:peak,samplePeak:peak-0.1) }
        let attenuation = AlignmentPlan.make(measurement(-10,-0.5),target:-18)!
        Tests.expect(attenuation.gainDB == -8 && !attenuation.limited, "Alignment attenuates a louder master to target")
        let boost = AlignmentPlan.make(measurement(-25,-12),target:-18)!
        Tests.expect(boost.gainDB == 7 && !boost.limited, "Alignment supports positive gain when headroom allows")
        let protected = AlignmentPlan.make(measurement(-26,-0.5),target:-18)!
        Tests.expect(abs(protected.gainDB + 0.8) < 0.001 && protected.limited, "True-peak headroom overrides loudness target without limiting dynamics")
        Tests.expect(AlignmentPlan.make(measurement(-50,-40),target:-18)?.gainDB == 12, "Quiet material has a 12 dB boost cap")
        Tests.expect(AlignmentPlan.make(nil,target:-18) == nil && AlignmentPlan.make(measurement(.nan,0),target:-18) == nil, "Missing and nonfinite measurements cannot enable normalization")
        Tests.expect(AlignmentPlan.make(measurement(-18,-2),target:0) == nil, "Invalid target is rejected")

        let url = root.appendingPathComponent("alignment-source.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        do {
            let writer = try AVAudioFile(forWriting:url,settings:format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:240000)!
            buffer.frameLength = 240000
            for i in 0..<240000 { for c in 0..<2 { buffer.floatChannelData![c][i] = Float(0.1*sin(2 * .pi * 1000 * Double(i)/48000)) } }
            try writer.write(from:buffer)
        }
        let original = try Data(contentsOf:url)
        let summary = try WaveformReader.read(url)
        let plan = AlignmentPlan.make(summary.loudness,target:-18)!
        let rendered = try AlignedAudioRenderer.render(url,gain:plan.multiplier)
        defer { try? FileManager.default.removeItem(at:rendered) }
        let result = try WaveformReader.read(rendered)
        Tests.expect(abs((result.loudness?.integrated ?? 0)+18)<0.05, "Rendered positive-gain preview measures at target LUFS")
        Tests.expect(result.duration == summary.duration && result.channels == summary.channels, "Alignment preserves duration and channel count")
        let unchanged = try Data(contentsOf:url)
        Tests.expect(unchanged == original, "Alignment never modifies source bytes")
        let task = Task.detached { try Task.checkCancellation(); return try AlignedAudioRenderer.render(url,gain:1) }
        task.cancel()
        do { let unexpected = try await task.value; try? FileManager.default.removeItem(at:unexpected); Tests.expect(false,"Cancelled render must throw") }
        catch { Tests.expect(error is CancellationError,"Cancelled render exits with cancellation") }

        let entry = ProjectScanner.entry(url)!
        let project = Project(directory:root.path,versions:[],backups:[],bounces:[entry])
        let player = PreviewPlayer(); player.normalizationEnabled = true
        player.load(entry,project:project); player.seek(1.25)
        for _ in 0..<1000 {
            if !player.loading && !player.waitingForAlignment { break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        Tests.expect(player.appliedGainDB != nil && !player.playing, "Paused selection stays paused after asynchronous alignment")
        Tests.expect(abs(player.time-1.25)<0.05, "Seek position survives alignment preparation")
        player.targetLUFS = -23; player.stop()
        for _ in 0..<1000 {
            if !player.waitingForAlignment { break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        Tests.expect(!player.playing && !player.wantsPlayback && player.time == 0, "Stop cancels queued playback while rendering")
        player.seek(2); player.normalizationEnabled = false
        Tests.expect(player.appliedGainDB == nil && !player.waitingForAlignment && abs(player.time-2)<0.05, "Disabling alignment restores original at current position")
        let oldSummary = player.summary?.loudness?.integrated
        let input = try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
        let replacement = AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:AVAudioFrameCount(input.length))!
        try input.read(into:replacement)
        for c in 0..<Int(input.processingFormat.channelCount) { for i in 0..<Int(replacement.frameLength) { replacement.floatChannelData![c][i] *= 0.5 } }
        do {
            let output = try AVAudioFile(forWriting:url,settings:input.processingFormat.settings,commonFormat:.pcmFormatFloat32,interleaved:false)
            try output.write(from:replacement)
        }
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(2)],ofItemAtPath:url.path)
        player.load(entry,project:project) // Deliberately reuse the old index entry.
        for _ in 0..<1000 {
            if !player.loading { break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        Tests.expect(abs((player.summary?.loudness?.integrated ?? 0) - (oldSummary ?? 0) + 20*log10(2)) < 0.01, "Reloading a changed audio file with a stale index entry invalidates analysis cache")
        player.shutdown()
    }
}
