//! Swift GlEnc's menu bar (`GlEncApp.swift:77-137`, `SettingsMenuItems.swift`) in muda, through glance-core's
//! app-defined menu bar:
//!
//! - App menu: About GlEnc, Preferences… ⌘, (SwiftUI's Settings scene), Services, Hide / Hide Others / Show All, Quit.
//! - Edit: the system's Undo, Redo, Cut, Copy, Paste, Delete, Select All, then **Select All Clips ⇧⌘A**.
//! - View: **Show / Hide Preview Pane ⇧⌘P** (after the sidebar group); AppKit adds Enter Full Screen.
//! - **Queue**: Reset Selected ⌘R, Reset All Finished ⇧⌘R, —, Select Finished Clips ⌥⌘A, —, Change Selected Clips ▸,
//!   Change All Clips ▸ (Codec, Alpha (DXV / HAP), Source Alpha Type (DXV sources), ProRes Variant, Container (H.264
//!   / HEVC), —, Audio, Audio Rate, —, Size (no Custom… / Manage Sizes… here, as Swift), Resize Quality, Aspect), —,
//!   Encode Queue.
//! - Window (Close ⌘W first: there is no File menu) and Help as SwiftUI gives them.

use crate::job::{Family, JobSettings};
use crate::queue::Queue;
use crate::settings::AlphaMode;
use glance_encode::audio::AudioRate;
use glance_encode::codec::{OutputContainer, ProResVariant};
use glance_encode::size::{AspectMode, OutputSize, ResizeQuality, StandardResolution};
use glance_encode::source::AlphaType;
use glance_ui::menu::muda::accelerator::{Accelerator, CMD_OR_CTRL, Code, Modifiers};
use glance_ui::menu::muda::{AboutMetadata, Menu, MenuItem, PredefinedMenuItem, Submenu};
use std::sync::Arc;

/// A settings edit (Swift's `EncodeQueue.SettingsEdit`).
pub type EditFn = Arc<dyn Fn(&mut JobSettings, Option<bool>) + Send + Sync>;

/// What a "Change … Clips" item does. (The menu bar's Size submenu has no Custom… / Manage Sizes…: Swift's has no
/// sheet to open from there, `SettingsControls.swift:106-109, 145-152`.)
#[derive(Clone)]
pub enum Edit {
    Settings(EditFn),
}

/// A menu command.
#[derive(Clone)]
pub enum Command {
    Preferences,
    TogglePreview,
    SelectAllClips,
    ResetSelected,
    ResetAllFinished,
    SelectFinished,
    EncodeQueue,
    AddFiles,
    Change { all: bool, edit: Edit },
}

/// A labelled item of a "Change … Clips" submenu.
type Item = (String, Edit);

/// One entry of a "Change … Clips" group: an item (enabled or not), a separator, or a text line (a SwiftUI
/// `Section` header or `Text`, drawn as a disabled item: muda has no section header).
enum Entry {
    Item(Item, bool),
    Separator,
    Text(String),
}

/// What a "Change … Clips" submenu shows that depends on its rows (SwiftUI builds these when the menu opens):
/// the Original item's text and the AAC cap of the Audio Rate group.
#[derive(Clone, PartialEq, Default)]
pub struct Targets {
    /// "Original", "Original (1920×1080)" or "Original (mixed)" (`OutputSizeMenuItems.originalLabel(for:)`).
    pub original: String,
    /// Some row writes AAC (`.mp4`): the note "MPEG-4 (AAC) caps at 48 kHz" is shown.
    pub any_aac: bool,
    /// Every row writes AAC: the rates over 48 kHz are disabled (`SettingsMenuItems.swift:77`).
    pub all_aac: bool,
}

impl Targets {
    pub fn of(jobs: &[&crate::job::EncodeJob]) -> Targets {
        Targets {
            original: super::list::rows_logic::original_label(jobs),
            any_aac: jobs.iter().any(|j| j.settings.container.uses_aac()),
            all_aac: !jobs.is_empty() && jobs.iter().all(|j| j.settings.container.uses_aac()),
        }
    }
}

