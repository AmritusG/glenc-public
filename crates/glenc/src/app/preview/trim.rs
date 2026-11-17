//! The In / Out rules of the preview (Swift `PreviewPlayerModel.swift` trim, `ScrubBar.swift` geometry and drags).
//! Frames are inclusive file frame indices; `None` is "no trim on that side". Pure, tested headless.

/// A row's In / Out (`EncodeJob.inFrame` / `outFrame`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Trim {
    pub in_frame: Option<i64>,
    pub out_frame: Option<i64>,
}

impl Trim {
    pub fn new(in_frame: Option<i64>, out_frame: Option<i64>) -> Trim {
        Trim { in_frame, out_frame }
    }

    pub fn is_set(self) -> bool {
        self.in_frame.is_some() || self.out_frame.is_some()
    }

    /// Set In (I) at the playhead; an Out before it moves to the playhead too (`setInAtCurrentFrame`, `:573-580`).
    pub fn set_in_at(self, current: i64) -> Trim {
        let out_frame = match self.out_frame {
            Some(o) if o < current => Some(current),
            o => o,
        };
        Trim { in_frame: Some(current), out_frame }
    }

    /// Set Out (O) at the playhead; an In after it moves to the playhead too (`setOutAtCurrentFrame`, `:584-591`).
    pub fn set_out_at(self, current: i64) -> Trim {
        let in_frame = match self.in_frame {
            Some(i) if i > current => Some(current),
            i => i,
        };
        Trim { in_frame, out_frame: Some(current) }
    }

    /// The In a drag on the bar's left half (or the In popover) lands on: at least 0, at most one before Out (or
    /// before the last frame) (`ScrubBar.swift:96-98`, `:137-139`).
    pub fn dragged_in(self, target: i64, total: i64) -> i64 {
        let last = total - 1;
        let out_clamp = self.out_frame.unwrap_or(last);
        target.min((out_clamp - 1).max(0)).max(0)
    }

    /// The Out a drag on the bar's right half (or the Out popover) lands on: at most the last frame, at least one
    /// after In (`ScrubBar.swift:112-114`, `:141-143`).
    pub fn dragged_out(self, target: i64, total: i64) -> i64 {
        let last = (total - 1).max(0);
        let in_clamp = self.in_frame.unwrap_or(0);
        target.max(in_clamp + 1).min(last)
    }

    /// The playable window `[lo, hi]` while a trim is set (`snapPlayheadIntoTrimIfNeeded` / `enforceTrimBoundary`).
    pub fn window(self, total: i64) -> Option<(i64, i64)> {
        self.is_set().then(|| (self.in_frame.unwrap_or(0), self.out_frame.unwrap_or(total - 1)))
    }

    /// Play from a playhead outside the window starts at In (`snapPlayheadIntoTrimIfNeeded`, `:492-502`).
    pub fn snap_into(self, current: i64, total: i64) -> Option<i64> {
        let (lo, hi) = self.window(total)?;
        (current < lo || current > hi).then_some(lo)
    }

    /// While playing (`enforceTrimBoundaryIfPlaying`, `:518-537`): past Out wraps to In with loop on, holds Out and
    /// pauses with loop off; before In jumps to In. No trim: the clock's own loop / stop at the end.
    pub fn enforce(self, current: i64, total: i64, looping: bool) -> Option<Enforce> {
        let (lo, hi) = self.window(total)?;
        if current > hi {
            Some(if looping { Enforce::Seek(lo) } else { Enforce::SeekAndPause(hi) })
        } else if current < lo {
            Some(Enforce::Seek(lo))
        } else {
            None
        }
    }
}

/// What the trim window does to a playing clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Enforce {
    Seek(i64),
    SeekAndPause(i64),
}

/// The frame under `x` on a bar `width` wide (`ScrubBar.frameForX`, `:205-210`).
pub fn frame_for_x(x: f32, width: f32, total: i64) -> i64 {
    if total <= 1 || width <= 0.0 || !x.is_finite() {
        return 0;
    }
    let t = f64::from(x.clamp(0.0, width)) / f64::from(width);
    (t * (total - 1) as f64).round() as i64
}

