// SPDX-License-Identifier: MIT
/*
 * CollisionPromptView — v0.9.2 Phase G + G.1.
 *
 * SwiftUI sheet that renders the output-filename collision prompt
 * when EncodeQueue publishes a `pendingCollisionPrompt`. The queue
 * suspends a CheckedContinuation while the sheet is up; the user's
 * button choice resumes it and the encode loop proceeds.
 *
 * G.1 rebuild: Phase G originally used SwiftUI `.alert` with 7
 * buttons (Overwrite / Overwrite All / Rename / Rename All / Skip /
 * Skip All / Cancel). On macOS, `.alert` silently caps the number
 * of displayed buttons (~3 in practice) — so the "All" variants
 * were unreachable from the rendered dialog. G.1 switches to a
 * custom sheet styled as an alert: 4 buttons + an "Apply to all
 * remaining collisions" checkbox. This matches Finder's own file-
 * collision dialog UX and works reliably across macOS versions.
 *
 * EncodeQueue's session-override plumbing
 * (`sessionCollisionOverride: CollisionDecisionBase?`,
 * `applyDecision(base:initialOutURL:)`) is unchanged — only the UI
 * surface changed. The checkbox state feeds `applyToAll` in
 * `CollisionPrompt.resolve(_:applyToAll:)`; Cancel is exempt from
 * apply-to-all (cancel ends the session outright).
 */

import SwiftUI

struct CollisionPromptModifier: ViewModifier {
    @ObservedObject var queue: EncodeQueue

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(
                get: { queue.pendingCollisionPrompt != nil },
                set: { showing in
                    // Sheet dismissed via OS gesture (Cmd+W, etc.).
                    // Treat as Cancel — never silently overwrite.
                    if !showing, let p = queue.pendingCollisionPrompt {
                        p.resolve(.cancel, applyToAll: false)
                    }
                }
            )
        ) {
            if let prompt = queue.pendingCollisionPrompt {
                CollisionPromptSheet(prompt: prompt)
                    .frame(width: 460)
            }
        }
    }
}

private struct CollisionPromptSheet: View {
    let prompt: CollisionPrompt
    @State private var applyToAll: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: icon + title.
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output file already exists")
                        .font(.headline)
                    Text("\(prompt.existingURL.lastPathComponent)")
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Text("in \(prompt.existingURL.deletingLastPathComponent().path)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                }
            }

            // Body text — short, scannable.
            Text("What should GlEnc do for this job?")
                .font(.system(size: 13))

            Text("Rename would write to **\(prompt.suggestedRename.lastPathComponent)**.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Apply-to-all checkbox. Native macOS pattern; matches
            // Finder's own collision dialog. Cancel ignores this
            // (cancelling the session is per-session, not per-job).
            Toggle("Apply to all remaining collisions in this batch",
                   isOn: $applyToAll)
                .toggleStyle(.checkbox)
                .padding(.vertical, 2)

            // Four buttons in a single row — order chosen for native
            // macOS reading (destructive on the left, default action
            // on the right). Cancel gets the keyboard-Esc default
            // via .cancel role.
            HStack(spacing: 10) {
                Button("Overwrite") {
                    prompt.resolve(.overwrite, applyToAll: applyToAll)
                }
                Button("Skip") {
                    prompt.resolve(.skip, applyToAll: applyToAll)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    // Cancel exempt from apply-to-all (cancels session,
                    // not a per-job decision).
                    prompt.resolve(.cancel, applyToAll: false)
                }
                .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    prompt.resolve(.rename(prompt.suggestedRename),
                                   applyToAll: applyToAll)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