/// What the "Change … Clips" submenus were last built from.
#[derive(Clone, PartialEq)]
struct Shown {
    sizes: Vec<crate::json::NamedSize>,
    selected: Targets,
    all: Targets,
}
/// A fixed item: its muda id and the command.
type Fixed = (&'static str, fn() -> Command);

/// The ten submenus' entries, in Swift's order (`SettingsMenuItems.swift:117-139`).
fn groups(sizes: &[crate::json::NamedSize], t: &Targets) -> Vec<(&'static str, Vec<Entry>)> {
    let e = |f: EditFn| Edit::Settings(f);
    let codec: Vec<Entry> = Family::ALL
        .iter()
        .enumerate()
        .flat_map(|(i, f)| {
            let f = *f;
            let item = Entry::Item((f.label().to_owned(), e(Arc::new(move |s: &mut JobSettings, a| s.select_family(f, a)))), true);
            if i == 4 { vec![Entry::Separator, item] } else { vec![item] }
        })
        .collect();
    let alpha = [AlphaMode::WithoutAlpha, AlphaMode::WithAlpha].iter().map(|m| {
        let m = *m;
        Entry::Item((m.label().to_owned(), e(Arc::new(move |s: &mut JobSettings, _| s.set_alpha(m)))), true)
    });
    let alpha_type = [AlphaType::Premultiplied, AlphaType::Straight].iter().map(|t| {
        let t = *t;
        let label = if t == AlphaType::Premultiplied { "Premultiplied" } else { "Straight" };
        Entry::Item((label.to_owned(), e(Arc::new(move |s: &mut JobSettings, _| s.alpha_type = t))), true)
    });
    let prores = ProResVariant::ALL.iter().map(|v| {
        let v = *v;
        Entry::Item((v.label().to_owned(), e(Arc::new(move |s: &mut JobSettings, _| s.set_prores_variant(v)))), true)
    });
    let container = [OutputContainer::Mov, OutputContainer::Mp4].iter().map(|c| {
        let c = *c;
        Entry::Item((c.label().to_owned(), e(Arc::new(move |s: &mut JobSettings, _| s.set_container(c)))), true)
    });
    let audio = [("Audio: On", true), ("Audio: Off (strip)", false)].iter().map(|(l, on)| {
        let on = *on;
        Entry::Item(((*l).to_owned(), e(Arc::new(move |s: &mut JobSettings, _| s.audio_enabled = on))), true)
    });
    let mut rate: Vec<Entry> = AudioRate::ALL
        .iter()
        .map(|r| {
            let r = *r;
            let unavailable = t.all_aac && r.hz().is_some_and(|hz| hz > 48_000);
            Entry::Item((r.label().to_owned(), e(Arc::new(move |s: &mut JobSettings, _| s.set_audio_rate(r)))), !unavailable)
        })
        .collect();
    if t.any_aac {
        rate.extend([Entry::Separator, Entry::Text("MPEG-4 (AAC) caps at 48 kHz".into())]);
    }
    // `OutputSizeMenuItems` (`SettingsControls.swift:101-152`): Original, then each SwiftUI `Section` as a separator,
    // its header and its items, closed by a separator (AppKit's rendering, read through Accessibility).
    let size_item = |label: String, sz: OutputSize| Entry::Item((label, e(Arc::new(move |s: &mut JobSettings, _| s.output_size = sz))), true);
    let mut size = vec![size_item(t.original.clone(), OutputSize::Original)];
    let mut section = |header: &str, items: Vec<Entry>| {
        size.extend([Entry::Separator, Entry::Text(header.into())]);
        size.extend(items);
        size.push(Entry::Separator);
    };
    if !sizes.is_empty() {
        section("My Sizes", sizes.iter().map(|n| size_item(n.label(), OutputSize::Custom { width: n.width, height: n.height })).collect());
    }
    let presets: Vec<Entry> = StandardResolution::ALL.iter().map(|p| size_item(p.label().to_owned(), OutputSize::Preset(*p))).collect();
    let mut presets = presets.into_iter();
    for (header, n) in [("HD / UHD", 4), ("DCI Cinema", 2), ("Square", 3), ("Vertical", 3)] {
        section(header, presets.by_ref().take(n).collect());
    }
    let quality = ResizeQuality::ALL.iter().map(|q| {
        let q = *q;
        Entry::Item((q.label().to_owned(), e(Arc::new(move |s: &mut JobSettings, _| s.resize_quality = q))), true)
    });
    let aspect = [AspectMode::Letterbox, AspectMode::DistortToFill].iter().map(|m| {
        let m = *m;
        Entry::Item((m.label().to_owned(), e(Arc::new(move |s: &mut JobSettings, _| s.aspect = m))), true)
    });
    vec![
        ("Codec", codec),
        ("Alpha (DXV / HAP)", alpha.collect()),
        ("Source Alpha Type (DXV sources)", alpha_type.collect()),
        ("ProRes Variant", prores.collect()),
        ("Container (H.264 / HEVC)", container.collect()),
        ("Audio", audio.collect()),
        ("Audio Rate", rate),
        ("Size", size),
        ("Resize Quality", quality.collect()),
        ("Aspect", aspect.collect()),
    ]
}

const FIXED: [Fixed; 8] = [
    ("glenc.preferences", || Command::Preferences),
    ("glenc.toggle-preview", || Command::TogglePreview),
    ("glenc.select-all-clips", || Command::SelectAllClips),
    ("glenc.reset-selected", || Command::ResetSelected),
    ("glenc.reset-all-finished", || Command::ResetAllFinished),
    ("glenc.select-finished", || Command::SelectFinished),
    ("glenc.encode-queue", || Command::EncodeQueue),
    ("glenc.add-files", || Command::AddFiles),
];

thread_local! {
    /// The "Change … Clips" items currently in the menu, by id (rebuilt when the saved sizes change).
    static CHANGE: std::cell::RefCell<Vec<(String, Command)>> = const { std::cell::RefCell::new(Vec::new()) };
}

impl Command {
    pub fn from_id(id: &str) -> Option<Command> {
        if let Some((_, f)) = FIXED.iter().find(|(i, _)| *i == id) {
            return Some(f());
        }
        CHANGE.with(|c| c.borrow().iter().find(|(i, _)| i == id).map(|(_, c)| c.clone()))
    }
}

fn err(e: glance_ui::menu::muda::Error) -> String {
    e.to_string()
}

fn fixed(id: &str, title: &str, accel: Option<Accelerator>) -> MenuItem {
    MenuItem::with_id(id, title, true, accel)
}

/// The menu bar and the items that follow the queue's state.
pub struct GlEncMenu {
    pub menu: Menu,
    toggle_preview: MenuItem,
    select_all_clips: MenuItem,
    reset_selected: MenuItem,
    reset_all: MenuItem,
    select_finished: MenuItem,
    change_selected: Submenu,
    change_all: Submenu,
    encode: MenuItem,
    window_menu: Submenu,
    help_menu: Submenu,
    shown: Option<Shown>,
}

fn fill_change(sub: &Submenu, all: bool, sizes: &[crate::json::NamedSize], t: &Targets) -> Result<Vec<(String, Command)>, String> {
    while sub.remove_at(0).is_some() {}
    let mut ids = Vec::new();
    for (gi, (title, items)) in groups(sizes, t).into_iter().enumerate() {
        if matches!(gi, 5 | 7) {
            sub.append(&PredefinedMenuItem::separator()).map_err(err)?;
        }
        let g = Submenu::new(title, true);
        for (ii, it) in items.into_iter().enumerate() {
            match it {
                Entry::Separator => g.append(&PredefinedMenuItem::separator()).map_err(err)?,
                Entry::Text(text) => g.append(&MenuItem::new(text, false, None)).map_err(err)?,
                Entry::Item((label, edit), enabled) => {
                    let id = format!("glenc.change.{}.{gi}.{ii}", if all { "all" } else { "sel" });
                    g.append(&MenuItem::with_id(id.clone(), label, enabled, None)).map_err(err)?;
                    ids.push((id, Command::Change { all, edit }));
                }
            }
        }
        sub.append(&g).map_err(err)?;
    }
    Ok(ids)
}

impl GlEncMenu {
    pub fn new(app: &str, version: &str) -> Result<GlEncMenu, String> {
        let s = PredefinedMenuItem::separator;
        let cmd = CMD_OR_CTRL;
        let shift = CMD_OR_CTRL | Modifiers::SHIFT;
        let alt = CMD_OR_CTRL | Modifiers::ALT;
        let about = AboutMetadata { name: Some(app.into()), version: Some(version.into()), ..Default::default() };
        let app_menu = Submenu::with_items(
            app,
            true,
            &[
                &PredefinedMenuItem::about(Some(&format!("About {app}")), Some(about)),
                &s(),
                &fixed("glenc.preferences", "Settings…", Some(Accelerator::new(cmd, Code::Comma))),
                &s(),
                &PredefinedMenuItem::services(None),
                &s(),
                &PredefinedMenuItem::hide(Some(&format!("Hide {app}"))),
                &PredefinedMenuItem::hide_others(None),
                &PredefinedMenuItem::show_all(None),
                &s(),
                &PredefinedMenuItem::quit(Some(&format!("Quit {app}"))),
            ],
        )
        .map_err(err)?;
        let select_all_clips = fixed("glenc.select-all-clips", "Select All Clips", Some(Accelerator::new(shift, Code::KeyA)));
        let edit = Submenu::with_items(
            "Edit",
            true,
            &[
                &PredefinedMenuItem::undo(None),
                &PredefinedMenuItem::redo(None),
                &s(),
                &PredefinedMenuItem::cut(None),
                &PredefinedMenuItem::copy(None),
                &PredefinedMenuItem::paste(None),
                &PredefinedMenuItem::delete(None),
                &PredefinedMenuItem::select_all(None),
                &select_all_clips,
            ],
        )
        .map_err(err)?;
        let toggle_preview = fixed("glenc.toggle-preview", "Hide Preview Pane", Some(Accelerator::new(shift, Code::KeyP)));
        let view = Submenu::with_items("View", true, &[&toggle_preview]).map_err(err)?;
        let reset_selected = fixed("glenc.reset-selected", "Reset Selected", Some(Accelerator::new(cmd, Code::KeyR)));
        let reset_all = fixed("glenc.reset-all-finished", "Reset All Finished", Some(Accelerator::new(shift, Code::KeyR)));
        let select_finished = fixed("glenc.select-finished", "Select Finished Clips", Some(Accelerator::new(alt, Code::KeyA)));
        let change_selected = Submenu::new("Change Selected Clips", true);
        let change_all = Submenu::new("Change All Clips", true);
        let encode = fixed("glenc.encode-queue", "Encode Queue", None);
        let queue =
            Submenu::with_items("Queue", true, &[&reset_selected, &reset_all, &s(), &select_finished, &s(), &change_selected, &change_all, &s(), &encode])
                .map_err(err)?;
        // SwiftUI's single-`Window` app has no File menu: Close sits first in the Window menu (AppKit adds Close All,
        // Minimize All, Zoom All, Fill, Center, Move & Resize, Full Screen Tile, Arrange in Front, Remove Window from Set).
        let window_menu = Submenu::with_items(
            "Window",
            true,
            &[
                &PredefinedMenuItem::close_window(Some("Close")),
                &PredefinedMenuItem::minimize(None),
                &PredefinedMenuItem::maximize(Some("Zoom")),
                // Two, as SwiftUI's Window menu has them before Bring All to Front (read through Accessibility).
                &s(),
                &s(),
                &PredefinedMenuItem::bring_all_to_front(None),
            ],
        )
        .map_err(err)?;
        let help_menu = Submenu::new("Help", true);
        let menu = Menu::with_items(&[&app_menu, &edit, &view, &queue, &window_menu, &help_menu]).map_err(err)?;
        let mut m = GlEncMenu {
            menu,
            toggle_preview,
            select_all_clips,
            reset_selected,
            reset_all,
            select_finished,
            change_selected,
            change_all,
            encode,
            window_menu,
            help_menu,
            shown: None,
        };
        m.rebuild_change(Shown { sizes: Vec::new(), selected: Targets::of(&[]), all: Targets::of(&[]) })?;
        Ok(m)
    }

    fn rebuild_change(&mut self, shown: Shown) -> Result<(), String> {
        let mut ids = fill_change(&self.change_selected, false, &shown.sizes, &shown.selected)?;
        ids.extend(fill_change(&self.change_all, true, &shown.sizes, &shown.all)?);
        CHANGE.with(|c| *c.borrow_mut() = ids);
        self.shown = Some(shown);
        Ok(())
    }

    /// Titles and enabled states from the queue (`GlEncApp.swift:91-137`).
    pub fn sync(&mut self, q: &Queue) {
        let v = q.settings.values();
        self.toggle_preview.set_text(if v.preview_pane_visible_by_default { "Hide Preview Pane" } else { "Show Preview Pane" });
        self.select_all_clips.set_enabled(!q.jobs.is_empty());
        self.reset_selected.set_enabled(!q.is_encoding() && q.selection_has_finished());
        self.reset_all.set_enabled(!q.is_encoding() && q.has_finished());
        self.select_finished.set_enabled(q.has_finished());
        self.change_selected.set_enabled(!q.selected_ids.is_empty());
        self.change_all.set_enabled(!q.jobs.is_empty());
        self.encode.set_enabled(!q.is_encoding() && q.jobs.iter().any(|j| j.status == crate::job::Status::Queued));
        let selected: Vec<&crate::job::EncodeJob> = q.jobs.iter().filter(|j| q.selected_ids.contains(&j.id)).collect();
        let all: Vec<&crate::job::EncodeJob> = q.jobs.iter().collect();
        let want = Shown { sizes: v.custom_presets.clone(), selected: Targets::of(&selected), all: Targets::of(&all) };
        if self.shown.as_ref() != Some(&want) {
            let _ = self.rebuild_change(want);
        }
    }
}

impl glance_ui::menu::MenuBar for GlEncMenu {
    #[cfg(target_os = "macos")]
    fn attach_to_app(&self) -> Result<(), String> {
        glance_ui::menu::attach_menu_bar(&self.menu, &self.window_menu, &self.help_menu, "GlEnc")
    }
    fn menu(&self) -> &Menu {
        &self.menu
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// (text, enabled) of a group's entries; separators as "---".
    fn entries(t: &Targets, group: &str) -> Vec<(String, bool)> {
        let mut gs = groups(&[], t);
        let Some(i) = gs.iter().position(|(g, _)| *g == group) else { return Vec::new() };
        gs.swap_remove(i)
            .1
            .into_iter()
            .map(|e| match e {
                Entry::Item((label, _), on) => (label, on),
                Entry::Separator => ("---".into(), false),
                Entry::Text(t) => (t, false),
            })
            .collect()
    }

    #[test]
    fn the_audio_rate_note_and_cap_follow_the_targets_like_swifts_settings_menu_items() {
        let mov = Targets { original: "Original".into(), any_aac: false, all_aac: false };
        let rates = entries(&mov, "Audio Rate");
        assert!(rates.iter().all(|(_, on)| *on) && !rates.iter().any(|(t, _)| t.contains("AAC")));
        let mixed = Targets { any_aac: true, ..mov.clone() };
        let rates = entries(&mixed, "Audio Rate");
        assert_eq!(rates.last().map(|(t, _)| t.as_str()), Some("MPEG-4 (AAC) caps at 48 kHz"));
        assert!(rates.iter().filter(|(t, _)| t.ends_with("kHz") && !t.contains("AAC")).all(|(_, on)| *on));
        let mp4 = Targets { any_aac: true, all_aac: true, ..mov };
        let off: Vec<String> =
            entries(&mp4, "Audio Rate").into_iter().filter(|(t, on)| !on && t.ends_with("kHz") && !t.contains("AAC")).map(|(t, _)| t).collect();
        assert_eq!(off, ["88.2 kHz", "96 kHz"]);
    }

    #[test]
    fn the_size_group_is_original_then_swifts_sections() {
        let t = Targets { original: "Original (512×288)".into(), any_aac: false, all_aac: false };
        let texts: Vec<String> = entries(&t, "Size").into_iter().map(|(t, _)| t).collect();
        assert_eq!(texts.first().map(String::as_str), Some("Original (512×288)"));
        let headers: Vec<&str> =
            texts.iter().map(String::as_str).filter(|t| ["HD / UHD", "DCI Cinema", "Square", "Vertical", "My Sizes"].contains(t)).collect();
        assert_eq!(headers, ["HD / UHD", "DCI Cinema", "Square", "Vertical"]);
        assert_eq!(texts.len(), 1 + 4 * 3 + 12);
    }
}
