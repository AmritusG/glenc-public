//! The crop overlay's pure math: Swift `CropDragMath.swift` (corner resize, arrow-key corner resize, interior
//! translation, the full-frame seed, codec-aware snapping), `CropAspectFit.swift` (view ↔ source mapping) and the
//! checkerboard's extent (`PreviewLayerHostingView.checkerboardFrame`). Everything is in source pixels, top-left
//! origin, except [`AspectFit`]'s view side (points).

use glance_encode::frame::CropRect;

/// A rectangle (Swift's `CGRect` as the crop code uses it: non-negative size).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const ZERO: Rect = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };

    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }
    pub fn max_x(self) -> f64 {
        self.x + self.w
    }
    pub fn max_y(self) -> f64 {
        self.y + self.h
    }
    pub fn contains(self, p: (f64, f64)) -> bool {
        p.0 >= self.x && p.0 < self.max_x() && p.1 >= self.y && p.1 < self.max_y()
    }
    pub fn corner(self, c: Corner) -> (f64, f64) {
        match c {
            Corner::TopLeft => (self.x, self.y),
            Corner::TopRight => (self.max_x(), self.y),
            Corner::BottomLeft => (self.x, self.max_y()),
            Corner::BottomRight => (self.max_x(), self.max_y()),
        }
    }
    pub fn from_crop(c: CropRect) -> Rect {
        Rect::new(f64::from(c.x), f64::from(c.y), f64::from(c.width), f64::from(c.height))
    }
    /// The crop the queue stores (the math only makes whole pixels; rounding is a guard).
    pub fn to_crop(self) -> CropRect {
        let px = |v: f64| if v.is_finite() { v.round().clamp(0.0, f64::from(u32::MAX)) as u32 } else { 0 };
        CropRect { x: px(self.x), y: px(self.y), width: px(self.w), height: px(self.h) }
    }
}

/// Which corner a resize moves; the opposite one stays (`CropDragMath.swift:43-45`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Corner {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

impl Corner {
    /// `Corner.allCases`, in the overlay's drawing order.
    pub const ALL: [Corner; 4] = [Corner::TopLeft, Corner::TopRight, Corner::BottomLeft, Corner::BottomRight];
    fn is_left(self) -> bool {
        matches!(self, Corner::TopLeft | Corner::BottomLeft)
    }
    fn is_top(self) -> bool {
        matches!(self, Corner::TopLeft | Corner::TopRight)
    }
}

/// `roundedToMultiple(_:of:)` (`ResizeCustomSheet.swift:51-57`): nearest multiple, ties up, at least `alignment`;
/// alignment 1 is "any pixel" (`max(1, n)`).
pub fn rounded_to_multiple(n: i64, alignment: i64) -> i64 {
    let a = alignment.max(1);
    if a == 1 {
        return n.max(1);
    }
    if n <= 0 {
        return a;
    }
    let rounded = (n.saturating_add(a / 2) / a) * a;
    rounded.max(a)
}

/// `snapCoordinate` (`:244-250`): a coordinate may be 0 (the rounder floors at `alignment`).
fn snap_coordinate(c: f64, alignment: i64) -> f64 {
    let n = if c.is_finite() { c.round() as i64 } else { 0 };
    let a = alignment.max(1);
    if a == 1 {
        return n.max(0) as f64;
    }
    if n <= 1 {
        return 0.0;
    }
    rounded_to_multiple(n, a) as f64
}

/// `alignedMax` (`:257-260`): the largest aligned edge not past `dim`.
fn aligned_max(dim: i64, alignment: i64) -> f64 {
    let a = alignment.max(1);
    ((dim / a) * a).max(0) as f64
}

