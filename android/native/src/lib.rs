//! Horizon on Android: the native library the app's activity loads (`ANDROID.md`).
//!
//! The Java side (`android/app/java`) is a `NativeActivity` subclass that loads this
//! library; `android-activity`'s glue then calls [`android_main`] on a thread of its own,
//! which sets up the game's folders, logging and crash reports and runs the game's own
//! loop (`horizon_client::run_game`, the same one the desktop binary runs). The few things
//! winit's Android backend cannot do (a real mouse, pointer capture, thermal state,
//! leaving) cross over through the plain functions at the end of this file, which the
//! Java side calls with numbers only.
//!
//! This crate is the only place with `unsafe` code: logcat, the environment and JNI.
#![cfg(target_os = "android")]

use std::ffi::{CString, c_char, c_int, c_void};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use horizon_client::platform::{self, PointerButton, PointerEvent};
use horizon_client::{crash, logging, mobile, winit_host};
use winit::platform::android::activity::AndroidApp;

/// The tag Horizon's lines carry in `adb logcat` (`adb logcat -s Horizon`).
const TAG: &std::ffi::CStr = c"Horizon";

/// A file in the game folder the Java launcher reads: why the last run ended, and whether
/// it ended at all.
const ERROR_FILE: &str = "last-error.txt";
const RUNNING_FILE: &str = "running.marker";

#[link(name = "log")]
unsafe extern "C" {
    fn __android_log_write(priority: c_int, tag: *const c_char, text: *const c_char) -> c_int;
}

/// Writes a line to logcat. `priority` is Android's: 2 verbose .. 6 error. Long text is cut
/// into pieces, as logcat drops what is past about 4000 bytes of an entry.
fn logcat(priority: u8, message: &str) {
    let mut rest = message;
    while !rest.is_empty() {
        let mut end = rest.len().min(3500);
        while !rest.is_char_boundary(end) {
            end -= 1;
        }
        let (piece, tail) = rest.split_at(end);
        rest = tail;
        if let Ok(text) = CString::new(piece.replace('\0', " ")) {
            // SAFETY: both pointers are NUL-terminated strings that outlive the call.
            unsafe {
                __android_log_write(c_int::from(priority), TAG.as_ptr(), text.as_ptr());
            }
        }
    }
}

/// The glue calls this once per activity, on its own thread. It returns when the game ends;
/// the glue then finishes the activity.
#[unsafe(no_mangle)]
fn android_main(app: AndroidApp) {
    static STARTED: AtomicBool = AtomicBool::new(false);
    // The Java side kills the game's process when its activity is destroyed, so this is the
    // only run in a process. A second one would find the game's process-wide state in use.
    if STARTED.swap(true, Ordering::SeqCst) {
        logcat(5, "Horizon: android_main ran twice in one process; leaving");
        return;
    }
    platform::set_log_sink(logcat);
    let files = files_dir(&app);
    // Panics are caught here so that the activity can finish (and the Java launcher can show
    // what happened) instead of the process aborting.
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| start(&app, &files)));
    let failure = match outcome {
        Ok(Ok(())) => None,
        Ok(Err(message)) => Some(message),
        Err(payload) => {
            let what = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".to_owned());
            Some(format!(
                "The game crashed: {what}\n\nA crash report is in the crash-reports folder of the game folder, and the log in logs/latest.log."
            ))
        }
    };
    logging::flush();
    let _ = fs::remove_file(files.join(RUNNING_FILE));
    if let Some(message) = failure {
        logcat(6, &format!("Horizon: {message}"));
        let _ = fs::write(files.join(ERROR_FILE), message);
    }
}

/// The app's folder on shared storage (`/sdcard/Android/data/<package>/files`), which `adb push`
/// and a file manager reach, else its private one.
fn files_dir(app: &AndroidApp) -> PathBuf {
    app.external_data_path()
        .or_else(|| app.internal_data_path())
        .unwrap_or_else(|| PathBuf::from("/data/local/tmp/horizon"))
}

