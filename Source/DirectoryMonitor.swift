import Foundation
import CoreServices

// FSEvents is advisory. Store also scans on activation/mount/wake and retries
// unavailable roots, and a low-frequency fallback handles missed events.
enum LibraryChange {
    static func isRelevant(path: String, root: String, directory: Bool, mustRescan: Bool = false) -> Bool {
        if mustRescan { return true }
        // FSEvents uses physical paths (/private/var/...); selected URLs can use
        // aliases (/var/...). Resolve only for event matching, not project identity.
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        guard LibraryIndex.contains(path, in: root) else { return false }
        let rootCount = URL(fileURLWithPath: root).pathComponents.count
        let components = Array(URL(fileURLWithPath: path).pathComponents.dropFirst(rootCount))
        let directories = directory ? components : Array(components.dropLast())
        if directories.contains(where: { $0.hasPrefix(".") || ProjectScanner.excludedFolders.contains($0.lowercased()) }) { return false }
        if directory { return true }
        guard !URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") else { return false }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext == "cpr" || ext == "bak" || ProjectScanner.audioExtensions.contains(ext)
    }
}

private final class EventSink {
    let roots: [String]
    let changed: () -> Void
    init(roots: [String], changed: @escaping () -> Void) { self.roots = roots; self.changed = changed }
}

final class DirectoryMonitor {
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    var isRunning: Bool { stream != nil }

    // Called on the main queue; event callbacks are delivered on the same queue.
    @discardableResult func start(roots: [String], changed: @escaping () -> Void) -> Bool {
        let paths = Array(Set(roots)).sorted()
        if paths == watched, stream != nil { return true }
        stop()
        guard !paths.isEmpty else { return true }
        let sink = EventSink(roots: paths, changed: changed)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<EventSink>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<EventSink>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let rescanMask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount | kFSEventStreamEventFlagEventIdsWrapped)
            for index in 0..<min(count, paths.count) {
                let flags = rawFlags[index]
                let rescan = flags & rescanMask != 0
                let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                if sink.roots.contains(where: { LibraryChange.isRelevant(path: paths[index], root: $0, directory: isDirectory, mustRescan: rescan) }) {
                    sink.changed(); break
                }
            }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.6, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created); return false
        }
        stream = created; watched = paths
        return true
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
        stream = nil; watched = []
    }
    deinit { stop() }
}
