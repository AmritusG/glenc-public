// SPDX-License-Identifier: MIT
/*
 * ResizeCustomSheet — Resize Release Phase F.
 *
 * Modal sheet that lets the user enter an arbitrary output size for
 * a job. The sheet is the agreed home for the 4-pixel-multiple
 * rounding (Phase D's deliberate decision: OutputSize.custom does
 * NOT self-round — the type is a general value; rounding lives at
 * the UI-commit boundary).
 *
 * UX:
 *   - Two numeric fields (width, height).
 *   - On commit: both dims rounded to the nearest 4-multiple via
 *     `roundedToFourPixelMultiple`. The sheet shows the rounded
 *     value live as the user types, so the rounding is never silent.
 *   - Rejects zero / negative / absurd dimensions inline. No crash.
 *   - On commit the caller is handed back an OutputSize.custom with
 *     the rounded values (the caller writes it to the job).
 *
 * Named-custom-preset persistence (CROP_RESIZE_PLAN.md Q5) is
 * deferred to Phase H — this sheet only commits a one-shot .custom
 * to the row.
 *
 * Used by JobCardView's per-row Output Size menu via a `.sheet(...)`
 * modifier; bound to an `@State` flag on the parent.
 */

import SwiftUI
import GlEncCore

// MARK: - Rounding helper

/// Round `n` to the nearest non-zero positive multiple of 4. Used by
/// the Custom sheet's commit path; OutputSize.custom does not
/// self-round (Phase D decision).
///
/// Round-half-up tie-breaking: 1282 → 1284 (distance 2 each way).
/// For `n <= 0`, returns 4 — the minimum legal output dim. Callers
/// are responsible for rejecting non-positive user input BEFORE
/// calling this; this fallback exists only so the function is total
/// and safe (clamping rather than crashing).
public func roundedToFourPixelMultiple(_ n: Int) -> Int {
    roundedToMultiple(n, of: 4)
}

/// Round `n` to the nearest multiple of `alignment` (ties round up),
/// clamped to a minimum of `alignment`. `alignment <= 1` means "no
/// rounding" — returns `max(1, n)` (any pixel value is legal). This is
/// the codec-aware generalization of the old 4-px-only rounding: H.264/
/// HEVC pass 2 (even dims), ProRes/MJPEG/DXV3/HAP pass 1 (arbitrary).
public func roundedToMultiple(_ n: Int, of alignment: Int) -> Int {
    let a = max(1, alignment)
    if a == 1 { return max(1, n) }
    if n <= 0 { return a }
    let rounded = ((n + a / 2) / a) * a
    return rounded < a ? a : rounded
}

// MARK: - The sheet view

/// SwiftUI sheet body. Bound to an `@State var showingCustomSheet`
/// on the parent (JobCardView). `onCommit` is invoked with the
/// rounded OutputSize.custom; the sheet auto-dismisses after commit.
struct ResizeCustomSheet: View {
    /// Pre-fill the fields with the row's current Custom size, if any.
    /// Otherwise the source dims, or a sensible default (1920×1080).
    var initialWidth: Int
    var initialHeight: Int
    /// Codec-aware dimension alignment to round to (2 = even for
    /// H.264/HEVC; 1 = arbitrary for ProRes/MJPEG/DXV3/HAP). Default 4
    /// preserves callers/tests that predate the codec-aware change.
    var alignment: Int = 4
    var onCommit: (_ rounded: OutputSize) -> Void
    var onCancel: () -> Void

    @State private var widthText: String = ""
    @State private var heightText: String = ""
    /// Phase H — the user's preset name. Empty disables the Save
    /// button. Trimmed on Save.
    @State private var presetNameText: String = ""
    /// Phase H — observe AppSettings so the live "will replace"
    /// note recomputes against the current customPresets list.
    /// Without this, the singleton's @Published changes aren't
    /// tracked as a body-render dependency.
    @ObservedObject private var settings: AppSettings = .shared

    init(initialWidth: Int = 1920, initialHeight: Int = 1080,
         alignment: Int = 4,
         onCommit: @escaping (OutputSize) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialWidth = initialWidth
        self.initialHeight = initialHeight
        self.alignment = alignment
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._widthText = State(initialValue: String(initialWidth))
        self._heightText = State(initialValue: String(initialHeight))
    }

    /// Codec-aware note for the sheet — the old hardcoded "rounded to the
    /// nearest 4-pixel multiple" claimed 4-px rounding for EVERY codec,
    /// including ProRes/DXV/HAP/MJPEG that accept arbitrary dims. (The
    /// commit rounding was already codec-aware; this text was the visible
    /// lie that read as "still rounds to 4px, same as H.264/HEVC".)
    private var alignmentNote: String {
        switch alignment {
        case ...1:
            return "Any dimensions are accepted — this codec needs no alignment."
        case 2:
            return "Rounded to the nearest even dimension on commit — H.264/HEVC require even (4:2:0) dimensions."
        default:
            return "Rounded to the nearest \(alignment)-pixel multiple on commit."
        }
    }

    private var parsedWidth: Int? { Int(widthText) }
    private var parsedHeight: Int? { Int(heightText) }

    /// Both dims are valid positive integers AND not absurdly large.
    /// Absurd ceiling: 16384 — wider than 16K UHD, leaves headroom.
    private var isValid: Bool {
        guard let w = parsedWidth, let h = parsedHeight else { return false }
        return w > 0 && h > 0 && w <= 16384 && h <= 16384
    }

    private var roundedPreview: (w: Int, h: Int)? {
        guard let w = parsedWidth, let h = parsedHeight,
              w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        return (roundedToMultiple(w, of: alignment), roundedToMultiple(h, of: alignment))
    }

