//! # glenc — GlEnc on glance-core
//!
//! The app's model, UI-free: settings (Swift GlEnc's 20 keys and encodings), the queue row and its codec rules,
//! auto-naming and output collisions, the queue engine. The encode itself is glance-core's `glance-encode`.

pub mod app;
pub mod cli;
pub mod job;
pub mod json;
pub mod naming;
pub mod queue;
pub mod settings;
