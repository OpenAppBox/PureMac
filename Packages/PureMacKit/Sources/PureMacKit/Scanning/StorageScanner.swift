import Darwin
import Foundation
import os

/// Thread-safe cancellation flag shared between a Swift task and a blocking worker thread.
public final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func cancel() { state.withLock { $0 = true } }
    public var isCancelled: Bool { state.withLock { $0 } }
}

public struct ScanConfiguration: Sendable, Hashable {
    public var roots: [ScanRoot]
    public var excludedPaths: [String]
    /// Files allocating fewer bytes than this are aggregated into their parent row.
    public var smallFileThreshold: Int64
    public var progressInterval: TimeInterval
    public var maxStoredIssues: Int
    public var transactionBatchSize: Int

    public init(roots: [ScanRoot], excludedPaths: [String] = [], smallFileThreshold: Int64 = 256 * 1024,
                progressInterval: TimeInterval = 0.15, maxStoredIssues: Int = 5_000, transactionBatchSize: Int = 10_000) {
        self.roots = roots
        self.excludedPaths = excludedPaths
        self.smallFileThreshold = smallFileThreshold
        self.progressInterval = progressInterval
        self.maxStoredIssues = maxStoredIssues
        self.transactionBatchSize = transactionBatchSize
    }

    /// Normalized roots with nested/duplicate roots removed (a nested root would double count).
    /// Nesting is judged on the Data volume, where `/Users/…` and `/System/Volumes/Data/Users/…`
    /// are one place.
    public var effectiveRoots: [ScanRoot] {
        var seen: [ScanRoot] = []
        let normalized = roots.compactMap { root -> ScanRoot? in
            guard let path = PathTools.normalize(root.path) else { return nil }
            return ScanRoot(path: PathTools.realPath(path) ?? path, kind: root.kind)
        }.sorted { PathTools.dataVolumeForm($0.path).count < PathTools.dataVolumeForm($1.path).count }
        for root in normalized where !seen.contains(where: {
            PathTools.isSameOrInside(PathTools.dataVolumeForm(root.path), PathTools.dataVolumeForm($0.path))
        }) {
            seen.append(root)
        }
        return seen
    }
}

/// Real filesystem scanner. Streams metadata into the SQLite index on a dedicated thread with its
/// own connection; the UI reads aggregated rows from `LocalStore`.
///
/// Guarantees: no symlink is followed, no mount point is crossed, no file content is read,
/// unreadable locations are recorded as coverage gaps, and cancellation leaves a consistent,
/// clearly-marked partial index.
public final class StorageScanner: Sendable {
    public let databaseURL: URL
    public let home: String

    public init(databaseURL: URL, home: String = PathTools.userHome) {
        self.databaseURL = databaseURL
        self.home = PathTools.realPath(home) ?? home
    }