/// Where frame `f` sits on a bar `width` wide (`ScrubBar.positionForFrame`, `:212-216`; the playhead uses the same
/// fraction, `:185-193`).
pub fn x_for_frame(f: i64, width: f32, total: i64) -> f32 {
    if total <= 1 {
        return 0.0;
    }
    let t = (f as f64 / (total - 1) as f64).clamp(0.0, 1.0);
    t as f32 * width
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONE: Trim = Trim { in_frame: None, out_frame: None };

    #[test]
    fn set_in_and_out_at_the_playhead() {
        // PreviewPaneTests.testPlayerModel_SetInAtCurrentFrame / SetOutAtCurrentFrame.
        assert_eq!(NONE.set_in_at(10), Trim::new(Some(10), None));
        assert_eq!(NONE.set_out_at(20), Trim::new(None, Some(20)));
    }

    #[test]
    fn set_in_after_out_pulls_out_along_and_vice_versa() {
        // testPlayerModel_SetInSnapsOutForward: out 5, playhead 20, set in → in 20, out 20.
        assert_eq!(Trim::new(None, Some(5)).set_in_at(20), Trim::new(Some(20), Some(20)));
        // testPlayerModel_SetOutSnapsInBackward: in 20, playhead 5, set out → out 5, in 5.
        assert_eq!(Trim::new(Some(20), None).set_out_at(5), Trim::new(Some(5), Some(5)));
        // Inside the window nothing else moves.
        assert_eq!(Trim::new(Some(2), Some(50)).set_in_at(10), Trim::new(Some(10), Some(50)));
        assert_eq!(Trim::new(Some(2), Some(50)).set_out_at(10), Trim::new(Some(2), Some(10)));
        // Equal is allowed (in ≤ out).
        assert_eq!(Trim::new(None, Some(10)).set_in_at(10), Trim::new(Some(10), Some(10)));
    }

    #[test]
    fn the_left_half_drag_keeps_in_before_out() {
        let total = 100;
        assert_eq!(NONE.dragged_in(-5, total), 0);
        assert_eq!(NONE.dragged_in(40, total), 40);
        assert_eq!(NONE.dragged_in(99, total), 98, "one before the last frame");
        assert_eq!(Trim::new(None, Some(30)).dragged_in(50, total), 29, "one before Out");
        assert_eq!(Trim::new(None, Some(0)).dragged_in(50, total), 0, "never negative");
    }

    #[test]
    fn the_right_half_drag_keeps_out_after_in() {
        let total = 100;
        assert_eq!(NONE.dragged_out(500, total), 99);
        assert_eq!(NONE.dragged_out(0, total), 1, "one after frame 0");
        assert_eq!(Trim::new(Some(40), None).dragged_out(10, total), 41, "one after In");
        assert_eq!(Trim::new(Some(99), None).dragged_out(10, total), 99, "never past the last frame");
    }

    #[test]
    fn play_snaps_into_the_window() {
        let total = 100;
        assert_eq!(NONE.snap_into(80, total), None, "no trim: unrestricted");
        let t = Trim::new(Some(10), Some(20));
        assert_eq!(t.snap_into(5, total), Some(10));
        assert_eq!(t.snap_into(25, total), Some(10));
        assert_eq!(t.snap_into(10, total), None);
        assert_eq!(t.snap_into(20, total), None);
        assert_eq!(Trim::new(None, Some(20)).snap_into(50, total), Some(0), "only Out: the window starts at 0");
        assert_eq!(Trim::new(Some(90), None).snap_into(3, total), Some(90), "only In: the window ends at the last frame");
    }

    #[test]
    fn playing_loops_inside_the_window_or_stops_at_out() {
        let total = 100;
        let t = Trim::new(Some(10), Some(20));
        assert_eq!(t.enforce(21, total, true), Some(Enforce::Seek(10)), "loop on: wrap to In");
        assert_eq!(t.enforce(21, total, false), Some(Enforce::SeekAndPause(20)), "loop off: hold Out, pause");
        assert_eq!(t.enforce(9, total, true), Some(Enforce::Seek(10)), "before In: jump to In");
        assert_eq!(t.enforce(9, total, false), Some(Enforce::Seek(10)));
        assert_eq!(t.enforce(15, total, true), None);
        assert_eq!(t.enforce(20, total, false), None);
        assert_eq!(NONE.enforce(99, total, false), None, "no trim: the clock's own end");
        // The clock's own wrap to 0 with only Out set lands inside; with In set it lands before In.
        assert_eq!(Trim::new(Some(50), None).enforce(0, total, true), Some(Enforce::Seek(50)));
    }

    #[test]
    fn bar_geometry() {
        assert_eq!(frame_for_x(0.0, 200.0, 101), 0);
        assert_eq!(frame_for_x(200.0, 200.0, 101), 100);
        assert_eq!(frame_for_x(100.0, 200.0, 101), 50);
        assert_eq!(frame_for_x(-30.0, 200.0, 101), 0, "clamped left");
        assert_eq!(frame_for_x(999.0, 200.0, 101), 100, "clamped right");
        assert_eq!(frame_for_x(1.0, 200.0, 101), 1, "0.5 rounds up");
        assert_eq!(frame_for_x(50.0, 200.0, 1), 0, "one frame: nothing to scrub");
        assert_eq!(frame_for_x(50.0, 0.0, 100), 0);
        assert_eq!(x_for_frame(50, 200.0, 101), 100.0);
        assert_eq!(x_for_frame(0, 200.0, 101), 0.0);
        assert_eq!(x_for_frame(500, 200.0, 101), 200.0, "clamped");
        assert_eq!(x_for_frame(5, 200.0, 1), 0.0);
        for f in 0..=100 {
            assert_eq!(frame_for_x(x_for_frame(f, 333.0, 101), 333.0, 101), f, "round trip of {f}");
        }
    }
}