/// `snappedResizedRect` (`:78-135`): the dragged corner snapped and clamped into the source, the opposite corner
/// fixed, at least `alignment` from it (a drag past it collapses, never inverts).
pub fn snapped_resized_rect(original: Rect, dragged: Corner, new_corner: (f64, f64), source_w: i64, source_h: i64, alignment: i64) -> Rect {
    let a = alignment.max(1);
    let af = a as f64;
    let max_x = aligned_max(source_w, a);
    let max_y = aligned_max(source_h, a);
    let (fixed_x, fixed_y) = original.corner(match dragged {
        Corner::TopLeft => Corner::BottomRight,
        Corner::TopRight => Corner::BottomLeft,
        Corner::BottomLeft => Corner::TopRight,
        Corner::BottomRight => Corner::TopLeft,
    });
    let snapped_x = snap_coordinate(new_corner.0, a).max(0.0).min(max_x);
    let snapped_y = snap_coordinate(new_corner.1, a).max(0.0).min(max_y);
    let (x, w) = if dragged.is_left() {
        let x = snapped_x.min(fixed_x - af).max(0.0);
        (x, fixed_x - x)
    } else {
        let x = snapped_x.max(fixed_x + af).min(max_x);
        (fixed_x, x - fixed_x)
    };
    let (y, h) = if dragged.is_top() {
        let y = snapped_y.min(fixed_y - af).max(0.0);
        (y, fixed_y - y)
    } else {
        let y = snapped_y.max(fixed_y + af).min(max_y);
        (fixed_y, y - fixed_y)
    };
    Rect::new(x, y, w, h)
}

/// `snappedResizeFromCorner` (`:157-182`): an arrow press with a focused corner moves that corner by `delta`.
pub fn snapped_resize_from_corner(rect: Rect, corner: Corner, delta: (f64, f64), source_w: i64, source_h: i64, alignment: i64) -> Rect {
    let (cx, cy) = rect.corner(corner);
    snapped_resized_rect(rect, corner, (cx + delta.0, cy + delta.1), source_w, source_h, alignment)
}

/// `snappedTranslatedRect` (`:198-218`): the origin moved and snapped, the whole rect kept inside, size unchanged.
pub fn snapped_translated_rect(original: Rect, translation: (f64, f64), source_w: i64, source_h: i64, alignment: i64) -> Rect {
    let max_x = aligned_max(source_w, alignment);
    let max_y = aligned_max(source_h, alignment);
    let sx = snap_coordinate(original.x + translation.0, alignment);
    let sy = snap_coordinate(original.y + translation.1, alignment);
    Rect::new(sx.min(max_x - original.w).max(0.0), sy.min(max_y - original.h).max(0.0), original.w, original.h)
}

/// `fullFrameSeedRect` (`:231-235`): the whole source, each side rounded down to the alignment.
pub fn full_frame_seed_rect(source_w: i64, source_h: i64, alignment: i64) -> Rect {
    Rect::new(0.0, 0.0, aligned_max(source_w, alignment), aligned_max(source_h, alignment))
}

/// The arrow-key step in source pixels (`PreviewPane.handleCropNudge`, `:356`): 4, 16 with ⇧.
pub fn nudge_step(shift: bool) -> f64 {
    if shift { 16.0 } else { 4.0 }
}

/// One arrow press during a crop edit (`handleCropNudge`, `:351-401`): from the pending rect or the full-frame seed;
/// with a focused corner that corner moves, else the whole rect.
pub fn nudge(pending: Option<Rect>, focused: Option<Corner>, delta: (f64, f64), source_w: i64, source_h: i64, alignment: i64) -> Rect {
    let base = pending.unwrap_or_else(|| full_frame_seed_rect(source_w, source_h, alignment));
    match focused {
        Some(c) => snapped_resize_from_corner(base, c, delta, source_w, source_h, alignment),
        None => snapped_translated_rect(base, delta, source_w, source_h, alignment),
    }
}

/// `CropAspectFit`: the source aspect-fitted and centred in the view, and the mapping between the two.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AspectFit {
    pub source_w: i64,
    pub source_h: i64,
    pub view: Rect,
    /// Where the picture is (`.zero` for degenerate inputs).
    pub fitted: Rect,
    /// View points per source pixel (0 for degenerate inputs).
    pub scale: f64,
}

