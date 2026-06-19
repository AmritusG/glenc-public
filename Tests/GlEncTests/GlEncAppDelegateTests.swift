/*
 * GlEncAppDelegateTests — v0.9.1 Phase G.5.
 *
 * Unit-tests the buffer + receiver state inside GlEncAppDelegate.
 * The AppKit delegate-method dispatch itself can't be exercised in
 * a unit test (it requires a real running NSApp + LaunchServices
 * routing); but the buffering logic — "URLs arriving before
 * receiver is installed are queued and drained on install" — is
 * pure Swift state and unit-testable.
 *
 * The full cold-launch / warm-launch / mixed-type round-trip from
 * Crate is covered by manual GUI smoke (deferred to the user).
 */

import XCTest
@testable import GlEnc

@MainActor
final class GlEncAppDelegateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        GlEncAppDelegate.resetForTesting()
    }

    override func tearDown() {
        GlEncAppDelegate.resetForTesting()
        super.tearDown()
    }

    /// Warm-launch path: receiver is installed before URLs arrive.
    /// `application(_:open:)` should forward URLs directly to the
    /// receiver, leaving pendingURLs empty.
    func testReceiverInstalledFirst_ForwardsImmediately() async {
        var received: [URL] = []
        GlEncAppDelegate.installReceiver { urls in
            received.append(contentsOf: urls)
        }
        let delegate = GlEncAppDelegate()
        let urls = [
            URL(fileURLWithPath: "/tmp/a.mov"),
            URL(fileURLWithPath: "/tmp/b.mov"),
            URL(fileURLWithPath: "/tmp/c.mov"),
        ]
        delegate.application(NSApplication.shared, open: urls)

        // application(_:open:) dispatches the receiver call into a
        // MainActor Task — await one runloop turn so it settles.
        await Task.yield()

        XCTAssertEqual(received, urls,
                       "warm-launch should forward all URLs to receiver")
        XCTAssertEqual(GlEncAppDelegate.pendingURLs, [],
                       "pendingURLs should remain empty when receiver is installed")
    }

    /// Cold-launch path: URLs arrive before receiver. They must
    /// accumulate in pendingURLs.
    func testNoReceiver_BuffersURLs() async {
        let delegate = GlEncAppDelegate()
        let urls = [
            URL(fileURLWithPath: "/tmp/cold1.mov"),
            URL(fileURLWithPath: "/tmp/cold2.mov"),
        ]
        delegate.application(NSApplication.shared, open: urls)
        await Task.yield()

        XCTAssertEqual(GlEncAppDelegate.pendingURLs, urls,
                       "URLs arriving before receiver should be buffered")
    }

    /// Cold-launch drain: install receiver after URLs arrived. The
    /// drain should fire on `installReceiver` with the buffered URLs.
    func testInstallReceiverDrainsPending() async {
        let delegate = GlEncAppDelegate()
        let urls = [
            URL(fileURLWithPath: "/tmp/d1.mov"),
            URL(fileURLWithPath: "/tmp/d2.mov"),
            URL(fileURLWithPath: "/tmp/d3.mov"),
        ]
        delegate.application(NSApplication.shared, open: urls)
        await Task.yield()
        XCTAssertEqual(GlEncAppDelegate.pendingURLs.count, 3,
                       "pre-drain: should have 3 buffered URLs")

        var drained: [URL] = []
        GlEncAppDelegate.installReceiver { urls in
            drained.append(contentsOf: urls)
        }
        XCTAssertEqual(drained, urls,
                       "installReceiver should drain buffered URLs")
        XCTAssertEqual(GlEncAppDelegate.pendingURLs, [],
                       "drained pendingURLs should be cleared")
    }

    /// After install + drain, subsequent application(_:open:) calls
    /// should bypass the buffer and forward directly.
    func testPostDrain_ForwardsWithoutBuffering() async {
        let delegate = GlEncAppDelegate()
        // Pre-drain URLs.
        delegate.application(NSApplication.shared,
                             open: [URL(fileURLWithPath: "/tmp/pre.mov")])
        await Task.yield()

        var received: [URL] = []
        GlEncAppDelegate.installReceiver { urls in
            received.append(contentsOf: urls)
        }
        XCTAssertEqual(received.count, 1, "drain ran")

        // Post-drain delivery.
        let postURLs = [URL(fileURLWithPath: "/tmp/post1.mov"),
                        URL(fileURLWithPath: "/tmp/post2.mov")]
        delegate.application(NSApplication.shared, open: postURLs)
        await Task.yield()

        XCTAssertEqual(received.count, 3,
                       "post-drain delivery should append to receiver")
        XCTAssertEqual(received.suffix(2), postURLs.prefix(2),
                       "post-drain URLs should be in order")
        XCTAssertEqual(GlEncAppDelegate.pendingURLs, [],
                       "buffer should stay empty post-drain")
    }

    /// Multiple application(_:open:) calls pre-receiver accumulate.
    /// Catches a regression where a second call clobbers the first.
    func testMultiplePreReceiverCallsAccumulate() async {
        let delegate = GlEncAppDelegate()
        delegate.application(NSApplication.shared,
                             open: [URL(fileURLWithPath: "/tmp/a.mov")])
        await Task.yield()
        delegate.application(NSApplication.shared,
                             open: [URL(fileURLWithPath: "/tmp/b.mov"),
                                    URL(fileURLWithPath: "/tmp/c.mov")])
        await Task.yield()

        XCTAssertEqual(GlEncAppDelegate.pendingURLs.count, 3,
                       "two pre-receiver calls should accumulate to 3 buffered URLs")

        var drained: [URL] = []
        GlEncAppDelegate.installReceiver { urls in
            drained.append(contentsOf: urls)
        }
        XCTAssertEqual(drained.map(\.lastPathComponent),
                       ["a.mov", "b.mov", "c.mov"],
                       "drain order should match arrival order")
    }
}