    /// Live indicator: "rounded to WxH" when the typed dims aren't
    /// already 4-multiple, empty when they match exactly.
    private var roundingNote: String? {
        guard let (rw, rh) = roundedPreview else { return nil }
        guard let w = parsedWidth, let h = parsedHeight else { return nil }
        if rw == w && rh == h { return nil }
        return "rounded to \(rw)×\(rh)"
    }

    /// Phase H — the trimmed preset name. Empty when the user
    /// hasn't typed anything; non-empty enables Save.
    private var trimmedPresetName: String {
        presetNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when dims + non-empty name AND no existing preset
    /// uses this name. Save = create-new only. Updating an
    /// existing preset uses the separate Update button below
    /// (forces the destructive overwrite to be deliberate).
    private var canSavePreset: Bool {
        guard isValid, !trimmedPresetName.isEmpty else { return false }
        return !existsByName
    }

    /// True when dims + a name that DOES match an existing preset
    /// (case-insensitive). Drives the Update button.
    private var canUpdatePreset: Bool {
        guard isValid, !trimmedPresetName.isEmpty else { return false }
        return existsByName
    }

    /// Case-insensitive trim match against the persisted list.
    /// Read through `settings` (@ObservedObject) so SwiftUI tracks
    /// the list as a render dependency.
    private var existsByName: Bool {
        let needle = trimmedPresetName.lowercased()
        return settings.customPresets.contains { p in
            p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    /// Phase H — live preview of what Save will do, including the
    /// duplicate-name policy (replace-by-name): the user sees the
    /// "will replace" warning before clicking Save.
    /// Phase H — preview state for the Save action. The view branches
    /// on this to color/icon the warning case differently from the
    /// neutral case (the user reported the previous all-gray text
    /// blended visually).
    private enum SavePresetPreview {
        case willReplace(name: String, w: Int, h: Int)
        case willCreate(name: String, w: Int, h: Int)
    }

    private var savePresetPreview: SavePresetPreview? {
        guard canSavePreset, let (rw, rh) = roundedPreview else { return nil }
        // Read through the @ObservedObject so SwiftUI tracks the
        // list as a render dependency. Case-insensitive match so
        // "wall a" / "Wall A" / "WALL A" collide (addCustomPreset
        // does the same case-insensitive match).
        let needle = trimmedPresetName.lowercased()
        let existing = settings.customPresets.contains { p in
            p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
        if existing {
            return .willReplace(name: trimmedPresetName, w: rw, h: rh)
        }
        return .willCreate(name: trimmedPresetName, w: rw, h: rh)
    }

    /// Inline validation message (or nil when valid).
    private var validationMessage: String? {
        if widthText.isEmpty && heightText.isEmpty { return nil }
        if parsedWidth == nil || parsedHeight == nil {
            return "Enter integer dimensions."
        }
        if let w = parsedWidth, w <= 0 {
            return "Width must be positive."
        }
        if let h = parsedHeight, h <= 0 {
            return "Height must be positive."
        }
        if let w = parsedWidth, w > 16384 {
            return "Width exceeds 16384."
        }
        if let h = parsedHeight, h > 16384 {
            return "Height exceeds 16384."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom output size")
                        .font(.headline)
                    Text(alignmentNote)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Width:")
                    TextField("1920", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                        .multilineTextAlignment(.trailing)
                    Text("px")
                        .foregroundColor(.secondary)
                }
                GridRow {
                    Text("Height:")
                    TextField("1080", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                        .multilineTextAlignment(.trailing)
                    Text("px")
                        .foregroundColor(.secondary)
                }
            }

            // Inline feedback (validation message OR rounding note).
            if let msg = validationMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
            } else if let note = roundingNote {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Reserve vertical space so the dialog doesn't jump
                // when the user types.
                Text(" ").font(.caption)
            }

            // ─── Phase H — Save-as-preset row ─────────────────────
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Save as a named preset (optional)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("e.g. Wall A", text: $presetNameText)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        guard canSavePreset,
                              let (rw, rh) = roundedPreview else { return }
                        AppSettings.shared.addCustomPreset(NamedSize(
                            name: trimmedPresetName,
                            width: rw, height: rh))
                        onCommit(.custom(width: rw, height: rh))
                    }
                    .disabled(!canSavePreset)
                    .help("Save as a new preset")
                    // Phase H — distinct Update button. Activates only
                    // when the typed name matches an existing preset
                    // (case-insensitive). Forces the destructive
                    // overwrite to be a deliberate, separate click —
                    // Save can't silently replace.
                    Button("Update") {
                        guard canUpdatePreset,
                              let (rw, rh) = roundedPreview else { return }
                        AppSettings.shared.addCustomPreset(NamedSize(
                            name: trimmedPresetName,
                            width: rw, height: rh))
                        onCommit(.custom(width: rw, height: rh))
                    }
                    .disabled(!canUpdatePreset)
                    .help("Replace the existing preset with this name")
                }
                // Phase H — branch styling on the preview state. The
                // "name already in use" case is orange + warning icon
                // and tells the user the Update button is the way to
                // replace; Save is correspondingly disabled.
                switch savePresetPreview {
                case .willReplace(let name, let w, let h):
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("“\(name)” already exists. Click Update to replace it with \(w)×\(h).")
                            .foregroundColor(.orange)
                    }
                    .font(.caption)
                case .willCreate(let name, let w, let h):
                    Text("Will save as “\(name)” — \(w)×\(h).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .none:
                    Text(" ").font(.caption)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Commit") {
                    guard let (rw, rh) = roundedPreview else { return }
                    onCommit(.custom(width: rw, height: rh))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
