//! Mods without the WebAssembly runtime (the `runtime` feature off: Android by default, where
//! wasmtime is left out of the build; `ANDROID.md`). Same surface as `runtime.rs`, so the game
//! builds either way: mods are found and listed, and content-only mods (blocks, items, data and
//! assets, which need no code) load as on every platform, but a mod with code is listed as
//! stopped, with the reason, and nothing runs.
use crate::manifest::Package;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

/// The local player, as mods would read it.
#[derive(Clone, Debug, PartialEq)]
pub struct Player {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub yaw: f32,
    pub pitch: f32,
    pub health: f32,
    pub food: u32,
    pub dimension: String,
}

/// The world clock, as mods would read it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Clock {
    pub game_time: u64,
    pub day_time: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Corner {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub text: String,
    pub color: u32,
}

/// What mods may read of the game, copied once per tick by the game.
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub player: Option<Player>,
    pub clock: Option<Clock>,
}

/// What mods asked the game to show.
#[derive(Clone, Debug, PartialEq)]
pub enum Output {
    Chat { name: String, text: String },
    Feedback { text: String, error: bool },
    Stopped { name: String, reason: String },
}

/// A mod's text panel.
#[derive(Clone, Debug)]
pub struct Panel {
    pub corner: Corner,
    pub lines: Vec<Line>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    /// Installed and turned off by the player.
    Off,
    Running,
    /// Could not load or start.
    Failed(String),
}

/// One installed mod, for the Mods page.
pub struct Entry {
    pub path: PathBuf,
    /// None when the manifest could not be read (`status` says why).
    pub manifest: Option<crate::manifest::Manifest>,
    pub status: Status,
    pub cost: Duration,
}

/// The installed mods. Nothing here ever runs code.
#[derive(Default)]
pub struct Mods {
    entries: Vec<Entry>,
}

/// The `.hmod` files and mod folders in `dir`, by name.
pub fn find(dir: &Path) -> Vec<PathBuf> {
    let Ok(read) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut found: Vec<PathBuf> = read
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.extension().is_some_and(|e| e == "hmod")
                || p.join(crate::manifest::MANIFEST).is_file()
        })
        .collect();
    found.sort();
    found
}

impl Mods {
    /// Reads every mod at `paths`. Those `enabled` says are on load their content; one with
    /// code stays stopped.
    pub fn load(
        paths: &[PathBuf],
        enabled: impl Fn(&str) -> bool,
        _reserved: impl Fn(&str) -> bool,
    ) -> Mods {
        let mut mods = Mods::default();
        for path in paths {
            let mut entry = Entry {
                path: path.clone(),
                manifest: None,
                status: Status::Off,
                cost: Duration::ZERO,
            };
            match Package::read(path) {
                Err(e) => entry.status = Status::Failed(e),
                Ok(package) => {
                    let on = enabled(&package.manifest.id);
                    entry.manifest = Some(package.manifest.clone());
                    if on {
                        entry.status = if package.wasm.is_some() {
                            Status::Failed(
                                "this build has no WebAssembly runtime, so mods with code cannot run"
                                    .into(),
                            )
                        } else {
                            match crate::Content::read(path, &package.manifest) {
                                Ok(_) => Status::Running,
                                Err(e) => Status::Failed(e),
                            }
                        };
                    }
                }
            }
            if let (Status::Failed(reason), Some(m)) = (&entry.status, &entry.manifest) {
                log::warn!("Horizon: mod {} did not start: {reason}", m.id);
            }
            mods.entries.push(entry);
        }
        mods
    }

    /// Always false: no mod code runs here, so the game skips its mod work.
    pub fn is_running(&self) -> bool {
        false
    }
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }
    pub fn set_snapshot(&mut self, _snapshot: Snapshot) {}
    pub fn tick(&mut self, _tick: u64) {}
    pub fn frame(&mut self, _seconds: f32) {}
    pub fn chat(&mut self, _text: &str) {}
    pub fn has_command(&self, _name: &str) -> bool {
        false
    }
    pub fn command(&mut self, _line: &str) -> bool {
        false
    }
    pub fn commands(&self) -> impl Iterator<Item = &str> {
        std::iter::empty()
    }
    pub fn panels(&self) -> impl Iterator<Item = &Panel> {
        std::iter::empty()
    }
    pub fn drain(&mut self) -> Vec<Output> {
        Vec::new()
    }
    pub fn reload_changed(&mut self, _reserved: impl Fn(&str) -> bool) -> bool {
        false
    }
}
