import Foundation

/// Owns one Steam operation so file writes cannot race with delete or launch.
@MainActor
final class SteamOperationCoordinator {
    enum Kind: Sendable { case importing, deleting, launching, stopping }
    struct Lease: Equatable, Sendable {
        let id = UUID()
        let kind: Kind
    }
    private(set) var active: Lease?
    private var task: Task<Void, Never>?

    func begin(_ kind: Kind) -> Lease? {
        guard active == nil else { return nil }
        let lease = Lease(kind: kind)
        active = lease
        return lease
    }

    func track(_ task: Task<Void, Never>, for lease: Lease) {
        guard active == lease else { task.cancel(); return }
        self.task = task
    }

    func finish(_ lease: Lease) {
        guard active == lease else { return }
        active = nil
        task = nil
    }

    /// File mutations finish before a new operation can start. Only launch
    /// requests can be cancelled by the Stop action.
    @discardableResult
    func cancelLaunch() -> Bool {
        guard active?.kind == .launching else { return false }
        task?.cancel()
        task = nil
        active = nil
        return true
    }
}
