import CryptoKit
import Darwin
import Foundation

public struct DuplicateFile: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var identity: FileIdentity
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var modified: Date
    /// Other paths that are hard links to this same file (not duplicates — removing one frees nothing).
    public var hardLinkPaths: [String]

    public var name: String { (path as NSString).lastPathComponent }

    /// The file as it was found; its content is unchanged while this still matches.
    public var snapshot: FileSnapshot { FileSnapshot(path: path, identity: identity, logicalSize: logicalSize, modified: modified) }

    public init(path: String, identity: FileIdentity, logicalSize: Int64, allocatedSize: Int64, modified: Date, hardLinkPaths: [String] = []) {
        self.path = path
        self.identity = identity
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.hardLinkPaths = hardLinkPaths
    }
}

/// Files with byte-identical content (same size and SHA-256), each a distinct inode.
public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public var id: String { sha256 }
    public var sha256: String
    public var size: Int64
    public var files: [DuplicateFile]

    /// Upper bound of reclaimable bytes if all but one copy were removed. APFS clones may already
    /// share blocks, so the real gain can be lower.
    public var potentialSavings: Int64 { Int64(max(0, files.count - 1)) * files.map(\.allocatedSize).min()! }

    public init(sha256: String, size: Int64, files: [DuplicateFile]) {
        self.sha256 = sha256
        self.size = size
        self.files = files
    }
}

public struct DuplicateScanResult: Sendable {
    public var groups: [DuplicateGroup]
    public var filesConsidered: Int
    public var bytesHashed: Int64
    public var skippedUnreadable: Int
    public var skippedCloudOnly: Int
    public var hardLinkSetsIgnored: Int
    public var wasCancelled: Bool

    public init(groups: [DuplicateGroup], filesConsidered: Int, bytesHashed: Int64 = 0, skippedUnreadable: Int = 0,
                skippedCloudOnly: Int = 0, hardLinkSetsIgnored: Int = 0, wasCancelled: Bool = false) {
        self.groups = groups
        self.filesConsidered = filesConsidered
        self.bytesHashed = bytesHashed
        self.skippedUnreadable = skippedUnreadable
        self.skippedCloudOnly = skippedCloudOnly
        self.hardLinkSetsIgnored = hardLinkSetsIgnored
        self.wasCancelled = wasCancelled
    }
}

/// Exact duplicate detection: size → hard-link collapse → sampled fingerprint → streaming SHA-256.
///
/// Only regular files are considered (no symlinks, no package internals). Files whose contents are
/// not local (iCloud "dataless" files) are skipped so that hashing never triggers downloads.
public struct DuplicateFinder: Sendable {
    public var minimumSize: Int64
    public var sampleSize: Int
    public var chunkSize: Int

    public init(minimumSize: Int64 = 1 << 20, sampleSize: Int = 64 * 1024, chunkSize: Int = 1 << 20) {
        self.minimumSize = minimumSize
        self.sampleSize = sampleSize
        self.chunkSize = chunkSize
    }

    struct Candidate {
        var path: String
        var stat: FileStat
    }

    public func find(roots: [String], isCancelled: @Sendable () -> Bool = { false },
                     progress: @Sendable (_ phase: String, _ done: Int, _ total: Int) -> Void = { _, _, _ in }) -> DuplicateScanResult {
        var bySize: [Int64: [Candidate]] = [:]
        var considered = 0
        var cloudOnly = 0
        var cancelled = false

        // 1. Collect regular files above the threshold (each location once, even if roots overlap).
        for root in PathTools.removingNested(roots) {
            try? FTSWalker.walk(root: root) { entry in
                if isCancelled() { cancelled = true; return .stop }
                switch entry.visit {
                case .directoryPre:
                    let ext = (entry.path as NSString).pathExtension.lowercased()
                    if entry.level > 0, CategoryClassifier.packageExtensions.contains(ext) { return .skipChildren }
                    let name = (entry.path as NSString).lastPathComponent
                    if entry.level > 0, name == ".Trash" || name == ".git" { return .skipChildren }
                case .file:
                    guard let st = entry.stat, st.identity.type == .regular, st.logicalSize >= minimumSize else { return .proceed }
                    if st.isDataless { cloudOnly += 1; return .proceed }
                    considered += 1
                    bySize[st.logicalSize, default: []].append(Candidate(path: entry.path, stat: st))
                    if considered % 2_000 == 0 { progress(String(localized: "Listing files", bundle: .module), considered, 0) }
                default:
                    break
                }
                return .proceed
            }
        }

        // 2. Collapse hard links; keep only sizes with ≥2 distinct inodes.
        var hardLinkSets = 0
        var sizeGroups: [(size: Int64, files: [DuplicateFile])] = []
        for (size, candidates) in bySize where candidates.count > 1 {
            var byInode: [String: DuplicateFile] = [:]
            var order: [String] = []
            for c in candidates.sorted(by: { $0.path < $1.path }) {
                let key = "\(c.stat.identity.device):\(c.stat.identity.inode)"
                if var existing = byInode[key] {
                    existing.hardLinkPaths.append(c.path)
                    byInode[key] = existing
                } else {
                    byInode[key] = DuplicateFile(path: c.path, identity: c.stat.identity, logicalSize: c.stat.logicalSize,
                                                 allocatedSize: c.stat.allocatedSize, modified: c.stat.modified, hardLinkPaths: [])
                    order.append(key)
                }
            }
            hardLinkSets += byInode.values.filter { !$0.hardLinkPaths.isEmpty }.count
            let distinct = order.compactMap { byInode[$0] }
            if distinct.count > 1 { sizeGroups.append((size, distinct)) }
        }

        // 3. Sampled fingerprint, then 4. full hash — both streaming and cancellable.
        var groups: [DuplicateGroup] = []
        var bytesHashed: Int64 = 0
        var unreadable = 0
        let totalCandidates = sizeGroups.reduce(0) { $0 + $1.files.count }
        var processed = 0
        // Progress at most ~10 times a second: thousands of small candidates would otherwise post
        // one main-actor update per file.
        var lastReport = Date.distantPast
        outer: for (size, files) in sizeGroups.sorted(by: { $0.size > $1.size }) {
            var bySample: [String: [DuplicateFile]] = [:]
            for file in files {
                if isCancelled() { cancelled = true; break outer }
                processed += 1
                let now = Date()
                if processed == totalCandidates || now.timeIntervalSince(lastReport) >= 0.1 {
                    lastReport = now
                    progress(String(localized: "Comparing contents", bundle: .module), processed, totalCandidates)
                }
                guard let sample = sampleHash(file.path, size: size) else { unreadable += 1; continue }
                bytesHashed += Int64(min(Int64(sampleSize * 2), size))
                bySample[sample, default: []].append(file)
            }
            for (_, sampleMatches) in bySample where sampleMatches.count > 1 {
                var byHash: [String: [DuplicateFile]] = [:]
                for file in sampleMatches {
                    if isCancelled() { cancelled = true; break outer }
                    guard let hash = fullHash(file.path, isCancelled: isCancelled) else { unreadable += 1; continue }
                    bytesHashed += size
                    byHash[hash, default: []].append(file)
                }
                for (hash, matches) in byHash where matches.count > 1 {
                    groups.append(DuplicateGroup(sha256: hash, size: size, files: matches))
                }
            }
        }
        return DuplicateScanResult(groups: groups.sorted { $0.potentialSavings > $1.potentialSavings }, filesConsidered: considered,
                                   bytesHashed: bytesHashed, skippedUnreadable: unreadable, skippedCloudOnly: cloudOnly,
                                   hardLinkSetsIgnored: hardLinkSets, wasCancelled: cancelled)
    }

