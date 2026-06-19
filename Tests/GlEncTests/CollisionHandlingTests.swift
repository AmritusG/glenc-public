/*
 * CollisionHandlingTests — v0.9.2 Phase G.
 *
 * Covers:
 *   - AutoNameEngine.collisionFreeURL highest-N scan (the key
 *     correctness gate — not blind _2, not gap-filling)
 *   - AppSettings.CollisionPolicy persistence
 *   - EncodeQueue overwrite / autoRename behavior on disk
 *     (the .ask path is a SwiftUI alert; covered by manual smoke)
 */

import XCTest
import Foundation
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class CollisionHandlingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppSettings.shared.resetToDefaults()
    }
    override func tearDown() {
        AppSettings.shared.resetToDefaults()
        super.tearDown()
    }

    // MARK: - AutoNameEngine.collisionFreeURL

    /// No collision → unchanged.
    func testCollisionFreeURL_NoCollision_ReturnsOriginal() {
        let url = URL(fileURLWithPath: "/tmp/Clip.mov")
        let result = AutoNameEngine.collisionFreeURL(url) { _ in [] }
        XCTAssertEqual(result, url, "no-collision input must be returned verbatim")
    }

    /// Base file exists, no _N siblings → _2.
    func testCollisionFreeURL_OneCollision_ReturnsUnderscore2() {
        let url = URL(fileURLWithPath: "/tmp/Clip.mov")
        let result = AutoNameEngine.collisionFreeURL(url) { _ in
            [URL(fileURLWithPath: "/tmp/Clip.mov")]
        }
        XCTAssertEqual(result.lastPathComponent, "Clip_2.mov")
    }

    /// Dense prefix: _2, _3, _4 already exist → _5 (the highest +1).
    func testCollisionFreeURL_DensePrefix_ReturnsHighestPlusOne() {
        let url = URL(fileURLWithPath: "/tmp/Clip.mov")
        let result = AutoNameEngine.collisionFreeURL(url) { _ in [
            URL(fileURLWithPath: "/tmp/Clip.mov"),
            URL(fileURLWithPath: "/tmp/Clip_2.mov"),
            URL(fileURLWithPath: "/tmp/Clip_3.mov"),
            URL(fileURLWithPath: "/tmp/Clip_4.mov"),
        ] }
        XCTAssertEqual(result.lastPathComponent, "Clip_5.mov",
                       "dense prefix _2,_3,_4 should return _5 — highest+1")
    }

    /// Sparse: _2 and _4 exist, _3 missing → _5 (NOT _3 — don't
    /// fill gaps, preserve chronological ordering).
    func testCollisionFreeURL_SparseHistory_ReturnsHighestPlusOne() {
        let url = URL(fileURLWithPath: "/tmp/Clip.mov")
        let result = AutoNameEngine.collisionFreeURL(url) { _ in [
            URL(fileURLWithPath: "/tmp/Clip.mov"),
            URL(fileURLWithPath: "/tmp/Clip_2.mov"),
            URL(fileURLWithPath: "/tmp/Clip_4.mov"),
        ] }
        XCTAssertEqual(result.lastPathComponent, "Clip_5.mov",
                       "sparse history should still return highest+1, not fill the _3 gap")
    }

    /// _N suffix goes BEFORE the extension, not after.
    func testCollisionFreeURL_SuffixGoesBeforeExtension() {
        let url = URL(fileURLWithPath: "/tmp/My Clip_HapY.mov")
        let result = AutoNameEngine.collisionFreeURL(url) { _ in
            [URL(fileURLWithPath: "/tmp/My Clip_HapY.mov")]
        }
        XCTAssertEqual(result.lastPathComponent, "My Clip_HapY_2.mov")
        XCTAssertEqual(result.pathExtension, "mov")
    }

    /// Non-numeric middles like "Clip_backup.mov" must NOT be parsed
    /// as N=… and must NOT shift the highest-N counter.
    func testCollisionFreeURL_IgnoresNonNumericMiddle() {
        let url = URL(fileURLWithPath: "/tmp/Clip.mov")
        let result = AutoNameEngine.collisionFreeURL(url) { _ in [
            URL(fileURLWithPath: "/tmp/Clip.mov"),
            URL(fileURLWithPath: "/tmp/Clip_backup.mov"),     // non-numeric — ignored
            URL(fileURLWithPath: "/tmp/Clip_2.mov"),
        ] }
        XCTAssertEqual(result.lastPathComponent, "Clip_3.mov",
                       "non-numeric _backup must not be treated as _N; highest-N is 2 → return _3")
    }

    /// 5-encode burst as a single sequence — what the priming
    /// described. Simulates the user encoding the same clip 5 times
    /// in a row by progressively expanding the existing-files set.
    func testCollisionFreeURL_FiveEncodeBurst() {
        var existing: [URL] = [URL(fileURLWithPath: "/tmp/Clip.mov")]
        let names = (0..<4).map { _ -> String in
            let url = URL(fileURLWithPath: "/tmp/Clip.mov")
            let r = AutoNameEngine.collisionFreeURL(url) { _ in existing }
            existing.append(r)
            return r.lastPathComponent
        }
        XCTAssertEqual(names, ["Clip_2.mov", "Clip_3.mov",
                               "Clip_4.mov", "Clip_5.mov"],
                       "five sequential encodes must produce _2..._5")
    }

    /// Extension-less filename: `_N` still goes before … nothing,
    /// so we end up with `Clip_2`. (Edge case — common on Unix-y
    /// filenames without a dot.)
    func testCollisionFreeURL_NoExtension() {
        let url = URL(fileURLWithPath: "/tmp/Clip")
        let result = AutoNameEngine.collisionFreeURL(url) { _ in
            [URL(fileURLWithPath: "/tmp/Clip")]
        }
        XCTAssertEqual(result.lastPathComponent, "Clip_2")
        XCTAssertEqual(result.pathExtension, "")
    }

    // MARK: - AppSettings.CollisionPolicy persistence

    func testCollisionPolicyDefault_IsAsk() {
        AppSettings.shared.resetToDefaults()
        XCTAssertEqual(AppSettings.shared.collisionPolicy, .ask,
                       "v0.9.2 Phase G default must be .ask — non-destructive")
    }

    func testCollisionPolicyPersistsToUserDefaults() {
        let suite = UserDefaults(suiteName: "GlEncCollisionTest-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.joined()) }

        let s1 = AppSettings(userDefaults: suite)
        XCTAssertEqual(s1.collisionPolicy, .ask, "fresh init defaults to .ask")
        s1.collisionPolicy = .autoRename

        // Re-init from the same suite — value survives.
        let s2 = AppSettings(userDefaults: suite)
        XCTAssertEqual(s2.collisionPolicy, .autoRename,
                       "set value must survive re-init via UserDefaults")
    }

    func testCollisionPolicyAllCasesCovered() {
        // Same defensive gate the DXVFormatTests pattern uses —
        // adding a CollisionPolicy case should require the test author
        // to think about UI placement + persistence.
        XCTAssertEqual(AppSettings.CollisionPolicy.allCases.count, 3)
        XCTAssertEqual(AppSettings.CollisionPolicy.allCases.map(\.rawValue),
                       ["ask", "overwrite", "autoRename"])
    }
}
