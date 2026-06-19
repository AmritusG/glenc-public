// SPDX-License-Identifier: MIT
/*
 * GlEncAppDelegate — v0.9.1 Phase G.5.
 *
 * Handles incoming URLs from sibling apps (Crate's "Send to GlEnc",
 * Finder's "Open With…", `open -a GlEnc.app file1 file2 …`,
 * NSWorkspace.shared.open([URL], withApplicationAt:)). Routes ALL
 * received URLs into the queue's `addJobs(urls:)` entry point —
 * same path drag-and-drop uses, so behavior matches drop semantics
 * (N URLs → N queue jobs, no dialog, no batch confirmation).
 *
 * Why a real AppDelegate instead of SwiftUI's `.onOpenURL`: SwiftUI's
 * Scene-level `.onOpenURL(_:)` modifier only delivers a single URL
 * per call. When a sibling app uses
 *
 *     NSWorkspace.shared.open([url1, url2, url3], withApplicationAt: ...)
 *
 * the system fires `application(_:open:)` once with all three URLs.
 * SwiftUI's bridge between that delegate method and `.onOpenURL`
 * drops the multi-URL semantics (delivers only one or silently
 * loses the rest). Providing a custom NSApplicationDelegate is the
 * documented fix — `application(_:open:)` receives the full `[URL]`
 * array and we iterate.
 *
 * Cold-launch vs warm-launch:
 *   - Warm: GlEnc is already running; `application(_:open:)` fires
 *     after the SwiftUI App's `@StateObject queue` is fully
 *     constructed. URLs flow directly to `receiver(urls)`.
 *   - Cold: macOS launches GlEnc to deliver URLs. The delegate's
 *     `application(_:open:)` can fire BEFORE the SwiftUI Scene's
 *     view tree exists. URLs arriving before the queue is wired up
 *     are buffered in `pendingURLs` and drained when `ContentView`
 *     calls `installReceiver(_:)` on first appear.
 *
 * All state lives on `@MainActor` — SwiftUI binding mutations + the
 * queue's @Published properties must run on the main actor.
 */

import AppKit
import Foundation

final class GlEncAppDelegate: NSObject, NSApplicationDelegate {

    /// URLs received before the SwiftUI ContentView installed its
    /// receiver. Drained on receiver install.
    @MainActor static var pendingURLs: [URL] = []

    /// Active sink for incoming URLs. Set once `ContentView` mounts
    /// (its `.onAppear` calls `installReceiver(_:)`).
    @MainActor private static var receiver: (([URL]) -> Void)? = nil

    /// Called by the AppKit runtime when one or more URLs are opened
    /// for this app. Examples:
    ///   - Finder: select 3 files → right-click → Open With → GlEnc
    ///   - Terminal: `open -a GlEnc.app file1.mov file2.mov file3.mov`
    ///   - Crate v0.6.4+: "Send to GlEnc" multi-select context-menu
    ///   - Any other app calling NSWorkspace.shared.open([URL], ...)
    ///
    /// Routes ALL urls to the queue. If the queue isn't ready yet
    /// (cold launch), buffers them until `installReceiver` drains.
    func application(_ application: NSApplication, open urls: [URL]) {
        print("[GlEnc] application(_:open:) received \(urls.count) URL(s)")
        for u in urls {
            print("[GlEnc]   url: \(u.path)")
        }
        Task { @MainActor in
            if let recv = Self.receiver {
                recv(urls)
            } else {
                Self.pendingURLs.append(contentsOf: urls)
                print("[GlEnc] queue not ready — buffered \(urls.count) URL(s)")
            }
        }
    }

    /// Install the SwiftUI-side receiver for incoming URLs. Drains
    /// any URLs that arrived before the receiver was ready, then
    /// installs it for future deliveries.
    @MainActor
    static func installReceiver(_ recv: @escaping ([URL]) -> Void) {
        receiver = recv
        if !pendingURLs.isEmpty {
            print("[GlEnc] draining \(pendingURLs.count) buffered URL(s)")
            let buffered = pendingURLs
            pendingURLs.removeAll()
            recv(buffered)
        }
    }

    /// Test-only: clear all state. AppDelegate is a singleton in
    /// production, but unit tests exercise the buffer/receiver
    /// state in isolation.
    @MainActor
    static func resetForTesting() {
        pendingURLs.removeAll()
        receiver = nil
    }
}
