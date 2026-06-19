// SPDX-License-Identifier: MIT
/*
 * AppVersion — v0.9.2 Phase D.5.
 *
 * Single source of truth for the GlEnc version string stamped into
 * encoded MOVs' `udta/©swr` (Apple's "writer software") metadata atom
 * — what Finder CMD+I displays as "Encoding software".
 *
 * Before D.5: every encoder hardcoded its own "GlEnc 0.x.y" literal,
 * and `VariantMOVWriter`'s default parameter was a stale "GlEnc 0.2.0"
 * leftover from Phase 2B. The GUI path (EncodeQueue → WriterFactory)
 * never passed writerVersion, so files stamped 0.2.0 regardless of
 * the actual app version. Convenience encoders' hardcoded literals
 * were unreachable from the GUI.
 *
 * After D.5: this enum reads `CFBundleShortVersionString` from
 * `Bundle.main` once. EncodeQueue's WriterFactory passes
 * `AppVersion.writerVersion` into VariantMOVWriter. The library's
 * default falls back to a non-misleading "GlEnc" (no number) for
 * direct callers without bundle access (unit tests using the
 * convenience encoders). Tests that need a specific historical
 * version for byte-identity comparison continue to pass an explicit
 * `writerVersion:` parameter.
 *
 * Bundle.main is reliable from the app target (`Sources/GlEnc/`),
 * which is why this lives here rather than in GlEncCore. From a
 * library context (unit tests, `swift test`, direct library use),
 * `Bundle.main` resolves to the test runner host, not GlEnc, so the
 * library's fallback default kicks in instead.
 */

import Foundation

enum AppVersion {

    /// `"GlEnc <version>"` formatted from `CFBundleShortVersionString`.
    /// Single readsite — the rest of the app references this.
    static let writerVersion: String = makeWriterVersion()

    /// Just the version component (e.g. `"0.9.2"`), or `nil` if the
    /// bundle dictionary doesn't expose CFBundleShortVersionString
    /// (shouldn't happen in a packaged app; defensive for the rare
    /// "executable launched outside its bundle" case during dev).
    static let shortVersion: String? = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }()

    private static func makeWriterVersion() -> String {
        guard let v = shortVersion else {
            // Bundle has no version (shouldn't happen at runtime, but
            // protect the stamping path from being wrong rather than
            // misleading). "GlEnc" with no number is the same fallback
            // the library uses when callers don't supply a writerVersion.
            return "GlEnc"
        }
        return "GlEnc \(v)"
    }
}
