// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin  // setbuf — disable stdio buffering for live console diagnostics

@main
struct GlEncApp: App {
    @StateObject private var queue = EncodeQueue()
    // Phase 7B-a — settings model. View hierarchy + EncodeQueue both
    // reach into AppSettings.shared directly; this @StateObject just keeps
    // the lifetime managed for the app's life.
    @StateObject private var settings: AppSettings = .shared
    // v0.9.1 Phase G.5 — real NSApplicationDelegate so multi-URL
    // opens (Crate "Send to GlEnc", `open -a GlEnc.app file1 file2`,
    // NSWorkspace.shared.open([URL], withApplicationAt:)) deliver
    // ALL URLs. SwiftUI's `.onOpenURL` modifier only handles single
    // URLs; see GlEncAppDelegate for the rationale.
    @NSApplicationDelegateAdaptor(GlEncAppDelegate.self) private var appDelegate

    init() {
        // When stdout is piped (e.g. `swift run GlEnc 2>&1 | tee log`),
        // Swift's stdout becomes block-buffered and prints sit in the
        // buffer until the buffer fills or the process exits cleanly
        // through libc atexit. AppKit's `[NSApp terminate:]` doesn't
        // always flush stdio. Disable buffering so diagnostic prints
        // hit the pipe immediately.
        setbuf(stdout, nil)
        print("[boot] GlEnc launched, pid=\(getpid())")

        // When launched via `swift run` (no .app bundle), LaunchServices
        // registers the binary as a background-only agent — no window
        // appears. The .app bundle path doesn't need this because the
        // Info.plist's CFBundlePackageType=APPL tells LaunchServices to
        // treat it as a regular app. Force regular activation so dev
        // runs behave the same as the bundled app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // Window (not WindowGroup) per HANDOVER §6 rule 3: GlEnc is a
        // single-window queue app, not a document-per-file editor.
        Window("GlEnc", id: "main") {
            ContentView()
                .environmentObject(queue)
                .environmentObject(settings)
                .frame(minWidth: 760, minHeight: 480)
                .toolbar { toolbarContent }
                // v0.9.1 Phase G.5 — Route doc-type opens (drag onto
                // app icon, "Open With…", `open -a GlEnc.app file.mov`,
                // Crate's "Send to GlEnc" multi-select) into the
                // queue. `.onOpenURL` (SwiftUI's bridge) only delivers
                // ONE URL per call when multiple arrive together; the
                // GlEncAppDelegate's `application(_:open:)` gets the
                // full [URL] array. On first appear we install a
                // receiver into the delegate that forwards URLs to
                // `queue.addJobs(urls:)` — same path drag-and-drop
                // uses. Any URLs that arrived before the receiver
                // was installed (cold launch) drain immediately.
                .onAppear {
                    GlEncAppDelegate.installReceiver { urls in
                        queue.addJobs(urls: urls)
                    }
                }
                // Phase 7B-a — install NSWindow.setFrameAutosaveName so
                // the main window's size + position survives quit/relaunch.
                // SwiftUI's `Window` scene doesn't expose autosave directly;
                // the WindowAccessor escape hatch wires it to the underlying
                // NSWindow on first attach.
                .background(WindowAccessor { window in
                    window.setFrameAutosaveName("glenc.main")
                })
        }
        .commands { viewMenuCommands }

        // Phase 7B-a — Preferences scene. SwiftUI's `AppSettings` scene is
        // auto-wired to the standard Cmd+, shortcut + the "GlEnc →
        // AppSettings…" app-menu item, so no `.commands` plumbing needed.
        Settings {
            PreferencesWindow()
        }
    }

    /// Phase 7B-a — View menu commands. Adds a "Show Preview Pane"
    /// toggle (⌘⇧P) that flips `AppSettings.shared.previewPaneVisibleByDefault`.
    /// SwiftUI's standard View menu placement (`.sidebar`) keeps this
    /// near the standard "Show Sidebar" / "Show Tab Bar" items.
    @CommandsBuilder
    private var viewMenuCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Button(settings.previewPaneVisibleByDefault
                   ? "Hide Preview Pane"
                   : "Show Preview Pane") {
                settings.previewPaneVisibleByDefault.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // v0.9.2 Phase G.1 user finding: macOS 14+ auto-groups
        // multiple `.navigation`-placement toolbar items into a single
        // pill-shaped container — framework chrome, not item styling.
        // Switching Picker→Menu+borderlessButton didn't remove the
        // pill because the pill lives on the toolbar group container,
        // not on the items.
        //
        // Fix: relocated the global Codec/Alpha menus OUT of the
        // toolbar and into a flat row at the top of the queue column
        // (ContentView.defaultsRow). They render as plain text +
        // chevron there — no framework-imposed chrome. The action
        // buttons (Add / Encode / Cancel) stay in the toolbar
        // because `.primaryAction` doesn't auto-group with a pill.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                pickFiles()
            } label: {
                Label("Add files…", systemImage: "plus")
            }
            .help("Open the file picker to add one or more videos to the queue.")
            .disabled(queue.isEncoding)

            Button {
                queue.encodeAll()
            } label: {
                Label(queue.isEncoding ? "Encoding…" : "Encode Queue",
                      systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(queue.isEncoding
                      || queue.jobs.isEmpty
                      || !queue.jobs.contains { $0.status == .queued })

            Button(role: .destructive) {
                queue.cancelAll()
            } label: {
                Label("Cancel All", systemImage: "stop.fill")
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!queue.isEncoding)
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.prompt = "Add"
        panel.message = "Select video files to add to the encode queue."
        if panel.runModal() == .OK {
            queue.addJobs(urls: panel.urls)
        }
    }
}

/// Phase 7B-a — tiny `NSViewRepresentable` that runs `onAttach` once
/// the underlying `NSWindow` is available. SwiftUI's `Window` scene
/// doesn't expose the AppKit window directly, so this is the standard
/// escape hatch (Glance uses an identical helper). Used here to call
/// `setFrameAutosaveName` so the main window's frame survives quit.
private struct WindowAccessor: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onAttach(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onAttach(window) }
        }
    }
}