impl AspectFit {
    pub fn new(source_w: i64, source_h: i64, view: Rect) -> AspectFit {
        if source_w <= 0 || source_h <= 0 || view.w <= 0.0 || view.h <= 0.0 {
            return AspectFit { source_w, source_h, view, fitted: Rect::ZERO, scale: 0.0 };
        }
        let (sw, sh) = (source_w as f64, source_h as f64);
        let source_aspect = sw / sh;
        let (fw, fh) = if view.w / view.h > source_aspect { (view.h * source_aspect, view.h) } else { (view.w, view.w / source_aspect) };
        let fitted = Rect::new(view.x + (view.w - fw) / 2.0, view.y + (view.h - fh) / 2.0, fw, fh);
        AspectFit { source_w, source_h, view, fitted, scale: fw / sw }
    }
    /// View point → source point, unclamped.
    pub fn source_point(&self, p: (f64, f64)) -> (f64, f64) {
        if self.scale <= 0.0 {
            return (0.0, 0.0);
        }
        ((p.0 - self.fitted.x) / self.scale, (p.1 - self.fitted.y) / self.scale)
    }
    /// Source point → view point.
    pub fn view_point(&self, p: (f64, f64)) -> (f64, f64) {
        if self.scale <= 0.0 {
            return (0.0, 0.0);
        }
        (self.fitted.x + p.0 * self.scale, self.fitted.y + p.1 * self.scale)
    }
    pub fn view_rect(&self, r: Rect) -> Rect {
        if self.scale <= 0.0 {
            return Rect::ZERO;
        }
        let (x, y) = self.view_point((r.x, r.y));
        Rect::new(x, y, r.w * self.scale, r.h * self.scale)
    }
    pub fn source_rect(&self, r: Rect) -> Rect {
        if self.scale <= 0.0 {
            return Rect::ZERO;
        }
        let (x, y) = self.source_point((r.x, r.y));
        Rect::new(x, y, r.w / self.scale, r.h / self.scale)
    }
}

/// `checkerboardFrame` (`PreviewLayerHostingView.swift:166-180`): the whole preview, or only the fitted picture
/// (falling back to the whole preview without source dimensions).
pub fn checkerboard_frame(behind_video_only: bool, source_w: i64, source_h: i64, bounds: Rect) -> Rect {
    if !behind_video_only || source_w <= 0 || source_h <= 0 || bounds.w <= 0.0 || bounds.h <= 0.0 {
        return bounds;
    }
    AspectFit::new(source_w, source_h, bounds).fitted
}

#[cfg(test)]
mod tests {
    //! `CropDragMathTests.swift` case for case (1920 × 1080, alignment 4 — Swift's default), then the codec-aware
    //! snapping, the nudge, `CropAspectFitTests` and `CheckerboardScopeTests`.
    use super::*;

    const W: i64 = 1920;
    const H: i64 = 1080;
    const A: i64 = 4;

    fn r(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect::new(x, y, w, h)
    }

    #[test]
    fn resize_top_left_inward() {
        let x = snapped_resized_rect(r(0.0, 0.0, 1920.0, 1080.0), Corner::TopLeft, (200.0, 100.0), W, H, A);
        assert_eq!(x, r(200.0, 100.0, 1720.0, 980.0));
        assert_eq!((x.max_x(), x.max_y()), (1920.0, 1080.0));
    }

    #[test]
    fn resize_bottom_right_outward() {
        let x = snapped_resized_rect(r(200.0, 100.0, 1000.0, 600.0), Corner::BottomRight, (1400.0, 800.0), W, H, A);
        assert_eq!((x.x, x.y, x.max_x(), x.max_y()), (200.0, 100.0, 1400.0, 800.0));
    }

    #[test]
    fn resize_top_right_opposite_fixed() {
        let x = snapped_resized_rect(r(200.0, 100.0, 1000.0, 600.0), Corner::TopRight, (1300.0, 48.0), W, H, A);
        assert_eq!((x.x, x.max_y(), x.max_x(), x.y), (200.0, 700.0, 1300.0, 48.0));
    }

