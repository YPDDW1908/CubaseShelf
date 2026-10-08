import Foundation

@main struct PerformanceCheck {
    static func timed<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let start = Date()
        let value = try work()
        print(String(format: "%@: %.3f ms", name, Date().timeIntervalSince(start) * 1000))
        return value
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let sessions = root.appendingPathComponent("Sessions")
        if !fm.fileExists(atPath: sessions.path) {
            try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
            for i in 0..<1000 {
                let dir = sessions.appendingPathComponent("工程-\(i)")
                for folder in ["Auto Saves", "Mixdown", "Audio"] {
                    try fm.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
                }
                try Data(repeating: UInt8(i % 255), count: 4096).write(to: dir.appendingPathComponent("Song.cpr"))
                for j in 0..<20 { try Data().write(to: dir.appendingPathComponent("Auto Saves/\(j).bak")) }
                try Data().write(to: dir.appendingPathComponent("Mixdown/demo.wav"))
                try Data().write(to: dir.appendingPathComponent("Audio/ignored.cpr"))
            }
        }
        let cold = timed("scan 1000 uncached") { ProjectScanner.scan(roots: [sessions]) }
        precondition(cold.projects.count == 1000 && cold.warnings.isEmpty)
        precondition(cold.projects.allSatisfy { $0.backups.count == 20 && $0.bounces.count == 1 })
        let warm = timed("scan 1000 cached") { ProjectScanner.scan(roots: [sessions], cached: cold.projects) }
        precondition(cold.projects == warm.projects)
        let overlap = timed("scan overlapping roots") { ProjectScanner.scan(roots: [sessions, sessions.appendingPathComponent("工程-0"), sessions], cached: warm.projects) }
        precondition(overlap.projects == warm.projects)
        _ = timed("relocation unchanged 1000") { ProjectRelocation.matches(old: warm.projects, fresh: warm.projects) }
        let db = root.appendingPathComponent("bench-library.json")
        try? fm.removeItem(at: db)
        let store = LibraryStore(persistenceURL: db, observesSystem: false)
        while store.scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        store.data.projects = warm.projects
        timed("visible default x10") { for _ in 0..<10 { precondition(store.visibleProjects.count == 1000) } }
        store.sort = "迭代评分"
        timed("visible rating x10") { for _ in 0..<10 { precondition(store.visibleProjects.count == 1000) } }
        store.query = "demo"
        timed("visible search x10") { for _ in 0..<10 { precondition(store.visibleProjects.count == 1000) } }
        // Exercise in-memory lists beyond the on-disk fixture size.
        store.data.projects = (0..<5).flatMap { n in warm.projects.map { p -> Project in var q = p; q.directory += "-\(n)"; return q } }
        store.query = ""; store.sort = "迭代评分"
        timed("visible rating 5000 first") { precondition(store.visibleProjects.count == 5000) }
        timed("visible rating 5000 repeated x10") { for _ in 0..<10 { precondition(store.visibleProjects.count == 5000) } }
        store.data.projects = warm.projects
        store.query = ""; store.sort = "最近修改"
        store.data.locations = [SavedLocation(path: sessions.path)]
        let start = Date(); var previous = Date(); var maxGap = 0.0; var beats = 0
        store.refresh()
        for _ in 0..<100 { store.refresh() }
        while store.scanning {
            try await Task.sleep(nanoseconds: 10_000_000)
            let now = Date(); maxGap = max(maxGap, now.timeIntervalSince(previous)); previous = now; beats += 1
        }
        precondition(store.data.projects.count == 1000)
        print(String(format: "refresh storm 100 requests: %.3f ms; main-actor max gap %.3f ms; heartbeat %d", Date().timeIntervalSince(start)*1000, maxGap*1000, beats))
        // A new file during a scan must be observed by the queued follow-up scan.
        let added = sessions.appendingPathComponent("工程-0/Mixdown/new-export.wav")
        store.refresh()
        try Data().write(to: added)
        store.update(warm.projects[0].id) { $0.notes = "edited-during-scan" }
        store.refresh()
        while store.scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.data.projects.first { $0.name == "工程-0" }?.bounces.count == 2)
        precondition(store.annotation(warm.projects[0].id).notes == "edited-during-scan")
        try fm.removeItem(at: added)
        let parked = root.appendingPathComponent(".Sessions-offline")
        try fm.moveItem(at: sessions, to: parked)
        let disconnected = ProjectScanner.scan(roots: [sessions])
        let offline = timed("offline merge 1000") { LibraryIndex.merge(cached: warm.projects, result: disconnected, roots: [sessions.path]) }
        precondition(offline.count == 1000 && offline.allSatisfy { $0.isOffline })
        try fm.moveItem(at: parked, to: sessions)
        let recovered = LibraryIndex.merge(cached: offline, result: warm, roots: [sessions.path])
        precondition(recovered == warm.projects)
        // Synthetic identities: each source has one unique destination, all source paths absent.
        let oldMoves = (0..<1000).map { i -> Project in
            Project(directory: root.appendingPathComponent("missing-\(i)").path, versions: [], backups: [], bounces: [], identity: ProjectIdentity(directoryKey: "dir-\(i)", contentHashes: ["hash-\(i)"], versions: []))
        }
        let newMoves = oldMoves.enumerated().map { i, p -> Project in var q = p; q.directory = root.appendingPathComponent("new-\(i)").path; return q }
        let moves = timed("match 1000 moved projects") { ProjectRelocation.matches(old: oldMoves, fresh: newMoves) }
        precondition(moves.count == 1000)
        store.shutdown()
        let restored = try LibraryPersistence.load(from: db)
        precondition(restored.annotations[warm.projects[0].id]?.notes == "edited-during-scan")
        print("PASS: benchmark invariants")
    }
}
