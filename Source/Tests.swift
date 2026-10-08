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
        let explicitExcluded = ProjectScanner.scan(roots: [root, main.deletingLastPathComponent().appendingPathComponent("Audio")])
        expect(explicitExcluded.projects.contains { $0.name == "Audio" }, "Explicit excluded child root remains scannable alongside its parent")
        let aliasRoot = root.appendingPathComponent("SelectedAlias")
        try fm.createSymbolicLink(at: aliasRoot, withDestinationURL: main.deletingLastPathComponent())
        let explicitAlias = ProjectScanner.scan(roots: [root, aliasRoot])
        expect(explicitAlias.projects.count == result.projects.count, "Explicit symlink root does not duplicate indexed projects")
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

        // Iteration scores derive only from unique BAK files, never legacy manual stars.
        for (count, expected) in [(0,0),(1,1),(4,1),(5,2),(9,2),(10,3),(19,3),(20,4),(49,4),(50,5),(80,5)] {
            var rated = project
            rated.backups = (0..<count).map { FileEntry(path: "/Fixture/Auto Saves/take-\($0).bak", modified: .distantPast) }
            expect(rated.iterationRating == expected, "Automatic rating boundary \(count) backups = \(expected) stars")
        }
        var duplicate = project
        duplicate.backups = [FileEntry(path: "/Fixture/take.BAK", modified: .distantPast), FileEntry(path: "/Fixture/take.BAK", modified: .distantPast), FileEntry(path: "/Fixture/take.cpr", modified: .distantPast)]
        expect(duplicate.iterationBackupCount == 1, "Rating counts unique case-insensitive BAK entries only")
        expect(project.iterationRating == 1 && annotation.rating == 4, "Legacy manual stars do not change automatic rating")

        _ = try file("ExportChecks/One/One.cpr")
        _ = try file("ExportChecks/Two/Two.cpr")
        _ = try file("ExportChecks/One/Mixdown/任意命名试听.mp3")
        _ = try file("ExportChecks/One/Mixdown/Revision/不同名字.WAV")
        _ = try file("ExportChecks/Two/mIxDoWn/另一首歌.flac")
        let exportRoot = root.appendingPathComponent("ExportChecks")
        let exportScan = ProjectScanner.scan(roots: [exportRoot])
        expect(exportScan.projects.first { $0.name == "One" }?.bounces.count == 2, "Each project's Mixdown includes arbitrary names and nested mixes")
        expect(exportScan.projects.first { $0.name == "Two" }?.bounces.map(\.name) == ["另一首歌.flac"], "Case-insensitive Mixdown stays scoped to its own project")
        _ = try file("ExportChecks/Two/mIxDoWn/新导出的试听.mp3", age: 500)
        let exportRefresh = ProjectScanner.scan(roots: [exportRoot])
        expect(exportRefresh.projects.first { $0.name == "Two" }?.bounces.first?.name == "新导出的试听.mp3", "Refresh discovers newly exported mix and sorts newest first")

        // v0.1 data has none of the new optional availability/settings keys.
        library.schemaVersion = 1
        let legacy = try JSONEncoder().encode(library)
        let migrated = try JSONDecoder().decode(LibraryData.self, from: legacy)
        expect(migrated.automaticRefresh == nil && migrated.projects.allSatisfy { $0.availability == nil }, "v0.1 library loads with online projects and default automatic refresh")
        expect(LibraryIndex.contains("/Volumes/Disk/Song", in: "/Volumes/Disk"), "Location includes descendants")
        expect(!LibraryIndex.contains("/Volumes/Disk2/Song", in: "/Volumes/Disk"), "Location prefix does not include sibling drive")
        expect(LibraryIndex.contains("/tmp/Project", in: "/"), "Root-directory containment handles slash boundary")

        let driveProject = try file("DriveA/Project/Project.cpr")
        _ = try file("DriveA/Project/Mixdown/Project.wav")
        let drive = root.appendingPathComponent("DriveA")
        let parked = root.appendingPathComponent(".DriveA-detached")
        let initialScan = ProjectScanner.scan(roots: [drive])
        let indexed = LibraryIndex.merge(cached: [], result: initialScan, roots: [drive.path])
        expect(indexed.count == 1 && !indexed[0].isOffline, "First successful scan creates online index")
        try fm.moveItem(at: drive, to: parked)
        let disconnected = ProjectScanner.scan(roots: [drive])
        expect(disconnected.unavailableRoots == [drive.path], "Disconnected location is recorded explicitly")
        let offline = LibraryIndex.merge(cached: indexed, result: disconnected, roots: [drive.path])
        expect(offline.count == 1 && offline[0].isOffline, "Disconnected drive retains cached project as offline")
        expect(offline[0].bounces == indexed[0].bounces && offline[0].versions == indexed[0].versions, "Offline cache keeps versions and preview metadata")
        expect(LibraryIndex.merge(cached: offline, result: disconnected, roots: []).isEmpty, "Removing a location removes its offline index")
        try fm.moveItem(at: parked, to: drive)
        _ = try file("DriveA/Project/Project-02.cpr", age: 120)
        let reconnected = ProjectScanner.scan(roots: [drive])
        let recovered = LibraryIndex.merge(cached: offline, result: reconnected, roots: [drive.path])
        expect(recovered.count == 1 && !recovered[0].isOffline && recovered[0].versions.count == 2, "Reconnect replaces offline cache with current versions")
        try fm.removeItem(at: driveProject)
        try fm.removeItem(at: driveProject.deletingLastPathComponent().appendingPathComponent("Project-02.cpr"))
        let deleted = LibraryIndex.merge(cached: recovered, result: ProjectScanner.scan(roots: [drive]), roots: [drive.path])
        expect(deleted.isEmpty, "Deleted CPRs on a readable drive do not become permanent offline entries")

        var partialProject = project
        partialProject.bounces = []
        let mixdown = URL(fileURLWithPath: project.directory).appendingPathComponent("Mixdown").path
        let partial = ScanResult(projects: [partialProject], warnings: ["test read failure"], unavailablePaths: [mixdown])
        let partialIndex = LibraryIndex.merge(cached: [project], result: partial, roots: [root.path])
        expect(partialIndex[0].availability == .partial, "Unreadable export subtree marks project as partial")
        expect(partialIndex[0].bounces.count == 2, "Only inaccessible audio metadata retained; deleted accessible files removed")
        let failedCPR = ScanResult(projects: [], warnings: [], unavailablePaths: [project.versions[0].path])
        expect(LibraryIndex.merge(cached: [project], result: failedCPR, roots: [root.path]).first?.availability == .partial, "Unreadable CPR file retains project instead of removing it")

        expect(LibraryChange.isRelevant(path: "/Sessions/Work/Song.cpr", root: "/Sessions", directory: false), "CPR saves trigger automatic refresh")
        expect(LibraryChange.isRelevant(path: "/Sessions/Work/Mixdown/Song.mp3", root: "/Sessions", directory: false), "New exported mixes trigger automatic refresh")
        expect(!LibraryChange.isRelevant(path: "/Sessions/Work/Audio/recording.wav", root: "/Sessions", directory: false), "Recording writes do not trigger scan storms")
        expect(!LibraryChange.isRelevant(path: "/Sessions/.build/cache", root: "/Sessions", directory: true), "Hidden build folders ignored by change filter")
        expect(!LibraryChange.isRelevant(path: "/Sessions/library.json", root: "/Sessions", directory: false), "Library save does not trigger a refresh loop")
        expect(LibraryChange.isRelevant(path: "/Sessions/New Project", root: "/Sessions", directory: true), "New project folders trigger scanning")
        expect(LibraryChange.isRelevant(path: "/Sessions", root: "/Sessions", directory: true, mustRescan: true), "Root-change and dropped-event notifications trigger full rescan")

        _ = try file("StoreA/A/A.cpr")
        _ = try file("StoreB/B/B.cpr")
        for index in 0..<10 { _ = try file("StoreB/B/Auto Saves/iteration-\(index).bak") }
        var storeFixture = LibraryData()
        let a = root.appendingPathComponent("StoreA")
        let b = root.appendingPathComponent("StoreB")
        let aID = ProjectScanner.scan(roots: [a]).projects[0].id
        storeFixture.locations = [SavedLocation(path: a.path), SavedLocation(path: b.path)]
        var aNote = Annotation(); aNote.favorite = true; aNote.stage = .mixing; aNote.notes = "保留这段备注"; aNote.rating = 5
        storeFixture.annotations[aID] = aNote
        let storeURL = root.appendingPathComponent("store/library.json")
        try LibraryPersistence.save(storeFixture, to: storeURL)
        try await checkStore(url: storeURL, a: a, b: b)
        try await AdvancedTests.run(root: root)
        try await AlignmentTests.run(root: root)
        try EnhancementTests.run(root:root)
        // Optional smoke test: supply a private fixture locally. No real project or audio
        // is included in the repository or required for the default test suite.
        if let rootPath = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
            let realRoot = URL(fileURLWithPath: rootPath)
            let real = ProjectScanner.scan(roots: [realRoot])
            expect(!real.projects.isEmpty, "Real fixture: at least one CPR project found")
            expect(real.warnings.isEmpty, "Real fixture: no unreadable folders")
            for actual in real.projects {
                expect(!actual.versions.isEmpty, "Real fixture: project has a CPR version")
                if CommandLine.arguments.contains("--expect-bpm100") {
                    expect(actual.metadata?.sampleRate == 48000 && actual.metadata?.bitDepth == 24 && actual.metadata?.signatures?.first?.text == "4/4", "Real CPR audio attributes/signature agree with user-recalled 48 kHz, 24 bit, 4/4")
                    expect(abs((actual.metadata?.tempos.first ?? 0)-100) < 0.001, "Real CPR initial BPM agrees with user-confirmed 100")
                    expect(!(actual.metadata?.channelNames.isEmpty ?? true) && !(actual.metadata?.pluginNames.isEmpty ?? true), "Real CPR exposes channel and plugin names")
                }
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

    @MainActor static func settle(_ store: LibraryStore) async throws {
        let deadline = Date().addingTimeInterval(10)
        while store.scanning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        expect(!store.scanning, "Store scan completes")
    }

    @MainActor static func checkStore(url: URL, a: URL, b: URL) async throws {
        let fm = FileManager.default
        let aID = ProjectScanner.scan(roots: [a]).projects[0].id
        let store = LibraryStore(persistenceURL: url, observesSystem: false)
        try await settle(store)
        expect(store.data.projects.count == 2, "Store indexes two locations")
        store.sort = "迭代评分"
        expect(store.visibleProjects.first?.name == "B", "Rating sort uses backup count rather than legacy manual rating")
        expect(store.visibleProjects.count == 2, "Repeated list reads retain all projects")
        store.filter = "收藏"
        expect(store.visibleProjects.map(\.id) == [aID], "Favorite filter warms list cache")
        store.update(aID) { $0.favorite = false }
        expect(store.visibleProjects.isEmpty, "Annotation edits immediately invalidate cached favorite list")
        store.update(aID) { $0.favorite = true }
        store.filter = "全部工程"; store.query = "cache-search-token"
        expect(store.visibleProjects.isEmpty, "Unmatched search warms empty cache")
        store.update(aID) { $0.notes += " cache-search-token" }
        expect(store.visibleProjects.map(\.id) == [aID], "Note edits immediately invalidate cached search")
        store.update(aID) { $0.notes = "保留这段备注" }
        store.query = ""; store.sort = "名称"
        expect(store.visibleProjects.first?.id == aID, "Sort changes invalidate cached order")
        store.sort = "迭代评分"
        store.selectedLocation = a.path
        expect(store.visibleProjects.map(\.id) == [aID], "Location filter scopes visible projects")
        store.filter = "收藏"
        expect(store.visibleProjects.count == 1, "Location and favorite filters compose")
        store.query = "no match"
        expect(store.visibleProjects.isEmpty, "Search also composes with location and favorite")
        store.query = ""; store.selectedLocation = b.path; store.reconcileSelection()
        expect(store.visibleProjects.isEmpty && store.selectedID == nil, "Filter excludes out-of-location selection")
        store.selectedLocation = nil; store.filter = "全部工程"
        let parked = a.deletingLastPathComponent().appendingPathComponent(".StoreA-detached")
        try fm.moveItem(at: a, to: parked)
        store.refresh(); try await settle(store)
        expect(store.data.projects.first(where: { $0.id == aID })?.isOffline == true, "Store preserves disconnected project")
        expect(store.annotation(aID).notes == "保留这段备注" && store.annotation(aID).rating == 5, "Offline scan preserves notes and rating")
        store.filter = "离线工程"
        expect(store.visibleProjects.map(\.id) == [aID], "Offline filter shows only unavailable project")
        store.update(aID) { $0.notes = "离线时更新的备注" }
        store.setAutomaticRefresh(false)
        let lastScan = store.lastScan
        store.requestAutomaticRefresh()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        expect(store.lastScan == lastScan, "Automatic refresh toggle prevents queued refresh")
        store.shutdown()
        let restored = LibraryStore(persistenceURL: url, observesSystem: false)
        try await settle(restored)
        expect(!restored.automaticRefresh, "Automatic refresh preference survives restart")
        expect(restored.data.projects.first(where: { $0.id == aID })?.isOffline == true, "Offline index survives restart")
        expect(restored.annotation(aID).notes == "离线时更新的备注", "Offline edits survive restart")
        try fm.moveItem(at: parked, to: a)
        restored.refresh(); try await settle(restored)
        expect(restored.data.projects.first(where: { $0.id == aID })?.isOffline == false, "Manual scan recovers reconnected drive while auto refresh is off")
        expect(restored.annotation(aID).favorite && restored.annotation(aID).notes == "离线时更新的备注", "Reconnect keeps edited annotations")
        restored.refresh(); restored.removeRoot(a.path)
        try await settle(restored)
        expect(restored.data.projects.count == 1 && LibraryIndex.contains(restored.data.projects[0].directory, in: b.path), "Removing a location during an in-flight scan cannot restore stale results")
        expect(fm.fileExists(atPath: a.appendingPathComponent("A/A.cpr").path), "Removing a library location never deletes project files")
        restored.addRoot(b.appendingPathComponent("B"))
        try await settle(restored)
        restored.removeRoot(b.path)
        try await settle(restored)
        expect(restored.data.projects.count == 1, "Overlapping child root retains project when parent location removed")
        restored.shutdown()
    }
}
