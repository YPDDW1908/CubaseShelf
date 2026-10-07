import Foundation
import AVFoundation

@main struct Tests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        checks += 1; print("PASS: \(message)")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CubaseShelf-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func file(_ relative: String, age: TimeInterval = 0) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + age)], ofItemAtPath: url.path)
            return url
        }
        let main = try file("示例工程/示例工程.cpr")
        let newer = try file("示例工程/示例工程-02.CPR", age: 60)
        _ = try file("示例工程/Auto Saves/示例工程-01-(pad).bak")
        _ = try file("示例工程/示例工程.bak")
        _ = try file("示例工程/Mixdown/示例工程.mp3")
        _ = try file("示例工程/Mixdown/demo.wav")
        _ = try file("示例工程/示例工程-final.wav")
        _ = try file("示例工程/主参考.wav")
        _ = try file("示例工程/Audio/Drums.wav")
        _ = try file("示例工程/Edits/edit.wav")
        _ = try file("示例工程/Mixdown/Stems/Bass.wav")
        _ = try file("示例工程/Audio/NotAProject.cpr")
        _ = try file("Other/Other.cpr")
        _ = try file("Empty/stray.bak")
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try fm.createSymbolicLink(at: main.deletingLastPathComponent().appendingPathComponent("Alias.cpr"), withDestinationURL: main)
        let result = ProjectScanner.scan(roots: [root, main.deletingLastPathComponent()])
        expect(result.projects.count == 2, "Multiple roots deduplicate projects; .bak-only folder ignored")
        let project = result.projects.first { $0.name == "示例工程" }!
        expect(project.versions.count == 2, "Uppercase CPR accepted; symlinks and Audio skipped")
        expect(project.versions.first?.path == newer.path, "Newest project version sorted first")
        expect(project.backups.count == 2, "Root and Auto Saves backups counted without duplicate roots")
        expect(project.bounces.count == 3, "Mixdown and project-named root exports found; stems/recordings excluded")
        expect(!project.bounces.contains { $0.name == "主参考.wav" || $0.name == "Drums.wav" || $0.name == "Bass.wav" }, "Reference and stem audio not mistaken for mixes")
        let unavailable = ProjectScanner.scan(roots: [root.appendingPathComponent("missing")])
        expect(unavailable.projects.isEmpty && !unavailable.warnings.isEmpty, "Offline folders return explicit warning")
        expect(ProjectScanner.matchesProject("Song_v2", names: ["Song"]), "Root export version suffix accepted")
        expect(!ProjectScanner.matchesProject("Song Vocals", names: ["Song"]), "Root vocal stem rejected")
        var library = LibraryData()
        var annotation = Annotation()
        annotation.favorite = true; annotation.stage = .mixing; annotation.notes = "下次调整副歌 🎹"; annotation.rating = 4
        annotation.externalAudio = [SavedLocation(path: "/external/demo.mp3", bookmark: Data([1, 2, 3]))]
        library.annotations[project.id] = annotation
        library.projects = result.projects
        let saved = root.appendingPathComponent("db/library.json")
        try LibraryPersistence.save(library, to: saved)
        let restored = try LibraryPersistence.load(from: saved)
        expect(restored.annotations[project.id]?.notes == annotation.notes, "Unicode notes persist")
        expect(restored.annotations[project.id]?.stage == .mixing && restored.annotations[project.id]?.rating == 4, "Status and rating persist")
        expect(restored.annotations[project.id]?.externalAudio.first?.bookmark == Data([1, 2, 3]), "External audio bookmarks persist")
        expect(restored.projects.count == 2, "Project cache persists")
        try Data("broken".utf8).write(to: saved)
        do { _ = try LibraryPersistence.load(from: saved); fatalError("Corrupt JSON accepted") } catch { checks += 1; print("PASS: Corrupt library rejected") }
        library.schemaVersion = 99; try LibraryPersistence.save(library, to: saved)
        do { _ = try LibraryPersistence.load(from: saved); fatalError("Unknown schema accepted") } catch { checks += 1; print("PASS: Unknown schema rejected") }
        // Optional smoke test: supply a private fixture locally. No real project or audio
        // is included in the repository or required for the default test suite.
        if let rootPath = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
            let realRoot = URL(fileURLWithPath: rootPath)
            let real = ProjectScanner.scan(roots: [realRoot])
            expect(!real.projects.isEmpty, "Real fixture: at least one CPR project found")
            expect(real.warnings.isEmpty, "Real fixture: no unreadable folders")
            for actual in real.projects {
                expect(!actual.versions.isEmpty, "Real fixture: project has a CPR version")
                guard !CommandLine.arguments.contains("--filesystem-only"), let mix = actual.bounces.first else { continue }
                let summary = try WaveformReader.read(mix.url)
                expect(summary.peaks.count == 600, "Real audio: expected waveform bin count")
                expect(summary.duration > 0 && summary.channels > 0, "Real audio: valid duration and channels")
                let audio = try AVAudioPlayer(contentsOf: mix.url)
                expect(abs(audio.duration - summary.duration) < 1, "Playback and waveform durations agree")
                await MainActor.run {
                    let player = PreviewPlayer()
                    player.load(mix, project: actual)
                    let position = min(12, player.duration / 2)
                    player.seek(position)
                    if actual.bounces.count > 1 {
                        player.load(actual.bounces[1], project: actual)
                        expect(abs(player.time - min(position, player.duration)) < 0.1, "Switching mixes keeps absolute position")
                        expect(!player.playing, "Paused switch stays paused")
                    }
                    player.seek(100000)
                    expect(player.time <= player.duration, "Seeking clamps at audio duration")
                    player.stop()
                }
            }
        }
        print("ALL \(checks) CHECKS PASSED")
    }
}
