import Darwin
import Foundation

/// Size summary of a file or directory subtree.
public struct SizeSummary: Sendable, Hashable {
    public var logicalSize: Int64 = 0
    public var allocatedSize: Int64 = 0
    public var fileCount: Int64 = 0
    public var directoryCount: Int64 = 0
    public var newestModification: Date?
    /// Some descendants could not be read; sizes are a lower bound.
    public var isPartial = false
    public var hardLinkDuplicates: Int64 = 0

    public init() {}
}

/// Measures subtrees with `fts`, without following symlinks or crossing volumes.
public enum DirectorySizer {
    /// Measures `path`. Checks `isCancelled` periodically and stops early when it returns `true`
    /// (the summary is then marked partial).
    public static func measure(_ path: String, isCancelled: () -> Bool = { false }) -> SizeSummary {
        var summary = SizeSummary()
        var ledger = HardLinkLedger()
        var counter = 0
        do {
            try FTSWalker.walk(root: path) { entry in
                counter += 1
                if counter & 0x3FF == 0, isCancelled() {
                    summary.isPartial = true
                    return .stop
                }
                switch entry.visit {
                case .file, .symlink:
                    guard let st = entry.stat else { return .proceed }
                    summary.fileCount += 1
                    summary.logicalSize += st.logicalSize
                    if ledger.shouldCount(device: st.identity.device, inode: st.identity.inode, linkCount: st.linkCount) {
                        summary.allocatedSize += st.allocatedSize
                    }
                    if summary.newestModification.map({ st.modified > $0 }) ?? true {
                        summary.newestModification = st.modified
                    }
                case .directoryPre:
                    if entry.level > 0 { summary.directoryCount += 1 }
                    if let st = entry.stat, summary.newestModification.map({ st.modified > $0 }) ?? true {
                        summary.newestModification = st.modified
                    }
                case .unreadableDirectory, .error:
                    summary.isPartial = true
                case .directoryPost, .cycle, .other:
                    break
                }
                return .proceed
            }
        } catch {
            summary.isPartial = true
        }
        summary.hardLinkDuplicates = ledger.duplicateCount
        return summary
    }

    /// Measures several paths concurrently with bounded parallelism.
    public static func measureAll(_ paths: [String], maxConcurrency: Int = 4) async -> [String: SizeSummary] {
        var results: [String: SizeSummary] = [:]
        await withTaskGroup(of: (String, SizeSummary).self) { group in
            var iterator = paths.makeIterator()
            func addNext() -> Bool {
                guard let path = iterator.next() else { return false }
                group.addTask {
                    (path, measure(path, isCancelled: { Task.isCancelled }))
                }
                return true
            }
            for _ in 0..<max(1, maxConcurrency) where !addNext() { break }
            while let (path, summary) = await group.next() {
                results[path] = summary
                _ = addNext()
            }
        }
        return results
    }
}
