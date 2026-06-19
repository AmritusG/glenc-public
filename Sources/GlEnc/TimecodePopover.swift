// SPDX-License-Identifier: MIT
import SwiftUI

/// v0.9.0.3 — popover surface that lets the user type a precise
/// HH:MM:SS:FF timecode for a trim in/out point. Anchored to the
/// trim-edge marker in `ScrubBar` via SwiftUI's `.popover`.
///
/// On Enter or "Set" → parses, clamps, and calls `onSet(frame)`.
/// On Esc or "Cancel" → calls `onCancel`.
struct TimecodePopover: View {
    let title: String
    let initialFrame: Int
    let fps: Double
    let totalFrames: Int
    let onSet: (Int) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @State private var parseError: String? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            HStack(spacing: 6) {
                TextField("HH:MM:SS:FF", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 130)
                    .focused($isFocused)
                    .onSubmit(commit)
            }

            if let err = parseError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Text("fps: \(Int(fps.rounded())) — frames 0-\(max(0, totalFrames - 1))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Set", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(fps <= 0)
            }
        }
        .padding(16)
        .frame(minWidth: 240)
        .onAppear {
            text = Timecode.string(frame: initialFrame, fps: fps)
            isFocused = true
        }
    }

    private func commit() {
        guard fps > 0 else {
            parseError = "Source frame rate unknown — can't parse timecode."
            return
        }
        guard let frame = Timecode.parse(text, fps: fps) else {
            parseError = "Format: HH:MM:SS:FF (e.g. 00:01:30:15)"
            return
        }
        let last = max(0, totalFrames - 1)
        guard frame >= 0, frame <= last else {
            parseError = "Out of range. Frames must be 0–\(last)."
            return
        }
        parseError = nil
        onSet(frame)
    }
}
