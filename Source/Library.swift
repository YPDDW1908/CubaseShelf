import Foundation

enum Stage: String, Codable, CaseIterable, Identifiable {
    case idea = "灵感", working = "进行中", arrangement = "编曲", mixing = "混音", delivered = "已交付", archived = "归档"
    var id: String { rawValue }
}

struct FileEntry: Identifiable, Codable, Hashable {
    var path: String
    var modified: Date
    init(path: String, modified: Date) {
        // URL paths may bridge lazily from Foundation. Materialize UTF-8 once so
        // repeated rating/search operations do not repeatedly convert long paths.
        self.path = String(decoding: path.utf8, as: UTF8.self)
        self.modified = modified
    }
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

enum ProjectAvailability: String, Codable {
    case offline, partial
}

struct Project: Identifiable, Codable, Equatable {
    var directory: String
    var versions: [FileEntry]
    var backups: [FileEntry]
    var bounces: [FileEntry]
    // Optional so libraries created by v0.1 remain readable without migration.
    var availability: ProjectAvailability?
    var identity: ProjectIdentity?
    var metadata: ProjectMetadata?
    var id: String { directory }
    var name: String { URL(fileURLWithPath: directory).lastPathComponent }
    var modified: Date { versions.first?.modified ?? .distantPast }
    var iterationBackupCount: Int {
        var paths = Set<String>()
        for file in backups where file.path.utf8.suffix(4).elementsEqual([46, 98, 97, 107], by: { ($0 | 32) == $1 }) {
            paths.insert(file.path)
        }
        return paths.count
    }
    var iterationRating: Int {
        switch iterationBackupCount {
        case 0: return 0
        case 1...4: return 1
        case 5...9: return 2
        case 10...19: return 3
        case 20...49: return 4
        default: return 5
        }
    }
    static let ratingExplanation = "按当前 .bak 备份数量自动评分：0 个无星，1–4 个 1 星，5–9 个 2 星，10–19 个 3 星，20–49 个 4 星，50 个以上 5 星。反映迭代活跃度，不评价音乐质量；删除或轮换备份会影响评分。"
    var isOffline: Bool { availability == .offline }
}

struct SavedLocation: Codable, Identifiable, Equatable {
    var path: String
    var bookmark: Data?
    var id: String { path }
}

struct Annotation: Codable {
    var favorite = false
    var template = false
    // Retained only to read older libraries; the UI and sorting use Project.iterationRating.
    var rating = 0
    var stage = Stage.idea
    var notes = ""
    var bpm = ""
    var externalAudio: [SavedLocation] = []
}

struct LibraryData: Codable {
    var schemaVersion = 1
    var locations: [SavedLocation] = []
    var annotations: [String: Annotation] = [:]
    var projects: [Project] = []
    var cubase: SavedLocation?
    var automaticRefresh: Bool?
    var relocationHistory: [Project]?
}

struct ScanResult {
    var projects: [Project]
    var warnings: [String]
    var unavailablePaths: [String] = []
    var unavailableRoots: [String] = []
}

enum LibraryIndex {
    // Lexical comparison must not depend on whether the disk currently exists.
    // Foundation standardization can change /private/var aliases after disconnect.
    private static func comparisonPath(_ path: String) -> String {
        var components: [String] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(part))
        }
        if components.count >= 2, components[0] == "private", ["var", "tmp", "etc"].contains(components[1]) {
            components.removeFirst()
        }
        return "/" + components.joined(separator: "/")
    }

    static func contains(_ path: String, in root: String) -> Bool {
        let directory = comparisonPath(root)
        let candidate = comparisonPath(path)
        return candidate == directory || candidate.hasPrefix(directory == "/" ? "/" : directory + "/")
    }

    static func merge(cached: [Project], result: ScanResult, roots: [String]) -> [Project] {
        func unavailable(_ path: String) -> Bool {
            result.unavailablePaths.contains { contains(path, in: $0) }
        }
        func managed(_ project: Project) -> Bool { roots.contains { contains(project.directory, in: $0) } }
        let previous = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var projects: [String: Project] = [:]
        for var project in result.projects where managed(project) {
            if let old = previous[project.id] {
                project.versions = ProjectScanner.newest(project.versions + old.versions.filter { unavailable($0.path) })
                project.backups = ProjectScanner.newest(project.backups + old.backups.filter { unavailable($0.path) })
                project.bounces = ProjectScanner.newest(project.bounces + old.bounces.filter { unavailable($0.path) })
            }
            if unavailable(project.directory) { project.availability = .offline }
            else if result.unavailablePaths.contains(where: { contains($0, in: project.directory) }) { project.availability = .partial }
            else { project.availability = nil }
            projects[project.id] = project
        }
        // A successful scan is authoritative: removed CPRs disappear. Failed subtrees
        // are not evidence of deletion, so their cached projects remain editable.
        for var project in cached where managed(project) && projects[project.id] == nil &&
            (unavailable(project.directory) || project.versions.contains(where: { unavailable($0.path) })) {
            project.availability = unavailable(project.directory) ? .offline : .partial
            projects[project.id] = project
        }
        return projects.values.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
    }
}

