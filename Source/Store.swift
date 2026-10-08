import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class LibraryStore: ObservableObject {
    @Published var data = LibraryData() { didSet { visibleCache = nil } }
    @Published var scanning = false
    @Published var warnings: [String] = []
    @Published var error: String?
    @Published var selectedID: String?
    @Published var filter = "全部工程" { didSet { visibleCache = nil } }
    @Published var query = "" { didSet { visibleCache = nil } }
    @Published var sort = "最近修改" { didSet { visibleCache = nil } }
    @Published var lastScan: Date?
    @Published var selectedLocation: String? { didSet { visibleCache = nil } }
    @Published var unavailableRoots = Set<String>()
    @Published var monitorHealthy = true
    let persistenceURL: URL
    private var visibleCache: [Project]?
    private var writeAllowed = true
    private var accessed: [String: URL] = [:]
    private var saveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var needsRescan = false
    private var rootRevision = UUID()
    private var unavailablePaths: [String] = []
    private let monitor = DirectoryMonitor()
    private var recoveryTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let observesSystem: Bool
    private var closed = false
    var automaticRefresh: Bool { data.automaticRefresh != false }

    init(persistenceURL explicitURL: URL? = nil, observesSystem: Bool = true) {
        self.observesSystem = observesSystem
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        persistenceURL = explicitURL ?? argument("--library-path").map { URL(fileURLWithPath: $0) }
            ?? (Bundle.main.object(forInfoDictionaryKey: "CubaseShelfLibraryPath") as? String).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CubaseShelf/library.json")
        do { data = try LibraryPersistence.load(from: persistenceURL) }
        catch { self.error = "读取资料库失败，已暂停保存以保护原文件：\(error.localizedDescription)"; writeAllowed = false }
        data.locations = data.locations.map { resolve($0) }
        for key in Array(data.annotations.keys) {
            data.annotations[key]?.externalAudio = (data.annotations[key]?.externalAudio ?? []).map { resolve($0) }
        }
        if let app = data.cubase { data.cubase = resolve(app) }
        if explicitURL == nil, let root = argument("--import-root") { addRoot(URL(fileURLWithPath: root), refresh: false) }
        if observesSystem { startObservation() }
        refresh()
    }

    func location(_ url: URL) -> SavedLocation {
        SavedLocation(path: url.standardizedFileURL.path, bookmark: try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
    }
    func resolve(_ location: SavedLocation) -> SavedLocation {
        guard let bookmark = location.bookmark else { return location }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { return location }
        if accessed[url.path] == nil, url.startAccessingSecurityScopedResource() { accessed[url.path] = url }
        return stale ? self.location(url) : SavedLocation(path: url.path, bookmark: bookmark)
    }
    func annotation(_ id: String) -> Annotation { data.annotations[id] ?? Annotation() }
    func update(_ id: String, _ change: (inout Annotation) -> Void) {
        var value = annotation(id); change(&value); data.annotations[id] = value
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }; self?.save()
        }
    }
    func save() {
        guard writeAllowed else { return }
        do { try LibraryPersistence.save(data, to: persistenceURL) }
        catch { self.error = "资料库保存失败：\(error.localizedDescription)" }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.message = "选择 Cubase 工程文件夹或包含多个工程的父文件夹"
        if panel.runModal() == .OK { for url in panel.urls { addRoot(url, refresh: false) }; refresh() }
    }
    func addRoot(_ url: URL, refresh: Bool = true) {
        let root = resolve(location(url))
        if !data.locations.contains(where: { $0.path == root.path }) {
            data.locations.append(root); rootRevision = UUID(); save(); configureMonitor()
        }
        if refresh { self.refresh() }
    }
    func removeRoot(_ path: String) {
        data.locations.removeAll { $0.path == path }; rootRevision = UUID()
        if selectedLocation == path { selectedLocation = nil }
        // Remove only the index entries no longer covered by any remaining root.
        data.projects.removeAll { project in !data.locations.contains { LibraryIndex.contains(project.directory, in: $0.path) } }
        unavailableRoots.remove(path)
        save(); configureMonitor(); reconcileSelection(); refresh()
    }
    func refresh() {
        guard !closed else { return }
        if scanning { needsRescan = true; return }
        let roots = data.locations.map { URL(fileURLWithPath: $0.path) }
        let cached = data.projects
        let revision = rootRevision
        let previous = Dictionary(((data.relocationHistory ?? []) + cached).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        scanning = true; needsRescan = false
        Task {
            let (result, indexed, moves) = await Task.detached(priority: .userInitiated) {
                let result = ProjectScanner.scan(roots: roots, cached: cached)
                let indexed = LibraryIndex.merge(cached: cached, result: result, roots: roots.map(\.path))
                let moves = ProjectRelocation.matches(old: Array(previous.values), fresh: indexed)
                return (result, indexed, moves)
            }.value
            guard !closed else { return }
            if revision == rootRevision {
                var merged = indexed
                applyRelocations(to: &merged, matches: moves)
                if merged != data.projects { data.projects = merged; save() }
                warnings = result.warnings; unavailableRoots = Set(result.unavailableRoots)
                unavailablePaths = result.unavailablePaths; lastScan = Date()
                visibleCache = nil // External audio dates and rolling date filters may change without index edits.
                reconcileSelection(); configureMonitor()
            } else { needsRescan = true }
            scanning = false
            if needsRescan { refresh() }
        }
    }

    private func migrationBackup() throws {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        let copy = persistenceURL.deletingLastPathComponent().appendingPathComponent("library-before-move-\(UUID()).json")
        try LibraryPersistence.save(data, to: copy)
    }

    private func applyRelocations(to projects: inout [Project], matches: [String: String]) {
        let previous = Dictionary(((data.relocationHistory ?? []) + data.projects).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let pairs = matches.filter { data.annotations[$0.key] != nil && data.annotations[$0.value] == nil }
        if !pairs.isEmpty {
            do { try migrationBackup() }
            catch { self.error = "迁移前备份失败，未更改资料：\(error.localizedDescription)"; return }
            for (from, to) in pairs {
                if let note = data.annotations[from] {
                    data.annotations[to] = ProjectRelocation.annotation(note, from: from, to: to)
                    data.annotations.removeValue(forKey: from)
                    if selectedID == from { selectedID = to }
                    projects.removeAll { $0.id == from }
                }
            }
        }
        let current = Set(projects.map(\.id))
        let history = previous.values.filter { !current.contains($0.id) && data.annotations[$0.id] != nil }.sorted { $0.id < $1.id }
        if history != (data.relocationHistory ?? []) { data.relocationHistory = history }
    }

    func relocate(_ project: Project) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "选择这个工程移动后的文件夹。只迁移资料库备注与收藏，不移动任何工程文件。"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let scan = ProjectScanner.scan(roots: [folder])
        guard let destination = scan.projects.first(where: { $0.directory == folder.path || URL(fileURLWithPath: $0.directory).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() }) else {
            error = "请选择直接包含 .cpr 的工程文件夹。"; return
        }
        guard destination.id != project.id else { return }
        guard data.annotations[destination.id] == nil else { error = "目标已有资料，未覆盖。请先核对目标工程。"; return }
        do { try migrationBackup() }
        catch { self.error = "备份失败，未迁移：\(error.localizedDescription)"; return }
        if let note = data.annotations[project.id] {
            data.annotations[destination.id] = ProjectRelocation.annotation(note, from: project.id, to: destination.id)
            data.annotations.removeValue(forKey: project.id)
        }
        rootRevision = UUID() // A manual relocation invalidates any in-flight index snapshot.
        data.projects.removeAll { $0.id == project.id }
        data.relocationHistory?.removeAll { $0.id == project.id }
        addRoot(folder); selectedID = destination.id; save()
    }

    func reconcileSelection() {
        let visible = visibleProjects
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }

    func setAutomaticRefresh(_ enabled: Bool) {
        data.automaticRefresh = enabled
        if !enabled { refreshTask?.cancel(); refreshTask = nil; needsRescan = false }
        save(); configureMonitor()
        if enabled { refresh() }
    }

    func requestAutomaticRefresh() {
        guard automaticRefresh, !closed else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self, self.automaticRefresh, !self.closed else { return }
            self.configureMonitor(); self.refresh()
        }
    }

    private func configureMonitor() {
        guard observesSystem, automaticRefresh, !closed else { monitor.stop(); monitorHealthy = true; return }
        let paths = data.locations.map(\.path).filter { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue && FileManager.default.isReadableFile(atPath: path)
        }
        monitorHealthy = monitor.start(roots: paths) { [weak self] in self?.requestAutomaticRefresh() }
    }

    private func startObservation() {
        configureMonitor() // Install before initial scanning so changes in flight are not lost.
        let events: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didBecomeActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didMountNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didUnmountNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        ]
        for (center, name) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestAutomaticRefresh() }
            }
            observers.append((center, token))
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automaticRefresh, !self.closed, !self.data.locations.isEmpty else { return }
                // Recover unavailable locations even if a mount event was not delivered.
                // Successful local scans use a five-minute safety net, not constant polling.
                if !self.unavailablePaths.isEmpty || !self.monitorHealthy || self.lastScan.map({ Date().timeIntervalSince($0) >= 300 }) != false {
                    self.requestAutomaticRefresh()
                }
            }
        }
    }

    func shutdown() {
        closed = true; refreshTask?.cancel(); saveTask?.cancel()
        monitor.stop(); recoveryTimer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll(); save()
        for url in accessed.values { url.stopAccessingSecurityScopedResource() }
        accessed.removeAll()
    }

    deinit {
        refreshTask?.cancel(); saveTask?.cancel(); recoveryTimer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
        for url in accessed.values { url.stopAccessingSecurityScopedResource() }
    }
    func audio(for project: Project) -> [FileEntry] {
        ProjectScanner.newest(project.bounces + annotation(project.id).externalAudio.map {
            ProjectScanner.entry(URL(fileURLWithPath: $0.path)) ?? FileEntry(path: $0.path, modified: .distantPast)
        })
    }
    func associateAudio(_ project: Project) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = ProjectScanner.audioExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "关联导出的完整混音；音频保留在原位置"
        if panel.runModal() == .OK {
            let locations = panel.urls.map { resolve(location($0)) }
            update(project.id) { annotation in
                for entry in locations where !annotation.externalAudio.contains(where: { $0.path == entry.path }) {
                    annotation.externalAudio.append(entry)
                }
            }
        }
    }
    var visibleProjects: [Project] {
        if let visibleCache { return visibleCache }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let filtered = data.projects.filter { project in
            if let selectedLocation, !LibraryIndex.contains(project.directory, in: selectedLocation) { return false }
            let a = annotation(project.id)
            let matches: Bool
            switch filter {
            case "收藏": matches = a.favorite
            case "模板": matches = a.template
            case "最近 30 天": matches = project.modified > cutoff
            case "缺少试听": matches = audio(for: project).isEmpty
            case "试听较旧": matches = audio(for: project).first.map { $0.modified < project.modified } ?? false
            case "全部工程": matches = true
            case "离线工程": matches = project.isOffline
            default: matches = a.stage.rawValue == filter
            }
            guard matches else { return false }
            guard !query.isEmpty else { return true }
            // Searching names requires no filesystem access, including offline external audio.
            let audioNames = project.bounces.map(\.name) + a.externalAudio.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            let searchable = ([project.name, a.notes] + project.versions.map(\.name) + audioNames).joined(separator: " ")
            return searchable.localizedCaseInsensitiveContains(query)
        }
        let byRating = sort == "评分" || sort == "迭代评分"
        let byName = sort == "名称"
        let result = filtered.map { project in
            (project: project, count: byRating ? project.iterationBackupCount : 0,
             name: byName ? project.name : "", modified: project.modified)
        }.sorted { left, right in
            if byName {
                let order = left.name.localizedStandardCompare(right.name)
                if order != .orderedSame { return order == .orderedAscending }
            }
            // Star thresholds are monotonic in backup count; count is also the tie-breaker.
            if byRating, left.count != right.count { return left.count > right.count }
            return left.modified == right.modified ? left.project.id < right.project.id : left.modified > right.modified
        }.map(\.project)
        visibleCache = result
        return result
    }
    func count(in location: String) -> Int {
        data.projects.filter { LibraryIndex.contains($0.directory, in: location) }.count
    }
    func audioIsUnavailable(_ file: FileEntry, project: Project) -> Bool {
        if project.isOffline && LibraryIndex.contains(file.path, in: project.directory) { return true }
        return !FileManager.default.isReadableFile(atPath: file.path)
    }
    func chooseCubase() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择用于打开 .cpr 工程的 Cubase 应用"
        if panel.runModal() == .OK, let url = panel.url { data.cubase = resolve(location(url)); save() }
    }
    var cubaseURL: URL? {
        if let saved = data.cubase { return URL(fileURLWithPath: saved.path) }
        let conventional = URL(fileURLWithPath: "/Applications/Cubase 15.app")
        if FileManager.default.fileExists(atPath: conventional.path) { return conventional }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.steinberg.cubase15")
    }
    func openProject(_ entry: FileEntry) {
        guard FileManager.default.fileExists(atPath: entry.path) else { error = "工程文件不存在，请连接硬盘或刷新资料库。"; return }
        guard let application = cubaseURL, FileManager.default.fileExists(atPath: application.path) else {
            error = "未找到 Cubase 15。请在侧栏中选择 Cubase 应用，然后重试。"; return
        }
        NSWorkspace.shared.open([entry.url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in self.error = "无法打开工程：\(error.localizedDescription)" } }
        }
    }
}
