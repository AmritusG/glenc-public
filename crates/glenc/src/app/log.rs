//! The event log for the measured GUI runs (E5): with `GLENC_EVENT_LOG=<file>` set, one JSON line `{"event": "state", …}` every
//! time what the window shows changes (rows, selection, the encode, the prompt, the open window / sheet), and
//! `event` lines for what the OS sent. Nothing is written without the variable.

use super::{GlEnc, Sheet};
use serde_json::{Value, json};
use std::io::Write;

pub struct EventLog {
    pub(super) file: Option<std::fs::File>,
    pub(super) last: Option<Value>,
}

impl EventLog {
    pub fn from_env() -> EventLog {
        let file = std::env::var_os("GLENC_EVENT_LOG").and_then(|p| std::fs::OpenOptions::new().create(true).append(true).open(p).ok());
        EventLog { file, last: None }
    }

    pub fn enabled(&self) -> bool {
        self.file.is_some()
    }

    pub fn write(&mut self, v: Value) {
        if let Some(f) = self.file.as_mut() {
            let _ = writeln!(f, "{v}");
        }
    }

    /// Write the state when it changed since the last line.
    pub fn state(&mut self, app: &GlEnc) {
        if self.file.is_none() {
            return;
        }
        let s = snapshot(app);
        if self.last.as_ref() != Some(&s) {
            let mut line = s.clone();
            if let Some(o) = line.as_object_mut() {
                o.insert("event".into(), json!("state"));
            }
            self.write(line);
            self.last = Some(s);
        }
    }
}

fn snapshot(app: &GlEnc) -> Value {
    let q = &app.q;
    let v = q.settings.values();
    let rows: Vec<Value> = q
        .jobs
        .iter()
        .map(|j| {
            let s = &j.settings;
            json!({
                "id": j.id,
                "source": j.source.file_name().map(|n| n.to_string_lossy().into_owned()),
                "status": j.status.label(),
                "progress": (j.progress * 100.0).round() / 100.0,
                "name": j.output_name,
                "name_overridden": j.output_name_overridden,
                "family": s.family().label(),
                "format": s.format.raw(),
                "codec": format!("{:?}", s.codec),
                "container": s.container.raw(),
                "chunks": s.hap_chunks,
                "alpha_type": s.alpha_type.raw(),
                "audio": s.audio_enabled,
                "audio_rate": s.audio_rate.label(),
                "size": format!("{:?}", s.output_size),
                "quality": s.resize_quality.raw(),
                "aspect": s.aspect.raw(),
                "video": format!("{:?}", s.video),
                "crop": j.crop.map(|c| [c.x, c.y, c.width, c.height]),
                "in": j.in_frame, "out": j.out_frame,
                "error": j.error, "audio_warning": j.audio_warning,
                "output": j.output_path.as_ref().map(|p| p.display().to_string()),
                "source_size": [j.source_width, j.source_height], "fps": j.source_fps, "frames": j.source_frame_count,
                "has_alpha": j.source_has_alpha, "has_audio": j.source_has_audio,
                "preview_side": format!("{:?}", j.preview_side),
            })
        })
        .collect();
    json!({
        "rows": rows,
        "selected": q.selected,
        "selected_ids": q.selected_ids.iter().collect::<Vec<_>>(),
        "encoding": q.is_encoding(),
        "prompt": q.prompt.as_ref().map(|p| json!({"job": p.job, "existing": p.existing.display().to_string(), "rename": p.suggested_rename.display().to_string()})),
        "prefs_open": app.st.prefs_open,
        "sheet": app.st.sheet.as_ref().map(|s| match s { Sheet::CustomSize { .. } => "custom-size", Sheet::ManageSizes => "manage-sizes" }),
        "crop_edit": q.crop_edit.map(|(id, r)| json!({"row": id, "rect": r.map(|c| [c.x, c.y, c.width, c.height])})),
        "preview_visible": v.preview_pane_visible_by_default,
        "defaults": format!("{:?}", q.default_settings()),
        "settings": format!("{v:?}"),
    })
}