enum ProjectScanner {
    static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "flac", "mp3", "m4a", "caf"]
    static let exportFolders: Set<String> = ["mixdown", "mixdowns", "bounce", "bounces", "export", "exports", "render", "renders"]
    static let excludedFolders: Set<String> = ["audio", "edits", "images", "track pictures", "stems", "stem", "分轨", "__macosx"]
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]

    static func entry(_ url: URL) -> FileEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return FileEntry(path: url.standardizedFileURL.path, modified: values.contentModificationDate ?? .distantPast)
    }

    static func newest(_ entries: [FileEntry]) -> [FileEntry] {
        Array(Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
    }

    static func normalizedName(_ name: String) -> String {
        name.lowercased().precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[\s_\-]+"#, with: "", options: .regularExpression)
    }

    // Root-level recordings are common in Cubase projects. Only admit names that
    // match the project or a project version; explicit export folders allow any mix name.
    static func matchesProject(_ audioName: String, names: [String]) -> Bool {
        let candidate = normalizedName(audioName)
        return names.contains { name in
            let base = normalizedName(name)
            if candidate == base { return true }
            guard !base.isEmpty, candidate.hasPrefix(base) else { return false }
            let suffix = String(candidate.dropFirst(base.count))
            return suffix.range(of: #"^(?:(?:mix|master|demo|bounce|export|final|v|version)[0-9]*|[0-9]+)$"#, options: .regularExpression) != nil
        }
    }

    static func scan(roots: [URL], cached: [Project] = []) -> ScanResult {
        let fm = FileManager.default
        var versions: [String: [FileEntry]] = [:]
        var backups: [String: [FileEntry]] = [:]
        var warnings: [String] = []
        var unavailablePaths = Set<String>()
        var unavailableRoots = Set<String>()
        var seen = Set<String>()
        var traversed: [String] = []
        for root in roots.sorted(by: { $0.path.count < $1.path.count }) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  fm.isReadableFile(atPath: root.path) else {
                warnings.append("位置离线或不可访问：\(root.path)")
                unavailableRoots.insert(root.path); unavailablePaths.insert(root.path); continue
            }
            // Deduplicate exact roots only: explicitly selected child roots may be
            // packages, symlinks or normally excluded folders with different traversal rules.
            if traversed.contains(root.path) { continue }
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                    unavailablePaths.insert(url.path)
                    warnings.append("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)"); return true
                }) else {
                    unavailablePaths.insert(root.path); unavailableRoots.insert(root.path)
                    warnings.append("无法扫描：\(root.path)"); continue
                }
            traversed.append(root.path)
            for case let url as URL in iterator {
                let values: URLResourceValues
                do { values = try url.resourceValues(forKeys: Set(keys)) }
                catch {
                    unavailablePaths.insert(url.path); warnings.append("无法读取属性：\(url.path)")
                    iterator.skipDescendants(); continue
                }
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if values.isDirectory == true {
                    if excludedFolders.contains(url.lastPathComponent.lowercased()) || exportFolders.contains(url.lastPathComponent.lowercased()) {
                        iterator.skipDescendants()
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard ext == "cpr" || ext == "bak", let file = entry(url), seen.insert(file.path).inserted else { continue }
                var folder = url.deletingLastPathComponent()
                let inBackups = ["auto saves", "autosaves", "backup", "backups"].contains(folder.lastPathComponent.lowercased())
                if inBackups { folder = folder.deletingLastPathComponent() }
                if ext == "bak" || inBackups { backups[folder.path, default: []].append(file) }
                else { versions[folder.path, default: []].append(file) }
            }
        }
        var projects: [Project] = []
        for (path, files) in versions {
            let directory = URL(fileURLWithPath: path)
            let names = [directory.lastPathComponent] + files.map { $0.url.deletingPathExtension().lastPathComponent }
            var audio: [FileEntry] = []
            do {
                for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard values?.isSymbolicLink != true else { continue }
                    if values?.isDirectory == true && exportFolders.contains(url.lastPathComponent.lowercased()) {
                        if let iterator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                            unavailablePaths.insert(url.path)
                            warnings.append("无法读取导出目录 \(url.lastPathComponent)：\(error.localizedDescription)"); return true
                        }) {
                            for case let mix as URL in iterator {
                                let mixValues = try? mix.resourceValues(forKeys: Set(keys))
                                if mixValues?.isSymbolicLink == true { iterator.skipDescendants(); continue }
                                if mixValues?.isDirectory == true && excludedFolders.contains(mix.lastPathComponent.lowercased()) { iterator.skipDescendants(); continue }
                                if audioExtensions.contains(mix.pathExtension.lowercased()), let file = entry(mix) { audio.append(file) }
                            }
                        } else { unavailablePaths.insert(url.path); warnings.append("无法读取导出目录：\(url.path)") }
                    } else if audioExtensions.contains(url.pathExtension.lowercased()),
                              matchesProject(url.deletingPathExtension().lastPathComponent, names: names), let file = entry(url) {
                        audio.append(file)
                    }
                }
            } catch { unavailablePaths.insert(path); warnings.append("无法读取工程目录：\(path)") }
            projects.append(Project(directory: path, versions: newest(files), backups: newest(backups[path] ?? []), bounces: newest(audio)))
        }
        let old = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for index in projects.indices {
            let previous = old[projects[index].id]
            projects[index].identity = ProjectIdentity.read(projects[index], previous: previous)
            if previous?.versions.first == projects[index].versions.first, let info = previous?.metadata, info.parserRevision == ProjectMetadata.currentRevision { projects[index].metadata = info }
            else if let file = projects[index].versions.first { projects[index].metadata = CPRMetadataReader.read(file.url) }
        }
        projects.sort { $0.modified == $1.modified ? $0.directory < $1.directory : $0.modified > $1.modified }
        // A drive can disconnect while enumeration is in flight.
        for root in roots {
            var isDirectory: ObjCBool = false
            if !fm.fileExists(atPath: root.path, isDirectory: &isDirectory) || !isDirectory.boolValue || !fm.isReadableFile(atPath: root.path) {
                unavailableRoots.insert(root.path); unavailablePaths.insert(root.path)
                warnings.append("位置离线或不可访问：\(root.path)")
            }
        }
        return ScanResult(projects: projects, warnings: Array(Set(warnings)).sorted(),
                          unavailablePaths: unavailablePaths.sorted(), unavailableRoots: unavailableRoots.sorted())
    }
}

enum LibraryPersistence {
    static func load(from url: URL) throws -> LibraryData {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryData() }
        let library = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: url))
        guard library.schemaVersion == 1 else { throw NSError(domain: "CubaseShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "资料库版本不受支持，未覆盖原文件。"] ) }
        return library
    }
    static func save(_ library: LibraryData, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
