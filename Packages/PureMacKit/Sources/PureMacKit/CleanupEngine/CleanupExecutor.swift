import Foundation

public enum CleanupError: Error, Equatable, CustomStringConvertible {
    case operationInProgress
    case emptyPlan
    /// There is no local database, so nothing could be recorded. Nothing was moved.
    case journalUnavailable
    /// The history could not be prepared. Nothing was moved.
    case journalFailed(String)

    public var description: String {
        switch self {
        case .operationInProgress: String(localized: "Another cleanup is already running.", bundle: .module)
        case .emptyPlan: String(localized: "Nothing is selected.", bundle: .module)
        case .journalUnavailable:
            String(localized: "PureMac's local database is not available, so this cleanup could not be recorded. Nothing was moved.", bundle: .module)
        case .journalFailed(let reason):
            String(localized: "PureMac could not save the history for this cleanup, so nothing was moved. (\(reason))", bundle: .module)
        }
    }
}

/// Executes reviewed plans, one at a time.
///
/// Order of work: the operation and every item are journaled as "pending" in one transaction →
/// per item: preflight (scope, identity, ownership, activity) → rename into Trash → verify the moved
/// object's identity → journal the outcome. Nothing moves unless the journal is committed first, and
/// the run stops at the first outcome that cannot be recorded. Cancellation is honored between
/// items; remaining items are reported as skipped. No item is ever permanently deleted.
public actor CleanupExecutor {
    private let store: LocalStore?
    private let remover: any FileRemover
    private let running: any RunningAppChecking
    private var policy: SafetyPolicy
    private var busy = false

    public init(store: LocalStore?, remover: any FileRemover = SystemTrashRemover(), policy: SafetyPolicy,
                running: any RunningAppChecking = WorkspaceRunningAppChecker()) {
        self.store = store
        self.remover = remover
        self.policy = policy
        self.running = running
    }

    public func update(policy: SafetyPolicy) { self.policy = policy }

    public var isBusy: Bool { busy }

    /// Throws only before anything is moved (busy, empty plan, journal unavailable or not
    /// preparable). Once items move, problems are reported in the returned result.
    public func execute(_ plan: CleanupPlan, detailedHistory: Bool = true,
                        isCancelled: @Sendable () -> Bool = { false },
                        progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> CleanupResult {
        guard !busy else { throw CleanupError.operationInProgress }
        guard !plan.items.isEmpty else { throw CleanupError.emptyPlan }
        guard let store else { throw CleanupError.journalUnavailable }
        busy = true
        defer { busy = false }

        let started = Date()
        let measurePath = plan.items.first.map { ($0.path as NSString).deletingLastPathComponent } ?? PathTools.userHome
        let freeBefore = VolumeInspector.freeBytes(atPath: measurePath) ?? VolumeInspector.freeBytes(atPath: PathTools.userHome)
        let journal: CleanupJournal
        do {
            journal = try await store.beginOperation(plan: plan, detailed: detailedHistory)
        } catch {
            throw CleanupError.journalFailed(String(describing: error))
        }
        guard journal.itemIDs.count == plan.items.count else {
            throw CleanupError.journalFailed(String(describing: SQLiteChangeCountError(expected: plan.items.count, actual: journal.itemIDs.count)))
        }
        let preflight = Preflight(policy: policy)
        var outcomes: [CleanupItemOutcome] = []
        var cancelled = false
        var journalProblem: String?

        for (index, item) in plan.items.enumerated() {
            progress(index, plan.items.count)
            let outcome: CleanupItemOutcome
            if journalProblem != nil {
                outcome = CleanupItemOutcome(path: item.path, status: .skipped, allocatedSize: item.allocatedSize, logicalSize: item.logicalSize,
                                             message: String(localized: "Not attempted: PureMac stopped because it could not save its history.", bundle: .module))
            } else if cancelled || isCancelled() || Task.isCancelled {
                cancelled = true
                outcome = CleanupItemOutcome(path: item.path, status: .skipped, allocatedSize: item.allocatedSize,
                                             logicalSize: item.logicalSize, message: String(localized: "Cancelled before this item.", bundle: .module))
            } else {
                let runningIDs = await running.runningBundleIdentifiers()
                let runningPaths = await running.runningBundlePaths()
                switch preflight.check(item, runningIdentifiers: runningIDs, runningPaths: runningPaths) {
                case .skip(let reason):
                    outcome = CleanupItemOutcome(path: item.path, status: .skipped, allocatedSize: item.allocatedSize,
                                                 logicalSize: item.logicalSize, message: reason)
                case .proceed:
                    outcome = move(item)
                }
            }
            outcomes.append(outcome)
            // Items skipped after a journal failure stay "pending" in the database (it is failing);
            // History explains that state.
            guard journalProblem == nil else { continue }
            do {
                try await store.journalOutcome(itemID: journal.itemIDs[index], outcome: outcome, detailed: detailedHistory)
            } catch {
                journalProblem = String(localized: "PureMac could not record what happened to \(item.path), so it stopped before the remaining items. (\(String(describing: error)))", bundle: .module)
            }
        }
        progress(plan.items.count, plan.items.count)

        // Measured on the same volume as `freeBefore`, or the delta would compare two disks.
        let freeAfter = VolumeInspector.freeBytes(atPath: measurePath) ?? VolumeInspector.freeBytes(atPath: PathTools.userHome)
        var result = CleanupResult(planID: plan.id, operationID: journal.operationID, mode: plan.mode, startedAt: started,
                                   finishedAt: Date(), outcomes: outcomes, wasCancelled: cancelled,
                                   freeSpaceBefore: freeBefore, freeSpaceAfter: freeAfter, journalProblem: journalProblem)
        do {
            try await store.finishOperation(id: journal.operationID, result: result)
        } catch {
            let summary = String(localized: "PureMac could not save the summary of this cleanup; History will show it as interrupted. (\(String(describing: error)))", bundle: .module)
            result.journalProblem = [journalProblem, summary].compactMap { $0 }.joined(separator: "\n")
        }
        return result
    }

    private func move(_ item: CleanupCandidate) -> CleanupItemOutcome {
        do {
            let destination = try remover.moveToTrash(item.path)
            var message: String?
            if case .success(let moved) = FileStat.lstat(destination), !moved.identity.isSameObject(as: item.identity) {
                message = String(localized: "Moved, but the item in the Trash does not match the reviewed item. Check the Trash.", bundle: .module)
            }
            return CleanupItemOutcome(path: item.path, status: .movedToTrash, trashPath: destination,
                                      allocatedSize: item.allocatedSize, logicalSize: item.logicalSize, message: message)
        } catch {
            return CleanupItemOutcome(path: item.path, status: .failed, allocatedSize: item.allocatedSize,
                                      logicalSize: item.logicalSize, message: Self.explain(error, item: item))
        }
    }

    static func explain(_ error: Error, item: CleanupCandidate) -> String {
        let ns = error as NSError
        let permission = (ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError))
            || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)))
            || ((ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && ($0.code == Int(EACCES) || $0.code == Int(EPERM)) } ?? false)
        if permission {
            if item.source.safetyIntent == .appBundleRemoval {
                return String(localized: "macOS did not allow PureMac to move this app. It may be owned by the system or protected by “App Management”. Allow PureMac under Privacy & Security → App Management, or drag the app to the Trash in Finder.", bundle: .module)
            }
            return String(localized: "Permission denied. PureMac does not request administrator rights; you can move it in Finder instead.", bundle: .module)
        }
        return ns.localizedDescription
    }

    // MARK: Restore

    public enum RestoreOutcome: Sendable, Equatable {
        case restored
        /// The item is back at its original location, but History could not record that.
        case restoredWithHistoryWarning(String)
        case notPossible(String)

        public var isRestored: Bool { if case .notPossible = self { false } else { true } }
    }

    /// Puts an item back from the Trash to its original location, when it is safe to do so.
    public func restore(_ record: CleanupItemRecord) async -> RestoreOutcome {
        guard !busy else { return .notPossible(String(localized: "Another operation is running.", bundle: .module)) }
        guard record.status == .movedToTrash else { return .notPossible(String(localized: "This item was not moved to the Trash.", bundle: .module)) }
        guard let original = record.originalPath, let trashed = record.trashPath else {
            return .notPossible(String(localized: "Detailed history was off, so the original location is unknown. Use Finder’s Put Back.", bundle: .module))
        }
        guard case .success(let st) = FileStat.lstat(trashed) else {
            return .notPossible(String(localized: "It is no longer in the Trash (the Trash may have been emptied).", bundle: .module))
        }
        if let identity = record.identity, !(st.identity.device == identity.device && st.identity.inode == identity.inode) {
            return .notPossible(String(localized: "The item in the Trash is not the one PureMac moved.", bundle: .module))
        }
        if case .success = FileStat.lstat(original) {
            return .notPossible(String(localized: "Something else now exists at the original location.", bundle: .module))
        }
        let parent = (original as NSString).deletingLastPathComponent
        guard case .success(let parentStat) = FileStat.lstat(parent), parentStat.identity.type == .directory else {
            return .notPossible(String(localized: "The original folder no longer exists.", bundle: .module))
        }
        // Serialized with cleanups: none can start while this one is recorded.
        busy = true
        defer { busy = false }
        do {
            try FileManager.default.moveItem(atPath: trashed, toPath: original)
        } catch {
            return .notPossible(error.localizedDescription)
        }
        guard let store else {
            return .restoredWithHistoryWarning(String(localized: "Put back, but History could not be updated because PureMac's local database is not available.", bundle: .module))
        }
        do {
            try await store.markRestored(itemID: record.id)
            return .restored
        } catch {
            return .restoredWithHistoryWarning(String(localized: "Put back, but History could not be updated and may still list it as in the Trash. (\(String(describing: error)))", bundle: .module))
        }
    }
}
