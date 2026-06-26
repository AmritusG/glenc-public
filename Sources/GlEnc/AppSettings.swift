// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import GlEncCore

/// Phase 7B-a — central app-settings model. Persists user preferences
/// to `UserDefaults`. Exposed as a `@MainActor` `ObservableObject`
/// singleton; views bind via `@ObservedObject`.
///
/// Persistence scope:
///   - `QualityTier` / `AlphaMode` defaults applied to new jobs
///   - Output directory policy (same-as-source or fixed) + the fixed path
///   - Trim filename format (time vs frame-indices)
///   - Preview pane default visibility
///
/// Defaults are read on init. Writes happen synchronously via
/// `didSet` so the on-disk store and observed state stay in lockstep.
/// `@AppStorage` was rejected because it doesn't bind cleanly to
/// String-rawValue enums; the property-observer pattern is verbose
/// but unambiguous.
///
/// Tests can inject a separate `UserDefaults` suite via the
/// internal `init(userDefaults:)` (the singleton hides this; tests
/// import `@testable` to access it).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Storage backing

    private let userDefaults: UserDefaults

    // MARK: - Defaults for new jobs

    @Published var defaultQuality: QualityTier {
        didSet { userDefaults.set(defaultQuality.rawValue, forKey: Keys.defaultQuality) }
    }

    @Published var defaultAlpha: AlphaMode {
        didSet { userDefaults.set(defaultAlpha.rawValue, forKey: Keys.defaultAlpha) }
    }

    /// Slice 4 — HAP chunked-section count seeded into newly-created
    /// jobs (1–64; 1 = single section, byte-identical to pre-Slice-4
    /// output). Parity with `defaultQuality`/`defaultAlpha`. Only the
    /// HAP family honours it — DXV3 variants ignore the value. Persisted
    /// as a plain Int.
    @Published var defaultHapChunks: Int {
        didSet { userDefaults.set(defaultHapChunks, forKey: Keys.defaultHapChunks) }
    }

    // MARK: - Resize defaults (v0.9.4-pending Phase C)

    /// Per-job resize-filter default applied to newly-created jobs.
    /// Persisted via `.rawValue` (String) — mirrors `defaultQuality`
    /// exactly. Default `.auto` (direction-based, not content-aware
    /// — see ResizeQuality's doc comment).
    @Published var defaultResizeQuality: ResizeQuality {
        didSet { userDefaults.set(defaultResizeQuality.rawValue, forKey: Keys.defaultResizeQuality) }
    }

    /// Per-job output-size default applied to newly-created jobs.
    /// `OutputSize` is an enum with associated values (`.preset(p)`,
    /// `.custom(w, h)`) so `rawValue` doesn't apply — persisted via
    /// JSON encode/decode. Default `.original` (no resize). A missing
    /// OR corrupt stored value falls back to `.original` via `try?`
    /// (the `?? .original` arm of the load — see init).
    @Published var defaultOutputSize: OutputSize {
        didSet {
            if let data = try? JSONEncoder().encode(defaultOutputSize) {
                userDefaults.set(data, forKey: Keys.defaultOutputSize)
            }
            // try? failure on encode is theoretical (OutputSize is
            // a well-formed Codable enum) — if it happens, leaving
            // the previous stored value intact is the safe behavior.
        }
    }

    /// Per-job aspect-handling default applied to newly-created jobs
    /// (Phase G). Persisted via `.rawValue` (String) — mirrors
    /// `defaultResizeQuality`. Default `.letterbox` per
    /// CROP_RESIZE_PLAN.md Q3.
    @Published var defaultAspectMode: AspectMode {
        didSet { userDefaults.set(defaultAspectMode.rawValue, forKey: Keys.defaultAspectMode) }
    }

    /// User-named custom presets (Phase H — Q5). Surface in the
    /// Output Size menu's "My Sizes" section when non-empty. JSON-
    /// persisted; corrupt or missing stored data falls back to []
    /// via the same try?-decode pattern Phase C uses for
    /// `defaultOutputSize`. Mutations should go through
    /// `addCustomPreset(_:)` / `removeCustomPreset(id:)` so the
    /// duplicate-name policy is centralized.
    @Published var customPresets: [NamedSize] {
        didSet {
            if let data = try? JSONEncoder().encode(customPresets) {
                userDefaults.set(data, forKey: Keys.customPresets)
            }
        }
    }

    /// Add a named preset. Duplicate-name policy: replace-by-name —
    /// if a preset with the same trimmed name already exists, its
    /// dims are overwritten (and its id preserved for stable list
    /// ordering). New names append to the end. The plan is silent
    /// on this choice; replace is the simplest behavior that avoids
    /// silent proliferation of "Wall A", "Wall A (2)", "Wall A (3)"
    /// when the user keeps tweaking the same preset.
    func addCustomPreset(_ preset: NamedSize) {
        let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let needle = trimmed.lowercased()
        if let i = customPresets.firstIndex(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }) {
            // Preserve the existing id so SwiftUI list bindings see
            // an update, not a remove+insert (which would animate as
            // a row swap).
            customPresets[i] = NamedSize(
                id: customPresets[i].id,
                name: trimmed,
                width: preset.width,
                height: preset.height)
        } else {
            customPresets.append(NamedSize(
                id: preset.id,
                name: trimmed,
                width: preset.width,
                height: preset.height))
        }
    }

    /// Remove a named preset by id. No-op when not found.
    func removeCustomPreset(id: UUID) {
        customPresets.removeAll { $0.id == id }
    }

    // MARK: - Output directory

    enum OutputLocation: String, CaseIterable, Identifiable {
        case sameAsSource
        case fixed
        var id: String { rawValue }
    }

    @Published var outputLocation: OutputLocation {
        didSet { userDefaults.set(outputLocation.rawValue, forKey: Keys.outputLocation) }
    }

    /// File-system path for `.fixed`. Empty/missing when
    /// `outputLocation == .sameAsSource`. Validated at encode time
    /// by `EncodeQueue.encodeOne`: if the path doesn't exist or
    /// isn't writable, falls back to `.sameAsSource` for that encode.
    @Published var fixedOutputPath: String {
        didSet { userDefaults.set(fixedOutputPath, forKey: Keys.fixedOutputPath) }
    }

    // MARK: - Collision policy (v0.9.2 Phase G)

    /// What happens when an encode job's output filename already
    /// exists on disk. Resolved at job write-start (not enqueue
    /// time) so batch queues with same-named outputs sequentially
    /// produce _2, _3, _4 rather than racing for the same _N.
    enum CollisionPolicy: String, CaseIterable, Identifiable {
        /// Pause the queue and prompt the user. Default — non-
        /// destructive; matches user expectation of "warn before
        /// overwrite".
        case ask
        /// Write over the existing file silently. Pre-Phase-G
        /// behavior, now opt-in.
        case overwrite
        /// Append `_N` before the extension; scans existing siblings
        /// for the highest N and picks N+1.
        case autoRename
        var id: String { rawValue }

        var label: String {
            switch self {
            case .ask:        return "Ask"
            case .overwrite:  return "Overwrite"
            case .autoRename: return "Auto-rename"
            }
        }
    }

    @Published var collisionPolicy: CollisionPolicy {
        didSet { userDefaults.set(collisionPolicy.rawValue, forKey: Keys.collisionPolicy) }
    }

    // MARK: - Trim filename format

    enum TrimFilenameFormat: String, CaseIterable, Identifiable {
        case time           // [MM.SS.CC-MM.SS.CC] — Phase 8C-b-fix2 default
        case frameIndices   // [N-M] — legacy Phase 8C-b style
        var id: String { rawValue }
    }

    @Published var trimFilenameFormat: TrimFilenameFormat {
        didSet { userDefaults.set(trimFilenameFormat.rawValue, forKey: Keys.trimFilenameFormat) }
    }

    // MARK: - View

    @Published var previewPaneVisibleByDefault: Bool {
        didSet { userDefaults.set(previewPaneVisibleByDefault, forKey: Keys.previewPaneVisibleByDefault) }
    }

    /// Crop Release Phase E.5 — draw a faint outline of the source
    /// frame's boundary in the preview pane. Default ON: a clip whose
    /// content is black to its edges otherwise gives no visual cue
    /// where the source frame ends against the pane's black
    /// background, which makes the full-frame crop seed ambiguous.
    @Published var showClipBoundary: Bool {
        didSet { userDefaults.set(showClipBoundary, forKey: Keys.showClipBoundary) }
    }

    // MARK: - HAP preview checkerboard extent

    /// v0.10.x — how far the HAP-preview transparency checkerboard
    /// extends. Default `.fillViewport` preserves the shipped v0.10.1
    /// behavior (checker across the whole preview, incl. letterbox bars).
    enum CheckerboardScope: String, CaseIterable, Identifiable {
        /// Checker fills the entire preview area (today's default).
        case fillViewport
        /// Checker confined to the fitted video rect; letterbox bars
        /// stay black.
        case behindVideoOnly
        var id: String { rawValue }

        var label: String {
            switch self {
            case .fillViewport:    return "Fill viewport"
            case .behindVideoOnly: return "Behind video only"
            }
        }
    }

    @Published var checkerboardScope: CheckerboardScope {
        didSet { userDefaults.set(checkerboardScope.rawValue, forKey: Keys.checkerboardScope) }
    }

    // MARK: - Audio defaults (Phase 4) — new jobs inherit these.

    /// Carry source audio into output by default (Alley parity).
    @Published var defaultAudioEnabled: Bool {
        didSet { userDefaults.set(defaultAudioEnabled, forKey: Keys.defaultAudioEnabled) }
    }
    /// Default output sample rate for new jobs.
    @Published var defaultAudioRate: AudioRate {
        didSet { userDefaults.set(defaultAudioRate.persistInt, forKey: Keys.defaultAudioRate) }
    }

    // MARK: - Keys (namespaced under glenc.)

    private enum Keys {
        static let defaultQuality              = "glenc.defaultQuality"
        static let defaultAlpha                = "glenc.defaultAlpha"
        static let defaultHapChunks            = "glenc.defaultHapChunks"
        static let defaultResizeQuality        = "glenc.defaultResizeQuality"
        static let defaultOutputSize           = "glenc.defaultOutputSize"
        static let defaultAspectMode           = "glenc.defaultAspectMode"
        static let customPresets               = "glenc.customPresets"
        static let outputLocation              = "glenc.outputLocation"
        static let fixedOutputPath             = "glenc.fixedOutputPath"
        static let trimFilenameFormat          = "glenc.trimFilenameFormat"
        static let previewPaneVisibleByDefault = "glenc.previewPaneVisibleByDefault"
        static let showClipBoundary            = "glenc.showClipBoundary"
        static let collisionPolicy             = "glenc.collisionPolicy"
        static let checkerboardScope           = "glenc.checkerboardScope"
        static let defaultAudioEnabled         = "glenc.defaultAudioEnabled"
        static let defaultAudioRate            = "glenc.defaultAudioRate"
    }

    // MARK: - Init

    /// Production singleton uses `UserDefaults.standard`. Tests inject
    /// a suite-named instance via `@testable` to avoid polluting the
    /// shared store.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let d = userDefaults
        self.defaultQuality =
            QualityTier(rawValue: d.string(forKey: Keys.defaultQuality) ?? "") ?? .normal
        self.defaultAlpha =
            AlphaMode(rawValue: d.string(forKey: Keys.defaultAlpha) ?? "") ?? .withoutAlpha
        // Slice 4 — HAP chunk count. object(forKey:) nil-distinction so a
        // fresh install reads 1 (integer(forKey:) would return 0). Clamp
        // to 1...64 defensively against a corrupt/out-of-range stored value.
        self.defaultHapChunks =
            min(64, max(1, (d.object(forKey: Keys.defaultHapChunks) as? Int) ?? 1))
        self.defaultResizeQuality =
            ResizeQuality(rawValue: d.string(forKey: Keys.defaultResizeQuality) ?? "") ?? .auto
        // OutputSize is JSON-persisted (associated values). Missing OR
        // corrupt stored data both fall through to `.original` via
        // try? on the decode.
        self.defaultOutputSize = {
            if let data = d.data(forKey: Keys.defaultOutputSize),
               let decoded = try? JSONDecoder().decode(OutputSize.self, from: data) {
                return decoded
            }
            return .original
        }()
        self.defaultAspectMode =
            AspectMode(rawValue: d.string(forKey: Keys.defaultAspectMode) ?? "") ?? .letterbox
        // Phase H — customPresets JSON-persisted. Missing OR corrupt
        // stored value falls back to []. Matches the Phase C pattern
        // for defaultOutputSize.
        self.customPresets = {
            if let data = d.data(forKey: Keys.customPresets),
               let decoded = try? JSONDecoder().decode([NamedSize].self, from: data) {
                return decoded
            }
            return []
        }()
        self.outputLocation =
            OutputLocation(rawValue: d.string(forKey: Keys.outputLocation) ?? "") ?? .sameAsSource
        self.fixedOutputPath = d.string(forKey: Keys.fixedOutputPath) ?? ""
        self.trimFilenameFormat =
            TrimFilenameFormat(rawValue: d.string(forKey: Keys.trimFilenameFormat) ?? "") ?? .time
        self.collisionPolicy =
            CollisionPolicy(rawValue: d.string(forKey: Keys.collisionPolicy) ?? "") ?? .ask
        // Bool: object(forKey:) returns nil when never set, vs bool(forKey:)
        // returns false. Distinguish so the default-true survives a fresh
        // install with no prior write.
        self.previewPaneVisibleByDefault =
            (d.object(forKey: Keys.previewPaneVisibleByDefault) as? Bool) ?? true
        // Phase E.5 — default true when never set (same object(forKey:)
        // != nil distinction so a fresh install reads as ON).
        self.showClipBoundary =
            (d.object(forKey: Keys.showClipBoundary) as? Bool) ?? true
        self.checkerboardScope =
            CheckerboardScope(rawValue: d.string(forKey: Keys.checkerboardScope) ?? "") ?? .fillViewport
        // Phase 4 — audio ON by default (Alley parity); object(forKey:)
        // nil-check so a fresh install reads ON.
        self.defaultAudioEnabled =
            (d.object(forKey: Keys.defaultAudioEnabled) as? Bool) ?? true
        self.defaultAudioRate =
            AudioRate.from(persistInt: d.integer(forKey: Keys.defaultAudioRate))
    }

    /// Reset all settings to factory defaults. Used by the Reset
    /// button in PreferencesWindow + by tests for clean state.
    func resetToDefaults() {
        defaultQuality = .normal
        defaultAlpha = .withoutAlpha
        defaultHapChunks = 1
        defaultResizeQuality = .auto
        defaultOutputSize = .original
        defaultAspectMode = .letterbox
        customPresets = []
        outputLocation = .sameAsSource
        fixedOutputPath = ""
        trimFilenameFormat = .time
        previewPaneVisibleByDefault = true
        showClipBoundary = true
        collisionPolicy = .ask
        defaultAudioEnabled = true
        defaultAudioRate = .original
    }
}
