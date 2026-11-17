//! The GlEnc window (Swift GlEnc 1.6.2 `GlEncApp.swift`, `ContentView.swift`): a toolbar (Add files…, Encode Queue
//! ⌘↩, Cancel All ⌘.), the queue column (settings bar, drop zone, queue header, rows) and the preview pane beside it
//! (hidden with ⇧⌘P), the Preferences window (⌘,), sheets (collision prompt, Custom size, Manage sizes), the menu
//! bar. Files sent by Finder / Open With / the Dock / `open -a` are queued after the movie-type filter (Swift skips
//! it on that path; fixed on purpose, Amrit 2026-11-14 "fix"); drops on the drop zone are filtered the same way.

pub mod bar;
pub mod card;
pub mod list;
pub mod log;
pub mod look;
pub mod menu;
pub mod prefs;
pub mod preview;
pub mod sheets;

use crate::queue::Queue;
use crate::settings::Settings;
use glance_ui::{App, Host, ShellConfig, ShellEvent};
use std::path::PathBuf;
use std::sync::Arc;

pub const APP: &str = "GlEnc";
/// Swift GlEnc's own id since the swap (1.7.0), so the settings carry over. A test build sets this and `app.conf` to
/// `com.amritus.glenc.rs` ("GlEnc RS") and never runs as `com.amritus.glenc`.
pub const BUNDLE_ID: &str = "com.amritus.glenc";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// `udta/©swr` of DXV / HAP outputs (`AppVersion.writerVersion`).
pub fn writer_version() -> String {
    format!("{APP} {VERSION}")
}
/// The window's minimum size (`.frame(minWidth: 760, minHeight: 480)`).
pub const MIN_SIZE: (f64, f64) = (760.0, 480.0);
/// The first launch's size: the split view's ideal width (1170) and a comfortable height.
pub const DEFAULT_SIZE: (f64, f64) = (1170.0, 760.0);

/// A sheet over the window.
#[derive(Clone, Debug, PartialEq)]
pub enum Sheet {
    /// Custom… output size, for the defaults (`None`) or these rows.
    CustomSize { rows: Option<Vec<crate::job::JobId>>, width: String, height: String, name: String },
    /// Manage Sizes….
    ManageSizes,
}

/// What the views share besides the queue.
#[derive(Default)]
pub struct UiState {
    pub prefs_open: bool,
    pub sheet: Option<Sheet>,
    /// Where the drop zone was drawn last (drops elsewhere are ignored, as Swift's `.onDrop` on the zone).
    pub drop_zone: Option<egui::Rect>,
    /// "Apply to all" in the collision prompt.
    pub prompt_apply_all: bool,
    /// Text being typed in a row's name field (row, text).
    pub editing_name: Option<(crate::job::JobId, String)>,
    /// State owned by the rows, the settings bar and the queue column (`list.rs`, `card.rs`, `bar.rs`).
    pub rows: list::RowsState,
    /// State owned by the Preferences window (`prefs.rs`).
    pub prefs: prefs::PrefsState,
    /// State owned by the sheets (`sheets.rs`).
    pub sheets: sheets::SheetsState,
}

pub struct GlEnc {
    /// GlEnc's look is set on the first frame (egui's context exists only then).
    styled: bool,
    pub q: Queue,
    pub st: UiState,
    menu: menu::GlEncMenu,
    preview: preview::Preview,
    log: log::EventLog,
}

impl GlEnc {
    pub fn new(_gpu: &glance_gpu::Gpu) -> Result<GlEnc, String> {
        let store = glance_settings::app_store(BUNDLE_ID, "Amritus", APP)?;
        let settings = Settings::new(store);
        let encoder: crate::queue::Encoder = Arc::new(|r, p, c| glance_encode::encode(r, p, c));
        let prober: crate::queue::Prober = Arc::new(crate::queue::probe);
        let q = Queue::new(settings, encoder, prober, writer_version());
        Ok(GlEnc {
            styled: false,
            q,
            st: UiState::default(),
            menu: menu::GlEncMenu::new(APP, VERSION)?,
            preview: preview::Preview::default(),
            log: log::EventLog::from_env(),
        })
    }

    /// Movie files only (`UTType(filenameExtension:).conforms(to: .movie)`).
    fn movies(paths: Vec<PathBuf>) -> Vec<PathBuf> {
        paths.into_iter().filter(|p| p.extension().and_then(|e| e.to_str()).is_some_and(|e| glance_platform::conforms_to_movie(&e.to_lowercase()))).collect()
    }

    fn add_files(&mut self) {
        if let Some(paths) = glance_ui::dialog::open_movies("Select video files to add to the encode queue.") {
            self.q.add(&paths);
        }
    }

