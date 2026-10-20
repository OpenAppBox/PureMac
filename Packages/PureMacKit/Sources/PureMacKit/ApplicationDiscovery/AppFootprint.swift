import CoreServices
import Foundation

/// Size and usage facts about one installed app, measured in the background for list views.
public struct AppMeasurement: Sendable, Hashable {
    public var path: String
    /// The bundle itself, measured with `DirectorySizer` (hard links counted once).
    public var bundle: SizeSummary
    /// When the app was last opened, as recorded by Spotlight (`kMDItemLastUsedDate`). `nil` when
    /// Spotlight has no record (never opened, indexing disabled, or excluded volume).
    public var lastUsed: Date?

    public init(path: String, bundle: SizeSummary, lastUsed: Date?) {
        self.path = path
        self.bundle = bundle
        self.lastUsed = lastUsed
    }
}

public enum AppFootprint {
    /// Spotlight's last-used date for an item. Metadata only; local; no file contents are read.
    public static func lastUsedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Measures each app bundle (and reads its last-used date) with bounded concurrency, yielding
    /// results as they finish so a list can fill in progressively. Cancelling the consuming task
    /// stops the remaining work.
    public static func measure(paths: [String], maxConcurrency: Int = 4) -> AsyncStream<AppMeasurement> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: AppMeasurement.self) { group in
                    var iterator = paths.makeIterator()
                    func addNext() -> Bool {
                        guard let path = iterator.next() else { return false }
                        group.addTask {
                            let size = DirectorySizer.measure(path, isCancelled: { Task.isCancelled })
                            return AppMeasurement(path: path, bundle: size, lastUsed: lastUsedDate(path: path))
                        }
                        return true
                    }
                    for _ in 0..<max(1, maxConcurrency) where !addNext() { break }
                    while let result = await group.next() {
                        if Task.isCancelled { break }
                        continuation.yield(result)
                        _ = addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Finds the associated files of every app (sizes included) with bounded concurrency, yielding
    /// one result per app. Used to show each app's full footprint without opening it.
    /// `knownSizes` (e.g. the bundle sizes from `measure`) are reused, not measured again.
    public static func associations(for apps: [InstalledApp], allApps: [InstalledApp], maxConcurrency: Int = 2,
                                    knownSizes: [String: SizeSummary] = [:],
                                    finder: AssociationFinder = AssociationFinder()) -> AsyncStream<(String, [AppAssociation])> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: (String, [AppAssociation]).self) { group in
                    var iterator = apps.makeIterator()
                    func addNext() -> Bool {
                        guard let app = iterator.next() else { return false }
                        group.addTask { (app.path, await finder.associations(for: app, allApps: allApps, knownSizes: knownSizes)) }
                        return true
                    }
                    for _ in 0..<max(1, maxConcurrency) where !addNext() { break }
                    while let result = await group.next() {
                        if Task.isCancelled { break }
                        continuation.yield(result)
                        _ = addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Array where Element == AppAssociation {
    /// Bytes of associated items other than the bundle itself. Shared and protected items are
    /// excluded because they are never removed with an app.
    public var associatedDataBytes: Int64 {
        filter { $0.kind != .appBundle && $0.confidence != .shared && $0.confidence != .protected }
            .reduce(0) { $0 + ($1.allocatedSize ?? 0) }
    }
}