    /// Opens without following symlinks.
    private func openNoFollow(_ path: String) -> Int32 {
        open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }

    func sampleHash(_ path: String, size: Int64) -> String? {
        let fd = openNoFollow(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: sampleSize)
        let head = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, sampleSize, 0) }
        guard head >= 0 else { return nil }
        hasher.update(data: buffer[0..<head])
        if size > Int64(sampleSize * 2) {
            let tail = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, sampleSize, off_t(size) - off_t(sampleSize)) }
            guard tail >= 0 else { return nil }
            hasher.update(data: buffer[0..<tail])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func fullHash(_ path: String, isCancelled: () -> Bool) -> String? {
        let fd = openNoFollow(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var offset: off_t = 0
        while true {
            if isCancelled() { return nil }
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunkSize, offset) }
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
            offset += off_t(n)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension CleanupPlanner {
    public enum DuplicatePlanError: Error, Equatable {
        /// Every copy of a group was selected; at least one must be kept.
        case wouldRemoveAllCopies(groupID: String)
    }

    /// Plans removal of user-selected duplicate copies. Refuses any selection that leaves a group
    /// without a remaining copy, and re-checks that each copy still exists unchanged.
    public static func duplicateCandidates(groups: [DuplicateGroup], selectedPaths: Set<String>, policy: SafetyPolicy) throws -> (candidates: [CleanupCandidate], rejected: [(String, String)]) {
        var candidates: [CleanupCandidate] = []
        var rejected: [(String, String)] = []
        for group in groups {
            let chosen = group.files.filter { selectedPaths.contains($0.path) }
            guard !chosen.isEmpty else { continue }
            guard chosen.count < group.files.count else { throw DuplicatePlanError.wouldRemoveAllCopies(groupID: group.id) }
            // At least one copy that stays must still be there, unchanged — otherwise removing the
            // others could remove the last copy.
            let kept = group.files.filter { !selectedPaths.contains($0.path) }.map(\.snapshot)
            let keptStillThere = kept.contains(where: \.isUnchanged)
            guard keptStillThere else {
                for file in chosen {
                    rejected.append((file.path, String(localized: "The copy that would be kept is gone or changed since the duplicate search. Search again.", bundle: .module)))
                }
                continue
            }
            for file in chosen {
                if let reason = policy.evaluate(file.path, intent: .userSelected).reason {
                    rejected.append((file.path, reason))
                    continue
                }
                guard file.snapshot.isUnchanged else {
                    rejected.append((file.path, String(localized: "It changed or was removed since the duplicate check.", bundle: .module)))
                    continue
                }
                let others = group.files.filter { $0.path != file.path }.map(\.path)
                var candidate = CleanupCandidate(
                    path: file.path, title: file.name, reason: String(localized: "Identical content (SHA-256) to \(others.count) other file(s), e.g. \(others.first ?? "")", bundle: .module),
                    category: .duplicate, risk: .review, source: .duplicate(groupID: group.id), logicalSize: file.logicalSize,
                    allocatedSize: file.allocatedSize, itemCount: 1, modified: file.modified, identity: file.identity,
                    regenerationImpact: file.hardLinkPaths.isEmpty ? nil : String(localized: "This file has hard links; removing one path frees no space.", bundle: .module),
                    evidence: [Evidence(.contentHashMatch, String(localized: "SHA-256 \(group.sha256.prefix(16))… matches", bundle: .module))], isPreselected: true)
                candidate.expectedContent = file.snapshot
                candidate.requiredCopies = kept
                candidates.append(candidate)
            }
        }
        return (candidates, rejected)
    }
}
