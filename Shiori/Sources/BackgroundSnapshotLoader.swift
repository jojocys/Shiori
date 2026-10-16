import Combine
import Foundation

/// One background operation at a time; only the newest requested generation
/// may publish. Repeated timer ticks do not build an unbounded scan queue.
@MainActor
final class BackgroundSnapshotLoader<Input: Equatable & Sendable, Output: Sendable>: ObservableObject {
    @Published private(set) var isLoading = false
    private let operation: @Sendable (Input) async -> Output
    private let publish: @MainActor (Output) -> Void
    private var activeTask: Task<Void, Never>?
    private var desiredInput: Input?
    private var queued: (input: Input, generation: UInt64)?
    private var generation: UInt64 = 0

    init(operation: @escaping @Sendable (Input) async -> Output,
         publish: @escaping @MainActor (Output) -> Void) {
        self.operation = operation
        self.publish = publish
    }

    func request(_ input: Input, force: Bool = false) {
        if activeTask != nil, !force, desiredInput == input { return }
        generation &+= 1
        desiredInput = input
        isLoading = true
        if activeTask != nil {
            queued = (input, generation)
        } else {
            start(input, generation: generation)
        }
    }

    func cancel() {
        generation &+= 1
        queued = nil
        desiredInput = nil
        isLoading = false
        // Synchronous filesystem/process work may not stop immediately. Keep
        // its slot occupied until it returns, while invalidating its result.
        activeTask?.cancel()
    }

    private func start(_ input: Input, generation token: UInt64) {
        let operation = self.operation
        activeTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                await operation(input)
            }.value
            self?.complete(result, input: input, generation: token)
        }
    }

    private func complete(_ result: Output, input: Input, generation token: UInt64) {
        activeTask = nil
        if generation == token, desiredInput == input { publish(result) }
        // A publisher may synchronously request another input.
        guard activeTask == nil else { return }
        if let next = queued {
            queued = nil
            start(next.input, generation: next.generation)
        } else {
            desiredInput = nil
            isLoading = false
        }
    }
}
