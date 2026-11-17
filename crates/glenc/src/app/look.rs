//! GlEnc's look: SwiftUI's stock macOS controls in the system's dark appearance (Swift GlEnc sets no colours of its
//! own besides `.secondary`, `accentColor` and grey opacities). The values are the system's dark-mode colours,
//! measured on Swift GlEnc's window (docs/data/e5/look) where noted.

use egui::Color32;

/// `NSColor.windowBackgroundColor` (dark).
pub const WINDOW: Color32 = Color32::from_rgb(30, 30, 30);
/// `controlBackgroundColor` / list background (dark).
pub const LIST: Color32 = Color32::from_rgb(30, 30, 30);
/// The selected row (`selectedContentBackgroundColor`, accent blue).
pub const SELECTED_ROW: Color32 = Color32::from_rgb(0, 88, 208);
/// Primary text (`labelColor` dark: white 85 %).
pub const TEXT: Color32 = Color32::from_rgb(223, 223, 223);
/// `.secondary` (`secondaryLabelColor` dark: white 55 %).
pub const SECONDARY: Color32 = Color32::from_rgb(152, 152, 152);
/// `.tertiary`.
pub const TERTIARY: Color32 = Color32::from_rgb(98, 98, 98);
/// The system accent (blue).
pub const ACCENT: Color32 = Color32::from_rgb(10, 132, 255);
/// `Divider()` / `separatorColor` (dark).
pub const SEPARATOR: Color32 = Color32::from_rgb(56, 56, 56);
/// A push button's face (dark).
pub const BUTTON: Color32 = Color32::from_rgb(78, 78, 78);
/// Red (`systemRed`, failed rows).
pub const RED: Color32 = Color32::from_rgb(255, 69, 58);
/// Orange (`systemOrange`, warnings).
pub const ORANGE: Color32 = Color32::from_rgb(255, 159, 10);
/// Green (`systemGreen`, done).
pub const GREEN: Color32 = Color32::from_rgb(50, 215, 75);

/// Font sizes of SwiftUI's text styles on macOS (points).
pub mod size {
    pub const BODY: f32 = 13.0;
    pub const CALLOUT: f32 = 12.0;
    pub const CAPTION: f32 = 10.0;
    pub const HEADLINE: f32 = 13.0;
    pub const SMALL_CONTROL: f32 = 11.0;
}

/// egui's visuals for GlEnc (dark, the system font from glance-ui).
pub fn apply(ctx: &egui::Context) {
    glance_ui::apply_look(ctx);
    let mut v = egui::Visuals::dark();
    v.panel_fill = WINDOW;
    v.window_fill = WINDOW;
    v.extreme_bg_color = Color32::from_rgb(20, 20, 20);
    v.selection.bg_fill = SELECTED_ROW;
    v.hyperlink_color = ACCENT;
    v.override_text_color = Some(TEXT);
    v.widgets.inactive.weak_bg_fill = BUTTON;
    v.widgets.inactive.bg_fill = BUTTON;
    ctx.set_visuals(v);
}
