//! GlEnc, the queue-based encoder for Resolume workflows.
#![cfg_attr(not(test), windows_subsystem = "windows")]

fn main() -> std::process::ExitCode {
    glenc::app::main()
}
