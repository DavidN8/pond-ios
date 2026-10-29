//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

/// Runs at most `limit` operations at once; the others wait their turn, in order. A limit of 1 is a lock.
final class TaskLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    
    init(limit: Int) {
        self.limit = limit
    }
    
    /// Waits for a turn, even when the calling task is cancelled: `operation` checks for that itself.
    func run<T>(_ operation: () async -> T) async -> T {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        defer {
            if waiting.isEmpty {
                running -= 1
            } else {
                waiting.removeFirst().resume()
            }
        }
        return await operation()
    }
}

/// The first value of `publisher` that satisfies `condition`, the current one included; nil once `timeout` passes, once `isEnded`
/// holds, or when the calling task is cancelled first.
nonisolated func firstValue<Output: Sendable>(of publisher: CurrentValuePublisher<Output, Never>,
                                              timeout: Duration? = nil,
                                              until isEnded: CurrentValuePublisher<Bool, Never>? = nil,
                                              where condition: @escaping @Sendable (Output) -> Bool) async -> Output? {
    await withTaskGroup(of: Output?.self) { group in
        group.addTask {
            await publisher.values.first(where: condition)
        }
        if let timeout {
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
        }
        if let isEnded {
            group.addTask {
                _ = await isEnded.values.first { $0 }
                return nil
            }
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