    public func scan(_ configuration: ScanConfiguration, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanSession {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ScanSession, Error>) in
                let thread = Thread { [self] in
                    do {
                        var worker = ScanWorker(databaseURL: databaseURL, home: home, configuration: configuration,
                                                flag: flag, progress: progress)
                        continuation.resume(returning: try worker.run())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "PureMac.StorageScanner"
                thread.qualityOfService = .utility
                thread.stackSize = 8 << 20
                thread.start()
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

/// Mutable traversal state. Lives entirely on the scanner thread.
private struct ScanWorker {
    struct DirAccumulator {
        var id: Int64
        var parentID: Int64?
        var depth: Int
        var name: String
        var path: String
        var pointer: UnsafeMutablePointer<FTSENT>
        var stat: FileStat
        var kind: EntryKind
        var context: StorageCategory?
        var flags: EntryFlags = []
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var fileCount: Int64 = 0
        var dirCount: Int64 = 0
        var smallCount: Int64 = 0
        var smallLogical: Int64 = 0
        var smallAllocated: Int64 = 0
        /// Allocated bytes per category (indexed by raw value) to derive a dominant category.
        var categoryBytes = [Int64](repeating: 0, count: StorageCategory.allCases.count + 1)
    }

    let databaseURL: URL
    let home: String
    let configuration: ScanConfiguration
    let flag: CancellationFlag
    let progressHandler: @Sendable (ScanProgress) -> Void
    let classifier: CategoryClassifier
    let excluded: [String]

    var db: SQLiteConnection!
    var insertEntry: SQLiteStatement!
    var insertIssue: SQLiteStatement!
    var insertSummary: SQLiteStatement!
    var sessionID: Int64 = 0
    var nextID: Int64 = 1
    var pendingRows = 0
    var stack: [DirAccumulator] = []
    var ledger = HardLinkLedger()
    var categoryTotals: [StorageCategory: CategoryTotal] = [:]
    var progress = ScanProgress()
    var storedIssues = 0
    var lastProgress = Date.distantPast
    var startedAt = Date()
    var visitCounter = 0
    var cancelled = false
    var rootDevice: Int32 = 0
    var currentRoot = ""
    /// The current root is (inside) the Data volume: paths are stored in their visible form.
    var presentsFirmlinks = false
    /// Name of the current root's row: its path, or the volume name for a whole-disk root.
    var rootName = ""
    var totals = (files: Int64(0), dirs: Int64(0), logical: Int64(0), allocated: Int64(0))

    init(databaseURL: URL, home: String, configuration: ScanConfiguration, flag: CancellationFlag,
         progress: @escaping @Sendable (ScanProgress) -> Void) {
        self.databaseURL = databaseURL
        self.home = home
        self.configuration = configuration
        self.flag = flag
        self.progressHandler = progress
        self.classifier = CategoryClassifier(home: home)
        self.excluded = configuration.excludedPaths.compactMap { PathTools.normalize($0) }.map { PathTools.realPath($0) ?? $0 }
    }

    mutating func run() throws -> ScanSession {
        // Its own connection with batched commits; never recovers (the store may have the file open).
        db = try DatabaseSchema.open(at: databaseURL, durability: .normal)
        startedAt = Date()
        let roots = configuration.effectiveRoots
        let rootsJSON = String(data: (try? JSONEncoder().encode(roots)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let excludedJSON = String(data: (try? JSONEncoder().encode(excluded)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        try db.prepare("INSERT INTO scan_session(started_at, status, roots, excluded, small_threshold) VALUES (?, 'running', ?, ?, ?)")
            .run(.of(startedAt), .text(rootsJSON), .text(excludedJSON), .int(configuration.smallFileThreshold))
        sessionID = db.lastInsertRowID
        let maxStmt = try db.prepare("SELECT COALESCE(MAX(id), 0) FROM entry")
        _ = try maxStmt.step()
        nextID = maxStmt.int64(0) + 1

        insertEntry = try db.prepare("""
            INSERT INTO entry(id, session_id, parent_id, depth, kind, name, name_key, path, ext, logical, allocated, modified, created,
                              file_count, dir_count, small_count, small_logical, small_allocated, device, inode, flags, category,
                              lead_category)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insertIssue = try db.prepare("INSERT INTO scan_issue(session_id, path, kind, code, message) VALUES (?, ?, ?, ?, ?)")
        insertSummary = try db.prepare("INSERT INTO root_summary(session_id, path, depth, logical, allocated, file_count) VALUES (?, ?, ?, ?, ?, ?)")

        var status: ScanStatus = .completed
        do {
            try db.execute("BEGIN")
            for root in roots {
                if flag.isCancelled { cancelled = true; break }
                try scanRoot(root)
                if cancelled { break }
            }
            if cancelled { status = .cancelled }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            status = .failed
            try? finish(status: status)
            throw error
        }
        try finish(status: status)
        return ScanSession(id: sessionID, startedAt: startedAt, finishedAt: Date(), status: status, roots: roots,
                           excludedPaths: excluded, fileCount: totals.files, directoryCount: totals.dirs,
                           logicalSize: totals.logical, allocatedSize: totals.allocated,
                           hardLinkDuplicateCount: ledger.duplicateCount, issueCount: progress.issueCount,
                           smallFileThreshold: configuration.smallFileThreshold, hasIndex: true)
    }

    mutating func finish(status: ScanStatus) throws {
        try db.transaction {
            let catStmt = try db.prepare("INSERT OR REPLACE INTO category_total(session_id, category, file_count, logical, allocated) VALUES (?, ?, ?, ?, ?)")
            for total in categoryTotals.values {
                try catStmt.run(.int(sessionID), .int(Int64(total.category.rawValue)), .int(total.fileCount), .int(total.logicalSize), .int(total.allocatedSize))
            }
            try db.prepare("""
                UPDATE scan_session SET finished_at = ?, status = ?, file_count = ?, dir_count = ?, logical_bytes = ?,
                       allocated_bytes = ?, hardlink_dups = ?, issue_count = ? WHERE id = ?
                """).run(.of(Date()), .text(status.rawValue), .int(totals.files), .int(totals.dirs), .int(totals.logical),
                         .int(totals.allocated), .int(ledger.duplicateCount), .int(progress.issueCount), .int(sessionID))
        }
        progress.elapsed = Date().timeIntervalSince(startedAt)
        snapshotCategories()
        progressHandler(progress)
    }

    mutating func snapshotCategories() {
        for (category, total) in categoryTotals where category.rawValue < progress.categoryAllocated.count {
            progress.categoryAllocated[category.rawValue] = total.allocatedSize
        }
    }

    // MARK: Traversal

    mutating func scanRoot(_ root: ScanRoot) throws {
        currentRoot = root.path
        progress.currentRoot = root.path
        presentsFirmlinks = PathTools.isSameOrInside(root.path, PathTools.dataVolume)
        rootName = root.path
        if root.path == PathTools.dataVolume {
            rootName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? root.path
        }
        switch FileStat.lstat(root.path) {
        case .failure(let error):
            try recordIssue(ScanIssue(path: root.path, kind: .missingRoot, errorCode: error.code.rawValue, message: String(cString: strerror(error.code.rawValue))))
            return
        case .success(let st):
            guard st.identity.type == .directory else {
                try recordIssue(ScanIssue(path: root.path, kind: .missingRoot, message: String(localized: "Not a folder", bundle: .module)))
                return
            }
            rootDevice = st.identity.device
        }

        var thrown: Error?
        try FTSWalker.walk(root: root.path) { entry in
            do {
                return try handle(entry)
            } catch {
                thrown = error
                return .stop
            }
        }
        if let thrown { throw thrown }
        // On cancellation fts stops mid-tree: close the open directories so the index stays consistent.
        while !stack.isEmpty {
            stack[stack.count - 1].flags.insert(.partial)
            try popDirectory()
        }
    }

    mutating func handle(_ entry: FTSWalker.Entry) throws -> FTSWalker.Decision {
        visitCounter += 1
        if visitCounter & 0x1FF == 0 {
            if flag.isCancelled {
                cancelled = true
                progress.isCancelling = true
                return .stop
            }
            emitProgressIfDue()
        }

        switch entry.visit {
        case .directoryPre:
            guard let st = entry.stat else { return .proceed }
            let path = presented(entry.path)
            let name = entry.level == 0 ? rootName : (path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            let parentContext = stack.last?.context
            var acc = DirAccumulator(
                id: nextID, parentID: stack.last?.id, depth: entry.level, name: name, path: path, pointer: entry.pointer,
                stat: st, kind: CategoryClassifier.packageExtensions.contains(ext) ? .package : .directory,
                context: classifier.directoryContext(path: path, name: name, parentContext: parentContext)
            )
            nextID += 1
            progress.directoriesVisited += 1
            let relative = PathTools.relativeComponents(of: entry.path, under: currentRoot) ?? []
            progress.currentRelativePath = relative.joined(separator: "/")
            if relative.count == 1 { progress.currentTopLevel = relative[0] }

            var decision = FTSWalker.Decision.proceed
            if st.identity.device != rootDevice {
                acc.flags.insert(.mountBoundary)
                try recordIssue(ScanIssue(path: path, kind: .mountBoundary, message: String(localized: "Another volume is mounted here; scan it separately.", bundle: .module)))
                decision = .skipChildren
            } else if entry.level > 0, excluded.contains(where: { PathTools.isSameOrInside(path, $0) }) {
                acc.flags.insert(.excluded)
                try recordIssue(ScanIssue(path: path, kind: .excluded, message: String(localized: "Excluded in Settings", bundle: .module)))
                decision = .skipChildren
            }
            stack.append(acc)
            return decision

        case .directoryPost:
            if let top = stack.last, top.pointer == entry.pointer { try popDirectory() }
            return .proceed

        case .unreadableDirectory(let code):
            if let top = stack.last, top.pointer == entry.pointer {
                stack[stack.count - 1].flags.insert(.unreadable)
                try recordIssue(issue(for: presented(entry.path), code: code))
                try popDirectory()
            } else {
                try recordIssue(issue(for: presented(entry.path), code: code))
                markParentPartial()
            }
            return .proceed

        case .file, .symlink, .other:
            guard let st = entry.stat else { return .proceed }
            try addFile(entry: entry, stat: st)
            return .proceed

        case .cycle:
            try recordIssue(ScanIssue(path: presented(entry.path), kind: .cycle, errorCode: ELOOP, message: String(localized: "Directory cycle not followed", bundle: .module)))
            return .proceed

        case .error(let code):
            if let top = stack.last, top.pointer == entry.pointer {
                stack[stack.count - 1].flags.insert(.unreadable)
                try recordIssue(issue(for: presented(entry.path), code: code))
                try popDirectory()
            } else {
                try recordIssue(issue(for: presented(entry.path), code: code))
                markParentPartial()
            }
            return .proceed
        }
    }

    /// Paths are stored as Finder shows them: inside a whole-disk scan, `/System/Volumes/Data/Users/x`
    /// is `/Users/x`, so categories, exclusions, Smart Clean and cleanups see one name per place.
    func presented(_ path: String) -> String {
        presentsFirmlinks ? PathTools.canonicalizingDataVolume(path) : path
    }

    func issue(for path: String, code: Int32) -> ScanIssue {
        ScanIssue(path: path, kind: ScanIssue.classify(errno: code), errorCode: code, message: String(cString: strerror(code)))
    }

    mutating func markParentPartial() {
        if !stack.isEmpty { stack[stack.count - 1].flags.insert(.partial) }
    }

    mutating func addFile(entry: FTSWalker.Entry, stat st: FileStat) throws {
        guard !stack.isEmpty else { return }
        let countAllocation = ledger.shouldCount(device: st.identity.device, inode: st.identity.inode, linkCount: st.linkCount)
        let allocated = countAllocation ? st.allocatedSize : 0
        let logical = st.logicalSize
        let parentIndex = stack.count - 1
        let name = (entry.path as NSString).lastPathComponent
        let path = presented(entry.path)
        let category = classifier.fileCategory(name: name, context: stack[parentIndex].context)

        stack[parentIndex].logical += logical
        stack[parentIndex].allocated += allocated
        stack[parentIndex].fileCount += 1
        stack[parentIndex].categoryBytes[category.rawValue] += max(allocated, 1)
        progress.filesVisited += 1
        progress.logicalBytes += logical
        progress.allocatedBytes += allocated

        var total = categoryTotals[category] ?? CategoryTotal(category: category)
        total.fileCount += 1
        total.logicalSize += logical
        total.allocatedSize += allocated
        categoryTotals[category] = total

        if st.allocatedSize >= configuration.smallFileThreshold || logical >= configuration.smallFileThreshold * 4 {
            var flags: EntryFlags = []
            if !countAllocation { flags.insert(.hardLinkDuplicate) }
            if st.isDataless || (logical > 0 && st.allocatedSize < logical / 4 && logical > 1 << 20) { flags.insert(.sparseOrDataless) }
            let kind: EntryKind = switch st.identity.type {
            case .regular: .file
            case .symlink: .symlink
            default: .other
            }
            try writeRow(id: nextID, parentID: stack[parentIndex].id, depth: entry.level, kind: kind, name: name,
                         path: path, logical: logical, allocated: allocated, stat: st, fileCount: 1, dirCount: 0,
                         small: (0, 0, 0), flags: flags, category: category)
            nextID += 1
        } else {
            stack[parentIndex].smallCount += 1
            stack[parentIndex].smallLogical += logical
            stack[parentIndex].smallAllocated += allocated
        }
    }

    mutating func popDirectory() throws {
        guard let acc = stack.popLast() else { return }
        let category = acc.context ?? Self.dominantCategory(acc.categoryBytes)
        try writeRow(id: acc.id, parentID: acc.parentID, depth: acc.depth, kind: acc.kind, name: acc.name, path: acc.path,
                     logical: acc.logical, allocated: acc.allocated, stat: acc.stat, fileCount: acc.fileCount,
                     dirCount: acc.dirCount, small: (acc.smallCount, acc.smallLogical, acc.smallAllocated),
                     flags: acc.flags, category: category,
                     lead: category == .unclassified ? Self.largestCategory(acc.categoryBytes) : nil)
        if acc.depth <= 1 {
            try insertSummary.run(.int(sessionID), .text(acc.path), .int(Int64(acc.depth)), .int(acc.logical), .int(acc.allocated), .int(acc.fileCount))
        }
        if stack.isEmpty {
            totals.files += acc.fileCount
            totals.dirs += acc.dirCount + 1
            totals.logical += acc.logical
            totals.allocated += acc.allocated
        } else {
            let p = stack.count - 1
            stack[p].logical += acc.logical
            stack[p].allocated += acc.allocated
            stack[p].fileCount += acc.fileCount
            stack[p].dirCount += acc.dirCount + 1
            for i in acc.categoryBytes.indices { stack[p].categoryBytes[i] += acc.categoryBytes[i] }
            if !acc.flags.isDisjoint(with: [.unreadable, .partial]) { stack[p].flags.insert(.partial) }
        }
    }

    /// The category holding the most bytes, other than "unclassified" (the color of a mixed folder).
    static func largestCategory(_ bytes: [Int64]) -> StorageCategory? {
        let ranked = bytes.indices.filter { $0 != StorageCategory.unclassified.rawValue && bytes[$0] > 0 }
        return ranked.max { bytes[$0] < bytes[$1] }.flatMap(StorageCategory.init(rawValue:))
    }

    /// The category holding at least 60% of a folder's bytes, else `.unclassified` (shown as "Mixed").
    static func dominantCategory(_ bytes: [Int64]) -> StorageCategory {
        let total = bytes.reduce(0, +)
        guard total > 0, let maxIndex = bytes.indices.max(by: { bytes[$0] < bytes[$1] }),
              Double(bytes[maxIndex]) >= Double(total) * 0.6 else { return .unclassified }
        return StorageCategory(rawValue: maxIndex) ?? .unclassified
    }

    mutating func writeRow(id: Int64, parentID: Int64?, depth: Int, kind: EntryKind, name: String, path: String,
                           logical: Int64, allocated: Int64, stat st: FileStat, fileCount: Int64, dirCount: Int64,
                           small: (Int64, Int64, Int64), flags: EntryFlags, category: StorageCategory,
                           lead: StorageCategory? = nil) throws {
        let ext = (kind == .file) ? (name as NSString).pathExtension.lowercased() : nil
        try insertEntry.run(
            .int(id), .int(sessionID), .of(parentID), .int(Int64(depth)), .int(Int64(kind.rawValue)),
            .text(name.precomposedStringWithCanonicalMapping), .text(SearchKey.make(name)), .text(path),
            ext.flatMap { $0.isEmpty ? nil : .text($0) }, .int(logical), .int(allocated), .of(st.modified), .of(st.created),
            .int(fileCount), .int(dirCount), .int(small.0), .int(small.1), .int(small.2),
            .int(Int64(st.identity.device)), .int(Int64(bitPattern: st.identity.inode)), .int(Int64(flags.rawValue)),
            .int(Int64(category.rawValue)), lead.map { .int(Int64($0.rawValue)) }
        )
        pendingRows += 1
        if pendingRows >= configuration.transactionBatchSize {
            try db.execute("COMMIT")
            try db.execute("BEGIN")
            pendingRows = 0
        }
    }

    mutating func recordIssue(_ issue: ScanIssue) throws {
        progress.issueCount += 1
        guard storedIssues < configuration.maxStoredIssues else { return }
        storedIssues += 1
        try insertIssue.run(.int(sessionID), .text(issue.path), .text(issue.kind.rawValue), .int(Int64(issue.errorCode)), .text(issue.message))
    }

    mutating func emitProgressIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastProgress) >= configuration.progressInterval else { return }
        lastProgress = now
        progress.elapsed = now.timeIntervalSince(startedAt)
        snapshotCategories()
        progressHandler(progress)
    }
}
