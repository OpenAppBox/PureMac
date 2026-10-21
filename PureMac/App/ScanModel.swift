import Foundation
import Observation
import PureMacKit

/// Scan lifecycle and the Overview's summary data, all read from the real local index.
@Observable
final class ScanModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case cancelling
    }

    struct ThroughputSample: Identifiable, Hashable {
        var id: Int
        var elapsed: Double
        var filesPerSecond: Double
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = ScanProgress()
    /// Rolling files-per-second history of the running scan (real deltas, last ~90 samples).
    private(set) var throughput: [ThroughputSample] = []
    private(set) var peakFilesPerSecond: Double = 0
    /// Set briefly when a scan finishes, to play the completion transition.
    private(set) var justFinished: ScanSession?
    /// Newest session with a browsable index.
    private(set) var latestSession: ScanSession?
    /// Newest session of any status (to surface failures / interruptions).
    private(set) var lastAttempt: ScanSession?
    private(set) var categoryTotals: [CategoryTotal] = []
    private(set) var largestFolders: [FileRecord] = []
    private(set) var largestFiles: [FileRecord] = []
    /// Files of at least 100 MB not modified for a year (the likeliest forgotten space).
    private(set) var oldLargeFiles: [FileRecord] = []
    /// Whether every root of the latest scan is on the startup disk (then its categories can be
    /// drawn as part of that disk). Computed on reload, never while rendering.
    private(set) var scansOnlyStartupVolume = false
    private(set) var issueCounts: [ScanIssueKind: Int] = [:]
    private(set) var startupVolume: VolumeInfo?
    private(set) var scannedVolumes: [VolumeInfo] = []
    private(set) var changes: [(path: String, previous: Int64, current: Int64)] = []
    /// Two-level map (root's children and grandchildren) for the Overview sunburst.
    private(set) var mapNodes: [SunburstNode] = []
    private(set) var mapRoot: FileRecord?
    var errorMessage: String?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool { phase != .idle }

    /// The latest browsable scan covered the whole startup disk (Data volume), not just the home folder.
    var latestScanCoveredEntireDisk: Bool { latestSession?.roots.contains { $0.kind == .dataVolume } ?? false }

    /// Switches the scan scope (remembered in Settings) and starts a scan.
    func start(entireDisk: Bool) {
        guard let app else { return }
        app.settings.scanEntireDataVolume = entireDisk
        start()
    }

    func attach(app: AppModel) { self.app = app }

    func start() {
        guard phase == .idle, let app, app.store != nil else { return }
        let roots = app.settings.scanRoots
        // In the App Sandbox every root needs a folder grant (asked once, remembered). A whole-disk
        // scan needs the startup disk itself, picked at the top of the Open panel.
        for root in roots where !app.access.hasAccess(to: root.path) {
            let granted: Bool
            let name: String
            if root.kind == .dataVolume {
                name = startupDiskName
                granted = app.access.request("/", message: String(localized: "To scan the entire disk, choose “\(name)” and click Allow Access. Only names, sizes and dates are read."))
            } else {
                name = FileManager.default.displayName(atPath: root.path)
                granted = app.access.request(root.path, message: String(localized: "Choose “\(name)” so PureMac can measure it. Only names, sizes and dates are read."))
            }
            guard granted else {
                errorMessage = String(localized: "PureMac can’t scan “\(name)” without access to it.")
                return
            }
        }
        phase = .scanning
        progress = ScanProgress()
        throughput = []
        peakFilesPerSecond = 0
        justFinished = nil
        errorMessage = nil
        let threshold = Int64(app.settings.smallFileThresholdKB) * 1024
        let scanner = StorageScanner(databaseURL: app.databaseURL)
        task = Task {
            let excluded = (try? await app.store?.exclusions(scope: .scan).map(\.path)) ?? []
            let config = ScanConfiguration(roots: roots, excludedPaths: excluded, smallFileThreshold: threshold)
            do {
                let session = try await scanner.scan(config) { progress in
                    Task { @MainActor in
                        guard self.phase != .idle else { return }
                        self.record(progress)
                    }
                }
                if session.status == .cancelled { self.errorMessage = nil }
                if session.status == .completed { self.justFinished = session }
                try? await app.store?.pruneIndexes(keep: 2)
            } catch {
                self.errorMessage = String(localized: "The scan stopped because of an error: \(error.localizedDescription)")
            }
            self.phase = .idle
            await self.reload()
            await app.explorer.sessionDidChange()
        }
    }

    private func record(_ next: ScanProgress) {
        let dt = next.elapsed - progress.elapsed
        if dt > 0.05 {
            let rate = Double(next.filesVisited - progress.filesVisited) / dt
            // Light smoothing so the chart reads as a trend, not jitter.
            let smoothed = throughput.last.map { $0.filesPerSecond * 0.5 + rate * 0.5 } ?? rate
            throughput.append(ThroughputSample(id: (throughput.last?.id ?? 0) + 1, elapsed: next.elapsed, filesPerSecond: max(0, smoothed)))
            if throughput.count > 90 { throughput.removeFirst(throughput.count - 90) }
            peakFilesPerSecond = max(peakFilesPerSecond, smoothed)
        }
        progress = next
    }

    func acknowledgeFinish() { justFinished = nil }

    /// Drops a folder whose own subfolder in the list holds nearly all of it (90% or more):
    /// `/Users` next to `/Users/alex`, `/System` next to `/System/Library`. The more specific
    /// folder says more, and the list doesn't show the same space twice.
    /// Folders inside packages (an app's `Contents`) are left out: the app itself is listed.
    static func withoutPassThroughFolders(_ folders: [FileRecord]) -> [FileRecord] {
        let visible = folders.filter { !isInsidePackage($0.path) }
        return visible.filter { folder in
            !visible.contains { $0.parentID == folder.id && Double($0.allocatedSize) >= Double(folder.allocatedSize) * 0.9 }
        }
    }

    private static func isInsidePackage(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains {
            CategoryClassifier.packageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    #if DEBUG
    /// Test-only hook for snapshot rendering of the scanning state. Never called by the app UI.
    func _setFixtureScanState(progress: ScanProgress, throughput: [ThroughputSample]) {
        guard app?.isHostingTests == true || app?.isDemo == true else { return }
        phase = .scanning
        self.progress = progress
        self.throughput = throughput
        peakFilesPerSecond = throughput.map(\.filesPerSecond).max() ?? 0
    }

    /// Demo mode: the startup disk shown instead of the real one.
    @ObservationIgnored var _demoVolume: VolumeInfo?

    func _clearFixtureScanState() {
        guard app?.isHostingTests == true || app?.isDemo == true else { return }
        phase = .idle
    }
    #endif

    var currentFilesPerSecond: Double { throughput.last?.filesPerSecond ?? 0 }

    func cancel() {
        guard phase == .scanning else { return }
        phase = .cancelling
        task?.cancel()
    }

    func reload() async {
        startupVolume = VolumeInspector.volume(containing: URL(fileURLWithPath: "/"))
        #if DEBUG
        if let demo = _demoVolume { startupVolume = demo }
        #endif
        guard let store = app?.store else { return }
        do {
            lastAttempt = try await store.sessions(limit: 1).first
            latestSession = try await store.latestBrowsableSession()
            if let session = latestSession {
                categoryTotals = try await store.categoryTotals(sessionID: session.id)
                largestFolders = Array(Self.withoutPassThroughFolders(
                    try await store.largestDirectories(sessionID: session.id, maxDepth: 3, limit: 40)).prefix(12))
                let devices = session.roots.compactMap { try? FileStat.lstat($0.path).get().identity.device }
                scansOnlyStartupVolume = !devices.isEmpty && devices.count == session.roots.count
                    && devices.allSatisfy { $0 == startupVolume?.deviceID }
                // Items moved to the Trash since the scan are already left out (and subtracted) by the index.
                largestFiles = try await store.files(sessionID: session.id, query: { var q = FileQuery(); q.limit = 16; return q }())
                oldLargeFiles = try await store.files(sessionID: session.id, query: {
                    var q = FileQuery()
                    q.limit = 500
                    q.minimumAllocated = 100_000_000
                    q.modifiedBefore = Calendar.current.date(byAdding: .year, value: -1, to: Date())
                    return q
                }())
                issueCounts = try await store.issueCounts(sessionID: session.id)
                changes = try await store.topLevelChanges(limit: 8)
                scannedVolumes = uniqueVolumes(for: session.roots)
                let roots = try await store.roots(sessionID: session.id)
                mapRoot = roots.first
                if let root = roots.first {
                    mapNodes = try await Self.mapNodes(for: root, store: store)
                }
            } else {
                mapNodes = []
                mapRoot = nil
                categoryTotals = []
                largestFolders = []
                largestFiles = []
                oldLargeFiles = []
                scansOnlyStartupVolume = false
                issueCounts = [:]
                changes = []
                scannedVolumes = []
            }
        } catch {
            errorMessage = String(localized: "Could not read scan results: \(error.localizedDescription)")
        }
    }

    /// Builds sunburst nodes for a folder: its 14 largest children, each with up to 10 children.
    static func mapNodes(for root: FileRecord, store: LocalStore) async throws -> [SunburstNode] {
        var nodes: [SunburstNode] = []
        for child in try await store.children(of: root.id, limit: 14) where child.allocatedSize > 0 {
            var node = SunburstNode(id: child.id, name: child.name, value: Double(child.allocatedSize), color: child.mapCategory.tint, isContainer: child.isContainer)
            if child.isContainer {
                node.children = try await store.children(of: child.id, limit: 10).map {
                    SunburstNode(id: $0.id, name: $0.name, value: Double($0.allocatedSize), color: $0.mapCategory.tint, isContainer: $0.isContainer)
                }
            }
            nodes.append(node)
        }
        return nodes
    }

    private func uniqueVolumes(for roots: [ScanRoot]) -> [VolumeInfo] {
        var seen = Set<String>()
        return roots.compactMap { VolumeInspector.volume(containing: URL(fileURLWithPath: $0.path)) }
            .filter { seen.insert($0.id).inserted }
    }
}
