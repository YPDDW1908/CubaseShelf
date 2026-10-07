import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class LibraryStore: ObservableObject {
    @Published var data = LibraryData()
    @Published var scanning = false
    @Published var warnings: [String] = []
    @Published var error: String?
    @Published var selectedID: String?
    @Published var filter = "全部工程"
    @Published var query = ""
    @Published var sort = "最近修改"
    @Published var lastScan: Date?
    let persistenceURL: URL
    private var writeAllowed = true
    private var accessed: [String: URL] = [:]
    private var scanGeneration = UUID()
    private var saveTask: Task<Void, Never>?

    init() {
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        persistenceURL = argument("--library-path").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CubaseShelf/library.json")
        do { data = try LibraryPersistence.load(from: persistenceURL) }
        catch { self.error = "读取资料库失败，已暂停保存以保护原文件：\(error.localizedDescription)"; writeAllowed = false }
        data.locations = data.locations.map { resolve($0) }
        for key in Array(data.annotations.keys) {
            data.annotations[key]?.externalAudio = (data.annotations[key]?.externalAudio ?? []).map { resolve($0) }
        }
        if let app = data.cubase { data.cubase = resolve(app) }
        if let root = argument("--import-root") { addRoot(URL(fileURLWithPath: root), refresh: false) }
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
        if !data.locations.contains(where: { $0.path == root.path }) { data.locations.append(root); save() }
        if refresh { self.refresh() }
    }
    func removeRoot(_ path: String) {
        data.locations.removeAll { $0.path == path }; save(); refresh()
    }
    func refresh() {
        let roots = data.locations.map { URL(fileURLWithPath: $0.path) }
        let generation = UUID(); scanGeneration = generation; scanning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { ProjectScanner.scan(roots: roots) }.value
            guard generation == scanGeneration else { return }
            data.projects = result.projects; warnings = result.warnings; scanning = false; lastScan = Date()
            if selectedID == nil || !data.projects.contains(where: { $0.id == selectedID }) { selectedID = data.projects.first?.id }
            save()
        }
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
        data.projects.filter { project in
            let a = annotation(project.id)
            let matches: Bool
            switch filter {
            case "收藏": matches = a.favorite
            case "模板": matches = a.template
            case "最近 30 天": matches = project.modified > Date().addingTimeInterval(-30 * 86400)
            case "缺少试听": matches = audio(for: project).isEmpty
            case "试听较旧": matches = audio(for: project).first.map { $0.modified < project.modified } ?? false
            case "全部工程": matches = true
            default: matches = a.stage.rawValue == filter
            }
            let searchable = ([project.name, a.notes] + project.versions.map(\.name) + audio(for: project).map(\.name)).joined(separator: " ")
            return matches && (query.isEmpty || searchable.localizedCaseInsensitiveContains(query))
        }.sorted { left, right in
            if sort == "名称" { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            if sort == "评分", annotation(left.id).rating != annotation(right.id).rating { return annotation(left.id).rating > annotation(right.id).rating }
            return left.modified == right.modified ? left.id < right.id : left.modified > right.modified
        }
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
