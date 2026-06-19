/*
 * AppSettingsTests — Phase 7B-a.
 *
 * UserDefaults-backed model. Tests use a per-test suite-named
 * UserDefaults instance via AppSettings's internal `init(userDefaults:)`
 * so the production singleton's store stays untouched.
 */

import XCTest
import Foundation
@testable import GlEnc

@MainActor
final class AppSettingsTests: XCTestCase {

    /// Fresh UserDefaults instance per test, scoped to a UUID-named
    /// suite so concurrent runs don't collide.
    private func freshUserDefaults() -> UserDefaults {
        let suiteName = "glenc-test-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        ud.removePersistentDomain(forName: suiteName)
        return ud
    }

    // MARK: - Defaults on fresh launch

    func testFreshLaunchDefaults() {
        let s = AppSettings(userDefaults: freshUserDefaults())
        XCTAssertEqual(s.defaultQuality, .normal)
        XCTAssertEqual(s.defaultAlpha, .withoutAlpha)
        XCTAssertEqual(s.outputLocation, .sameAsSource)
        XCTAssertEqual(s.fixedOutputPath, "")
        XCTAssertEqual(s.trimFilenameFormat, .time)
        XCTAssertTrue(s.previewPaneVisibleByDefault,
                      "preview pane defaults to visible on a fresh install")
    }

    // MARK: - Write → read round-trip (persistence)

    func testPersistence_DefaultQuality() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        s1.defaultQuality = .hq
        // New AppSettings instance backed by the same UserDefaults
        // simulates app relaunch.
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertEqual(s2.defaultQuality, .hq)
    }

    func testPersistence_DefaultAlpha() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        s1.defaultAlpha = .withAlpha
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertEqual(s2.defaultAlpha, .withAlpha)
    }

    func testPersistence_OutputLocation() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        s1.outputLocation = .fixed
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertEqual(s2.outputLocation, .fixed)
    }

    func testPersistence_FixedOutputPath() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        s1.fixedOutputPath = "/tmp/glenc-test-output"
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertEqual(s2.fixedOutputPath, "/tmp/glenc-test-output")
    }

    func testPersistence_TrimFilenameFormat() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        s1.trimFilenameFormat = .frameIndices
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertEqual(s2.trimFilenameFormat, .frameIndices)
    }

    func testPersistence_PreviewPaneVisible() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        s1.previewPaneVisibleByDefault = false
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertFalse(s2.previewPaneVisibleByDefault)
    }

    // MARK: - Reset

    func testResetToDefaults() {
        let s = AppSettings(userDefaults: freshUserDefaults())
        // Flip everything from defaults.
        s.defaultQuality = .hq
        s.defaultAlpha = .withAlpha
        s.outputLocation = .fixed
        s.fixedOutputPath = "/somewhere"
        s.trimFilenameFormat = .frameIndices
        s.previewPaneVisibleByDefault = false
        // Reset.
        s.resetToDefaults()
        XCTAssertEqual(s.defaultQuality, .normal)
        XCTAssertEqual(s.defaultAlpha, .withoutAlpha)
        XCTAssertEqual(s.outputLocation, .sameAsSource)
        XCTAssertEqual(s.fixedOutputPath, "")
        XCTAssertEqual(s.trimFilenameFormat, .time)
        XCTAssertTrue(s.previewPaneVisibleByDefault)
    }

    /// Reset writes are persisted — a fresh AppSettings sees the
    /// reset values, not the prior overrides.
    func testResetPersists() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        s1.defaultQuality = .hq
        s1.previewPaneVisibleByDefault = false
        s1.resetToDefaults()
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertEqual(s2.defaultQuality, .normal)
        XCTAssertTrue(s2.previewPaneVisibleByDefault)
    }

    // MARK: - Bool storage distinguishes never-set from false

    /// previewPaneVisibleByDefault defaults to true when no prior
    /// value was written. Writing false then reading back must yield
    /// false (not the never-set default).
    func testPreviewPaneVisible_FalseSurvives() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        XCTAssertTrue(s1.previewPaneVisibleByDefault, "fresh default")
        s1.previewPaneVisibleByDefault = false
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertFalse(s2.previewPaneVisibleByDefault,
                       "explicit false must survive reload")
    }

    // MARK: - showClipBoundary (Crop Release Phase E.5)

    /// showClipBoundary defaults to TRUE on a fresh install — the
    /// one pref in the app that defaults ON for an additive feature
    /// (the invisible-boundary failure mode outweighs a faint
    /// unwanted outline; see the AppSettings declaration comment).
    func testShowClipBoundary_DefaultIsTrueOnFreshInstall() {
        let s = AppSettings(userDefaults: freshUserDefaults())
        XCTAssertTrue(s.showClipBoundary,
                      "clip boundary indicator defaults ON on a fresh "
                      + "install with no prior write")
    }

    /// Writing false then reloading must yield false — the
    /// object(forKey:) != nil distinction keeps an explicit false
    /// from being overwritten by the never-set default of true.
    func testShowClipBoundary_FalsePersistsAcrossReload() {
        let ud = freshUserDefaults()
        let s1 = AppSettings(userDefaults: ud)
        XCTAssertTrue(s1.showClipBoundary, "fresh default is true")
        s1.showClipBoundary = false
        // A new instance on the same store simulates app relaunch.
        let s2 = AppSettings(userDefaults: ud)
        XCTAssertFalse(s2.showClipBoundary,
                       "explicit false must survive reload")
    }

    // MARK: - Malformed UserDefaults values fall back safely

    func testCorruptValuesFallBackToDefaults() {
        let ud = freshUserDefaults()
        // Write nonsense under each key.
        ud.set("not-a-real-tier", forKey: "glenc.defaultQuality")
        ud.set("nope", forKey: "glenc.defaultAlpha")
        ud.set("invalid", forKey: "glenc.outputLocation")
        ud.set("???", forKey: "glenc.trimFilenameFormat")
        let s = AppSettings(userDefaults: ud)
        XCTAssertEqual(s.defaultQuality, .normal)
        XCTAssertEqual(s.defaultAlpha, .withoutAlpha)
        XCTAssertEqual(s.outputLocation, .sameAsSource)
        XCTAssertEqual(s.trimFilenameFormat, .time)
    }
}