fn start(app: &AndroidApp, files: &Path) -> Result<(), String> {
    fs::create_dir_all(files).map_err(|e| format!("Could not create {}: {e}", files.display()))?;
    let internal = app
        .internal_data_path()
        .unwrap_or_else(|| files.to_path_buf());
    let tmp = internal.join("tmp");
    let _ = fs::create_dir_all(&tmp);
    // The game takes its folder from the working directory and `HORIZON_HOME`, and a phone's
    // defaults for both (the root, and /data/local/tmp) are not writable.
    // SAFETY: the game's threads do not exist yet; this thread is the only one reading the
    // environment while it is set.
    unsafe {
        std::env::set_var("HORIZON_HOME", files);
        std::env::set_var("HOME", &internal);
        std::env::set_var("TMPDIR", &tmp);
        // The default panic hook prints a backtrace (to logcat) with this set.
        std::env::set_var("RUST_BACKTRACE", "1");
    }
    std::env::set_current_dir(files)
        .map_err(|e| format!("Could not enter {}: {e}", files.display()))?;
    fs::write(files.join(RUNNING_FILE), "running\n").ok();
    let _ = fs::remove_file(files.join(ERROR_FILE));
    logging::init(files, "Render thread");
    crash::mark_main_thread();
    crash::install(files.to_path_buf(), "client");
    log::info!(
        "Horizon for Android {} starting; game folder {}, private folder {}",
        env!("CARGO_PKG_VERSION"),
        files.display(),
        internal.display()
    );
    match mobile::seed(files) {
        Ok(written) if !written.is_empty() => {
            log::info!("Horizon: first start, wrote the phone defaults to {written:?}");
        }
        Ok(_) => {}
        Err(e) => log::warn!("Horizon: could not write the phone defaults: {e}"),
    }
    check_resources(files)?;
    winit_host::set_android_app(app.clone());
    if let Err(error) = horizon_client::run_game() {
        log::error!("Horizon: {error}");
        let report = crash::report_error(files, "client", &*error);
        let mut message = format!("The game stopped with an error:\n{error}");
        if let Some(report) = report {
            message.push_str(&format!("\n\nCrash report: {}", report.display()));
        }
        return Err(message);
    }
    Ok(())
}

/// Stops with a readable message when the prepared resources are not on the phone, which is
/// the first thing that goes wrong. A `--resources` in `horizon-args.txt` says the player put
/// them elsewhere.
fn check_resources(files: &Path) -> Result<(), String> {
    let args = fs::read_to_string(files.join("horizon-args.txt")).unwrap_or_default();
    if args.contains("--resources") {
        return Ok(());
    }
    let resources = files.join("resources");
    if resources.join("horizon-resources.json").is_file() {
        return Ok(());
    }
    Err(format!(
        "The game's resources are missing.\n\n\
         Horizon does not include Minecraft's files. Prepare them on a computer from your own \
         Minecraft Java Edition install with horizon-prepare, then copy the prepared folder \
         (the one that holds horizon-resources.json) to the phone:\n\n\
         adb push <prepared folder>/. {}/\n\n\
         The script android/push-resources does both steps. ANDROID.md has the details.",
        resources.display()
    ))
}

// ---- called from Java: numbers only ----------------------------------------------------------
//
// The Java class is `dev.horizon.android.HorizonActivity`; JNI finds these by name once the
// activity has loaded this library with `System.loadLibrary`.

/// The device's thermal status (`PowerManager.THERMAL_STATUS_*`).
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_horizon_android_HorizonActivity_nativeThermal(
    _env: *mut c_void,
    _class: *mut c_void,
    status: i32,
) {
    platform::set_thermal_status(status);
}

/// What the game asks of the platform, as bits: 1 captures the pointer, 2 shows the keyboard.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_horizon_android_HorizonActivity_nativeWants(
    _env: *mut c_void,
    _class: *mut c_void,
) -> i32 {
    platform::wants()
}

/// A mouse event. `kind` 0: the pointer is at (`a`, `b`) pixels; 1: it moved by (`a`, `b`)
/// while captured; 2: button `c` (0 left, 1 right, 2 middle) went down if `a` is positive,
/// else up; 3: the wheel turned by (`a`, `b`) lines.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_horizon_android_HorizonActivity_nativePointer(
    _env: *mut c_void,
    _class: *mut c_void,
    kind: i32,
    a: f32,
    b: f32,
    c: i32,
) {
    let event = match kind {
        0 => PointerEvent::Moved { x: a, y: b },
        1 => PointerEvent::Relative { dx: a, dy: b },
        2 => PointerEvent::Button {
            button: match c {
                1 => PointerButton::Right,
                2 => PointerButton::Middle,
                _ => PointerButton::Left,
            },
            down: a > 0.0,
        },
        3 => PointerEvent::Scroll { x: a, y: b },
        _ => return,
    };
    platform::push_pointer(event);
}

/// The activity is being destroyed: its `onDestroy` waits for the game thread to end, so the
/// game saves and leaves its loop.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_horizon_android_HorizonActivity_nativeExit(
    _env: *mut c_void,
    _class: *mut c_void,
) {
    platform::request_exit();
}