    #[test]
    fn resize_bottom_left_opposite_fixed() {
        let x = snapped_resized_rect(r(200.0, 100.0, 1000.0, 600.0), Corner::BottomLeft, (300.0, 900.0), W, H, A);
        assert_eq!((x.max_x(), x.y, x.x, x.max_y()), (1200.0, 100.0, 300.0, 900.0));
    }

    #[test]
    fn resize_drag_past_opposite_collapses_to_the_floor() {
        let x = snapped_resized_rect(r(200.0, 100.0, 1000.0, 600.0), Corner::TopLeft, (5000.0, 5000.0), W, H, A);
        assert_eq!((x.w, x.h), (4.0, 4.0));
        assert_eq!((x.max_x(), x.max_y()), (1200.0, 700.0));
    }

    #[test]
    fn resize_drag_outside_bounds_clamps() {
        let x = snapped_resized_rect(r(200.0, 100.0, 1000.0, 600.0), Corner::TopLeft, (-80.0, -40.0), W, H, A);
        assert_eq!((x.x, x.y), (0.0, 0.0));
        assert_eq!(x.w as i64 % 4, 0);
        assert_eq!(x.h as i64 % 4, 0);
    }

    #[test]
    fn resize_snaps_non_aligned_input() {
        // 101.7 → 102 → 104; 50.3 → 50 → 52 (ties round up).
        let x = snapped_resized_rect(r(0.0, 0.0, 1920.0, 1080.0), Corner::TopLeft, (101.7, 50.3), W, H, A);
        assert_eq!((x.x, x.y), (104.0, 52.0));
    }

    #[test]
    fn translate_snaps_non_aligned_to_four() {
        let x = snapped_translated_rect(r(100.0, 100.0, 400.0, 200.0), (7.0, 3.0), W, H, A);
        assert_eq!(x, r(108.0, 104.0, 400.0, 200.0));
    }

    #[test]
    fn translate_off_each_edge_clamps() {
        let o = r(100.0, 100.0, 400.0, 200.0);
        assert_eq!(snapped_translated_rect(o, (-500.0, 0.0), W, H, A).x, 0.0);
        let right = snapped_translated_rect(o, (5000.0, 0.0), W, H, A);
        assert_eq!((right.max_x(), right.w), (1920.0, 400.0));
        assert_eq!(snapped_translated_rect(o, (0.0, -500.0), W, H, A).y, 0.0);
        let bottom = snapped_translated_rect(o, (0.0, 5000.0), W, H, A);
        assert_eq!((bottom.max_y(), bottom.h), (1080.0, 200.0));
    }

    #[test]
    fn corner_resize_by_arrow_each_corner() {
        let o = r(320.0, 180.0, 1280.0, 720.0);
        assert_eq!(snapped_resize_from_corner(o, Corner::TopLeft, (-4.0, -4.0), W, H, A), r(316.0, 176.0, 1284.0, 724.0));
        assert_eq!(snapped_resize_from_corner(o, Corner::TopRight, (4.0, -4.0), W, H, A), r(320.0, 176.0, 1284.0, 724.0));
        assert_eq!(snapped_resize_from_corner(o, Corner::BottomLeft, (-4.0, 4.0), W, H, A), r(316.0, 180.0, 1284.0, 724.0));
        assert_eq!(snapped_resize_from_corner(o, Corner::BottomRight, (4.0, 4.0), W, H, A), r(320.0, 180.0, 1284.0, 724.0));
    }

