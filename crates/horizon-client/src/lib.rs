//! Gameplay and startup, above the reusable client library.
#![forbid(unsafe_code)]
extern crate self as horizon_client;
pub use horizon_client_lib::*;
pub mod entry;
pub mod game;
pub mod mod_api;

/// Runs the game until it ends: the Android library's entry point (`horizon-android`). The
/// app has set up logging and crash reports already; a failed run comes back as an error
/// (the desktop `main` would exit the process, which an app must not do).
#[cfg(target_os = "android")]
pub fn run_game() -> Result<()> {
    entry::main_with(Default::default());
    entry::take_android_failure().map_or(Ok(()), |message| Err(message.into()))
}
