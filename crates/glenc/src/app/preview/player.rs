//! The preview's player (Swift `PreviewPlayerModel.swift`) on glance-core's one player for every clip
//! (`glance_playback::ClipPlayer`: DXV, HAP and the OS-decoded clips). No window here — the pane draws it.
//!
//! - Routing is by content (glance-media), so `DXD4` plays like `DXD3` (Swift's DXV set lacks `DXD4`, `:204-206`:
//!   fixed on purpose, Amrit 2026-11-14 "fix").
//! - Every clip opens playing from frame 0 (`:278-280`); loop is the session's (default on, `:73`), carried to the
//!   next clip, never persisted.
//! - Sound as Swift's backends have it: HAP plays its audio track and that audio is the clock (`:177-200`), the OS
//!   path plays its sound (`AVPlayer`); DXV is silent (`DXVPlayer` has no audio path).
//! - The checkerboard shows only behind a clip with real alpha (`previewSourceHasAlpha`, `:97-106`; lessons §1, §5):
//!   DXV by its variant, HAP by its FourCC, OS clips by `ContainsAlphaChannel` (so an opaque ProRes 4444 is opaque) —
//!   glance-media's `has_alpha`.
//! - Alpha Type of the picture: HAP straight, OS clips as their format description states, DXV with alpha as the
//!   row's Alpha Type on the source side; a GlEnc DXV output is written from straight frames (the encoder
//!   un-premultiplies a premultiplied source on read), so it is drawn straight.

use super::trim::{Enforce, Trim};
use crate::job::PreviewSide;
use glance_encode::source::AlphaType;
use glance_media::{AlphaRule, AlphaView, CacheSettings, Route};
use glance_playback::{ClipPlayer, Shown, Sound};
use std::path::{Path, PathBuf};
use std::time::Instant;

/// The decoded-frame cache per clip (glance-sample's, Glance's and CueGlance's numbers).
pub const CACHE: CacheSettings = CacheSettings { capacity: 24, read_ahead: 8, threads: 4 };

/// Which clips play their sound (Swift's three backends).
pub fn sound_for(route: Route) -> Sound {
    match route {
        Route::Dxv => Sound::Off,
        Route::Hap | Route::Native | Route::Lmbd => Sound::Device,
    }
}

/// The Alpha Type the picture is drawn with.
pub fn alpha_view(rule: AlphaRule, side: PreviewSide, row_alpha_type: AlphaType) -> AlphaView {
    match rule {
        AlphaRule::Stated(v) => v,
        AlphaRule::Opaque => AlphaView::default(),
        AlphaRule::Choosable => match (side, row_alpha_type) {
            (PreviewSide::Source, AlphaType::Premultiplied) => AlphaView::Premultiplied,
            (PreviewSide::Source, AlphaType::Straight) | (PreviewSide::Output, _) => AlphaView::Straight,
        },
    }
}

/// The clip in the player.
pub struct Loaded {
    pub player: ClipPlayer,
    pub route: Route,
    pub rule: AlphaRule,
    /// The previewed file carries real alpha: the checkerboard shows behind it.
    pub has_alpha: bool,
    pub width: u32,
    pub height: u32,
    pub fps: f64,
}

impl Loaded {
    /// `totalFrames`.
    pub fn total(&self) -> i64 {
        i64::from(self.player.clock().clip().frames)
    }
    /// `currentFrame`.
    pub fn current(&self) -> i64 {
        i64::from(self.player.clock().current())
    }
}

/// `PreviewPlayerModel`.
pub struct Player {
    pub loaded: Option<Loaded>,
    /// The file last asked for, playing or not (`currentURL`): a failed load is not retried until it changes.
    pub path: Option<PathBuf>,
    /// `playState == .failed(msg)`.
    pub failure: Option<String>,
    /// `loopEnabled` (the session's).
    pub looping: bool,
    /// Bumped on every load / unload, so the pane redraws a new clip's frame 0.
    pub generation: u64,
}

impl Default for Player {
    fn default() -> Player {
        Player { loaded: None, path: None, failure: None, looping: true, generation: 0 }
    }
}

fn to_frame(n: i64) -> u32 {
    u32::try_from(n.max(0)).unwrap_or(u32::MAX)
}