    #[test]
    fn corner_resize_snaps_and_clamps() {
        let o = r(320.0, 180.0, 1280.0, 720.0);
        assert_eq!(snapped_resize_from_corner(o, Corner::BottomRight, (3.0, 3.0), W, H, A), r(320.0, 180.0, 1284.0, 724.0));
        assert_eq!(snapped_resize_from_corner(r(4.0, 4.0, 1280.0, 720.0), Corner::TopLeft, (-100.0, -100.0), W, H, A), r(0.0, 0.0, 1284.0, 724.0));
        assert_eq!(snapped_resize_from_corner(r(0.0, 0.0, 1280.0, 720.0), Corner::TopLeft, (10000.0, 10000.0), W, H, A), r(1276.0, 716.0, 4.0, 4.0));
        let tl = snapped_resize_from_corner(o, Corner::TopLeft, (16.0, 8.0), W, H, A);
        assert_eq!((tl.max_x(), tl.max_y()), (1600.0, 900.0), "bottom-right fixed");
        let br = snapped_resize_from_corner(o, Corner::BottomRight, (16.0, 8.0), W, H, A);
        assert_eq!((br.x, br.y), (320.0, 180.0), "top-left fixed");
    }

    #[test]
    fn full_frame_seed_is_the_source_for_aligned_dims() {
        assert_eq!(full_frame_seed_rect(W, H, A), r(0.0, 0.0, 1920.0, 1080.0));
        // An odd source rounds down to the alignment, never past the source.
        assert_eq!(full_frame_seed_rect(1923, 1081, 4), r(0.0, 0.0, 1920.0, 1080.0));
        assert_eq!(full_frame_seed_rect(1923, 1081, 2), r(0.0, 0.0, 1922.0, 1080.0));
        assert_eq!(full_frame_seed_rect(1923, 1081, 1), r(0.0, 0.0, 1923.0, 1081.0));
    }

    #[test]
    fn codec_alignment_rounding() {
        // ResizeCustomSheet.roundedToMultiple: nearest, ties up, floored at the alignment; 1 = any pixel.
        assert_eq!(rounded_to_multiple(101, 4), 100);
        assert_eq!(rounded_to_multiple(102, 4), 104);
        assert_eq!(rounded_to_multiple(1, 4), 4);
        assert_eq!(rounded_to_multiple(-3, 4), 4);
        assert_eq!(rounded_to_multiple(101, 2), 102);
        assert_eq!(rounded_to_multiple(100, 2), 100);
        assert_eq!(rounded_to_multiple(101, 1), 101);
        assert_eq!(rounded_to_multiple(0, 1), 1);
        assert_eq!(rounded_to_multiple(7, 0), 7, "alignment below 1 is 1");
        // Coordinates may be 0; pixel-exact codecs (ProRes, DXV, HAP, MJPEG) never snap.
        let o = r(0.0, 0.0, 1920.0, 1080.0);
        assert_eq!(snapped_resized_rect(o, Corner::TopLeft, (101.4, 50.6), W, H, 1), r(101.0, 51.0, 1819.0, 1029.0));
        // H.264 / HEVC: even edges.
        assert_eq!(snapped_resized_rect(o, Corner::TopLeft, (101.4, 50.6), W, H, 2), r(102.0, 52.0, 1818.0, 1028.0));
        assert_eq!(snapped_translated_rect(r(10.0, 10.0, 100.0, 100.0), (-9.0, -10.4), W, H, 2), r(0.0, 0.0, 100.0, 100.0));
        assert_eq!(snapped_translated_rect(r(10.0, 10.0, 100.0, 100.0), (1.0, 0.0), W, H, 1), r(11.0, 10.0, 100.0, 100.0));
        // The floor from the opposite corner is the alignment.
        assert_eq!(snapped_resized_rect(r(10.0, 10.0, 100.0, 100.0), Corner::BottomRight, (0.0, 0.0), W, H, 1), r(10.0, 10.0, 1.0, 1.0));
        assert_eq!(snapped_resized_rect(r(10.0, 10.0, 100.0, 100.0), Corner::BottomRight, (0.0, 0.0), W, H, 2), r(10.0, 10.0, 2.0, 2.0));
    }

