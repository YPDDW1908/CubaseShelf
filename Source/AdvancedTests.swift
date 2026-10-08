import Foundation
import AVFoundation

enum AdvancedTests {
    @MainActor static func run(root: URL) async throws {
        let fm = FileManager.default
        let libraryRoot = root.appendingPathComponent("MoveTests")
        let source = libraryRoot.appendingPathComponent("Original")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("unique relocation fixture".utf8).write(to: source.appendingPathComponent("Song.cpr"))
        let original = ProjectScanner.scan(roots: [libraryRoot]).projects[0]
        Tests.expect(original.identity?.contentHashes.count == 1, "Migration stores CPR SHA256 identity")
        let duplicate = libraryRoot.appendingPathComponent("Copy")
        try fm.copyItem(at: source, to: duplicate)
        let copied = ProjectScanner.scan(roots: [libraryRoot]).projects
        Tests.expect(ProjectRelocation.matches(old: [original], fresh: copied).isEmpty, "Existing original prevents annotation theft by a copy")
        try fm.removeItem(at: duplicate)
        let moved = libraryRoot.appendingPathComponent("Renamed")
        try fm.moveItem(at: source, to: moved)
        try Data("edited after moving".utf8).write(to: moved.appendingPathComponent("Song.cpr"))
        let renamed = ProjectScanner.scan(roots: [libraryRoot]).projects[0]
        Tests.expect(ProjectRelocation.matches(old: [original], fresh: [renamed])[original.id] == renamed.id, "Same-volume rename preserves identity even after CPR edit")
        var note = Annotation(); note.favorite = true; note.notes = "移动后继续制作"; note.bpm = "100"
        note.externalAudio = [SavedLocation(path: original.id + "/Mixdown/manual.wav", bookmark: Data([1])), SavedLocation(path: "/Elsewhere/reference.wav", bookmark: Data([2]))]
        let shifted = ProjectRelocation.annotation(note, from: original.id, to: renamed.id)
        Tests.expect(shifted.externalAudio[0].path == renamed.id + "/Mixdown/manual.wav" && shifted.externalAudio[0].bookmark == nil, "Move remaps project-relative manual audio without stale bookmark")
        Tests.expect(shifted.externalAudio[1].path == note.externalAudio[1].path && shifted.notes == note.notes, "Move preserves outside references and notes")
        let db = root.appendingPathComponent("migration-db/library.json")
        var data = LibraryData(); data.locations = [SavedLocation(path: libraryRoot.path)]; data.projects = [original]; data.annotations[original.id] = note
        try LibraryPersistence.save(data, to: db)
        let store = LibraryStore(persistenceURL: db, observesSystem: false)
        try await Tests.settle(store)
        Tests.expect(store.annotation(renamed.id).notes == note.notes && store.annotation(renamed.id).favorite, "Store automatically migrates notes and favorite")
        Tests.expect(store.data.annotations[original.id] == nil, "Successful move removes stale annotation key")
        let savedFiles = try fm.contentsOfDirectory(atPath: db.deletingLastPathComponent().path)
        Tests.expect(savedFiles.contains { $0.hasPrefix("library-before-move-") }, "Migration makes a recovery copy before changing library")
        store.shutdown()
        let reopened = LibraryStore(persistenceURL: db, observesSystem: false)
        try await Tests.settle(reopened)
        Tests.expect(reopened.annotation(renamed.id).notes == note.notes, "Migrated annotations survive restart")
        // Moving outside indexed roots preserves a recoverable record across restart.
        let outside = root.appendingPathComponent("OutsideRoot")
        try fm.moveItem(at: moved, to: outside)
        reopened.refresh(); try await Tests.settle(reopened)
        Tests.expect(reopened.data.relocationHistory?.contains { $0.id == renamed.id } == true, "Missing annotated project retains relocation history")
        reopened.shutdown()
        let recovered = LibraryStore(persistenceURL: db, observesSystem: false)
        try await Tests.settle(recovered)
        recovered.addRoot(outside); try await Tests.settle(recovered)
        let outsideID = recovered.data.projects.first!.id
        Tests.expect(recovered.annotation(outsideID).notes == note.notes, "Adding new location recovers archived move after restart")
        recovered.shutdown()
        try fm.moveItem(at: outside, to: moved)
        var hashOnlyOld = original; hashOnlyOld.identity?.directoryKey = nil
        var hashOnlyNew = renamed; hashOnlyNew.identity = original.identity; hashOnlyNew.identity?.directoryKey = "different-volume"
        Tests.expect(ProjectRelocation.matches(old: [hashOnlyOld], fresh: [hashOnlyNew])[original.id] == renamed.id, "Cross-volume matching can use unique unchanged CPR contents")
        var another = hashOnlyNew; another.directory += "-other"
        Tests.expect(ProjectRelocation.matches(old: [hashOnlyOld], fresh: [hashOnlyNew,another]).isEmpty, "Ambiguous identical copies never migrate automatically")
        var inaccessible = hashOnlyOld; inaccessible.directory = root.appendingPathComponent("GoneDisk/Old").path
        Tests.expect(ProjectRelocation.matches(old: [inaccessible], fresh: [hashOnlyNew]).isEmpty, "Unavailable source volume cannot be mistaken for a cross-volume move")

        func tone(rate: Double = 48000, seconds: Double, channels: Int = 2, amplitude: (Double) -> Double, frequency: Double = 1000) -> LoudnessResult {
            let meter = LoudnessMeter(rate: rate, channels: channels)
            let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
            for channel in 0..<channels { pointers[channel] = .allocate(capacity: 4096) }
            defer { for channel in 0..<channels { pointers[channel].deallocate() }; pointers.deallocate() }
            var offset = 0; let total = Int(seconds*rate)
            while offset < total {
                let count = min(4096,total-offset)
                for i in 0..<count {
                    let t = Double(offset+i)/rate
                    let sample = Float(amplitude(t)*sin(2 * .pi * frequency*t))
                    for c in 0..<channels { pointers[c][i] = sample }
                }
                meter.consume(pointers,count: count); offset += count
            }
            return meter.finish()
        }
        let steady = tone(seconds: 5, amplitude: { _ in 0.1 })
        Tests.expect(abs((steady.integrated ?? 0) - (-20)) < 0.15, "Stereo 1 kHz -20 dBFS peak measures approximately -20 LUFS")
        Tests.expect(abs((steady.samplePeak ?? 0) + 20) < 0.01 && abs((steady.truePeak ?? 0) + 20) < 0.2, "Calibrated sine sample and true peaks agree within tolerance")
        let mono = tone(seconds: 2, channels: 1, amplitude: { _ in 0.1 })
        Tests.expect(abs((mono.integrated ?? 0) - (-23.01)) < 0.15, "Mono loudness excludes stereo channel gain")
        let alternate = tone(rate: 44100, seconds: 2, amplitude: { _ in 0.1 })
        Tests.expect(abs((alternate.integrated ?? 0) - (-20)) < 0.15, "K weighting supports 44.1 kHz")
        let silence = tone(seconds: 1, amplitude: { _ in 0 })
        Tests.expect(silence.integrated == nil && silence.truePeak == nil && silence.range == nil, "Silence yields no bogus numeric loudness")
        let short = tone(seconds: 0.2, amplitude: { _ in 0.1 })
        Tests.expect(short.integrated == nil && short.range == nil, "Short audio does not fabricate integrated loudness or LRA")
        let surround = tone(seconds: 0.5, channels: 6, amplitude: { _ in 0.1 })
        Tests.expect(surround.integrated == nil, "Unknown surround layout does not report incorrectly weighted LUFS")
        let gated = tone(seconds: 10, amplitude: { $0 < 5 ? 0.1 : 0 })
        Tests.expect(abs((gated.integrated ?? 0)-(steady.integrated ?? 0)) < 0.2, "Absolute and relative gates reject trailing silence")
        let range = tone(seconds: 40, amplitude: { $0 < 20 ? 0.1 : pow(10,-30.0/20) })
        Tests.expect(abs((range.range ?? 0)-10) < 1, "EBU synthetic 20s -20/-30 dBFS two-tone LRA is 10 plus/minus 1 LU")
        // 12 kHz sine phase pi/4: sample peaks under-report reconstructed peaks.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(2 * .pi * 12000 * Double(i)/48000 + .pi/4)) }
        let intersample = LoudnessMeter(rate: 48000, channels: 1); intersample.consume(buffer.floatChannelData!,count:4800)
        let peak = intersample.finish()
        Tests.expect((peak.truePeak ?? -100) > (peak.samplePeak ?? 0)+2, "True-peak FIR detects intersample overshoot")

        func be(_ n: UInt64, count: Int) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: n >> ($0*8)) }) }
        var cpr = Data("RIF2 Version 15.0.30\0MTempoTrackEvent\0".utf8)
        cpr += be(3,count:2); cpr += be(60,count:8); cpr += be(2,count:4)
        for bpm in [100.0,98.0] {
            cpr += be(UInt64(Float(60/bpm).bitPattern),count:4); cpr += be(0,count:8); cpr += be(0,count:8); cpr += be(0,count:2)
        }
        cpr += Data(repeating:0,count:30)
        let info = CPRMetadataReader.parse(cpr)
        Tests.expect(abs((info.tempos.first ?? 0)-100) < 0.001 && info.tempos.count == 2, "Bounded tempo event decoding recognizes 100 BPM and changes")
        Tests.expect(info.applicationVersion == "15.0.30", "CPR header version is recognized")
        Tests.expect(CPRMetadataReader.parse(Data("RIF2 plugin Tempo=120 BPM=85".utf8)).tempos.isEmpty, "Plugin preset text is never used as project BPM")
        Tests.expect(CPRMetadataReader.parse(cpr.prefix(45)).tempos.isEmpty, "Truncated CPR yields unknown tempo without unsafe reads")
        Tests.expect(CPRMetadataReader.parse(Data("bad".utf8)).message != nil, "Unsupported CPR headers return explicit status")
    }
}