impl Player {
    /// `load(url:)`: the old clip goes; the new one opens playing from frame 0 with the session's loop.
    pub fn load(&mut self, path: &Path) {
        self.unload();
        self.path = Some(path.to_path_buf());
        let opened = glance_media::route(path).and_then(|routed| {
            let player = ClipPlayer::open_with(path, CACHE, sound_for(routed.route))?;
            Ok((routed, player))
        });
        match opened {
            Ok((routed, mut player)) => {
                let info = &routed.info;
                let clock = player.clock_mut();
                clock.set_looping(self.looping);
                clock.seek(0);
                clock.play();
                self.loaded = Some(Loaded {
                    route: routed.route,
                    rule: glance_media::alpha_rule(info),
                    has_alpha: info.has_alpha,
                    width: info.width,
                    height: info.height,
                    fps: info.rate.as_f64(),
                    player,
                });
            }
            Err(e) => self.failure = Some(format!("Couldn't load: {}", e.message)),
        }
    }

    /// `unload()`: nothing loaded. The row's trim is untouched (`:635-642`).
    pub fn unload(&mut self) {
        if self.loaded.is_some() || self.path.is_some() || self.failure.is_some() {
            self.generation = self.generation.wrapping_add(1);
        }
        self.loaded = None;
        self.path = None;
        self.failure = None;
    }

    /// `totalFrames > 0`.
    pub fn is_playable(&self) -> bool {
        self.loaded.as_ref().is_some_and(|l| l.total() > 0)
    }

    pub fn is_playing(&self) -> bool {
        self.loaded.as_ref().is_some_and(|l| !l.player.clock().is_paused())
    }

    pub fn current(&self) -> i64 {
        self.loaded.as_ref().map_or(0, Loaded::current)
    }

    pub fn total(&self) -> i64 {
        self.loaded.as_ref().map_or(0, Loaded::total)
    }

    pub fn fps(&self) -> f64 {
        self.loaded.as_ref().map_or(0.0, |l| l.fps)
    }

    /// `play()`: a playhead outside the trim window starts at In.
    pub fn play(&mut self, trim: Trim) {
        let total = self.total();
        let Some(l) = self.loaded.as_mut() else { return };
        let clock = l.player.clock_mut();
        if let Some(f) = trim.snap_into(i64::from(clock.current()), total) {
            clock.seek(to_frame(f));
        }
        clock.play();
    }

    pub fn pause(&mut self) {
        if let Some(l) = self.loaded.as_mut() {
            l.player.clock_mut().pause();
        }
    }

    /// `togglePause()` (Space): un-pausing snaps into the trim window first.
    pub fn toggle_pause(&mut self, trim: Trim) {
        if self.is_playing() { self.pause() } else { self.play(trim) }
    }

    /// `seek(to:)`, clamped; play / pause kept.
    pub fn seek(&mut self, frame: i64) {
        if let Some(l) = self.loaded.as_mut() {
            l.player.clock_mut().seek(to_frame(frame));
        }
    }

    /// `step(by:)` (← / →): pause, then one frame, clamped.
    pub fn step(&mut self, delta: i64) {
        let Some(l) = self.loaded.as_mut() else { return };
        let clock = l.player.clock_mut();
        clock.pause();
        let target = i64::from(clock.current()) + delta;
        clock.seek(to_frame(target));
    }

    /// The loop button.
    pub fn set_looping(&mut self, looping: bool) {
        self.looping = looping;
        if let Some(l) = self.loaded.as_mut() {
            l.player.clock_mut().set_looping(looping);
        }
    }

    /// Advance the clock to `now` and hold playback inside the trim window (`enforceTrimBoundaryIfPlaying`, run
    /// before the frame is fetched so a frame past Out is never shown).
    pub fn advance(&mut self, now: Instant, trim: Trim) {
        let looping = self.looping;
        let Some(l) = self.loaded.as_mut() else { return };
        let total = l.total();
        let clock = l.player.clock_mut();
        if clock.is_paused() {
            return;
        }
        let current = i64::from(clock.tick(now));
        match trim.enforce(current, total, looping) {
            Some(Enforce::Seek(f)) => clock.seek(to_frame(f)),
            Some(Enforce::SeekAndPause(f)) => {
                clock.seek(to_frame(f));
                clock.pause();
            }
            None => {}
        }
    }