    #[test]
    fn nudge_moves_the_rect_or_the_focused_corner() {
        assert_eq!(nudge_step(false), 4.0);
        assert_eq!(nudge_step(true), 16.0);
        // No pending crop yet: seeded from the full frame, so a right nudge of the full frame stays put.
        assert_eq!(nudge(None, None, (4.0, 0.0), W, H, 1), r(0.0, 0.0, 1920.0, 1080.0));
        // …while a corner nudge shrinks it.
        assert_eq!(nudge(None, Some(Corner::TopLeft), (16.0, 0.0), W, H, 1), r(16.0, 0.0, 1904.0, 1080.0));
        let p = r(100.0, 100.0, 400.0, 200.0);
        assert_eq!(nudge(Some(p), None, (0.0, -4.0), W, H, 1), r(100.0, 96.0, 400.0, 200.0));
        assert_eq!(nudge(Some(p), None, (-16.0, 0.0), W, H, 2), r(84.0, 100.0, 400.0, 200.0));
        assert_eq!(nudge(Some(p), Some(Corner::BottomRight), (4.0, 4.0), W, H, 1), r(100.0, 100.0, 404.0, 204.0));
    }

    #[test]
    fn crop_rect_round_trip() {
        let c = CropRect { x: 8, y: 4, width: 640, height: 360 };
        assert_eq!(Rect::from_crop(c).to_crop(), c);
        assert_eq!(r(-3.0, f64::NAN, 10.4, 10.6).to_crop(), CropRect { x: 0, y: 0, width: 10, height: 11 });
    }

    #[test]
    fn aspect_fit_matches_swift() {
        let square = AspectFit::new(512, 512, r(0.0, 0.0, 400.0, 400.0));
        assert_eq!(square.fitted, r(0.0, 0.0, 400.0, 400.0));
        assert!((square.scale - 400.0 / 512.0).abs() < 1e-9);
        let pillar = AspectFit::new(512, 512, r(0.0, 0.0, 800.0, 400.0));
        assert_eq!(pillar.fitted, r(200.0, 0.0, 400.0, 400.0));
        let letter = AspectFit::new(1920, 1080, r(0.0, 0.0, 800.0, 800.0));
        assert_eq!(letter.fitted, r(0.0, 175.0, 800.0, 450.0));
        let o = r(320.0, 180.0, 1280.0, 720.0);
        let back = letter.source_rect(letter.view_rect(o));
        assert!((back.x - o.x).abs() < 1e-9 && (back.y - o.y).abs() < 1e-9 && (back.w - o.w).abs() < 1e-9 && (back.h - o.h).abs() < 1e-9);
        assert_eq!(letter.view_point((0.0, 0.0)), (0.0, 175.0), "top-left origin, no flip");
        assert_eq!(letter.view_point((0.0, 1080.0)), (0.0, 625.0));
        assert!(letter.source_point((10.0, 10.0)).1 < 0.0, "a point in the bar maps outside the source");
        let none = AspectFit::new(0, 0, r(0.0, 0.0, 100.0, 100.0));
        assert_eq!((none.fitted, none.scale, none.source_point((10.0, 10.0))), (Rect::ZERO, 0.0, (0.0, 0.0)));
        let empty = AspectFit::new(1920, 1080, Rect::ZERO);
        assert_eq!((empty.fitted, empty.scale), (Rect::ZERO, 0.0));
    }

    #[test]
    fn checkerboard_extent() {
        let b = r(0.0, 0.0, 800.0, 800.0);
        assert_eq!(checkerboard_frame(false, 1920, 1080, b), b, "Fill viewport");
        assert_eq!(checkerboard_frame(true, 1920, 1080, b), r(0.0, 175.0, 800.0, 450.0), "Behind video only");
        assert_eq!(checkerboard_frame(true, 512, 512, b), b);
        assert_eq!(checkerboard_frame(true, 0, 0, b), b, "no dims: never unframed");
        assert_eq!(checkerboard_frame(true, 1920, 1080, Rect::ZERO), Rect::ZERO);
    }
}
