// SPDX-License-Identifier: MIT
/*
 * CollisionPrompt — v0.9.2 Phase G.
 *
 * Types that bridge EncodeQueue (which detects an output-filename
 * collision mid-batch) to ContentView's SwiftUI alert (which presents
 * the user choice). The queue suspends a CheckedContinuation while
 * the alert is up; the user's selection resumes the continuation, and
 * the queue proceeds with the chosen action.
 *
 * Apply-to-all: a single CollisionDecision can be stamped as
 * "apply to all remaining" — EncodeQueue caches that decision for
 * the rest of the encodeAll session and bypasses subsequent prompts.
 */

import Foundation

/// What to do for one collision. Returned by the alert to
/// EncodeQueue's continuation. `.rename(URL)` carries the resolved
/// collision-free URL (computed by AutoNameEngine.collisionFreeURL).
enum CollisionDecision {
    case overwrite
    case rename(URL)
    /// Skip this job (mark .failed with a clear message); continue
    /// the batch.
    case skip
    /// Cancel the entire encode session.
    case cancel
}

/// A pending collision prompt. Held by EncodeQueue while the alert
/// is up; cleared (set to nil) when the user resolves it.
@MainActor
final class CollisionPrompt: ObservableObject, Identifiable {
    let id = UUID()
    let jobID: UUID
    /// The output URL that already exists on disk.
    let existingURL: URL
    /// The suggested auto-rename if the user picks "Rename".
    let suggestedRename: URL
    /// Resumed once with the user's decision.
    private var continuation: CheckedContinuation<(CollisionDecision, Bool), Never>?

    init(jobID: UUID, existingURL: URL, suggestedRename: URL,
         continuation: CheckedContinuation<(CollisionDecision, Bool), Never>) {
        self.jobID = jobID
        self.existingURL = existingURL
        self.suggestedRename = suggestedRename
        self.continuation = continuation
    }

    /// User picked one of the buttons. `applyToAll` mirrors the
    /// alert's checkbox state — when true, EncodeQueue caches the
    /// decision for the remainder of this encodeAll session.
    func resolve(_ decision: CollisionDecision, applyToAll: Bool) {
        continuation?.resume(returning: (decision, applyToAll))
        continuation = nil
    }
}