    /// The frame that belongs on screen at `now`.
    pub fn frame(&mut self, now: Instant) -> Option<Result<Shown, glance_media::MediaError>> {
        self.loaded.as_mut().map(|l| l.player.frame_at(now))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dxv_is_silent_hap_and_native_play_their_sound() {
        assert_eq!(sound_for(Route::Dxv), Sound::Off);
        assert_eq!(sound_for(Route::Hap), Sound::Device);
        assert_eq!(sound_for(Route::Native), Sound::Device);
    }

    #[test]
    fn the_alpha_type_of_the_picture() {
        use AlphaView::{Premultiplied as P, Straight as S};
        let src = PreviewSide::Source;
        let out = PreviewSide::Output;
        // HAP: straight whatever the row says; native: as stated.
        assert_eq!(alpha_view(AlphaRule::Stated(S), src, AlphaType::Premultiplied), S);
        assert_eq!(alpha_view(AlphaRule::Stated(P), src, AlphaType::Straight), P);
        // DXV with alpha: the row's Alpha Type on the source; GlEnc's straight output drawn straight.
        assert_eq!(alpha_view(AlphaRule::Choosable, src, AlphaType::Premultiplied), P);
        assert_eq!(alpha_view(AlphaRule::Choosable, src, AlphaType::Straight), S);
        assert_eq!(alpha_view(AlphaRule::Choosable, out, AlphaType::Premultiplied), S);
        // Opaque: nothing to read.
        assert_eq!(alpha_view(AlphaRule::Opaque, src, AlphaType::Straight), P);
    }

    #[test]
    fn a_new_player_loops_and_has_nothing() {
        // PreviewPaneTests.testPlayerModel_LoopToggleDefault / StepNoOpWhenNoPlayer / SetTrimNoOpWhenNoPlayer.
        let mut p = Player::default();
        assert!(p.looping);
        assert!(!p.is_playable());
        p.step(1);
        p.seek(10);
        p.toggle_pause(Trim::default());
        assert_eq!((p.current(), p.total(), p.is_playing()), (0, 0, false));
        p.set_looping(false);
        assert!(!p.looping, "the loop choice is kept for the next clip");
    }

    /// Swift's own DXT1 fixture (`.ref`, gitignored): skipped without it.
    fn fixture() -> Option<PathBuf> {
        let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.ref/glenc/fixtures/fixture-512x288-dxt1.mov");
        if p.exists() {
            Some(p)
        } else {
            eprintln!("skip: {} not found", p.display());
            None
        }
    }

    #[test]
    fn a_dxv_clip_opens_playing_and_holds_the_trim_window() {
        let Some(path) = fixture() else { return };
        let mut p = Player::default();
        p.load(&path);
        let l = p.loaded.as_ref().expect("the fixture plays");
        assert_eq!((l.route, l.width, l.height, l.has_alpha), (Route::Dxv, 512, 288, false));
        assert!(p.is_playing(), "auto-play on load (`:278-280`)");
        let total = p.total();
        assert_eq!(total, 15, "the fixture's frames");
        // testPlayerModel_SeekUpdatesCurrentFrame / SeekClampedToTotalRange / StepBy / StepClamped.
        p.seek(10);
        assert_eq!(p.current(), 10);
        p.seek(total + 50);
        assert_eq!(p.current(), total - 1);
        p.seek(-4);
        assert_eq!(p.current(), 0);
        p.step(-1);
        assert_eq!(p.current(), 0);
        assert!(!p.is_playing(), "a step pauses");
        p.step(3);
        assert_eq!(p.current(), 3);
        // Loop on: past Out wraps to In.
        let trim = Trim::new(Some(5), Some(9));
        p.play(trim);
        assert_eq!(p.current(), 5, "play from outside the window starts at In");
        p.seek(10);
        p.advance(Instant::now(), trim);
        assert_eq!(p.current(), 5);
        assert!(p.is_playing());
        // Loop off: past Out holds Out, paused.
        p.set_looping(false);
        p.seek(10);
        p.advance(Instant::now(), trim);
        assert_eq!((p.current(), p.is_playing()), (9, false));
        // A frame for the playhead decodes.
        let shown = p.frame(Instant::now()).expect("loaded").expect("decodes");
        assert_eq!(shown.index, 9);
        p.unload();
        assert!(p.loaded.is_none() && !p.looping, "loop stays the session's");
    }

    #[test]
    fn a_missing_file_fails_with_swifts_prefix_and_is_not_retried() {
        let mut p = Player::default();
        let path = Path::new("/nonexistent/glenc-preview-test.mov");
        p.load(path);
        assert!(p.loaded.is_none());
        assert!(p.failure.as_deref().is_some_and(|m| m.starts_with("Couldn't load: ")), "{:?}", p.failure);
        assert_eq!(p.path.as_deref(), Some(path), "the asked-for file is remembered");
        let g = p.generation;
        p.unload();
        assert!(p.failure.is_none() && p.path.is_none());
        assert_ne!(p.generation, g);
    }
}
