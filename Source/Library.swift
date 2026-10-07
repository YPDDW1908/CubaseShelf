import Foundation

enum Stage: String, Codable, CaseIterable, Identifiable {
    case idea = "灵感", working = "进行中", arrangement = "编曲", mixing = "混音", delivered = "已交付", archived = "归档"
    var id: String { rawValue }
}

struct FileEntry: Identifiable, Codable, Hashable {
    var path: String
    var modified: Date
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

struct Project: Identifiable, Codable {
    var directory: String
    var versions: [FileEntry]
    var backups: [FileEntry]
    var bounces: [FileEntry]
    var id: String { directory }
    var name: String { URL(fileURLWithPath: directory).lastPathComponent }
    var modified: Date { versions.first?.modified ?? .distantPast }
}

struct SavedLocation: Codable, Identifiable, Equatable {
    var path: String
    var bookmark: Data?
    var id: String { path }
}

struct Annotation: Codable {
    var favorite = false
    var template = false
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
}

struct ScanResult {
    var projects: [Project]
    var warnings: [String]
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

    static func scan(roots: [URL]) -> ScanResult {
        let fm = FileManager.default
        var versions: [String: [FileEntry]] = [:]
        var backups: [String: [FileEntry]] = [:]
        var warnings: [String] = []
        var seen = Set<String>()
        for root in roots {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  fm.isReadableFile(atPath: root.path) else {
                warnings.append("位置不可访问：\(root.path)"); continue
            }
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                    warnings.append("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)"); return true
                }) else { warnings.append("无法扫描：\(root.path)"); continue }
            for case let url as URL in iterator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if values?.isDirectory == true {
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
                            warnings.append("无法读取导出目录 \(url.lastPathComponent)：\(error.localizedDescription)"); return true
                        }) {
                            for case let mix as URL in iterator {
                                let mixValues = try? mix.resourceValues(forKeys: Set(keys))
                                if mixValues?.isSymbolicLink == true { iterator.skipDescendants(); continue }
                                if mixValues?.isDirectory == true && excludedFolders.contains(mix.lastPathComponent.lowercased()) { iterator.skipDescendants(); continue }
                                if audioExtensions.contains(mix.pathExtension.lowercased()), let file = entry(mix) { audio.append(file) }
                            }
                        }
                    } else if audioExtensions.contains(url.pathExtension.lowercased()),
                              matchesProject(url.deletingPathExtension().lastPathComponent, names: names), let file = entry(url) {
                        audio.append(file)
                    }
                }
            } catch { warnings.append("无法读取工程目录：\(path)") }
            projects.append(Project(directory: path, versions: newest(files), backups: newest(backups[path] ?? []), bounces: newest(audio)))
        }
        projects.sort { $0.modified == $1.modified ? $0.directory < $1.directory : $0.modified > $1.modified }
        return ScanResult(projects: projects, warnings: Array(Set(warnings)).sorted())
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
