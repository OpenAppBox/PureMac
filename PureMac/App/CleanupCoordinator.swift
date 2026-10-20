import Foundation
import Observation
import PureMacKit

/// The single gateway for every destructive action in the app. Presents the review sheet, runs the
/// executor, and refuses to start a second operation while one is running.
@Observable
final class CleanupCoordinator {
    enum Stage: Equatable {
        case review
        case running(done: Int, total: Int)
        case finished(CleanupResult)
    }

    var activePlan: CleanupPlan?
    private(set) var stage: Stage = .review
    /// Items the planner refused (shown in the review so nothing disappears silently).
    private(set) var rejected: [(path: String, reason: String)] = []

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var executor: CleanupExecutor?
    @ObservationIgnored private var cancelFlag = CancellationFlag()
    @ObservationIgnored private var completion: ((CleanupResult) -> Void)?

    var isRunning: Bool { if case .running = stage { true } else { false } }

    func attach(app: AppModel) {
        self.app = app
        executor = CleanupExecutor(store: app.store, policy: SafetyPolicy.forCurrentUser(ownDataDirectory: app.databaseURL.deletingLastPathComponent()))
    }

    /// Shows the review sheet for a plan. Nothing is modified until the user confirms.
    func present(_ plan: CleanupPlan, rejected: [(String, String)] = [], completion: ((CleanupResult) -> Void)? = nil) {
        guard !isRunning else { return }
        self.rejected = rejected.map { (path: $0.0, reason: $0.1) }
        self.completion = completion
        stage = .review
        activePlan = plan
    }

    /// Runs the reviewed plan. `reviewed` may only narrow the presented plan (items the user
    /// unticked in the review); it can never add anything.
    func confirm(_ reviewed: CleanupPlan? = nil) {
        guard let presented = activePlan, case .review = stage, let app, let executor else { return }
        var plan = presented
        if let reviewed, reviewed.id == presented.id {
            let allowed = Set(reviewed.items.map(\.id))
            plan.items = presented.items.filter { allowed.contains($0.id) }
        }
        guard !plan.items.isEmpty else { return }
        stage = .running(done: 0, total: plan.items.count)
        cancelFlag = CancellationFlag()
        let flag = cancelFlag
        let detailed = app.settings.keepDetailedHistory
        Task {
            await executor.update(policy: await app.safetyPolicy())
            do {
                let result = try await executor.execute(plan, detailedHistory: detailed, isCancelled: { flag.isCancelled }) { [weak self] done, total in
                    Task { @MainActor in
                        guard let self, case .running = self.stage else { return }
                        self.stage = .running(done: done, total: total)
                    }
                }
                self.stage = .finished(result)
                self.completion?(result)
                await app.cleanupDidFinish(result)
            } catch {
                // The executor throws only before it moves anything (busy, or no journal), so
                // "nothing moved" is exact here.
                let reason = (error as? CleanupError)?.description ?? error.localizedDescription
                let failed = CleanupResult(planID: plan.id, operationID: nil, mode: plan.mode, startedAt: Date(), finishedAt: Date(),
                                           outcomes: plan.items.map { CleanupItemOutcome(path: $0.path, status: .skipped, allocatedSize: $0.allocatedSize, logicalSize: $0.logicalSize, message: reason) },
                                           wasCancelled: false, freeSpaceBefore: nil, freeSpaceAfter: nil, journalProblem: reason)
                self.stage = .finished(failed)
            }
        }
    }

    func cancelRunning() { cancelFlag.cancel() }

    func dismiss() {
        guard !isRunning else { return }
        activePlan = nil
        stage = .review
        rejected = []
        completion = nil
    }

    func restore(_ record: CleanupItemRecord) async -> CleanupExecutor.RestoreOutcome {
        guard let executor else { return .notPossible(String(localized: "Put Back is not available right now.")) }
        return await executor.restore(record)
    }
}
