import Foundation
import CryptoKit

struct ProjectIdentity: Codable, Equatable {
    var directoryKey: String?
    var contentHashes: [String]
    var versions: [FileEntry]

    static func read(_ project: Project, previous: Project?) -> ProjectIdentity {
        let attributes = try? FileManager.default.attributesOfItem(atPath: project.directory)
        let key: String?
        if let device = attributes?[.systemNumber] as? NSNumber,
           let inode = attributes?[.systemFileNumber] as? NSNumber,
           let birth = attributes?[.creationDate] as? Date {
            key = "\(device):\(inode):\(birth.timeIntervalSince1970)"
        } else { key = nil }
        if let old = previous?.identity, old.versions == project.versions, old.directoryKey == key { return old }
        var hashes: [String] = []
        for file in project.versions {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { continue }
            defer { try? handle.close() }
            var hash = SHA256()
            do {
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
                hashes.append(hash.finalize().map { String(format: "%02x", $0) }.joined())
            } catch { continue }
        }
        return ProjectIdentity(directoryKey: key, contentHashes: hashes.sorted(), versions: project.versions)
    }
}

enum ProjectRelocation {
    // Only unique, absent-source matches migrate automatically. Existing originals,
    // disconnected volumes and ambiguous copies must never steal annotations.
    static func matches(old: [Project], fresh: [Project]) -> [String: String] {
        let fm = FileManager.default
        let oldIDs = Set(old.map(\.id))
        let candidates = fresh.filter { !oldIDs.contains($0.id) && !$0.isOffline }
        guard !candidates.isEmpty else { return [:] }
        let missing = old.filter { !fm.fileExists(atPath: $0.directory) }
        var byDirectory: [String: Set<String>] = [:]
        var byHash: [String: Set<String>] = [:]
        for destination in candidates {
            guard let identity = destination.identity else { continue }
            if let key = identity.directoryKey { byDirectory[key, default: []].insert(destination.id) }
            for hash in identity.contentHashes { byHash[hash, default: []].insert(destination.id) }
        }
        var destinationsBySource: [String: Set<String>] = [:]
        var sourceCounts: [String: Int] = [:]
        for source in missing {
            guard let identity = source.identity else { continue }
            var destinations = identity.directoryKey.flatMap { byDirectory[$0] } ?? []
            let parent = URL(fileURLWithPath: source.directory).deletingLastPathComponent().path
            if !identity.contentHashes.isEmpty && fm.isReadableFile(atPath: parent) {
                for hash in identity.contentHashes { destinations.formUnion(byHash[hash] ?? []) }
            }
            destinationsBySource[source.id] = destinations
            for destination in destinations { sourceCounts[destination, default: 0] += 1 }
        }
        var pairs: [String: String] = [:]
        for (source, destinations) in destinationsBySource {
            if destinations.count == 1, let destination = destinations.first, sourceCounts[destination] == 1 {
                pairs[source] = destination
            }
        }
        return pairs
    }

    static func annotation(_ original: Annotation, from: String, to: String) -> Annotation {
        var result = original
        result.externalAudio = original.externalAudio.map { location in
            guard location.path.hasPrefix(from + "/") else { return location }
            return SavedLocation(path: to + location.path.dropFirst(from.count), bookmark: nil)
        }
        return result
    }
}