    fn toolbar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let encoding = self.q.is_encoding();
                if ui.add_enabled(encoding, egui::Button::new("⏹ Cancel All")).on_hover_text("Cancel All (⌘.)").clicked() {
                    self.q.cancel_all();
                }
                let queued = self.q.jobs.iter().any(|j| j.status == crate::job::Status::Queued);
                let label = if encoding { "▶ Encoding…" } else { "▶ Encode Queue" };
                if ui.add_enabled(!encoding && queued, egui::Button::new(label)).clicked() {
                    self.q.encode_all();
                }
                if ui
                    .add_enabled(!encoding, egui::Button::new("＋ Add files…"))
                    .on_hover_text("Open the file picker to add one or more videos to the queue.")
                    .clicked()
                {
                    self.add_files();
                }
            });
        });
    }

    fn keys(&mut self, ctx: &egui::Context) {
        // A sheet, the collision prompt or Preferences keeps the main window's shortcuts (Swift: sheets are modal,
        // Settings is another window).
        if self.st.sheet.is_some() || self.q.prompt.is_some() || self.st.prefs_open {
            return;
        }
        let (enc, cancel) =
            ctx.input_mut(|i| (i.consume_key(egui::Modifiers::COMMAND, egui::Key::Enter), i.consume_key(egui::Modifiers::COMMAND, egui::Key::Period)));
        if enc && !self.q.is_encoding() {
            self.q.encode_all();
        }
        if cancel && self.q.is_encoding() {
            self.q.cancel_all();
        }
    }
}

impl App for GlEnc {
    fn frame(&mut self, ui: &mut egui::Ui, host: &mut Host<'_>) {
        self.q.refined_bc4 = self.st.prefs.refined_bc4;
        self.q.poll();
        let ctx = ui.ctx().clone();
        if !self.styled {
            look::apply(&ctx);
            self.styled = true;
        }
        self.keys(&ctx);
        self.menu.sync(&self.q);
        egui::Panel::top("toolbar").show(ui, |ui| self.toolbar(ui));
        let show_preview = self.q.settings.values().preview_pane_visible_by_default;
        if show_preview {
            // Swift's `HSplitView` opens the two panes at an even split (measured 584 / 584 pt in a 1170 pt window).
            let half = ((ui.available_width() - 2.0) / 2.0).max(370.0);
            egui::Panel::right("preview").resizable(true).min_size(370.0).default_size(half).show(ui, |ui| {
                ui.set_min_width(ui.available_width());
                self.preview.show(ui, host, &mut self.q, &mut self.st);
            });
        } else {
            // Swift unloads the clip when the pane goes (`PreviewPane.swift:334-336`): no sound from a hidden pane.
            self.preview.hidden();
        }
        egui::CentralPanel::default().show(ui, |ui| list::queue_column(ui, &mut self.q, &mut self.st));
        prefs::show(&ctx, &mut self.q, &mut self.st);
        sheets::show(&ctx, &mut self.q, &mut self.st);
        if self.log.enabled() {
            let mut log = std::mem::replace(&mut self.log, log::EventLog { file: None, last: None });
            log.state(self);
            self.log = log;
        }
        ctx.request_repaint();
    }

    fn event(&mut self, event: ShellEvent, host: &mut Host<'_>) {
        if self.log.enabled() {
            self.log.write(serde_json::json!({"event": "shell", "what": format!("{event:?}")}));
        }
        match event {
            ShellEvent::DroppedAll(paths) => {
                let inside = match (host.drop_position(), self.st.drop_zone) {
                    (Some(p), Some(r)) => r.contains(p),
                    _ => true,
                };
                if inside {
                    self.q.add(&Self::movies(paths));
                }
            }
            ShellEvent::Platform(glance_ui::PlatformEvent::Open(paths)) => self.q.add(&Self::movies(paths)),
            ShellEvent::MenuItem(id) => {
                if let Some(c) = menu::Command::from_id(&id) {
                    self.command(c);
                }
            }
            _ => {}
        }
    }

    fn menu(&self) -> Option<&dyn glance_ui::menu::MenuBar> {
        Some(&self.menu)
    }

    /// ⌘W / the close button while Preferences is open closes Preferences (Swift's Settings is its own window, which
    /// ⌘W closes); otherwise the window closes and the app ends, as Swift GlEnc's single window does.
    fn close_requested(&mut self) -> bool {
        if self.st.prefs_open {
            self.st.prefs_open = false;
            return false;
        }
        true
    }
}

impl GlEnc {
    fn command(&mut self, c: menu::Command) {
        use menu::Command as C;
        match c {
            C::Preferences => self.st.prefs_open = true,
            C::TogglePreview => {
                let v = !self.q.settings.values().preview_pane_visible_by_default;
                self.q.settings.set(crate::settings::Change::PreviewPaneVisibleByDefault(v));
            }
            C::SelectAllClips => self.q.select_all(),
            C::ResetSelected => {
                self.q.reset_selected();
            }
            C::ResetAllFinished => {
                self.q.reset_all_finished();
            }
            C::SelectFinished => self.q.select_finished(),
            C::EncodeQueue => self.q.encode_all(),
            C::AddFiles => self.add_files(),
            C::Change { all, edit } => {
                let ids = if all { self.q.jobs.iter().map(|j| j.id).collect() } else { self.q.selected_ids.clone() };
                let menu::Edit::Settings(f) = edit;
                self.q.apply_settings(&ids, &*f);
            }
        }
    }
}

/// Run the app.
pub fn main() -> std::process::ExitCode {
    let config = ShellConfig { title: APP.into(), size: DEFAULT_SIZE, min_size: Some(MIN_SIZE), open_files: true, frame_autosave: Some("glenc.main".into()) };
    match glance_ui::run_shell(config, |gpu| {
        let app = GlEnc::new(gpu)?;
        Ok(app)
    }) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{APP}: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}
